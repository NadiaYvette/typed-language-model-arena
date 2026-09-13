{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The one-cell campaign domain: what a verification cell is, and the
-- deterministic checker that owns ground truth.
--
-- The cell reuses toy-fixer's seeded corpus and its checker verbatim — the
-- point of the skeleton is that /nothing about the oracle changes/ when the
-- same decision loop moves onto a durable runtime. The file's original text
-- (the ground truth the no-regression guard needs) is persisted alongside the
-- cell, exactly as a campaign row would carry its input artifact.
module Campaign.Cell
  ( -- * Cells
    CellId (..),
    unCellId,
    mkCellId,
    Cell (..),
    corpusCells,
    cellForId,
    freshCellId,

    -- * The oracle (pure, deterministic, from toy-fixer)
    cellDiagnostics,
    cellIsClean,

    -- * The fix attempt record (what the decision step journals)
    FixAttempt (..),
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.List (find)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime)
import Data.UUID (UUID)
import Data.UUID.V4 (nextRandom)
import GHC.Generics (Generic)

import Toy.Fixer.Domain (Source (..), SourcePath, checkSource, corpus, showDiagnostic, sourceText)

-- | A cell identifier: campaign-local, opaque.
newtype CellId = CellId Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

mkCellId :: Text -> CellId
mkCellId = CellId

unCellId :: CellId -> Text
unCellId (CellId t) = t

-- | One verification cell: a file to check, its current contents, and the
-- original it must not regress from. In the real pgcl/telix campaigns the
-- contents come from a worktree and the original from the campaign's start
-- commit; here the corpus provides both.
data Cell = Cell
  { cellId :: !CellId,
    cellPath :: !SourcePath,
    cellOriginal :: !Source,
    cellCurrent :: !Source
  }
  deriving stock (Eq, Show)

-- | The campaign's cells: one per corpus entry, each seeded broken.
corpusCells :: [Cell]
corpusCells =
  [ Cell (CellId p) p orig broken
    | (p, broken, _expected) <- corpus,
      let orig = broken -- seeded broken; the original is the broken state
  ]

-- | Look a cell up by id (corpus cells carry their path as their id).
cellForId :: CellId -> Maybe Cell
cellForId cid = find (\c -> cellPath c == unCellId cid) corpusCells

-- | A fresh campaign-local cell id.
freshCellId :: IO CellId
freshCellId = CellId . T.take 8 . T.pack . show <$> (nextRandom :: IO UUID)

-- | Deterministic diagnostics for a cell's current contents: the oracle.
cellDiagnostics :: Cell -> [Text]
cellDiagnostics c = map showDiagnostic (checkSource (cellPath c) (cellCurrent c))

-- | The oracle's verdict: a cell is done when it is clean.
cellIsClean :: Cell -> Bool
cellIsClean = null . cellDiagnostics

-- | One LM fix attempt, journaled by the decision step. The repaired text
-- rides along (the workflow journal is the campaign's audit trail), so a
-- replayed workflow body continues from journaled attempts without re-asking
-- the model.
data FixAttempt = FixAttempt
  { faAttempt :: !Int,
    faSucceeded :: !Bool, -- ^ the no-regression guard accepted the repair
    faDiagnosticsBefore :: ![Text],
    faDiagnosticsAfter :: ![Text],
    faRepaired :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)
