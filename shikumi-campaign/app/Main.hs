{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE BlockArguments #-}
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

-- help-check: the paced compiler build

import Baikai (Context (..), Message (..), Response, TextContent (..), UserContent (..))
import Baikai.Message (UserPayload (UserPayload))
import Campaign.Aggregate (CellSummary (..), CellVertex (..), cellSummaryOf, replayCellJournal)
import Campaign.Attestation (journalRefText)
import Campaign.Bootstrap
  ( bootstrapCampaignStore,
    bootstrapStore,
    ccDbname,
    ccPassword,
    createDatabaseIfAbsent,
    defaultCampaignConn,
    dropDatabase,
    ownedServerAlive,
    ownedServerConn,
    ownedServerStateDir,
    parseCampaignConn,
    renderCampaignConn,
    scratchConnFor,
    sentinelRelation,
    serverAnswers,
    stopOwnedServer,
    storeWorkflowCount,
  )
import Campaign.Cell (Cell (..), CellId (..), FixAttempt (..), cellForId, corpusCells, unCellId)
import Campaign.Dispatch
  ( DispatchAction (..),
    dispatchActionOfPlanLine,
    dispatchRegistry,
    dispatchWorkflowIdTagged,
    dispatchWorkflowName,
    planDispatchWorkflow,
  )
import Campaign.Fanout (runCellFanout)
import Campaign.Hands
  ( appPhaseBranchFor,
    campaignBranchFor,
    campaignWorktreePath,
    ensureCampaignWorktree,
    gitCapture,
    git_,
    parentDirtyCount,
  )
import Campaign.Landing
  ( LandingRecord (..),
    landProjectCellWorkflow,
    landingRecordOf,
    landingWorkflowId,
    landingWorkflowIdFor,
    landingWorkflowName,
  )
import Campaign.Matrix
  ( ArchName (..),
    ConfigName (..),
    MatrixAttempt (..),
    TriageIn (..),
    TriageOut (..),
    matrixAttemptsOf,
    matrixCellId,
    matrixCellSpecs,
    matrixCellWorkflow,
    matrixRegistry,
    matrixWorkflowIdTagged,
    matrixWorkflowName,
    mkMatrixCell,
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
    recordGlobalLessonSuperseding,
    recordLesson,
    startFixSession,
    startInfraSession,
  )
import Campaign.Mercury
  ( HelpCheckVerdict (..),
    HelpStageVerdict (..),
    MercuryAttempt (..),
    MercuryCell (..),
    MercuryEngine,
    MercuryFact (..),
    OracleVerdict (..),
    helpCheckCellFor,
    helpCheckRegistry,
    helpCheckWorkflowIdTagged,
    helpCheckWorkflowName,
    installedHelpCheckProbe,
    mercuryAttemptsOf,
    mercuryCellSpecs,
    mercuryCellWorkflow,
    mercuryHelpCheckWorkflow,
    mercuryIntegrationTag,
    mercuryOptionsPath,
    mercuryPrivCount,
    mercuryPromotionBranches,
    mercuryRegistry,
    mercuryScriptedEngine,
    mercuryWorkflowIdTagged,
    mercuryWorkflowName,
    mercuryWorktreeFor,
    oracleDumpProbe,
    oracleFactProbe,
    readMercuryFacts,
  )
import Campaign.Oracle
  ( CellOracle (..),
    ProjectCell (..),
    RepairRules (..),
    diagLineOf,
    markerOracle,
    projectCellSpecs,
    readProjectCell,
    repairRulesFor,
    scanProjectUnusedImportCells,
    unusedImportOracle,
  )
import Campaign.ReactFixer (reactEngineFor, scriptedReactEngine)
import Campaign.Real
import Campaign.RepairReceipt (loadRepairReceipt)
import Campaign.Review
  ( ApprovalOutcome (..),
    ReviewBranch (..),
    approveBranch,
    journalRefFor,
    listReviewBranches,
    rejectBranch,
  )
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
    projectCampaignWorkflowName,
    projectWorkflowId,
    stubEngine,
  )
import Control.Applicative ((<|>))
import Control.Concurrent.Async (mapConcurrently)
import Control.Exception (SomeException, try)
import Control.Monad (filterM, foldM_, forM, forM_, unless, void, when)
import Data.Aeson ()
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as BL
import Data.Either (isRight, lefts, rights)
import Data.Foldable (for_, traverse_)
import Data.IORef (atomicModifyIORef', modifyIORef', newIORef, readIORef, writeIORef)
import Data.List (find, groupBy, nub, partition, sort, sortOn)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, fromMaybe, isJust, listToMaybe, mapMaybe)
import Data.Set qualified as SSet
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Time.Clock (addUTCTime, getCurrentTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Data.Vector qualified as Vector
import Effectful (Eff, IOE, UnliftStrategy (..), liftIO, raise, runEff, withEffToIO)
import Effectful.Error.Static (Error, runErrorNoCallStack)
import GHC.Generics (Generic)
import Keiro.Codec (decodeRecorded)
import Keiro.Connection (keiroConnectionSettings)
import Keiro.Timer (TimerRow (..), deadLetterTimer)
import Keiro.Workflow
  ( WorkflowId (..),
    WorkflowJournalEvent (..),
    WorkflowName (..),
    WorkflowOutcome (..),
    cancelWorkflow,
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
import Kioku.AI.Config (AIExecutionError (..), AIFeature (..))
import Kioku.AI.File (loadAIRuntime)
import Kioku.AI.Runtime (AIRuntime, runAIProgram)
import Kioku.Api.Scope (MemoryScope (..), Namespace)
import Kioku.Distill.Consolidate (ConsolidateInput, ConsolidationDecision, consolidateProgram)
import Kioku.Distill.Extract
  ( ExtractInput (..),
    ExtractOutput (..),
    ExtractedAtom (..),
    extractSignature,
  )
import Kioku.Distill.L1 (L1Outcome (..), L1RunMode (..), L1Summary (..), distillSessionL1, scopedScanCandidates)
import Kioku.Distill.L2 (SceneRow (..), regenerateScene)
import Kioku.Distill.L3 (PersonaRow (..), regeneratePersona)
import Kioku.Distill.Persona (PersonaInput (..), PersonaOutput (..), personaSignature)
import Kioku.Distill.Runtime (TestRunners (..), newDistillRuntime, withDistillWorkspace, withTestRunners)
import Kioku.Distill.Scene (SceneInput (..), SceneOutput (..), sceneSignature)
import Kioku.Id (SessionId, parseId)
import Kioku.ReadModel (registerKiokuReadModels)
import Kiroku.Store qualified as Store
import Kiroku.Store.Connection (ConnectionSettings)
import Kiroku.Store.Effect (Store, runStoreResource)
import Kiroku.Store.Effect.Resource (KirokuStoreResource, withKirokuStore)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Types
  ( EventType (..),
    RecordedEvent (..),
    StreamName (..),
    StreamVersion (..),
  )
import Shikumi.Adapter (ToPrompt)
import Shikumi.Coder.Pipeline (ProposeIn (..))
import Shikumi.Coder.Task (PatchPlan (..))
import Shikumi.Error (ShikumiError (..))
import Shikumi.Module (predict)
import Shikumi.Program (Program)
import Shikumi.Schema (FromModel, ToSchema, Validatable)
import Shikumi.Schema.Types (Field (Field, unField), field)
import Shikumi.Signature (Demo (..), Signature, getInstruction, mkSignature, setDemos, setInstruction)
import Shikumi.Testing (markerResponse)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, removeFile)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..), exitFailure, exitSuccess)
import System.IO (hClose, hPutStrLn, openTempFile, stderr)
import Text.Read (readMaybe)
import Toy.Fixer.Domain (Source (..), sourceText)
import Toy.Fixer.Program (RepairOut (..))

main :: IO ()
main = do
  -- Operator mode: server lifecycle without running acts. The demo binary
  -- owns the server, so it owns the controls too.
  serverMode <- lookupEnv "SERVER"
  case fmap (T.unpack . T.toLower . T.strip . T.pack) serverMode of
    Just "status" -> serverStatusMode >> exitSuccess
    Just "stop" -> stopOwnedServer >> exitSuccess
    Just other -> fail ("SERVER=" <> other <> " — supported: status, stop")
    Nothing -> pure ()
  -- Discover mode: inspect verification units across all portfolio projects
  discoverMode <- lookupEnv "DISCOVER"
  case fmap (T.unpack . T.toLower . T.strip . T.pack) discoverMode of
    Just "json" -> discoverJsonMode >> exitSuccess
    Just "text" -> discoverTextMode >> exitSuccess
    Just other -> fail ("DISCOVER=" <> other <> " — supported: json, text")
    Nothing -> pure ()

  -- Schedule mode: compute and print memory-ranked schedule from Kioku lessons
  scheduleMode <- lookupEnv "SCHEDULE"
  case fmap (T.unpack . T.toLower . T.strip . T.pack) scheduleMode of
    Just "json" -> scheduleJsonMode >> exitSuccess
    Just "text" -> scheduleTextMode >> exitSuccess
    Just other -> fail ("SCHEDULE=" <> other <> " — supported: json, text")
    Nothing -> pure ()

  -- Evidence mode: query Kioku memory lessons and baselines
  evidenceMode <- lookupEnv "EVIDENCE"
  case fmap (T.unpack . T.strip . T.pack) evidenceMode of
    Just target -> evidenceOperatorMode target >> exitSuccess
    Nothing -> pure ()

  -- Operator mode: the human merge seam. The application phase lands
  -- repairs on campaign/<run> branches and stops — on purpose. REVIEW=list
  -- inventories the branches; REVIEW=approve|reject carries the operator's
  -- verdict on CAMPAIGN_REVIEW_BRANCH, journaled like every campaign event.
  reviewMode <- lookupEnv "REVIEW"
  case fmap (T.unpack . T.toLower . T.strip . T.pack) reviewMode of
    Just mode -> reviewOperatorMode mode >> exitSuccess
    Nothing -> pure ()
  -- Distillation mode: the operator round's verdict sessions are L0
  -- evidence; this mode runs kioku's L1 distiller over each of them so the
  -- approve/reject patterns become memory atoms the planner can recall.
  reviewDistill <- lookupEnv "REVIEW_DISTILL"
  case fmap (T.unpack . T.toLower . T.strip . T.pack) reviewDistill of
    Just "backfill" -> reviewBackfillMode >> exitSuccess
    Just "run" -> reviewDistillMode >> exitSuccess
    Just other -> fail ("REVIEW_DISTILL=" <> other <> " — supported: backfill, run")
    Nothing -> pure ()
  -- Verdict-probe mode: classify real logs through the same classifier act
  -- 23 uses, so an oracle change is validated against ground truth (archived
  -- matrix logs, hand-boot transcripts) before any cell pays for it.
  classifyMode <- lookupEnv "CLASSIFY"
  case classifyMode of
    Just spec -> classifyProbeMode spec >> exitSuccess
    Nothing -> pure ()
  replayMode <- lookupEnv "REPLAY"
  case replayMode of
    Just "mercury" -> runMercuryReplay >> exitSuccess
    Just other -> fail ("unknown REPLAY target: " <> other <> " (supported: mercury)")
    Nothing -> pure ()
  -- Operator mode: retire stale or superseded workflows from historical runs
  -- that nag the resume sweep (e.g. old Sail units).
  cleanupMode <- lookupEnv "CLEANUP"
  case fmap (T.unpack . T.toLower . T.strip . T.pack) cleanupMode of
    Just "stale" -> cleanupStaleWorkflows >> exitSuccess
    Just other -> fail ("unknown CLEANUP target: " <> other <> " (supported: stale)")
    Nothing -> pure ()
  putStrLn "[campaign] verification cells on keiro's durable runtime (shikumi decides, keiro journals, kioku remembers)"
  -- The demo runs all seventeen acts; a filter like ACTS=9 runs one act alone
  -- (against whatever journal state the database already has). The fix
  -- session is recorded exactly once per driver run: act 4 records it, act
  -- 5 distills it — or act 5 records it itself when act 4 was filtered out.
  acts <- lookupEnv "ACTS"
  let splitOnComma = T.splitOn "," . T.strip
      wanted = maybe [1 .. 22] (map (read . T.unpack) . splitOnComma . T.pack) acts
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
            20 -> runHelpCheckAct >> pure mSid
            21 -> runDispatchAct >> pure mSid
            22 -> runAppPhaseAct >> pure mSid
            23 -> runRealAct >> pure mSid
            24 -> runEscalationDistillAct >> pure mSid
            25 -> runMercuryReplayAct >> pure mSid
            n' -> fail ("unknown act: " <> show n')
  foldM_ step Nothing [1 .. 24 :: Int]

-- ---------------------------------------------------------------------------
-- Operator modes: discovery, scheduling, and evidence queries
-- ---------------------------------------------------------------------------

discoverJsonMode :: IO ()
discoverJsonMode = do
  units <- realUnitCells
  BL.putStr (Aeson.encode units <> "\n")

discoverTextMode :: IO ()
discoverTextMode = do
  units <- realUnitCells
  for_ units $ \u ->
    TIO.putStrLn (realCellKey u <> " (" <> ruKind u <> ")")

scheduleJsonMode :: IO ()
scheduleJsonMode = do
  units <- realUnitCells
  lessonsRef <- newIORef (Map.empty :: Map.Map Text [Text])
  withCampaignStore $ \store ->
    for_ (nub (map ruProject units)) $ \proj -> do
      notes <- requireEither =<< runCampaignStore store (recallNotes (projectNamespace proj))
      modifyIORef' lessonsRef (Map.insert proj notes)
  lessonsByProject <- readIORef lessonsRef
  let evidence = evidenceFromLessons (concat (Map.elems lessonsByProject))
      schedule = scheduleFromEvidence units evidence
  BL.putStr (Aeson.encode schedule <> "\n")

scheduleTextMode :: IO ()
scheduleTextMode = do
  units <- realUnitCells
  lessonsRef <- newIORef (Map.empty :: Map.Map Text [Text])
  withCampaignStore $ \store ->
    for_ (nub (map ruProject units)) $ \proj -> do
      notes <- requireEither =<< runCampaignStore store (recallNotes (projectNamespace proj))
      modifyIORef' lessonsRef (Map.insert proj notes)
  lessonsByProject <- readIORef lessonsRef
  let evidence = evidenceFromLessons (concat (Map.elems lessonsByProject))
      schedule = scheduleFromEvidence units evidence
  for_ (schRows schedule) $ \row ->
    TIO.putStrLn ("#" <> T.pack (show (seRank row)) <> " " <> realCellKey (seUnit row) <> " — " <> seWhy row)

