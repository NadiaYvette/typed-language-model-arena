{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE BlockArguments #-}
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
    campaignInfraNamespace,
    projectNamespace,
    projectNamespaceSafe,
    campaignAccessContext,
    cellScope,
    cellScopeIn,

    -- * Lessons: content format
    lessonText,
    parseLesson,

    -- * Writes (driver side; full write effect row)
    recordLesson,
    recordGlobalLesson,
    recordGlobalLessonSuperseding,
    startFixSession,
    startInfraSession,
    recordFixTurn,
    completeFixSession,

    -- * Reads (workflow side; only @IOE@ and @Store@)
    recallNotes,
    recallNotesForKeyword,
  )
where

import Control.Monad (void)
import Data.Maybe (fromMaybe, listToMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock (getCurrentTime)
import Effectful (Eff, IOE, liftIO, (:>))
import Effectful.Error.Static (Error)
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
    scopeNamespaceText,
  )
import Kioku.Api.Types (Confidence (..), MemoryRecord (..), MemoryType (..))
import Kioku.Id (SessionId, genMemoryId, genSessionId, idText, parseId)
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
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Effect.Resource (KirokuStoreResource)
import Kiroku.Store.Error (StoreError)

-- ---------------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------------

-- | One memory space for the whole campaign driver. Projects are separated
-- by /namespace/ below it: the toy corpus is @toy@, the real checkouts are
-- @mowgli@ and @peirce@ — so namespace-wide recall reaches exactly one
-- project's lessons and scopes stay (project, cell, path)-partitioned.
campaignMemorySpace :: MemorySpaceId
campaignMemorySpace = either (error . T.unpack) id (mkMemorySpaceId "shikumi-campaign")

-- | The namespace of one project: @"toy"@, @"mowgli"@, @"peirce"@, …
projectNamespace :: Text -> Namespace
projectNamespace name = either (error . T.unpack) id (mkNamespace name)

-- | 'projectNamespace' for names that may carry kioku's forbidden
-- characters (@%@, @/@, @:@): they are stripped/replaced /deterministically/
-- so every session for one project lands in one namespace — a slash-y
-- project like @tessera/third_party/sail@ becomes
-- @tessera.third_party.sail@. The vendored-submodule round crashed the
-- lexing cell on the raw name; every project-cell fix session now goes
-- through this.
projectNamespaceSafe :: Text -> Namespace
projectNamespaceSafe =
  projectNamespace . T.replace "/" "." . T.replace "%" "" . T.replace ":" ""

-- | The toy corpus's namespace (the original single-project demo).
campaignNamespace :: Namespace
campaignNamespace = projectNamespace "toy"

-- | The campaign's own infrastructure namespace: how the store is
-- provisioned, how the read model is built, what the stack needs to run.
-- Infrastructure memory lives apart from project lessons so a planner can
-- pull @how do we run at all@ without wading through fix advice.
campaignInfraNamespace :: Namespace
campaignInfraNamespace = projectNamespace "infra"

-- | The embedded host mints its own context: full permissions on its space.
campaignAccessContext :: MemoryAccessContext
campaignAccessContext =
  assumeAuthorizedMemoryContext campaignMemorySpace campaignActor
  where
    campaignActor =
      MemoryActor (either (error . T.unpack) id (mkPrincipalRef "campaign-driver"))

