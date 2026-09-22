{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The campaign's fan-out: a shibuya app fed by the campaign's own journal
-- store.
--
-- The read model so far is offline: @replayCellJournal@ folds a journal
-- after the fact. This module builds the same read model /continuously/:
--
--   * a @shibuya@ processor subscribes to the store's @$all@ stream through
--     @shibuya-kiroku-adapter@ — kiroku subscriptions bridged into
--     shibuya's pull-based adapter, with ack-coupled checkpointing;
--   * the handler decodes each event with keiro's own journal codec and
--     steps 'Campaign.Aggregate.cellReplayStep' — one streaming replay
--     state per source stream, keyed by kiroku's 'StreamId';
--   * foreign events (kioku atoms, session journals, landing journals)
--     fail to decode as journal events and never reach the handler — the
--     filter is the codec, not a string match;
--   * after the app drains, every @wf:cell-campaign-*@ stream's live state
--     is compared against a fresh offline
--     'Campaign.Aggregate.replayCellJournal' of the same journal. Both
--     paths share one step function, so they must agree — and the act
--     proves it, stream by stream.
--
-- The subscription name is fresh per run (timestamped) with
-- @FromBeginning@ checkpointing, so /every run replays the campaign's
-- whole history live/ — not just new events.
module Campaign.Fanout
  ( runCellFanout,
  )
where

import Campaign.Aggregate
  ( CellReplayState,
    CellSummary (..),
    CellVertex (..),
    cellReplayInitial,
    cellReplayStep,
    cellSummaryOf,
    replayCellJournal,
  )
import Campaign.Cell (FixAttempt (..))
import Control.Concurrent (threadDelay)
import Control.Monad (forM, forM_, unless, when)
import Data.Aeson qualified as Aeson
import Data.Either (rights)
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef)
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime, addUTCTime, getCurrentTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Data.Vector qualified as Vector
import Effectful (IOE, liftIO, runEff, (:>))
import Keiro.Codec (decodeRecorded, encodeForAppend)
import Keiro.Connection (keiroConnectionSettings)
import Keiro.Workflow.Types (WorkflowJournalEvent (..), workflowJournalCodec)
import Kiroku.Store qualified as Store
import Kiroku.Store.Connection (KirokuStore, withStore)
import Kiroku.Store.Effect (runStoreIO)
import Kiroku.Store.Subscription.Types
  ( SubscriptionName (..),
    SubscriptionTarget (..),
  )
import Kiroku.Store.Types
  ( ExpectedVersion (..),
    RecordedEvent (..),
    StreamId (..),
    StreamName (..),
    StreamVersion (..),
  )
import Shibuya
  ( AckDecision (..),
    Handler,
    Message (..),
    ProcessorId (..),
    defaultAppConfig,
    mkProcessor,
    runApp,
    stopApp,
  )
import Shibuya.Adapter.Kiroku
  ( KirokuAdapterConfig (..),
    defaultKirokuAdapterConfig,
    kirokuAdapter,
  )
import Shibuya.Core.Types (Envelope (..))
import Shibuya.Telemetry.Effect (runTracingNoop)
import Prelude

-- * Shared live state --------------------------------------------------------

-- | One streaming replay per source stream, an event counter for
-- quiescence detection, and replay warnings.
data FanoutState = FanoutState
  { fsStates :: !(IORef (Map.Map StreamId CellReplayState)),
    fsCount :: !(IORef Int),
    fsWarnings :: !(IORef [Text])
  }

newFanoutState :: IO FanoutState
newFanoutState =
  FanoutState
    <$> newIORef Map.empty
    <*> newIORef 0
    <*> newIORef []

-- * The runner ---------------------------------------------------------------

-- | Run the whole act against the campaign's database. @connString@ is the
-- same value @withCampaignStore@ derives (@host=/tmp dbname=campaign@ by
-- default); the fan-out opens its own store handle so the act is
-- self-contained.
runCellFanout :: Text -> IO ()
runCellFanout connString = withStore (keiroConnectionSettings connString "campaign") $ \store -> do
  now <- getCurrentTime
  putStrLn "[fanout] appending synthetic journals (cleared + parked-escalation)"
  appendFixtureJournals store now

  st <- newFanoutState
  let subName =
        SubscriptionName
          ("cell-fanout-" <> T.pack (show (floor (utcTimeToPOSIXSeconds now) :: Int)))

  putStrLn "[fanout] starting shibuya app over the kiroku adapter (full-history replay)"
  runEff $
    runTracingNoop $ do
      adapter <-
        kirokuAdapter store $
          (defaultKirokuAdapterConfig subName AllStreams)
            { selector = Just journalEventOnly
            }
      started <-
        runApp
          defaultAppConfig
          [(ProcessorId "cell-fanout", mkProcessor adapter (cellHandler st))]
      case started of
        Left err -> liftIO (fail ("shibuya app failed to start: " <> show err))
        Right appHandle -> do
          liftIO $ do
            awaitQuiescent st
            count <- readIORef st.fsCount
            putStrLn ("[fanout] drained " <> show count <> " journal event(s); stopping app")
          stopApp appHandle

  finalStates <- readIORef st.fsStates
  warnings <- reverse <$> readIORef st.fsWarnings
  unless (null warnings) $
    forM_ warnings $
      \w -> putStrLn ("[fanout] WARNING " <> T.unpack w)
  reportFanout store finalStates

