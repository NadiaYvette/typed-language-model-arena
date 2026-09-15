{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The verification matrix: campaign cells that are (arch × config) matrix
-- entries with a hardware-ish testing process, not one-shot file fixes.
--
-- The pgcl campaign this generalizes is a matrix of architecture ×
-- configuration cells where each cell's verification is a staged process —
-- build, boot, verify — and a failing cell can mean anything from "retry
-- with a config knob turned" to "a human must walk to the board". This
-- module models that shape honestly but offline:
--
--   * a 'MatrixCell' is one (arch × config) entry with its synthetic device
--     log; the full grid is 'matrixCellSpecs' (3 architectures × 3 configs);
--   * verification is a staged pipeline journaled as durable steps: the boot
--     stage (kernel, init, net) and the stress stage (iteration counts and
--     failures) are deterministic functions of the cell and attempt number —
--     data, so replay reproduces every stage exactly;
--   * a failing stage goes to a /triage/ LM program ('triageSignature') whose
--     typed verdict splits the two futures a real matrix has: a retryable
--     fault loops back through a cool-down timer; a fault that
--     'TriageOut.needsHardware' parks the cell on the /same human seam/ the
--     fixer campaign already has ('humanQueryStepName') — the operator
--     answers, the workflow resumes.
--
-- The decision layer is again a shikumi program: the triage signature's
-- output is a typed record (a boolean plus operator advice), so "should a
-- human intervene" is data the workflow acts on, not prose it parses.
module Campaign.Matrix
  ( -- * Cells
    ArchName (..),
    ConfigName (..),
    MatrixCell (..),
    mkMatrixCell,
    matrixCellId,
    matrixCellSpecs,
    matrixFaultKind,
    FaultKind (..),
    -- * Workflow
    matrixWorkflowName,
    campaignMatrixWorkflowId,
    matrixWorkflowIdTagged,
    matrixCellFromWf,
    matrixCellWorkflow,
    matrixRegistry,
    MatrixEngine,
    matrixStubEngine,
    MatrixAttempt (..),
    matrixAttemptsOf,
    -- * The triage program
    TriageIn (..),
    TriageOut (..),
    triageSignature,
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Aeson qualified as Aeson
import Data.List (isPrefixOf, stripPrefix)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock (NominalDiffTime)
import Effectful (Eff, IOE, liftIO, raise, (:>))
import GHC.Generics (Generic)

import Campaign.Cell (CellId (..), unCellId)
import Campaign.Memory (projectNamespace, recallNotesForKeyword)
import Campaign.Workflow
  ( HumanVerdict (..),
    campaignStreamNameText,
    humanQueryStepName,
  )
import Keiro.Workflow
  ( StepName (..),
    Workflow,
    WorkflowId (..),
    step,
  )
import Keiro.Workflow.Awakeable (AwakeableId, awakeableNamed)
import Keiro.Workflow.Resume (WorkflowDef (..), WorkflowRegistry)
import Keiro.Workflow.Sleep (sleepNamed)
import Keiro.Workflow.Types (WorkflowJournalEvent (..), WorkflowName (..))
import Baikai (Context, Response)
import Kioku.Api.Scope (Namespace)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Effect.Resource (KirokuStoreResource)
import Shikumi.Adapter (ToPrompt)
import Shikumi.Error (ShikumiError)
import Shikumi.Module (predict)
import Shikumi.Program (Program, runProgram)
import Shikumi.Schema (FromModel, ToSchema, Validatable)
import Shikumi.Schema.Types (Field (..), unField)
import Shikumi.Signature (Signature, getInstruction, mkSignature, setInstruction)
import Shikumi.Testing (runStubEval)

-- ---------------------------------------------------------------------------
-- Cells: one (arch × config) entry
-- ---------------------------------------------------------------------------

newtype ArchName = ArchName Text
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON, FromJSON)

newtype ConfigName = ConfigName Text
  deriving stock (Eq, Ord, Show)
  deriving newtype (ToJSON, FromJSON)

-- | One matrix cell: an architecture × configuration entry, plus the
-- synthetic device identity the boot log is generated against.
data MatrixCell = MatrixCell
  { mcArch :: ArchName
  , mcConfig :: ConfigName
  , mcDevice :: Text
  }
  deriving stock (Eq, Ord, Show)

-- | The cell's id, unique per (arch × config): @matrix:<arch>@<config>@.
matrixCellId :: MatrixCell -> CellId
matrixCellId mc = CellId ("matrix:" <> archText mc <> "@" <> configText mc)

archText :: MatrixCell -> Text
archText (MatrixCell (ArchName a) _ _) = a

configText :: MatrixCell -> Text
configText (MatrixCell _ (ConfigName c) _) = c

-- | A cell from its arch and config, with a deterministic device name.
mkMatrixCell :: ArchName -> ConfigName -> MatrixCell
mkMatrixCell a@(ArchName at) c@(ConfigName ct) =
  MatrixCell a c ("virt-" <> at <> "-" <> ct <> "-00")

-- | The full grid: every architecture × configuration combination.
matrixCellSpecs :: [MatrixCell]
matrixCellSpecs =
  [ mkMatrixCell arch config
  | arch <- [ArchName "riscv", ArchName "x86_64", ArchName "arm"]
  , config <- [ConfigName "std", ConfigName "kvm", ConfigName "rt"]
  ]

-- | Which fault a cell carries, if any. The two fault classes are the two
-- futures a real matrix has: a misconfiguration a retry clears, and a
-- property that only reproduces on real hardware.
data FaultKind = FaultRetryable | FaultHardware
  deriving stock (Eq, Ord, Show)

-- | The matrix's own pacing policy: a cool-down between boot/stress
-- attempts (longer than the fixer's settle — a boot cycle is minutes in
-- the real world).
matrixCoolDown :: NominalDiffTime
matrixCoolDown = 0.1

matrixFaultKind :: MatrixCell -> Maybe FaultKind
matrixFaultKind mc = case (archText mc, configText mc) of
  ("riscv", "kvm") -> Just FaultRetryable
  ("arm", "rt") -> Just FaultHardware
  _ -> Nothing

-- ---------------------------------------------------------------------------
-- The triage program: boot/stress log in, typed verdict out
-- ---------------------------------------------------------------------------

data TriageIn = TriageIn
  { tiArch :: Field "Target architecture" Text
  , tiConfig :: Field "Kernel configuration" Text
  , tiBoot :: Field "Boot stage results, one per line" [Text]
  , tiStress :: Field "Stress test summary, one per line" [Text]
  }
  deriving stock (Generic, Show, Eq)
  deriving anyclass (FromModel, ToPrompt)

data TriageOut = TriageOut
  { needsHardware :: Field "True only if the fault requires real hardware" Bool
  , advice :: Field "One-sentence instruction for the operator" Text
  }
  deriving stock (Generic, Show, Eq)
  deriving anyclass (FromModel, ToPrompt, ToSchema, Validatable)

-- | The triage signature: a failing boot or stress log in, a typed verdict
-- out — @needsHardware@ decides the workflow's future, @advice@ is what the
-- retry (or the human) is told.
triageSignature :: Signature TriageIn TriageOut
triageSignature =
  mkSignature
    "You triage a kernel boot and stress log for one architecture/configuration \
    \cell of a verification matrix. Decide whether the fault can be cleared by \
    \retrying with the operator advice applied (needsHardware false), or whether \
    \it only reproduces on real hardware and a human must intervene \
    \(needsHardware true). Give one concrete sentence of advice either way."

-- ---------------------------------------------------------------------------
-- The synthetic world: staged boot and stress, deterministic per cell
-- ---------------------------------------------------------------------------

-- | Boot stage results, journaled as data.
data BootStage = BootStage
  { bsKernel :: Bool
  , bsInit :: Bool
  , bsNet :: Bool
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | Stress results, journaled as data.
data StressResult = StressResult
  { srIterations :: Int
  , srFails :: Int
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | One matrix attempt: the staged world it saw and the verdict the
-- decision layer produced.
data MatrixAttempt = MatrixAttempt
  { maAttempt :: Int
  , maBoot :: BootStage
  , maStress :: StressResult
  , maVerdict :: Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | A per-cell RNG seed, derived once from the cell id. 'unsafePerformIO'
-- with 'newStdGen' would be non-deterministic; instead the seed is the sum
-- of character codes — pure and stable across replays.
cellSeed :: MatrixCell -> Int
cellSeed mc = sum (fromEnum <$> T.unpack (unCellId (matrixCellId mc)))

-- | The boot stage for one attempt of one cell. Attempt 1 of a faulty cell
-- hits its fault (a retryable fault breaks the net stage; a hardware fault
-- boots but corrupts under load); every later attempt boots clean — the
-- retryable fault is cleared by applying the triage advice.
bootStageFor :: MatrixCell -> Int -> BootStage
bootStageFor mc n = case matrixFaultKind mc of
  Just FaultRetryable | n == 1 -> BootStage True True False
  Just FaultHardware | n == 1 -> BootStage True True True
  _ -> BootStage True True True

-- | The stress stage for one attempt. A retryable fault never reaches a
-- full stress run (boot failed); a hardware fault fails early and hard;
-- healthy cells pass a full run whose length varies by cell (the seed).
stressFor :: MatrixCell -> Int -> StressResult
stressFor mc n = case matrixFaultKind mc of
  Just FaultRetryable | n == 1 -> StressResult 0 0
  Just FaultHardware | n == 1 -> StressResult 120 17
  _ -> StressResult (3000 + cellSeed mc `mod` 2000) 0

-- | The boot log lines the triage program reads — the synthetic device's
-- story, stage by stage.
bootLogFor :: MatrixCell -> BootStage -> [Text]
bootLogFor mc bs =
  [ "kernel: " <> archText mc <> " " <> deviceLine <> " booting"
  , "kernel: " <> (if bs.bsKernel then "ok" else "FAILED")
  , "init: applying config " <> configText mc <> " -> " <> (if bs.bsInit then "ok" else "FAILED")
  , "net: link " <> deviceLine <> " -> " <> (if bs.bsNet then "up" else "DOWN (kvm misconfiguration)")
  ]
  where
    deviceLine = "device " <> mc.mcDevice

-- | The stress summary lines the triage program reads.
stressLogFor :: MatrixCell -> StressResult -> [Text]
stressLogFor mc sr =
  [ "stress: " <> T.pack (show sr.srIterations) <> " iterations on " <> mc.mcDevice
  , "stress: " <> (if sr.srFails == 0 then "no failures" else T.pack (show sr.srFails) <> " failures (data corruption under load — hardware-only symptom)")
  ]

bootClean :: BootStage -> Bool
bootClean bs = bs.bsKernel && bs.bsInit && bs.bsNet

stressClean :: StressResult -> Bool
stressClean sr = sr.srFails == 0

-- ---------------------------------------------------------------------------
-- The workflow: boot → stress → triage → retry-or-escalate, all durable
-- ---------------------------------------------------------------------------

-- | The matrix campaign's workflow name (distinct from the fixer's).
matrixWorkflowName :: WorkflowName
matrixWorkflowName = WorkflowName "matrix-campaign"

-- | A matrix cell's workflow id: @matrix-<arch>-<config>@.
campaignMatrixWorkflowId :: MatrixCell -> WorkflowId
campaignMatrixWorkflowId mc = WorkflowId ("matrix-" <> archText mc <> "-" <> configText mc)

-- | A matrix cell's workflow id with a run tag: @matrix-<arch>-<config>-<tag>@
-- — a fresh campaign per driver run (the fleet acts' philosophy: a re-run
-- re-tells, it does not replay a previous run's half-finished story).
matrixWorkflowIdTagged :: MatrixCell -> Text -> WorkflowId
matrixWorkflowIdTagged mc tag =
  WorkflowId ("matrix-" <> archText mc <> "-" <> configText mc <> "-" <> tag)

-- | Parse a matrix workflow id back to its cell. Arch and config are
-- dash-free in this grid; anything after the second field is the run tag.
matrixCellFromWf :: WorkflowId -> Maybe MatrixCell
matrixCellFromWf (WorkflowId t) = do
  rest <- stripPrefix "matrix-" (T.unpack t)
  case T.splitOn "-" (T.pack rest) of
    (arch : config : _) -> Just (mkMatrixCell (ArchName arch) (ConfigName config))
    _ -> Nothing

-- | The matrix engine: one triage attempt, keyed by attempt number. The
-- same shape as the fixer campaign's 'Campaign.Workflow.AttemptEngine' —
-- a stub factory scripts it, a live engine runs the same program through
-- the real model.
type MatrixEngine =
  -- | the attempt number
  Int ->
  -- | the triage program
  Program TriageIn TriageOut ->
  -- | the task, as the decision step saw it
  TriageIn ->
  -- | recalled notes
  [Text] ->
  IO (Maybe TriageOut)

-- | The matrix stub engine: replay a scripted responder through shikumi's
-- stub LM, exactly like the fixer campaign's 'stubEngine'.
matrixStubEngine :: (Int -> Context -> Response) -> MatrixEngine
matrixStubEngine responder n prog input _notes = do
  r <- runStubEval (responder n) (runProgram prog input)
  pure $ case r of
    Right out -> Just out
    Left (_ :: ShikumiError) -> Nothing

-- | The triage signature with the campaign's recalled notes folded into its
-- instruction — the same "memory steers the prompt" move as the fixer's
-- 'guidedFixer'. No output guard: the verdict is a typed record, so a
-- malformed reply is already a 'ShikumiError' under every engine.
guidedTriage :: [Text] -> Program TriageIn TriageOut
guidedTriage notes =
  predict
    ( setInstruction
        ( getInstruction triageSignature
            <> (if null notes then "" else "\n\nOperational notes from earlier in this campaign (obey them):\n" <> T.unlines (map ("- " <>) notes))
        )
        triageSignature
    )

-- | One triage attempt as journaled data: the staged world, then the
-- decision. The triage program's input is the /actual/ boot and stress
-- logs the stages produced — ground truth enters as data, the same way the
-- fixer's diagnostics do.
matrixAttemptRecord ::
  (Workflow :> es, IOE :> es, KirokuStoreResource :> es, Store :> es) =>
  MatrixCell ->
  Namespace ->
  MatrixEngine ->
  Int ->
  Eff es MatrixAttempt
matrixAttemptRecord mc ns engine n = do
  let boot = bootStageFor mc n
      stress = stressFor mc n
      bootLog = bootLogFor mc boot
      stressLog = stressLogFor mc stress
  -- Both stages are journaled as ordinary steps: a replay never re-runs a
  -- "device", it reads what the stages produced — the same property the
  -- real matrix gets from writing boot logs into the journal.
  jBoot <- step (StepName ("boot-" <> T.pack (show n))) (pure boot)
  jStress <-
    if bootClean boot
      then step (StepName ("stress-" <> T.pack (show n))) (pure stress)
      else pure (StressResult 0 0)
  verdict <-
    if bootClean jBoot && stressClean jStress
      then pure "passed"
      else do
        -- Memory, keyed by the task: matrix cells recall boot-flavored notes.
        notes <- recallNotesForKeyword ns "boot"
        let input =
              TriageIn
                (Field (archText mc))
                (Field (configText mc))
                (Field (bootLogFor mc jBoot <> stressLogFor mc jStress))
                (Field (stressLogFor mc jStress))
        mTriage <- liftIO (engine n (guidedTriage notes) input notes)
        pure $ case mTriage of
          Just t
            | not (unField (t.needsHardware)) -> "retry: " <> unField (t.advice)
            | otherwise -> "escalate: " <> unField (t.advice)
          Nothing -> "retry: triage unavailable, retrying"
  pure (MatrixAttempt n jBoot jStress verdict)

-- | The matrix cell workflow: verify-initial, then boot-stress attempts
-- paced by cool-down timers. A retryable verdict loops; a hardware verdict
-- parks on the human seam immediately (there is no point burning the
-- budget on a fault no retry can clear); budget exhaustion parks too.
matrixCellWorkflow ::
  (Workflow :> es, KirokuStoreResource :> es, Store :> es, IOE :> es) =>
  MatrixEngine ->
  -- | publish the human-query awakeable id (the operator's queue)
  (AwakeableId -> Eff es ()) ->
  MatrixCell ->
  Namespace ->
  Int ->
  Eff es Text
matrixCellWorkflow engine publishHumanQuery mc ns maxAttempts = do
  _initial <- step (StepName "verify-initial") (pure (bootStageFor mc 1, stressFor mc 1))
  go 1
  where
    go n
      | n > maxAttempts = budgetExhausted
      | otherwise = do
          attempt <-
            step (StepName ("boot-stress-" <> T.pack (show n))) (matrixAttemptRecord mc ns engine n)
          sleepNamed (StepName ("cool-down-" <> T.pack (show n))) matrixCoolDown
          case T.stripPrefix "passed" attempt.maVerdict of
            Just _ -> pure ("passed: boot + stress clean on attempt " <> T.pack (show n))
            Nothing
              | "escalate:" `T.isPrefixOf` attempt.maVerdict -> hardwarePark attempt.maVerdict
              | otherwise -> go (n + 1)

    -- A fault the triage says only reproduces on hardware: journal the
    -- reason, then park on the same human seam the fixer campaign uses.
    hardwarePark reason = do
      _ <- step (StepName "escalate-reason") (pure reason)
      (awakeableId, awaitVerdict) <- awakeableNamed humanQueryStepName
      _publication <- step (StepName "publish-human-query") (publishHumanQuery awakeableId)
      verdict <- awaitVerdict
      case verdict of
        VerdictApproved -> pure ("human-approved: " <> reason <> "; verdict recorded")
        VerdictRejected -> pure ("human-rejected: " <> reason <> "; verdict recorded")

    budgetExhausted = do
      (awakeableId, awaitVerdict) <- awakeableNamed humanQueryStepName
      _publication <- step (StepName "publish-human-query") (publishHumanQuery awakeableId)
      verdict <- awaitVerdict
      case verdict of
        VerdictApproved -> pure "human-approved: matrix cell still failing; verdict recorded"
        VerdictRejected -> pure "human-rejected: matrix cell still failing; verdict recorded"

-- | The matrix registry: one workflow name, every cell rebuilt from its id.
matrixRegistry ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es) =>
  MatrixEngine ->
  (AwakeableId -> Eff es ()) ->
  WorkflowRegistry es
matrixRegistry engine publishHumanQuery =
  Map.fromList
    [ ( matrixWorkflowName,
        WorkflowDef $ \wid ->
          case matrixCellFromWf wid of
            Nothing -> error ("matrixRegistry: malformed matrix workflow id " <> T.unpack (unWorkflowId wid))
            Just mc ->
              matrixCellWorkflow
                engine
                (raise . publishHumanQuery)
                mc
                (projectNamespace "matrix")
                defaultMatrixMaxAttempts
      )
    ]

defaultMatrixMaxAttempts :: Int
defaultMatrixMaxAttempts = 3

-- | All journaled matrix attempts (from @boot-stress-N@ steps).
matrixAttemptsOf :: [WorkflowJournalEvent] -> [MatrixAttempt]
matrixAttemptsOf = mapMaybe extract
  where
    extract = \case
      StepRecorded name result _
        | "boot-stress-" `T.isPrefixOf` name ->
            case Aeson.fromJSON result of
              Aeson.Success ma -> Just ma
              Aeson.Error _ -> Nothing
      _ -> Nothing
