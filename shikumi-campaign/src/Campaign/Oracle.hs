{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The campaign's oracles: deterministic checkers that own ground truth.
--
-- A cell's oracle is /data/, so the same decision loop runs over any project:
--
--   * 'markerOracle' — toy-fixer's checker (the tutorial ladder's oracle).
--   * 'unusedImportOracle' — a real one over actual files from real
--     checkouts: an unused top-level import is flagged by line, and the
--     minimal-diff repair is deleting that statement. The unusedness test is
--     the honest AST-free approximation: the imported name never appears in
--     the file body (the lines below the import block). A false positive
--     would surface as the guard accepting the deletion and the checker
--     re-flagging — an honest failed attempt, never a wrong fix.
--
-- The widened vocabulary (this is the "widen the corpus" run): single- and
-- multi-name imports, @from@ imports, dotted roots (@import os.path@ binds
-- @os@), and parenthesized multi-line statements tracked by /span/. The
-- oracle still refuses what it cannot see honestly: star imports (their
-- exports are unknowable without the module), @__future__@ imports
-- (deleting one changes runtime semantics), and anything with a comment.
--
-- Both oracles are minimal-diff /deletion/ defect classes, so the same
-- toy-fixer 'fixSource' Program — diagnostics in, whole file back,
-- deletion-only guard embedded — drives both. The oracle changed; the
-- decision loop did not.
module Campaign.Oracle
  ( -- * The oracle record
    CellOracle (..),
    markerOracle,
    unusedImportOracle,

    -- * Import parsing (the surgical guard re-derives spans from these)
    ImportSpec (..),
    importSpecsOf,
    flaggedLinesOf,

    -- * The syntax floor
    pythonSyntaxCheck,

    -- * Real project cells (read from the checkouts at runtime)
    ProjectCell (..),
    projectCellSpecs,
    readProjectCell,
    scanProjectUnusedImportCells,

    -- * Diagnostics helpers
    diagLineOf,
    diagIsKind,
  )
where

