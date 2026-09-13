{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The campaign's kioku memory: lessons recorded per cell, recalled into
-- the fixer's prompt, sessions distilled from the journal.
--
-- The split follows kioku's own philosophy:
--
--   * /Writes/ (lessons, sessions, turns) need the full write row
--     @(IOE, KirokuStoreResource, Store, Error StoreError)@ and live on the
--     driver side. Session turns are L0 evidence; kioku's distillers can
--     promote them to atoms later.
--   * /Reads/ (recall) need only @(IOE, Store)@ — so the /workflow itself/
--     recalls lessons inside the attempt step and journals them into the
--     'Campaign.Cell.FixAttempt' record: every journaled attempt carries the
--     memory that informed its prompt, and replay never re-recalls.
--
-- Memory content format: a lesson is one line @lesson: <advice>@. The advice
-- is plain text the model reads; @parseLesson@ is the machine-readable part
-- hosts and responders key on.
module Campaign.Memory
  ( -- * Configuration
    campaignMemorySpace,
    campaignNamespace,
    campaignAccessContext,
    cellScope,

    -- * Lessons: content format
    lessonText,
    parseLesson,

    -- * Writes (driver side; full write effect row)
    recordLesson,
    startFixSession,
    recordFixTurn,
    completeFixSession,

    -- * Reads (workflow side; only @IOE@ and @Store@)
    recallNotes,
    recallNotesForKeyword,
  )
where

import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock (getCurrentTime)
import Effectful (Eff, IOE, liftIO, (:>))
import Effectful.Error.Static (Error)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Effect.Resource (KirokuStoreResource)
import Kiroku.Store.Error (StoreError)
import Kioku.Api.Access
  ( MemoryAccessContext,
    MemoryActor (..),
    MemorySpaceId,
    assumeAuthorizedMemoryContext,
    memoryContextRecordedActor,
    mkMemorySpaceId,
    mkPrincipalRef,
  )
import Kioku.Api.Scope
  ( MemoryScope (..),
    Namespace,
    mkNamespace,
    mkScopeKind,
  )
import Kioku.Api.Types (Confidence (..), MemoryRecord (..), MemoryType (..))
import Kioku.Id (SessionId, genMemoryId, genSessionId)
import Kioku.Memory (MemoryWriteError, recordWithContext)
import Kioku.Memory.Domain (RecordMemoryData (..))
import Kioku.Recall (getActiveInNamespace)
import Kioku.Session
  ( SessionWriteError,
    completeWithContext,
    recordTurnWithContext,
    startWithContext,
  )
import Kioku.Session.Domain (CompleteSessionData (..), RecordTurnData (..), StartSessionData (..))

-- ---------------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------------

-- | One memory space for the whole campaign. A real multi-project host would
-- use one space per project; the skeleton is one campaign.
campaignMemorySpace :: MemorySpaceId
campaignMemorySpace = either (error . T.unpack) id (mkMemorySpaceId "shikumi-campaign")

-- | The campaign namespace. Cell lessons live in per-cell entity scopes under
-- it, so namespace-wide recall reaches every lesson while scopes stay tidy.
campaignNamespace :: Namespace
campaignNamespace = either (error . T.unpack) id (mkNamespace "campaign")

-- | The embedded host mints its own context: full permissions on its space.
campaignAccessContext :: MemoryAccessContext
campaignAccessContext =
  assumeAuthorizedMemoryContext campaignMemorySpace campaignActor
  where
    campaignActor =
      MemoryActor (either (error . T.unpack) id (mkPrincipalRef "campaign-driver"))

-- | Entity scope per cell: @(campaign, cell, \"alpha.py\")@.
cellScope :: Text -> MemoryScope
cellScope path = ScopeEntity campaignNamespace (either (error . T.unpack) id (mkScopeKind "cell")) path

-- ---------------------------------------------------------------------------
-- Lesson content format
-- ---------------------------------------------------------------------------

-- | A lesson's stored content: @lesson: <advice>@.
lessonText :: Text -> Text
lessonText advice = "lesson: " <> advice

-- | Parse a lesson back to its advice ('Nothing' for non-lesson content).
parseLesson :: Text -> Maybe Text
parseLesson = T.stripPrefix "lesson: "

-- ---------------------------------------------------------------------------
-- Writes (driver side)
-- ---------------------------------------------------------------------------

-- | Record one lesson for a cell. Idempotent for identical re-runs (kioku's
-- write-conflict rules), so a driver replay cannot duplicate lessons.
recordLesson ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  -- | the cell path the lesson is anchored to
  Text ->
  -- | the advice text
  Text ->
  Eff es (Either MemoryWriteError ())
recordLesson path advice = do
  mid <- genMemoryId
  now <- liftIO getCurrentTime
  let ctx = campaignAccessContext
  result <-
    recordWithContext ctx
      RecordMemoryData
        { memoryId = mid,
          memorySpaceId = campaignMemorySpace,
          actorPrincipal = memoryContextRecordedActor ctx,
          ownerPrincipal = Nothing,
          agentId = "campaign-driver",
          sessionId = Nothing,
          scope = cellScope path,
          memoryType = MemoryPattern,
          content = lessonText advice,
          priority = 100,
          confidence = HighConfidence,
          tags = Set.fromList ["fix-lesson", "cell:" <> path],
          supersedes = Nothing,
          recordedAt = now
        }
  pure (const () <$> result)

-- | Start one fix session for a cell (L0 evidence container).
startFixSession ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  -- | cell path (the session's focus and subject)
  Text ->
  Eff es (Either SessionWriteError SessionId)
startFixSession path = do
  sid <- genSessionId
  now <- liftIO getCurrentTime
  let ctx = campaignAccessContext
  startWithContext ctx
    StartSessionData
      { sessionId = sid,
        memorySpaceId = campaignMemorySpace,
        actorPrincipal = memoryContextRecordedActor ctx,
        ownerPrincipal = Nothing,
        agentId = "campaign-fixer",
        focus = "fix " <> path,
        scope = cellScope path,
        subjectRef = Just path,
        previousSessionId = Nothing,
        parentSessionId = Nothing,
        delegationDepth = 0,
        startedAt = now
      }

-- | Record one turn of the fix session.
recordFixTurn ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  SessionId ->
  -- | turn index (strictly increasing)
  Int ->
  -- | role (@user@ / @assistant@ / @tool@)
  Text ->
  -- | content
  Text ->
  Eff es (Either SessionWriteError SessionId)
recordFixTurn sid idx role content = do
  now <- liftIO getCurrentTime
  let ctx = campaignAccessContext
  recordTurnWithContext ctx
    RecordTurnData
      { sessionId = sid,
        memorySpaceId = campaignMemorySpace,
        actorPrincipal = memoryContextRecordedActor ctx,
        turnId = "turn-" <> T.pack (show idx),
        turnIndex = idx,
        role = role,
        content = content,
        toolSummary = Nothing,
        promptTokens = Nothing,
        outputTokens = Nothing,
        recordedAt = now
      }

-- | Complete a fix session with a summary line.
completeFixSession ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  SessionId ->
  -- | summary
  Text ->
  Eff es (Either SessionWriteError ())
completeFixSession sid summary = do
  now <- liftIO getCurrentTime
  let ctx = campaignAccessContext
  result <-
    completeWithContext ctx
      CompleteSessionData
        { sessionId = sid,
          memorySpaceId = campaignMemorySpace,
          actorPrincipal = memoryContextRecordedActor ctx,
          completedAt = now,
          modelUsed = Just "shikumi-stub",
          summary = Just summary
        }
  pure (const () <$> result)

-- ---------------------------------------------------------------------------
-- Reads (workflow side)
-- ---------------------------------------------------------------------------

-- | Every active memory's advice in the campaign namespace. Lessons are
-- @lesson: @-prefixed (the prefix is stripped); any other content — such as
-- atoms machine-written by kioku's L1 distiller — passes through verbatim.
-- Full-text recall needs no embeddings; with pgvector installed a host would
-- switch this to hybrid recall without changing the call shape.
recallNotes :: (IOE :> es, Store :> es) => Eff es [Text]
recallNotes = do
  r <- getActiveInNamespace campaignMemorySpace campaignNamespace
  pure $ case r of
    Left _ -> []
    Right records ->
      [ maybe content id (parseLesson content)
      | MemoryRecord {content} <- records
      ]

-- | Lessons whose advice mentions a keyword (@todo@, @unused@, …). The
-- workflow derives keywords from the cell's own diagnostics, so the memory
-- consulted is a function of the task, not of the caller's mood.
recallNotesForKeyword :: (IOE :> es, Store :> es) => Text -> Eff es [Text]
recallNotesForKeyword kw = do
  notes <- recallNotes
  pure [n | n <- notes, kw `T.isInfixOf` T.toLower n]
