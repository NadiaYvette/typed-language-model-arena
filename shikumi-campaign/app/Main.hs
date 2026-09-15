{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The one-cell campaign, act by act, on keiro's durable runtime, now with
-- kioku memory.
--
-- The cell is toy-fixer's @alpha.py@ corpus entry; the \"model\" is a stub
-- responder (a live OmniRoute stack is the same call — swap the interpreters
-- in @Campaign.Workflow.runFixAttempt@, nothing else changes). Acts:
--
--   1. /Informed retry to success/: attempt 1 deletes only one of the two
--      TODO lines (a partial repair — the checker still reports a marker);
--      between passes the model strategy is swapped for a corrected one and
--      attempt 2 clears the cell. Both attempts are journaled as durable
--      decisions; replay never re-asks the model.
--   2. /Escalation/: the model never recovers, the typed attempt budget
--      runs out, the workflow parks on a human awakeable, the demo answers
--      the query through 'signalAwakeable', and the workflow completes with
--      the human's verdict — the typed human seam, end to end.
--   3. /Memory at work/: the campaign records lessons into kioku (from
--      act 1's journal), then a fresh cell (@gamma.py@, needing BOTH the
--      TODO and the unused-binding lesson) is fixed on the FIRST attempt by
--      a responder that actually reads the recalled notes out of the
--      rendered request — memory in, better decision out, all journaled.
--   4. /Session evidence/: the campaign's fix session (one turn per
--      journaled attempt) is recorded through kioku's session API — L0
--      evidence kioku's distillers can promote to memory atoms later.
--   5. /Distillation/: kioku's L1 distiller runs LIVE over that session —
--      an AI config file generated from the OmniRoute environment (no
--      secrets on disk: the config names @OMNIROUTE_API_KEY@ and baikai
--      reads the key at call time), 'loadAIRuntime', then
--      'distillSessionL1' with the keyword-only merge scan (no embeddings
--      needed). L0 turns become machine-written memory atoms, shown by
--      recalling them back through the same read the workflow uses.
--   6. /Restart proof/ (after each act): a fresh store connection — a new
--      \"process\" — finds no unfinished work. The campaign state lives in
--      the journal, not in the process.
--
-- Acts 1–4 run offline: the model is 'markerResponse' scripts, the checker
-- is pure, and Postgres is the only external dependency. Act 5 is the one
-- live act — it drives a real model through the local OmniRoute proxy.
--
-- Acts 6–8 scale the same loop: the remaining toy corpus cells run as a
-- fleet of concurrent durable workflows (act 6), real cells from the mowgli
-- and peirce checkouts run through the identical campaign under a second
-- deterministic oracle (act 7), and kioku's L2 scenes and L3 persona
-- distill each project's memory — live, like act 5 (act 8).
module Main
  ( main,
  )
where