import Data.List (foldl', sort)
import Control.Monad (filterM)
import Data.Text (Text)
import Data.Text qualified as T
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.FilePath (makeRelative, takeExtension, (</>))
import System.Exit (ExitCode (..))
import System.Process.Typed (byteStringInput, proc, readProcess, setStdin)
import Data.Text.Lazy qualified as TL
import Data.Text.Lazy.Encoding qualified as TLE

import Toy.Fixer.Domain (Diagnostic (..), Source (..), SourcePath, checkSource)

-- ---------------------------------------------------------------------------
-- The oracle record
-- ---------------------------------------------------------------------------

-- | One project's deterministic ground truth: what the checker is, and what
-- the no-regression /original/ is for a given cell.
data CellOracle = CellOracle
  { oracleId :: !Text,
    -- | Diagnostics for a (path, current contents) pair.
    oracleCheck :: !(SourcePath -> Source -> [Diagnostic]),
    -- | The original a cell's repairs must not regress from. For the seeded
    -- corpus the original is the broken seed; for real files it is the file
    -- as read from the checkout.
    oracleOriginal :: !(SourcePath -> Source -> Source)
  }

-- | The tutorial ladder's oracle, verbatim.
markerOracle :: CellOracle
markerOracle =
  CellOracle
    { oracleId = "toy-markers",
      oracleCheck = checkSource,
      oracleOriginal = \_ current -> current
    }

-- ---------------------------------------------------------------------------
-- Import parsing: statements, spans, bound names
-- ---------------------------------------------------------------------------

-- | One import statement as the oracle sees it: the /span/ it occupies
-- (start line .. end line, inclusive, so a parenthesized multi-line import
-- can be deleted whole) and the names it binds, dotted down to their roots
-- (@import os.path@ binds @os@).
data ImportSpec = ImportSpec
  { isStart :: !Int,
    isEnd :: !Int,
    isNames :: ![Text]
  }
  deriving stock (Eq, Show)

-- | Parse the import statement beginning at the head of @ls@ (the first
-- line is already known to start one). Continuation lines are consumed
-- while parentheses remain open — the parenthesized multi-line form. The
-- parser refuses, honestly, what it cannot see through: a comment anywhere
-- in the statement, a star import, an @__future__@ import. @Nothing@ means
-- "not an import this oracle speaks"; the statement is left unflagged.
importSpecFrom :: [Text] -> Maybe ImportSpec
importSpecFrom ls = do
  (raw, nLines) <- chunk
  if "#" `T.isInfixOf` raw || "*" `T.isInfixOf` raw || "__future__" `T.isInfixOf` raw
    then Nothing
    else do
      names <- parseNames raw
      pure (ImportSpec 1 (max 1 nLines) names)
  where
    chunk :: Maybe (Text, Int)
    chunk = go [] 0 0 ls
      where
        -- acc: reversed lines; open: paren depth before this line; i: lines seen
        go acc _ i [] =
          if null acc then Nothing else Just (T.intercalate "\n" (reverse acc), i)
        go acc open i (y : ys)
          | i > 0 && open <= 0 = Just (T.intercalate "\n" (reverse acc), i) -- statement ended
          | otherwise = go (y : acc) (open + T.count "(" y - T.count ")" y) (i + 1) ys
    parseNames raw =
      let flat = T.intercalate " " (map T.strip (T.lines raw))
          s = T.strip flat
       in if not ("import" `T.isPrefixOf` s)
            then Nothing
            else
              let body = T.strip (T.drop 6 s)
               in case T.breakOn " import " body of
                    (_modPart, rest)
                      | not (T.null rest) ->
                          -- from X import a, b — the module part binds nothing itself
                          Just [n | spec <- T.splitOn "," (T.strip (T.drop 7 rest)), Just n <- [boundName spec]]
                    _ -> Just [n | spec <- T.splitOn "," body, Just n <- [boundName spec]]
    boundName spec =
      let s = T.strip spec
       in if T.null s
            then Nothing
            else case T.breakOn " as " s of
              (n, rest)
                | not (T.null rest) -> Just (T.strip (T.drop 3 rest))
                | otherwise -> Just (rootName n)
    rootName n = case T.splitOn "." (T.strip n) of
      (h : _) -> h
      [] -> ""

-- | Every import statement in the file, with absolute line spans.
importSpecsOf :: Source -> [ImportSpec]
importSpecsOf (Source body) = go (zip [1 ..] (T.lines body))
  where
    go [] = []
    go ws@((n, l) : rest)
      | startsImport (T.strip l) =
          let -- The statement's continuation lines: consumed only while the
              -- first line's parens are still open. A closed statement owns
              -- exactly itself — the next line belongs to the next
              -- statement, never to this one.
              takeChunk [] _ = []
              takeChunk (y : ys) open
                | open <= 0 = []
                | otherwise = y : takeChunk ys (open + T.count "(" y - T.count ")" y)
              chunk = l : takeChunk (map snd rest) (T.count "(" l - T.count ")" l)
           in case importSpecFrom chunk of
                Just spec -> spec {isStart = n, isEnd = n + length chunk - 1} : go (drop (length chunk - 1) rest)
                Nothing -> go rest
      | otherwise = go rest
    startsImport s =
      "import " `T.isPrefixOf` s
        || s == "import"
        || "from " `T.isPrefixOf` s

-- ---------------------------------------------------------------------------
-- The real oracle: unused imports
-- ---------------------------------------------------------------------------

-- | Diagnostics for the unused-import oracle: an import whose every bound
-- name appears nowhere in the file body (all lines below the import block)
-- is flagged on its /first/ line — the repair is deleting the whole span.
--
-- The abstention rule: the oracle only speaks about files whose import
-- statements all sit in the /leading top-level import block/. An indented
-- import (function-local) or one after the first code line (a
-- @TYPE_CHECKING@ block, a lazy import) means names can be used /above/ the
-- import's line — the "body is below the block" test would then flag names
-- that are used, and the repair would break working code. On any such file
-- the oracle returns @[]@ — it does not know, so it does not say.
unusedImportDiags :: SourcePath -> Source -> [Diagnostic]
unusedImportDiags path (Source body) =
  [ Diagnostic path (isStart spec) "W-unused-import" ("unused import " <> T.intercalate ", " (isNames spec))
  | not abstain,
    spec <- specs,
    all unused (isNames spec)
  ]
  where
    numbered = zip [1 :: Int ..] (T.lines body)
    specs = importSpecsOf (Source body)
    bodyLines = T.lines body
    rawLine n = bodyLines !! (n - 1)
    -- The first /executable/ line: not blank, not a comment, not inside the
    -- leading module docstring (a docstring is not executable — a name in it
    -- is never a use, so it must not trigger the abstention). Triple-quote
    -- toggles from the top; a miscount's failure mode is "treat everything
    -- as in-block", the pre-abstention behavior, whose residual risk is only
    -- on files that also carry an out-of-block import.
    firstCodeLine = go 1 0
      where
        qcount l = T.count "\"\"\"" l + T.count "'''" l
        inImport n = any (\spec -> n >= isStart spec && n <= isEnd spec) specs
        go n quotes
          | n > length bodyLines = maxBound
          | quotes `rem` 2 == 1 = go (n + 1) (quotes + qcount l) -- inside a docstring
          | qcount l `rem` 2 == 1 = go (n + 1) (quotes + qcount l) -- opens a docstring
          | inImport n = go (n + 1) quotes -- imports are not executable
          | T.null (T.strip l) || "#" `T.isPrefixOf` T.strip l = go (n + 1) quotes
          | otherwise = n
          where
            l = rawLine n
    abstain
      | null specs = False
      | otherwise =
          any (\spec -> isStart spec > firstCodeLine || isIndented (isStart spec)) specs
    isIndented n = let l = rawLine n in " " `T.isPrefixOf` l || "\t" `T.isPrefixOf` l
    maxImportLine = foldl' (\acc s -> max acc (isEnd s)) 0 specs
    -- Case-sensitive, as Python identifiers are. (Lowercasing the body — an
    -- early shortcut — made every CamelCase import unmatchable: a used
    -- `analyseOutput` read as unused. The tessera run caught it.)
    bodyText = T.intercalate "\n" [l | (n, l) <- numbered, n > maxImportLine]
    unused nm = not (T.null nm) && not (nm `T.isInfixOf` bodyText)

-- | The real oracle over a checkout's files.
unusedImportOracle :: CellOracle
unusedImportOracle =
  CellOracle
    { oracleId = "unused-imports",
      oracleCheck = unusedImportDiags,
      oracleOriginal = \_ current -> current
    }

-- | The lines whose deletion the surgical guard allows for a cell: the
-- oracle's flagged lines /extended to whole import statements/ (a flagged
-- multi-line import must be deleted whole), plus blank lines. Re-derived
-- from the same span parser the oracle flags with, so guard and oracle can
-- never disagree about what a statement is.
flaggedLinesOf :: Source -> [Int] -> [Int]
flaggedLinesOf src@(Source body) flaggedStarts =
  sort (concat [spanLines spec | spec <- specs, isStart spec `elem` flaggedStarts])
    ++ blankLines
  where
    specs = importSpecsOf src
    spanLines spec = [isStart spec .. isEnd spec]
    numbered = zip [1 ..] (T.lines body)
    blankLines = [n | (n, l) <- numbered, T.null (T.strip l)]

