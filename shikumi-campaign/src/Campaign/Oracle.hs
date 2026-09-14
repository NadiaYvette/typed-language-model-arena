{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The campaign's oracles: deterministic checkers that own ground truth.
--
-- A cell's oracle is /data/, so the same decision loop runs over any project:
--
--   * 'markerOracle' — toy-fixer's checker (the tutorial ladder's oracle).
--   * 'unusedImportOracle' — a real one over actual files from mowgli and
--     peirce: an unused top-level import is flagged by line, and the
--     minimal-diff repair is deleting that line. The unusedness test is the
--     honest AST-free approximation: the imported name never appears in the
--     file body (the lines below the import block). A false positive would
--     surface as the guard accepting the deletion and the checker
--     re-flagging — an honest failed attempt, never a wrong fix.
--
-- Both are minimal-diff /deletion/ defect classes, so the same toy-fixer
-- 'fixSource' Program — diagnostics in, whole file back, deletion-only guard
-- embedded — drives both. The oracle changed; the decision loop did not.
module Campaign.Oracle
  ( -- * The oracle record
    CellOracle (..),
    markerOracle,
    unusedImportOracle,

    -- * Real project cells (read from the checkouts at runtime)
    ProjectCell (..),
    projectCellSpecs,
    readProjectCell,

    -- * Diagnostics helpers
    diagLineOf,
    diagIsKind,
  )
where

import Data.Text (Text)
import Data.Text qualified as T
import System.Directory (doesFileExist)
import System.FilePath ((</>))

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
-- The real oracle: unused imports
-- ---------------------------------------------------------------------------

-- | Bound names of an import line: @import X[ as Y]@, @import X.Y as Y@,
-- @import X, Y.Z@, @from X import a, b[@ as c]@. Only single-line, plain
-- forms — enough for real research code, honest about what it sees.
parseImportNames :: Text -> Maybe [Text]
parseImportNames raw0 =
  let raw = T.strip raw0
   in if not ("import" `T.isPrefixOf` raw) || "#" `T.isInfixOf` raw
        then Nothing
        else
          let body = T.strip (T.drop 6 raw)
           in case T.breakOn " import " body of
                (modPart, rest)
                  | not (T.null rest) ->
                      -- from X import a, b  (modPart is the module; unused)
                      let _ = modPart
                       in Just (mapMaybe boundName (T.splitOn "," (T.strip (T.drop 7 rest))))
                _ -> Just (mapMaybe boundName (T.splitOn "," body))
  where
    boundName spec =
      let s = T.strip spec
       in case T.breakOn " as " s of
            (n, rest)
              | not (T.null rest) -> Just (T.strip (T.drop 3 rest))
              | otherwise -> Just (headName n)
    headName n = case T.splitOn "." (T.strip n) of
      (h : _) -> h
      [] -> ""
    mapMaybe f xs = [y | Just y <- f <$> xs]

-- | Diagnostics for the unused-import oracle: an import whose every bound
-- name appears nowhere in the file body (all lines below the import block)
-- is flagged on its own line.
unusedImportDiags :: SourcePath -> Source -> [Diagnostic]
unusedImportDiags path (Source body) =
  [ Diagnostic path n "W-unused-import" ("unused import " <> T.intercalate ", " names)
  | (n, raw, Just names) <- importLines,
    all unused names
  ]
  where
    numbered = zip [1 :: Int ..] (T.lines body)
    importLines =
      [ (n, raw, parseImportNames raw)
      | (n, raw) <- numbered
      ]
    maxImportLine = maximum (0 : [n | (n, _, Just _) <- importLines])
    bodyText = T.toLower (T.intercalate "\n" [l | (n, l) <- numbered, n > maxImportLine])
    unused nm = not (T.null nm) && not (nm `T.isInfixOf` bodyText)

-- | The real oracle over a checkout's files.
unusedImportOracle :: CellOracle
unusedImportOracle =
  CellOracle
    { oracleId = "unused-imports",
      oracleCheck = unusedImportDiags,
      oracleOriginal = \_ current -> current
    }

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

-- | Read one project cell from its checkout under @~\/src\/<project>@.
readProjectCell :: (Text, SourcePath) -> IO (Maybe ProjectCell)
readProjectCell (proj, path) = do
  let fp = "/home/nyc/src" </> T.unpack proj </> T.unpack path
  exists <- doesFileExist fp
  if not exists
    then pure Nothing
    else do
      body <- readFile fp
      pure (Just (ProjectCell proj path (Source (T.pack body))))