-- | Adapter-side filter: only events that decode as journal events reach
-- the handler. The filter is the codec, not a string match.
journalEventOnly :: RecordedEvent -> Bool
journalEventOnly ev = case decodeRecorded workflowJournalCodec ev of
  Right _ -> True
  Left _ -> False

-- * Handler ------------------------------------------------------------------

-- | One shibuya message = one recorded event. Journal events step the
-- per-stream replay.
cellHandler ::
  (IOE :> es) =>
  FanoutState ->
  Handler es RecordedEvent
cellHandler st Message {envelope = Envelope {payload = ev}} = do
  liftIO $ modifyIORef' st.fsCount (+ 1)
  case decodeRecorded workflowJournalCodec ev of
    Left _ -> pure AckOk -- unreachable behind the selector; kept total
    Right wje -> do
      outcome <-
        liftIO $
          atomicModifyIORef' st.fsStates $ \m ->
            let s0 = Map.findWithDefault cellReplayInitial ev.originalStreamId m
             in case cellReplayStep s0 wje of
                  Left err -> (m, Left err)
                  Right s' -> (Map.insert ev.originalStreamId s' m, Right ())
      case outcome of
        Left err ->
          liftIO $
            let warn = "replay failure on event " <> T.pack (show ev.eventId) <> ": " <> T.pack err
             in atomicModifyIORef' st.fsWarnings $ \ws -> (warn : ws, ())
        Right () -> pure ()
      pure AckOk

-- * Quiescence ---------------------------------------------------------------

-- | Poll until the event counter is positive and stable for two
-- consecutive seconds (catch-up drained), bounded at ~30s.
awaitQuiescent :: FanoutState -> IO ()
awaitQuiescent st = go (0 :: Int) (-1 :: Int)
  where
    go tries prev = do
      n <- readIORef st.fsCount
      if n > 0 && n == prev
        then pure ()
        else
          if tries >= 30
            then putStrLn "[fanout] quiescence timeout; reporting anyway"
            else do
              threadDelay 1_000_000
              go (tries + 1) n

-- * Live-vs-offline report ---------------------------------------------------

-- | Compare the live read model against a fresh offline replay for every
-- cell-campaign stream the fan-out tracked. A disagreement fails the act.
reportFanout :: KirokuStore -> Map.Map StreamId CellReplayState -> IO ()
reportFanout store finalStates = do
  namesE <- runStoreIO store (Store.lookupStreamNames (Map.keys finalStates))
  names <- requireRight namesE
  let cellStreams =
        [ (sid, sname)
        | (sid, sname) <-
            [ (sid, maybe "<unknown>" streamNameText (Map.lookup sid names))
            | (sid, _) <- Map.toList finalStates
            ],
          isCellStreamName sname
        ]

  putStrLn
    ( "[fanout] streams tracked: "
        <> show (Map.size finalStates)
        <> "; cell journals: "
        <> show (length cellStreams)
    )
  results <- forM (sortOn snd cellStreams) $ \(sid, sname) -> do
    journalE <- runStoreIO store (Store.readStreamForward (StreamName sname) (StreamVersion 0) 1000)
    journal <- requireRight journalE
    let events = Vector.toList journal
        live = cellSummaryOf (Map.findWithDefault cellReplayInitial sid finalStates)
        offline = offlineSummary events
        verdict = case offline of
          Just off -> off == live
          Nothing -> False
        offlineOk = case offline of
          Just _ -> True
          Nothing -> False
    pure (sname, live, offline, offlineOk, verdict)

  forM_ results $ \(sname, live, offline, offlineOk, verdict) ->
    putStrLn $
      "[fanout] "
        <> T.unpack (T.drop (T.length "wf:cell-campaign-") sname)
        <> "  live: "
        <> T.unpack (describeSummary live)
        <> "  offline: "
        <> if offlineOk
          then T.unpack (describeSummary (fromMaybe live offline))
          else
            "REPLAY-FAILED"
              <> "  ["
              <> (if verdict then "MATCH" else "DIFF")
              <> "]"

  let nMatch = length [() | (_, _, _, _, True) <- results]
      nDiff = length [() | (_, _, _, _, False) <- results]
  putStrLn ("[fanout] agreement: " <> show nMatch <> " match, " <> show nDiff <> " diff")
  when (nDiff > 0) $
    fail "[fanout] live and offline read models disagree"

