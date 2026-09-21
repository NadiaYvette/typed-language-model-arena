{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}

-- | Repair blueprints and receipts (Track 10, milestone 3 — Vector D model).
--
-- A /blueprint/ is the repair task handed to an agent (the campaign analogue
-- of a seihou Blueprint): which cell, which oracle, the failing source state
-- with its diagnostics, the repair rules, and the prompt. A /receipt/ is the
-- evidence of one pass-to-fail-to-pass trajectory: the failing state, the
-- applied operations (original line numbers), and the passing state.
--
-- Per seihou ADR 0011 a migration receipt asserts a claim about the
-- project; per the Track 10 facts-only decision (and invariant #4) the claim
-- is /re-derived, never trusted/. 'admitReceipt' replays the receipt's
-- operations and re-runs the named oracle on both states; the receipt is
-- admissible only if every re-derived fact matches what it recorded. An
-- admitted receipt is evidence for the review gate — approveBranch still
-- owns the final oracle re-verification of the branch's actual files.

module Campaign.RepairReceipt
  ( -- * Schemas
    RepairOp (..),
    SourceState (..),
    RepairRules (..),
    RepairBlueprint (..),
    RepairReceipt (..),

    -- * Loading
    loadRepairBlueprint,
    loadRepairReceipt,

    -- * Admission (re-derivation under the oracle)
    admitReceipt,
    replayOps,
  )
where

import Control.Exception qualified as E
import Control.Exception (SomeException)
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)
import GHC.Natural (Natural)

import Dhall qualified as Dhall
import Toy.Fixer.Domain (Source (..), showDiagnostic)

import Campaign.Oracle (CellOracle (..))

-- ---------------------------------------------------------------------------
-- Schema types (field names mirror the Dhall record keys exactly, so the
-- dhall library's generic FromDhall decodes a validated file directly)
-- ---------------------------------------------------------------------------

-- | One minimal-diff repair step. The corpus's repair contract (the
-- toy-fixer subset guard) makes repairs deletions only, so the union starts
-- with 'DeleteLine'. This is the campaign analogue of seihou's MigrationOp.
-- | One minimal-diff repair step. The corpus's repair contract (the
-- toy-fixer subset guard: "every line must appear in order in the original")
-- makes repairs /deletions only/, so an operation is a single record shape:
-- delete the line at ORIGINAL number @opLine@, whose text must be @opText@.
-- This is the campaign analogue of seihou's MigrationOp; when a second op
-- kind (e.g. ReplaceLine) is needed, RepairOp graduates to a Dhall union and
-- the receipt schema bumps a version. (A single-constructor union does not
-- derive to its own Dhall union type — the dhall package derives it to the
-- payload record — so the record is the honest first shape.)
data RepairOp = DeleteLine
  { opLine :: !Natural,
    -- ^ the ORIGINAL line number the operation deletes
    opText :: !Text
    -- ^ the line's text, recorded so a tampered op fails re-derivation
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Dhall.FromDhall, Dhall.ToDhall)

-- | A source state as the oracle sees it: the bytes and its diagnostics,
-- rendered in the exact '<path>:<line>: warning: [W-code] message' shape.
data SourceState = SourceState
  { ssSource :: !Text,
    ssDiagnostics :: ![Text]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Dhall.FromDhall, Dhall.ToDhall)

-- | The repair contract the blueprint imposes on the agent.
data RepairRules = RepairRules
  { rrSubsetOnly :: !Bool,
    rrDeletionsOnly :: !Bool,
    rrMaxOperations :: !Natural
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Dhall.FromDhall, Dhall.ToDhall)

data RepairBlueprint = RepairBlueprint
  { rbName :: !Text,
    rbProject :: !Text,
    rbTargetCell :: !Text,
    rbOracleId :: !Text,
    rbPath :: !Text,
    rbRules :: !RepairRules,
    rbBroken :: !SourceState,
    rbPrompt :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Dhall.FromDhall, Dhall.ToDhall)

