{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The one-cell campaign as a keiro durable workflow.
--
-- The decision layer is toy-fixer's shikumi fixer 'Program', promoted into a
-- journaled process:
--
--   1. @verify-initial@ — a plain step journals the oracle's diagnostics.
--   2. @propose-fix-N@ — one LM attempt per step. The step action runs the
--      shikumi program (stub model here; a live stack is the same call)
--      under the attempt-keyed responder and applies the typed
--      no-regression guard. The journaled result is the 'FixAttempt' record
--      (with the repair), so replay never re-asks the model — attempts are
--      durable decisions. A crash between "model answered" and "journal
--      written" re-runs the attempt (at-least-once, jitsurei's publisher
--      contract).
--   3. A durable 'sleepNamed' paces attempts (in a real campaign: the build
--      or boot itself).
--   4. If the budget is exhausted with the cell still failing, the workflow
--      parks on an 'awakeableNamed' — the typed human seam — after
--      publishing the query id through an idempotent callback.
--   5. The 'HumanVerdict' signal (or a clean cell at any checkpoint)
--      completes the workflow with a verdict line.
module Campaign.Workflow
  ( -- * Names
    cellCampaignWorkflowName,
    campaignWorkflowId,
    campaignIdFromWf,
    campaignStreamNameText,

    -- * The human seam
    HumanVerdict (..),
    humanQueryStepName,

    -- * The decision step's configuration
    AttemptResponder,
    HumanQueryPublisher,

    -- * The workflow
    cellCampaignWorkflow,
    defaultMaxAttempts,

    -- * The registry
    campaignRegistry,
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock (NominalDiffTime)
import Effectful (Eff, IOE, liftIO, raise, (:>))
import GHC.Generics (Generic)

import Baikai (Context, Response)
import Campaign.Memory (recallNotesForKeyword)
import Kiroku.Store.Effect.Resource (KirokuStoreResource)
import Shikumi.Error (ShikumiError)
import Shikumi.Program (Program, runProgram)
import Shikumi.Schema.Types (Field (..))
import Shikumi.Testing (runStubEval)
import Toy.Fixer.Domain (Source (..), checkSource, showDiagnostic, sourceText)
import Toy.Fixer.Program (DiagnosticsIn (..), RepairOut (..), fixSource)

import Campaign.Cell
  ( Cell (..),
    CellId (..),
    FixAttempt (..),
    cellDiagnostics,
    cellForId,
    cellIsClean,
    unCellId,
  )

import Keiro.Workflow
  ( StepName (..),
    Workflow,
    WorkflowId (..),
    step,
    workflowStreamName,
  )
import Keiro.Workflow.Awakeable (AwakeableId, awakeableNamed)
import Keiro.Workflow.Resume (WorkflowDef (..), WorkflowRegistry)
import Keiro.Workflow.Sleep (sleepNamed)
import Keiro.Workflow.Types (WorkflowName (..))
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Types (StreamName (..))

-- ---------------------------------------------------------------------------
-- Names and identity
-- ---------------------------------------------------------------------------

cellCampaignWorkflowName :: WorkflowName
cellCampaignWorkflowName = WorkflowName "cell-campaign"

-- | The workflow instance id embeds the cell id, so the journal stream is
-- findable from the cell alone and the registry can rebuild the body from
-- the id (mirroring jitsurei's order-id round trip). A @-escalation@ suffix
-- distinguishes a second campaign over the same cell (the demo's act 2) from
-- the first; both map back to the same cell.
campaignWorkflowId :: CellId -> WorkflowId
campaignWorkflowId (CellId t) = WorkflowId ("cell-" <> t)

campaignIdFromWf :: WorkflowId -> CellId
campaignIdFromWf (WorkflowId t0) = CellId cellPath
  where
    t1 = fromMaybe t0 (T.stripPrefix "cell-" t0)
    cellPath = fromMaybe t1 (T.stripSuffix "-escalation" t1)

campaignStreamNameText :: WorkflowName -> WorkflowId -> Text
campaignStreamNameText name wid =
  let StreamName s = workflowStreamName name wid in s

-- ---------------------------------------------------------------------------
-- The human seam: the typed third outcome
-- ---------------------------------------------------------------------------

data HumanVerdict = VerdictApproved | VerdictRejected
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | The awakeable step name for the human verdict.
humanQueryStepName :: StepName
humanQueryStepName = StepName "human-verdict"

-- ---------------------------------------------------------------------------
-- The decision step's configuration
-- ---------------------------------------------------------------------------

-- | The scripted model, keyed by attempt number and given the recalled
-- memory notes the attempt step recalled (a live model would see them as
-- prompt lines). Lets the demo script a failing first attempt and a good
-- second one (the informed-retry story), or a permanently confused model
-- (the escalation story). A live stack swaps this for the routing
-- interpreters; the workflow body is untouched.
type AttemptResponder = Int -> [Text] -> Context -> Response

-- | Publish a human query's awakeable id to the outside world. Must be
-- idempotent: like jitsurei's webhook publisher, its action has
-- at-least-once execution across the action-to-journal crash window.
type HumanQueryPublisher es = AwakeableId -> Eff es ()

-- | The demo's typed attempt budget.
defaultMaxAttempts :: Int
defaultMaxAttempts = 3

-- ---------------------------------------------------------------------------
-- The decision step: run the shikumi fixer under an attempt-keyed responder
-- ---------------------------------------------------------------------------

-- | Run one LM fix attempt against a cell, with recalled memory as extra
-- guidance. Step actions get full IOE, so the stub-or-live interpreter stack
-- runs right here. Returns the repaired source when the model's proposal
-- passed the no-regression guard (the guard lives inside 'fixSource';
-- failures surface as typed 'ShikumiError's, recorded as failed attempts).
runFixAttempt ::
  (IOE :> es) =>
  Cell ->
  AttemptResponder ->
  -- | recalled memory notes, already rendered as prompt lines
  [Text] ->
  Int ->
  Eff es (Maybe Source)
runFixAttempt cell responder notes n = do
  let orig = cellOriginal cell
      prog :: Program DiagnosticsIn RepairOut
      prog = fixSource orig
      input =
        DiagnosticsIn
          (Field (cellPath cell))
          (Field (cellDiagnostics cell))
  r <- liftIO $ runStubEval (responder n notes) (runProgram prog input)
  case r of
    Right (RepairOut (Field txt)) -> pure (Just (Source txt))
    Left (_ :: ShikumiError) -> pure Nothing

-- | One attempt, as a step action: recall lessons (a kioku read, journaled
-- into the record — replay never re-recalls), run the model, apply the guard.
attemptRecord :: (IOE :> es, KirokuStoreResource :> es, Store :> es) => Cell -> AttemptResponder -> Int -> Eff es FixAttempt
attemptRecord cell responder n = do
  let before = cellDiagnostics cell
      -- The keywords the diagnostics themselves suggest: the memory consulted
      -- is a function of the task, not of the caller.
      diagKws = concat [keywordsOf d | d <- before]
  notes <- if null diagKws then pure [] else concat <$> mapM recallNotesForKeyword diagKws
  mRepaired <- runFixAttempt cell responder notes n
  case mRepaired of
    Nothing ->
      pure
        FixAttempt
          { faAttempt = n,
            faSucceeded = False,
            faDiagnosticsBefore = before,
            faDiagnosticsAfter = before,
            faRecallNotes = notes,
            faRepaired = Nothing
          }
    Just repaired -> do
      let after = map showDiagnostic (checkSource (cellPath cell) repaired)
          ok = null after
      pure
        FixAttempt
          { faAttempt = n,
            faSucceeded = ok,
            faDiagnosticsBefore = before,
            faDiagnosticsAfter = after,
            faRecallNotes = notes,
            faRepaired = Just (sourceText repaired)
          }
  where
    -- Diagnostic-kind keywords to recall lessons for. The toy checker's codes
    -- are the vocabulary; a real campaign would map its own diagnostics.
    keywordsOf d
      | "W-todo" `T.isInfixOf` d = ["todo"]
      | "W-unused" `T.isInfixOf` d = ["unused"]
      | otherwise = []

-- ---------------------------------------------------------------------------
-- The workflow
-- ---------------------------------------------------------------------------

-- | Pacing between attempts. A real campaign's inter-attempt delay is the
-- build/boot itself; the journal semantics are identical.
interAttemptDelay :: NominalDiffTime
interAttemptDelay = 1

-- | The one-cell campaign. @maxAttempts@ is the typed attempt budget; the
-- responder supplies the "model"; the publisher hands human-query ids to the
-- outside world. The final result is a verdict line.
cellCampaignWorkflow ::
  (Workflow :> es, KirokuStoreResource :> es, Store :> es, IOE :> es) =>
  AttemptResponder ->
  HumanQueryPublisher es ->
  Cell ->
  Int ->
  Eff es Text
cellCampaignWorkflow responder publishHumanQuery cell maxAttempts = do
  -- 1) Journal the oracle's initial verdict for the cell as received.
  _initial <- step (StepName "verify-initial") (pure (cellDiagnostics cell))
  if cellIsClean cell
    then pure "passed: cell was already clean"
    else go 1
  where
    go n
      | n > maxAttempts = budgetExhausted
      | otherwise = do
          -- 2) One durable LM attempt, journaled with its repair...
          attempt <-
            step (StepName ("propose-fix-" <> T.pack (show n))) (attemptRecord cell responder n)
          -- 3) ...paced by a durable timer...
          sleepNamed (StepName ("settle-" <> T.pack (show n))) interAttemptDelay
          -- 4) ...then the oracle decides: done, or another attempt.
          if faSucceeded attempt && null (faDiagnosticsAfter attempt)
            then pure ("passed: fix attempt " <> T.pack (show n) <> " cleared the cell")
            else go (n + 1)

    -- Budget exhausted, cell still failing: park on the human seam.
    budgetExhausted = do
      (awakeableId, awaitVerdict) <- awakeableNamed humanQueryStepName
      _publication <-
        step (StepName "publish-human-query") (publishHumanQuery awakeableId)
      verdict <- awaitVerdict
      case verdict of
        VerdictApproved -> pure "human-approved: cell remains failing; verdict recorded"
        VerdictRejected -> pure "human-rejected: cell remains failing; verdict recorded"

-- ---------------------------------------------------------------------------
-- The registry
-- ---------------------------------------------------------------------------

-- | The application-supplied registry the resume worker re-invokes through.
-- It rebuilds the workflow body from the id alone: the cell comes from the
-- corpus via its id, the responder and publisher are ambient. Both must be
-- registered — here just the parent (no child workflows in the skeleton).
campaignRegistry ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es) =>
  AttemptResponder ->
  HumanQueryPublisher es ->
  WorkflowRegistry es
campaignRegistry responder publishHumanQuery =
  Map.fromList
    [ ( cellCampaignWorkflowName,
        WorkflowDef $ \wid ->
          case cellForId (campaignIdFromWf wid) of
            Nothing -> error ("campaignRegistry: unknown cell " <> T.unpack (unCellId (campaignIdFromWf wid)))
            Just cell ->
              cellCampaignWorkflow
                responder
                (raise . publishHumanQuery)
                cell
                defaultMaxAttempts
      )
    ]
