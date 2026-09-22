{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The Mercury promotion campaign: the analyze → propose → guard → test →
-- land pipeline (the shikumi-coder demo and acts 9–12) pointed at a real
-- compiler change, packaged as campaign cells the act-17 planner schedules.
--
-- The change: promote the private @--dump-mlds@ option family —
-- @dump-mlds@, @dump-mlds-pred-name@, @verbose-dump-mlds@ — from Mercury's
-- @priv_arg_help@ / @priv_alt_arg_help@ registrations to the public
-- @arg_help@ / @alt_arg_help@ ones, so IR dumps are selectable by plain CLI
-- options with no special compiler build (the project goal).
--
-- The design rules, all inherited from the earlier rungs:
--
--   * /facts, not guesses/ — each cell's ground truth is a 'MercuryFact'
--     extracted from the tree's real @options.m@; the analyze stage is not
--     a model call. A tree whose private line is absent yields no fact —
--     the analyze step reports @already-promoted@ instead of inventing work
--     (which is also exactly what a re-run sees).
--   * /the model edits, Haskell verifies/ — propose runs the coder's real
--     program ('Shikumi.Coder.Task.PatchPlan': one exact-match replacement,
--     decoded from the model's reply) and 'Shikumi.Coder.Task.applyPlan'
--     applies it under the exact-once guard. A stale or invented context is
--     a typed rejection ('maGuard' carries the reason), never a corruption.
--   * /the oracle is the compiler/ — the test stage is two probes:
--     'oracleFactProbe' (the private line is gone, the public line is in,
--     and the file's private-registration count fell by exactly one relative
--     to the worktree's HEAD — the no-regression guard) and
--     'oracleDumpProbe' (the installed @mmc@, in the MLDS grade @hlc.gc@,
--     emits a real @.c_dump.NNN-stage@ file — the capability the promotion
--     exposes, grade-pinned per the project goal).
--   * /one cell, one worktree, one branch, one run/ — each cell lands in its
--     own worktree on its own @campaign/mercury-…@ branch (Hands' worktree
--     machinery), and the run tag is part of the branch name, so every run
--     replays the whole drama fresh: a new branch from the parent's HEAD,
--     a new journal, a new landing — reviewable per run.
--   * /every stage is journaled/ — analyze, attempts, and landing are keiro
--     steps; replay reads what was decided and re-verifies nothing live.
module Campaign.Mercury
  ( -- * Facts and cells
    MercuryFact (..),
    mercuryOptionsPath,
    mercuryPromotionTargets,
    readMercuryFacts,
    MercuryCell (..),
    mercuryCellSpecs,
    mercuryCellFor,
    mercuryBranchFor,
    mercuryWorktreeFor,
    mercuryPrivCount,

    -- * The staged oracle
    OracleVerdict (..),
    oracleFactProbe,
    oracleDumpProbe,

    -- * The promotion engine
    MercuryEngine,
    mercuryPromotionSignature,
    mercuryScriptedEngine,

    -- * The workflow
    mercuryWorkflowName,
    mercuryWorkflowIdTagged,
    mercuryCellKeyFromWf,
    mercuryCellWorkflow,
    mercuryRegistry,
    MercuryAttempt (..),
    mercuryAttemptsOf,
    mercuryCoolDown,

    -- * The help-check cell (the paced compiler build)
    HelpCheckCell (..),
    mercuryPromotionBranches,
    mercuryIntegrationTag,
    integrationBranchName,
    helpCheckBranchFor,
    helpCheckCellFor,
    mercuryHelpCheckWorkflow,
    installedHelpCheckProbe,
    helpCheckWorkflowName,
    helpCheckWorkflowIdTagged,
    helpCheckCellKeyFromWf,
    helpCheckRegistry,
    HelpStageVerdict (..),
    HelpCheckVerdict (..),
    mercuryBootstrapStages,
    helpCheckProbe,
  )
where

import Baikai (Response)
import Campaign.Hands (campaignWorktreePath, ensureCampaignWorktree, gitCapture)
import Campaign.Memory (projectNamespace, recallNotesForKeyword)
import Campaign.Workflow (HumanVerdict (..), humanQueryStepName)
import Control.Exception (SomeException, catch, try)
import Control.Monad (forM, unless, void, when)
import Data.Aeson (FromJSON, ToJSON)
import Data.Aeson qualified as Aeson
import Data.Char (isDigit)
import Data.Function ((&))
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, fromMaybe, listToMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Text.Lazy qualified as TL
import Data.Text.Lazy.Encoding qualified as TLE
import Data.Time.Clock (NominalDiffTime)
import Effectful (Eff, IOE, liftIO, raise, (:>))
import GHC.Generics (Generic)
import Keiro.Workflow (StepName (..), Workflow, WorkflowId (..), step)
import Keiro.Workflow.Awakeable (AwakeableId, awakeableNamed)
import Keiro.Workflow.Resume (WorkflowDef (..), WorkflowRegistry)
import Keiro.Workflow.Sleep (sleepNamed)
import Keiro.Workflow.Types (WorkflowJournalEvent (..), WorkflowName (..))
import Kioku.Api.Scope (Namespace)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Effect.Resource (KirokuStoreResource)
import Shikumi.Coder.Pipeline (ProposeIn (..), failureReport)
import Shikumi.Coder.Task (PatchPlan (..), applyPlan, renderEditFailure)
import Shikumi.Error (ShikumiError)
import Shikumi.Module (predict)
import Shikumi.Program (Program, runProgram)
import Shikumi.Schema.Types (Field (Field, unField))
import Shikumi.Signature (Signature, mkSignature)
import Shikumi.Testing (runStubEval)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, findExecutable, listDirectory)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Process.Typed (proc, readProcess, setWorkingDir)

-- ---------------------------------------------------------------------------
-- Facts and cells
-- ---------------------------------------------------------------------------

-- | One promotion target, extracted from a real options.m. @mfLine@ is the
-- private registration verbatim (the edit's anchor); @mfPublicLine@ is the
-- expected replacement (same line, public constructor).
data MercuryFact = MercuryFact
  { mfOption :: !Text, -- e.g. "dump-mlds"
    mfConstructor :: !Text, -- "priv_alt_arg_help" / "priv_arg_help"
    mfPublicConstructor :: !Text, -- "alt_arg_help" / "arg_help"
    mfLineNo :: !Int,
    mfLine :: !Text,
    mfPublicLine :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | The options.m inside a Mercury tree.
mercuryOptionsPath :: FilePath -> FilePath
mercuryOptionsPath tree = tree </> "compiler" </> "options.m"

-- | The promotion targets: the MLDS dump family — (option, private
-- constructor, public constructor). Order = cell order.
mercuryPromotionTargets :: [(Text, Text, Text)]
mercuryPromotionTargets =
  [ ("dump-mlds", "priv_alt_arg_help", "alt_arg_help"),
    ("dump-mlds-pred-name", "priv_arg_help", "arg_help"),
    ("verbose-dump-mlds", "priv_alt_arg_help", "alt_arg_help")
  ]

-- | The needle that identifies a target's registration line.
targetNeedle :: Text -> Text -> Text
targetNeedle privC opt = privC <> "(\"" <> opt <> "\""

-- | Extract the facts for the promotion targets from a real options.m.
-- Targets whose private line is absent are skipped (already promoted, or
-- the tree changed under us — either way the analyze stage reports the gap
-- rather than inventing work).
readMercuryFacts :: FilePath -> IO [MercuryFact]
readMercuryFacts tree = do
  let fp = mercuryOptionsPath tree
  exists <- doesFileExist fp
  if not exists
    then pure []
    else do
      body <- TIO.readFile fp
      let ls = T.lines body
          facts =
            [ MercuryFact
                { mfOption = opt,
                  mfConstructor = privC,
                  mfPublicConstructor = pubC,
                  mfLineNo = i,
                  mfLine = l,
                  mfPublicLine = T.replace privC pubC l
                }
            | (opt, privC, pubC) <- mercuryPromotionTargets,
              (i, l) <- take 1 [(i, l) | (i, l) <- zip [1 :: Int ..] ls, targetNeedle privC opt `T.isInfixOf` l]
            ]
      pure facts

-- | One promotion cell: an option, its per-run worktree and branch, and the
-- fact the parent tree yielded at roster time. The workflow's analyze step
-- re-reads the worktree's own options.m — the tree, not a stale copy, is
-- ground truth.
data MercuryCell = MercuryCell
  { mcOption :: !Text,
    mcWorktree :: !FilePath,
    mcBranch :: !Text,
    mcFact :: !MercuryFact
  }
  deriving stock (Eq, Show)

-- | The cell's campaign branch for one run: @campaign/mercury-\<opt\>-\<tag\>@.
-- The run tag in the branch name makes every run a fresh, reviewable replay.
mercuryBranchFor :: Text -> Text -> Text
mercuryBranchFor opt tag = "campaign/mercury-" <> opt <> "-" <> tag

-- | The cell's worktree (Hands' path layout, so ensureCampaignWorktree
-- manages it).
mercuryWorktreeFor :: Text -> Text -> FilePath
mercuryWorktreeFor opt tag = campaignWorktreePath "mercury" (mercuryBranchFor opt tag)

-- | Rebuild a cell from its (option, run tag) — what the registry does from
-- the workflow id, and what the act does for its launch rows.
mercuryCellFor :: Text -> Text -> MercuryCell
mercuryCellFor opt tag =
  MercuryCell
    { mcOption = opt,
      mcWorktree = mercuryWorktreeFor opt tag,
      mcBranch = mercuryBranchFor opt tag,
      mcFact = placeholderFact opt
    }

-- | Every promotion cell the tree still needs (a tree whose family is
-- already promoted yields an empty roster — the campaign is done).
mercuryCellSpecs :: FilePath -> Text -> IO [MercuryCell]
mercuryCellSpecs tree tag = do
  facts <- readMercuryFacts tree
  pure
    [ MercuryCell
        { mcOption = mfOption f,
          mcWorktree = mercuryWorktreeFor (mfOption f) tag,
          mcBranch = mercuryBranchFor (mfOption f) tag,
          mcFact = f
        }
    | f <- facts
    ]

-- | Count the private registrations (lines starting with exactly four spaces
-- then @priv_@) in a tree's options.m. The no-regression guard's
-- denominator: promoting one option must lower this by exactly one.
mercuryPrivCount :: FilePath -> IO (Maybe Int)
mercuryPrivCount tree = do
  let fp = mercuryOptionsPath tree
  exists <- doesFileExist fp
  if not exists
    then pure Nothing
    else do
      body <- TIO.readFile fp
      pure (Just (length [() | l <- T.lines body, "    priv_" `T.isPrefixOf` l]))

-- ---------------------------------------------------------------------------
-- The staged oracle
-- ---------------------------------------------------------------------------

-- | One probe's verdict: pass/fail plus the detail a human (or the journal
-- reader) sees.
data OracleVerdict = OracleVerdict
  { ovOk :: !Bool,
    ovDetail :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | The fact probe over the edited worktree: the private registration is
-- gone, the expected public line is present verbatim, and the file's
-- private-registration count fell by exactly one relative to the worktree's
-- own git HEAD (no-regression: nothing else was demoted).
oracleFactProbe :: FilePath -> MercuryFact -> IO OracleVerdict
oracleFactProbe wt fact = do
  let fp = mercuryOptionsPath wt
  body <- TIO.readFile fp
  let ls = T.lines body
      privGone = not (any (targetNeedle (mfConstructor fact) (mfOption fact) `T.isInfixOf`) ls)
      publicIn = mfPublicLine fact `elem` ls
  baseline <- gitShowFile wt
  countNow <- mercuryPrivCount wt
  let countBase = length [() | l <- T.lines baseline, "    priv_" `T.isPrefixOf` l]
      countOk = case countNow of
        Just now -> now == countBase - 1
        Nothing -> False
      problems =
        ["the private registration is still present" | not privGone]
          <> ["the expected public line is absent" | not publicIn]
          <> ["the private-registration count did not fall by exactly one (no-regression guard)" | not countOk]
  pure
    OracleVerdict
      { ovOk = null problems,
        ovDetail =
          if null problems
            then
              "private line gone, public line in, priv-count "
                <> T.pack (show (fromMaybe 0 countNow))
                <> " (baseline "
                <> T.pack (show countBase)
                <> ")"
            else T.intercalate "; " problems
      }

-- | The dump probe: the capability the promotion exposes, proven against
-- the /installed/ compiler. Writes a tiny module, asks the grade-pinned MLDS
-- compiler (@--grade hlc.gc@) for a stage-99 MLLDS dump, and requires the
-- @.c_dump.099-final@ artifact. Grade pinning is the project goal's whole
-- point: dumps selectable by CLI options, no special build. The tag makes
-- the probe directory unique — concurrent cells must not clobber each
-- other's compile.
oracleDumpProbe :: Text -> IO OracleVerdict
oracleDumpProbe tag = do
  mmc <- findExecutable "mmc"
  case mmc of
    Nothing -> pure OracleVerdict {ovOk = False, ovDetail = "mmc not found on PATH"}
    Just _ -> do
      let dir = "/tmp/mercury-oracle-probe-" <> T.unpack tag
      createDirectoryIfMissing True dir
      TIO.writeFile (dir </> "hello.m") probeModule
      (ec, _, err) <-
        readProcess
          ( proc
              "mmc"
              [ "--grade",
                "hlc.gc",
                "--dump-mlds",
                "99",
                "hello.m"
              ]
              & setWorkingDir dir
          )
      let dumpPath = dir </> "hello.c_dump.099-final"
      dumpExists <- doesFileExist dumpPath
      case (ec, dumpExists) of
        (ExitSuccess, True) ->
          pure OracleVerdict {ovOk = True, ovDetail = "mmc --grade hlc.gc --dump-mlds 99 emitted " <> T.pack dumpPath}
        (ExitSuccess, False) ->
          pure OracleVerdict {ovOk = False, ovDetail = "mmc succeeded but emitted no stage-99 dump"}
        (_, _) ->
          pure
            OracleVerdict
              { ovOk = False,
                ovDetail = "mmc failed: " <> T.take 300 (TL.toStrict (TLE.decodeUtf8 err))
              }
  where
    probeModule =
      T.unlines
        [ ":- module hello.",
          ":- interface.",
          ":- import_module io.",
          ":- pred main(io::di, io::uo) is det.",
          ":- implementation.",
          "main(!IO) :- io.write_string(\"hi\\n\", !IO)."
        ]

-- | The worktree's options.m at HEAD (the pristine branch point — the
-- no-regression baseline). Nothing if git says no.
gitShowFile :: FilePath -> IO Text
gitShowFile wt = do
  (ec, out, _) <- readProcess (proc "git" ["-C", wt, "show", "HEAD:compiler/options.m"])
  pure $
    if ec == ExitSuccess
      then TL.toStrict (TLE.decodeUtf8 out)
      else ""

-- ---------------------------------------------------------------------------
-- The promotion engine
-- ---------------------------------------------------------------------------

-- | One propose attempt, keyed by attempt number — the same engine shape as
-- the matrix's 'Campaign.Matrix.MatrixEngine'. A scripted engine decides
-- from the TYPED 'ProposeIn' (no Context sniffing) but still runs the real
-- propose program through shikumi's stub LM, so rendering, decoding, and
-- validation are exercised; a live engine runs the same program through the
-- real model.
type MercuryEngine =
  -- | the attempt number
  Int ->
  -- | the propose program
  Program ProposeIn PatchPlan ->
  -- | the task, as the propose step carries it (typed)
  ProposeIn ->
  -- | recalled notes (informed-retry feedback rides in here)
  [Text] ->
  IO (Maybe PatchPlan)

-- | The propose signature: the coder's policy, specialized to promotion —
-- one line, constructor swap, nothing else.
mercuryPromotionSignature :: Signature ProposeIn PatchPlan
mercuryPromotionSignature =
  mkSignature
    "You are a careful code editor working on Mercury's compiler/options.m. \
    \The fact lines show one option registration that uses a private \
    \constructor (priv_arg_help or priv_alt_arg_help), which hides the \
    \option from --help and the reference manual. Promote it: produce ONE \
    \edit whose old block is exactly that line copied verbatim, and whose \
    \new block is the same line with the private constructor replaced by \
    \its public counterpart (arg_help or alt_arg_help). Change nothing else."

-- | A scripted engine: the script picks the response from the attempt
-- number, the typed task, and the recalled notes; the chosen response then
-- goes through the REAL pipeline (program render → stub LM → 'FromModel'
-- decode → validity check). A script that returns Nothing models a reply
-- from which no plan decodes.
mercuryScriptedEngine :: (Int -> ProposeIn -> [Text] -> Maybe Response) -> MercuryEngine
mercuryScriptedEngine scriptFor n prog input notes =
  case scriptFor n input notes of
    Nothing -> pure Nothing
    Just resp -> do
      r <- runStubEval (const resp) (runProgram prog input)
      pure $ case r of
        Right out -> Just out
        Left (_ :: ShikumiError) -> Nothing

-- ---------------------------------------------------------------------------
-- The workflow
-- ---------------------------------------------------------------------------

mercuryWorkflowName :: WorkflowName
mercuryWorkflowName = WorkflowName "mercury-promotion"

-- | The cell's workflow id for one run: @mercury:\<option\>:\<run tag\>@.
-- The tag keeps re-runs on fresh journals (the matrix's honest-fresh-run
-- lesson: a stable id replays a crashed run's journal without
-- re-publishing).
mercuryWorkflowIdTagged :: Text -> Text -> WorkflowId
mercuryWorkflowIdTagged opt tag = WorkflowId ("mercury:" <> opt <> ":" <> tag)

-- | Parse a workflow id back to its (option, run tag).
mercuryCellKeyFromWf :: WorkflowId -> Maybe (Text, Text)
mercuryCellKeyFromWf (WorkflowId t) = case T.splitOn ":" t of
  ["mercury", opt, tag] -> Just (opt, tag)
  _ -> Nothing

-- | The matrix's pacing lesson: a cool-down between attempts.
mercuryCoolDown :: NominalDiffTime
mercuryCoolDown = 0.1

-- | One journaled attempt (the @attempt-N@ step's record).
data MercuryAttempt = MercuryAttempt
  { meAttempt :: !Int,
    -- | "applied" or the exact-once guard's typed rejection
    meGuard :: !Text,
    -- | the retry payload appended to the next attempt's notes
    meFeedback :: !Text,
    -- | the plan's old/new blocks ("" when no plan decoded)
    meOld :: !Text,
    meNew :: !Text,
    -- | the fact probe after apply
    meFactOk :: !Bool,
    -- | the dump probe after apply
    meDumpOk :: !Bool,
    -- | "applied-ok" | "already-promoted" | "guard-failed: …" | "test-failed: …"
    meVerdict :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | All journaled attempts (from @attempt-N@ steps).
mercuryAttemptsOf :: [WorkflowJournalEvent] -> [MercuryAttempt]
mercuryAttemptsOf = mapMaybe extract
  where
    extract = \case
      StepRecorded name result _t
        | "attempt-" `T.isPrefixOf` name ->
            case Aeson.fromJSON result of
              Aeson.Success ma -> Just ma
              Aeson.Error _ -> Nothing
      _ -> Nothing

-- | The promotion cell, as a durable workflow:
--
--   1. @analyze-1@ ensures the cell's worktree exists, then reads its real
--      options.m: the private line is there (proceed) or absent (the cell
--      completes as already-promoted — the honest re-run story).
--   2. @attempt-N@ is one full propose → guard → apply → test pass,
--      journaled atomically. A failed probe /reverts the file/ before
--      returning, so a retry always starts clean.
--   3. @land-N@ commits the verified edit on the cell's branch.
--   4. Budget exhaustion parks on the same human seam every campaign cell
--      uses.
mercuryCellWorkflow ::
  (Workflow :> es, KirokuStoreResource :> es, Store :> es, IOE :> es) =>
  MercuryEngine ->
  -- | publish the human-query awakeable id (the operator's queue)
  (AwakeableId -> Eff es ()) ->
  MercuryCell ->
  Namespace ->
  Int ->
  Eff es Text
mercuryCellWorkflow engine publishHumanQuery cell ns maxAttempts = do
  analyzed <- step (StepName "analyze-1") (liftIO (analyzeIO cell))
  case analyzed of
    Nothing -> pure "already-promoted: the private registration is absent"
    Just _lineNo -> do
      notes0 <- recallNotesForKeyword ns "promote"
      go 1 notes0
  where
    go n notes
      | n > maxAttempts = park ("budget exhausted after " <> T.pack (show maxAttempts) <> " attempts")
      | otherwise = do
          att <- step (StepName ("attempt-" <> T.pack (show n))) (liftIO (attemptIO n notes cell engine))
          case meVerdict att of
            "applied-ok" -> do
              commit <- step (StepName ("land-" <> T.pack (show n))) (liftIO (landIO cell))
              pure ("landed: " <> commit)
            "already-promoted" -> pure "already-promoted: the private registration is absent"
            v
              | "guard-failed:" `T.isPrefixOf` v || "test-failed:" `T.isPrefixOf` v -> do
                  sleepNamed (StepName ("cool-down-" <> T.pack (show n))) mercuryCoolDown
                  -- The informed retry: the next attempt's notes carry the
                  -- typed rejection (the coder demo's failureReport) or the
                  -- probes' verdicts.
                  go (n + 1) (notes <> [meFeedback att])
              | otherwise -> park ("unknown attempt verdict: " <> v)

    park reason = do
      (awakeableId, awaitVerdict) <- awakeableNamed humanQueryStepName
      _publication <- step (StepName "publish-human-query") (publishHumanQuery awakeableId)
      verdict <- awaitVerdict
      case verdict of
        VerdictApproved -> pure ("human-approved: " <> reason <> "; verdict recorded")
        VerdictRejected -> pure ("human-rejected: " <> reason <> "; verdict recorded")

-- | The analyze stage: ensure the worktree, then the fact is real only if
-- the private line is in the worktree's options.m right now. Just the line
-- number rides forward (the attempt re-reads the file itself — the tree is
-- ground truth, not a stale copy).
analyzeIO :: MercuryCell -> IO (Maybe Int)
analyzeIO cell = do
  _ <- ensureCampaignWorktree "mercury" (mcBranch cell)
  facts <- readMercuryFacts (mcWorktree cell)
  pure (mfLineNo <$> listToMaybe [f | f <- facts, mfOption f == mcOption cell])

-- | One attempt: propose, guard, apply, probe — all in IO, journaled as one
-- record. A failed test reverts the file so the next attempt (or a human)
-- starts from the committed state.
attemptIO :: Int -> [Text] -> MercuryCell -> MercuryEngine -> IO MercuryAttempt
attemptIO n notes cell engine = do
  let wt = mcWorktree cell
      fp = mercuryOptionsPath wt
  fileText <- TIO.readFile fp
  facts <- readMercuryFacts wt
  case listToMaybe [f | f <- facts, mfOption f == mcOption cell] of
    Nothing -> pure emptyAttempt {meVerdict = "already-promoted"}
    Just fact -> do
      let proposeIn =
            ProposeIn
              { piPath = Field "compiler/options.m",
                piTitle = Field ("Promote --" <> mfOption fact <> " to a public option"),
                piWhy =
                  Field
                    ( "The option is registered with the private constructor "
                        <> mfConstructor fact
                        <> " (hidden from --help and the reference manual); the public constructor "
                        <> mfPublicConstructor fact
                        <> " is the established registration for user-visible options. "
                        <> "The whole change is that one line: swap the constructor, verbatim otherwise."
                    ),
                piFact =
                  Field
                    $ T.unlines
                    $ [T.pack (show (mfLineNo fact)) <> ": " <> mfLine fact]
                      ++ (if null notes then [] else ["", "Feedback on your previous attempt:"])
                      ++ map ("  " <>) notes
              }
          prog = predict mercuryPromotionSignature
      mPlan <- engine n prog proposeIn notes
      case mPlan of
        Nothing ->
          pure
            emptyAttempt
              { meFeedback = "the model's reply carried no patch plan",
                meVerdict = "guard-failed: no plan decoded from the model's reply"
              }
        Just plan ->
          case applyPlan fileText plan of
            Left f ->
              pure
                emptyAttempt
                  { meGuard = renderEditFailure f,
                    meFeedback = failureReport f,
                    meOld = unField (ppOld plan),
                    meNew = unField (ppNew plan),
                    meVerdict = "guard-failed: " <> renderEditFailure f
                  }
            Right newText -> do
              TIO.writeFile fp newText
              factV <- oracleFactProbe wt fact
              dumpV <- oracleDumpProbe (mfOption fact <> "-a" <> T.pack (show n))
              if ovOk factV && ovOk dumpV
                then
                  pure
                    emptyAttempt
                      { meGuard = "applied",
                        meOld = unField (ppOld plan),
                        meNew = unField (ppNew plan),
                        meFactOk = True,
                        meDumpOk = True,
                        meVerdict = "applied-ok"
                      }
                else do
                  -- The oracle failed: revert so the next attempt starts
                  -- from the committed state.
                  _ <- gitCapture wt ["checkout", "--", "compiler/options.m"]
                  pure
                    emptyAttempt
                      { meGuard = "applied",
                        meOld = unField (ppOld plan),
                        meNew = unField (ppNew plan),
                        meFactOk = ovOk factV,
                        meDumpOk = ovOk dumpV,
                        meFeedback =
                          "your previous edit applied but failed verification: "
                            <> T.intercalate "; " [ovDetail p | p <- [factV, dumpV], not (ovOk p)],
                        meVerdict =
                          "test-failed: "
                            <> T.intercalate "; " [ovDetail p | p <- [factV, dumpV], not (ovOk p)]
                      }
  where
    emptyAttempt =
      MercuryAttempt
        { meAttempt = n,
          meGuard = "",
          meFeedback = "",
          meOld = "",
          meNew = "",
          meFactOk = False,
          meDumpOk = False,
          meVerdict = ""
        }

-- | The landing stage: commit the verified edit on the cell's branch in the
-- cell's worktree. Idempotent: nothing to commit → the existing HEAD.
landIO :: MercuryCell -> IO Text
landIO cell = do
  let wt = mcWorktree cell
  status <- gitCapture wt ["status", "--porcelain", "compiler/options.m"]
  if T.null (T.strip status)
    then gitCapture wt ["rev-parse", "--short", "HEAD"]
    else do
      _ <- gitCapture wt ["add", "compiler/options.m"]
      _ <-
        gitCapture
          wt
          [ "commit",
            "-m",
            T.unpack (mercuryCommitMessage cell),
            "--",
            "compiler/options.m"
          ]
      gitCapture wt ["rev-parse", "--short", "HEAD"]

mercuryCommitMessage :: MercuryCell -> Text
mercuryCommitMessage cell =
  "campaign: promote --"
    <> mcOption cell
    <> " to a public option\n\n\
       \Landed by the shikumi-campaign Mercury promotion cell: proposed by\n\
       \the coder patch program, accepted by the exact-once guard, verified\n\
       \by the fact probe (private gone, public in, no-regression count) and\n\
       \the MLDS dump probe (mmc --grade hlc.gc --dump-mlds 99), and\n\
       \committed here by a journaled landing step.\n"

-- | The registry: one workflow name, every cell rebuilt from its id (the
-- option and run tag name the cell; the worktree and branch follow).
mercuryRegistry ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es) =>
  MercuryEngine ->
  (AwakeableId -> Eff es ()) ->
  WorkflowRegistry es
mercuryRegistry engine publishHumanQuery =
  Map.fromList
    [ ( mercuryWorkflowName,
        WorkflowDef $ \wid ->
          case mercuryCellKeyFromWf wid of
            Nothing -> error ("mercuryRegistry: malformed workflow id " <> mercuryWfIdText wid)
            Just (opt, tag) ->
              mercuryCellWorkflow
                engine
                (raise . publishHumanQuery)
                (mercuryCellFor opt tag)
                (projectNamespace "mercury")
                defaultMercuryMaxAttempts
      )
    ]

defaultMercuryMaxAttempts :: Int
defaultMercuryMaxAttempts = 3

mercuryWfIdText :: WorkflowId -> String
mercuryWfIdText (WorkflowId t) = T.unpack t

-- | The registry's cells carry a placeholder fact; the workflow's analyze
-- step re-reads the real tree (the worktree, not a stale copy, is ground
-- truth).
placeholderFact :: Text -> MercuryFact
placeholderFact opt =
  MercuryFact
    { mfOption = opt,
      mfConstructor = "priv_arg_help",
      mfPublicConstructor = "arg_help",
      mfLineNo = 0,
      mfLine = "",
      mfPublicLine = ""
    }

-- ---------------------------------------------------------------------------
-- The help-check cell: the paced compiler build
-- ---------------------------------------------------------------------------
--
-- The third oracle probe, deliberately deferred from the first Mercury rung:
-- @mercury_compile --help@ shows the promoted options only in a compiler
-- BUILT from a promoted tree. That is an hours-long, resumable, paced
-- process — the matrix rung's slow-cell pattern applied to a compiler
-- bootstrap:
--
--   * one integration worktree per run tag, in which every promotion landing
--     found in the parent repo is merged, so ONE compiler build carries every
--     promotion (the parent checkout's own working tree is never touched),
--   * one help-check worktree per tag, branched from the integration branch,
--     shared by all three cells of the tag (three @--help@ assertions, one
--     build),
--   * configure and the canonical mmake stages (util → runtime → library →
--     mdbcomp → browser → ssdb → compiler), each stage probed under a
--     wall-clock timeout one round at a time: @completed@ advances,
--     @still-running@ (timeout 124/143) suspends on a durable timer and the
--     next round re-probes — mmake is idempotent, so no work is ever lost.
--     The keiro determinism rule shapes the loop: a recorded step never
--     re-executes, so every probe round gets its OWN step name
--     (@bootstrap-<n>-<stage>-r<k>@); a resume pass replays the recorded
--     rounds cheaply, executes exactly one new bounded probe, and suspends.
--   * @failed@ parks on the shared human seam,
--   * after the compiler stage, the artifact probe: the fresh binary's
--     @--help@ must mention each promoted option. The negative control is
--     real — the installed compiler shows zero.
--
-- The run tag is the newest landing's tip hash: same landings mean the same
-- tag, so a second act run RESUMES the same worktree, journal, and build
-- instead of discarding hours of progress.

-- | One bounded probe of one bootstrap stage (or configure).
data HelpStageVerdict = HelpStageVerdict
  { hsStage :: !Text,
    hsOutcome :: !Text, -- "completed" | "still-running" | "failed"
    hsDetail :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | The artifact check: does the freshly built compiler's --help show the
-- promoted option?
data HelpCheckVerdict = HelpCheckVerdict
  { hvShows :: !Bool,
    hvHits :: !Int,
    hvDetail :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | One help-check cell: the promotions to prove and the tag naming the
-- build. Deliberately ONE cell for ALL options — one compiler build, three
-- artifact assertions — because three concurrent mmake builds in one
-- worktree would race.
data HelpCheckCell = HelpCheckCell
  { hcOptions :: ![Text],
    hcTag :: !Text
  }
  deriving stock (Eq, Show)

helpCheckWorkflowName :: WorkflowName
helpCheckWorkflowName = WorkflowName "mercury-help-check"

helpCheckWorkflowIdTagged :: Text -> WorkflowId
helpCheckWorkflowIdTagged tag = WorkflowId ("mercury-help:" <> tag)

helpCheckCellKeyFromWf :: WorkflowId -> Maybe Text
helpCheckCellKeyFromWf (WorkflowId t) = case T.splitOn ":" t of
  ["mercury-help", tag] -> Just tag
  _ -> Nothing

-- | The help-check branch (and with 'campaignWorktreePath', the worktree)
-- for one tag. Keyed on the LANDING tip only — the recipe revision is
-- deliberately NOT part of it — so a fixed recipe reuses the existing build
-- (mmake is idempotent and every probe re-verifies for real) instead of
-- discarding hours of work. Only the JOURNAL id carries the revision, so a
-- fixed recipe still gets a fresh journal and stale recorded verdicts never
-- replay.
helpCheckBranchFor :: Text -> Text
helpCheckBranchFor tag =
  "campaign/mercury-help-" <> case T.breakOnEnd "-r" tag of
    (prefix, rev)
      | T.all isDigit rev && not (T.null rev) -> T.dropEnd 2 prefix
    _ -> tag

helpCheckCellFor :: [Text] -> Text -> HelpCheckCell
helpCheckCellFor opts tag =
  HelpCheckCell {hcOptions = opts, hcTag = tag}

-- | Every @campaign/mercury-...@ landing in the parent repo (worktrees
-- share refs), as @(option, branch)@ pairs, newest first.
mercuryPromotionBranches :: FilePath -> IO [(Text, Text)]
mercuryPromotionBranches parent = do
  out <-
    gitCapture
      parent
      [ "for-each-ref",
        "--sort=-committerdate",
        "--format=%(refname:short)",
        "refs/heads/campaign"
      ]
  -- The pattern is a ref DIRECTORY; the landings are flat files under it
  -- (campaign/mercury-dump-mlds-… is ONE name, not a mercury/ directory),
  -- so filter by the exact prefix here.
  let branches =
        [ T.strip l
        | l <- T.lines out,
          T.isPrefixOf "campaign/mercury-" (T.strip l),
          not (T.null (T.strip l))
        ]
  pure
    [ (opt, b)
    | b <- branches,
      Just rest <- [T.stripPrefix "campaign/mercury-" b],
      -- Option names contain hyphens (dump-mlds-pred-name), so match the
      -- known targets rather than splitting on the first hyphen.
      opt <- [t | (t, _, _) <- mercuryPromotionTargets, (t <> "-") `T.isPrefixOf` rest],
      not (T.null opt)
    ]

-- | The recipe revision: bumped whenever the cell's own procedure changes
-- (like fixing the configure execute bit), so the fixed recipe runs under a
-- FRESH journal while an unchanged recipe keeps resuming its build.
helpCheckRecipeRevision :: Int
helpCheckRecipeRevision = 10

-- | The stable run tag for a set of landings: the newest landing's tip
-- hash plus the recipe revision. Same landings and the same recipe mean the
-- same tag, so the same worktree and journal are resumed across act runs;
-- new landings or a fixed recipe mean a new tag, a fresh build.
mercuryIntegrationTag :: FilePath -> [(Text, Text)] -> IO Text
mercuryIntegrationTag _parent [] = pure "nolandings"
mercuryIntegrationTag parent ((_, newest) : _) = do
  out <- gitCapture parent ["rev-parse", "--short", T.unpack newest]
  pure ("h" <> T.strip out <> "-r" <> T.pack (show helpCheckRecipeRevision))

integrationBranchName :: Text
integrationBranchName = "campaign/mercury-integration"

-- | The integration worktree: a worktree on 'integrationBranchName' (from
-- the parent's HEAD) in which every promotion landing is merged, so one
-- compiler build carries every promotion. The parent checkout's own working
-- tree is never touched. Idempotent: an existing worktree is reused and the
-- merges are no-ops once applied; a landing that cannot auto-merge is
-- skipped and reported, and the artifact check then honestly reflects the
-- tree that was actually built.
ensureIntegrationWorktree :: FilePath -> IO (Text, [Text])
ensureIntegrationWorktree parent = do
  landings <- mercuryPromotionBranches parent
  let wt = campaignWorktreePath "mercury" integrationBranchName
  _ <- gitCapture parent ["worktree", "prune"]
  registered <- doesDirectoryExist wt
  unless registered $
    tryAddWorktree parent wt integrationBranchName
  integrated <- forM landings $ \(opt, b) -> do
    ok <- tryIsAncestor wt b
    if ok
      then pure (Just opt) -- already merged: the no-op re-merge
      else do
        r <- try (gitCapture wt ["merge", "--no-edit", "-q", T.unpack b])
        case r of
          Right _ -> pure (Just opt)
          Left (_ :: SomeException) -> do
            _ <- try (gitCapture wt ["merge", "--abort"]) :: IO (Either SomeException Text)
            pure Nothing -- cannot auto-merge; skipped, reported honestly
  pure (integrationBranchName, catMaybes integrated)

-- | Is @b@ already an ancestor of HEAD in the repo at @dir@? (git exits 0
-- silently when it is, 1 when it is not.)
tryIsAncestor :: FilePath -> Text -> IO Bool
tryIsAncestor dir b = do
  r <- try (gitCapture dir ["merge-base", "--is-ancestor", T.unpack b, "HEAD"])
  pure $ case r of
    Right _ -> True
    Left (_ :: SomeException) -> False

-- | @git worktree add@ with a new branch, falling back to checking out the
-- existing branch when the directory was wiped but the branch lives on.
tryAddWorktree :: FilePath -> FilePath -> Text -> IO ()
tryAddWorktree parent wt branch = do
  _ <-
    gitCapture parent ["worktree", "add", wt, "-b", T.unpack branch]
      `catchAny` \_ ->
        gitCapture parent ["worktree", "add", wt, T.unpack branch]
  pure ()

-- | The help-check worktree, branched FROM the integration branch (the
-- promotions must be in the tree being built). Idempotent: an existing
-- worktree is resumed, not recreated.
ensureHelpCheckWorktree :: FilePath -> Text -> Text -> IO FilePath
ensureHelpCheckWorktree parent integrationBranch helpBranch = do
  let wt = campaignWorktreePath "mercury" helpBranch
  _ <- gitCapture parent ["worktree", "prune"]
  registered <- doesDirectoryExist wt
  if registered
    then wt <$ ensureBoehmGc parent wt
    else do
      -- The integration worktree must EXIST (not just the ref) before the
      -- help worktree branches from it.
      let integrationWt = campaignWorktreePath "mercury" integrationBranch
      haveIntegration <- doesDirectoryExist integrationWt
      unless haveIntegration $ void (ensureIntegrationWorktree parent)
      -- git refuses to check out a branch that is already checked out in
      -- another worktree (the integration worktree holds its branch), so
      -- the help worktree gets its OWN branch, pre-created at the
      -- integration tip. The branch name carries the tag, so an existing
      -- branch was created by a previous run of the SAME tag and points at
      -- the same tree.
      haveBranch <-
        try (gitCapture parent ["rev-parse", "--verify", "refs/heads/" <> T.unpack helpBranch])
      case haveBranch of
        Right _ -> pure ()
        Left (_ :: SomeException) ->
          void (gitCapture parent ["branch", T.unpack helpBranch, T.unpack integrationBranch])
      _ <- gitCapture parent ["worktree", "add", wt, T.unpack helpBranch]
      wt <$ ensureBoehmGc parent wt
  -- Also on the resume path: a worktree created by recipe r2 has no GC.
  where
    -- The world-fact: @boehm_gc@ is a git submodule that fresh worktrees
    -- never initialize (and this deployment has no network for it), while
    -- the parent checkout's copy is populated AND built. The runtime stage
    -- cannot even compile without gc_mark.h, so the recipe copies the
    -- parent's tree in. Idempotent: only when the worktree's copy is empty.
    ensureBoehmGc parentRepo wt = do
      let gcInWt = wt </> "boehm_gc"
          gcInParent = parentRepo </> "boehm_gc"
      haveParent <- doesDirectoryExist gcInParent
      haveInWt <- doesDirectoryExist gcInWt
      emptyInWt <- if haveInWt then null <$> listDirectory gcInWt else pure True
      when (emptyInWt && haveParent)
        $
        -- The destination exists (git creates the empty submodule dir), so
        -- copy the CONTENTS (SRC/.), not the directory itself.
        void
        $ readProcess (proc "cp" ["-a", gcInParent <> "/.", gcInWt])

-- | Any exception, swallowed (the git merges and probes run on real trees
-- and can fail in real ways; the verdicts carry the failure).
catchAny :: IO a -> (SomeException -> IO a) -> IO a
catchAny = catch

-- | Run a shell command in a directory under a wall-clock timeout, with the
-- installed compiler pinned as the bootstrapping MERCURY_COMPILER. Exit 124
-- means the timeout fired — the stage simply is not done yet.
runPaced :: Int -> FilePath -> Text -> IO (ExitCode, Text)
runPaced secs dir cmd = do
  (ec, out, err) <-
    readProcess $
      proc "timeout" [show secs, "sh", "-c", T.unpack cmd]
        & setWorkingDir dir
  pure (ec, TL.toStrict (TLE.decodeUtf8 out) <> TL.toStrict (TLE.decodeUtf8 err))

bootstrappingCompiler :: Text
bootstrappingCompiler = "MERCURY_COMPILER=/home/nyc/.local/bin/mercury_compile"

-- | One bounded probe of the configure stage. The world-fact this
-- deployment encodes: the @configure@ script is generated (never committed)
-- and this box's autoconf produces a broken one, while the parent checkout's
-- pre-generated script works — so the bootstrap copies the parent's before
-- configuring.
bootstrapConfigureProbe :: FilePath -> IO HelpStageVerdict
bootstrapConfigureProbe tree = do
  configured <- doesFileExist (tree </> "Mmake.common")
  if configured
    then pure (HelpStageVerdict "configure" "completed" "Mmake.common already present")
    else do
      haveConfigure <- doesFileExist (tree </> "configure")
      unless haveConfigure $ do
        srcConfigure <-
          TIO.readFile "/home/nyc/src/mercury/configure"
            `catch` \(_ :: SomeException) -> pure ""
        unless (T.null srcConfigure) $
          TIO.writeFile (tree </> "configure") srcConfigure
      -- The script must be executable UNCONDITIONALLY: a worktree may carry
      -- a configure copied by an older recipe (writeFile makes mode 644,
      -- and an existing file skips the copy path entirely — journal-verified
      -- when recipe r6 failed on exactly that stale copy).
      hasConfigure <- doesFileExist (tree </> "configure")
      when hasConfigure
        $ void
        $ readProcess (proc "chmod" ["+x", tree </> "configure"])
      (ec, out) <- runPaced 240 tree (bootstrappingCompiler <> " ./configure --prefix=/tmp/mhelp-install 2>&1")
      pure $ case ec of
        ExitSuccess -> HelpStageVerdict "configure" "completed" "configured"
        ExitFailure 124 -> HelpStageVerdict "configure" "still-running" (T.take 200 (lastNonEmptyLine out))
        ExitFailure 143 -> HelpStageVerdict "configure" "still-running" (T.take 200 (lastNonEmptyLine out))
        _ -> HelpStageVerdict "configure" "failed" (T.take 400 (T.strip out))
  where
    lastNonEmptyLine t = case reverse (filter (not . T.null . T.strip) (T.lines t)) of
      (l : _) -> T.strip l
      [] -> "(no output)"

-- | The canonical bootstrap order: (stage name, command, subdirectory).
-- The C stages (util, runtime) are plain @mmake@; the Mercury-source stages
-- need dependency generation first — without it the library fails with
-- "undefined variable mer_std.mhs" (journal-verified, recipe r4). The
-- compiler stage is the hours-long one and names its binary target.
mercuryBootstrapStages :: [(Text, Text, FilePath)]
mercuryBootstrapStages =
  [ ("util", "mmake", "util"),
    ("runtime", "mmake", "runtime"),
    ("library", "mmake depend && mmake", "library"),
    ("mdbcomp", "mmake depend && mmake", "mdbcomp"),
    -- The compiler links ../trace/libmer_trace.a — journal-verified (recipe
    -- r5 died exactly there) — so trace is a stage of its own. Its
    -- Mmakefile has no depend target at all: it is a C-only library, so a
    -- plain mmake (journal-verified: r7's "mmake depend" died with "no rule
    -- to make depend").
    ("trace", "mmake", "trace"),
    ("browser", "mmake depend && mmake", "browser"),
    ("ssdb", "mmake depend && mmake", "ssdb"),
    ("compiler", "mmake depend && mmake mercury_compile", "compiler"),
    -- What `mmake install` would do next: put the freshly generated
    -- compiler configuration where the freshly built compiler looks for it
    -- (<stdlib>/conf/Mercury.config). Without it the artifact probe dies
    -- with "cannot open options file" (journal-verified, recipe r9). The
    -- probe then runs the bare binary against the FRESH library, never the
    -- installed one.
    ("install-config", "mkdir -p library/conf && cp -f scripts/Mercury.config library/conf/Mercury.config", "")
  ]

-- | One bounded probe of one stage, in the stage's own directory. The C
-- stages finish in seconds; the Mercury-source stages are given a generous
-- slice per round — mmake is incremental, so every timeout simply means
-- "more done, resume later".
bootstrapStageProbe :: FilePath -> (Text, Text, FilePath) -> IO HelpStageVerdict
bootstrapStageProbe tree (name, cmd, subdir) = do
  let slice = if name `elem` ["util", "runtime"] then 60 else 240
  (ec, out) <- runPaced slice (tree </> subdir) (bootstrappingCompiler <> " " <> cmd <> " 2>&1")
  pure $ case ec of
    ExitSuccess -> HelpStageVerdict name "completed" (lastLine out)
    ExitFailure 124 -> HelpStageVerdict name "still-running" (lastLine out)
    ExitFailure 143 -> HelpStageVerdict name "still-running" (lastLine out)
    _ -> HelpStageVerdict name "failed" (T.take 400 (T.strip out))
  where
    lastLine t = case reverse (filter (not . T.null . T.strip) (T.lines t)) of
      (l : _) -> T.take 200 (T.strip l)
      [] -> "(no output)"

-- | The artifact probe: the freshly built compiler's --help, via the
-- build tree's own generated @scripts/mmc@ wrapper (it pins the fresh
-- MERCURY_COMPILER, MERCURY_STDLIB_DIR and friends INTO the worktree — the
-- bare binary refuses to even print --help without them, journal-verified
-- in recipe r8). The negative control is real: the installed compiler
-- shows zero dump-mlds lines.
helpCheckProbe :: FilePath -> Text -> IO HelpCheckVerdict
helpCheckProbe tree opt = do
  let bin = tree </> "compiler" </> "mercury_compile"
  have <- doesFileExist bin
  if not have
    then pure (HelpCheckVerdict False 0 "the compiler binary does not exist yet")
    else do
      -- The FRESH library (the build tree's own), never the installed one:
      -- the whole point is that the built compiler is the one under test.
      let invocation =
            "MERCURY_STDLIB_DIR="
              <> T.pack (tree </> "library")
              <> " "
              <> T.pack bin
              <> " --help 2>&1"
      (ec, out) <- runPaced 60 (tree </> "compiler") invocation
      let hits = length [() | l <- T.lines out, ("--" <> opt) `T.isInfixOf` l]
      pure $ case ec of
        ExitSuccess ->
          HelpCheckVerdict
            { hvShows = hits > 0,
              hvHits = hits,
              hvDetail =
                if hits > 0
                  then "--" <> opt <> " appears " <> T.pack (show hits) <> " time(s) in --help"
                  else "--" <> opt <> " is still absent from --help"
            }
        _ -> HelpCheckVerdict False 0 ("--help failed: " <> T.take 300 (T.strip out))

helpCheckCoolDown :: NominalDiffTime
helpCheckCoolDown = 0.1

-- | The help-check workflow: integrate the landings, ensure the worktree,
-- then pace through configure and the bootstrap stages — one bounded probe
-- per round, one round-unique step per probe (a recorded step never
-- re-executes, so each resume pass runs exactly one new probe);
-- @still-running@ suspends on a durable timer; @failed@ parks on the human
-- seam. After the compiler stage, the artifact check decides the cell.
mercuryHelpCheckWorkflow ::
  (Workflow :> es, KirokuStoreResource :> es, Store :> es, IOE :> es) =>
  -- | publish the human-query awakeable id
  (AwakeableId -> Eff es ()) ->
  HelpCheckCell ->
  Eff es Text
mercuryHelpCheckWorkflow publishHumanQuery cell = do
  (_branch, _integrated) <-
    step (StepName "integrate") . liftIO $
      ensureIntegrationWorktree "/home/nyc/src/mercury"
  wt <-
    step (StepName "ensure-worktree") . liftIO $
      ensureHelpCheckWorktree
        "/home/nyc/src/mercury"
        integrationBranchName
        (helpCheckBranchFor (hcTag cell))
  configureLoop wt 1
  where
    total = length mercuryBootstrapStages

    -- The configure stage: one bounded probe per round until it completes.
    configureLoop wt k = do
      v <- step (StepName ("configure-r" <> T.pack (show (k :: Int)))) (liftIO (bootstrapConfigureProbe wt))
      case hsOutcome v of
        "completed" -> paceStages wt 1 1
        "still-running" -> do
          sleepNamed (StepName ("cool-configure-r" <> T.pack (show k))) helpCheckCoolDown
          configureLoop wt (k + 1)
        _ -> park ("configure failed: " <> hsDetail v)

    -- The bootstrap stages: round k of stage n is its own step; a
    -- still-running probe suspends on a durable timer and the next round
    -- re-probes the same stage.
    paceStages wt n k
      | n > total = finish wt
      | otherwise = do
          let stage = mercuryBootstrapStages !! (n - 1)
              stageName = fst3 stage
          v <-
            step
              (StepName ("bootstrap-" <> T.pack (show (n :: Int)) <> "-" <> stageName <> "-r" <> T.pack (show (k :: Int))))
              (liftIO (bootstrapStageProbe wt stage))
          case hsOutcome v of
            "completed" -> paceStages wt (n + 1) 1
            "still-running" -> do
              sleepNamed (StepName ("cool-" <> T.pack (show n) <> "-r" <> T.pack (show k))) helpCheckCoolDown
              paceStages wt n (k + 1)
            _ -> park ("stage " <> stageName <> " failed: " <> hsDetail v)

    finish wt = do
      verdicts <-
        step (StepName "help-check") . liftIO $
          forM (hcOptions cell) (helpCheckProbe wt)
      let zipped = zip (hcOptions cell) verdicts
          shown_ = [o | (o, v) <- zipped, hvShows v]
          missing = [o | (o, v) <- zipped, not (hvShows v)]
      pure $
        "help-check: "
          <> T.pack (show (length shown_))
          <> "/"
          <> T.pack (show (length (hcOptions cell)))
          <> " promoted option(s) visible in the built compiler's --help"
          <> (if null missing then "" else "; absent: " <> T.intercalate ", " missing)

    park reason = do
      (awakeableId, awaitVerdict) <- awakeableNamed humanQueryStepName
      _publication <- step (StepName "publish-human-query") (publishHumanQuery awakeableId)
      verdict <- awaitVerdict
      case verdict of
        VerdictApproved -> pure ("human-approved: " <> reason)
        VerdictRejected -> pure ("human-rejected: " <> reason)

    fst3 (a, _, _) = a

-- | The help-check registry: the one per-tag cell rebuilt from its id
-- (@mercury-help:\<tag\>@). The options are the run's landing set — the tag
-- pins that set (any new landing changes the newest tip hash), so the
-- closure is deterministic across replays of the same tag.
helpCheckRegistry ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es) =>
  -- | the promoted options this run proves
  [Text] ->
  (AwakeableId -> Eff es ()) ->
  WorkflowRegistry es
helpCheckRegistry opts publishHumanQuery =
  Map.fromList
    [ ( helpCheckWorkflowName,
        WorkflowDef $ \wid ->
          case helpCheckCellKeyFromWf wid of
            Nothing -> error ("helpCheckRegistry: malformed workflow id " <> show wid)
            Just tag ->
              mercuryHelpCheckWorkflow
                (raise . publishHumanQuery)
                (helpCheckCellFor opts tag)
      )
    ]

-- | The negative control, run for real: the INSTALLED compiler's --help
-- (zero dump-mlds mentions today). The bare binary needs the environment
-- its @mmc@ wrapper would set — at minimum MERCURY_STDLIB_DIR — and this is
-- the same artifact probe the cell runs against the built compiler, pointed
-- at the pre-promotion binary.
installedHelpCheckProbe :: Text -> IO HelpCheckVerdict
installedHelpCheckProbe opt = do
  (ec, out) <-
    runPaced
      60
      "/tmp"
      ( "MERCURY_STDLIB_DIR=/home/nyc/.local/lib/mercury "
          <> T.pack "/home/nyc/.local/bin/mercury_compile --help 2>&1"
      )
  let hits = length [() | l <- T.lines out, ("--" <> opt) `T.isInfixOf` l]
  pure $ case ec of
    ExitSuccess ->
      HelpCheckVerdict
        { hvShows = hits > 0,
          hvHits = hits,
          hvDetail =
            if hits > 0
              then "--" <> opt <> " appears " <> T.pack (show hits) <> " time(s) in the installed compiler's --help"
              else "--" <> opt <> " is absent from the installed compiler's --help (the negative control)"
        }
    _ -> HelpCheckVerdict False 0 ("installed --help failed: " <> T.take 300 (T.strip out))
