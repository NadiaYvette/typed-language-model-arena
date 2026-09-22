{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The dispatch loop: the planner's plan lines become journaled work.
--
-- Act 17's planner emitted a typed plan whose every line carried a dispatch
-- class — @execute@ / @delegate@ / @verify@ — but the classes were
-- /advisory/: the driver printed them and ran nothing. This module closes
-- the loop. Each plan line becomes a 'planDispatchWorkflow' whose steps ARE
-- the dispatch:
--
--   * @execute@ runs the real executor this stack owns — a nested cell
--     campaign under a fresh dispatch tag (the inner run journals to its own
--     stream; the dispatch step records its outcome),
--   * @verify@ re-runs the real oracles against ground truth — a claim is
--     checked before anything builds on it,
--   * @delegate@ parks on the shared human seam — the operator's verdict is
--     recorded like every other journal event.
--
-- The dispatch journal cannot tell a plan line's execution from any other
-- campaign cell: same steps, same timers, same human seam. That is the
-- design property — planning is just another producer of campaign work.
module Campaign.Dispatch
  ( -- * Actions and outcomes
    DispatchAction (..),
    DispatchOutcome (..),
    dispatchActionOfPlanLine,
    dispatchWorkflowName,
    dispatchWorkflowIdTagged,
    dispatchCellKeyFromWf,
    dispatchRegistry,
    planDispatchWorkflow,
  )
where

import Campaign.Workflow (HumanVerdict (..), humanQueryStepName)
import Data.Aeson (FromJSON, ToJSON)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Effectful (Eff, IOE, raise, (:>))
import GHC.Generics (Generic)
import Keiro.Workflow (StepName (..), Workflow, WorkflowId (..), step)
import Keiro.Workflow.Awakeable (AwakeableId, awakeableNamed)
import Keiro.Workflow.Resume (WorkflowDef (..), WorkflowRegistry)
import Keiro.Workflow.Types (WorkflowName (..))
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Effect.Resource (KirokuStoreResource)

-- | One plan line, exactly as the planner emitted it (act 17's
-- @PortfolioNext@, flattened to plain data the dispatch layer can journal).
data DispatchAction = DispatchAction
  { daProject :: !Text,
    daAction :: !Text,
    daDispatch :: !Text, -- "execute" | "delegate" | "verify"
    daWhy :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | What running (or parking, or checking) the action decided.
data DispatchOutcome = DispatchOutcome
  { doProject :: !Text,
    doDispatch :: !Text,
    doResult :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | A plan line, as the planner wire shape delivers it (unField-ed).
dispatchActionOfPlanLine :: Text -> Text -> Text -> Text -> DispatchAction
dispatchActionOfPlanLine project action dispatch why =
  DispatchAction {daProject = project, daAction = action, daDispatch = dispatch, daWhy = why}

dispatchWorkflowName :: WorkflowName
dispatchWorkflowName = WorkflowName "plan-dispatch"

dispatchWorkflowIdTagged :: Text -> Text -> WorkflowId
dispatchWorkflowIdTagged project tag = WorkflowId ("dispatch:" <> project <> ":" <> tag)

dispatchCellKeyFromWf :: WorkflowId -> Maybe (Text, Text)
dispatchCellKeyFromWf (WorkflowId t) = case T.splitOn ":" t of
  ["dispatch", project, tag] -> Just (project, tag)
  _ -> Nothing

-- | The dispatch registry: every action rebuilt from its id (the project
-- and tag name it). The executors are the run's closures — built once per
-- act from the real machinery (cell campaigns, oracles, the human seam).
dispatchRegistry ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es) =>
  -- | publish the human-query awakeable id
  (AwakeableId -> Eff es ()) ->
  -- | the run tag (fresh per act run)
  Text ->
  -- | the plan lines this run dispatches, keyed by project
  [DispatchAction] ->
  -- | execute: run the real campaign the line names (a nested workflow)
  (DispatchAction -> Eff es Text) ->
  -- | verify: re-run the real oracles the line names
  (DispatchAction -> Eff es Text) ->
  WorkflowRegistry es
dispatchRegistry publishHumanQuery tag actions execExecute execVerify =
  Map.fromList
    [ ( dispatchWorkflowName,
        WorkflowDef $ \wid ->
          case dispatchCellKeyFromWf wid of
            Nothing -> error ("dispatchRegistry: malformed workflow id " <> show wid)
            Just (project, _) ->
              case [a | a <- actions, T.strip (daProject a) == project] of
                (action : _) ->
                  planDispatchWorkflow
                    (raise . publishHumanQuery)
                    tag
                    action
                    (raise . execExecute)
                    (raise . execVerify)
                [] -> error ("dispatchRegistry: no plan line for project " <> T.unpack project)
      )
    ]

-- | The dispatch workflow: the plan line's class decides which REAL thing
-- runs. Every branch journals its outcome as a step result.
planDispatchWorkflow ::
  (Workflow :> es, KirokuStoreResource :> es, Store :> es, IOE :> es) =>
  -- | publish the human-query awakeable id
  (AwakeableId -> Eff es ()) ->
  -- | the run tag (names the dispatch cell's own journals)
  Text ->
  DispatchAction ->
  -- | execute: run the real campaign the line names
  (DispatchAction -> Eff es Text) ->
  -- | verify: re-run the real oracles the line names
  (DispatchAction -> Eff es Text) ->
  Eff es DispatchOutcome
planDispatchWorkflow publishHumanQuery _tag action execExecute execVerify =
  case T.toLower (T.strip (daDispatch action)) of
    "execute" -> do
      result <- step (StepName "execute") (execExecute action)
      pure (DispatchOutcome (daProject action) "execute" result)
    "verify" -> do
      result <- step (StepName "verify") (execVerify action)
      pure (DispatchOutcome (daProject action) "verify" result)
    "delegate" -> do
      result <- park ("delegated by the plan: " <> daAction action <> " — " <> daWhy action)
      recorded <- step (StepName "delegate") (pure result)
      pure (DispatchOutcome (daProject action) "delegate" recorded)
    other -> do
      -- An unknown class is recorded, never run: the planner's vocabulary
      -- is closed, and a plan line outside it is a finding, not a crash.
      let note = other <> ": unknown dispatch class — recorded, not run"
      recorded <- step (StepName "unknown") (pure note)
      pure (DispatchOutcome (daProject action) other recorded)
  where
    park reason = do
      (awakeableId, awaitVerdict) <- awakeableNamed humanQueryStepName
      _publication <- step (StepName "publish-human-query") (publishHumanQuery awakeableId)
      verdict <- awaitVerdict
      case verdict of
        VerdictApproved -> pure ("human-approved: " <> reason)
        VerdictRejected -> pure ("human-rejected: " <> reason)