evidenceOperatorMode :: String -> IO ()
evidenceOperatorMode target = do
  let targets = case target of
        "all" -> ["pgcl", "telix", "tessera", "organ-bank", "mowgli", "peirce", "mercury", "infra", "campaign"]
        other -> [T.pack other]
  withCampaignStore $ \store -> do
    resultsRef <- newIORef ([] :: [(Text, [Text])])
    for_ targets $ \proj -> do
      let ns = case proj of
            "infra" -> campaignInfraNamespace
            "campaign" -> campaignNamespace
            _ -> projectNamespace proj
      notes <- requireEither =<< runCampaignStore store (recallNotes ns)
      modifyIORef' resultsRef ((proj, notes) :)
    results <- reverse <$> readIORef resultsRef
    outputMode <- lookupEnv "EVIDENCE_FORMAT"
    case outputMode of
      Just "json" -> BL.putStr (Aeson.encode (Map.fromList results) <> "\n")
      _ -> for_ results $ \(proj, notes) -> do
        TIO.putStrLn ("[evidence] " <> proj <> " (" <> T.pack (show (length notes)) <> " notes):")
        if null notes
          then putStrLn "  (none)"
          else for_ notes (\n -> TIO.putStrLn ("  - " <> n))

-- ---------------------------------------------------------------------------
-- The human merge seam: operator verdicts over landed campaign branches
-- ---------------------------------------------------------------------------

-- | REVIEW=list | approve | reject over CAMPAIGN_REVIEW_BRANCH. Every
-- verdict is journaled into kioku — as a fix session whose turns are the
-- operator's actions — so memory holds the seam's history the same way it
-- holds every attempt and lesson.
reviewOperatorMode :: String -> IO ()
reviewOperatorMode mode = do
  mproj <- lookupEnv "CAMPAIGN_APP_PROJECT"
  let proj = maybe "mowgli" (T.strip . T.pack) mproj
  case mode of
    "list" -> do
      branches <- listReviewBranches proj
      mfmt <- lookupEnv "REVIEW_FORMAT"
      case mfmt of
        Just "json" -> BL.putStr (Aeson.encode branches <> "\n")
        _ -> do
          putStrLn ("[review] campaign branches of " <> T.unpack proj <> ":")
          if null branches
            then putStrLn "  (none)"
            else
              mapM_
                ( \b ->
                    putStrLn
                      ( "  "
                          <> T.unpack (rbBranch b)
                          <> "  +"
                          <> show (rbCommitsAhead b)
                          <> (if rbMerged b then "  [merged — safe to prune]" else "  [open]")
                      )
                )
                branches
    _ -> do
      mbranch <- lookupEnv "CAMPAIGN_REVIEW_BRANCH"
      branch <- maybe (fail ("REVIEW=" <> mode <> " needs CAMPAIGN_REVIEW_BRANCH=campaign/<run>")) (pure . T.strip . T.pack) mbranch
      unless ("campaign/" `T.isPrefixOf` branch) $
        fail ("CAMPAIGN_REVIEW_BRANCH must be a campaign/<run> branch, got: " <> T.unpack branch)
      case mode of
        "approve" -> reviewApprove proj branch
        "reject" -> reviewReject proj branch
        "answer" -> reviewAnswer proj branch
        other -> fail ("REVIEW=" <> other <> " — supported: list, approve, reject, answer")

-- | Approve: the receipts the operator presents (CAMPAIGN_REVIEW_RECEIPTS,
-- comma-separated paths — the repair evidence, admitted against the branch's
-- changed files before anything else), oracle re-verification of the
-- branch's bytes, then the --no-ff merge in the parent checkout (the human
-- sanction lifts the landing phase's never-touch-the-parent rule), the merge
-- commit attested with a Verification: trailer, and the verdict journaled.
reviewApprove :: T.Text -> T.Text -> IO ()
reviewApprove proj branch = do
  mrcpts <- lookupEnv "CAMPAIGN_REVIEW_RECEIPTS"
  rcs <- case mrcpts of
    Nothing -> pure Nothing
    Just spec -> do
      let paths = filter (not . null) . map (T.unpack . T.strip) . T.splitOn "," $ T.pack spec
      loaded <- forM paths $ \p -> do
        e <- loadRepairReceipt p
        case e of
          Left err -> pure (Left (p <> ": " <> T.unpack err))
          Right rc -> pure (Right rc)
      let errs = lefts loaded
      case errs of
        [] -> pure (Just (rights loaded))
        es -> fail $ "[review] receipt(s) failed to load:\n  " <> unlines es
  outcome <- approveBranch unusedImportOracle rcs proj branch
  mapM_
    (\d -> TIO.putStrLn ("  [gate] " <> d))
    (aoDiagnostics outcome)
  if T.null (aoMergeCommit outcome)
    then do
      putStrLn ("[review] " <> T.unpack branch <> " NOT merged — see gate lines above")
      exitFailure
    else do
      putStrLn
        ( "[review] "
            <> T.unpack branch
            <> " merged as "
            <> T.unpack (aoMergeCommit outcome)
            <> " ("
            <> show (length (aoFiles outcome))
            <> " file(s), re-verified clean before merge)"
        )
      mapM_ (TIO.putStrLn . ("    " <>)) (aoFiles outcome)
      let attLine =
            case aoAttestation outcome of
              Just h ->
                [ "attested " <> h <> " (Verification: trailer on the merge commit; journal " <> journalRefText (journalRefFor proj branch) <> ")"
                ]
              Nothing -> []
      journalVerdict proj branch "approve" . T.unlines $
        [ "merged as " <> aoMergeCommit outcome,
          T.intercalate ", " (aoFiles outcome)
        ]
          <> attLine
      mapM_ (TIO.putStrLn . ("    " <>)) attLine

-- | Answer: respond to a parked workflow's human-query awakeable — the
-- answering half of the escalation seam (act 2 proved the asking half).
-- CAMPAIGN_HUMAN_VERDICT=approve|reject (default approve), the awakeable id
-- from the @awkid:human-verdict@ journal step. The answer is journaled like
-- every operator act.
reviewAnswer :: T.Text -> T.Text -> IO ()
reviewAnswer proj branch = do
  maid <- lookupEnv "CAMPAIGN_HUMAN_AWAKEABLE"
  aidText <- maybe (fail "REVIEW=answer needs CAMPAIGN_HUMAN_AWAKEABLE=<uuid>") (pure . T.strip . T.pack) maid
  verdict <- do
    v <- lookupEnv "CAMPAIGN_HUMAN_VERDICT"
    pure $ case fmap (T.toLower . T.strip . T.pack) v of
      Just "reject" -> VerdictRejected
      _ -> VerdictApproved
  aid <- case Aeson.fromJSON (Aeson.String aidText) of
    Aeson.Success a -> pure (a :: AwakeableId)
    Aeson.Error e -> fail ("CAMPAIGN_HUMAN_AWAKEABLE is not a uuid: " <> e)
  withCampaignStore $ \store -> do
    signalled <- requireEither =<< runCampaignStore store (signalAwakeable aid verdict)
    if signalled
      then putStrLn ("[review] awakeable " <> T.unpack aidText <> " answered: " <> show verdict)
      else fail ("awakeable " <> T.unpack aidText <> " unknown or already signalled")
  journalVerdict proj branch "answer" $
    "answered parked human query " <> aidText <> " with " <> T.pack (show verdict)

-- | Reject: the branch and its worktree go away; the reason the operator
-- gives lives in the kioku session, not in git history.
reviewReject :: T.Text -> T.Text -> IO ()
reviewReject proj branch = do
  rejectBranch proj branch
  putStrLn ("[review] " <> T.unpack branch <> " rejected — branch and worktree removed")
  mreason <- lookupEnv "CAMPAIGN_REVIEW_REASON"
  journalVerdict proj branch "reject" $
    maybe "(no reason given)" (T.strip . T.pack) mreason

-- | The verdict, journaled: one fix session named for the verdict, its
-- turns the operator's actions. Kioku's distillers can promote these the
-- same way they promote any fix evidence.
journalVerdict :: T.Text -> T.Text -> T.Text -> T.Text -> IO ()
journalVerdict proj branch verdict detail =
  withCampaignStore $ \store -> do
    sid <- runKiokuWrite store (startFixSession (reviewNamespace proj) ("review " <> branch))
    _ <- runKiokuWrite store (recordFixTurn sid 1 "user" ("operator verdict: " <> verdict))
    _ <- runKiokuWrite store (recordFixTurn sid 2 "assistant" detail)
    _ <- runKiokuWrite store (completeFixSession sid ("verdict " <> verdict <> ": " <> detail))
    putStrLn "[review] verdict journaled to kioku"

-- | Kioku namespaces forbid %, / and : — a slash-y project path like
-- @tessera/third_party/islaris@ becomes @tessera.third_party.islaris@.
-- Deterministic, so every verdict for one project lands in one namespace.
reviewNamespace :: T.Text -> Namespace
reviewNamespace = projectNamespace . T.replace "/" "." . T.replace "%" "" . T.replace ":" ""

-- ---------------------------------------------------------------------------
-- Distilling the review verdicts: evidence becomes memory
-- ---------------------------------------------------------------------------

-- | REVIEW_DISTILL=backfill: journal the verdicts that predate the journal
-- (islaris's approve crashed on the namespace bug after the merge but before
-- journaling). The session and its turns are idempotent writes — a re-run
-- makes no duplicate — so backfill converges exactly like every other step.
reviewBackfillMode :: IO ()
reviewBackfillMode = do
  let proj = "tessera/third_party/islaris" :: T.Text
      branch = "campaign/app-app1789583141" :: T.Text
  withCampaignStore $ \store -> do
    sid <- runKiokuWrite store (startFixSession (reviewNamespace proj) ("review " <> branch))
    _ <- runKiokuWrite store (recordFixTurn sid 1 "user" "operator verdict: approve")
    _ <-
      runKiokuWrite
        store
        ( recordFixTurn
            sid
            2
            "assistant"
            ( T.unlines
                [ "merged as 408a879",
                  "generate_data.py",
                  "Backfilled: the verdict was carried out live (merge 408a879 on main, branch retired) but its journaling crashed on the namespace slash before the fix; this session records it for the distiller."
                ]
            )
        )
    _ <- runKiokuWrite store (completeFixSession sid "verdict approve: merged as 408a879 (backfilled)")
    putStrLn "[review] backfilled islaris verdict session"

-- | REVIEW_DISTILL=run: distill every review verdict session in the journal.
-- The verdicts live in the store's own $all log (SessionStarted events
-- carrying a "review " focus), so the store itself says what is distillable —
-- the same read-state-not-assumptions rule the planner's journal walk uses.
-- Each pass runs kioku's stock L1 distiller with the campaign's shape-contract
-- extract runner; per-session verdicts become scoped atoms, and the
-- consolidate step may promote a cross-session pattern (e.g. the vendored-pin
-- reject rule) when the extracted atoms support one.
reviewDistillMode :: IO ()
reviewDistillMode = do
  cfgJSON <- campaignAIConfigJSON
  (cfgPath, cfgHandle) <- openTempFile "/tmp" "campaign-ai.json"
  BL.hPut cfgHandle cfgJSON
  hClose cfgHandle
  air <- loadAIRuntime False (Just cfgPath)
  removeFile cfgPath
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
    events <-
      requireEither
        =<< runCampaignStore
          store
          (Store.readAllForward (Store.GlobalPosition 0) 10000)
    -- The verdict sessions, oldest first: SessionStarted events whose focus
    -- names a review, from the store's own log.
    let verdictSessions =
          [ (sidText, focus)
          | ev <- Vector.toList events,
            EventType etext <- [ev.eventType],
            etext == "SessionStarted",
            Just pv <- [payloadValue ev],
            Just inner <- [objAt "data" pv],
            Just (Aeson.String focus) <- [objAt "focus" inner],
            -- startFixSession renders the focus as "fix <path>", and the
            -- verdict sessions' path is "review <branch>" — hence the
            -- double prefix here.
            "fix review " `T.isPrefixOf` focus,
            Just (Aeson.String sidText) <- [objAt "sessionId" inner]
          ]
        -- The payload type varies across kiroku versions (Value vs KeyMap);
        -- the JSON round-trip normalizes it, and the DB's jsonb shape —
        -- {"data": {sessionId, focus, ...}} — is what both produce.
        payloadValue ev = Aeson.decode (Aeson.encode ev.payload)
        objAt k v = case v of
          Aeson.Object o -> KeyMap.lookup (Key.fromText k) o
          _ -> Nothing
    -- Vector.toList is $all-forward (oldest first), so the verdicts
    -- arrive in verdict order with no extra sort.
    putStrLn
      ( "[review] "
          <> show (length [() | ev <- Vector.toList events, EventType et <- [ev.eventType], et == "SessionStarted"])
          <> " session event(s) in the journal, "
          <> show (length verdictSessions)
          <> " verdict session(s) to distill"
      )
    for_ verdictSessions $ \(sidText, focus) ->
      case parseId sidText of
        Left err ->
          putStrLn ("  skip " <> T.unpack focus <> " (unparseable id: " <> T.unpack err <> ")")
        Right sid -> do
          result <-
            runCampaignStore store $
              distillSessionL1
                campaignAccessContext
                -- Forced: re-running each session re-extracts and feeds the
                -- overlapping atoms through consolidation, so paraphrase
                -- clusters (six rejects stating one vendored-pin rule)
                -- deduplicate instead of accumulating.
                IgnoreWatermark
                distillRT
                (scopedScanCandidates 8)
                sid
          case result of
            Left err -> putStrLn ("  store error on " <> T.unpack focus <> ": " <> show err)
            Right (Left err) -> putStrLn ("  distill failed on " <> T.unpack focus <> ": " <> show err)
            Right (Right L1SkippedUpToDate) ->
              putStrLn ("  up-to-date: " <> T.unpack focus)
            Right (Right (L1Distilled summary)) ->
              putStrLn
                ( "  distilled "
                    <> T.unpack focus
                    <> ": "
                    <> show summary.extracted
                    <> " extracted, "
                    <> show summary.stored
                    <> " stored, "
                    <> show summary.merged
                    <> " merged, "
                    <> show summary.skipped
                    <> " skipped"
                )
    -- The proof: what memory now holds about reviews.
    for_ ["mowgli", "tessera.third_party.sail", "tessera.third_party.islaris", "tessera.third_party.sail-x86-from-acl2"] $ \ns -> do
      notes <- requireEither =<< runCampaignStore store (recallNotes (projectNamespace ns))
      putStrLn ("  memory[" <> T.unpack ns <> "]: " <> show (length notes) <> " note(s)")
      for_ notes (TIO.putStrLn . ("    - " <>))