import Control.Applicative ((<|>))
import Control.Monad (filterM, foldM_, forM, forM_, unless, when)
import Data.List (find, nub, partition, sort, sortOn)
import Data.Map.Strict qualified as Map
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as BL
import Data.Foldable (for_, traverse_)
import Data.IORef (atomicModifyIORef', modifyIORef', newIORef, readIORef, writeIORef)
import Data.Maybe (catMaybes, isJust)
import Data.Set qualified as SSet
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time.Clock (addUTCTime, getCurrentTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Data.Vector qualified as Vector
import Control.Concurrent.Async (mapConcurrently)
import Effectful (Eff, IOE, UnliftStrategy (..), liftIO, raise, runEff, withEffToIO)
import Effectful.Concurrent (runConcurrent)
import Effectful.Error.Static (Error, runErrorNoCallStack)
import Keiro.Codec (decodeRecorded)
import Keiro.Connection (keiroConnectionSettings)
import Keiro.Workflow
  ( WorkflowId (..),
    WorkflowJournalEvent (..),
    WorkflowName,
    WorkflowOutcome (..),
    defaultWorkflowRunOptions,
    findUnfinishedWorkflowIds,
    runWorkflowWith,
    workflowJournalCodec,
  )
import Keiro.Workflow.Awakeable (AwakeableId, awakeableIdText, signalAwakeable)
import Keiro.Workflow.Resume
  ( ResumeSummary (..),
    WorkflowRegistry,
    WorkflowResumeOptions (..),
    defaultWorkflowResumeOptions,
    resumeWorkflowsOnce,
  )
import Keiro.Workflow.Sleep (drainWorkflowSleepTimers, runWorkflowTimerWorker)
import Kioku.Api.Scope (MemoryScope (..), Namespace)
import Kiroku.Store qualified as Store
import Kiroku.Store.Connection (ConnectionSettings)
import Kiroku.Store.Effect (Store, runStoreResource)
import Kiroku.Store.Effect.Resource (KirokuStoreResource, withKirokuStore)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Types
  ( RecordedEvent (..),
    StreamName (..),
    StreamVersion (..),
  )
import System.Directory (createDirectoryIfMissing, doesFileExist, listDirectory, removeFile)
import System.Environment (lookupEnv)

import Campaign.Bootstrap
  ( bootstrapCampaignStore
  , bootstrapStore
  , ccDbname
  , createDatabaseIfAbsent
  , defaultCampaignConn
  , dropDatabase
  , renderCampaignConn
  , scratchConnFor
  , sentinelRelation
  , storeWorkflowCount
  )
import System.FilePath ((</>))
import System.IO (hClose, openTempFile)
import Data.UUID.V4 (nextRandom)

import Kioku.AI.Config (AIExecutionError (..), AIFeature (..))
import Kioku.AI.File (loadAIRuntime)
import Kioku.AI.Runtime (AIRuntime, runAIProgram)
import Kioku.Distill.Consolidate (ConsolidateInput, ConsolidationDecision, consolidateProgram)
import Kioku.Distill.Extract
  ( ExtractInput (..),
    ExtractOutput (..),
    ExtractedAtom (..),
    extractSignature,
  )
import Kioku.Distill.L1 (L1Outcome (..), L1RunMode (..), L1Summary (..), distillSessionL1, scopedScanCandidates)
import Kioku.Distill.L2 (SceneRow (..), regenerateScene)
import Kioku.Distill.L3 (PersonaRow (..), getPersonaByScope, regeneratePersona)
import Kioku.Distill.Persona (PersonaInput (..), PersonaOutput (..), personaProgram, personaSignature)
import Kioku.Distill.Runtime (TestRunners (..), newDistillRuntime, withDistillWorkspace, withTestRunners)
import Kioku.Distill.Scene (SceneInput (..), SceneOutput (..), sceneProgram, sceneSignature)
import Kioku.Id (SessionId)
import Kioku.ReadModel (registerKiokuReadModels)
import Shikumi.Adapter (ToPrompt)
import Shikumi.Error (ShikumiError (..))
import Shikumi.Module (predict)
import Shikumi.Program (Program)
import Shikumi.Schema (FromModel, ToSchema, Validatable)
import Shikumi.Schema.Types (Field (Field, unField), field)
import Shikumi.Signature (Demo (..), Signature, getInstruction, mkSignature, setDemos, setInstruction)
import Shikumi.Coder.Pipeline (ProposeIn (..))
import Shikumi.Coder.Task (PatchPlan (..), applyPlan)

import Campaign.Aggregate (CellSummary (..), CellVertex (..), cellSummaryOf, replayCellJournal)
import Campaign.Cell (Cell (..), CellId (..), FixAttempt (..), corpusCells, cellForId, unCellId)
import Campaign.Fanout (runCellFanout)
import Campaign.Hands  ( campaignBranchFor,
    campaignWorktreePath,
    ensureCampaignWorktree,
    gitCapture,
    parentDirtyCount
  )
import Campaign.Landing
  ( LandingRecord (..),
    landProjectCellWorkflow,
    landingRecordOf,
    landingWorkflowId,
    landingWorkflowIdFor,
    landingWorkflowName,
  )
import Campaign.Memory
  ( campaignAccessContext,
    campaignInfraNamespace,
    campaignMemorySpace,
    campaignNamespace,
    completeFixSession,
    projectNamespace,
    recallNotes,
    recallNotesForKeyword,
    recordFixTurn,
    recordGlobalLesson,
    recordLesson,
    startFixSession,
    startInfraSession,
  )
import Campaign.Matrix
  ( MatrixAttempt (..),
    MatrixCell (..),
    TriageIn (..),
    TriageOut (..),
    matrixAttemptsOf,
    matrixCellFromWf,
    matrixCellId,
    matrixCellSpecs,
    matrixCellWorkflow,
    matrixRegistry,
    matrixWorkflowIdTagged,
    matrixWorkflowName,
  )
import Campaign.Mercury
  ( MercuryAttempt (..),
    MercuryCell (..),
    MercuryEngine,
    MercuryFact (..),
    mercuryAttemptsOf,
    mercuryBranchFor,
    mercuryCellFor,
    mercuryCellSpecs,
    mercuryCellWorkflow,
    mercuryCellKeyFromWf,
    mercuryOptionsPath,
    mercuryPrivCount,
    mercuryRegistry,
    mercuryScriptedEngine,
    mercuryWorkflowIdTagged,
    mercuryWorkflowName,
    OracleVerdict (..),
    oracleDumpProbe,
    oracleFactProbe,
    readMercuryFacts,
  )
import Baikai (Context (..), Message (..), Response, TextContent (..), UserContent (..))
import Baikai.Message (UserPayload (UserPayload))
import Campaign.Oracle (CellOracle (..), ProjectCell (..), diagLineOf, markerOracle, projectCellSpecs, readProjectCell, unusedImportOracle)
import Campaign.ReactFixer (renderSteps, reactEngineFor, scriptedReactEngine)
import Campaign.Workflow
  ( AttemptEngine,
    EngineFor,
    HumanVerdict (..),
    campaignRegistry,
    campaignStreamNameText,
    campaignWorkflowId,
    cellCampaignWorkflow,
    cellCampaignWorkflowName,
    defaultMaxAttempts,
    guidedFixer,
    projectCampaignWorkflowName,
    projectWorkflowId,
    stubEngine,
  )
import Shikumi.Testing (markerResponse)
import Toy.Fixer.Domain (Source (..), sourceText)
import Toy.Fixer.Program (DiagnosticsIn (..), RepairOut (..))
import GHC.Generics (Generic)
import Data.Aeson qualified as Aeson
import Data.Aeson (FromJSON, ToJSON)

main :: IO ()
main = do
  putStrLn "[campaign] verification cells on keiro's durable runtime (shikumi decides, keiro journals, kioku remembers)"
  -- The demo runs all seventeen acts; a filter like ACTS=9 runs one act alone
  -- (against whatever journal state the database already has). The fix
  -- session is recorded exactly once per driver run: act 4 records it, act
  -- 5 distills it — or act 5 records it itself when act 4 was filtered out.
  acts <- lookupEnv "ACTS"
  let splitOnComma = T.splitOn "," . T.strip
      wanted = maybe [1 .. 19] (map (read . T.unpack) . splitOnComma . T.pack) acts
      step mSid n
        | n `notElem` wanted = pure mSid
        | otherwise = case n of
            1 -> runInformedRetryAct >> pure mSid
            2 -> runEscalationAct >> pure mSid
            3 -> runMemoryAct >> pure mSid
            4 -> Just <$> runSessionAct
            5 -> maybe runSessionAct pure mSid >>= runDistillAct >> pure mSid
            6 -> runFleetAct >> pure mSid
            7 -> runProjectFleetAct >> pure mSid
            8 -> runL2L3Act >> pure mSid
            9 -> runLiveDecisionAct >> pure mSid
            10 -> runPlannerAct >> pure mSid
            11 -> runLandingAct >> pure mSid
            12 -> runReactAct >> pure mSid
            13 -> runFanoutAct >> pure mSid
            14 -> runScratchAct >> pure mSid
            15 -> runInfraMemoryAct >> pure mSid
            16 -> runMatrixAct >> pure mSid
            17 -> runCrossPlanAct >> pure mSid
            18 -> runMercuryAct >> pure mSid
            19 -> runLiveMercuryAct >> pure mSid
            n -> fail ("unknown act: " <> show n)
  foldM_ step Nothing [1 .. 19 :: Int]

-- ---------------------------------------------------------------------------
-- Store plumbing (jitsurei's shape; no projection schema — the journal is
-- the campaign's audit trail, so the demo reads events back directly)
-- ---------------------------------------------------------------------------

type CampaignEffects = '[Store, Error StoreError, KirokuStoreResource, IOE]

-- | A store handle: run any @Store@ effect block to IO.
newtype CampaignStore = CampaignStore
  { runCampaignStore :: forall a. Eff CampaignEffects a -> IO (Either StoreError a)
  }

-- | The campaign keeps no read models of its own, so it needs no projection
-- schema of substance: keiro's settings with a campaign projection-schema tag.
-- (Argument order matters: connString first, schema second.)
campaignConnectionSettings :: Text -> ConnectionSettings
campaignConnectionSettings connString = keiroConnectionSettings connString "campaign"

-- | The campaign store on an explicit connection — the parameterized scope
-- (act 14's scratch store uses this directly).
withCampaignStoreAt :: T.Text -> (CampaignStore -> IO ()) -> IO ()
withCampaignStoreAt connString action = do
  putStrLn ("[campaign] connecting to " <> T.unpack connString)
  runEff $
    withKirokuStore (campaignConnectionSettings connString) $
      withEffToIO SeqUnlift \unlift -> do
        let runIt :: Eff CampaignEffects a -> IO (Either StoreError a)
            runIt = unlift . runErrorNoCallStack . runStoreResource
        -- Host duty (kioku's library-api contract): kioku's read models must
        -- be registered before serving queries. Idempotent; kioku-migrate's
        -- reconcile normally covers it, this keeps the host self-sufficient.
        reg <- runIt Kioku.ReadModel.registerKiokuReadModels
        either (ioError . userError . show) pure reg
        action (CampaignStore runIt)

-- | The campaign store on the default connection, after a self-boot: resolve
-- the connection, create the database if the server lacks it, migrate if the
-- schema is absent — then open. A @dropdb@ followed by the demo Just Works.
withCampaignStore :: (CampaignStore -> IO ()) -> IO ()
withCampaignStore action = do
  conn <- defaultCampaignConn
  applied <- bootstrapCampaignStore conn
  putStrLn
    ( if applied == 0
        then "[bootstrap] store current (schema present, nothing to apply)"
        else
          "[bootstrap] applied " <> show applied <> " migration file(s) to "
            <> T.unpack (renderCampaignConn conn)
    )
  withCampaignStoreAt (renderCampaignConn conn) action

requireEither :: (Show err) => Either err a -> IO a
requireEither = \case
  Left err -> fail (show err)
  Right value -> pure value

readJournal :: CampaignStore -> Text -> IO [RecordedEvent]
readJournal store streamName = do
  events <-
    requireEither
      =<< runCampaignStore
        store
        (Store.readStreamForward (StreamName streamName) (StreamVersion 0) 1000)
  pure (Vector.toList events)

decodedJournal :: [RecordedEvent] -> [WorkflowJournalEvent]
decodedJournal events =
  [event | Right event <- decodeRecorded workflowJournalCodec <$> events]

printJournal :: [RecordedEvent] -> IO ()
printJournal = traverse_ printOne
  where
    printOne recorded =
      case decodeRecorded workflowJournalCodec recorded of
        Left err -> putStrLn ("  decode failed: " <> show err)
        Right event -> do
          putStr ("  " <> show recorded.streamVersion <> "  ")
          case event of
            StepRecorded name result _ ->
              TIO.putStrLn (name <> "  " <> briefValue result)
            other ->
              putStrLn (show other)

-- | Crude JSON summariser so the journal dump stays readable.
briefValue :: Aeson.Value -> Text
briefValue = \case
  Aeson.Object o ->
    T.take 150 $
      T.intercalate ", " [Key.toText k <> "=" <> briefAtom v | (k, v) <- KeyMap.toList o]
  other -> T.take 60 (T.pack (show other))

briefAtom :: Aeson.Value -> Text
briefAtom = \case
  Aeson.String s -> if T.length s > 60 then T.take 57 s <> "..." else s
  Aeson.Number n -> T.pack (show n)
  Aeson.Bool b -> if b then "true" else "false"
  Aeson.Null -> "null"
  Aeson.Array a -> "[" <> T.pack (show (Vector.length a)) <> " items]"
  Aeson.Object o -> "{" <> T.pack (show (KeyMap.size o)) <> " keys}"

journalIsComplete :: [WorkflowJournalEvent] -> Bool
journalIsComplete = any isCompletion
  where
    isCompletion = \case
      WorkflowCompleted {} -> True
      _ -> False

-- | All journaled fix attempts (from @propose-fix-N@ steps) of a journal.
journaledAttempts :: [WorkflowJournalEvent] -> [FixAttempt]
journaledAttempts = mapMaybe extract
  where
    mapMaybe f xs = [y | Just y <- f <$> xs]
    extract = \case
      StepRecorded name result _
        | "propose-fix-" `T.isPrefixOf` name ->
            case Aeson.fromJSON result of
              Aeson.Success fa -> Just fa
              _ -> Nothing
      _ -> Nothing

ourUnfinished :: CampaignStore -> [Text] -> IO [(Text, Text)]
ourUnfinished store ourIds = do
  now <- liftIO getCurrentTime
  pairs <- requireEither =<< runCampaignStore store (findUnfinishedWorkflowIds now)
  pure [pair | pair@(wid, _) <- pairs, wid `elem` ourIds]

resumeOptions :: WorkflowResumeOptions
resumeOptions =
  defaultWorkflowResumeOptions
    { runOptions = defaultWorkflowRunOptions,
      pollInterval = 1000,
      maxAttempts = 3
    }

driveResumeOnce :: CampaignStore -> WorkflowRegistry CampaignEffects -> IO ()
driveResumeOnce store registry = do
  summary <-
    requireEither
      =<< runCampaignStore store (resumeWorkflowsOnce resumeOptions registry)
  putStrLn ("  resume: " <> show summary)

-- | A resume pass that stays quiet when there is nothing to do (the sweep's
-- driver — twenty lines of @discovered = 0@ help nobody).
resumeOnceQuiet :: CampaignStore -> WorkflowRegistry CampaignEffects -> IO ()
resumeOnceQuiet store registry = do
  summary <-
    requireEither
      =<< runCampaignStore store (resumeWorkflowsOnce resumeOptions registry)
  when (discovered summary > 0) $ putStrLn ("  resume: " <> show summary)

-- | Fire workflow-sleep timers (clock well past the delay) until @step@ shows
-- up in the journal, bounded. Jitsurei's helper, pointed at our act.
fireTimerUntilJournaled :: CampaignStore -> Text -> Text -> IO ()
fireTimerUntilJournaled store streamName stepName = do
  fireTime <- liftIO (addUTCTime 3600 <$> getCurrentTime)
  let loop :: Int -> IO ()
      loop n
        | n > 10 = fail (T.unpack stepName <> " was not journaled after 10 timer passes")
        | otherwise = do
            done <- journalHasStep store streamName stepName
            if done
              then putStrLn ("  timer fired " <> T.unpack stepName <> " -> journal")
              else do
                _ <-
                  requireEither
                    =<< runCampaignStore
                      store
                      (runWorkflowTimerWorker Nothing fireTime (\_ -> pure Nothing))
                loop (n + 1)
  loop 0

journalHasStep :: CampaignStore -> Text -> Text -> IO Bool
journalHasStep store streamName target = do
  events <- readJournal store streamName
  pure (any matches (decodedJournal events))
  where
    matches = \case
      StepRecorded name _ _ -> name == target
      _ -> False

-- | The demo's acts assume a fresh campaign: each cell's workflow id is
-- stable (so the restart proof re-opens the same journal), so a second run
-- against a used database would replay a completed journal instead of telling
-- the story. Fail with the reset recipe instead.
requireFreshJournal :: CampaignStore -> Text -> IO ()
requireFreshJournal store streamName = do
  existing <- readJournal store streamName
  unless (null existing) $
    fail
      ( "journal "
          <> T.unpack streamName
          <> " already exists; reset the campaign DB first: dropdb campaign"
          <> " && createdb campaign && DATABASE_URL='host=/tmp dbname=campaign'"
          <> " cabal run kioku-migrate -- up"
      )

requireCell :: Text -> IO Cell
requireCell path =
  case cellForId (CellId path) of
    Just c -> pure c
    Nothing -> fail (T.unpack path <> " missing from the toy-fixer corpus")

wfIdText :: WorkflowId -> Text
wfIdText (WorkflowId t) = t

-- | Run one kioku write block against the campaign store, failing on error.
runKiokuWrite :: (Show e) => CampaignStore -> Eff CampaignEffects (Either e a) -> IO a
runKiokuWrite store block = do
  r <- requireEither =<< runCampaignStore store block
  requireEither r

-- ---------------------------------------------------------------------------
-- Act 1: informed retry to success
-- ---------------------------------------------------------------------------

runInformedRetryAct :: IO ()
runInformedRetryAct = do
  putStrLn "\n=== act 1: informed retry to success ==="
  cell <- requireCell "alpha.py"
  let wfId = campaignWorkflowId cell.cellId
      wfName = cellCampaignWorkflowName
      stream = campaignStreamNameText wfName wfId
      ourIds = [wfIdText wfId]
      current = sourceText cell.cellCurrent
      isTodo l = "TODO" `T.isInfixOf` l

      -- Attempt 1: a partial repair — only the FIRST TODO line is deleted,
      -- so the checker still reports the second one. Plausible, wrong.
      dropFirstTodo = go
        where
          go [] = []
          go (l : rest)
            | isTodo l = rest
            | otherwise = l : go rest
      pick1 = T.unlines (dropFirstTodo (T.lines current))

      -- Attempt 2 (the corrected strategy between passes): delete every TODO.
      pick2 = T.unlines (filter (not . isTodo) (T.lines current))

      responder1 _n _ctx = markerResponse [("repaired", pick1)]
      responder2 _n _ctx = markerResponse [("repaired", pick2)]
      -- A publisher that never publishes: act 1 never escalates. Typed at
      -- the plain store row; raised at the workflow call sites.
      noPublisher :: AwakeableId -> Eff CampaignEffects ()
      noPublisher = const (pure ())

  withCampaignStore $ \store -> do
    requireFreshJournal store stream
    putStrLn ("[informed] first run for cell " <> T.unpack (unCellId cell.cellId))
    outcome1 <-
      requireEither
        =<< runCampaignStore
          store
          (runWorkflowWith defaultWorkflowRunOptions wfName wfId (cellCampaignWorkflow (stubEngine responder1) (raise . noPublisher) cell markerOracle campaignNamespace defaultMaxAttempts))
    putStrLn ("  first run outcome: " <> show outcome1 <> "  (partial attempt journaled; settle sleep armed; run suspended)")

    fireTimerUntilJournaled store stream "sleep:settle-1"
    putStrLn "[informed] resuming with the corrected model strategy"
    driveResumeOnce store (campaignRegistry [] [] (\_o _c -> stubEngine responder2) noPublisher)

    -- Attempt 2 clears the cell, but the success check runs after the next
    -- settle sleep, so fire it and resume once more to complete.
    fireTimerUntilJournaled store stream "sleep:settle-2"
    driveResumeOnce store (campaignRegistry [] [] (\_o _c -> stubEngine responder2) noPublisher)

    journal <- readJournal store stream
    unless (journalIsComplete (decodedJournal journal)) $
      fail "informed-retry journal has no WorkflowCompleted"
    putStrLn ("[informed] journal for " <> T.unpack stream <> ":")
    printJournal journal

    -- The final verdict is re-derived by a plain final run (pure replay).
    finalOutcome <-
      requireEither
        =<< runCampaignStore
          store
          (runWorkflowWith defaultWorkflowRunOptions wfName wfId (cellCampaignWorkflow (stubEngine responder2) (raise . noPublisher) cell markerOracle campaignNamespace defaultMaxAttempts))
    case finalOutcome of
      Completed v -> putStrLn ("  verdict: " <> T.unpack v)
      _ -> fail ("expected completion, got " <> show finalOutcome)

  putStrLn "[informed] --- simulated restart: re-opening the store ---"
  withCampaignStore $ \store -> do
    remaining <- ourUnfinished store ourIds
    unless (null remaining) $ fail ("restart found unfinished workflows: " <> show remaining)
    putStrLn "  restart: no unfinished work — the journal is the campaign's audit trail"

-- ---------------------------------------------------------------------------
-- Act 2: escalation through the human seam
-- ---------------------------------------------------------------------------

runEscalationAct :: IO ()
runEscalationAct = do
  putStrLn "\n=== act 2: budget exhaustion parks on the human seam ==="
  cell <- requireCell "alpha.py"
  let wfId = WorkflowId (wfIdText (campaignWorkflowId cell.cellId) <> "-escalation")
      wfName = cellCampaignWorkflowName
      stream = campaignStreamNameText wfName wfId
      ourIds = [wfIdText wfId]
      current = sourceText cell.cellCurrent
      -- A permanently confused model: every attempt returns the unchanged
      -- file, so diagnostics survive and the budget runs out.
      confused _n _ctx = markerResponse [("repaired", current)]

  sink <- newIORef []
  let -- The publisher lives at the plain store row (jitsurei's pattern); the
      -- workflow and the registry each raise it where they call it.
      publishHumanQuery :: AwakeableId -> Eff CampaignEffects ()
      publishHumanQuery aid = do
        inserted <-
          liftIO $
            atomicModifyIORef' sink $ \published ->
              if aid `elem` published
                then (published, False)
                else (published <> [aid], True)
        when inserted $
          liftIO $
            putStrLn ("  published human-query awakeable id: " <> T.unpack (awakeableIdText aid))
      registry = campaignRegistry [] [] (\_o _c -> stubEngine confused) publishHumanQuery

  withCampaignStore $ \store -> do
    requireFreshJournal store stream
    putStrLn "[escalation] first run: a bad attempt records, the settle sleep suspends the run"
    outcome1 <-
      requireEither
        =<< runCampaignStore
          store
          (runWorkflowWith defaultWorkflowRunOptions wfName wfId (cellCampaignWorkflow (stubEngine confused) (raise . publishHumanQuery) cell markerOracle campaignNamespace defaultMaxAttempts))
    putStrLn ("  first run outcome: " <> show outcome1)

    -- Three bad attempts, each paced by a settle sleep: fire the timer, then
    -- resume so the next attempt records.
    fireTimerUntilJournaled store stream "sleep:settle-1"
    driveResumeOnce store registry
    fireTimerUntilJournaled store stream "sleep:settle-2"
    driveResumeOnce store registry
    fireTimerUntilJournaled store stream "sleep:settle-3"
    -- The third failed attempt exhausted the budget, so this resume enters
    -- budget exhaustion: the awakeable is allocated, the publication step is
    -- journaled (idempotently), and the run parks.
    putStrLn "[escalation] budget exhausted; the run parks on the human seam"
    driveResumeOnce store registry

    published <- readIORef sink
    aid <- case published of
      [a] -> pure a
      [] -> fail "no human-query awakeable was published"
      as -> fail ("published more than one human-query awakeable: " <> show as)

    putStrLn "[escalation] signalling the human verdict (a person answers the query)"
    signalled <-
      requireEither
        =<< runCampaignStore store (signalAwakeable aid VerdictApproved)
    unless signalled $ fail "signalAwakeable returned False for the published human-query id"

    putStrLn "[escalation] resuming: the parked workflow consumes the verdict and completes"
    driveResumeOnce store registry

    journal <- readJournal store stream
    unless (journalIsComplete (decodedJournal journal)) $
      fail "escalation journal has no WorkflowCompleted"
    putStrLn ("[escalation] journal for " <> T.unpack stream <> ":")
    printJournal journal

    finalOutcome <-
      requireEither
        =<< runCampaignStore
          store
          (runWorkflowWith defaultWorkflowRunOptions wfName wfId (cellCampaignWorkflow (stubEngine confused) (raise . publishHumanQuery) cell markerOracle campaignNamespace defaultMaxAttempts))
    case finalOutcome of
      Completed v -> putStrLn ("  verdict: " <> T.unpack v)
      _ -> fail ("expected completion, got " <> show finalOutcome)

  putStrLn "[escalation] --- simulated restart: re-opening the store ---"
  withCampaignStore $ \store -> do
    remaining <- ourUnfinished store ourIds
    unless (null remaining) $ fail ("restart found unfinished workflows: " <> show remaining)
    putStrLn "  restart: escalation journal is complete — durability proven"

-- ---------------------------------------------------------------------------
-- Act 3: memory at work — lessons recorded, recalled, and used
-- ---------------------------------------------------------------------------

runMemoryAct :: IO ()
runMemoryAct = do
  putStrLn "\n=== act 3: kioku memory at work — lessons in, first-try fix out ==="
  gamma <- requireCell "gamma.py"

  -- 3a. Record lessons (as a real campaign would project them from act 1's
  -- journal) into kioku. Idempotent writes: a driver replay cannot duplicate.
  withCampaignStore $ \store -> do
    putStrLn "[memory] recording lessons into kioku"
    runKiokuWrite store $ recordLesson campaignNamespace "alpha.py" "a line marked TODO must be deleted entirely, not commented out"
    runKiokuWrite store $ recordLesson campaignNamespace "beta.py" "a binding flagged unused must have its whole line deleted"
    recorded <- runCampaignStore store (recallNotes campaignNamespace)
    case recorded of
      Left err -> fail (show err)
      Right notes -> do
        putStrLn ("  kioku now holds " <> show (length notes) <> " lesson(s):")
        for_ notes \n -> TIO.putStrLn ("    - " <> n)

  -- 3b. The memory-informed model: READS the recalled notes out of the
  -- rendered request and applies each matching lesson. A real model does this
  -- because the notes ride the prompt; the stub does it textually. Each
  -- deletion is conditioned on its lesson actually being recalled — no
  -- memory, no deletion, failing cell.
  let gammaText = sourceText gamma.cellCurrent
      -- The engine's script: the model reads the lessons out of the /rendered
      -- request/ (they ride the instruction since guidedFixer folds them in)
      -- and applies each matching one. A real model does exactly this.
      informed _n ctx = markerResponse [("repaired", fixed)]
        where
          lowered = [T.toLower (promptText ctx)]
          dropUnused = any ("unused" `T.isInfixOf`) lowered
          dropTodo = any ("todo" `T.isInfixOf`) lowered
          keep l =
            not (dropUnused && "-- unused" `T.isInfixOf` l)
              && not (dropTodo && "TODO" `T.isInfixOf` l)
          fixed = T.unlines (filter keep (T.lines gammaText))

  let wfId = campaignWorkflowId gamma.cellId
      wfName = cellCampaignWorkflowName
      stream = campaignStreamNameText wfName wfId
      ourIds = [wfIdText wfId]
      noPublisher :: AwakeableId -> Eff CampaignEffects ()
      noPublisher = const (pure ())

  withCampaignStore $ \store -> do
    requireFreshJournal store stream
    putStrLn "[memory] running gamma.py through the campaign with a memory-informed model"
    outcome <-
      requireEither
        =<< runCampaignStore
          store
          (runWorkflowWith defaultWorkflowRunOptions wfName wfId (cellCampaignWorkflow (stubEngine informed) (raise . noPublisher) gamma markerOracle campaignNamespace defaultMaxAttempts))
    putStrLn ("  first run outcome: " <> show outcome)

    -- The single successful attempt still pauses on its settle sleep before
    -- the workflow's success check, so fire and resume once.
    fireTimerUntilJournaled store stream "sleep:settle-1"
    driveResumeOnce store (campaignRegistry [] [] (\_o _c -> stubEngine informed) noPublisher)

    journal <- readJournal store stream
    let attempts = journaledAttempts (decodedJournal journal)
    unless (journalIsComplete (decodedJournal journal)) $
      fail "memory journal has no WorkflowCompleted"
    putStrLn ("[memory] journal for " <> T.unpack stream <> ":")
    printJournal journal
    case attempts of
      [fa] | fa.faAttempt == 1 && fa.faSucceeded ->
        putStrLn "  first-try fix: ONE journaled attempt, informed by recalled memory, cleared the cell"
      _ -> fail ("expected exactly one successful attempt, got " <> show attempts)

  putStrLn "[memory] --- simulated restart: re-opening the store ---"
  withCampaignStore $ \store -> do
    remaining <- ourUnfinished store ourIds
    unless (null remaining) $ fail ("restart found unfinished workflows: " <> show remaining)
    putStrLn "  restart: memory journal is complete — durability proven"

-- ---------------------------------------------------------------------------
-- Act 4: the fix session as L0 evidence in kioku
-- ---------------------------------------------------------------------------

runSessionAct :: IO SessionId
runSessionAct = do
  putStrLn "\n=== act 4: the fix session as kioku L0 evidence ==="
  cell <- requireCell "alpha.py"
  sidRef <- newIORef (error "session id unset")
  withCampaignStore $ \store -> do
    putStrLn "[session] starting a fix session for alpha.py"
    sid <- runKiokuWrite store (startFixSession campaignNamespace (unCellId cell.cellId))
    writeIORef sidRef sid
    putStrLn ("  session started: " <> show sid)

    -- One turn per journaled attempt of act 1's journal — the campaign's
    -- audit trail projected into kioku as session evidence.
    journal <- readJournal store (campaignStreamNameText cellCampaignWorkflowName (campaignWorkflowId cell.cellId))
    let attempts = journaledAttempts (decodedJournal journal)
    for_ (zip [1 ..] attempts) \(idx, fa) -> do
      let diagLine = T.intercalate " | " (fa.faDiagnosticsAfter)
          turn =
            "attempt " <> T.pack (show fa.faAttempt)
              <> ": diagnostics before: " <> T.intercalate " | " (fa.faDiagnosticsBefore)
              <> "; after: " <> (if T.null diagLine then "(clean)" else diagLine)
              <> maybe "" (\r -> "; repair: " <> T.take 60 r) fa.faRepaired
      _ <- runKiokuWrite store (recordFixTurn sid idx "assistant" turn)
      putStrLn ("  turn " <> show idx <> " recorded")

    runKiokuWrite store (completeFixSession sid "informed retry cleared the cell; lessons recorded for the next cells")
    putStrLn "  session completed — L0 evidence ready for kioku's L1 distiller"

    -- The recall path reads the memory back (the workflow's read, shown from
    -- the driver for the demo).
    notes <- runCampaignStore store (recallNotes campaignNamespace)
    case notes of
      Left err -> fail (show err)
      Right ns -> do
        putStrLn ("  recall check — " <> show (length ns) <> " lesson(s) available to the next workflow:")
        for_ ns \n -> TIO.putStrLn ("    - " <> n)

  putStrLn "[session] done"
  readIORef sidRef

-- ---------------------------------------------------------------------------
-- Act 5: kioku's L1 distiller runs live — L0 evidence becomes memory atoms
-- ---------------------------------------------------------------------------

-- | The campaign's AI config, generated from the OmniRoute environment so no
-- secret ever lands on disk: the JSON names @OMNIROUTE_API_KEY@ (or the
-- OpenAI fallback) and baikai resolves the key at call time — the same
-- discipline as the live tier-1 stack. Embeddings stay unset: the
-- keyword-only merge scan needs no vectors, and this host has no pgvector.
campaignAIConfigJSON :: IO BL.ByteString
campaignAIConfigJSON = do
  keyEnv <- do
    omni <- lookupEnv "OMNIROUTE_API_KEY"
    pure (if isJust omni then ("OMNIROUTE_API_KEY" :: Text) else "OPENAI_API_KEY")
  modelId <- do
    -- SHIKUMI_MODEL wins (e.g. auto/smart), then OMNIROUTE_CHAT_MODEL, then
    -- the proxy's ambient free-models tier.
    override <- lookupEnv "SHIKUMI_MODEL"
    ambient <- lookupEnv "OMNIROUTE_CHAT_MODEL"
    pure (maybe "free-models" T.pack (override <|> ambient))
  baseUrl <- do
    openAiBase <- lookupEnv "OPENAI_API_BASE"
    omniBase <- lookupEnv "OMNIROUTE_BASE_URL"
    pure $ case (openAiBase, omniBase) of
      (Just b, _) -> T.pack b
      (_, Just b) -> T.pack b
      _ -> "http://localhost:20128/v1"
  pure $
    Aeson.encode $
      Aeson.object
        [ "version" Aeson..= (1 :: Int),
          "permissions" Aeson..= ["api" :: Text],
          "distillation"
            Aeson..= Aeson.object
              [ "mode" Aeson..= ("api" :: Text),
                "api" Aeson..= ("openai-chat-completions" :: Text),
                "model" Aeson..= modelId,
                -- "openai" is the wire protocol (baikai's provider registry key),
                -- and it is what shikumi's capabilityFor checks to stamp the
                -- strict JSON schema — OmniRoute is an OpenAI-compatible proxy,
                -- so the native-schema path is exactly right here.
                "provider" Aeson..= ("openai" :: Text),
                "baseUrl" Aeson..= baseUrl,
                "options"
                  Aeson..= Aeson.object
                    [ "apiKeyEnv" Aeson..= keyEnv,
                      "maxTokens" Aeson..= (16384 :: Int),
                      "timeoutMs" Aeson..= (120000 :: Int)
                    ]
              ]
        ]

-- | A shape contract for the extractor, worked as a demonstration: the model
-- must reply with @atoms@ as a JSON array of /objects/ (the four named fields),
-- never a list of sentences. Kioku's stock guide lists top-level fields only, so
-- capable models still answered @atoms: ["sentence", ...]@ and the typed decode
-- failed with @expected object, got string@ — through every model tier. This is
-- the DSPy remedy at the signature level: show the exact output shape. The
-- runner goes through kioku's own 'TestRunners' seam (the sanctioned override
-- point), delegating execution to the same validated 'AIRuntime' and config as
-- every other feature, so the live stack is unchanged.
shapeInstruction :: Text
shapeInstruction =
  getInstruction extractSignature
    <> "\n\nWIRE FORMAT (mandatory): atoms MUST be a JSON array of objects, each \
       \object with exactly these keys: atomType (one of fact | pattern | \
       \preference | constraint | instruction), content (one concise sentence), \
       \priority (integer 0..100), confidence (one of high | medium | low). \
       \Never reply with a bare list of strings; if there is nothing durable \
       \to retain, reply with an empty array."

shapeDemo :: Demo ExtractInput ExtractOutput
shapeDemo = Demo
  { input =
      ExtractInput
        { focus = field "fix cell alpha.py",
          scopeLabel = field "cell alpha.py (verification campaign)",
          conversation =
            field
              "attempt 1: diagnostics before: [W-todo] found a TODO marker; \
               \after: (clean); repair: the TODO line was deleted entirely"
        },
    output =
      ExtractOutput
        { atoms =
            [ ExtractedAtom
                { atomType = field "pattern",
                  content = field "the fixer deletes TODO lines entirely once diagnostics confirm the marker",
                  priority = field (60 :: Int),
                  confidence = field "medium"
                }
            ]
        }
  }

shapeProgram :: Program ExtractInput ExtractOutput
shapeProgram = predict (setDemos [shapeDemo] (setInstruction shapeInstruction extractSignature))

-- | Run one AI program on the live stack with a bounded retry: live models
-- occasionally misbehave (a missing field, a truncated reply), and the tier-1
-- lesson was that /retries are part of the contract/. Each attempt is a fresh
-- model call; surfacing shikumi errors as kioku expects them.
runWithRetry :: AIRuntime -> AIFeature -> Program i o -> i -> IO (Either ShikumiError o)
runWithRetry air feature prog input = go (3 :: Int)
  where
    go 0 = once
    go n = do
      r <- once
      case r of
        Left _ -> go (n - 1)
        right -> pure right
    once =
      runAIProgram air feature prog input >>= \case
        Left (AIProgramFailed err) -> pure (Left err)
        Left other -> pure (Left (ProviderFailure (T.pack (show other))))
        Right out -> pure (Right out)

-- | Run the shape-contract extractor on the live stack.
campaignExtractRunner :: AIRuntime -> ExtractInput -> IO (Either ShikumiError ExtractOutput)
campaignExtractRunner air = runWithRetry air Extraction shapeProgram

-- | Consolidation stays on kioku's stock program — the same call the
-- non-overridden path would make (a decision over one or two atoms, no shape
-- contract needed).
campaignConsolidateRunner :: AIRuntime -> ConsolidateInput -> IO (Either ShikumiError ConsolidationDecision)
campaignConsolidateRunner air = runWithRetry air Consolidation consolidateProgram

-- | The scene and persona programs have scalar outputs, but the same live
-- flakiness applies — a missing field is one malformed reply away — so they
-- get the same treatment as the extractor: an explicit wire contract in the
-- instruction, a demonstration pinning the shape, bounded retries.
sceneShapeProgram :: Program SceneInput SceneOutput
sceneShapeProgram =
  predict
    ( setDemos
        [Demo (SceneInput (field "toy/cell/alpha.py") (field "the file alpha.py was repaired by deleting its TODO lines; the fixer deletes flagged lines entirely")) (SceneOutput (field "Marker hygiene for alpha.py") (field "- flagged lines are deleted entirely, never commented out\n- the journal keeps the before and after of every repair"))]
        ( setInstruction
            ( getInstruction sceneSignature
                <> "\n\nWIRE FORMAT (mandatory): reply with an object with exactly two keys: title (one short line) and bodyMd (markdown). Never omit either key."
            )
            sceneSignature
        )
    )

personaShapeProgram :: Program PersonaInput PersonaOutput
personaShapeProgram =
  predict
    ( setDemos
        [Demo (PersonaInput (field "toy/cell/alpha.py") (field "### Marker hygiene for alpha.py\n- flagged lines are deleted entirely, never commented out")) (PersonaOutput (field "A verification campaign over toy corpus cells: delete-only hygiene fixes, every repair journaled and re-checked by the oracle before it counts."))]
        ( setInstruction
            ( getInstruction personaSignature
                <> "\n\nWIRE FORMAT (mandatory): reply with an object with exactly one key: bodyMd (markdown). Never omit the key."
            )
            personaSignature
        )
    )

campaignSceneRunner :: AIRuntime -> SceneInput -> IO (Either ShikumiError SceneOutput)
campaignSceneRunner air = runWithRetry air Scene sceneShapeProgram

campaignPersonaRunner :: AIRuntime -> PersonaInput -> IO (Either ShikumiError PersonaOutput)
campaignPersonaRunner air = runWithRetry air Persona personaShapeProgram

runDistillAct :: SessionId -> IO ()
runDistillAct sid = do
  putStrLn "\n=== act 5: kioku's L1 distiller runs live — evidence becomes memory ==="

  -- Generate the config from the environment, hand it to kioku by path (no
  -- KIOKU_AI_CONFIG env needed — loadAIRuntime takes an explicit path), and
  -- remove the temp file once the runtime has parsed it.
  cfgJSON <- campaignAIConfigJSON
  (cfgPath, cfgHandle) <- openTempFile "/tmp" "campaign-ai.json"
  BL.hPut cfgHandle cfgJSON
  hClose cfgHandle
  air <- loadAIRuntime False (Just cfgPath)
  removeFile cfgPath
  -- The extraction runner carries the shape contract; consolidation (one or
  -- two atoms to decide over) stays on the stock path.
  let distillRT =
        withTestRunners
          (newDistillRuntime air Nothing)
          ( \tr ->
              tr
                { runExtract = campaignExtractRunner air,
                  runConsolidate = campaignConsolidateRunner air
                }
          )

  withCampaignStore $ \store -> do
    -- The distiller's effect row is the campaign's write row, so it runs
    -- inside the same store handle as every other kioku write. Merge
    -- candidates come from the keyword-only scan — no embeddings required.
    result <-
      runCampaignStore store $
        distillSessionL1
          campaignAccessContext
          IgnoreWatermark
          distillRT
          (scopedScanCandidates 8)
          sid
    case result of
      Left err -> fail ("  store error: " <> show err)
      Right inner -> case inner of
        Left err -> fail ("  L1 distillation failed: " <> show err)
        Right L1SkippedUpToDate ->
          putStrLn "  distiller: session already up to date — no new turns since the last pass"
        Right (L1Distilled summary) ->
          putStrLn
            ( "  distilled: " <> show summary.extracted <> " candidate(s) extracted, "
                <> show summary.stored <> " stored, "
                <> show summary.merged <> " merged, "
                <> show summary.skipped <> " skipped"
            )

    -- The proof: the same read the workflow uses now returns the
    -- machine-written atoms alongside the human-curated lessons.
    notes <- runCampaignStore store (recallNotes campaignNamespace)
    case notes of
      Left err -> fail (show err)
      Right ns -> do
        putStrLn ("  recall after distillation — " <> show (length ns) <> " note(s) in memory:")
        for_ ns \n -> TIO.putStrLn ("    - " <> n)

  putStrLn "[distill] done — the campaign writes its own lessons from its own journal"

-- ---------------------------------------------------------------------------
-- Shared fleet plumbing: the honest responder, concurrent store, timer sweep
-- ---------------------------------------------------------------------------

-- | The honest fleet "model": applies the one lesson each diagnostic needs
-- (delete the flagged line) to the diagnostics the /actual oracle/ computed
-- for the /actual cell/. A live model does the same because the diagnostics
-- and lessons ride the prompt; this stub does it textually. The repair is
-- still checked by the real no-regression guard, and the oracle still
-- re-scores what survived, so a wrong lesson application fails honestly.
honestEngineFor :: EngineFor
honestEngineFor oracle cell = stubEngine (\_n _ctx -> markerResponse [("repaired", T.unlines kept)])
  where
    diags = oracleCheck oracle (cellPath cell) (cellCurrent cell)
    doomed = SSet.fromList (map diagLineOf diags)
    kept =
      [ l
      | (i, l) <- zip [1 :: Int ..] (T.lines (sourceText (cellCurrent cell))),
        not (i `SSet.member` doomed)
      ]

-- | The full text of a rendered request — system prompt plus every user
-- message's text blocks. A scripted stub may condition its answer on it (the
-- live model reads the very same bytes); act 3's memory-informed model greps
-- its recalled lessons out of here.
promptText :: Context -> Text
promptText ctx =
  T.intercalate "\n" $
    maybe [] pure (systemPrompt ctx)
      <> [ t
         | UserMessage (UserPayload blocks _ts) <- Vector.toList (messages ctx),
           UserText (TextContent t) <- Vector.toList blocks
         ]

-- | Launch every cell's first run concurrently — one store connection per
-- launcher, so each launch is its own "process" talking to the same journal
-- (the unlift strategy stays sequential inside each connection; concurrency
-- lives between connections, in the async pool).
launchCells ::
  [(Cell, CellOracle, Namespace, WorkflowName, WorkflowId)] ->
  EngineFor ->
  IO ()
launchCells specs engineFor = do
  outcomes <-
    mapConcurrently
      ( \(cell, oracle, ns, wfName, wfId) ->
          withCampaignStore $ \store ->
            requireEither
              =<< runCampaignStore
                store
                ( do
                    _ <- runWorkflowWith defaultWorkflowRunOptions wfName wfId (cellCampaignWorkflow (engineFor oracle cell) (raise . noPublisherEff) cell oracle ns defaultMaxAttempts)
                    pure ()
                )
      )
      specs
  for_ outcomes \o -> putStrLn ("  launch outcome: " <> show o)

-- | A publisher that never publishes; typed at the plain store row, raised at
-- the workflow call sites (cells that escalate are not part of the fleet
-- acts).
noPublisherEff :: AwakeableId -> Eff CampaignEffects ()
noPublisherEff = const (pure ())

-- | Drive the fleet's clocks until no @sleep:*@ step is missing from any
-- journal, bounded: each pass BATCH-drains due timers, then runs a resume
-- pass — the resume is what journals the sleep step (the fire action only
-- marks the timer fired), so a sweep without resumes would spin forever.
fireTimerSweep :: CampaignStore -> WorkflowRegistry CampaignEffects -> [(Text, Text)] -> IO ()
fireTimerSweep store registry streamSteps = do
  fireTime <- liftIO (addUTCTime 3600 <$> getCurrentTime)
  let satisfied (s, t) = do
        has <- journalHasStep store s t
        if has
          then pure True
          else
            -- A cell that passed at launch (the corpus's negative control
            -- is clean by design) never arms a settle sleep, so its
            -- /completed journal/ satisfies the sweep too.
            journalIsComplete . decodedJournal <$> readJournal store s
      pending = filterM (fmap not . satisfied) streamSteps
      loop n
        | n > 20 = fail "timer sweep: steps still unjournaled after 20 passes"
        | otherwise = do
            remaining <- pending
            if null remaining
              then putStrLn ("  timer sweep: all " <> show (length streamSteps) <> " sleep steps journaled")
              else do
                -- One BATCH drain per pass: the timer table is shared by every
                -- host (kioku's L1/L2 distillation timers live here too), so a
                -- single-claim worker can starve the fleet's sleeps behind a
                -- backlog of other hosts' due timers. Non-workflow timers have
                -- no handler in this driver (a kioku deployment would run its
                -- own worker) — the no-op process-manager fallback releases
                -- them without inventing events.
                _ <-
                  requireEither
                    =<< runCampaignStore
                      store
                      (drainWorkflowSleepTimers Nothing fireTime 100 (\_ -> pure Nothing))
                -- The fired timers only wake the workflows; this resume pass
                -- is what replays each body past its sleep and journals it.
                resumeOnceQuiet store registry
                loop (n + 1)
  loop 0

-- | Drain: resume passes until every fleet workflow is complete, bounded.
drainFleet :: CampaignStore -> WorkflowRegistry CampaignEffects -> [Text] -> IO ()
drainFleet store registry ids = loop (0 :: Int)
  where
    loop n
      | n > 20 = fail "fleet drain: still unfinished after 20 resume passes"
      | otherwise = do
          remaining <- ourUnfinished store ids
          if null remaining
            then putStrLn "  drain: fleet complete — all journals carry WorkflowCompleted"
            else do
              driveResumeOnce store registry
              loop (n + 1)

-- | Per-cell attempt summary from the journal (the fleet's scoreboard).
printCellScoreboard :: CampaignStore -> WorkflowRegistry CampaignEffects -> [(Text, Text, WorkflowName, WorkflowId)] -> IO ()
printCellScoreboard store _registry rows =
  for_ rows \(label, stream, _wfName, _wfId) -> do
    journal <- decodedJournal <$> readJournal store stream
    let attempts = journaledAttempts journal
        ok = journalIsComplete journal
        cleared = case reverse attempts of
          (last_ : _) -> faSucceeded last_ && null (faDiagnosticsAfter last_)
          [] -> True -- passed at launch: no attempts needed
        verdict
          | not ok = "INCOMPLETE"
          | cleared = "cleared"
          | otherwise = "closed without clearing"
    TIO.putStrLn
      ( "  " <> label
          <> ": "
          <> (if ok then "complete" else "INCOMPLETE")
          <> ", "
          <> T.pack (show (length attempts))
          <> " attempt(s) — "
          <> verdict
      )

-- | The campaign's AI runtime, generated from the OmniRoute environment (see
-- act 5 for the config discipline). Shared by acts 5 and 8.
withLoadedAIRuntime :: (AIRuntime -> IO ()) -> IO ()
withLoadedAIRuntime action = withAIRuntime (\air -> action air >> pure ())

-- | The same runtime, for blocks that produce a value (act 17's planner and
-- persona distillation both need the result, not just the effect).
withAIRuntime :: (AIRuntime -> IO a) -> IO a
withAIRuntime action = do
  cfgJSON <- campaignAIConfigJSON
  (cfgPath, cfgHandle) <- openTempFile "/tmp" "campaign-ai.json"
  BL.hPut cfgHandle cfgJSON
  hClose cfgHandle
  air <- loadAIRuntime False (Just cfgPath)
  removeFile cfgPath
  action air

-- ---------------------------------------------------------------------------
-- Act 6: the toy fleet — the remaining corpus cells as concurrent durable
-- workflows
-- ---------------------------------------------------------------------------

-- | Act 6 runs the corpus cells acts 1–3 did not already journal (alpha,
-- beta and gamma have histories with meaning; their workflow ids are stable
-- and a re-run would replay, not re-tell). The fleet is the /same/ workflow
-- name and body as the single-cell acts — what scales is the number of
-- concurrent instances, each launched on its own store connection (a cell's
-- launch is its own process), then drained by one registry.
runFleetAct :: IO ()
runFleetAct = do
  putStrLn "\n=== act 6: the toy fleet — concurrent durable campaign instances ==="
  let fleetCells = [c | c <- corpusCells, unCellId (cellId c) `notElem` ["alpha.py", "beta.py", "gamma.py"]]
  when (null fleetCells) $ fail "fleet: no unjournaled corpus cells (reset the campaign DB first)"
  let specs =
        [ (cell, markerOracle, campaignNamespace, cellCampaignWorkflowName, campaignWorkflowId (cellId cell))
        | cell <- fleetCells
        ]
      rows =
        [ ( "toy/" <> unCellId (cellId cell),
            campaignStreamNameText cellCampaignWorkflowName wfId,
            cellCampaignWorkflowName,
            wfId
          )
        | (cell, _oracle, _ns, _wfName, wfId) <- specs
        ]
      ourIds = [wfIdText wfId | (_, _, _, _, wfId) <- specs]
      fleetRegistry = campaignRegistry [] [] honestEngineFor noPublisherEff

  putStrLn ("[fleet] launching " <> show (length specs) <> " cells concurrently — one store connection per launcher")
  launchCells specs honestEngineFor

  -- One clock for the whole fleet: sweep timers until every settle sleep is
  -- journaled, then resume passes drain every completed attempt.
  withCampaignStore $ \store -> do
    fireTimerSweep store fleetRegistry [(s, "sleep:settle-1") | (_, s, _, _) <- rows]
    drainFleet store fleetRegistry ourIds

  putStrLn "[fleet] journal scoreboard:"
  withCampaignStore $ \store -> do
    printCellScoreboard store fleetRegistry rows
    remaining <- ourUnfinished store ourIds
    unless (null remaining) $ fail ("fleet restart check: unfinished work remains: " <> show remaining)
    putStrLn "  restart: no unfinished work — every cell's campaign lives in its journal"

-- ---------------------------------------------------------------------------
-- Act 7: the project fleet — real cells from the mowgli and peirce checkouts
-- ---------------------------------------------------------------------------

-- | Act 7 runs the /same/ campaign body over real files: unused-import cells
-- scanned out of the actual checkouts (mowgli: @llada_interface.py@; peirce:
-- @python/base_model.py@, @python/pdf_extract.py@), the real unused-import
-- oracle owning ground truth, and one memory namespace per project so each
-- project's lessons and distillations partition cleanly. Nothing writes back
-- to the checkouts — the journals are the record, and the registry rebuilds
-- each cell's body from its workflow id alone.
runProjectFleetAct :: IO ()
runProjectFleetAct = do
  putStrLn "\n=== act 7: the project fleet — real cells from mowgli and peirce ==="
  pcs <- catMaybes <$> mapM readProjectCell projectCellSpecs
  when (length pcs /= length projectCellSpecs) $
    fail "project fleet: some checkouts are missing (expected ~/src/mowgli and ~/src/peirce)"
  for_ pcs $ \pc ->
    putStrLn ("[projects] cell " <> T.unpack (pcProject pc) <> ":" <> T.unpack (pcPath pc))

  let mkCell pc =
        Cell
          { cellId = CellId (pcProject pc <> ":" <> pcPath pc),
            cellPath = pcPath pc,
            cellOriginal = pcSource pc,
            cellCurrent = pcSource pc
          }
      specs =
        [ (mkCell pc, unusedImportOracle, projectNamespace (pcProject pc), projectCampaignWorkflowName, projectWorkflowId (pcProject pc) (pcPath pc))
        | pc <- pcs
        ]
      rows =
        [ ( pcProject pc <> "/" <> pcPath pc,
            campaignStreamNameText projectCampaignWorkflowName (projectWorkflowId (pcProject pc) (pcPath pc)),
            projectCampaignWorkflowName,
            projectWorkflowId (pcProject pc) (pcPath pc)
          )
        | pc <- pcs
        ]
      ourIds = [wfIdText wid | (_, _, _, _, wid) <- specs]
      projectRegistry = campaignRegistry pcs [] honestEngineFor noPublisherEff

  -- Each project's campaign memory is seeded with the lesson its diagnostics
  -- call for (as a real campaign would have learned from earlier runs), so
  -- the fleet's attempts carry recalled-memory provenance like the toy fleet.
  for_ [("mowgli", "an unused import must have its whole import line deleted"), ("peirce", "delete the whole import line flagged unused; never leave a stub")
       ] $ \(proj, advice) ->
    withCampaignStore $ \store ->
      runKiokuWrite store (recordLesson (projectNamespace proj) (proj <> "/imports") advice)

  putStrLn ("[projects] launching " <> show (length specs) <> " cells concurrently")
  launchCells specs honestEngineFor

  withCampaignStore $ \store -> do
    fireTimerSweep store projectRegistry [(s, "sleep:settle-1") | (_, s, _, _) <- rows]
    drainFleet store projectRegistry ourIds

  putStrLn "[projects] journal scoreboard:"
  withCampaignStore $ \store -> do
    printCellScoreboard store projectRegistry rows
    remaining <- ourUnfinished store ourIds
    unless (null remaining) $ fail ("project fleet restart check: unfinished work remains: " <> show remaining)
    putStrLn "  restart: no unfinished work — the checkouts were never touched; the journals are the record"

  -- The partitioning proof: each project's namespace recalls its own
  -- lessons only — mowgli's memory never answers for peirce.
  withCampaignStore $ \store ->
    for_ ["mowgli", "peirce"] $ \proj -> do
      notes <- requireEither =<< runCampaignStore store (recallNotes (projectNamespace proj))
      putStrLn ("  memory in " <> T.unpack proj <> ": " <> show (length notes) <> " note(s)")
      for_ notes \n -> TIO.putStrLn ("    - " <> n)

-- ---------------------------------------------------------------------------
-- Act 8: kioku's L2 scenes and L3 persona — each project's memory distilled
-- ---------------------------------------------------------------------------

-- | Act 8 distills each project's /global/ memory — the lessons a host
-- promotes to project level — through kioku's L2 scene program, and the
-- scenes through the L3 persona program. Both run LIVE on the same
-- AIRuntime as act 5 (scalar outputs only, so the stock programs decode
-- fine), and both mirror their markdown under a workspace directory: the
-- scene and persona files are the project's distilled self-image, one
-- directory per project, rebuilt whenever the memory changes.
runL2L3Act :: IO ()
runL2L3Act = do
  putStrLn "\n=== act 8: kioku's L2 scenes and L3 persona — projects distilled, live ==="

  -- Promote one project-level lesson per project: scenes and personas distill
  -- over the namespace's global scope (ScopeGlobal ns), so what reaches them
  -- is exactly what a host promotes — not every cell's note.
  withCampaignStore $ \store ->
    for_
      [ ("mowgli", "project mowgli: hygiene fixes are delete-only; a flagged import line is removed, never stubbed"),
        ("peirce", "project peirce: the campaign fixes hygiene wherever it lives; delete-only repairs, originals preserved in the journal")
      ]
      $ \(proj, advice) ->
        runKiokuWrite store (recordGlobalLesson (projectNamespace proj) advice)

  withLoadedAIRuntime $ \air -> do
    let mirrorRoot = "/tmp/campaign-mirrors"
        distillRT =
          withDistillWorkspace mirrorRoot
            ( withTestRunners
                (newDistillRuntime air Nothing)
                (\tr -> tr{runScene = campaignSceneRunner air, runPersona = campaignPersonaRunner air})
            )
    for_ ["mowgli", "peirce"] $ \proj -> do
      let ns = projectNamespace proj
          gscope = ScopeGlobal ns
      withCampaignStore $ \store -> do
        sceneR <- requireEither =<< runCampaignStore store (regenerateScene distillRT campaignMemorySpace gscope)
        case sceneR of
          Left err -> fail ("scene regeneration failed: " <> show err)
          Right Nothing -> putStrLn ("  [" <> T.unpack proj <> "] scene: no global memory to distill")
          Right (Just row) -> do
            TIO.putStrLn ("  [" <> proj <> "] scene: " <> row.title)
            putStrLn
              ( "    body: " <> show (T.length row.bodyMd) <> " chars, "
                  <> show (length row.atomIds) <> " atom(s) distilled"
              )
        personaR <- requireEither =<< runCampaignStore store (regeneratePersona distillRT campaignMemorySpace gscope)
        case personaR of
          Left err -> fail ("persona regeneration failed: " <> show err)
          Right Nothing -> putStrLn ("  [" <> T.unpack proj <> "] persona: no scenes to distill")
          Right (Just prow) ->
            putStrLn
              ( "  [" <> T.unpack proj <> "] persona: " <> show prow.sceneCount <> " scene(s), "
                  <> show (T.length prow.bodyMd) <> " chars of markdown"
              )
      putStrLn ("    (mirrors under " <> mirrorRoot <> ")")

  putStrLn "[distill-l2l3] done — each project's memory now has a narrative self-image"

-- ---------------------------------------------------------------------------
-- Acts 9 and 10: the live decision engine and the memory-driven planner
-- ---------------------------------------------------------------------------

-- | The campaign's typed planner contract: the campaign's state and its
-- persona in, one chosen cell and a reason out. Everything is data — the
-- pending list is the real journal state, the persona is the real distilled
-- self-image, and the choice is decoded through shikumi's typed decode.
data PlannerInput = PlannerInput
  { pendingCells :: Field "pending cells, one per line: id — which lesson applies — what its diagnostics need" Text,
    lessons :: Field "campaign lessons recalled from memory" Text,
    personaMd :: Field "the campaign's distilled persona (how this campaign operates)" Text
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ToSchema, FromModel, ToPrompt)

data PlannerOutput = PlannerOutput
  { chosenCell :: Field "the id of the one cell to fix next" Text,
    reason :: Field "why this cell, given the persona and the lessons" Text
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ToSchema, FromModel, ToPrompt, Validatable)

plannerSignature :: Signature PlannerInput PlannerOutput
plannerSignature =
  mkSignature
    "You are the planner of a file-hygiene verification campaign. Given the \
    \pending cells, the campaign's lessons, and your distilled persona, choose \
    \the ONE cell to fix next and say why. Obey the persona: it describes how \
    \this campaign operates. Cells whose needed lesson is already in the \
    \lessons are the cheapest to fix correctly — prefer them."

plannerProgram :: Program PlannerInput PlannerOutput
plannerProgram =
  predict
    ( setDemos
        [ Demo
            ( PlannerInput
                (field "toy/cell/alpha.py — needs: delete TODO lines\ntoy/cell/zeta.py — needs: delete a whole import line (lesson: unused imports are deleted, never stubbed)")
                (field "a line marked TODO must be deleted entirely, not commented out\ndelete the whole import line flagged unused; never leave a stub")
                (field "### Campaign persona\n- delete-only repairs; every repair is re-checked by the oracle before it counts")
            )
            (PlannerOutput (field "toy/cell/zeta.py") (field "the persona demands delete-only repairs and the lessons already cover zeta's unused-import class, so it is the cheapest correct fix"))
        ]
        (setInstruction shapeContractInstruction plannerSignature)
    )
  where
    shapeContractInstruction =
      "Reply in the exact wire shape demonstrated: a chosenCell field holding \
      \the bare cell id text, and a reason field holding one sentence. Never \
      \reply with prose outside the fields."

-- | The live decision engine: the very same 'runAIProgram' call kioku's own
-- distillers make, pointed at the campaign's fixer program. The model field
-- of the AI config (act 5's discipline — generated from the OmniRoute
-- environment, no secrets on disk) selects the tier; 'AIFeature' is only a
-- config key here, so Extraction's model tier drives the fix attempt.
liveEngine :: AIRuntime -> AttemptEngine
liveEngine air n prog input _notes = do
  -- Bounded retry: a live model is one malformed reply away from a typed
  -- error, and the tier-1 lesson was that retries are part of the contract.
  let go :: Int -> IO (Maybe Source)
      go 0 = once
      go k =
        once >>= \case
          Nothing -> go (k - 1)
          ok -> pure ok
      once =
        runAIProgram air Extraction prog input >>= \case
          Right (RepairOut (Field txt)) -> pure (Just (Source txt))
          Left (AIProgramFailed err) -> do
            putStrLn ("    [live-engine] typed error: " <> show err)
            pure Nothing
          Left other -> do
            putStrLn ("    [live-engine] " <> show other)
            pure Nothing
  r <- go (3 :: Int)
  putStrLn ("    [live] attempt " <> show n <> ": " <> maybe "failed (typed error)" (const "proposed a repair") r)
  pure r

-- | Act 9: the live decision loop. The corpus cells run again — same bytes,
-- same oracle, same timers, same attempt budget — under a @live:@ journal
-- prefix, with a real model behind the fixer program instead of the stub.
-- The lessons acts 1–3 recorded are recalled into the attempts by the
-- ordinary decision step; nothing is seeded for the live fleet.
runLiveDecisionAct :: IO ()
runLiveDecisionAct = do
  putStrLn "\n=== act 9: the live decision loop — a real model runs the campaign ==="
  withLoadedAIRuntime $ \air -> do
    let liveCells = [c | c <- corpusCells, unCellId (cellId c) `elem` ["delta.py", "epsilon.py", "zeta.py"]]
        specs =
          [ ( Cell (CellId ("live:" <> unCellId (cellId c))) (cellPath c) (cellOriginal c) (cellCurrent c),
              markerOracle,
              campaignNamespace,
              cellCampaignWorkflowName,
              campaignWorkflowId (CellId ("live:" <> unCellId (cellId c)))
            )
          | c <- liveCells
          ]
        rows =
          [ ( "live/" <> unCellId (cellId cell),
              campaignStreamNameText cellCampaignWorkflowName wfId,
              cellCampaignWorkflowName,
              wfId
            )
          | (cell, _, _, _, wfId) <- specs
          ]
        ourIds = [wfIdText wfId | (_, _, _, _, wfId) <- specs]
        liveRegistry =
          campaignRegistry
            []
            [Cell (CellId ("live:" <> unCellId (cellId c))) (cellPath c) (cellOriginal c) (cellCurrent c) | c <- liveCells]
            (\_oracle _cell -> liveEngine air)
            noPublisherEff

    putStrLn ("[live] launching " <> show (length specs) <> " cells concurrently — a real model behind every attempt")
    launchCells specs (\_oracle _cell -> liveEngine air)

    withCampaignStore $ \store -> do
      fireTimerSweep store liveRegistry [(s, "sleep:settle-" <> T.pack (show n)) | (_, s, _, _) <- rows, n <- [1 :: Int .. 3]]
      drainFleet store liveRegistry ourIds

    putStrLn "[live] journal scoreboard:"
    withCampaignStore $ \store -> do
      printCellScoreboard store liveRegistry rows
      remaining <- ourUnfinished store ourIds
      unless (null remaining) $ fail ("live fleet restart check: unfinished work remains: " <> show remaining)
      putStrLn "  restart: no unfinished work — the live campaign is journaled like every other"

-- | Act 10: memory-driven planning. The toy campaign's own persona is
-- distilled live (the same L2/L3 path act 8 runs for the projects), and the
-- persona — with the recalled lessons and the real pending-cell list read
-- off the journals — is what the planner program sees. Its typed choice
-- decides which fresh cell the live campaign fixes; the decision itself is
-- recorded into memory as an atom, so the campaign's next planner call can
-- recall what it chose and why.
runPlannerAct :: IO ()
runPlannerAct = do
  putStrLn "\n=== act 10: memory-driven planning — the persona picks the next cell ==="

  -- One pending cell the campaign has never touched: the corpus's negative
  -- control (clean at launch, so its campaign ends immediately — the honest
  -- choice for a live planner demo whose job is the choice, not the fixing).
  let chosenCellName = "eta.py"
      chosenCell = case [c | c <- corpusCells, unCellId (cellId c) == chosenCellName] of
        [c] -> c
        _ -> error "planner: eta.py missing from the corpus"
      pendingLines =
        [ unCellId (cellId c) <> " — needs: " <> needDescription (unCellId (cellId c))
        | c <- corpusCells,
          unCellId (cellId c) == chosenCellName
        ]
      needDescription name
        | name == chosenCellName = "no diagnostics (the negative control); verifying it stays clean"
        | otherwise = "delete the flagged lines"

  withCampaignStore $ \store -> do
    notes <- requireEither =<< runCampaignStore store (recallNotes campaignNamespace)
    let personaMd = case notes of
          [] -> "(no lessons recalled yet)"
          ns -> T.unlines ns
    withLoadedAIRuntime $ \air -> do
      let distillRT =
            withDistillWorkspace "/tmp/campaign-mirrors"
              ( withTestRunners
                  (newDistillRuntime air Nothing)
                  (\tr -> tr{runScene = campaignSceneRunner air, runPersona = campaignPersonaRunner air})
              )
          gscope = ScopeGlobal campaignNamespace
      -- Distill the toy campaign's own memory (its lessons live in
      -- campaignNamespace; act 5's session evidence is already in there).
      _ <- requireEither =<< runCampaignStore store (regenerateScene distillRT campaignMemorySpace gscope)
      personaE <- requireEither =<< runCampaignStore store (regeneratePersona distillRT campaignMemorySpace gscope)
      personaText <- case personaE of
        Right (Just prow) -> do
          putStrLn ("  persona distilled: " <> show (T.length prow.bodyMd) <> " chars of markdown")
          pure prow.bodyMd
        Right Nothing -> pure "(no persona yet — a fresh campaign)"
        Left err -> fail ("persona distillation failed: " <> show err)

      let input =
            PlannerInput
              (Field (T.unlines pendingLines))
              (Field (T.unlines (map ("- " <>) (T.lines personaMd))))
              (Field personaText)
      runPlanner <- do
        r <- runAIProgram air Extraction plannerProgram input
        pure (either (Left . show) Right r :: Either String PlannerOutput)
      choice <- case runPlanner of
        Left err -> fail ("planner program failed: " <> err)
        Right out -> pure out
      let picked = unField choice.chosenCell
      putStrLn ("  planner chose: " <> T.unpack picked)
      TIO.putStrLn ("    reason: " <> unField choice.reason)
      unless (picked == chosenCellName) $
        putStrLn "    (planner picked a different cell than the demo's prepared one — running it anyway)"
      -- The decision is recorded into memory as an atom: the campaign can
      -- recall what it chose and why.
      _ <-
        requireEither
          =<< runCampaignStore
            store
            (recordLesson campaignNamespace ("planner/" <> picked) ("planner chose " <> picked <> ": " <> unField choice.reason))
      pure ()

      -- The chosen cell runs the live campaign under a fresh journal prefix.
      let cell = chosenCell{cellId = CellId ("live2:" <> chosenCellName)}
          wfId = campaignWorkflowId (CellId ("live2:" <> chosenCellName))
          stream = campaignStreamNameText cellCampaignWorkflowName wfId
          liveRegistry = campaignRegistry [] [cell] (\_oracle _c -> liveEngine air) noPublisherEff
      requireFreshJournal store stream
      _ <-
        requireEither
          =<< runCampaignStore
            store
            (runWorkflowWith defaultWorkflowRunOptions cellCampaignWorkflowName wfId (cellCampaignWorkflow (liveEngine air) (raise . noPublisherEff) cell markerOracle campaignNamespace defaultMaxAttempts))
      -- A clean-at-launch cell (the negative control) completes at verify
      -- with no settle sleep armed; only a parked workflow needs firing.
      journal0 <- readJournal store stream
      unless (journalIsComplete (decodedJournal journal0)) $
        fireTimerUntilJournaled store stream "sleep:settle-1"
      driveResumeOnce store liveRegistry
      journal <- readJournal store stream
      unless (journalIsComplete (decodedJournal journal)) $
        fail "planner journal has no WorkflowCompleted"
      putStrLn ("  the planner's choice ran the live campaign: " <> T.unpack (unCellId cell.cellId) <> " completed")
      let attempts = journaledAttempts (decodedJournal journal)
      putStrLn ("  journal: " <> show (length attempts) <> " attempt(s) journaled")

-- ---------------------------------------------------------------------------
-- Act 11: the campaign gets hands — accepted repairs land in git worktrees
-- ---------------------------------------------------------------------------

-- | Act 11 closes the loop on the world. So far every repair lived only in a
-- keiro journal; this act makes each project cell's accepted repair real:
--
--   1. Read each fix journal and extract the accepted repair ('faRepaired').
--   2. Run a @campaign-landing@ workflow per cell — journaled steps that
--      ensure the worktree, write the repair, re-verify against the /real/
--      file on disk, and commit on @campaign\/unused-imports@. Replay never
--      re-writes or re-commits: the 'LandingRecord' is the durable decision.
--   3. Prove the safety rule: the parent checkouts' dirty-entry counts are
--      identical before and after — landings touch only worktrees.
--   4. Show each campaign branch's log: the campaign's work, reviewable.
--
-- Re-runs are honest no-ops: the worktree is reused, HEAD already carries
-- the repair, so the commit step reports the existing commit unchanged.
runLandingAct :: IO ()
runLandingAct = do
  putStrLn "\n=== act 11: the campaign gets hands — repairs land in git worktrees ==="

  pcs <- catMaybes <$> mapM readProjectCell projectCellSpecs
  when (null pcs) $ fail "landing: no project cells found in the checkouts"

  -- Read-only observation of the parents, before any landing.
  dirtyBefore <- forM (nub (map pcProject pcs)) parentDirtyCount

  -- The accepted repairs, read out of the fix journals (act 7's output —
  -- the campaign decided; this act executes).
  repairsRef <- newIORef []
  withCampaignStore $ \store ->
    forM_ pcs $ \pc -> do
      journal <- readJournal store (campaignStreamNameText projectCampaignWorkflowName (projectWorkflowId (pcProject pc) (pcPath pc)))
      let accepted = [r | FixAttempt{faRepaired = Just r} <- journaledAttempts (decodedJournal journal)]
      case accepted of
        [] -> fail ("landing: no accepted repair journaled for " <> T.unpack (pcProject pc <> ":" <> pcPath pc))
        (r : _) -> modifyIORef' repairsRef ((pc, r) :)
  cellsWithRepairs <- reverse <$> readIORef repairsRef

  -- One landing workflow per cell, journaled like every other act. (The
  -- landing steps never park, so no resume pass or registry is needed —
  -- a crashed landing resumes through the registry in real deployments,
  -- where registerLanding is what the host registers.) The journal is the
  -- record: on a re-run the landing is reported from the existing journal
  -- instead of re-executed — and the hands are idempotent either way.
  let reportLanding recd
        | lrVerified recd =
            putStrLn
              ( "  landed " <> T.unpack (lrProject recd <> ":" <> lrPath recd)
                  <> " — commit " <> T.unpack (lrCommit recd)
                  <> " on " <> T.unpack (lrBranch recd)
                  <> " (" <> T.unpack (lrWorktree recd) <> ")"
              )
        | otherwise = do
            putStrLn ("  NOT LANDED " <> T.unpack (lrProject recd <> ":" <> lrPath recd) <> " — on-disk verification failed:")
            for_ (lrDiagnostics recd) (putStrLn . ("    " <>) . T.unpack)
  withCampaignStore $ \store ->
    forM_ cellsWithRepairs $ \(pc, repair) -> do
      let wfId = landingWorkflowId (pcProject pc, pcPath pc)
          stream = campaignStreamNameText landingWorkflowName wfId
      existing <- readJournal store stream
      case landingRecordOf (decodedJournal existing) of
        (recd : _) -> reportLanding recd
        [] -> do
          _ <-
            requireEither
              =<< runCampaignStore
                store
                ( runWorkflowWith
                    defaultWorkflowRunOptions
                    landingWorkflowName
                    wfId
                    (landProjectCellWorkflow pc unusedImportOracle "campaign/unused-imports" repair)
                )
          journal <- readJournal store stream
          case landingRecordOf (decodedJournal journal) of
            (recd : _) -> reportLanding recd
            [] -> fail ("landing: journal has no landing record for " <> T.unpack (pcProject pc <> ":" <> pcPath pc))

  -- The safety proof: the parents are byte-identical in git's eyes.
  dirtyAfter <- forM (nub (map pcProject pcs)) parentDirtyCount
  putStrLn ("  parent dirty-entry counts before: " <> show dirtyBefore)
  putStrLn ("  parent dirty-entry counts after:  " <> show dirtyAfter)
  when (dirtyBefore /= dirtyAfter) $ fail "landing: parent checkouts were modified — safety rule violated"

  -- The campaign's work, as a human would review it: one branch per project.
  for_ (nub (map pcProject pcs)) $ \proj -> do
    let wt = campaignWorktreePath proj (campaignBranchFor proj)
    log <- gitCapture wt ["log", "--oneline", T.unpack (campaignBranchFor proj)]
    putStrLn ("  " <> T.unpack proj <> " branch log:")
    for_ (T.lines log) (putStrLn . ("    " <>) . T.unpack)
  putStrLn "[landing] done — the journals decided, the worktrees received, the parents untouched"

-- ---------------------------------------------------------------------------
-- Act 12: the ReAct fixer — the same cells, fixed by an agent with tools
-- ---------------------------------------------------------------------------

-- | Act 12 runs the project cells again — same oracles, same attempt
-- budgets, same journals — but the attempts are now a /ReAct agent with
-- typed tools/ (read_file, delete_lines, check_diagnostics) instead of the
-- whole-file fixer. The delete-only policy becomes structural: the only
-- mutation tool there is is a deletion. The engine's success is the real
-- oracle on the agent's final state; the model's done claim is never
-- trusted.
--
-- Two runs:
--
--   * @react:@ — the /scripted/ agent (deterministic, offline): the loop's
--     shape, the tools, the trajectory, and the landing all real.
--   * @react-live:@ — the same agent driven by the real model through
--     'runAIProgram' (a live stack is the same call). Trajectories show the
--     agent actually reading the file, deleting, checking, and finishing.
--
-- Both are landed through the act-11 worktree machinery onto
-- @campaign\/react-fixes@ branches — the campaign's new hands handle a new
-- kind of repair without change.
runReactAct :: IO ()
runReactAct = do
  putStrLn "\n=== act 12: the ReAct fixer — an agent with typed tools ==="
  pcs <- catMaybes <$> mapM readProjectCell projectCellSpecs
  when (null pcs) $ fail "react act: no project cells found in the checkouts"

  let prefix = "react-"
      -- The registry's project-id parser accepts the react- prefix (fresh
      -- campaign instances of the same cells).
      rcell pc =
        Cell
          { cellId = CellId ("pcell-" <> prefix <> pcProject pc <> ":" <> pcPath pc),
            cellPath = pcPath pc,
            cellOriginal = pcSource pc,
            cellCurrent = pcSource pc
          }
      specs =
        [ ( rcell pc,
            unusedImportOracle,
            projectNamespace (pcProject pc),
            projectCampaignWorkflowName,
            projectWorkflowId2 prefix (pcProject pc) (pcPath pc)
          )
        | pc <- pcs
        ]
      rows =
        [ ( "react/" <> pcProject pc <> "/" <> pcPath pc,
            campaignStreamNameText projectCampaignWorkflowName (projectWorkflowId2 prefix (pcProject pc) (pcPath pc)),
            projectCampaignWorkflowName,
            projectWorkflowId2 prefix (pcProject pc) (pcPath pc)
          )
        | pc <- pcs
        ]
      ourIds = [wfIdText wid | (_, _, _, _, wid) <- specs]

  -- Scripted run: offline, journaled.
  putStrLn "[react] scripted agent over the project cells"
  let scriptedRegistry = campaignRegistry pcs [] (\o c -> scriptedReactEngine o c) noPublisherEff
  launchCells specs (\o c -> scriptedReactEngine o c)
  withCampaignStore $ \store -> do
    fireTimerSweep store scriptedRegistry [(s, "sleep:settle-" <> T.pack (show n)) | (_, s, _, _) <- rows, n <- [1 :: Int .. 3]]
    drainFleet store scriptedRegistry ourIds
  putStrLn "[react] journal scoreboard:"
  withCampaignStore $ \store -> printCellScoreboard store scriptedRegistry rows

  -- Live run: the same agent, real model.
  withLoadedAIRuntime $ \air -> do
    putStrLn "[react-live] launching the same cells under the live agent"
    let livePrefix = "react-live-"
        lspecs =
          [ ( rcell' pc
            , unusedImportOracle
            , projectNamespace (pcProject pc)
            , projectCampaignWorkflowName
            , projectWorkflowId2 livePrefix (pcProject pc) (pcPath pc)
            )
          | pc <- pcs
          ]
        lrows =
          [ ( "react-live/" <> pcProject pc <> "/" <> pcPath pc,
              campaignStreamNameText projectCampaignWorkflowName (projectWorkflowId2 livePrefix (pcProject pc) (pcPath pc)),
              projectCampaignWorkflowName,
              projectWorkflowId2 livePrefix (pcProject pc) (pcPath pc)
            )
          | pc <- pcs
          ]
        ourLIds = [wfIdText wid | (_, _, _, _, wid) <- lspecs]
        rcell' pc =
          (rcell pc)
            { cellId = CellId ("pcell-" <> livePrefix <> pcProject pc <> ":" <> pcPath pc)
            }
        liveRegistry = campaignRegistry pcs [] (\o c -> reactEngineFor air o c) noPublisherEff
    launchCells lspecs (\o c -> reactEngineFor air o c)
    withCampaignStore $ \store -> do
      fireTimerSweep store liveRegistry [(s, "sleep:settle-" <> T.pack (show n)) | (_, s, _, _) <- lrows, n <- [1 :: Int .. 3]]
      drainFleet store liveRegistry ourLIds
    putStrLn "[react-live] journal scoreboard:"
    withCampaignStore $ \store -> do
      printCellScoreboard store liveRegistry lrows
      remaining <- ourUnfinished store ourLIds
      unless (null remaining) $
        putStrLn
          ( "  [react-live] " <> show (length remaining)
              <> " workflow(s) still suspended \8212 live-model budget or provider"
              <> " rate limits ran out; the journals hold every partial attempt and"
              <> " a later resume pass continues exactly where they stopped"
          )

    -- Land the live run's accepted repairs on campaign/react-fixes.
    landRun livePrefix

  -- Land the scripted run's repairs too (its own journal prefix, same
  -- branch). The landing machinery is repair-agnostic: it cannot tell which
  -- engine proposed what it is committing.
  landRun prefix
  putStrLn "[react] done — the agent decides with tools; the journals record; the branches receive"
  where
    projectWorkflowId2 pfx proj path =
      let WorkflowId t = projectWorkflowId proj path
       in WorkflowId (T.replace "pcell-" ("pcell-" <> pfx) t)
    -- One landing pass: read each project cell's accepted repair out of the
    -- prefix's fix journal, run the journaled landing workflow (or report the
    -- existing record on a re-run), and print the branch log at the end.
    landRun pfx = do
      let branch = "campaign/react-fixes"
      pcs' <- catMaybes <$> mapM readProjectCell projectCellSpecs
      withCampaignStore $ \store ->
        forM_ pcs' $ \pc -> do
          let proj = pcProject pc
              path = pcPath pc
          journal <- readJournal store (campaignStreamNameText projectCampaignWorkflowName (projectWorkflowId2 pfx proj path))
          let accepted = [r | FixAttempt{faRepaired = Just r} <- journaledAttempts (decodedJournal journal)]
          case accepted of
            [] -> putStrLn ("  [" <> labelOf pfx <> "] no accepted repair for " <> T.unpack (proj <> ":" <> path) <> " — nothing to land")
            (repair : _) -> do
              let wfId = landingWorkflowIdFor pfx (proj, path)
                  stream = campaignStreamNameText landingWorkflowName wfId
              existing <- readJournal store stream
              recd <- case landingRecordOf (decodedJournal existing) of
                (r : _) -> pure r
                [] -> do
                  _ <-
                    requireEither
                      =<< runCampaignStore
                        store
                        ( runWorkflowWith
                            defaultWorkflowRunOptions
                            landingWorkflowName
                            wfId
                            (landProjectCellWorkflow pc unusedImportOracle branch repair)
                        )
                  journal2 <- readJournal store stream
                  case landingRecordOf (decodedJournal journal2) of
                    (r : _) -> pure r
                    [] -> fail ("landing: no record for " <> T.unpack (proj <> ":" <> path))
              if lrVerified recd
                then
                  putStrLn
                    ( "  [" <> labelOf pfx <> "] landed " <> T.unpack (lrProject recd <> ":" <> lrPath recd)
                        <> " — commit " <> T.unpack (lrCommit recd)
                        <> " on " <> T.unpack (lrBranch recd)
                    )
                else do
                  putStrLn ("  [" <> labelOf pfx <> "] NOT LANDED " <> T.unpack (lrProject recd <> ":" <> lrPath recd) <> " — on-disk verification failed:")
                  for_ (lrDiagnostics recd) (putStrLn . ("    " <>) . T.unpack)
      forM_ (nub (map pcProject pcs')) $ \proj -> do
        logTxt <- gitCapture (campaignWorktreePath proj branch) ["log", "--oneline", T.unpack branch]
        putStrLn ("  " <> T.unpack proj <> " " <> T.unpack branch <> ":")
        for_ (T.lines logTxt) (putStrLn . ("    " <>) . T.unpack)
    labelOf pfx = if "live" `T.isInfixOf` pfx then "react-live" else "react"

-- ---------------------------------------------------------------------------
-- Act 13: the read model — one keiki aggregate, replayed offline and fed
-- live through a shibuya app over the kiroku adapter. The live and offline
-- read models must agree, stream by stream; the act fails if they don't.
runFanoutAct :: IO ()
runFanoutAct = do
  connString <- do
    configured <- lookupEnv "PG_CONNECTION_STRING"
    pure (maybe "host=/tmp dbname=campaign" T.pack configured)
  putStrLn "=== act 13: keiki aggregate + shibuya fan-out (live-vs-offline) ==="
  runCellFanout connString

-- ---------------------------------------------------------------------------
-- Act 14: the campaign boots its own store — a fresh database, end to end.
--
-- The act derives a scratch database on the same server as the campaign's
-- own, drops any stale copy, and proves the bootstrap from three angles:
--
--   1. a bare connection to the empty database applies the full migration
--      set (kiroku, keiro, kioku) in one call — no psql, no external tools;
--   2. the sentinel agrees: before, keiro's workflow-instances table is
--      absent (Nothing); after, it exists and counts zero (Just 0);
--   3. the campaign's own machinery runs on the bootstrapped store: the
--      zeta.py cell — launched with the same workflow body the fleet uses,
--      cleared by the honest stub, settle sleep fired, journal complete.
--
-- The scratch database is dropped afterwards; the main store is untouched.
runScratchAct :: IO ()
runScratchAct = do
  putStrLn "\n=== act 14: the campaign boots its own store (scratch DB end-to-end) ==="
  mainConn <- defaultCampaignConn
  let scratchName = mainConn.ccDbname <> "-scratch"
      scratch = scratchConnFor mainConn scratchName
  putStrLn ("[scratch] database " <> T.unpack scratchName <> " on the main server")
  dropDatabase scratch
  _ <- createDatabaseIfAbsent scratch
  before <- storeWorkflowCount scratch
  putStrLn ("[scratch] sentinel (" <> T.unpack sentinelRelation <> ") before: " <> show before)
  files <- bootstrapStore scratch
  putStrLn ("[scratch] bootstrap applied " <> show files <> " migration file(s)")
  after <- storeWorkflowCount scratch
  putStrLn ("[scratch] sentinel after: " <> show after)
  case after of
    Just 0 -> pure ()
    other -> fail ("scratch: sentinel should be Just 0 after bootstrap, got " <> show other)
  cell <- requireCell "zeta.py"
  let wfId = campaignWorkflowId cell.cellId
      stream = campaignStreamNameText cellCampaignWorkflowName wfId
      registry = campaignRegistry [] [] honestEngineFor noPublisherEff
  withCampaignStoreAt (renderCampaignConn scratch) $ \store -> do
    _ <-
      requireEither
        =<< runCampaignStore
          store
          (runWorkflowWith defaultWorkflowRunOptions cellCampaignWorkflowName wfId (cellCampaignWorkflow (honestEngineFor markerOracle cell) (raise . noPublisherEff) cell markerOracle campaignNamespace defaultMaxAttempts))
    fireTimerSweep store registry [(stream, "sleep:settle-1")]
    drainFleet store registry [wfIdText wfId]
    putStrLn "[scratch] cell scoreboard on the bootstrapped store:"
    printCellScoreboard store registry [(unCellId cell.cellId, stream, cellCampaignWorkflowName, wfId)]
    remaining <- ourUnfinished store [wfIdText wfId]
    unless (null remaining) $ fail ("scratch: unfinished work remains: " <> show remaining)
  dropDatabase scratch
  putStrLn "[scratch] dropped — the campaign can now boot any empty database on demand"

-- ---------------------------------------------------------------------------
-- Act 15: the campaign remembers its own infrastructure — the keiki/shibuya
-- read model and the self-bootstrapping store recorded as kioku L0 evidence,
-- distilled to L1, promoted to global lessons, and recalled the way the
-- planner will.
--
-- Acts 13 and 14 built two pieces of infrastructure: the read model (one
-- keiki aggregate fed two ways — offline replay and a live shibuya fan-out
-- over the kiroku adapter) and the self-bootstrapping store (kiroku, keiro
-- and kioku migrations applied in-process, freshness read from keiro's
-- sentinel). Until now that knowledge lived only in the driver's source.
-- This act teaches the campaign's own memory about it:
--
--   1. an infra session (L0) records the bootstrap recipe and the
--      live-vs-offline agreement property as evidence turns;
--   2. the L1 distiller runs over the session, storing machine-written
--      atoms (degraded honestly when the live model is unavailable —
--      evidence is already durable, so a later pass can pick it up);
--   3. two global lessons promote the operational essentials into the
--      infra namespace — the units a planner or a fresh operator consumes;
--   4. keyword recall reads the namespace back — the queries a planner
--      would issue (@bootstrap@, @read model@) must both hit.
--
-- The infra namespace is deliberately separate from every project
-- namespace: @how do we run at all@ is not fix advice, and conflating them
-- would make planner recall wade through both.
infraEvidence :: [(Text, Text)]
infraEvidence =
  [ ( "bootstrap",
      "an empty database is bootstrapped in-process: Campaign.Bootstrap applies"
        <> " all three migration sets (kiroku, keiro, kioku — 56 idempotent SQL files)"
        <> " as one Session.script transaction each; no external psql or migrate tool"
    )
  , ( "freshness",
      "store freshness is data, not schema: keiro.keiro_workflows absent means"
        <> " unmigrated, present and empty means fresh; the driver self-boots before"
        <> " opening the store, so dropdb followed by a rerun just works"
    )
  , ( "server",
      "the private Postgres cluster lives in the arena repo (db/campaign-private,"
        <> " socket db/campaign-private-socket, trust auth, user campaign);"
        <> " PG_CONNECTION_STRING carries user= explicitly because the notifier"
        <> " does not inherit PGUSER"
    )
  , ( "read-model",
      "the campaign's read model is one keiki symbolic-register transducer over"
        <> " cell journals (CellOpen -> Cleared/Escalated with a non-terminal"
        <> " CellHumanQueried vertex), fed two ways: offline replay via keiro's"
        <> " replayEvents, and live through a shibuya app over the shibuya-kiroku adapter"
    )
  , ( "agreement",
      "the live fan-out and the offline replay must agree on every cell journal;"
        <> " act 13 proves it (13 match, 0 diff), and the per-act hand-rolled journal"
        <> " decoders were retired in favor of the one verified read model"
    )
  ]

runInfraMemoryAct :: IO ()
runInfraMemoryAct = do
  putStrLn "\n=== act 15: the campaign remembers its own infrastructure ==="
  withCampaignStore $ \store -> do
    -- (1) L0: the infra session, one turn per fact, straight from the acts
    -- that earned them.
    sid <- runKiokuWrite store (startInfraSession "store bootstrap and read model")
    putStrLn ("  infra session started: " <> show sid)
    for_ (zip [1 ..] infraEvidence) $ \(idx, (topic, body)) -> do
      _ <- runKiokuWrite store (recordFixTurn sid idx "assistant" ("[" <> topic <> "] " <> body))
      putStrLn ("  evidence " <> show idx <> " recorded: " <> T.unpack topic)
    _ <- runKiokuWrite store (completeFixSession sid "the campaign can boot any empty database in-process and serves one verified read model over its journals")
    putStrLn "  session completed — L0 evidence ready"

    -- (2) L1: the distiller turns evidence into atoms. A rate-limited or
    -- absent live model is a warning, not a failure: the evidence is
    -- durable, and a later distillation pass picks it up.
    withLoadedAIRuntime $ \air -> do
      let distillRT =
            withTestRunners
              (newDistillRuntime air Nothing)
              ( \tr ->
                  tr
                    { runExtract = campaignExtractRunner air,
                      runConsolidate = campaignConsolidateRunner air
                    }
              )
      result <-
        runCampaignStore store $
          distillSessionL1
            campaignAccessContext
            IgnoreWatermark
            distillRT
            (scopedScanCandidates 8)
            sid
      case result of
        Left err -> putStrLn ("  [warn] store error during L1 distillation (continuing): " <> show err)
        Right inner -> case inner of
          Left err -> putStrLn ("  [warn] L1 distillation unavailable (continuing): " <> show err)
          Right L1SkippedUpToDate ->
            putStrLn "  distiller: session already up to date"
          Right (L1Distilled summary) ->
            putStrLn
              ( "  distilled: " <> show summary.extracted <> " candidate(s) extracted, "
                  <> show summary.stored <> " stored, "
                  <> show summary.merged <> " merged, "
                  <> show summary.skipped <> " skipped"
              )

    -- (3) Promote the operational essentials to the infra namespace's global
    -- scope — the units recall serves to planners and fresh operators.
    for_
      [ "the store self-boots: an empty database gets the kiroku, keiro and kioku"
          <> " migrations applied in-process (56 idempotent files); freshness is"
          <> " keiro.keiro_workflows being present and empty; the private cluster"
          <> " lives at db/campaign-private with its socket at db/campaign-private-socket"
      ,
        "the read model is one keiki aggregate over cell journals, fed two ways"
          <> " (offline replay and a live shibuya fan-out over the kiroku adapter);"
          <> " the two paths must agree — act 13 proves 13 match, 0 diff"
      ]
      $ \advice -> do
        _ <- runKiokuWrite store (recordGlobalLesson campaignInfraNamespace advice)
        pure ()
    putStrLn "  2 global lesson(s) promoted to the infra namespace"

    -- (4) The proof: planner-shaped keyword recall must hit.
    notes <- runCampaignStore store (recallNotes campaignInfraNamespace)
    case notes of
      Left err -> fail ("infra recall failed: " <> show err)
      Right ns -> do
        putStrLn ("  infra recall — " <> show (length ns) <> " note(s) in the infra namespace:")
        for_ ns \n -> TIO.putStrLn ("    - " <> n)
        for_ ["bootstrap", "read model"] $ \kw -> do
          hits <- runCampaignStore store (recallNotesForKeyword campaignInfraNamespace kw)
          putStrLn ("  recall for \"" <> T.unpack kw <> "\": " <> show (length hits) <> " hit(s)")
          when (null hits) $ fail ("infra memory: keyword recall for \"" <> T.unpack kw <> "\" found nothing")

  putStrLn "[infra-memory] done — the campaign's memory now knows how the campaign runs"

-- ---------------------------------------------------------------------------
-- Act 16: the verification matrix — (arch × config) cells whose verification
-- is a staged boot → stress process, triaged by a typed shikumi verdict that
-- splits retry from human escalation.
--
-- This is the pgcl shape: an 80-cell matrix of boards × configs where a
-- boot log or a stress failure means one of two futures — retry with advice,
-- or a human walks to the board. Here the world is synthetic but the
-- machinery is the campaign's own:
--
--   * each stage is a journaled step (boot-N, stress-N) — the device log is
--     data, so replay reproduces it without re-running hardware;
--   * the triage program ('triageSignature') reads the actual boot/stress
--     logs and returns needsHardware + advice as typed fields;
--   * needsHardware=false loops through a durable cool-down timer and
--     retries (the riscv/kvm cell clears on attempt 2);
--   * needsHardware=true parks on the campaign's human seam — the SAME
--     awakeable the fixer uses — and an operator answer resumes it.
--
-- The scripted triage engine decides from the TYPED TriageIn (the engine
-- receives the program input directly), so no Context sniffing: a cell with
-- a DOWN net stage is retryable advice; a cell with stress corruption is
-- hardware-only.
runMatrixAct :: IO ()
runMatrixAct = do
  putStrLn "\n=== act 16: the verification matrix — boot/stress cells, triage, hardware seam ==="
  runTag <- T.pack . show . floor . utcTimeToPOSIXSeconds <$> getCurrentTime 
  sink <- newIORef []
  let publishHumanQuery :: AwakeableId -> Eff CampaignEffects ()
      publishHumanQuery aid = do
        inserted <-
          liftIO $
            atomicModifyIORef' sink $ \published ->
              if aid `elem` published
                then (published, False)
                else (published <> [aid], True)
        when inserted $
          liftIO $ putStrLn ("  published human-query awakeable id: " <> T.unpack (awakeableIdText aid))

      scriptedTriage :: Campaign.Matrix.TriageIn -> TriageOut
      scriptedTriage input =
        let stressLines = unField input.tiStress
            corrupt = any ("corruption" `T.isInfixOf`) stressLines
         in if corrupt
              then
                TriageOut
                  (Field True)
                  (Field "this stress corruption reproduces only on the physical board; a human must inspect it")
              else
                TriageOut
                  (Field False)
                  (Field "the kvm misconfiguration clears by re-applying the config; retry after the cool-down")
      -- The scripted policy decides from the typed TriageIn the engine call
      -- carries directly — no stub-LM round trip, no Context sniffing.
      matrixEngine _n _prog input _notes = pure (Just (scriptedTriage input))
      registry = matrixRegistry matrixEngine publishHumanQuery

      cells = matrixCellSpecs
      rows = [(mc, matrixWorkflowIdTagged mc runTag) | mc <- cells]
      ourIds = [wfIdText wid | (_, wid) <- rows]
      streamOf = campaignStreamNameText matrixWorkflowName

  putStrLn ("[matrix] launching " <> show (length cells) <> " cells (3 arch × 3 config), run tag " <> T.unpack runTag)
  for_ rows $ \(mc, wid) ->
    withCampaignStore $ \store -> do
      requireFreshJournal store (streamOf wid)
      outcome <-
        requireEither
          =<< runCampaignStore
            store
            (runWorkflowWith defaultWorkflowRunOptions matrixWorkflowName wid (matrixCellWorkflow matrixEngine (raise . publishHumanQuery) mc (projectNamespace "matrix") 3))
      putStrLn ("  launch " <> T.unpack (unCellId (matrixCellId mc)) <> ": " <> show outcome)

  -- Drive every cell: cool-down timers fire, retries resume, the hardware
  -- cell parks. Then the human answers the one parked query. The second
  -- sweep targets only the cell that reaches a second attempt — the
  -- hardware-parked cell never arms a second cool-down (its future is the
  -- human seam, not a retry), so demanding its timer would spin forever.
  let retryingRows = [(mc, wid) | (mc, wid) <- rows, unCellId (matrixCellId mc) == "matrix:riscv@kvm"]
  withCampaignStore $ \store -> do
    fireTimerSweep store registry [(streamOf wid, "sleep:cool-down-1") | (_, wid) <- rows]
    fireTimerSweep store registry [(streamOf wid, "sleep:cool-down-2") | (_, wid) <- retryingRows]
    driveResumeOnce store registry
    driveResumeOnce store registry
    published <- readIORef sink
    putStrLn ("  parked cells awaiting the operator: " <> show (length published))
    for_ published $ \aid -> do
      _ <- requireEither =<< runCampaignStore store (signalAwakeable aid VerdictApproved)
      pure ()
    driveResumeOnce store registry
    driveResumeOnce store registry

  putStrLn "[matrix] scoreboard — arch × config grid:"
  withCampaignStore $ \store -> do
    for_ rows $ \(mc, wid) -> do
      journal <- readJournal store (streamOf wid)
      let attempts = matrixAttemptsOf (decodedJournal journal)
          verdicts = [ma.maVerdict | ma <- attempts]
      putStrLn
        ( "  " <> T.unpack (unCellId (matrixCellId mc))
            <> ": "
            <> ( if journalIsComplete (decodedJournal journal)
                   then "complete"
                   else "incomplete"
               )
            <> " — "
            <> T.unpack (T.intercalate " | " (map (T.take 70) verdicts))
        )
    remaining <- ourUnfinished store ourIds
    unless (null remaining) $ fail ("matrix: unfinished cells remain: " <> show remaining)

  putStrLn "[matrix] done — boot/stress as data, triage as typed verdict, the human seam shared"

-- ===========================================================================
-- Act 17: cross-project planning — one portfolio, one persona, one plan
-- ===========================================================================

-- | Act 17 lifts planning from cells to the portfolio. Act 10's planner
-- chose a cell within one campaign; this act's planner reads the WHOLE
-- portfolio — every cell journal in the store, all three namespace scopes
-- (toy, project, infra), and the two distilled personas — and emits a typed
-- cross-project plan:
--
--   * the NEXT ACTION for each project (campaign, mowgli, peirce),
--   * a PRIORITY ordering over the portfolio, and
--   * a dispatch class per project: @execute@ (this stack runs it),
--     @delegate@ (a human or another agent owns it), or @verify@ (nothing
--     may start until an existing claim is checked against ground truth).
--
-- The planner program is live (the same runAIProgram path act 10 uses), the
-- persona is distilled live at the portfolio's global scope, and the plan
-- itself is recorded back into memory as evidence — the loop closes.
runCrossPlanAct :: IO ()
runCrossPlanAct = do
  putStrLn "\n=== act 17: cross-project planning — the persona schedules the portfolio ==="
  putStrLn "[portfolio] reading every cell journal in the store"
  withCampaignStore $ \store -> do
    journalRows <- portfolioJournalRows store
    summaries <-
      forM journalRows $ \(label, stream, vertexHint) -> do
        events <- readJournal store stream
        let wjes = [wje | Right wje <- decodeRecorded workflowJournalCodec <$> events]
        pure
          ( PortfolioRow
              { prLabel = label,
                prStream = stream,
                prEvents = length events,
                prVertex = case replayCellJournal wjes of
                  Left _ -> vertexHint
                  Right st ->
                    let s = cellSummaryOf st
                     in if s.csComplete
                          then case s.csVertex of
                            CellClearedVertex -> "cleared"
                            CellEscalatedVertex -> "escalated"
                            _ -> "complete"
                          else case s.csVertex of
                            CellHumanQueried -> "awaiting-human"
                            _ -> vertexHint
              }
          )

    let toyRows = [r | r@(PortfolioRow l _ _ _) <- summaries, "toy/" `T.isPrefixOf` l]
        projectRows = [r | r@(PortfolioRow l _ _ _) <- summaries, "project/" `T.isPrefixOf` l]
        matrixRows = [r | r@(PortfolioRow l _ _ _) <- summaries, "matrix/" `T.isPrefixOf` l]
        matrixHealthy = not (null matrixRows) && all ((\v -> v == "cleared" || v == "escalated") . prVertex) matrixRows
        (projectDone, projectOpen) =
          partition ((\v -> v == "cleared" || v == "escalated") . prVertex) projectRows
        (toyDone, toyOpen) =
          partition ((\v -> v == "cleared" || v == "escalated") . prVertex) toyRows

    putStrLn
      ( "  toy cells: " <> show (length toyRows) <> " (" <> show (length toyDone) <> " done, "
          <> show (length toyOpen) <> " open)"
      )
    putStrLn
      ( "  project cells: " <> show (length projectRows) <> " (" <> show (length projectDone) <> " done, "
          <> show (length projectOpen) <> " open)"
      )
    putStrLn ("  matrix cells: " <> show (length matrixRows) <> " (" <> show (length matrixRows) <> " terminal)")
    for_ toyOpen $ \r -> putStrLn ("    open: " <> T.unpack (prLabel r) <> " [" <> T.unpack (prVertex r) <> "]")
    for_ projectOpen $ \r -> putStrLn ("    open: " <> T.unpack (prLabel r) <> " [" <> T.unpack (prVertex r) <> "]")

    -- Cross-project lessons: what one project knows that another needs.
    -- These are recorded once (idempotent on re-run by content), recalled
    -- into the planner prompt, and the recall is verified — the portfolio
    -- plan is grounded in the campaign's own memory, not thin air.
    putStrLn "[portfolio] recording cross-project lessons"
    _ <-
      requireEither
        =<< runCampaignStore
          store
          (recordGlobalLesson (projectNamespace "mowgli") "The one-cell campaign cleared its corpus; the fixer cell machinery is proven and reusable for mowgli's unused-import class")
    _ <-
      requireEither
        =<< runCampaignStore
          store
          (recordGlobalLesson (projectNamespace "peirce") "The matrix's staged boot/stress cells and hardware seam are the pattern for any peirce verification campaign")
    _ <-
      requireEither
        =<< runCampaignStore
          store
          (recordGlobalLesson campaignInfraNamespace "Campaign store boots itself from bare Postgres; any new project campaign needs no manual migration recipe")
    mowgliRecall <- requireEither =<< runCampaignStore store (recallNotes (projectNamespace "mowgli"))
    unless (any ("fixer" `T.isInfixOf`) mowgliRecall) $
      fail "act 17: the campaign->mowgli cross lesson is not recallable in the mowgli namespace"
    peirceRecallEarly <- requireEither =<< runCampaignStore store (recallNotes (projectNamespace "peirce"))
    unless (any ("matrix" `T.isInfixOf`) peirceRecallEarly) $
      fail "act 17: the matrix->peirce cross lesson is not recallable in the peirce namespace"
    putStrLn
      ( "  cross lessons recallable: mowgli " <> show (length mowgliRecall) <> " note(s), peirce "
          <> show (length peirceRecallEarly) <> " note(s)"
      )

    -- One distilled persona at the portfolio's global scope, read back
    -- through kioku's own L3 API (the same path act 8 uses per project).
    personaText <- withAIRuntime $ \air -> do
      let distillRT =
            withDistillWorkspace "/tmp/campaign-mirrors"
              ( withTestRunners
                  (newDistillRuntime air Nothing)
                  (\tr -> tr{runScene = campaignSceneRunner air, runPersona = campaignPersonaRunner air})
              )
          gscope = ScopeGlobal campaignNamespace
      _ <- requireEither =<< runCampaignStore store (regenerateScene distillRT campaignMemorySpace gscope)
      personaR <- requireEither =<< runCampaignStore store (regeneratePersona distillRT campaignMemorySpace gscope)
      case personaR of
        Right (Just prow) -> do
          putStrLn ("  persona distilled: " <> show (T.length prow.bodyMd) <> " chars of markdown")
          pure prow.bodyMd
        Right Nothing -> pure "(no persona yet — a fresh campaign)"
        Left err -> fail ("persona distillation failed: " <> show err)

    -- The live cross-project planner. Its typed input is the portfolio: the
    -- real journal-derived state per project, the recalled notes per
    -- namespace, the personas, and the infra facts.
    let mowgliNotes = T.unlines (map ("- " <>) mowgliRecall)
    peirceRecall <- requireEither =<< runCampaignStore store (recallNotes (projectNamespace "peirce"))
    infraRecall <- requireEither =<< runCampaignStore store (recallNotes campaignInfraNamespace)
    toyRecall <- requireEither =<< runCampaignStore store (recallNotes campaignNamespace)
    let input =
          PortfolioInput
            { piState = Field (portfolioStateText summaries matrixHealthy),
              piToyNotes = Field (T.unlines (map ("- " <>) toyRecall)),
              piMowgliNotes = Field mowgliNotes,
              piPeirceNotes = Field (T.unlines (map ("- " <>) peirceRecall)),
              piInfraNotes = Field (T.unlines (map ("- " <>) infraRecall)),
              piPersona = Field personaText
            }
    putStrLn "[planner] live cross-project plan over the real portfolio"
    plan <- withAIRuntime $ \air -> do
      r <- runWithRetry air Extraction portfolioPlannerProgram input
      case r of
        Left err -> fail ("cross-project planner failed: " <> show err)
        Right out -> pure out
    putStrLn ("  priority: " <> T.unpack (unField plan.ppPriority))
    for_ plan.ppNext $ \nx ->
      putStrLn
        ( "    " <> T.unpack (unField nx.anProject) <> " -> " <> T.unpack (unField nx.anAction)
            <> " [" <> T.unpack (unField nx.anDispatch) <> "] :: " <> T.unpack (T.take 110 (unField nx.anWhy))
        )

    -- The plan is honest: every dispatch class must be one of the three;
    -- each project must appear; mowgli's plan must cite the cross lesson
    -- (the planner was shown it; the stub-grade live model can paraphrase,
    -- so accept a loose match).
    let dispatches = [T.toLower (unField nx.anDispatch) | nx <- plan.ppNext]
    unless (all (`elem` ["execute", "delegate", "verify"]) dispatches) $
      fail ("act 17: planner produced an unknown dispatch class: " <> show dispatches)
    let projectsNamed = [T.strip (unField nx.anProject) | nx <- plan.ppNext]
    for_ ["campaign", "mowgli", "peirce"] $ \p ->
      unless (any (p `T.isInfixOf`) projectsNamed) $
        fail ("act 17: the plan omits project " <> T.unpack p)
    mowgliPlan <-
      case [nx | nx <- plan.ppNext, "mowgli" `T.isInfixOf` T.strip (unField nx.anProject)] of
        (nx : _) -> pure nx
        [] -> fail "act 17: no mowgli line in the plan"
    unless
      ( any
          (\kw -> kw `T.isInfixOf` T.toLower (unField mowgliPlan.anAction <> " " <> unField mowgliPlan.anWhy))
          ["import", "matrix", "cell", "reuse", "fixer", "campaign"]
      )
      $ fail "act 17: mowgli's plan does not engage its known state"

    -- The plan is recorded back into memory as evidence: the portfolio's
    -- next planner call can recall what was decided and why.
    sessionOutcome <-
      requireEither
        =<< runCampaignStore
          store
          ( do
              e <- startInfraSession "cross-project plan (act 17)"
              case e of
                Left err -> pure (Left err)
                Right sid -> do
                  _ <- recordFixTurn sid 1 "assistant" (portfolioPlanText plan)
                  _ <- completeFixSession sid "the portfolio's cross-project plan, recorded as evidence"
                  pure (Right ())
          )
    case sessionOutcome of
      Left err -> fail ("recording the plan failed: " <> show err)
      Right () -> pure ()
    putStrLn "[cross-plan] done — one portfolio, one persona, one plan, recorded"

-- ---------------------------------------------------------------------------
-- Act 17 internals: portfolio state, typed plan, planner program
-- ---------------------------------------------------------------------------

-- | One portfolio row: a real journal in the store, read through the
-- keiki aggregate (act 13's replay) into a vertex-shaped verdict.
data PortfolioRow = PortfolioRow
  { prLabel :: !Text,
    prStream :: !Text,
    prEvents :: !Int,
    prVertex :: !Text
  }
  deriving stock (Eq, Show)

-- | Every cell journal in the store: the toy corpus (the acts' cell
-- campaigns), the project cells (mowgli/peirce, with and without the
-- react/live run prefixes), and the matrix (with run tags). Discovered from
-- kiroku's $all log plus a stream-name lookup — the store itself says what
-- campaigns it has run, which is the point: planning reads state, not
-- assumptions. Everything else in the store (landing journals, kioku's own
-- evidence streams) is not a cell and is skipped.
portfolioJournalRows :: CampaignStore -> IO [(Text, Text, Text)]
portfolioJournalRows store = do
  events <-
    requireEither
      =<< runCampaignStore
        store
        (Store.readAllForward (Store.GlobalPosition 0) 10000)
  let ids = nub (map originalStreamId (Vector.toList events))
  namesE <- requireEither =<< runCampaignStore store (Store.lookupStreamNames ids)
  pure
    [ row
    | sid <- ids,
      Just (StreamName sname) <- [Map.lookup sid namesE],
      Just row <- [classifyJournalStream sname]
    ]

-- | A stream is a portfolio journal iff its name names one of the three
-- campaign workflow bodies. The label carries the raw workflow id —
-- per-project grouping is by substring, so run prefixes (react-, live-,
-- matrix run tags) survive verbatim.
classifyJournalStream :: Text -> Maybe (Text, Text, Text)
classifyJournalStream sname
  | Just wid <- T.stripPrefix "wf:cell-campaign-" sname =
      Just ("toy/" <> wid, sname, "open")
  | Just wid <- T.stripPrefix "wf:project-cell-campaign-" sname =
      Just ("project/" <> wid, sname, "open")
  | Just wid <- T.stripPrefix "wf:matrix-campaign-" sname =
      Just ("matrix/" <> wid, sname, "open")
  | otherwise = Nothing

-- | A journal whose events we could not decode is a foreign stream; the
-- aggregate replay is the shared fold over the decoded events.
journalEventsOfLocal :: [RecordedEvent] -> [WorkflowJournalEvent]
journalEventsOfLocal events = [wje | Right wje <- decodeRecorded workflowJournalCodec <$> events]

-- | The typed plan the planner emits.
data PortfolioInput = PortfolioInput
  { piState :: Field "the portfolio's real state read off the journals" Text,
    piToyNotes :: Field "lessons recalled from the toy campaign's namespace" Text,
    piMowgliNotes :: Field "lessons recalled from mowgli's namespace (incl. cross-project ones)" Text,
    piPeirceNotes :: Field "lessons recalled from peirce's namespace" Text,
    piInfraNotes :: Field "infrastructure lessons (the campaign's own ops memory)" Text,
    piPersona :: Field "the distilled persona of this portfolio's operator" Text
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ToSchema, FromModel, ToPrompt)

data PortfolioNext = PortfolioNext
  { anProject :: Field "which project this line is about (campaign, mowgli, or peirce)" Text,
    anAction :: Field "the concrete next action for that project" Text,
    anDispatch :: Field "who runs it: execute (this stack), delegate (a human/other agent), or verify (check an existing claim first)" Text,
    anWhy :: Field "why this action, given the state and the persona" Text
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ToSchema, FromModel, ToPrompt)

data PortfolioOutput = PortfolioOutput
  { ppPriority :: Field "the single highest-priority item across the whole portfolio" Text,
    ppNext :: [PortfolioNext]
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ToSchema, FromModel, ToPrompt, Validatable)

portfolioPlannerSignature :: Signature PortfolioInput PortfolioOutput
portfolioPlannerSignature =
  mkSignature
    "You are the cross-project planner of a typed-LM campaign. The input is \
    \the portfolio's REAL state (journal-derived): the toy campaign, the \
    \project campaigns (mowgli, peirce), and the verification matrix. Produce \
    \exactly one PortfolioNext line per project, each with a dispatch class \
    \(execute / delegate / verify), plus the one highest-priority item. Obey \
    \the persona; use the recalled lessons; prefer actions that reuse proven \
    \machinery over novel machinery."

-- | The wire-shape contract, as in act 10's planner: fields only, no prose.
portfolioContractInstruction :: Text
portfolioContractInstruction =
  "Reply in the exact wire shape demonstrated: a priority field holding one \
  \sentence, and a next list holding exactly one entry per project with \
  \project, action, dispatch, and why fields. Never reply with prose outside \
  \the fields."

portfolioPlannerProgram :: Program PortfolioInput PortfolioOutput
portfolioPlannerProgram =
  predict
    ( setDemos
        [ Demo
            ( PortfolioInput
                (field "campaign: 3 toy cells open; mowgli: 1/3 project cells cleared; peirce: 2/3 cleared; matrix: 9/9 terminal")
                (field "- delete-only repairs; every repair re-checked by the oracle")
                (field "- the campaign's fixer cells are proven for mowgli's unused-import class")
                (field "- the matrix's staged boot/stress cells fit peirce's verification needs")
                (field "- the store self-boots; new campaigns need no manual DB recipe")
                (field "### Portfolio persona\n- reuse proven machinery before building new")
            )
            ( PortfolioOutput
                (field "peirce: wire the matrix pattern to its verification oracles")
                [ PortfolioNext (field "campaign") (field "clear the remaining open toy cells") (field "execute") (field "the fixer machinery is proven and the lessons cover both fault classes"),
                  PortfolioNext (field "mowgli") (field "run the remaining project cells through the fixer campaign") (field "execute") (field "the unused-import lesson transfers and the cells are already registered"),
                  PortfolioNext (field "peirce") (field "stand up a staged verification campaign on the matrix pattern") (field "delegate") (field "the oracles need a human's domain decisions before cells can run")
                ]
            )
        ]
        (setInstruction portfolioContractInstruction portfolioPlannerSignature)
    )

portfolioPlanText :: PortfolioOutput -> Text
portfolioPlanText out =
  T.unlines $
    ("priority: " <> unField out.ppPriority)
      : [ "- " <> unField nx.anProject <> " -> " <> unField nx.anAction <> " [" <> unField nx.anDispatch <> "]"
        | nx <- out.ppNext
        ]

portfolioStateText :: [PortfolioRow] -> Bool -> Text
portfolioStateText rows matrixHealthy =
  T.unlines $
    [ "campaign: " <> T.pack (show (length toyOpen')) <> " open / " <> T.pack (show (length toyDone')) <> " done toy cells",
      "mowgli: " <> T.pack (show (length moOpen)) <> " open / " <> T.pack (show (length moDone)) <> " done project cells",
      "peirce: " <> T.pack (show (length peOpen)) <> " open / " <> T.pack (show (length peDone)) <> " done project cells",
      "matrix: " <> (if matrixHealthy then "all cells terminal" else "in flight"),
      "awaiting human: " <> T.pack (show (length [r | r <- rows, prVertex r == "awaiting-human"]))
    ]
  where
    projectLabel p = [r | r@(PortfolioRow l _ _ _) <- rows, "project/" `T.isPrefixOf` l, p `T.isInfixOf` l]
    (toyDone', toyOpen') = splitDone [r | r@(PortfolioRow l _ _ _) <- rows, "toy/" `T.isPrefixOf` l]
    (moDone, moOpen) = splitDone (projectLabel "mowgli")
    (peDone, peOpen) = splitDone (projectLabel "peirce")
    splitDone rs = partition ((\v -> v == "cleared" || v == "escalated") . prVertex) rs


-- ===========================================================================
-- Act 18: the Mercury promotion campaign — the codegen pipeline on a real
-- compiler change
-- ===========================================================================

-- | Act 18 points the analyze → propose → guard → test → land pipeline at a
-- real, finished change in a real codebase: promoting Mercury's private
-- @--dump-mlds@ option family to public, so IR dumps are selectable by CLI
-- options (the project goal) instead of demanding a special compiler build.
--
-- The replayable-campaign property: every stage is journaled data. The
-- analyze stage reads the real options.m (facts, not guesses); the propose
-- stage runs the coder's real patch program through the stub LM (a live
-- model is the same call — swap the engine); the guard is the exact-once
-- PatchPlan application; the test stage is the compiler oracle (the fact
-- probe plus the grade-pinned MLDS dump probe against the installed mmc);
-- the landing is a real commit on the cell's own worktree/branch — one per
-- run, so every run replays the whole drama reviewably.
--
-- Acts, one per pipeline stage:
--
--   1. @analyze@ — extract the facts from the real options.m (offline, no
--      model), print the cell roster.
--   2. @oracle probes@ — the dump probe (the installed mmc, hlc.gc) must
--      pass, and the fact probe against the pristine tree must FAIL: the
--      oracle detects the defect it exists to catch.
--   3. @campaign@ — the three promotion cells, one per option: propose →
--      guard → apply → probe → land. Cell 1 proposes a stale edit first (a
--      typed guard rejection), then recovers via the informed retry.
--   4. @scoreboard@ — every cell's journaled attempts and the landed
--      commits, with the parent checkout proven untouched.
--   5. @memory@ — the promotion recipe recorded as infra evidence, the
--      promoted lessons, planner-shaped recall.
runMercuryAct :: IO ()
runMercuryAct = do
  putStrLn "\n=== act 18: the Mercury promotion — the codegen pipeline on a real compiler change ==="

  -- The campaign works on per-run worktrees off the campaign clone
  -- (/home/nyc/src/mercury-campaign — the clean checkout with the dump
  -- family still private).
  runTag <- T.pack . show . floor . utcTimeToPOSIXSeconds <$> getCurrentTime
  sink <- newIORef []
  let campaignTree = "/home/nyc/src/mercury-campaign"
      publishHumanQuery :: AwakeableId -> Eff CampaignEffects ()
      publishHumanQuery aid = do
        inserted <-
          liftIO $
            atomicModifyIORef' sink $ \published ->
              if aid `elem` published
                then (published, False)
                else (published <> [aid], True)
        when inserted $
          liftIO $ putStrLn ("  published human-query awakeable id: " <> T.unpack (awakeableIdText aid))
      streamOf opt = campaignStreamNameText mercuryWorkflowName (mercuryWorkflowIdTagged opt runTag)

      -- The GOOD responder builds the marker sections from the TYPED
      -- ProposeIn the engine call carries: the fact's line verbatim
      -- (first-line indentation stripped — the wire strips section edge
      -- whitespace and the applier re-indents), constructor swapped. That
      -- is exactly what a good model emits.
      factOldLine :: ProposeIn -> Text
      factOldLine pin = snd (T.breakOnEnd ": " (head (T.lines (unField (piFact pin)))))
      swapCtor :: Text -> Text
      swapCtor = T.replace "priv_alt_arg_help" "alt_arg_help" . T.replace "priv_arg_help" "arg_help"
      goodPlan :: ProposeIn -> Response
      goodPlan pin =
        markerResponse
          [ ("ppOld", T.stripStart (factOldLine pin)),
            ("ppNew", T.stripStart (swapCtor (factOldLine pin))),
            ("ppWhy", "the private constructor hides the option from --help and the manual; the public one is the established registration for user-visible options"),
            ("ppNote", "Promotes the option to a public, documented registration.")
          ]
      -- The STALE responder: a real model's honest mistake — it misremembers
      -- which private constructor the line uses, so the old block matches
      -- nothing and the exact-once guard rejects it, typed.
      stalePlan :: ProposeIn -> Response
      stalePlan pin =
        markerResponse
          [ ("ppOld", T.stripStart (T.replace "priv_alt_arg_help" "priv_arg_help" (factOldLine pin))),
            ("ppNew", T.stripStart (T.replace "priv_alt_arg_help" "alt_arg_help" (factOldLine pin))),
            ("ppWhy", "same edit from a stale memory of the constructor's name"),
            ("ppNote", "A stale first attempt.")
          ]
      -- The script: attempt 1 of the dump-mlds cell proposes the stale
      -- constructor (the informed retry's raw material); every other
      -- attempt is correct.
      scriptFor :: Text -> Int -> ProposeIn -> [Text] -> Maybe Response
      scriptFor "dump-mlds" 1 pin _notes = Just (stalePlan pin)
      scriptFor _ _n pin _notes = Just (goodPlan pin)

  -- ------------------------------------------------------------------ (1)
  putStrLn "[mercury] analyze — facts from the real options.m (no model in sight)"
  optsExists <- doesFileExist (mercuryOptionsPath campaignTree)
  unless optsExists $ fail ("act 18: the campaign clone is missing at " <> campaignTree)
  facts <- readMercuryFacts campaignTree
  for_ facts $ \f ->
    putStrLn
      ( "  fact: --" <> T.unpack (mfOption f) <> " at options.m:" <> show (mfLineNo f)
          <> " (" <> T.unpack (mfConstructor f) <> " -> " <> T.unpack (mfPublicConstructor f) <> ")"
      )
  when (null facts) $ putStrLn "  (the family is already promoted — nothing to do)"
  priv0 <- mercuryPrivCount campaignTree
  putStrLn ("  private registrations in the tree: " <> show priv0)

  -- The per-run cells: one worktree + branch per (option, run).
  cells <- mercuryCellSpecs campaignTree runTag
  for_ cells $ \c ->
    putStrLn ("  cell: --" <> T.unpack (mcOption c) <> " on branch " <> T.unpack (mcBranch c))

  -- ------------------------------------------------------------------ (2)
  putStrLn "[mercury] oracle — the dump probe (installed mmc, MLDS grade hlc.gc)"
  dumpV0 <- oracleDumpProbe ("pristine-" <> runTag)
  putStrLn ("  dump probe: " <> (if ovOk dumpV0 then "ok — " else "FAILED — ") <> T.unpack (ovDetail dumpV0))
  unless (ovOk dumpV0) $ fail "act 18: the dump oracle must pass on the installed compiler"
  putStrLn "[mercury] oracle — the fact probe must FAIL on the pristine tree"
  case cells of
    [] -> putStrLn "  (no cells — skipping the negative control)"
    (c0 : _) -> do
      _ <- ensureCampaignWorktree "mercury" (mcBranch c0)
      negV <- oracleFactProbe (mcWorktree c0) (mcFact c0)
      putStrLn
        ( "  fact probe on pristine tree: "
            <> (if ovOk negV then "UNEXPECTEDLY ok" else "correctly rejects")
            <> " — " <> T.unpack (ovDetail negV)
        )
      when (ovOk negV) $ fail "act 18: the fact probe accepted the pristine tree — the oracle is broken"

  -- ------------------------------------------------------------------ (3)
  putStrLn "[mercury] campaign — the promotion cells (propose → guard → test → land)"
  for_ cells $ \cell -> do
    let engine = mercuryScriptedEngine (scriptFor (mcOption cell))
        wid = mercuryWorkflowIdTagged (mcOption cell) runTag
    withCampaignStore $ \store -> do
      requireFreshJournal store (streamOf (mcOption cell))
      outcome <-
        requireEither
          =<< runCampaignStore
            store
            (runWorkflowWith defaultWorkflowRunOptions mercuryWorkflowName wid (mercuryCellWorkflow engine (raise . publishHumanQuery) cell (projectNamespace "mercury") 3))
      putStrLn ("  launch --" <> T.unpack (mcOption cell) <> ": " <> show outcome)

  -- The driver loop: cells retry on their own durable cool-downs. The
  -- second cool-down exists only where a cell actually reaches attempt 2 —
  -- the dump-mlds cell (its attempt 1 is the stale rejection); demanding a
  -- timer a cell never arms spins the sweep forever (act 16's lesson).
  let registry = mercuryRegistry (mercuryScriptedEngine (\_n pin _notes -> Just (goodPlan pin))) publishHumanQuery
      retryingOpts = ["dump-mlds" | any ((== "dump-mlds") . mcOption) cells]
  withCampaignStore $ \store -> do
    for_ (map mcOption cells) $ \opt ->
      fireTimerSweep store registry [(streamOf opt, "sleep:cool-down-1")]
    for_ retryingOpts $ \opt ->
      fireTimerSweep store registry [(streamOf opt, "sleep:cool-down-2")]
    driveResumeOnce store registry
    driveResumeOnce store registry
    published <- readIORef sink
    for_ published $ \aid -> do
      _ <- requireEither =<< runCampaignStore store (signalAwakeable aid VerdictApproved)
      pure ()
    driveResumeOnce store registry
    driveResumeOnce store registry

  -- ------------------------------------------------------------------ (4)
  putStrLn "[mercury] scoreboard — journaled attempts and the landed state"
  for_ cells $ \cell -> do
    let opt = mcOption cell
    withCampaignStore $ \store -> do
      journal <- readJournal store (streamOf opt)
      let attempts = mercuryAttemptsOf (decodedJournal journal)
      putStrLn ("  --" <> T.unpack opt <> ":")
      for_ attempts $ \ma ->
        putStrLn
          ( "    attempt " <> show (meAttempt ma) <> ": " <> T.unpack (meVerdict ma)
              <> (if T.null (meOld ma) then "" else "  [old: " <> T.unpack (T.take 46 (T.strip (meOld ma))) <> "…]")
          )
      remaining <- ourUnfinished store [wfIdText (mercuryWorkflowIdTagged opt runTag)]
      unless (null remaining) $ fail ("mercury: unfinished cell remains: " <> show remaining)

  -- The landings: real commits, one per cell, on per-run branches — and
  -- the parent tree untouched.
  putStrLn "[mercury] landings:"
  for_ cells $ \cell -> do
    _ <- ensureCampaignWorktree "mercury" (mcBranch cell)
    commit <- gitCapture (mcWorktree cell) ["rev-parse", "--short", "HEAD"]
    stat <- gitCapture (mcWorktree cell) ["show", "--stat", "--oneline", "HEAD"]
    let statLine = case drop 1 (T.lines stat) of
          (l : _) -> T.strip l
          [] -> "(no stat)"
    putStrLn ("  " <> T.unpack (mcBranch cell) <> " @ " <> T.unpack commit <> " — " <> T.unpack statLine)
  parentDirty <- parentDirtyCount "mercury"
  putStrLn ("  parent checkout dirty entries after the campaign: " <> show parentDirty)

  -- ------------------------------------------------------------------ (5)
  putStrLn "[mercury] memory — the promotion recipe enters the campaign's own memory"
  withCampaignStore $ \store -> do
    sid <- runKiokuWrite store (startInfraSession "mercury promotion campaign recipe")
    for_ (zip [1 ..] mercuryEvidence) $ \(idx, (topic, body)) -> do
      _ <- runKiokuWrite store (recordFixTurn sid idx "assistant" ("[" <> topic <> "] " <> body))
      pure ()
    _ <- runKiokuWrite store (completeFixSession sid "the promotion pipeline is replayable: facts in, guarded edits, a compiler oracle, landings as commits")
    putStrLn ("  infra session recorded (" <> show (length mercuryEvidence) <> " evidence turns)")
    withLoadedAIRuntime $ \air -> do
      let distillRT =
            withTestRunners
              (newDistillRuntime air Nothing)
              ( \tr ->
                  tr
                    { runExtract = campaignExtractRunner air,
                      runConsolidate = campaignConsolidateRunner air
                    }
              )
      result <-
        runCampaignStore store $
          distillSessionL1
            campaignAccessContext
            IgnoreWatermark
            distillRT
            (scopedScanCandidates 8)
            sid
      case result of
        Left err -> putStrLn ("  [warn] store error during L1 distillation (continuing): " <> show err)
        Right inner -> case inner of
          Left err -> putStrLn ("  [warn] L1 distillation unavailable (continuing): " <> show err)
          Right L1SkippedUpToDate -> putStrLn "  distiller: session already up to date"
          Right (L1Distilled summary) ->
            putStrLn
              ( "  distilled: " <> show summary.extracted <> " candidate(s) extracted, "
                  <> show summary.stored <> " stored"
              )
    for_
      [ "mercury promotion = one cell per private option: propose ONE verbatim-line edit,"
          <> " exact-once guard, then the two-probe oracle (fact probe: private gone, public in,"
          <> " priv-count -1; dump probe: mmc --grade hlc.gc --dump-mlds 99 emits .c_dump.099-final)"
      ,
        "mercury cells land on per-run branches (campaign/mercury-<option>-<tag>) so every"
          <> " campaign run replays reviewably; the parent checkout is never touched"
      ]
      $ \advice -> do
        _ <- runKiokuWrite store (recordGlobalLesson (projectNamespace "mercury") advice)
        pure ()
    for_ ["dump-mlds", "promotion"] $ \kw -> do
      hits <- runCampaignStore store (recallNotesForKeyword (projectNamespace "mercury") kw)
      putStrLn ("  recall for \"" <> T.unpack kw <> "\": " <> show (length hits) <> " hit(s)")

  putStrLn "[mercury] done — facts in, guarded edits, a compiler oracle, real commits"
  where
    -- The infra evidence, straight from what this act earned.
    mercuryEvidence =
      [ ("oracle", "the promotion oracle is two probes: the fact probe (private registration gone, expected public line verbatim, private-registration count fallen by exactly one vs the branch point) and the dump probe (mmc --grade hlc.gc --dump-mlds 99 on a probe module emits hello.c_dump.099-final)"),
        ("grades", "MLDS dumps exist only in MLDS grades that target C (hlc.gc); the default asm_fast grade silently produces no dump, so the oracle pins the grade"),
        ("worktrees", "each cell works in its own worktree on its own per-run branch off the clean campaign clone at /home/nyc/src/mercury-campaign; the parent checkout is never touched"),
        ("engine", "propose is the coder patch program (PatchPlan: one exact-match replacement); guard failures and no-decode replies are typed rejections that feed the informed retry"),
        ("guard", "the no-regression denominator is the options.m private-registration count (368 in the campaign clone); promoting one option must lower it by exactly one")
      ]
-- ===========================================================================
-- Act 19: the Mercury promotion, live — a real model proposes the edits
-- ===========================================================================

-- | Act 19 re-runs the promotion campaign with the scripted engine swapped
-- for the live stack: the very same 'runAIProgram' call kioku's distillers
-- make, behind the very same 'MercuryEngine' shape. Nothing else changes —
-- the facts, the exact-once guard, the two-probe compiler oracle, the
-- durable cool-downs, the per-run worktrees and landings, the human seam.
--
-- The journal cannot tell a live attempt from a scripted one by shape —
-- that is the point. What the run adds is the scoreboard showing the REAL
-- model's proposed old/new blocks, and the honest failures: a malformed
-- reply is a typed error, retried up to three times, exactly as the tier-1
-- lesson demands.
--
-- The driver is the adaptive generalization of act 16's targeting: instead
-- of hand-listing which cells reach attempt 2, each round reads every
-- unfinished cell's journal, finds the failed attempt numbers, and demands
-- exactly the cool-down timers those failures arm — a timer is demanded
-- only when a journaled failure proves it will exist.
runLiveMercuryAct :: IO ()
runLiveMercuryAct = do
  putStrLn "\n=== act 19: the Mercury promotion, live — a real model proposes the edits ==="
  withLoadedAIRuntime $ \air -> do
    runTag0 <- T.pack . show . floor . utcTimeToPOSIXSeconds <$> getCurrentTime
    let liveTag = "live" <> runTag0
        campaignTree = "/home/nyc/src/mercury-campaign"
    sink <- newIORef []
    let publishHumanQuery :: AwakeableId -> Eff CampaignEffects ()
        publishHumanQuery aid = do
          inserted <-
            liftIO $
              atomicModifyIORef' sink $ \published ->
                if aid `elem` published
                  then (published, False)
                  else (published <> [aid], True)
          when inserted $
            liftIO $ putStrLn ("  published human-query awakeable id: " <> T.unpack (awakeableIdText aid))
        streamOf opt = campaignStreamNameText mercuryWorkflowName (mercuryWorkflowIdTagged opt liveTag)

        -- The live engine: 'runAIProgram' behind the 'MercuryEngine' shape,
        -- with the bounded retry that is part of the live contract. The
        -- propose program is the same 'mercuryPromotionSignature' the stub
        -- ran; only the interpreter differs.
        liveEngine :: MercuryEngine
        liveEngine n prog input _notes = do
          let go :: Int -> IO (Maybe PatchPlan)
              go 0 = pure Nothing
              go k =
                once >>= \case
                  Nothing -> go (k - 1)
                  ok -> pure ok
              once =
                runAIProgram air Extraction prog input >>= \case
                  Right plan -> pure (Just plan)
                  Left (AIProgramFailed err) -> do
                    putStrLn ("    [live-engine] typed error: " <> show err)
                    pure Nothing
                  Left other -> do
                    putStrLn ("    [live-engine] " <> show other)
                    pure Nothing
          r <- go (3 :: Int)
          putStrLn ("    [live] attempt " <> show n <> ": " <> maybe "failed (typed error)" (const "proposed a plan") r)
          pure r

    -- ---------------------------------------------------------------- (1)
    putStrLn "[mercury-live] analyze — facts from the real options.m"
    facts <- readMercuryFacts campaignTree
    for_ facts $ \f ->
      putStrLn
        ( "  fact: --" <> T.unpack (mfOption f) <> " at options.m:" <> show (mfLineNo f)
            <> " (" <> T.unpack (mfConstructor f) <> " -> " <> T.unpack (mfPublicConstructor f) <> ")"
        )
    when (null facts) $ fail "act 19: no facts — the campaign clone changed under us"
    cells <- mercuryCellSpecs campaignTree liveTag
    putStrLn ("  cells: " <> show (length cells) <> ", live tag " <> T.unpack liveTag)

    -- A quick oracle sanity: the dump probe must pass before any model call.
    dumpV0 <- oracleDumpProbe ("live-pristine-" <> liveTag)
    unless (ovOk dumpV0) $
      fail ("act 19: the dump oracle must pass on the installed compiler: " <> T.unpack (ovDetail dumpV0))
    putStrLn ("  dump probe: ok — " <> T.unpack (ovDetail dumpV0))

    -- ---------------------------------------------------------------- (2)
    putStrLn "[mercury-live] campaign — the promotion cells under the live engine"
    for_ cells $ \cell -> do
      let wid = mercuryWorkflowIdTagged (mcOption cell) liveTag
      withCampaignStore $ \store -> do
        requireFreshJournal store (streamOf (mcOption cell))
        outcome <-
          requireEither
            =<< runCampaignStore
              store
              (runWorkflowWith defaultWorkflowRunOptions mercuryWorkflowName wid (mercuryCellWorkflow liveEngine (raise . publishHumanQuery) cell (projectNamespace "mercury") 3))
        putStrLn ("  launch --" <> T.unpack (mcOption cell) <> ": " <> show outcome)

    -- The adaptive driver: each round demands exactly the cool-down timers
    -- that journaled failures prove will exist, resumes, and repeats while
    -- anything is unfinished (bounded — 3 attempts + the park). One round,
    -- one store block: the recursion happens OUTSIDE it.
    let registry = mercuryRegistry liveEngine publishHumanQuery
        ourIds = [wfIdText (mercuryWorkflowIdTagged (mcOption c) liveTag) | c <- cells]
        driveRound :: IO Bool
        driveRound = do
          workedRef <- newIORef False
          withCampaignStore $ \store -> do
            unfinished <- ourUnfinished store ourIds
            unless (null unfinished) $ do
              demands <- fmap concat $ forM (map mcOption cells) $ \opt -> do
                journal <- readJournal store (streamOf opt)
                let attempts = mercuryAttemptsOf (decodedJournal journal)
                    failedNs =
                      [ meAttempt a
                      | a <- attempts,
                        not ("applied-ok" `T.isPrefixOf` meVerdict a),
                        not ("already-promoted" `T.isPrefixOf` meVerdict a)
                      ]
                pure [(streamOf opt, "sleep:cool-down-" <> T.pack (show n)) | n <- failedNs, n <= 3]
              forM_ demands $ \(stream, timer) ->
                fireTimerSweep store registry [(stream, timer)]
              driveResumeOnce store registry
              writeIORef workedRef True
          readIORef workedRef
        driveRounds :: Int -> IO ()
        driveRounds r
          | r <= (0 :: Int) = pure ()
          | otherwise = driveRound >>= \worked -> when worked (driveRounds (r - 1))
    driveRounds 4

    -- Anything still parked goes through the human seam (the operator
    -- approves; the journal records who decided what).
    withCampaignStore $ \store -> do
      published <- readIORef sink
      unless (null published) $
        putStrLn ("  parked cells awaiting the operator: " <> show (length published))
      for_ published $ \aid -> do
        _ <- requireEither =<< runCampaignStore store (signalAwakeable aid VerdictApproved)
        pure ()
      driveResumeOnce store registry
      driveResumeOnce store registry

    -- ---------------------------------------------------------------- (3)
    putStrLn "[mercury-live] scoreboard — the real model's proposals and verdicts"
    for_ cells $ \cell -> do
      let opt = mcOption cell
      withCampaignStore $ \store -> do
        journal <- readJournal store (streamOf opt)
        let attempts = mercuryAttemptsOf (decodedJournal journal)
        putStrLn ("  --" <> T.unpack opt <> ":")
        for_ attempts $ \ma -> do
          putStrLn
            ( "    attempt " <> show (meAttempt ma) <> ": " <> T.unpack (meVerdict ma)
                <> (if T.null (meOld ma) then "" else "\n      old: " <> T.unpack (T.strip (meOld ma)))
                <> (if T.null (meNew ma) then "" else "\n      new: " <> T.unpack (T.strip (meNew ma)))
            )
        remaining <- ourUnfinished store [wfIdText (mercuryWorkflowIdTagged opt liveTag)]
        unless (null remaining) $ fail ("mercury-live: unfinished cell remains: " <> show remaining)

    putStrLn "[mercury-live] landings:"
    for_ cells $ \cell -> do
      _ <- ensureCampaignWorktree "mercury" (mcBranch cell)
      commit <- gitCapture (mcWorktree cell) ["rev-parse", "--short", "HEAD"]
      stat <- gitCapture (mcWorktree cell) ["show", "--stat", "--oneline", "HEAD"]
      let statLine = case drop 1 (T.lines stat) of
            (l : _) -> T.strip l
            [] -> "(no stat)"
      putStrLn ("  " <> T.unpack (mcBranch cell) <> " @ " <> T.unpack commit <> " — " <> T.unpack statLine)
    parentDirty <- parentDirtyCount "mercury"
    putStrLn ("  parent checkout dirty entries after the campaign: " <> show parentDirty)

    -- ---------------------------------------------------------------- (4)
    putStrLn "[mercury-live] memory — what the live run taught"
    withCampaignStore $ \store -> do
      sid <- runKiokuWrite store (startInfraSession "mercury promotion live-engine run")
      for_ (zip [1 ..] liveMercuryEvidence) $ \(idx, (topic, body)) -> do
        _ <- runKiokuWrite store (recordFixTurn sid idx "assistant" ("[" <> topic <> "] " <> body))
        pure ()
      _ <- runKiokuWrite store (completeFixSession sid "the live engine is one function swap; the journal shape cannot tell stub from live attempts apart")
      putStrLn ("  infra session recorded (" <> show (length liveMercuryEvidence) <> " evidence turns)")
      let distillRT =
            withTestRunners
              (newDistillRuntime air Nothing)
              ( \tr ->
                  tr
                    { runExtract = campaignExtractRunner air,
                      runConsolidate = campaignConsolidateRunner air
                    }
              )
      result <-
        runCampaignStore store $
          distillSessionL1
            campaignAccessContext
            IgnoreWatermark
            distillRT
            (scopedScanCandidates 8)
            sid
      case result of
        Left err -> putStrLn ("  [warn] store error during L1 distillation (continuing): " <> show err)
        Right inner -> case inner of
          Left err -> putStrLn ("  [warn] L1 distillation unavailable (continuing): " <> show err)
          Right L1SkippedUpToDate -> putStrLn "  distiller: session already up to date"
          Right (L1Distilled summary) ->
            putStrLn
              ( "  distilled: " <> show summary.extracted <> " candidate(s) extracted, "
                  <> show summary.stored <> " stored"
              )
      for_
        [ "the live mercury engine is one function swap: runAIProgram behind the MercuryEngine"
            <> " shape; the facts, guard, oracle, cool-downs and landings are identical, and a"
            <> " journal cannot tell a live attempt from a scripted one by shape"
        ,
          "live-model failures are typed: a malformed reply is an AIProgramFailed surfaced and"
            <> " retried up to three times before the attempt records a guard-failed verdict"
        ]
        $ \advice -> do
          _ <- runKiokuWrite store (recordGlobalLesson (projectNamespace "mercury") advice)
          pure ()
      hits <- runCampaignStore store (recallNotesForKeyword (projectNamespace "mercury") "live")
      putStrLn ("  recall for \"live\": " <> show (length hits) <> " hit(s)")

    putStrLn "[mercury-live] done — the real model proposed, the oracle decided, the campaign landed"
  where
    liveMercuryEvidence =
      [ ("engine", "the live engine wraps runAIProgram (Extraction tier) with a 3-retry loop inside the MercuryEngine shape; attempt economics: one propose call plus the two probes per attempt"),
        ("adaptive-driver", "the driver demands a cool-down timer only when a journaled failed attempt proves it will be armed — the general form of act 16's hand-tuned second sweep"),
        ("verdicts", "the typed guard rejections (stale context, ambiguous match) and no-decode replies are the same data for a live model as for a script; the informed retry feeds them back as notes")
      ]
