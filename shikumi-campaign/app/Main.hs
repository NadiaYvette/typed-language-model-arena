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
--   5. /Restart proof/ (after each act): a fresh store connection — a new
--      \"process\" — finds no unfinished work. The campaign state lives in
--      the journal, not in the process.
--
-- Everything runs offline: the model is 'markerResponse' scripts, the
-- checker is pure, and Postgres is the only external dependency.
module Main
  ( main,
  )
where

import Control.Monad (unless, when)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Foldable (for_, traverse_)
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
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
import System.Environment (lookupEnv)

import Kioku.ReadModel (registerKiokuReadModels)

import Campaign.Cell (Cell (..), CellId (..), FixAttempt (..), cellForId, unCellId)
import Campaign.Memory
  ( completeFixSession,
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
  runSessionAct

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

runSessionAct :: IO ()
runSessionAct = do
  putStrLn "\n=== act 4: the fix session as kioku L0 evidence ==="
  cell <- requireCell "alpha.py"
  withCampaignStore $ \store -> do
    putStrLn "[session] starting a fix session for alpha.py"
    sid <- runKiokuWrite store (startFixSession (unCellId cell.cellId))
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