data RepairReceipt = RepairReceipt
  { rcName :: !Text,
    rcBlueprint :: !Text,
    rcProject :: !Text,
    rcPath :: !Text,
    rcOracleId :: !Text,
    rcBefore :: !SourceState,
    rcOperations :: ![RepairOp],
    rcAfter :: !SourceState,
    rcCheckedBy :: !Text,
    rcCheckedAt :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (Dhall.FromDhall, Dhall.ToDhall)

-- ---------------------------------------------------------------------------
-- Loading: the dhall library typechecks the file (imports resolved) before
-- decoding — a malformed or mistyped receipt is an operator error, surfaced,
-- not a silent no-op (seihou ADR 0003 spirit).
-- ---------------------------------------------------------------------------

loadRepairBlueprint :: FilePath -> IO (Either Text RepairBlueprint)
loadRepairBlueprint path = do
  m <-
    E.try (Dhall.inputFileWithSettings Dhall.defaultEvaluateSettings Dhall.auto path)
      :: IO (Either SomeException RepairBlueprint)
  pure $ case m of
    Left e -> Left (T.pack (show e))
    Right t -> Right t

loadRepairReceipt :: FilePath -> IO (Either Text RepairReceipt)
loadRepairReceipt path = do
  m <-
    E.try (Dhall.inputFileWithSettings Dhall.defaultEvaluateSettings Dhall.auto path)
      :: IO (Either SomeException RepairReceipt)
  pure $ case m of
    Left e -> Left (T.pack (show e))
    Right t -> Right t

-- ---------------------------------------------------------------------------
-- Admission: re-derive every claim under the named oracle
-- ---------------------------------------------------------------------------

-- | Replay the receipt's operations on the before-state to reconstruct the
-- after-state. The subset contract makes repairs /deletions from the
-- original/, so a 'DeleteLine' names an original line number; replay is a
-- single pass that drops every deleted line (order-independent). This is the
-- claim we /check/ rather than trust: the replayed source must equal the
-- recorded after-state, and each op's text must match the original line it
-- names (a tampered op fails re-derivation).
replayOps :: Text -> [RepairOp] -> Text
replayOps src ops = T.intercalate "\n" [l | (i, l) <- zip [1 ..] (T.lines src), i `notElem` deletedLines]
  where
    -- intercalate (not T.unlines) so no trailing newline is added: the
    -- recorded before/after states are stored without one, and the replay
    -- must byte-match the recorded after-state.
    deletedLines =
      [ fromIntegral (opLine op)
      | op <- ops,
        opApplies src op
      ]

opApplies :: Text -> RepairOp -> Bool
opApplies src (DeleteLine {opLine = ln, opText = tx}) =
  let lines = T.lines src
      i = fromIntegral ln - 1
   in 0 <= i && i < length lines && lines !! i == tx

-- | Admit a receipt: re-derive its claims under 'oracle'. Returns
-- 'Right ()' when every fact matches (the receipt is admissible evidence) or
-- 'Left' with the list of re-derivation failures (it is not). This is the
-- facts-only seam: the oracle is the judge, the receipt is the claim.
admitReceipt :: CellOracle -> RepairReceipt -> Either [Text] ()
admitReceipt oracle rc =
  let path = rcPath rc
      beforeSrc = ssSource (rcBefore rc)
      recordedAfterSrc = ssSource (rcAfter rc)
      replayedAfterSrc = replayOps beforeSrc (rcOperations rc)

      reBeforeDiags = renderDiagnostics path beforeSrc
      reAfterDiags = renderDiagnostics path replayedAfterSrc

      failures =
        [ "replayed operations do not reproduce the recorded after-state"
            | replayedAfterSrc /= recordedAfterSrc
        ]
          <> [ "recorded before-diagnostics do not match the oracle: "
                <> T.intercalate "; " reBeforeDiags
            | reBeforeDiags /= ssDiagnostics (rcBefore rc)
        ]
          <> [ "recorded after-diagnostics do not match the oracle: "
                <> T.intercalate "; " reAfterDiags
            | reAfterDiags /= ssDiagnostics (rcAfter rc)
        ]
          -- the pass-to-fail-to-pass shape: the before-state must actually fail
          <> [ "before-state has no diagnostics — not a failing repair"
              | null reBeforeDiags
          ]
          -- and the replayed after-state must actually pass
          <> [ "after-state still has diagnostics: " <> T.intercalate "; " reAfterDiags
              | not (null reAfterDiags)
          ]
          -- each operation must be a faithful deletion of a real original line
          <> [ "operation " <> T.pack (show (i + 1)) <> " is not a faithful deletion of an original line"
          | (i, op) <- zip [0 :: Int ..] (rcOperations rc),
            not (opApplies beforeSrc op)
          ]
   in if null failures then Right () else Left failures
  where
    renderDiagnostics p s = map showDiagnostic (oracleCheck oracle p (Source s))
