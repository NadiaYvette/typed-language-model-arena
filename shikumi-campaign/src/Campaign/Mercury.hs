{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GHC2024 #-}
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
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Aeson qualified as Aeson
import Data.Function ((&))
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe, mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Text.Lazy qualified as TL
import Data.Text.Lazy.Encoding qualified as TLE
import Data.Time.Clock (NominalDiffTime)
import Effectful (Eff, IOE, liftIO, raise, (:>))
import GHC.Generics (Generic)
import System.Directory (createDirectoryIfMissing, doesFileExist, findExecutable)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Process.Typed (proc, readProcess, setWorkingDir)

import Baikai (Response)
import Campaign.Hands (campaignWorktreePath, ensureCampaignWorktree, gitCapture)
import Campaign.Memory (projectNamespace, recallNotesForKeyword)
import Campaign.Workflow (HumanVerdict (..), humanQueryStepName)
import Keiro.Workflow (StepName (..), Workflow, WorkflowId (..), step)
import Keiro.Workflow.Awakeable (AwakeableId, awakeableNamed)
import Keiro.Workflow.Resume (WorkflowDef (..), WorkflowRegistry)
import Keiro.Workflow.Sleep (sleepNamed)
import Keiro.Workflow.Types (WorkflowJournalEvent (..), WorkflowName (..))
import Kioku.Api.Scope (Namespace)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Effect.Resource (KirokuStoreResource)
import Shikumi.Error (ShikumiError)
import Shikumi.Module (predict)
import Shikumi.Program (Program, runProgram)
import Shikumi.Schema.Types (Field (Field, unField))
import Shikumi.Signature (Signature, mkSignature)
import Shikumi.Testing (runStubEval)
import Shikumi.Coder.Pipeline (ProposeIn (..), failureReport)
import Shikumi.Coder.Task (PatchPlan (..), applyPlan, renderEditFailure)

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
      publicIn = any (== mfPublicLine fact) ls
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
                <> T.pack (show (maybe 0 id countNow))
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
                  Field $
                    T.unlines $
                      [T.pack (show (mfLineNo fact)) <> ": " <> mfLine fact]
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