offlineSummary :: [RecordedEvent] -> Maybe CellSummary
offlineSummary events =
  case replayCellJournal (journalEventsOf events) of
    Left _ -> Nothing
    Right rst -> Just (cellSummaryOf rst)

journalEventsOf :: [RecordedEvent] -> [WorkflowJournalEvent]
journalEventsOf events = rights (decodeRecorded workflowJournalCodec <$> events)

isCellStreamName :: Text -> Bool
isCellStreamName = T.isPrefixOf "wf:cell-campaign-"

streamNameText :: StreamName -> Text
streamNameText (StreamName t) = t

describeSummary :: CellSummary -> Text
describeSummary s = case s.csVertex of
  CellClearedVertex -> "cleared after " <> T.pack (show s.csAttempts) <> " attempt(s)"
  CellEscalatedVertex -> "escalated: " <> fromMaybe "?" s.csEscalatedReason
  CellHumanQueried -> "parked (human queried) after " <> T.pack (show s.csAttempts) <> " attempt(s)"
  CellOpen -> "open after " <> T.pack (show s.csAttempts) <> " attempt(s)"

requireRight :: (Show err) => Either err a -> IO a
requireRight = either (fail . show) pure

-- * Synthetic journals -------------------------------------------------------

-- | Two fixture journals: one clearing after two attempts (attempt 1
-- fails the guard, attempt 2 succeeds), one escalating to the human after
-- three failed attempts and parking there (the act-2 story). Appending is
-- skipped if the streams already exist, so the act re-runs cleanly.
appendFixtureJournals :: KirokuStore -> UTCTime -> IO ()
appendFixtureJournals store now = do
  appendOnce "wf:cell-campaign-synth-alpha" (alphaEvents now)
  appendOnce "wf:cell-campaign-synth-beta" (betaEvents now)
  where
    appendOnce name events =
      case traverse (encodeForAppend workflowJournalCodec) events of
        Left err -> fail ("fixture encode failed: " <> show err)
        Right evts -> do
          res <- runStoreIO store (Store.appendToStream (StreamName name) NoStream evts)
          case res of
            Right _ -> pure ()
            Left _ -> putStrLn ("[fanout] fixture " <> T.unpack name <> " already present; skipped")

alphaEvents :: UTCTime -> [WorkflowJournalEvent]
alphaEvents t0 =
  [ StepRecorded "verify-initial" (Aeson.toJSON (["W: unused import Data.List"] :: [Text])) t0,
    StepRecorded "propose-fix-1" (jsonAttempt 1 False) (addUTCTime 5 t0),
    StepRecorded "propose-fix-2" (jsonAttempt 2 True) (addUTCTime 10 t0),
    WorkflowCompleted (addUTCTime 12 t0)
  ]

betaEvents :: UTCTime -> [WorkflowJournalEvent]
betaEvents t0 =
  [ StepRecorded "verify-initial" (Aeson.toJSON (["E: type error in main"] :: [Text])) t0,
    StepRecorded "propose-fix-1" (jsonAttempt 1 False) (addUTCTime 5 t0),
    StepRecorded "propose-fix-2" (jsonAttempt 2 False) (addUTCTime 10 t0),
    StepRecorded "propose-fix-3" (jsonAttempt 3 False) (addUTCTime 15 t0),
    StepRecorded
      "publish-human-query"
      (Aeson.toJSON (("question", "How should this cell be fixed?") :: (Text, Text)))
      (addUTCTime 16 t0)
  ]

jsonAttempt :: Int -> Bool -> Aeson.Value
jsonAttempt n ok =
  Aeson.toJSON
    FixAttempt
      { faAttempt = n,
        faSucceeded = ok,
        faDiagnosticsBefore = ["before"],
        faDiagnosticsAfter = ["after"],
        faRecallNotes = [],
        faRepaired = if ok then Just "repaired" else Nothing
      }