-- ---------------------------------------------------------------------------
-- Store plumbing (jitsurei's shape; no projection schema — the journal is
-- the campaign's audit trail, so the demo reads events back directly)
-- ---------------------------------------------------------------------------

type CampaignEffects = '[Store, Error StoreError, KirokuStoreResource, IOE]

-- | A store handle: run any @Store@ effect block to IO.
newtype CampaignStore = CampaignStore
  { runCampaignStore :: forall a. Eff CampaignEffects a -> IO (Either StoreError a)
  }

-- | Operator mode: report the server picture without running acts — and
-- without /changing/ it. Status never starts or stops anything: it reports
-- the owned server's liveness, where its state lives, and which connection
-- the acts would resolve (the env string when set and answering, the owned
-- server otherwise).
serverStatusMode :: IO ()
serverStatusMode = do
  stateDir <- ownedServerStateDir
  alive <- ownedServerAlive
  envConn <- lookupEnv "PG_CONNECTION_STRING"
  putStrLn
    ( "[server] owned server: "
        <> (if alive then "UP" else "down")
        <> " (state: "
        <> stateDir
        <> ")"
    )
  case fmap T.pack envConn of
    Just raw | not (T.null (T.strip raw)) -> do
      envAlive <- serverAnswers (parseCampaignConn raw)
      putStrLn
        ( "[server] campaign connection (env): "
            <> T.unpack (T.strip raw)
            <> if envAlive then " — answering" else " — DOES NOT ANSWER (acts would fail with guidance)"
        )
    _ -> do
      conn <- ownedServerConn
      putStrLn
        ( "[server] campaign connection (owned server): "
            <> T.unpack (renderCampaignConn conn {ccPassword = Nothing})
            <> (if alive then "" else " — would be started on the next act run")
        )

-- | The campaign keeps no read models of its own, so it needs no projection
-- schema of substance: keiro's settings with a campaign projection-schema tag.
-- (Argument order matters: connString first, schema second.)
campaignConnectionSettings :: Text -> ConnectionSettings
campaignConnectionSettings connString = keiroConnectionSettings connString "campaign"

-- | The campaign store on an explicit connection — the parameterized scope
-- (act 14's scratch store uses this directly).
withCampaignStoreAt :: T.Text -> (CampaignStore -> IO ()) -> IO ()
withCampaignStoreAt connString action = do
  hPutStrLn stderr ("[campaign] connecting to " <> T.unpack connString)
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
  hPutStrLn
    stderr
    ( if applied == 0
        then "[bootstrap] store current (schema present, nothing to apply)"
        else
          "[bootstrap] applied "
            <> show applied
            <> " migration file(s) to "
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
  rights (decodeRecorded workflowJournalCodec <$> events)

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
              print other

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

-- | @Keiro.Workflow.Types@ keeps 'WorkflowName''s accessor internal; the act
-- compares discovery's text against the name constant through this wrapper.
unWorkflowName' :: WorkflowName -> Text
unWorkflowName' (WorkflowName t) = t

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

-- | Operator cleanup: retire stale or orphaned workflows with a typed
-- cancellation — journal event recorded, never a silent delete.
-- Resolves the old Sail lexing/analysis units that nag the resume sweep.
cleanupStaleWorkflows :: IO ()
cleanupStaleWorkflows = withCampaignStore $ \store -> do
  putStrLn "[cleanup] scanning for stale/orphaned workflows..."
  now <- getCurrentTime
  pairs <- requireEither =<< runCampaignStore store (findUnfinishedWorkflowIds now)
  let isSailUnit (name, wid) =
        name == unWorkflowName' projectCampaignWorkflowName
          && ("sail" `T.isInfixOf` wid || "tessera" `T.isInfixOf` wid)
      discoveredStale = filter isSailUnit pairs
      knownOrphaned =
        [ (unWorkflowName' projectCampaignWorkflowName, "pcell-app-app1789643209-sail-x86-from-acl2:translator/validation/automation/analyseOutput.py"),
          (unWorkflowName' projectCampaignWorkflowName, "pcell-app-app1789652435-tessera/third_party/sail:test/lexing/run_tests.py")
        ]
      allTargets = nub (discoveredStale ++ knownOrphaned)
  if null allTargets
    then putStrLn "  no stale workflows found"
    else for_ allTargets $ \(nameText, idText) -> do
      outcome <- requireEither =<< runCampaignStore store (cancelWorkflow (WorkflowName nameText) (WorkflowId idText))
      putStrLn ("  retired: " <> T.unpack nameText <> " [" <> T.unpack idText <> "] -> " <> show outcome)
  putStrLn "[cleanup] done"

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
          <> " already exists; the demo replays completed journals — point "
          <> "PG_CONNECTION_STRING at a fresh database, or (operator mode) "
          <> "SERVER=stop and clear the owned server's state directory"
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
        when inserted
          $ liftIO
          $ putStrLn ("  published human-query awakeable id: " <> T.unpack (awakeableIdText aid))
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
      [fa]
        | fa.faAttempt == 1 && fa.faSucceeded ->
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
            "attempt "
              <> T.pack (show fa.faAttempt)
              <> ": diagnostics before: "
              <> T.intercalate " | " (fa.faDiagnosticsBefore)
              <> "; after: "
              <> (if T.null diagLine then "(clean)" else diagLine)
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
  pure
    $ Aeson.encode
    $ Aeson.object
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
shapeDemo =
  Demo
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
            ( "  distilled: "
                <> show summary.extracted
                <> " candidate(s) extracted, "
                <> show summary.stored
                <> " stored, "
                <> show summary.merged
                <> " merged, "
                <> show summary.skipped
                <> " skipped"
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

-- | The honest fleet "model": applies the repair contract the diagnostics
-- imply to the /actual oracle/'s view of the /actual cell/ — delete the
-- droppable flagged statements, and rewrite a partially-used statement to
-- exactly the contract's canonical kept-name line. A live model does the
-- same because the diagnostics and lessons ride the prompt; this stub does
-- it textually. The repair is still checked by the real no-regression guard
-- and the surgical contract guard, and the oracle still re-scores what
-- survived, so a wrong lesson application fails honestly.
honestEngineFor :: EngineFor
honestEngineFor oracle cell = stubEngine (\_n _ctx -> markerResponse [("repaired", repaired)])
  where
    orig = cellCurrent cell
    diags = oracleCheck oracle (cellPath cell) (cellCurrent cell)
    rules = repairRulesFor orig (map diagLineOf diags)
    origLines = T.lines (sourceText orig)
    kept =
      [ l
      | (i, l) <- zip [1 :: Int ..] origLines,
        not (i `SSet.member` SSet.fromList (rrDroppableLines rules))
      ]
    repaired = case rrRewrite rules of
      -- The rewrite line replaces the original's span (one line here; a
      -- multi-line span would need the same line arithmetic the guard does,
      -- and no stub corpus cell has one).
      Just (rn, txt) -> T.unlines [if i == rn then txt else l | (i, l) <- zip [1 :: Int ..] origLines, i == rn || not (i `SSet.member` SSet.fromList (rrDroppableLines rules))]
      Nothing -> T.unlines kept

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
-- | The fire action for non-sleep (process-manager) timers this campaign's
-- driver does not own. Kioku's consolidation timers (L1 extract, L2 scene,
-- L3 persona) belong to a kioku deployment's own timer worker; in this
-- campaign every distillation pass runs inline inside the acts, so those
-- rows carry no outstanding work. A no-op fallback strands each claimed row
-- in @firing@ forever — and the stranded rows re-claim ahead of workflow
-- sleeps (fire_at order), starving every campaign's settle/cool timers.
-- The honest disposition is kioku's own FireDeferred semantics: dead-letter
-- the row with an operator-visible note. Anything else stays untouched.
campaignTimerPmFallback :: TimerRow -> Eff CampaignEffects (Maybe Store.EventId)
campaignTimerPmFallback row
  | "kioku-" `T.isPrefixOf` row.processManagerName = do
      _ <-
        deadLetterTimer
          row.timerId
          "campaign driver: kioku consolidation timer deferred — distillation passes run inline in this campaign; no timer worker owns them here"
      pure Nothing
  | otherwise = pure Nothing

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
      loop :: Int -> IO ()
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
                      (drainWorkflowSleepTimers Nothing fireTime 100 campaignTimerPmFallback)
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
      ( "  "
          <> label
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
withLoadedAIRuntime action = withAIRuntime (void . action)

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
-- scanned out of the actual checkouts (mowgli: @src/adapters/llada_interface.py@; peirce:
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
  for_
    [ ("mowgli", "an unused import must have its whole import line deleted"),
      ("peirce", "delete the whole import line flagged unused; never leave a stub")
    ]
    $ \(proj, advice) ->
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
          withDistillWorkspace
            mirrorRoot
            ( withTestRunners
                (newDistillRuntime air Nothing)
                (\tr -> tr {runScene = campaignSceneRunner air, runPersona = campaignPersonaRunner air})
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
              ( "    body: "
                  <> show (T.length row.bodyMd)
                  <> " chars, "
                  <> show (length row.atomIds)
                  <> " atom(s) distilled"
              )
        personaR <- requireEither =<< runCampaignStore store (regeneratePersona distillRT campaignMemorySpace gscope)
        case personaR of
          Left err -> fail ("persona regeneration failed: " <> show err)
          Right Nothing -> putStrLn ("  [" <> T.unpack proj <> "] persona: no scenes to distill")
          Right (Just prow) ->
            putStrLn
              ( "  ["
                  <> T.unpack proj
                  <> "] persona: "
                  <> show prow.sceneCount
                  <> " scene(s), "
                  <> show (T.length prow.bodyMd)
                  <> " chars of markdown"
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
            withDistillWorkspace
              "/tmp/campaign-mirrors"
              ( withTestRunners
                  (newDistillRuntime air Nothing)
                  (\tr -> tr {runScene = campaignSceneRunner air, runPersona = campaignPersonaRunner air})
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

      -- The chosen cell runs the live campaign under a fresh journal prefix.
      let cell = chosenCell {cellId = CellId ("live2:" <> chosenCellName)}
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
      let accepted = [r | FixAttempt {faRepaired = Just r} <- journaledAttempts (decodedJournal journal)]
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
              ( "  landed "
                  <> T.unpack (lrProject recd <> ":" <> lrPath recd)
                  <> " — commit "
                  <> T.unpack (lrCommit recd)
                  <> " on "
                  <> T.unpack (lrBranch recd)
                  <> " ("
                  <> T.unpack (lrWorktree recd)
                  <> ")"
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
    log' <- gitCapture wt ["log", "--oneline", T.unpack (campaignBranchFor proj)]
    putStrLn ("  " <> T.unpack proj <> " branch log:")
    for_ (T.lines log') (putStrLn . ("    " <>) . T.unpack)
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
  let scriptedRegistry = campaignRegistry pcs [] scriptedReactEngine noPublisherEff
  launchCells specs scriptedReactEngine
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
          [ ( rcell' pc,
              unusedImportOracle,
              projectNamespace (pcProject pc),
              projectCampaignWorkflowName,
              projectWorkflowId2 livePrefix (pcProject pc) (pcPath pc)
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
        liveRegistry = campaignRegistry pcs [] (reactEngineFor air) noPublisherEff
    launchCells lspecs (reactEngineFor air)
    withCampaignStore $ \store -> do
      fireTimerSweep store liveRegistry [(s, "sleep:settle-" <> T.pack (show n)) | (_, s, _, _) <- lrows, n <- [1 :: Int .. 3]]
      drainFleet store liveRegistry ourLIds
    putStrLn "[react-live] journal scoreboard:"
    withCampaignStore $ \store -> do
      printCellScoreboard store liveRegistry lrows
      remaining <- ourUnfinished store ourLIds
      unless (null remaining) $
        putStrLn
          ( "  [react-live] "
              <> show (length remaining)
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
          let accepted = [r | FixAttempt {faRepaired = Just r} <- journaledAttempts (decodedJournal journal)]
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
                    ( "  ["
                        <> labelOf pfx
                        <> "] landed "
                        <> T.unpack (lrProject recd <> ":" <> lrPath recd)
                        <> " — commit "
                        <> T.unpack (lrCommit recd)
                        <> " on "
                        <> T.unpack (lrBranch recd)
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
    ),
    ( "freshness",
      "store freshness is data, not schema: keiro.keiro_workflows absent means"
        <> " unmigrated, present and empty means fresh; the driver self-boots before"
        <> " opening the store, so dropdb followed by a rerun just works"
    ),
    ( "server",
      "the private Postgres cluster lives in the arena repo (db/campaign-private,"
        <> " socket db/campaign-private-socket, trust auth, user campaign);"
        <> " PG_CONNECTION_STRING carries user= explicitly because the notifier"
        <> " does not inherit PGUSER"
    ),
    ( "read-model",
      "the campaign's read model is one keiki symbolic-register transducer over"
        <> " cell journals (CellOpen -> Cleared/Escalated with a non-terminal"
        <> " CellHumanQueried vertex), fed two ways: offline replay via keiro's"
        <> " replayEvents, and live through a shibuya app over the shibuya-kiroku adapter"
    ),
    ( "agreement",
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
              ( "  distilled: "
                  <> show summary.extracted
                  <> " candidate(s) extracted, "
                  <> show summary.stored
                  <> " stored, "
                  <> show summary.merged
                  <> " merged, "
                  <> show summary.skipped
                  <> " skipped"
              )

    -- (3) Promote the operational essentials to the infra namespace's global
    -- scope — the units recall serves to planners and fresh operators.
    for_
      [ "the store self-boots: an empty database gets the kiroku, keiro and kioku"
          <> " migrations applied in-process (56 idempotent files); freshness is"
          <> " keiro.keiro_workflows being present and empty; the private cluster"
          <> " lives at db/campaign-private with its socket at db/campaign-private-socket",
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

genTag :: IO Text
genTag = T.pack . show . (floor :: Double -> Int) . realToFrac . utcTimeToPOSIXSeconds <$> getCurrentTime

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
  runTag <- genTag
  sink <- newIORef []
  let publishHumanQuery :: AwakeableId -> Eff CampaignEffects ()
      publishHumanQuery aid = do
        inserted <-
          liftIO $
            atomicModifyIORef' sink $ \published ->
              if aid `elem` published
                then (published, False)
                else (published <> [aid], True)
        when inserted
          $ liftIO
          $ putStrLn ("  published human-query awakeable id: " <> T.unpack (awakeableIdText aid))

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
        ( "  "
            <> T.unpack (unCellId (matrixCellId mc))
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
  (plan, _matrixHealthy) <- planPortfolio
  putStrLn ("  priority: " <> T.unpack (unField plan.ppPriority))
  for_ plan.ppNext $ \nx ->
    putStrLn
      ( "    "
          <> T.unpack (unField nx.anProject)
          <> " -> "
          <> T.unpack (unField nx.anAction)
          <> " ["
          <> T.unpack (unField nx.anDispatch)
          <> "] :: "
          <> T.unpack (T.take 110 (unField nx.anWhy))
      )
  putStrLn "[cross-plan] done — one portfolio, one persona, one plan, recorded"

-- | The portfolio-to-plan pipeline both act 17 (print + record) and act 21
-- (dispatch) share: read every cell journal from the store, record the
-- cross-project lessons, distill the persona, and call the live planner.
-- Returns the plan and the matrix-health flag the honesty checks use.
planPortfolio :: IO (PortfolioOutput, Bool)
planPortfolio = do
  putStrLn "[portfolio] reading every cell journal in the store"
  resultRef <- newIORef (error "planPortfolio: store block did not run")
  withCampaignStore $ \store -> do
    journalRows <- portfolioJournalRows store
    summaries <-
      forM journalRows $ \(label, stream, vertexHint) -> do
        events <- readJournal store stream
        let wjes = rights (decodeRecorded workflowJournalCodec <$> events)
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
      ( "  toy cells: "
          <> show (length toyRows)
          <> " ("
          <> show (length toyDone)
          <> " done, "
          <> show (length toyOpen)
          <> " open)"
      )
    putStrLn
      ( "  project cells: "
          <> show (length projectRows)
          <> " ("
          <> show (length projectDone)
          <> " done, "
          <> show (length projectOpen)
          <> " open)"
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
      ( "  cross lessons recallable: mowgli "
          <> show (length mowgliRecall)
          <> " note(s), peirce "
          <> show (length peirceRecallEarly)
          <> " note(s)"
      )

    -- One distilled persona at the portfolio's global scope, read back
    -- through kioku's own L3 API (the same path act 8 uses per project).
    personaText <- withAIRuntime $ \air -> do
      let distillRT =
            withDistillWorkspace
              "/tmp/campaign-mirrors"
              ( withTestRunners
                  (newDistillRuntime air Nothing)
                  (\tr -> tr {runScene = campaignSceneRunner air, runPersona = campaignPersonaRunner air})
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
        ( "    "
            <> T.unpack (unField nx.anProject)
            <> " -> "
            <> T.unpack (unField nx.anAction)
            <> " ["
            <> T.unpack (unField nx.anDispatch)
            <> "] :: "
            <> T.unpack (T.take 110 (unField nx.anWhy))
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
    writeIORef resultRef (plan, matrixHealthy)
  readIORef resultRef

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
    anDispatch :: Field "dispatch class — exactly one of the three words: execute, delegate, or verify (never a project name, never a phrase)" Text,
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
    \— the dispatch field is exactly one of the three words execute, \
    \delegate, or verify — plus the one highest-priority item. Obey \
    \the persona; use the recalled lessons; prefer actions that reuse proven \
    \machinery over novel machinery."

-- | The wire-shape contract, as in act 10's planner: fields only, no prose.
portfolioContractInstruction :: Text
portfolioContractInstruction =
  "Reply in the exact wire shape demonstrated: a priority field holding one \
  \sentence, and a next list holding exactly one entry per project with \
  \project, action, dispatch, and why fields. The dispatch field of every \
  \entry is exactly one of the three words: execute, delegate, or verify \
  \(lowercase, alone, no project names). Never reply with prose outside \
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
  T.unlines
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
    splitDone = partition ((\v -> v == "cleared" || v == "escalated") . prVertex)

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
  runTag <- genTag
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
        when inserted
          $ liftIO
          $ putStrLn ("  published human-query awakeable id: " <> T.unpack (awakeableIdText aid))
      streamOf opt = campaignStreamNameText mercuryWorkflowName (mercuryWorkflowIdTagged opt runTag)

      -- The GOOD responder builds the marker sections from the TYPED
      -- ProposeIn the engine call carries: the fact's line verbatim
      -- (first-line indentation stripped — the wire strips section edge
      -- whitespace and the applier re-indents), constructor swapped. That
      -- is exactly what a good model emits.
      factOldLine :: ProposeIn -> Text
      factOldLine pin
        | h : _t <- T.lines . unField $ piFact pin =
            snd $ T.breakOnEnd ": " h
        | otherwise =
            ""
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
      ( "  fact: --"
          <> T.unpack (mfOption f)
          <> " at options.m:"
          <> show (mfLineNo f)
          <> " ("
          <> T.unpack (mfConstructor f)
          <> " -> "
          <> T.unpack (mfPublicConstructor f)
          <> ")"
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
            <> " — "
            <> T.unpack (ovDetail negV)
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
          ( "    attempt "
              <> show (meAttempt ma)
              <> ": "
              <> T.unpack (meVerdict ma)
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
              ( "  distilled: "
                  <> show summary.extracted
                  <> " candidate(s) extracted, "
                  <> show summary.stored
                  <> " stored"
              )
    for_
      [ "mercury promotion = one cell per private option: propose ONE verbatim-line edit,"
          <> " exact-once guard, then the two-probe oracle (fact probe: private gone, public in,"
          <> " priv-count -1; dump probe: mmc --grade hlc.gc --dump-mlds 99 emits .c_dump.099-final)",
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
-- The Mercury replayable demo: the whole promotion drama on demand
-- ===========================================================================

-- | The campaign clone the Mercury track works against (the clean checkout
-- with the dump family still private).
mercuryCampaignClone :: FilePath
mercuryCampaignClone = "/home/nyc/src/mercury-campaign"

-- | REPLAY=mercury (or act 25): the promotion campaign as an on-demand,
-- on-the-rails demo. Preflight proves every piece of ground truth BEFORE
-- any cell starts — tree and facts, the compiler oracle, and the human
-- seam wire (the awakeable id that the operator answers). Three engines:
--   * MERCURY_ENGINE unset — the deterministic scripted responder (act 18's
--     drama: one stale first attempt, informed retry, landing).
--   * MERCURY_ENGINE=live — the real model via the live stack (act 19's
--     engine; the same typed pipeline, honest model failures).
--   * MERCURY_ENGINE=replay — no model at all: re-run the oracle and the
--     fact probe over every existing per-run landing, then a replay tally
--     over the journaled attempts — pure verification of what previous
--     runs decided, zero cost.
-- MERCURY_CLEAN=1 prunes this demo's own worktrees and branches first (a
-- ref-by-ref loop through git worktree remove + branch -D, ignoring errors;
-- the journals keep the history). Never touches the parent checkout.
runMercuryReplay :: IO ()
runMercuryReplay = do
  putStrLn "\n=== mercury replay: the promotion campaign as a demo ==="
  replayTag <- genTag

  -- ---------------------------------------------------------------- (1)
  -- Preflight 1: the tree and its facts. The demo cannot start without
  -- ground truth to work from.
  putStrLn "[preflight] tree + facts"
  optsExists <- doesFileExist (mercuryOptionsPath mercuryCampaignClone)
  unless optsExists $
    fail ("mercury replay: the campaign clone is missing at " <> mercuryCampaignClone)
  facts <- readMercuryFacts mercuryCampaignClone
  if null facts
    then
      putStrLn
        ( "  clone is fully promoted (no private dump-family lines in "
            <> mercuryOptionsPath mercuryCampaignClone
            <> ") — scripted/live runs have nothing to do; use MERCURY_ENGINE=replay"
        )
    else for_ facts $ \f ->
      putStrLn
        ( "  fact: --"
            <> T.unpack (mfOption f)
            <> " at options.m:"
            <> show (mfLineNo f)
            <> " ("
            <> T.unpack (mfConstructor f)
            <> " -> "
            <> T.unpack (mfPublicConstructor f)
            <> ")"
        )
  privNow <- mercuryPrivCount mercuryCampaignClone
  putStrLn ("  private registrations in the tree: " <> show privNow)

  -- ---------------------------------------------------------------- (2)
  -- Optional cleanup of prior run state (worktrees first, then branches — a
  -- ref-by-ref loop, ignoring per-ref errors so a half-removed state cannot
  -- wedge the sweep). NOTE: this removes EVERY campaign/mercury-* worktree
  -- and branch — scripted-run landings AND live-run landings alike; the
  -- journals keep the history. Never touches the parent checkout. And the
  -- journals are not inert: the driver's resume sweeps are store-wide, so
  -- workflows parked on old cool-down timers will RE-LAND their branches on
  -- the next scripted/live run — cleanup clears the git artifacts, not the
  -- durable intentions.
  doClean <- (== "1") . fromMaybe "" <$> lookupEnv "MERCURY_CLEAN"
  when doClean $ do
    putStrLn "[cleanup] pruning every campaign/mercury-* worktree and branch"
    branches <- map snd <$> mercuryPromotionBranches mercuryCampaignClone
    for_ branches $ \b -> do
      let wt = mercuryWorktreeFor "mercury" b
      wtExists <- doesDirectoryExist wt
      when wtExists $ do
        _ <- guardTry (git_ mercuryCampaignClone ["worktree", "remove", "--force", wt])
        pure ()
      _ <- guardTry (git_ mercuryCampaignClone ["branch", "-D", T.unpack b])
      pure ()
    git_ mercuryCampaignClone ["worktree", "prune"]
    putStrLn ("  removed " <> show (length branches) <> " campaign branch(es) and their worktrees")

  -- ---------------------------------------------------------------- (3)
  -- Preflight 2: the compiler oracle — the dump probe must pass on the
  -- INSTALLED mmc before any cell is allowed to run.
  putStrLn "[preflight] compiler oracle (dump probe on the installed mmc)"
  dumpV <- oracleDumpProbe ("replay-" <> replayTag)
  putStrLn ("  dump probe: " <> (if ovOk dumpV then "ok — " else "FAILED — ") <> T.unpack (ovDetail dumpV))
  unless (ovOk dumpV) $ fail "mercury replay: the dump oracle failed on the installed compiler"

  -- ---------------------------------------------------------------- (4)
  -- Engine choice and the run itself.
  engineName <- fromMaybe "scripted" <$> lookupEnv "MERCURY_ENGINE"
  case engineName of
    "replay" -> do
      -- Pure verification: no model, no writes. For every landing, re-run
      -- the fact probe honestly: materialize a detached verify-worktree at
      -- the landing's PARENT commit (the no-regression leg compares against
      -- the pre-edit HEAD, so verifying in place would compare the landing
      -- against itself and misreport), then apply the landing's options.m
      -- diff as working-tree changes and probe that.
      putStrLn "[replay] verifying existing landings (no model calls)"
      landings0 <- mercuryPromotionBranches mercuryCampaignClone
      -- mercuryPromotionBranches matches by known-target prefix, so a
      -- dump-mlds-pred-name branch comes back twice (once as dump-mlds).
      -- Derive each branch's owner from the branch NAME instead, longest
      -- known target first, and dedupe by branch.
      let branches = nub (map snd landings0)
          landings = [(opt, b) | b <- branches, Just opt <- [mercuryBranchOwner b]]
      if null landings
        then putStrLn "  no campaign/mercury-* landings exist yet — nothing to replay"
        else for_ landings $ \(opt, branch) -> do
          mf <- case [f | f <- facts, mfOption f == opt] of
            (f : _) -> pure (Just f)
            [] -> pure Nothing
          case mf of
            Nothing ->
              putStrLn
                ( "  --"
                    <> T.unpack opt
                    <> " ["
                    <> T.unpack branch
                    <> "]: no fact for this option"
                    <> " — fact probe not applicable"
                )
            Just f -> do
              v <- withVerifyWorktree branch $ \vt -> oracleFactProbe vt f
              putStrLn
                ( "  --"
                    <> T.unpack opt
                    <> " ["
                    <> T.unpack branch
                    <> "]: "
                    <> (if ovOk v then "still verifies" else "REGRESSED")
                    <> " — "
                    <> T.unpack (ovDetail v)
                )
    "live" -> do
      putStrLn "[campaign] the promotion cells under the live engine (REPLAY running act-19's shape)"
      runLiveMercuryAct
    "scripted" -> do
      putStrLn "[campaign] the promotion cells under the scripted engine (REPLAY running act-18's shape)"
      runMercuryAct
    other -> fail ("mercury replay: unknown MERCURY_ENGINE " <> other <> " (scripted | live | replay)")

  -- ---------------------------------------------------------------- (5)
  -- The replay tally: every campaign/mercury-* landing, subject + age, so
  -- the demo ends with the durable artifact, not a printout.
  putStrLn "[tally] campaign landings in the clone"
  landingsT <- nub . map snd <$> mercuryPromotionBranches mercuryCampaignClone
  if null landingsT
    then putStrLn "  (none)"
    else for_ landingsT $ \branch -> do
      subject <- gitCapture mercuryCampaignClone ["log", "-1", "--format=%s", T.unpack branch]
      age <- gitCapture mercuryCampaignClone ["log", "-1", "--format=%cr", T.unpack branch]
      putStrLn ("  " <> T.unpack branch <> "  “" <> T.unpack subject <> "”  (" <> T.unpack age <> ")")
  dirty <- parentDirtyCount "mercury"
  putStrLn ("  parent checkout dirty entries: " <> show dirty)
  putStrLn "[mercury replay] done"
  where
    -- \| The option a @campaign/mercury-…@ branch lands: the leaf after
    -- @mercury-@ STARTS with the option name (then @-<runtag>@ or the
    -- help/integration shapes, which own no option). Longest target first
    -- so @dump-mlds-pred-name-…@ is not misread as @dump-mlds@.
    mercuryBranchOwner :: Text -> Maybe Text
    mercuryBranchOwner b = do
      leaf <- T.stripPrefix "campaign/mercury-" b
      case [c | c <- ["dump-mlds-pred-name", "verbose-dump-mlds", "dump-mlds"], c `T.isPrefixOf` leaf] of
        (c : _) -> Just c
        [] -> Nothing

    -- \| Run an IO action that may throw (git_ uses runProcess_, which
    -- throws on nonzero exit), swallowing ANY exception as Left — the
    -- cleanup/verify paths must never die on a missing ref or worktree.
    guardTry :: IO a -> IO (Either () a)
    guardTry a = do
      r <- try a
      case r of
        Right v -> pure (Right v)
        Left (_ :: SomeException) -> pure (Left ())

    -- \| A detached verify-worktree for one landing: the branch's parent
    -- commit checked out, the landing's options.m diff applied as
    -- working-tree changes — exactly the state the fact probe expects
    -- (edit present, pre-edit HEAD for the no-regression leg). Always
    -- removed afterwards; a staging failure reports REGRESSED loudly
    -- rather than silently skipping.
    withVerifyWorktree :: Text -> (FilePath -> IO OracleVerdict) -> IO OracleVerdict
    withVerifyWorktree branch probe = do
      -- Worktree paths must not contain the branch's “campaign/” prefix.
      let vt = "/tmp/mercury-verify-" <> T.unpack (last (T.splitOn "/" branch))
          parentRev = T.unpack branch <> "~"
      _ <- guardTry (git_ mercuryCampaignClone ["worktree", "remove", "--force", vt])
      _ <- guardTry (git_ mercuryCampaignClone ["worktree", "prune"])
      added <- isRight <$> guardTry (git_ mercuryCampaignClone ["worktree", "add", "--detach", vt, parentRev])
      r <-
        if not added
          then pure (Left ())
          else guardTry $
            do
              -- Materialize the landing's options.m WITHOUT moving HEAD:
              -- HEAD stays at the parent commit (the pre-edit baseline the
              -- no-regression leg compares against), the working file is
              -- the landing's version.
              git_ vt ["checkout", T.unpack branch, "--", "compiler/options.m"]
              probe vt
      _ <- guardTry (git_ mercuryCampaignClone ["worktree", "remove", "--force", vt])
      case r of
        Right v -> pure v
        Left _ -> pure (OracleVerdict False "verify worktree could not be staged")

-- | The act wrapper: act 25 is the same demo inside the numbered sequence.
runMercuryReplayAct :: IO ()
runMercuryReplayAct = do
  putStrLn "\n=== act 25: the Mercury promotion demo, replayable on demand ==="
  runMercuryReplay

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
    runTag0 <- genTag
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
          when inserted
            $ liftIO
            $ putStrLn ("  published human-query awakeable id: " <> T.unpack (awakeableIdText aid))
        streamOf opt = campaignStreamNameText mercuryWorkflowName (mercuryWorkflowIdTagged opt liveTag)

        -- The live engine: 'runAIProgram' behind the 'MercuryEngine' shape,
        -- with the bounded retry that is part of the live contract. The
        -- propose program is the same 'mercuryPromotionSignature' the stub
        -- ran; only the interpreter differs.
        mercuryLiveEngine :: MercuryEngine
        mercuryLiveEngine n prog input _notes = do
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
        ( "  fact: --"
            <> T.unpack (mfOption f)
            <> " at options.m:"
            <> show (mfLineNo f)
            <> " ("
            <> T.unpack (mfConstructor f)
            <> " -> "
            <> T.unpack (mfPublicConstructor f)
            <> ")"
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
              (runWorkflowWith defaultWorkflowRunOptions mercuryWorkflowName wid (mercuryCellWorkflow mercuryLiveEngine (raise . publishHumanQuery) cell (projectNamespace "mercury") 3))
        putStrLn ("  launch --" <> T.unpack (mcOption cell) <> ": " <> show outcome)

    -- The adaptive driver: each round demands exactly the cool-down timers
    -- that journaled failures prove will exist, resumes, and repeats while
    -- anything is unfinished (bounded — 3 attempts + the park). One round,
    -- one store block: the recursion happens OUTSIDE it.
    let registry = mercuryRegistry mercuryLiveEngine publishHumanQuery
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
            ( "    attempt "
                <> show (meAttempt ma)
                <> ": "
                <> T.unpack (meVerdict ma)
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
              ( "  distilled: "
                  <> show summary.extracted
                  <> " candidate(s) extracted, "
                  <> show summary.stored
                  <> " stored"
              )
      for_
        [ "the live mercury engine is one function swap: runAIProgram behind the MercuryEngine"
            <> " shape; the facts, guard, oracle, cool-downs and landings are identical, and a"
            <> " journal cannot tell a live attempt from a scripted one by shape",
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

-- ---------------------------------------------------------------------------
-- Act 20: the help-check cell — proving the promotion in a BUILT compiler
-- ---------------------------------------------------------------------------
--
-- The paced, resumable, hours-long cell. The third oracle probe, deferred
-- from act 18: @mercury_compile --help@ shows the promoted options only in a
-- compiler BUILT from a promoted tree, so the cell builds one — configure,
-- util, runtime, library, mdbcomp, browser, ssdb, compiler — one bounded
-- probe per round, @still-running@ suspending on a durable timer, the next
-- act run resuming the same worktree, journal, and build. ONE cell for all
-- three options: one build, three artifact assertions.

runHelpCheckAct :: IO ()
runHelpCheckAct = do
  putStrLn "\n=== act 20: the help-check cell — one paced compiler build, three --help assertions ==="
  sink <- newIORef []
  let publishHumanQuery :: AwakeableId -> Eff CampaignEffects ()
      publishHumanQuery aid = do
        inserted <-
          liftIO $
            atomicModifyIORef' sink $ \published ->
              if aid `elem` published
                then (published, False)
                else (published <> [aid], True)
        when inserted
          $ liftIO
          $ putStrLn ("  published human-query awakeable id: " <> T.unpack (awakeableIdText aid))
      parent = "/home/nyc/src/mercury"
      streamOf tag = campaignStreamNameText helpCheckWorkflowName (helpCheckWorkflowIdTagged tag)

  -- ------------------------------------------------------------- (1) analyze
  putStrLn "[help-check] analyze — the landings the campaign has actually produced"
  landings <- mercuryPromotionBranches parent
  unless (null landings) $
    for_ landings $ \(opt, b) ->
      putStrLn ("  landing: --" <> T.unpack opt <> " on " <> T.unpack b)
  when (null landings) $
    fail "act 20: no campaign/mercury-* branches — run act 18 first"
  tag <- mercuryIntegrationTag parent landings
  let opts = nub [opt | (opt, _) <- landings]
      cell = helpCheckCellFor opts tag
      wid = helpCheckWorkflowIdTagged tag
  putStrLn
    ( "  tag "
        <> T.unpack tag
        <> ": one help-check cell proving "
        <> show (length opts)
        <> " promoted option(s): "
        <> T.unpack (T.intercalate ", " opts)
    )

  -- The negative control, run for real: the INSTALLED compiler's --help —
  -- the same artifact probe the cell runs, pointed at the pre-promotion
  -- binary. It must show zero.
  for_ opts $ \opt -> do
    neg <- installedHelpCheckProbe opt
    putStrLn ("  negative control: " <> T.unpack (hvDetail neg))
    when (hvShows neg) $
      fail ("act 20: the installed compiler already shows --" <> T.unpack opt <> " — nothing to prove")

  -- ------------------------------------------------------- (2) the paced run
  putStrLn "[help-check] launch — the paced compiler build under the durable workflow"
  withCampaignStore $ \store -> do
    let stream = streamOf tag
    journal0 <- decodedJournal <$> readJournal store stream
    if journalIsComplete journal0
      then putStrLn "  already complete — resume only"
      else
        if not (null journal0)
          then putStrLn ("  journal exists with " <> show (length journal0) <> " event(s) — resuming in place")
          else do
            requireFreshJournal store stream
            outcome <-
              requireEither
                =<< runCampaignStore
                  store
                  (runWorkflowWith defaultWorkflowRunOptions helpCheckWorkflowName wid (mercuryHelpCheckWorkflow (raise . publishHumanQuery) cell))
            putStrLn ("  launch: " <> show outcome)

  -- The driver: discover armed cool-down timers from the journals (step
  -- names cool-<stage>-r<round>), fire exactly those, resume, repeat —
  -- bounded by the probe BUDGET, not a fixed round count: the build is
  -- hours long and the act is designed to be re-run until it closes.
  let registry = helpCheckRegistry opts publishHumanQuery
      ourIds = [wfIdText wid]
      probeBudget = 6 :: Int
      driveRound :: IO Bool
      driveRound = do
        doneRef <- newIORef False
        withCampaignStore $ \store -> do
          unfinished <- ourUnfinished store ourIds
          if null unfinished
            then writeIORef doneRef True
            else do
              let stream = streamOf tag
              journal <- decodedJournal <$> readJournal store stream
              -- The workflow is suspended INSIDE the sleep that follows the
              -- last still-running probe, so that sleep has no recorded
              -- step yet — the demand must come from the probe VERDICT, not
              -- from recorded sleep steps. The sleep names mirror the
              -- workflow's convention exactly: @configure-r<k>@ arms
              -- @cool-configure-r<k>@; @bootstrap-<n>-<stage>-r<k>@ arms
              -- @cool-<n>-r<k>@ (the stage NUMBER, not its name).
              let probeOutcomes =
                    [ (name, Aeson.fromJSON v :: Aeson.Result HelpStageVerdict)
                    | StepRecorded name v _ <- journal,
                      "bootstrap-" `T.isPrefixOf` name || "configure-r" `T.isPrefixOf` name
                    ]
                  sleepForProbe name =
                    case T.stripPrefix "configure-" name of
                      Just suffix -> Just ("cool-configure-" <> suffix)
                      Nothing -> do
                        rest <- T.stripPrefix "bootstrap-" name
                        let (num, tail_) = T.span (/= '-') rest
                            roundK = T.takeWhileEnd (/= '-') tail_
                        digits <- T.stripPrefix "r" roundK
                        if T.null num || T.null digits
                          then Nothing
                          else pure ("cool-" <> num <> "-r" <> digits)
                  stillRunning =
                    [ s
                    | (name, Aeson.Success hv) <- probeOutcomes,
                      hsOutcome hv == "still-running",
                      Just s <- [sleepForProbe name]
                    ]
                  demand = case reverse stillRunning of
                    (latest : _) -> [latest]
                    [] -> []
              forM_ demand $ \n ->
                fireTimerSweep store registry [(stream, "sleep:" <> n)]
              driveResumeOnce store registry
        readIORef doneRef
      driveRounds k
        | k <= (0 :: Int) = pure ()
        | otherwise = do
            done <- driveRound
            unless done $ do
              putStrLn ("  paced rounds remaining: " <> show (k - 1) <> " (probe budget)")
              driveRounds (k - 1)
  driveRounds probeBudget
  stillOpenRef <- newIORef False
  withCampaignStore $ \store -> do
    unfinished <- ourUnfinished store ourIds
    writeIORef stillOpenRef (not (null unfinished))
  stillOpen <- readIORef stillOpenRef
  when stillOpen $
    putStrLn
      ( "  BUDGET: "
          <> show probeBudget
          <> " driver rounds used without finishing — the cell remains open in its journal."
          <> " Re-run ACTS=20 to resume the same build (mmake is idempotent; no work is lost)."
      )

  -- Anything parked goes through the human seam (the operator approves).
  withCampaignStore $ \store -> do
    published <- readIORef sink
    unless (null published) $
      putStrLn ("  parked cells awaiting the operator: " <> show (length published))
    for_ published $ \aid -> do
      _ <- requireEither =<< runCampaignStore store (signalAwakeable aid VerdictApproved)
      pure ()
    driveResumeOnce store registry
    driveResumeOnce store registry

  -- ------------------------------------------------------------ (3) verdicts
  putStrLn "[help-check] verdicts — the built compiler's --help, per option"
  withCampaignStore $ \store -> do
    journal <- decodedJournal <$> readJournal store (streamOf tag)
    let helpSteps = [v | StepRecorded name v _ <- journal, name == "help-check"]
    case reverse helpSteps of
      (v : _) -> case Aeson.fromJSON v of
        Aeson.Success vs ->
          for_ (zip [1 :: Int ..] vs) $ \(i, hv) ->
            putStrLn
              ( "  assertion "
                  <> show i
                  <> ": "
                  <> (if hvShows hv then "SHOWN" else "ABSENT")
                  <> " — "
                  <> T.unpack (hvDetail hv)
              )
        Aeson.Error err -> putStrLn ("  help-check verdict undecodable: " <> err)
      [] -> putStrLn "  no help-check verdict yet — the build is still pacing"
    remaining <- ourUnfinished store ourIds
    unless (null remaining) $
      putStrLn "  (open — re-run ACTS=20; the build continues where it left off)"

  -- ------------------------------------------------------------- (4) memory
  putStrLn "[help-check] memory — the paced-cell recipe enters the campaign's memory"
  withCampaignStore $ \store -> do
    sid <- runKiokuWrite store (startInfraSession "mercury help-check paced build")
    for_ (zip [1 ..] helpCheckEvidence) $ \(idx, (topic, body)) -> do
      _ <- runKiokuWrite store (recordFixTurn sid idx "assistant" ("[" <> topic <> "] " <> body))
      pure ()
    _ <- runKiokuWrite store (completeFixSession sid "a paced compiler build is an ordinary campaign cell: bounded probes, durable timers, resume across act runs")
    putStrLn ("  infra session recorded (" <> show (length helpCheckEvidence) <> " evidence turns)")
    hits <- runCampaignStore store (recallNotesForKeyword (projectNamespace "mercury") "help-check")
    putStrLn ("  recall for \"help-check\": " <> show (length hits) <> " hit(s)")
  putStrLn "[help-check] done — the promotion is proven (or pacing) in a real built compiler"
  where
    helpCheckEvidence =
      [ ("paced-build", "the help-check cell is the matrix rung's slow cell on a compiler: configure and each mmake stage are bounded probes; timeout 124/143 is the typed still-running verdict; mmake's idempotence makes every resume safe"),
        ("resume-across-acts", "the run tag is the newest landing's tip hash, so re-running the act resumes the same worktree and journal instead of discarding hours of build progress; one shared build serves all three option assertions"),
        ("keiro-determinism", "a recorded step never re-executes, so each probe round is its own step name (bootstrap-<n>-<stage>-r<k>): a resume pass replays recorded rounds cheaply, runs exactly one new bounded probe, and suspends again"),
        ("world-facts", "the bootstrap copies the parent checkout's pre-generated configure because this box's autoconf emits a broken one — a world-fact the cell encodes rather than fights")
      ]

-- ---------------------------------------------------------------------------
-- Act 21: the dispatch loop — the plan is executed, not printed
-- ---------------------------------------------------------------------------
--
-- Act 17's planner emitted a typed plan whose dispatch classes were
-- advisory; this act runs them. Each plan line becomes a journaled
-- plan-dispatch workflow (Campaign.Dispatch): execute runs a REAL cell
-- campaign nested inside the dispatch workflow (fresh dispatch tag, own
-- journal stream); verify re-runs the REAL oracles against ground truth;
-- delegate parks on the shared human seam and the operator's verdict is
-- journaled. The plan is the same live cross-project plan act 17 produces —
-- portfolio from store truth, persona distilled, honesty checks enforced —
-- and every line's execution is campaign work indistinguishable in shape
-- from any other cell.

runDispatchAct :: IO ()
runDispatchAct = do
  putStrLn "\n=== act 21: the dispatch loop — the planner decides, the stack runs, the journal records ==="
  runTag0 <- genTag
  let tag = "d" <> runTag0
  sink <- newIORef []
  let publishHumanQuery :: AwakeableId -> Eff CampaignEffects ()
      publishHumanQuery aid = do
        inserted <-
          liftIO $
            atomicModifyIORef' sink $ \published ->
              if aid `elem` published
                then (published, False)
                else (published <> [aid], True)
        when inserted
          $ liftIO
          $ putStrLn ("  published human-query awakeable id: " <> T.unpack (awakeableIdText aid))

  -- The real cells the execute lines name, read once — the executors and the
  -- drive registry share them. Each nested launch runs under a fresh
  -- dispatch-instance id (act 9's live-prefix trick) so a re-run replays
  -- nothing and the resume worker drives the campaign through the merged
  -- registry.
  pcsM <- catMaybes <$> mapM readProjectCell [("mowgli", "src/adapters/llada_interface.py")]
  let dispatchCell c = c {cellId = CellId ("dispatch:" <> unCellId (cellId c))}
      mowgliCell = case pcsM of
        (pc : _) ->
          Just
            Cell
              { cellId = CellId (pcProject pc <> ":" <> pcPath pc),
                cellPath = pcPath pc,
                cellOriginal = pcSource pc,
                cellCurrent = pcSource pc
              }
        [] -> Nothing
      mowgliWfId = case pcsM of
        (pc : _) ->
          let WorkflowId t = projectWorkflowId (pcProject pc) (pcPath pc)
           in WorkflowId (T.replace "pcell-" "pcell-dispatch-" t)
        [] -> WorkflowId "pcell-dispatch-missing"
      toyCellD = dispatchCell (corpusCells !! 3)
      matrixCellD = mkMatrixCell (ArchName "riscv") (ConfigName "debug")
      matrixWfId = matrixWorkflowIdTagged matrixCellD tag

  -- ------------------------------------------------------------- (1) plan
  putStrLn "[dispatch] the live cross-project planner over the real portfolio"
  (plan, _matrixHealthy) <- planPortfolio
  putStrLn ("  priority: " <> T.unpack (unField plan.ppPriority))
  for_ plan.ppNext $ \nx ->
    putStrLn
      ( "    "
          <> T.unpack (unField nx.anProject)
          <> " -> "
          <> T.unpack (unField nx.anAction)
          <> " ["
          <> T.unpack (unField nx.anDispatch)
          <> "]"
      )

  -- Same honesty checks as act 17: closed dispatch vocabulary, full project
  -- coverage. The dispatch layer cannot guess what to do with a class the
  -- planner was never taught.
  let dispatches = [T.toLower (unField nx.anDispatch) | nx <- plan.ppNext]
  unless (all (`elem` ["execute", "delegate", "verify"]) dispatches) $
    fail ("act 21: planner produced an unknown dispatch class: " <> show dispatches)
  let projectsNamed = [T.strip (unField nx.anProject) | nx <- plan.ppNext]
  for_ ["campaign", "mowgli", "peirce"] $ \p ->
    unless (any (p `T.isInfixOf`) projectsNamed) $
      fail ("act 21: the plan omits project " <> T.unpack p)

  let actions =
        [ dispatchActionOfPlanLine (T.strip (unField nx.anProject)) (unField nx.anAction) (T.toLower (unField nx.anDispatch)) (unField nx.anWhy)
        | nx <- plan.ppNext
        ]
      findAction p = case [a | a <- actions, daProject a == p] of
        (a : _) -> a
        [] -> error (T.unpack ("act 21: no action for " <> p))

  -- ------------------------------------------------------------ (2) execute
  putStrLn "[dispatch] the plan becomes journaled work"
  -- The real executors, one per dispatch class. execute runs the actual
  -- cell campaign the line names; verify re-runs the actual oracles.
  let execExecute :: DispatchAction -> Eff CampaignEffects Text
      execExecute action = case daProject action of
        p
          | "mowgli" `T.isInfixOf` p -> case mowgliCell of
              Nothing -> pure "execute: mowgli's cell file is missing — nothing to run"
              Just cell -> do
                -- Launch the real project-cell campaign (act 7's machinery)
                -- under its own fresh journal: the same workflow body the
                -- registry rebuilds. The resume worker drives it to its
                -- verdict through the merged registry.
                r <-
                  runWorkflowWith
                    defaultWorkflowRunOptions
                    projectCampaignWorkflowName
                    mowgliWfId
                    ( cellCampaignWorkflow
                        (honestEngineFor unusedImportOracle cell)
                        (raise . publishHumanQuery)
                        cell
                        unusedImportOracle
                        (projectNamespace "mowgli")
                        defaultMaxAttempts
                    )
                pure
                  ( "execute(mowgli fixer): launched project-cell campaign "
                      <> wfIdText mowgliWfId
                      <> " ("
                      <> T.pack (show r)
                      <> ")"
                  )
          | "peirce" `T.isInfixOf` p || "matrix" `T.isInfixOf` p -> do
              -- The real verification-matrix machinery (act 16's pattern), one
              -- staged boot/stress cell under the dispatch tag: launched here,
              -- driven to its verdict by the resume worker through the merged
              -- registry. The planner names this work peirce or matrix depending
              -- on which project's line carries it — both get real cells.
              r <-
                runWorkflowWith
                  defaultWorkflowRunOptions
                  matrixWorkflowName
                  matrixWfId
                  ( matrixCellWorkflow
                      matrixEngine
                      (raise . publishHumanQuery)
                      matrixCellD
                      (projectNamespace "matrix")
                      3
                  )
              pure
                ( "execute(peirce matrix cell): launched matrix cell "
                    <> wfIdText matrixWfId
                    <> " ("
                    <> T.pack (show r)
                    <> ")"
                )
          | otherwise -> do
              -- The toy corpus cell the plan line names (or the first open
              -- one): the real fixer campaign, the real marker oracle —
              -- launched under a fresh dispatch-instance id, driven by the
              -- resume worker through the merged registry.
              let wfId = campaignWorkflowId (cellId toyCellD)
              r <-
                runWorkflowWith
                  defaultWorkflowRunOptions
                  cellCampaignWorkflowName
                  wfId
                  ( cellCampaignWorkflow
                      (honestEngineFor markerOracle toyCellD)
                      (raise . publishHumanQuery)
                      toyCellD
                      markerOracle
                      campaignNamespace
                      defaultMaxAttempts
                  )
              pure
                ( "execute(campaign fixer): launched cell campaign "
                    <> wfIdText wfId
                    <> " ("
                    <> T.pack (show r)
                    <> ")"
                )

      execVerify :: DispatchAction -> Eff CampaignEffects Text
      execVerify action = case daProject action of
        p
          | "mowgli" `T.isInfixOf` p -> do
              -- The real unused-import oracle over the real checkout file:
              -- the claim "mowgli's file carries unused imports" is checked
              -- against ground truth before any fixer runs on it.
              mpc <- liftIO (readProjectCell ("mowgli", "src/adapters/llada_interface.py"))
              pure $ case mpc of
                Nothing -> "verify(mowgli): file missing — claim uncheckable"
                Just pc ->
                  let diags = oracleCheck unusedImportOracle (pcPath pc) (pcSource pc)
                   in "verify(mowgli): " <> T.pack (show (length diags)) <> " unused-import diagnostic(s) confirmed in the real checkout"
          | "peirce" `T.isInfixOf` p -> do
              -- The real compiler oracle: the dump probe against the
              -- installed compiler (the promotion's capability, live).
              v <- liftIO (oracleDumpProbe ("dispatch-" <> tag))
              pure ("verify(peirce): " <> ovDetail v)
          | otherwise -> do
              -- The toy corpus's marker oracle over one known cell.
              _v <- liftIO (oracleDumpProbe ("dispatch-campaign-" <> tag))
              mpc <- liftIO (readProjectCell ("mowgli", "src/adapters/llada_interface.py"))
              pure $ case mpc of
                Just pc ->
                  let diags = oracleCheck unusedImportOracle (pcPath pc) (pcSource pc)
                   in "verify(campaign): marker oracle ready; mowgli's real file carries "
                        <> T.pack (show (length diags))
                        <> " checkable diagnostic(s)"
                Nothing -> "verify(campaign): marker oracle ready; dump probe ok"

      -- The dispatch registry: executors closed over the run's machinery.
      dispatchDefs =
        dispatchRegistry
          publishHumanQuery
          tag
          actions
          execExecute
          execVerify
      -- The nested campaigns this run launches, rebuilt from the SAME bodies
      -- the executors used at launch: the resume worker drives a suspended
      -- campaign to its verdict through its own journal (the settle/cool
      -- sleeps between attempts are real durable timers). The engine is the
      -- honest stub, exactly what the launches closed over; a live run is
      -- the same registry with a live engine.
      campaignDefs =
        campaignRegistry
          pcsM
          [toyCellD]
          honestEngineFor
          publishHumanQuery
      matrixDefs = matrixRegistry matrixEngine publishHumanQuery
      registry = Map.unions [dispatchDefs, campaignDefs, matrixDefs]
      nestedIds =
        [ wfIdText mowgliWfId,
          wfIdText matrixWfId,
          wfIdText (campaignWorkflowId (cellId toyCellD))
        ]
      -- Which projects the plan actually dispatched as execute — the nested
      -- campaigns only exist for those lines (a verify/delegate line launches
      -- nothing, and the scoreboard must not pretend it did).
      isExecuteFor proj a = daDispatch a == "execute" && proj (daProject a)
      mowgliLaunched = any (isExecuteFor ("mowgli" `T.isInfixOf`)) actions
      peirceLaunched = any (isExecuteFor ("peirce" `T.isInfixOf`)) actions
      campaignLaunched = any (isExecuteFor (\p -> not ("mowgli" `T.isInfixOf` p || "peirce" `T.isInfixOf` p || "matrix" `T.isInfixOf` p))) actions
      ourIds =
        [wfIdText (dispatchWorkflowIdTagged (daProject a) tag) | a <- actions]
          <> nestedIds
  for_ actions $ \a -> do
    let wid = dispatchWorkflowIdTagged (daProject a) tag
        stream = campaignStreamNameText dispatchWorkflowName wid
    withCampaignStore $ \store -> do
      journal0 <- decodedJournal <$> readJournal store stream
      if not (null journal0)
        then putStrLn ("  " <> T.unpack (daProject a) <> ": journal exists — resuming in place")
        else do
          requireFreshJournal store stream
          outcome <-
            requireEither
              =<< runCampaignStore
                store
                (runWorkflowWith defaultWorkflowRunOptions dispatchWorkflowName wid (planDispatchWorkflow (raise . publishHumanQuery) tag a (raise . execExecute) (raise . execVerify)))
          putStrLn ("  dispatch " <> T.unpack (daProject a) <> " [" <> T.unpack (daDispatch a) <> "]: " <> show outcome)

  -- Operator hygiene: retire instances this run's registry can no longer
  -- rebuild. A workflow whose id no longer parses (launched by superseded
  -- code, before a recipe/branch fix) would crash every resume pass
  -- forever; the honest disposition is a typed cancellation — a journal
  -- event recording the retirement — never a silent delete. Legitimately
  -- parked cells (the escalation cell awaiting its human) stay open: their
  -- ids are known to the registry.
  withCampaignStore $ \store -> do
    now <- getCurrentTime
    pairs <- requireEither =<< runCampaignStore store (findUnfinishedWorkflowIds now)
    let knownCellIds =
          SSet.fromList
            ( [wfIdText (campaignWorkflowId (cellId c)) | c <- corpusCells]
                <> [wfIdText (campaignWorkflowId (cellId toyCellD))]
            )
    for_ pairs $ \(nameText, idText) ->
      when (nameText == "cell-campaign" && not (idText `SSet.member` knownCellIds)) $ do
        _ <- requireEither =<< runCampaignStore store (cancelWorkflow cellCampaignWorkflowName (WorkflowId idText))
        putStrLn ("  retired superseded instance: " <> T.unpack idText)

  -- The driver: fire whatever the journals prove is armed, resume, repeat.
  -- The nested campaigns pace their attempts with settle/cool durable
  -- timers in the shared table; firing everything due (fireTime an hour
  -- ahead) before each resume pass lets one round advance a campaign by a
  -- full attempt — the same fast-forward every fleet act uses.
  let driveRound :: IO Bool
      driveRound = do
        doneRef <- newIORef False
        withCampaignStore $ \store -> do
          unfinished <- ourUnfinished store ourIds
          if null unfinished
            then writeIORef doneRef True
            else do
              fireTime <- addUTCTime 3600 <$> getCurrentTime
              fired <-
                requireEither
                  =<< runCampaignStore
                    store
                    (drainWorkflowSleepTimers Nothing fireTime 100 campaignTimerPmFallback)
              putStrLn ("  timer drain: " <> show fired <> " fired (fireTime +1h)")
              driveResumeOnce store registry
              driveResumeOnce store registry
        readIORef doneRef
      driveRounds k
        | k <= (0 :: Int) = pure ()
        | otherwise = do
            done <- driveRound
            unless done (driveRounds (k - 1))
  driveRounds 6

  -- The human seam: the operator answers every delegation.
  withCampaignStore $ \store -> do
    published <- readIORef sink
    unless (null published) $
      putStrLn ("  delegated lines awaiting the operator: " <> show (length published))
    for_ published $ \aid -> do
      _ <- requireEither =<< runCampaignStore store (signalAwakeable aid VerdictApproved)
      pure ()
    driveResumeOnce store registry
    driveResumeOnce store registry

  -- -------------------------------------------------------- (3) scoreboard
  putStrLn "[dispatch] scoreboard — what the plan's execution decided"
  withCampaignStore $ \store -> do
    for_ actions $ \a -> do
      let stream = campaignStreamNameText dispatchWorkflowName (dispatchWorkflowIdTagged (daProject a) tag)
      journal <- decodedJournal <$> readJournal store stream
      let outcomes =
            [ v
            | StepRecorded name v _ <- journal,
              name `elem` ["execute", "verify", "delegate", "unknown"]
            ]
      case reverse outcomes of
        (v : _) -> case Aeson.fromJSON v of
          Aeson.Success d ->
            putStrLn
              ( "  "
                  <> T.unpack (daProject a)
                  <> " ["
                  <> T.unpack (daDispatch a)
                  <> "]: "
                  <> T.unpack (T.take 160 d)
              )
          Aeson.Error err -> putStrLn ("  " <> T.unpack (daProject a) <> ": undecodable outcome: " <> err)
        [] -> putStrLn ("  " <> T.unpack (daProject a) <> ": no outcome recorded (workflow open)")
      remaining <- ourUnfinished store [wfIdText (dispatchWorkflowIdTagged (daProject a) tag)]
      unless (null remaining) $ fail ("act 21: dispatch still open for " <> show remaining)
    -- The nested campaigns' own journals: the attempts they made and how
    -- they ended — the same scoreboard the fleet acts print, read from the
    -- streams the executors launched.
    putStrLn "  nested campaigns:"
    for_ [("mowgli fixer" :: String, projectCampaignWorkflowName, mowgliWfId, mowgliLaunched, "mowgli" :: Text), ("peirce matrix", matrixWorkflowName, matrixWfId, peirceLaunched, "peirce"), ("campaign fixer", cellCampaignWorkflowName, campaignWorkflowId (cellId toyCellD), campaignLaunched, "campaign")] $ \(label, wname, wid, launched, proj) ->
      if not launched
        then putStrLn ("  " <> label <> ": not launched — the plan dispatched " <> T.unpack proj <> " as " <> T.unpack (daDispatch (findAction proj)))
        else do
          let stream = campaignStreamNameText wname wid
          journal <- decodedJournal <$> readJournal store stream
          let attempts = journaledAttempts journal
              ok = journalIsComplete journal
              cleared = case reverse attempts of
                (last_ : _) -> faSucceeded last_ && null (faDiagnosticsAfter last_)
                [] -> True
              verdict
                | not ok = "INCOMPLETE"
                | cleared = "cleared"
                | otherwise = "closed without clearing"
          TIO.putStrLn
            ( T.pack ("  " <> label <> ": ")
                <> (if ok then "complete" else "INCOMPLETE")
                <> ", "
                <> T.pack (show (length attempts))
                <> " attempt(s) — "
                <> verdict
            )

  -- ------------------------------------------------------------ (4) memory
  putStrLn "[dispatch] memory — the executed plan and its outcomes enter the record"
  withCampaignStore $ \store -> do
    sid <- runKiokuWrite store (startInfraSession "dispatch loop (act 21)")
    _ <- runKiokuWrite store (recordFixTurn sid 1 "assistant" (portfolioPlanText plan))
    for_ (zip [1 ..] actions) $ \(idx, a) -> do
      let stream = campaignStreamNameText dispatchWorkflowName (dispatchWorkflowIdTagged (daProject a) tag)
      journal <- decodedJournal <$> readJournal store stream
      let outcomes =
            [ v
            | StepRecorded name v _ <- journal,
              name `elem` ["execute", "verify", "delegate", "unknown"]
            ]
      let outcomeText = case reverse outcomes of
            (v : _) -> case Aeson.fromJSON v of
              Aeson.Success d -> d
              Aeson.Error _ -> "(undecodable)"
            [] -> "(open)"
      _ <-
        runKiokuWrite
          store
          ( recordFixTurn
              sid
              (idx + 1)
              "assistant"
              ("[" <> daProject a <> "/" <> daDispatch a <> "] " <> daAction a <> " -> " <> outcomeText)
          )
      pure ()
    _ <- runKiokuWrite store (completeFixSession sid "the plan's dispatch classes are executed work: nested campaigns, oracle re-checks, and the operator's verdicts, all journaled")
    putStrLn "  infra session recorded (the plan + one turn per executed line)"
    hits <- runCampaignStore store (recallNotesForKeyword (projectNamespace "mercury") "dispatch")
    putStrLn ("  recall for \"dispatch\": " <> show (length hits) <> " hit(s)")
  putStrLn "[dispatch] done — the planner decides, the stack runs, the journal records"
  where
    -- The scripted triage policy (act 16's): kvm misconfigurations retry,
    -- physical-board corruptions go to the human. Typed on TriageIn, no
    -- stub-LM round trip.
    matrixEngine _n _prog input _notes =
      pure
        $ Just
        $ if any ("corruption" `T.isInfixOf`) (unField input.tiStress)
          then TriageOut (Field False) (Field "board corruption: human inspection required")
          else TriageOut (Field True) (Field "kvm misconfiguration clears by re-applying the config")

-- ===========================================================================
-- Act 22: the application phase — mowgli's real corpus, live, landed
-- ===========================================================================

-- | The stack, applied. Act 21 closed the dispatch loop on the campaign's
-- own demo portfolio; this act points the same machinery at a real
-- checkout, mowgli:
--
--   1. @scan@ — the real oracle scans the checkout's top-level @.py@ files.
--      Cells are the files the oracle actually flags; nothing is invented.
--   2. @fix@ — one live fixer campaign per file (the act-9 live engine, the
--      unused-import oracle, the no-regression guard), driven to a verdict
--      through the merged registry: launch, then fire whatever timers the
--      journals prove are armed, then resume, until every journal is
--      complete.
--   3. @land@ — each cleared cell's accepted repair is committed for real,
--      by the act-11 landing machinery, on this run's reviewable branch
--      (@campaign/app-<tag>@ in the mowgli campaign worktree). The parent
--      checkout is never touched; the dirty-count safety proof runs here
--      exactly as act 11's does.
--   4. @scoreboard + memory@ — per-cell verdicts from the journals, the
--      landed commits, and the run recorded as infra memory.
runAppPhaseAct :: IO ()
runAppPhaseAct = do
  -- The application target is parameterized (default: mowgli, the proven
  -- checkout) — the same act runs wherever the oracle speaks.
  mproj <- lookupEnv "CAMPAIGN_APP_PROJECT"
  let proj = T.pack (fromMaybe "mowgli" (listToMaybe . words =<< mproj))
  putStrLn "\n=== act 22: the application phase — unused imports, live, landed ==="
  runTag0 <- genTag
  let runTag = "app" <> runTag0
      branch = appPhaseBranchFor runTag proj

  -- ----------------------------------------------------------- (1) scan
  putStrLn ("[app] scanning " <> T.unpack proj <> "'s checkout with the real unused-import oracle")
  cells0 <- scanProjectUnusedImportCells proj
  -- CAMPAIGN_APP_LIMIT=n / CAMPAIGN_APP_OFFSET=n: one run takes a window of
  -- the sorted scan (a long checkout is chewed over several runs; each run
  -- lands its own reviewable branch). The offset exists because the scan
  -- reads the parent checkout — cells a previous run cleared live only on
  -- that run's branch — so consecutive runs partition the scan by offset.
  mlimit <- (>>= readMaybe) <$> lookupEnv "CAMPAIGN_APP_LIMIT"
  moffset <- (>>= readMaybe) <$> lookupEnv "CAMPAIGN_APP_OFFSET"
  let windowed = maybe cells0 (`drop` cells0) moffset
      cells = maybe windowed (`take` windowed) (mlimit :: Maybe Int)
  case (mlimit, length cells0) of
    (Just n, total) | n < total -> putStrLn ("  (run limit " <> show n <> " of " <> show total <> " scanned cells — the rest wait for a later run)")
    _ -> pure ()
  when (null cells) $
    putStrLn "  the scan found no cells — the oracle speaks nowhere in this checkout (nothing to do)"
  for_ cells $ \pc ->
    putStrLn
      ( "  cell "
          <> T.unpack (pcProject pc <> ":" <> pcPath pc)
          <> " — "
          <> show (length (oracleCheck unusedImportOracle (pcPath pc) (pcSource pc)))
          <> " diagnostic(s)"
      )
  -- CAMPAIGN_APP_SCAN_ONLY=1: the validation run — compare this scan against
  -- an independent detector, attempt nothing, land nothing.
  scanOnly <- (== Just "1") <$> lookupEnv "CAMPAIGN_APP_SCAN_ONLY"
  when scanOnly $ putStrLn "[app] scan-only mode — no attempts, no landings"
  when (null cells && not scanOnly) $
    fail "act 22: the scan found no cells — is the oracle's vocabulary still true of the checkout?"
  -- (the act continues below only when cells exist and scan-only is unset)
  unless (scanOnly || null cells) $ runAppPhaseFixAndLand proj runTag branch cells

-- | Act 22, continued: fix, land, score — everything past the scan, as one
-- function of the application target, so the scan-only validation mode stops
-- before any attempt is made.
runAppPhaseFixAndLand :: Text -> Text -> Text -> [ProjectCell] -> IO ()
runAppPhaseFixAndLand proj runTag branch cells = do
  -- ------------------------------------------------------------- (2) fix
  putStrLn "[app] launching the live fixer campaigns (one per real cell)"
  withLoadedAIRuntime $ \air -> do
    sink <- newIORef []
    let publishHumanQuery :: AwakeableId -> Eff CampaignEffects ()
        publishHumanQuery aid = do
          inserted <- liftIO $ atomicModifyIORef' sink (\p -> if aid `elem` p then (p, False) else (p <> [aid], True))
          when inserted $ liftIO $ putStrLn ("  published human-query awakeable id: " <> T.unpack (awakeableIdText aid))
        -- Cells are keyed like every project cell: @projectWorkflowId proj
        -- path@; the fresh-campaign instance prefix carries the run tag
        -- (@pcell-app<runTag>-@, admitted by projectCellFromWf) so this run
        -- launches its own journals instead of resuming a superseded run's
        -- — a resume-in-place replayed a pre-surgical repair once already.
        cellKey pc = pcProject pc <> ":" <> pcPath pc
        instWfId pc =
          let WorkflowId t = projectWorkflowId (pcProject pc) (pcPath pc)
           in WorkflowId (T.replace "pcell-" ("pcell-app-" <> runTag <> "-") t)
        rows = [(pc, campaignStreamNameText projectCampaignWorkflowName (instWfId pc)) | pc <- cells]
        registry =
          Map.unions
            [ campaignRegistry
                [pc {pcSource = pcSource pc} | pc <- cells]
                []
                (\_oracle _cell -> liveEngine air)
                publishHumanQuery
            ]

    for_ cells $ \pc -> do
      let wid = instWfId pc
          stream = campaignStreamNameText projectCampaignWorkflowName wid
      withCampaignStore $ \store -> do
        journal0 <- decodedJournal <$> readJournal store stream
        if not (null journal0)
          then putStrLn ("  " <> T.unpack (cellKey pc) <> ": journal exists — resuming in place")
          else do
            requireFreshJournal store stream
            outcome <-
              requireEither
                =<< runCampaignStore
                  store
                  ( runWorkflowWith
                      defaultWorkflowRunOptions
                      projectCampaignWorkflowName
                      wid
                      ( cellCampaignWorkflow
                          (liveEngine air)
                          (raise . publishHumanQuery)
                          (Cell (CellId (cellKey pc)) (pcPath pc) (pcSource pc) (pcSource pc))
                          unusedImportOracle
                          (projectNamespace "mowgli")
                          defaultMaxAttempts
                      )
                  )
            putStrLn ("  launch " <> T.unpack (cellKey pc) <> ": " <> show outcome)

    -- Operator hygiene, act 21's rule applied to the app phase: retire any
    -- unfinished cell-campaign instance this run's registry cannot rebuild —
    -- the pre-fix doubled-path id among them — with a typed cancellation,
    -- never a silent delete.
    withCampaignStore $ \store -> do
      now <- getCurrentTime
      pairs <- requireEither =<< runCampaignStore store (findUnfinishedWorkflowIds now)
      let ours = SSet.fromList (map (wfIdText . instWfId) cells)
      for_ pairs $ \(nameText, idText) ->
        when (nameText == unWorkflowName' projectCampaignWorkflowName && not (idText `SSet.member` ours)) $ do
          _ <- requireEither =<< runCampaignStore store (cancelWorkflow projectCampaignWorkflowName (WorkflowId idText))
          putStrLn ("  retired superseded instance: " <> T.unpack idText)

    -- The drive: settle/cool timers fire (the typed fallback dead-letters
    -- kioku's own stranded rows), the registry resumes the campaigns, and
    -- the loop ends when every journal is complete — or the budget is out.
    -- Completion is judged from the journals, not from discovery: a campaign
    -- suspended on a settle timer is invisible to the instance query until
    -- its fire_at passes, and the launch-to-drive gap is smaller than the
    -- settle delay — gating on discovery alone ends the loop before the
    -- first timer is ever fired.
    let driveRound :: IO Bool
        driveRound = do
          doneRef <- newIORef False
          withCampaignStore $ \store -> do
            fireTime <- addUTCTime 3600 <$> getCurrentTime
            _ <-
              requireEither
                =<< runCampaignStore
                  store
                  (drainWorkflowSleepTimers Nothing fireTime 100 campaignTimerPmFallback)
            driveResumeOnce store registry
            driveResumeOnce store registry
            statuses <- forM rows $ \(_, stream) -> do
              j <- decodedJournal <$> readJournal store stream
              pure (journalIsComplete j)
            writeIORef doneRef (and statuses)
          readIORef doneRef
        driveRounds k
          | k <= (0 :: Int) = pure ()
          | otherwise = driveRound >>= \done -> unless done (driveRounds (k - 1))
    driveRounds 10
    -- The campaigns never park in normal operation (maxAttempts per cell,
    -- each attempt a proposed deletion the guard re-checks); a parked one
    -- means the model proposed something the guard kept rejecting, and the
    -- honest move is to report it, not to answer for it.
    withCampaignStore $ \_store -> do
      published <- readIORef sink
      unless (null published) $ putStrLn ("  parked queries (reported, not answered): " <> show (length published))

    -- ------------------------------------------------------- (3) land
    putStrLn "[app] landing every cleared cell's repair on " >> putStrLn (T.unpack branch)
    -- The landing gate: a cell's repair lands only when its journal is
    -- /complete and cleared/ — the last attempt succeeded with zero
    -- diagnostics after. "Some attempt was accepted" once landed a degenerate
    -- whole-file wipe: the guard had passed it, the oracle could not see what
    -- was missing, and the run was honest everywhere except here.
    repairsRef <- newIORef []
    withCampaignStore $ \store ->
      forM_ rows $ \(pc, stream) -> do
        journal <- decodedJournal <$> readJournal store stream
        let attempts = journaledAttempts journal
            ok = journalIsComplete journal
            cleared = case reverse attempts of
              (last_ : _) -> faSucceeded last_ && null (faDiagnosticsAfter last_)
              [] -> False
        let lastRepair = case reverse attempts of
              (last_ : _) -> faRepaired last_
              [] -> Nothing
        case (ok, cleared, lastRepair) of
          (False, _, _) -> putStrLn ("  " <> T.unpack (cellKey pc) <> ": journal incomplete — not landed")
          (_, False, _) -> putStrLn ("  " <> T.unpack (cellKey pc) <> ": closed without clearing — not landed")
          (_, _, Just r) -> modifyIORef' repairsRef ((pc, r) :)
          (_, _, Nothing) -> putStrLn ("  " <> T.unpack (cellKey pc) <> ": cleared but no accepted repair recorded — not landed")
    cellsWithRepairs <- reverse <$> readIORef repairsRef

    dirtyBefore <- parentDirtyCount proj
    withCampaignStore $ \store ->
      forM_ cellsWithRepairs $ \(pc, repair) -> do
        let wid = landingWorkflowIdFor ("app-" <> runTag) (pcProject pc, pcPath pc)
            stream = campaignStreamNameText landingWorkflowName wid
        existing <- decodedJournal <$> readJournal store stream
        case landingRecordOf existing of
          (recd : _) -> putStrLn ("  already landed " <> T.unpack (lrProject recd <> ":" <> lrPath recd) <> " — " <> T.unpack (lrCommit recd))
          [] -> do
            _ <-
              requireEither
                =<< runCampaignStore
                  store
                  ( runWorkflowWith
                      defaultWorkflowRunOptions
                      landingWorkflowName
                      wid
                      (landProjectCellWorkflow pc unusedImportOracle branch repair)
                  )
            journal <- decodedJournal <$> readJournal store stream
            case landingRecordOf journal of
              (recd : _) ->
                if lrVerified recd
                  then putStrLn ("  landed " <> T.unpack (lrProject recd <> ":" <> lrPath recd) <> " — commit " <> T.unpack (lrCommit recd) <> " on " <> T.unpack (lrBranch recd))
                  else putStrLn ("  NOT LANDED " <> T.unpack (lrProject recd <> ":" <> lrPath recd) <> " — " <> T.unpack (T.intercalate "; " (lrDiagnostics recd)))
              [] -> fail ("act 22: landing journal has no record for " <> T.unpack (cellKey pc))
    dirtyAfter <- parentDirtyCount proj
    putStrLn ("  parent dirty entries before: " <> show dirtyBefore <> ", after: " <> show dirtyAfter)
    when (dirtyBefore /= dirtyAfter) $ fail "act 22: the parent checkout was modified — safety rule violated"

    -- The run's work, reviewable — only when there is work: a run that
    -- lands nothing creates no worktree, so there is no log to show.
    unless (null cellsWithRepairs) $ do
      wtLog <- gitCapture (campaignWorktreePath proj branch) ["log", "--oneline", T.unpack branch]
      putStrLn ("  branch log (" <> T.unpack branch <> "):")
      for_ (T.lines wtLog) (putStrLn . ("    " <>) . T.unpack)

    -- --------------------------------------------- (4) scoreboard + memory
    putStrLn "[app] journal scoreboard — the real corpus, fixed by the real model"
    withCampaignStore $ \store -> do
      forM_ rows $ \(pc, stream) -> do
        journal <- decodedJournal <$> readJournal store stream
        let attempts = journaledAttempts journal
            ok = journalIsComplete journal
            cleared = case reverse attempts of
              (last_ : _) -> faSucceeded last_ && null (faDiagnosticsAfter last_)
              [] -> False
            verdict
              | not ok = "INCOMPLETE"
              | cleared = "cleared"
              | otherwise = "closed without clearing"
        putStrLn
          ( "  "
              <> T.unpack (cellKey pc)
              <> ": "
              <> (if ok then "complete" else "INCOMPLETE")
              <> ", "
              <> show (length attempts)
              <> " attempt(s) — "
              <> verdict
          )
      sid <- runKiokuWrite store (startInfraSession ("application phase (act 22): " <> proj <> " corpus, live, landed"))
      _ <-
        runKiokuWrite
          store
          ( recordFixTurn
              sid
              1
              "assistant"
              ( "act 22 scanned "
                  <> T.pack (show (length cells))
                  <> " real cells in mowgli, fixed them live, and landed "
                  <> T.pack (show (length cellsWithRepairs))
                  <> " repair(s) on "
                  <> branch
              )
          )
      _ <- runKiokuWrite store (completeFixSession sid "the stack applied to a real checkout: scan by oracle, fix by live model, land by worktree, prove by parent-dirty-count")
      putStrLn "  infra session recorded"
    putStrLn "[app] done — a real checkout's real defects, decided by the journals"

-- | Act 23: the dispatch shape over the /real/ verification processes —
-- pgcl's (arch × config) kernel boot matrix and telix's host verification.
--
--   1. @discover@ — the units this host can actually run, probed from
--      ground truth (toolchains, emulators, kernel trees, checkouts). The
--      plan says why absent capability is absent.
--   2. @dispatch@ — one keiro workflow per unit. @verify-plan@ journals the
--      exact command; @run-cell@ journals the outcome. Offline (default)
--      the command is recorded and nothing executes: the plan is the
--      product. REAL_LIVE=1 lifts the gate and verdicts are read from the
--      logs the tools wrote.
--   3. @scoreboard@ — per-unit verdicts straight off the journals, plus
--      the run recorded as infra memory (live runs only — plans pollute
--      nothing).
runRealAct :: IO ()
runRealAct = do
  mode <- realModeFromEnv
  mlim <- realBudgetFromEnv
  let modeText = case mode of
        RealPlan -> "plan"
        RealLive -> "live" <> maybe "" (\n -> " (budget " <> show n <> ")") mlim
  putStrLn ("\n=== act 23: real verification processes — " <> modeText <> " mode ===")

  units0 <- realUnitCells
  -- REAL_UNIT=<project/arch@config> restricts the act to one cell — the
  -- live one-cell proof pays for one QEMU boot, not seventy.
  mSel <- fmap (T.strip . T.pack) <$> lookupEnv "REAL_UNIT"
  selected <- case mSel of
    Nothing -> pure units0
    Just sel -> do
      let hits = filter (\u -> realCellKey u == sel) units0
      when (null hits) $
        error
          ( "REAL_UNIT="
              <> T.unpack sel
              <> " matches no discovered unit. Discovered:\n"
              <> T.unpack (T.intercalate "\n" (map realCellKey units0))
          )
      pure hits
  -- The schedule is memory-driven: recall each project's lessons, fold
  -- them into per-cell evidence, and order cells failed-first (reproduce
  -- while fresh), then unknown, then passed — cheapest-first within tier.
  -- The same evidence block drives the toy matrix's boot-tier plan (act
  -- 16) via recallNotesForKeyword — here the /real/ cells get the same
  -- treatment, and the rationale is journaled as data alongside the order.
  lessonsRef <- newIORef (Map.empty :: Map.Map Text [Text])
  withCampaignStore $ \store ->
    for_ (nub (map ruProject units0)) $ \proj -> do
      notes <- requireEither =<< runCampaignStore store (recallNotes (projectNamespace proj))
      modifyIORef' lessonsRef (Map.insert proj notes)
  lessonsByProject <- readIORef lessonsRef
  let evidence = evidenceFromLessons (concat (Map.elems lessonsByProject))
      schedule = scheduleFromEvidence selected evidence
      units = map seUnit (schRows schedule)
  putStrLn
    ( "[real] schedule from "
        <> show (Map.size lessonsByProject)
        <> " namespace(s) of memory: "
        <> show (Map.size evidence)
        <> " cell(s) with evidence"
    )
  let rows = schRows schedule
  for_ (take 8 rows) $ \row ->
    putStrLn
      ( "  #"
          <> show (seRank row)
          <> " "
          <> T.unpack (realCellKey (seUnit row))
          <> " — "
          <> T.unpack (seWhy row)
      )
  -- A long schedule hides its passed tier at the tail — show it: the tail
  -- is where the evidence (and the money) actually sits.
  when (length rows > 11) $ do
    putStrLn "  …"
    for_ (drop (length rows - 3) rows) $ \row ->
      putStrLn
        ( "  #"
            <> show (seRank row)
            <> " "
            <> T.unpack (realCellKey (seUnit row))
            <> " — "
            <> T.unpack (seWhy row)
        )
  -- The pacing gate: with REAL_LIMIT=n, exactly the first n schedule
  -- ranks go live and the rest plan — the mode is decided per cell, from
  -- the schedule itself, so what executes is what memory ranked first.
  -- The registry must see the same mapping: a resumed cell replays the
  -- mode its rank earned.
  let modeFor u = budgetedMode mode mlim (seRankOf u)
      planWhyFor u = case budgetedMode mode mlim (seRankOf u) of
        RealLive -> "REAL_LIVE=1"
        RealPlan | mode == RealLive -> "beyond REAL_LIMIT=" <> T.pack (show (fromMaybe (0 :: Int) mlim))
        RealPlan -> "offline; set REAL_LIVE=1"
      seRankOf u = maybe 1 seRank (find ((== realCellKey u) . realCellKey . seUnit) rows)
      pgclUnits = [u | u <- units, ruProject u == "pgcl"]
      hostUnits = [u | u <- units, ruKind u == "host-verify"]
  putStrLn
    ( "[real] discovered "
        <> show (length pgclUnits)
        <> " pgcl cell(s) across "
        <> show (length (nub (map ruArch pgclUnits)))
        <> " arch(es), "
        <> show (length hostUnits)
        <> " host unit(s)"
    )
  for_ (groupSortOn ruProject units) $ \group ->
    let keyOf u = ruArch u <> "@" <> ruConfig u
        projectOf = case group of
          (u : _) -> ruProject u
          [] -> ""
     in putStrLn
          ( "  "
              <> T.unpack projectOf
              <> ": "
              <> T.unpack (T.intercalate ", " (sort (nub (map keyOf group))))
          )

  ts <- genTag
  let outDir = "/tmp/real-cells-" <> T.unpack ts
      taggedRows = [(u, realWorkflowIdTagged u ts) | u <- units]
      streamOf = campaignStreamNameText realWorkflowName
      registry = realRegistry (\u -> (modeFor u, planWhyFor u)) outDir :: WorkflowRegistry CampaignEffects
  createDirectoryIfMissing True outDir

  -- Launch every cell. Offline the workflow completes immediately (its run
  -- step is a pure record); live it runs the tool synchronously inside the
  -- step and completes the same way — either way no timers, so one launch
  -- sweep per run and one resume pass to drain.
  putStrLn ("[real] dispatching " <> show (length taggedRows) <> " cell workflow(s) into keiro")
  for_ taggedRows $ \(u, wid) ->
    withCampaignStore $ \store -> do
      requireFreshJournal store (streamOf wid)
      outcome <-
        requireEither
          =<< runCampaignStore
            store
            (runWorkflowWith defaultWorkflowRunOptions realWorkflowName wid (realCellWorkflow u (modeFor u) (planWhyFor u) outDir))
      putStrLn ("  " <> T.unpack (realCellKey u) <> ": " <> show outcome)

  -- One resume pass: a no-op when every workflow completed at launch, but
  -- it drives any cell left pending by a crashed prior run — the durable
  -- property the whole shape exists for.
  withCampaignStore $ \store -> driveResumeOnce store registry

  putStrLn "[real] scoreboard — from the journals:"
  verdictsRef <- newIORef []
  forM_ taggedRows $ \(u, wid) ->
    withCampaignStore $ \store -> do
      journal <- readJournal store (streamOf wid)
      modifyIORef' verdictsRef ((u, realAttemptsOf (decodedJournal journal)) :)
  verdicts <- reverse <$> readIORef verdictsRef
  for_ verdicts $ \(u, attempts) ->
    for_ attempts $ \a -> do
      putStrLn
        ( "  "
            <> T.unpack (realCellKey u)
            <> " ["
            <> T.unpack a.raMode
            <> "] "
            <> T.unpack a.raVerdict
            <> (if T.null a.raLog then "" else "  log: " <> T.unpack a.raLog)
        )
      when (a.raMode == "live") $ putStrLn ("    cmd: " <> T.unpack a.raCommand)

  -- Memory: only live verdicts record lessons — a plan is not evidence.
  -- The gate is the attempt's own mode, not the run's: under REAL_LIMIT,
  -- budgeted cells plan while the run is live, and a plan must not
  -- pollute the evidence the next schedule reads.
  when (mode == RealLive) $
    withCampaignStore $ \store ->
      for_ verdicts $ \(u, attempts) ->
        for_ attempts $ \a -> when (a.raMode == "live") $ do
          let v = a.raVerdict
              advice = lessonAdviceFor u v a.raSeconds a.raLog
          _ <- runKiokuWrite store (recordLesson (projectNamespace (ruProject u)) (realCellKey u) advice)
          pure ()

  -- The run itself, as infra evidence for the distiller.
  withCampaignStore $ \store -> do
    sid <- runKiokuWrite store (startInfraSession "act 23: real verification dispatch")
    _ <-
      runKiokuWrite
        store
        ( recordFixTurn
            sid
            1
            "assistant"
            ( "dispatched "
                <> T.pack (show (length taggedRows))
                <> " real cells in "
                <> T.pack modeText
                <> " mode, scheduled from memory ("
                <> T.pack (show (Map.size evidence))
                <> " cell(s) with evidence): "
                <> T.intercalate ", " [realCellKey u | (u, _) <- taggedRows]
            )
        )
    _ <-
      runKiokuWrite
        store
        (completeFixSession sid ("real-cell dispatch (" <> T.pack modeText <> ") over pgcl and telix: verdicts from the tools' own logs"))
    putStrLn "  infra session recorded"

  putStrLn "[real] done — the dispatch shape over the processes that actually exist"

-- | Sort-and-group a list by one key, the tiny helper the scoreboard's
-- grouped listing wants (Data.List.groupOn is not in base).
groupSortOn :: (Ord b) => (a -> b) -> [a] -> [[a]]
groupSortOn f = groupBy (\x y -> f x == f y) . sortOn f

-- ---------------------------------------------------------------------------
-- Act 24: distill the human-seam escalation pattern
-- ---------------------------------------------------------------------------

-- | Mine the journals for human-seam escalations and keep one campaign-wide
-- pattern atom in kioku's infra namespace, record-on-change.
--
-- The pattern is the queue item that earned this act: when a project cell's
-- repair attempts are exhausted, the durable workflow parks on an awakeable
-- ('humanQueryStepName' — the journal fingerprint is a step
-- @awkid:human-verdict@ whose result is the awakeable's UUID). The
-- operator's answer arrives through 'signalAwakeable', and the resumed
-- workflow records the verdict as a step named @awk:@\<aid\>@@ whose result
-- is @VerdictApproved@ / @VerdictRejected@. This act folds those two step
-- shapes out of kiroku's @$all@ stream — the same codec-only discipline the
-- fan-out uses — into /evidence/, and the evidence into /advice/:
--
--   * the observed escalation count and per-verdict tally,
--   * the operational lesson twice confirmed live: partially-specified
--     repairs (a rewrite, not a pure deletion) exhaust their attempt budget
--     more often; the parked workflow holds honestly (no false repair), and
--     a fresh run clears the cell after the verdict without inventing
--     anything the operator did not sanction.
--
-- The atom is /revised, not duplicated/: on content change the new atom
-- carries 'RecordMemoryData.supersedes' pointing at the old, so kioku's
-- lineage holds the pattern's history. On no change the act is a no-op.
runEscalationDistillAct :: IO ()
runEscalationDistillAct = do
  putStrLn "\n=== act 24: distill the human-seam escalation pattern ==="
  withCampaignStore $ \store -> do
    evsE <- runCampaignStore store (Store.readAllForward (Store.GlobalPosition 0) 100000)
    events <- requireEither evsE
    let wjes = rights (decodeRecorded workflowJournalCodec <$> Vector.toList events)
        textOf v = case Aeson.fromJSON v of
          Aeson.Success t -> Just (t :: Text)
          Aeson.Error _ -> Nothing
        publishes =
          [ (aid, recordedAt)
          | StepRecorded name result recordedAt <- wjes,
            name == "awkid:human-verdict",
            Just aid <- [textOf result]
          ]
        verdictOf ev = case ev of
          StepRecorded name result _
            | "awk:" `T.isPrefixOf` name,
              Just v <- textOf result,
              v `elem` ["VerdictApproved", "VerdictRejected"] ->
                Just (T.drop 4 name, v)
          _ -> Nothing
        verdicts = mapMaybe verdictOf wjes
        answeredCount = length verdicts
        approvedCount = length [() | (_, "VerdictApproved") <- verdicts]
        n = length publishes
    putStrLn
      ( "[escalation] "
          <> show n
          <> " human query(ies) published, "
          <> show answeredCount
          <> " answered ("
          <> show approvedCount
          <> " approved, "
          <> show (answeredCount - approvedCount)
          <> " rejected)"
      )
    for_ publishes $ \(aid, at) ->
      putStrLn ("  query " <> T.unpack aid <> " @ " <> show at)
    for_ verdicts $ \(aid, v) ->
      putStrLn ("  verdict " <> T.unpack v <> " for " <> T.unpack aid)
    when (n > 0) $ do
      let advice =
            "when a repair is partially specified (a rewrite, not a pure deletion), attempts exhaust more often; \
            \the parked workflow holds honestly (no false repair), and a fresh run clears the cell after the \
            \operator verdict through the human seam ("
              <> T.pack (show n)
              <> " escalations observed, "
              <> T.pack (show approvedCount)
              <> " approved, "
              <> T.pack (show (answeredCount - approvedCount))
              <> " rejected)"
      written <-
        runKiokuWrite
          store
          ( recordGlobalLessonSuperseding
              campaignInfraNamespace
              "human-seam-escalation"
              advice
          )
      putStrLn
        ( if written
            then "[escalation] pattern atom written to the infra namespace (supersedes the prior revision if any)"
            else "[escalation] pattern atom already current — no change"
        )
  putStrLn "[escalation] done — memory holds the seam's pattern, evidence holds its history"

-- | The verdict probe: @CLASSIFY=arch:path[,arch:path…]@ (arch empty for the
-- un-scoped classifier) runs each log through 'verdictFrom' — the exact
-- classifier × exit-code pipeline act 23 uses — printing one verdict per
-- file. rc=0 is assumed for every entry (a probe replays logs, not
-- processes); the pipeline's timeout/exit-code arms are exercised by the
-- synthetic-variant checks in the repo's probe notes.
classifyProbeMode :: String -> IO ()
classifyProbeMode spec =
  for_ (T.splitOn "," (T.strip (T.pack spec))) $ \item ->
    if T.null item
      then pure ()
      else do
        let (archPart, path) = case T.breakOn ":" item of
              (_, rest) | T.null rest -> ("", item)
              (a, r) -> (a, T.drop 1 r)
            (arch, baseline) = case T.breakOn "@" archPart of
              (a, r) | T.null r -> (a, [] :: [Text])
              (a, r) -> (a, T.splitOn ";" (T.drop 1 r))
        body <- T.pack <$> readFile (T.unpack path)
        -- No `@baseline` in the spec: exercise the arch built-in only (the
        -- pre-existing behaviour). With it: union the built-in with the named
        -- baselines, exactly as the manifest path does.
        let v =
              if null baseline
                then verdictFrom ExitSuccess arch body
                else verdictFromBaseline ExitSuccess arch (knownFailuresFor arch <> baseline) body
        putStrLn $
          "  "
            <> T.unpack arch
            <> (if null baseline then "" else "@" <> T.unpack (T.intercalate ";" baseline))
            <> ":"
            <> T.unpack path
            <> " -> "
            <> T.unpack v
