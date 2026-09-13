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
module Main
  ( main,
  )
where

import Control.Applicative ((<|>))
import Control.Monad (unless, when)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as BL
import Data.Foldable (for_, traverse_)
import Data.IORef (atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Maybe (isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time.Clock (addUTCTime, getCurrentTime)
import Data.Vector qualified as Vector
import Effectful (Eff, IOE, UnliftStrategy (..), liftIO, raise, runEff, withEffToIO)
import Effectful.Error.Static (Error, runErrorNoCallStack)
import Keiro.Codec (decodeRecorded)
import Keiro.Connection (keiroConnectionSettings)
import Keiro.Workflow
  ( WorkflowId (..),
    WorkflowJournalEvent (..),
    WorkflowOutcome (..),
    defaultWorkflowRunOptions,
    findUnfinishedWorkflowIds,
    runWorkflowWith,
    workflowJournalCodec,
  )
import Keiro.Workflow.Awakeable (AwakeableId, awakeableIdText, signalAwakeable)
import Keiro.Workflow.Resume
  ( WorkflowRegistry,
    WorkflowResumeOptions (..),
    defaultWorkflowResumeOptions,
    resumeWorkflowsOnce,
  )
import Keiro.Workflow.Sleep (runWorkflowTimerWorker)
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
import System.Directory (removeFile)
import System.Environment (lookupEnv)
import System.IO (hClose, openTempFile)

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
import Kioku.Distill.Runtime (TestRunners (..), newDistillRuntime, withTestRunners)
import Kioku.Id (SessionId)
import Kioku.ReadModel (registerKiokuReadModels)
import Shikumi.Error (ShikumiError (..))
import Shikumi.Module (predict)
import Shikumi.Program (Program)
import Shikumi.Schema.Types (field)
import Shikumi.Signature (Demo (..), getInstruction, setDemos, setInstruction)

import Campaign.Cell (Cell (..), CellId (..), FixAttempt (..), cellForId, unCellId)
import Campaign.Memory
  ( campaignAccessContext,
    completeFixSession,
    recallNotes,
    recordFixTurn,
    recordLesson,
    startFixSession,
  )
import Campaign.Workflow
  ( HumanVerdict (..),
    campaignRegistry,
    campaignStreamNameText,
    campaignWorkflowId,
    cellCampaignWorkflow,
    cellCampaignWorkflowName,
    defaultMaxAttempts,
  )
import Shikumi.Testing (markerResponse)
import Toy.Fixer.Domain (sourceText)

main :: IO ()
main = do
  putStrLn "[campaign] one verification cell on keiro's durable runtime (shikumi decides, keiro journals, kioku remembers)"
  runInformedRetryAct
  runEscalationAct
  runMemoryAct
  sid <- runSessionAct
  runDistillAct sid

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

withCampaignStore :: (CampaignStore -> IO ()) -> IO ()
withCampaignStore action = do
  connString <- do
    configured <- lookupEnv "PG_CONNECTION_STRING"
    pure (maybe "host=/tmp dbname=campaign" T.pack configured)
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

      responder1 _n _notes _ctx = markerResponse [("repaired", pick1)]
      responder2 _n _notes _ctx = markerResponse [("repaired", pick2)]
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
          (runWorkflowWith defaultWorkflowRunOptions wfName wfId (cellCampaignWorkflow responder1 (raise . noPublisher) cell defaultMaxAttempts))
    putStrLn ("  first run outcome: " <> show outcome1 <> "  (partial attempt journaled; settle sleep armed; run suspended)")

    fireTimerUntilJournaled store stream "sleep:settle-1"
    putStrLn "[informed] resuming with the corrected model strategy"
    driveResumeOnce store (campaignRegistry responder2 noPublisher)

    -- Attempt 2 clears the cell, but the success check runs after the next
    -- settle sleep, so fire it and resume once more to complete.
    fireTimerUntilJournaled store stream "sleep:settle-2"
    driveResumeOnce store (campaignRegistry responder2 noPublisher)

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
          (runWorkflowWith defaultWorkflowRunOptions wfName wfId (cellCampaignWorkflow responder2 (raise . noPublisher) cell defaultMaxAttempts))
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
      confused _n _notes _ctx = markerResponse [("repaired", current)]

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
      registry = campaignRegistry confused publishHumanQuery

  withCampaignStore $ \store -> do
    requireFreshJournal store stream
    putStrLn "[escalation] first run: a bad attempt records, the settle sleep suspends the run"
    outcome1 <-
      requireEither
        =<< runCampaignStore
          store
          (runWorkflowWith defaultWorkflowRunOptions wfName wfId (cellCampaignWorkflow confused (raise . publishHumanQuery) cell defaultMaxAttempts))
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
          (runWorkflowWith defaultWorkflowRunOptions wfName wfId (cellCampaignWorkflow confused (raise . publishHumanQuery) cell defaultMaxAttempts))
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
    runKiokuWrite store $ recordLesson "alpha.py" "a line marked TODO must be deleted entirely, not commented out"
    runKiokuWrite store $ recordLesson "beta.py" "a binding flagged unused must have its whole line deleted"
    recorded <- runCampaignStore store recallNotes
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
      informed _n notes _ctx = markerResponse [("repaired", fixed)]
        where
          lowered = map T.toLower notes
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
          (runWorkflowWith defaultWorkflowRunOptions wfName wfId (cellCampaignWorkflow informed (raise . noPublisher) gamma defaultMaxAttempts))
    putStrLn ("  first run outcome: " <> show outcome)

    -- The single successful attempt still pauses on its settle sleep before
    -- the workflow's success check, so fire and resume once.
    fireTimerUntilJournaled store stream "sleep:settle-1"
    driveResumeOnce store (campaignRegistry informed noPublisher)

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
    sid <- runKiokuWrite store (startFixSession (unCellId cell.cellId))
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
    notes <- runCampaignStore store recallNotes
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

-- | Run the shape-contract extractor on the live stack, surfacing shikumi
-- errors as kioku expects them.
campaignExtractRunner :: AIRuntime -> ExtractInput -> IO (Either ShikumiError ExtractOutput)
campaignExtractRunner air input =
  runAIProgram air Extraction shapeProgram input >>= \case
    Left (AIProgramFailed err) -> pure (Left err)
    Left other -> pure (Left (ProviderFailure (T.pack (show other))))
    Right out -> pure (Right out)

-- | Consolidation stays on kioku's stock program — the same call the
-- non-overridden path would make (a decision over one or two atoms, no shape
-- contract needed).
campaignConsolidateRunner :: AIRuntime -> ConsolidateInput -> IO (Either ShikumiError ConsolidationDecision)
campaignConsolidateRunner air input =
  runAIProgram air Consolidation consolidateProgram input >>= \case
    Left (AIProgramFailed err) -> pure (Left err)
    Left other -> pure (Left (ProviderFailure (T.pack (show other))))
    Right out -> pure (Right out)

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
    notes <- runCampaignStore store recallNotes
    case notes of
      Left err -> fail (show err)
      Right ns -> do
        putStrLn ("  recall after distillation — " <> show (length ns) <> " note(s) in memory:")
        for_ ns \n -> TIO.putStrLn ("    - " <> n)

  putStrLn "[distill] done — the campaign writes its own lessons from its own journal"