-- | A Python syntax check: @python3@ compiles the source, in memory, via
-- @ast.parse@. The widened oracle (parenthesized multi-line imports that
-- the surgical guard may now delete whole) makes unparseable repairs a
-- /typed possibility/ the AST-free oracle cannot see — a partial deletion
-- inside a multi-line statement can leave a file that no longer parses
-- while flagging no diagnostics. This is the honesty floor under every
-- repair: @Just msg@ means the source does not parse.
pythonSyntaxCheck :: SourcePath -> Source -> IO (Maybe Text)
pythonSyntaxCheck path (Source body) = do
  let code = "import ast,sys; ast.parse(sys.stdin.read()); print('OK')"
      stdinBytes = TLE.encodeUtf8 (TL.fromStrict body)
  (ec, out, err) <- readProcess (setStdin (byteStringInput stdinBytes) (proc "python3" ["-c", code]))
  pure $ case ec of
    ExitSuccess -> Nothing
    _ ->
      Just $
        T.pack (T.unpack path <> ": does not parse as Python")
          <> (case (T.strip (TL.toStrict (TLE.decodeUtf8 err)), T.strip (TL.toStrict (TLE.decodeUtf8 out))) of
                ("", o) -> if T.null o then "" else " " <> o
                (e, o) -> " — " <> lastLine e <> (if T.null o then "" else " " <> o))
  where
    lastLine = T.intercalate " " . filter (not . T.null) . take 1 . reverse . T.lines

