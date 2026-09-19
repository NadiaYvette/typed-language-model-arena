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
    ImportClause (..),
    ImportSpec (..),
    importSpecsOf,
    flaggedLinesOf,

    -- * The repair contract
    RepairRules (..),
    repairRulesFor,

    -- * The syntax floor
    pythonSyntaxCheck,

    -- * The use test (the oracle's, exposed for probes and rules)
    nameUsedIn,
    executableBodyText,

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

import Data.Char (isAlphaNum)
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
-- (start line .. end line, inclusive) and its top-level clauses. Each
-- clause is a source line, the names it binds, and its module text — the
-- ingredients of both the flag decision and the canonical rewrite
-- (@repairRulesFor@ rebuilds a partially-used statement from the kept
-- clauses' module text).
data ImportClause = ImportClause
  { icLine :: !Int,
    icNames :: ![Text],
    -- | The clause's spec text as written (@sys@, @os.path@, @a as b@) —
    -- the ingredient a canonical rewrite recombines.
    icSpec :: !Text
  }
  deriving stock (Eq, Show)

data ImportSpec = ImportSpec
  { isStart :: !Int,
    isEnd :: !Int,
    -- | @Just mod@ for @from mod import ...@, @Nothing@ for plain imports.
    isFromMod :: !(Maybe Text),
    isClauses :: ![ImportClause]
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
      clauses <- parseClauses raw
      let isFrom = "from " `T.isPrefixOf` T.strip (head ls)
          fromMod
            | isFrom = Just (T.strip (T.takeWhile (/= ' ') (T.strip (T.drop 5 (head (T.lines raw))))))
            | otherwise = Nothing
      pure (ImportSpec 1 (max 1 nLines) fromMod clauses)
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
    -- Clauses are the statement split at top-level commas (not commas
    -- nested in parens — @from x import (a, b)@ is one clause).
    parseClauses raw =
      let ls' = T.lines raw
          s = T.strip (T.intercalate " " (map T.strip ls'))
       in if not ("import" `T.isPrefixOf` s || "from " `T.isPrefixOf` s)
            then Nothing
            else
              let isFrom = "from " `T.isPrefixOf` s
                  body
                    | isFrom = T.strip (T.drop 7 (snd (T.breakOn " import " s)))
                    | otherwise = T.strip (T.drop 6 s)
                  specs = splitTopCommas body
                  clauseOf spec =
                    let st = T.strip spec
                     in if T.null st
                          then Nothing
                          else
                            let names = case T.breakOn " as " st of
                                  (n, r)
                                    | not (T.null r) -> [T.strip (T.drop 3 r)]
                                    | otherwise -> [rootName n]
                             in Just (names, st)
               in Just
                    [ ImportClause 0 names st
                    | spec <- specs
                    , Just (names, st) <- [clauseOf spec]
                    ]
    rootName n = case T.splitOn "." (T.strip n) of
      (h : _) -> h
      [] -> ""
    -- Commas at paren depth zero only. The pieces of @T.splitOn ","@ are
    -- the text /between/ commas, so the comma decision happens after each
    -- piece: if the paren depth accumulated through the piece is back to
    -- zero, the comma that followed it was top-level and the piece ends a
    -- clause; otherwise the piece continues the clause (inside parens).
    splitTopCommas t = go (T.splitOn "," t) "" 0
      where
        go [] cur _ = [T.strip cur | not (T.null (T.strip cur))]
        go (p : ps) cur depth =
          let cur' = cur <> p
              depth' = depth + T.count "(" p - T.count ")" p
           in if depth' <= 0
                then [T.strip cur' | not (T.null (T.strip cur'))] <> go ps "" 0
                else go ps (cur' <> ", ") depth'

-- | Every import statement in the file, with absolute line spans.
importSpecsOf :: Source -> [ImportSpec]
importSpecsOf src = go (executableLines src)
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
  [ Diagnostic path (isStart spec) "W-unused-import" msg
  | not abstain,
    spec <- specs,
    let unusedClauses = [c | c <- isClauses spec, all unused (icNames c)],
    not (null unusedClauses),
    let unusedNames = concatMap (filter unused . icNames) unusedClauses
        msg
          | length unusedClauses == length (isClauses spec) =
              "unused import " <> T.intercalate ", " unusedNames
          | otherwise =
              "unused import names " <> T.intercalate ", " unusedNames
                <> " (statement partially used — rewrite keeping the used names)"
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
    -- `analyseOutput` read as unused. The tessera run caught it.) The body
    -- is comment-stripped ('executableBodyText'): a name mentioned only in
    -- a comment is not a use.
    bodyText =
      let maxImportLine = foldl' (\acc s -> max acc (isEnd s)) 0 specs
       in T.intercalate "\n" [l | (n, l) <- executableBodyLines (Source body), n > maxImportLine]
    unused nm = not (nameUsedIn nm bodyText)

-- | Is a bound name /used/ in the body text? The precise test: the name
-- occurs as a whole word (identifier boundaries on both sides) /and not as
-- an attribute/ — an occurrence preceded by @.@ is a field of some other
-- object (@shutil.copyfile@ uses @shutil@, never the @copyfile@ binding).
-- This is what the bare substring test could not see: it read
-- @shutil.copyfile@ as a use of @copyfile@ and stayed silent on a cell
-- whose honest repair is deleting the import.
--
-- Still conservative in the safe direction: a keyword argument
-- (@f(copyfile=…)@) reads as a use, so a shadowed-argument corner counts
-- as used and is never touched.
nameUsedIn :: Text -> Text -> Bool
nameUsedIn nm body
  | T.null nm = False
  | otherwise = any ok (occurrences nm body)
  where
    isIdentChar c = isAlphaNum c || c == '_'
    ok i =
      let prevC = if i == 0 then Nothing else Just (T.index body (i - 1))
          nextC = if i + T.length nm >= T.length body then Nothing else Just (T.index body (i + T.length nm))
       in maybe True (\c -> not (isIdentChar c) && c /= '.') prevC
            && maybe True (not . isIdentChar) nextC
    occurrences needle t = go 0 t
      where
        go base rest = case T.breakOn needle rest of
          (pre, hit)
            | T.null hit -> []
            | otherwise -> (base + T.length pre) : go (base + T.length pre + 1) (T.drop 1 hit)

-- | The body with comments and docstrings removed — the text the use test
-- reads, shared by the oracle and the repair rules so they can never
-- disagree about what counts as a use.
--
-- What is stripped, and why it is safe:
--
--   * /End-of-line @#@ comments/ — a name mentioned in a comment is not a
--     use (socketFuncs.py's @import socket@ was held by a comment alone).
--   * /Multi-line triple-quoted spans/ — docstrings and long string
--     statements. A name in a docstring is never a code use (the AST
--     reference counts only Name nodes); deleting an import cannot break
--     a docstring.
--
-- What deliberately stays: string contents on ordinary lines — a
-- @getattr(o, "name")@ style use is real, so counting them keeps the
-- conservative direction: we may still hold a name for a string mention,
-- never delete a used import.
--
-- Line-scoped and parity-based: a line with an odd triple-quote count
-- opens or closes a span and is dropped /whole/ (the corner: a real use
-- sharing a line with an unmatched triple quote would be missed — no such
-- line exists in any scanned checkout, and the scan-only validation
-- against the AST detector is the standing check). Quoting opened and
-- closed on one line (@"""a"""@) is even and the line is kept.
executableBodyLines :: Source -> [(Int, Text)]
executableBodyLines src = [(n, stripEol l) | (n, l) <- executableLines src]
  where
    nOf l = T.length l
    -- Cut at the first # outside single/double quotes on this line. A
    -- line with an unterminated quote resolves Nothing and stays verbatim
    -- (the conservative direction: a comment mention still reads as use).
    stripEol l = case scan 0 of
      Just i -> T.take i l
      Nothing -> l
      where
        scan i
          | i >= nOf l = Nothing
          | c == '#' = Just i
          | c == '"' = scanPast (i + 1) '"'
          | c == '\'' = scanPast (i + 1) '\''
          | otherwise = scan (i + 1)
          where c = T.index l i
        scanPast j close
          | j >= nOf l = Nothing
          | T.index l j == close = scan (j + 1)
          | otherwise = scanPast (j + 1) close

-- | The executable body as one text ('executableBodyLines', numbering
-- preserved — the pair form is what region tests need).
executableBodyText :: Source -> Text
executableBodyText = T.intercalate "\n" . map snd . executableBodyLines

-- | The @(lineNumber, line)@ pairs /outside/ triple-quoted spans — the
-- file's executable text with original numbering. The parity rule lives
-- here, once, and both consumers share it: the use test
-- ('executableBodyText') so a docstring mention is never a use, and the
-- span parser ('importSpecsOf') so a docstring line is never an import
-- statement (socketFuncs.py's @from ACL2 instance …@ docstring line once
-- parsed as an indented import and vetoed the whole file through the
-- abstention rule).
executableLines :: Source -> [(Int, Text)]
executableLines (Source body) = go 0 (zip [1 ..] (T.lines body))
  where
    go _ [] = []
    go quotes ((n, l) : rest)
      | odd quotes = go (quotes + qcount l) rest -- inside a triple-quoted span
      | odd (qcount l) = go (quotes + qcount l) rest -- opens/closes a span on this line
      | otherwise = (n, l) : go quotes rest
      where
        qcount x = T.count "\"\"\"" x + T.count "'''" x
    -- Cut at the first # that is outside single/double quotes on this line.
    -- A line with an odd quote count at scan end (apostrophes in words, an
    -- unterminated literal) resolves nothing: keep the line verbatim.
    stripEol l = case scan 0 0 of
      Just i -> T.take i l
      Nothing -> l
      where
        n = T.length l
        scan i q
          | i >= n = Nothing
          | c == '#', q == 0 = Just i
          | c == '"' = scanPast (i + 1) '"'
          | c == '\'' = scanPast (i + 1) '\''
          | otherwise = scan (i + 1) q
          where
            c = T.index l i
        -- Scan past a quoted span (q = which quote kind, unused beyond
        -- readability) and resume normal scanning after its close. An
        -- unterminated span resolves Nothing: the line stays verbatim.
        scanPast j close
          | j >= n = Nothing
          | T.index l j == close = scan (j + 1) 0
          | otherwise = scanPast (j + 1) close

-- | The real oracle over a checkout's files.
unusedImportOracle :: CellOracle
unusedImportOracle =
  CellOracle
    { oracleId = "unused-imports",
      oracleCheck = unusedImportDiags,
      oracleOriginal = \_ current -> current
    }

-- | The repair contract for one cell, /as data/: the lines whose deletion
-- the guard allows (fully-flagged statements and blanks) and, for a
-- partially-used statement, the canonical rewrite of its first line that
-- keeps exactly the used clauses. Computed by re-deriving the spans and
-- clauses from the same parser the oracle flags with, so guard and oracle
-- can never disagree about what a statement is or what keeping it means.
--
-- The rewrite is /canonical/: the model does not get to invent a formatting
-- for the kept clause — the guard compares against this exact line, so a
-- "rewrite" that also reformats the neighbors, or keeps the wrong clause,
-- is not a repair this contract admits.
data RepairRules = RepairRules
  { rrDroppableLines :: ![Int],
    rrRewrite :: !(Maybe (Int, Text))
  }

repairRulesFor :: Source -> [Int] -> RepairRules
repairRulesFor src@(Source body) flaggedStarts =
  RepairRules
    { -- Droppable: whole spans of fully-flagged import statements, plus any
      -- flagged line that is not an import statement's start (the toy-marker
      -- cells' contract: the flagged line is the deletion). The partially-
      -- used statement's span is /not/ droppable — deleting it whole would
      -- silently remove its used names; only the rewrite admits it.
      rrDroppableLines =
        sort
          ( nub
              ( [n | n <- flaggedStarts, n `notElem` map isStart specs]
                  ++ concat [[isStart s .. isEnd s] | s <- specs, isStart s `elem` flaggedStarts, not (partiallyUsed s)]
              )
          ),
      rrRewrite = rewrite
    }
  where
    specs = importSpecsOf src
    -- The diagnostic sits on the statement's first line; a partial flag is
    -- recognizable by clause count: some clause keeps a used name.
    rewrite = case [spec | spec <- specs, isStart spec `elem` flaggedStarts, partiallyUsed spec] of
      [spec] ->
        let keptSpecs = [icSpec c | c <- isClauses spec, not (allNamesUnused (icNames c))]
            newStmt = case isFromMod spec of
              Just m -> "from " <> m <> " import " <> T.intercalate ", " keptSpecs
              Nothing -> "import " <> T.intercalate ", " keptSpecs
         in Just (isStart spec, newStmt)
      _ -> Nothing
    partiallyUsed spec =
      length (isClauses spec) > length [c | c <- isClauses spec, allNamesUnused (icNames c)]
        && not (null [c | c <- isClauses spec, allNamesUnused (icNames c)])
    -- The same use-test the oracle flags with, verbatim: whole-word,
    -- attribute-disqualified occurrences in the case-sensitive,
    -- comment-stripped body below the import block.
    allNamesUnused = all (\nm -> not (T.null nm) && not (nameUsedIn nm bodyText))
    bodyText =
      let maxImportLine = foldl' (\acc s -> max acc (isEnd s)) 0 specs
       in T.intercalate "\n" [l | (n, l) <- executableBodyLines (Source body), n > maxImportLine]
    nub = foldr (\x acc -> x : filter (/= x) acc) []

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
  [ ("mowgli", "src/adapters/llada_interface.py"),
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