-- | Entity scope per cell: @(namespace, cell, \"alpha.py\")@.
cellScopeIn :: Namespace -> Text -> MemoryScope
cellScopeIn ns = ScopeEntity ns (either (error . T.unpack) id (mkScopeKind "cell"))

-- | The toy namespace's per-cell scope.
cellScope :: Text -> MemoryScope
cellScope = cellScopeIn campaignNamespace

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
  -- | the project namespace the lesson belongs to
  Namespace ->
  -- | the cell path the lesson is anchored to
  Text ->
  -- | the advice text
  Text ->
  Eff es (Either MemoryWriteError ())
recordLesson ns path advice = do
  mid <- genMemoryId
  now <- liftIO getCurrentTime
  let ctx = campaignAccessContext
  result <-
    recordWithContext
      ctx
      RecordMemoryData
        { memoryId = mid,
          memorySpaceId = campaignMemorySpace,
          actorPrincipal = memoryContextRecordedActor ctx,
          ownerPrincipal = Nothing,
          agentId = "campaign-driver",
          sessionId = Nothing,
          scope = cellScopeIn ns path,
          memoryType = MemoryPattern,
          content = lessonText advice,
          priority = 100,
          confidence = HighConfidence,
          tags = Set.fromList ["fix-lesson", "cell:" <> path, "project:" <> scopeNamespaceText (ScopeGlobal ns)],
          supersedes = Nothing,
          recordedAt = now
        }
  pure (void result)

-- | Record a project-level lesson at the namespace's /global/ scope — the
-- scope kioku's L2 scenes and L3 personas distill over ('ScopeGlobal' ns).
-- Cell lessons ('recordLesson') are entity-scoped, so a project's scene is
-- fed by the lessons a host promotes to project level, not by every cell.
recordGlobalLesson ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  -- | the project namespace
  Namespace ->
  -- | the advice text
  Text ->
  Eff es (Either MemoryWriteError ())
recordGlobalLesson ns advice = do
  mid <- genMemoryId
  now <- liftIO getCurrentTime
  let ctx = campaignAccessContext
  result <-
    recordWithContext
      ctx
      RecordMemoryData
        { memoryId = mid,
          memorySpaceId = campaignMemorySpace,
          actorPrincipal = memoryContextRecordedActor ctx,
          ownerPrincipal = Nothing,
          agentId = "campaign-driver",
          sessionId = Nothing,
          scope = ScopeGlobal ns,
          memoryType = MemoryPattern,
          content = lessonText advice,
          priority = 100,
          confidence = HighConfidence,
          tags = Set.fromList ["fix-lesson", "project:" <> scopeNamespaceText (ScopeGlobal ns)],
          supersedes = Nothing,
          recordedAt = now
        }
  pure (void result)

-- | 'recordGlobalLesson' for /revisable/ knowledge: the new atom carries
-- 'RecordMemoryData.supersedes' pointing at the active atom it replaces
-- (matched by content prefix), so kioku's lineage — not a deletion — keeps
-- the history. A no-op when the active atom already says the same thing,
-- so the act is idempotent. Returns @Just ()@ when a new atom was written.
recordGlobalLessonSuperseding ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  -- | the project namespace
  Namespace ->
  -- | the tag the pattern lives under (the content-prefix match key)
  Text ->
  -- | the advice text
  Text ->
  Eff es (Either MemoryWriteError Bool)
recordGlobalLessonSuperseding ns tag advice = do
  active <- getActiveInNamespace campaignMemorySpace ns
  let mOld = case active of
        Right records ->
          listToMaybe
            [ r
            | r@MemoryRecord {content} <- records,
              ("lesson: " <> tag <> ":") `T.isPrefixOf` content
            ]
        Left _ -> Nothing
      newContent = lessonText (tag <> ": " <> advice)
  case mOld of
    Just MemoryRecord {content = oldContent, memoryId = oldMid}
      | oldContent == newContent -> pure (Right False)
      -- An unparsable id would break lineage; since these ids are minted by
      -- this very module (idText round-trips parseId), treat failure as the
      -- degenerate no-lineage write rather than an error the caller can't
      -- act on.
      | otherwise -> write (either (const Nothing) Just (parseId oldMid))
    Nothing -> write Nothing
  where
    write mSupersedes = do
      mid <- genMemoryId
      now <- liftIO getCurrentTime
      let ctx = campaignAccessContext
      result <-
        recordWithContext
          ctx
          RecordMemoryData
            { memoryId = mid,
              memorySpaceId = campaignMemorySpace,
              actorPrincipal = memoryContextRecordedActor ctx,
              ownerPrincipal = Nothing,
              agentId = "campaign-driver",
              sessionId = Nothing,
              scope = ScopeGlobal ns,
              memoryType = MemoryPattern,
              content = lessonText (tag <> ": " <> advice),
              priority = 100,
              confidence = HighConfidence,
              tags = Set.fromList ["fix-lesson", "pattern:" <> tag, "project:" <> scopeNamespaceText (ScopeGlobal ns)],
              supersedes = mSupersedes,
              recordedAt = now
            }
      pure (True <$ result)

-- | Start one fix session for a cell (L0 evidence container).
startFixSession ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  -- | the project namespace
  Namespace ->
  -- | cell path (the session's focus and subject)
  Text ->
  Eff es (Either SessionWriteError SessionId)
startFixSession ns path = do
  sid <- genSessionId
  now <- liftIO getCurrentTime
  let ctx = campaignAccessContext
  startWithContext
    ctx
    StartSessionData
      { sessionId = sid,
        memorySpaceId = campaignMemorySpace,
        actorPrincipal = memoryContextRecordedActor ctx,
        ownerPrincipal = Nothing,
        agentId = "campaign-fixer",
        focus = "fix " <> path,
        scope = cellScopeIn ns path,
        subjectRef = Just path,
        previousSessionId = Nothing,
        parentSessionId = Nothing,
        delegationDepth = 0,
        startedAt = now
      }

-- | Start an infrastructure session (L0 evidence about the campaign's own
-- stack) at the infra namespace's global scope — the scope that later
-- distillation and planner-facing keyword recall read.
startInfraSession ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  -- | the topic (goes into the session focus)
  Text ->
  Eff es (Either SessionWriteError SessionId)
startInfraSession topic = do
  sid <- genSessionId
  now <- liftIO getCurrentTime
  let ctx = campaignAccessContext
  startWithContext
    ctx
    StartSessionData
      { sessionId = sid,
        memorySpaceId = campaignMemorySpace,
        actorPrincipal = memoryContextRecordedActor ctx,
        ownerPrincipal = Nothing,
        agentId = "campaign-ops",
        focus = "campaign infrastructure: " <> topic,
        scope = ScopeGlobal campaignInfraNamespace,
        subjectRef = Nothing,
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
  recordTurnWithContext
    ctx
    RecordTurnData
      { sessionId = sid,
        memorySpaceId = campaignMemorySpace,
        actorPrincipal = memoryContextRecordedActor ctx,
        -- kioku_turns.turn_id is a GLOBAL primary key, so the id must be
        -- unique across every session the store has ever recorded — derive
        -- it from the session id, not the turn index alone.
        turnId = "turn-" <> idText sid <> "-" <> T.pack (show idx),
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
    completeWithContext
      ctx
      CompleteSessionData
        { sessionId = sid,
          memorySpaceId = campaignMemorySpace,
          actorPrincipal = memoryContextRecordedActor ctx,
          completedAt = now,
          modelUsed = Just "shikumi-stub",
          summary = Just summary
        }
  pure (void result)

-- ---------------------------------------------------------------------------
-- Reads (workflow side)
-- ---------------------------------------------------------------------------

-- | Every active memory's advice in one project namespace. Lessons are
-- @lesson: @-prefixed (the prefix is stripped); any other content — such as
-- atoms machine-written by kioku's L1 distiller — passes through verbatim.
-- Full-text recall needs no embeddings; with pgvector installed a host would
-- switch this to hybrid recall without changing the call shape.
recallNotes :: (IOE :> es, Store :> es) => Namespace -> Eff es [Text]
recallNotes ns = do
  r <- getActiveInNamespace campaignMemorySpace ns
  pure $ case r of
    Left _ -> []
    Right records ->
      [ fromMaybe content (parseLesson content)
      | MemoryRecord {content} <- records
      ]

-- | Lessons whose advice mentions a keyword (@todo@, @unused@, …). The
-- workflow derives keywords from the cell's own diagnostics, so the memory
-- consulted is a function of the task, not of the caller's mood.
recallNotesForKeyword :: (IOE :> es, Store :> es) => Namespace -> Text -> Eff es [Text]
recallNotesForKeyword ns kw = do
  notes <- recallNotes ns
  pure [n | n <- notes, kw `T.isInfixOf` T.toLower n]