-- ---------------------------------------------------------------------------
-- Diagnostics helpers (the fleet's scripted "good model" reads these)
-- ---------------------------------------------------------------------------

diagLineOf :: Diagnostic -> Int
diagLineOf = diagLine

diagIsKind :: Text -> Diagnostic -> Bool
diagIsKind kind d = diagCode d == kind

-- ---------------------------------------------------------------------------
-- Real project cells
-- ---------------------------------------------------------------------------

-- | One real file: project, in-checkout path, contents as read.
data ProjectCell = ProjectCell
  { pcProject :: !Text,
    pcPath :: !SourcePath,
    pcSource :: !Source
  }
  deriving stock (Eq, Show)

-- | The cells the campaign will attempt, as @(project, in-checkout path)@ pairs — files the
-- outer scan found carrying unused imports. Read at runtime so the cells are the real
-- bytes on disk, not embedded copies.
projectCellSpecs :: [(Text, SourcePath)]
projectCellSpecs =
  [ ("mowgli", "llada_interface.py"),
    ("peirce", "python/base_model.py"),
    ("peirce", "python/pdf_extract.py")
  ]

-- | Read one project cell from its checkout under @~\\/src\\/<project>@.
readProjectCell :: (Text, SourcePath) -> IO (Maybe ProjectCell)
readProjectCell (proj, path) = do
  let fp = "/home/nyc/src" </> T.unpack proj </> T.unpack path
  exists <- doesFileExist fp
  if not exists
    then pure Nothing
    else do
      body <- readFile fp
      pure (Just (ProjectCell proj path (Source (T.pack body))))

-- | Directories never scanned: VCS internals, virtualenvs, caches, build
-- outputs, editor machinery. The scan is of the project's /source/.
skipDirNames :: [FilePath]
skipDirNames =
  [ ".git", ".hg", ".svn", ".claude", ".venv", "venv", ".venv-diffusion",
    "__pycache__", ".mypy_cache", ".pytest_cache", ".ruff_cache",
    "node_modules", "dist", "build", ".tox", ".hypothesis", "target"
  ]

-- | The outer scan for the application phase: every @.py@ file under a
-- checkout (recursively, skipping 'skipDirNames') that the oracle flags —
-- the real defects, found by the real oracle, read from the real bytes on
-- disk. A file the oracle clears is not a cell: there is nothing for the
-- campaign to do on it.
scanProjectUnusedImportCells :: Text -> IO [ProjectCell]
scanProjectUnusedImportCells proj = do
  let root = "/home/nyc/src" </> T.unpack proj
  paths <- walk root root
  candidates <- mapM (readProjectCell . (proj,)) paths
  pure
    [ pc
    | Just pc <- candidates
    , not (null (oracleCheck unusedImportOracle (pcPath pc) (pcSource pc)))
    ]
  where
    -- Paths are /project-root-relative/ — the invariant every downstream
    -- consumer relies on: readProjectCell joins them against the parent
    -- checkout, and the landing hands join them against the worktree (a
    -- checkout of the same tree). An absolute path here once made
    -- `wt </> path` silently discard the worktree prefix — the parent
    -- checkout would have been the write target.
    walk root dir = do
      entries <- listDirectory dir
      let rel e = T.pack (makeRelative root (dir </> e))
          pyHere = sort [rel e | e <- entries, takeExtension e == ".py"]
      subdirs <-
        mapM (walk root . (dir </>))
          =<< filterM (doesDirectoryExist . (dir </>))
            [e | e <- entries, e `notElem` skipDirNames, takeExtension e /= ".py"]
      pure (pyHere ++ concat subdirs)
