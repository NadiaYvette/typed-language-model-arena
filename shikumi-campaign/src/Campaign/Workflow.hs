{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The one-cell campaign as a keiro durable workflow.
--
-- The decision layer is toy-fixer's shikumi fixer 'Program', promoted into a
-- journaled process:
--
--   1. @verify-initial@ — a plain step journals the oracle's diagnostics.
--   2. @propose-fix-N@ — one LM attempt per step. The step action runs the
--      shikumi program (stub model here; a live stack is the same call)
--      under the attempt-keyed responder and applies the typed
--      no-regression guard. The journaled result is the 'FixAttempt' record
--      (with the repair), so replay never re-asks the model — attempts are
--      durable decisions. A crash between "model answered" and "journal
--      written" re-runs the attempt (at-least-once, jitsurei's publisher
--      contract).
--   3. A durable 'sleepNamed' paces attempts (in a real campaign: the build
--      or boot itself).
--   4. If the budget is exhausted with the cell still failing, the workflow
--      parks on an 'awakeableNamed' — the typed human seam — after
--      publishing the query id through an idempotent callback.
--   5. The 'HumanVerdict' signal (or a clean cell at any checkpoint)
--      completes the workflow with a verdict line.
module Campaign.Workflow
  ( -- * Names
    cellCampaignWorkflowName,
    campaignWorkflowId,
    campaignIdFromWf,
    campaignStreamNameText,
    projectCampaignWorkflowName,
    projectWorkflowId,
    projectCellFromWf,

    -- * The human seam
    HumanVerdict (..),
    humanQueryStepName,

    -- * The decision step's configuration
    AttemptEngine,
    EngineFor,
    stubEngine,
    guidedFixer,
    HumanQueryPublisher,

    -- * The workflow
    cellCampaignWorkflow,
    defaultMaxAttempts,

    -- * The surgical guard (the repair contract's enforcement half)
    surgicalRepair,

    -- * The registry
    campaignRegistry,
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock (NominalDiffTime)
import Control.Applicative ((<|>))
import Effectful (Eff, IOE, liftIO, raise, (:>))
import Effectful.Error.Static (throwError)
import GHC.Generics (Generic)

import Baikai (Context, Response)
import Campaign.Memory (campaignNamespace, projectNamespace, projectNamespaceSafe, recallNotesForKeyword)
import Campaign.Oracle (CellOracle (..), ProjectCell (..), RepairRules (..), markerOracle, pythonSyntaxCheck, repairRulesFor, unusedImportOracle)
import Data.Char (isDigit)
import Data.List (find)
import Kioku.Api.Scope (Namespace)
import Kiroku.Store.Effect.Resource (KirokuStoreResource)
import Shikumi.Combinator ((>>>))
import Shikumi.Error (ShikumiError (..))
import Shikumi.Module (predict)
import Shikumi.Program (Program, embed, runProgram)
import Shikumi.Schema.Types (Field (..))
import Shikumi.Signature (Demo (..), Signature, getInstruction, setDemos, setInstruction)
import Shikumi.Testing (runStubEval)
import Toy.Fixer.Domain (Source (..), SourcePath, diagLine, showDiagnostic, sourceText)
import Toy.Fixer.Program (DiagnosticsIn (..), RepairOut (..), applyRepair, repairSignature)

import Campaign.Cell
  ( Cell (..),
    CellId (..),
    FixAttempt (..),
    cellForId,
    unCellId,
  )
import Data.List (find)

import Keiro.Workflow
  ( StepName (..),
    Workflow,
    WorkflowId (..),
    step,
    workflowStreamName,
  )
import Keiro.Workflow.Awakeable (AwakeableId, awakeableNamed)
import Keiro.Workflow.Resume (WorkflowDef (..), WorkflowRegistry)
import Keiro.Workflow.Sleep (sleepNamed)
import Keiro.Workflow.Types (WorkflowName (..))
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Types (StreamName (..))

-- ---------------------------------------------------------------------------
-- Names and identity
-- ---------------------------------------------------------------------------

cellCampaignWorkflowName :: WorkflowName
cellCampaignWorkflowName = WorkflowName "cell-campaign"

-- | The workflow instance id embeds the cell id, so the journal stream is
-- findable from the cell alone and the registry can rebuild the body from
-- the id (mirroring jitsurei's order-id round trip). A @-escalation@ suffix
-- distinguishes a second campaign over the same cell (the demo's act 2) from
-- the first; both map back to the same cell.
campaignWorkflowId :: CellId -> WorkflowId
campaignWorkflowId (CellId t) = WorkflowId ("cell-" <> t)

campaignIdFromWf :: WorkflowId -> CellId
campaignIdFromWf (WorkflowId t0) = CellId cellPath
  where
    t1 = fromMaybe t0 (T.stripPrefix "cell-" t0)
    cellPath = fromMaybe t1 (T.stripSuffix "-escalation" t1)

campaignStreamNameText :: WorkflowName -> WorkflowId -> Text
campaignStreamNameText name wid =
  let StreamName s = workflowStreamName name wid in s

-- | The project-cells workflow (real files, the real oracle, per-project
-- memory namespaces).
projectCampaignWorkflowName :: WorkflowName
projectCampaignWorkflowName = WorkflowName "project-cell-campaign"

-- | A project workflow id embeds @project:path@ under a @pcell-@ prefix.
projectWorkflowId :: Text -> SourcePath -> WorkflowId
projectWorkflowId proj path = WorkflowId ("pcell-" <> proj <> ":" <> path)

-- | Round-trip 'projectWorkflowId'.
projectCellFromWf :: WorkflowId -> Maybe (Text, SourcePath)
projectCellFromWf (WorkflowId t0) = do
  -- "pcell-<proj>:<path>" or "pcell-<prefixes><proj>:<path>" where <prefixes>
  -- is any run of the fresh-campaign instance prefixes ("react-", "live-",
  -- "dispatch-") the acts put in front of the same cells.
  t <- T.stripPrefix "pcell-" t0
  let t1 = stripInstancePrefixes t
      (proj, pathRest) = T.breakOn ":" t1
  case T.stripPrefix ":" pathRest of
    Nothing -> fail "projectCellFromWf: malformed path part"
    Just path -> pure (proj, path)
  where
    stripInstancePrefixes u =
      -- Named prefixes first (the acts' fixed tags), then the act-22 per-run
      -- instance tag: "app" <> digits <> "-" (runTag is a POSIX-seconds show).
      case T.stripPrefix "react-" u <|> T.stripPrefix "live-" u <|> T.stripPrefix "dispatch-" u <|> T.stripPrefix "app-" u of
        Just u' -> stripInstancePrefixes u'
        Nothing
          | Just r <- T.stripPrefix "app" u,
            (ds, rest) <- T.span isDigit r,
            not (T.null ds),
            Just u' <- T.stripPrefix "-" rest ->
              stripInstancePrefixes u'
          | otherwise -> u

-- ---------------------------------------------------------------------------
-- The human seam: the typed third outcome
-- ---------------------------------------------------------------------------

data HumanVerdict = VerdictApproved | VerdictRejected
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | The awakeable step name for the human verdict.
humanQueryStepName :: StepName
humanQueryStepName = StepName "human-verdict"

-- ---------------------------------------------------------------------------
-- The decision step's configuration
-- ---------------------------------------------------------------------------

-- | The decision engine: run one attempt (keyed by its number, so a scripted
-- stub can fail early attempts) of the fixer program — ground truth and
-- recalled memory already bound in — on its input, returning the proposed
-- repair; 'Nothing' on any typed 'ShikumiError' (a guard rejection, a
-- malformed reply). The workflow body is agnostic to what executes the
-- program: the /stub/ engine replays a scripted responder through shikumi's
-- stub LM ('stubEngine'); the /live/ engine runs the very same program
-- through kioku's 'runAIProgram' — the exact call kioku's own distillers
-- make. Swapping engines changes nothing else: same oracle, same journal,
-- same timers, same attempt budget.
type AttemptEngine =
  -- | the attempt number (scripted engines key demos on it)
  Int ->
  -- | the whole-file fixer program (the whole-file engines run it)
  Program DiagnosticsIn RepairOut ->
  -- | the task, as the decision step saw it
  DiagnosticsIn ->
  -- | the recalled campaign lessons for this attempt
  [Text] ->
  IO (Maybe Source)

-- | An engine /factory/: the honest type for a fleet. A rebuilt workflow body
-- knows which oracle (and cell) it serves; the caller supplies /how attempts
-- run given that task/.
type EngineFor = CellOracle -> Cell -> AttemptEngine

-- | The stub engine: the workflow's original interpreter, kept as an engine so
-- the offline acts and the live acts are the same code with a different
-- bottom. The scripted responder is keyed by attempt number; the recalled
-- lessons already ride the rendered request (folded into the instruction),
-- exactly as a live model would see them.
stubEngine :: (Int -> Context -> Response) -> AttemptEngine
stubEngine responder n prog input _notes = do
  r <- runStubEval (responder n) (runProgram prog input)
  pure $ case r of
    Right (RepairOut (Field txt)) -> Just (Source txt)
    Left (_ :: ShikumiError) -> Nothing

-- | The fixer program with the campaign's recalled lessons folded into its
-- instruction — /memory steers the prompt/ — while the wire shape (diagnostics
-- in, whole repaired file out) and the no-regression guard stay untouched.
-- With no lessons this is exactly 'fixSource'; either way the guard is
-- composed back on, so invented lines are typed errors under every engine.
guidedFixer :: Source -> [Text] -> Maybe (Int, Text) -> Program DiagnosticsIn RepairOut
guidedFixer orig notes mRewrite =
  predict (liveInstruction orig notes mRewrite)
    >>> embed
      ( \out -> case mRewrite of
          -- The canonical rewrite's line does not exist in the original, so
          -- the subsequence check would reject it sight unseen; when a
          -- rewrite is admissible the campaign guard ('surgicalRepair')
          -- owns admissibility entirely — it admits exactly the canonical
          -- rewrite or pure deletions of droppable lines, which is a
          -- strictly tighter floor than the subsequence check.
          Just _ -> pure out
          Nothing -> either throwError (\_ -> pure out) (applyRepair orig out)
      )

-- | 'repairSignature' with the file content and the recalled lessons folded
-- into its instruction. A live model must /see the file/ to repair it — the
-- stub engines never needed this (they are scripted per cell), but a real
-- model asked to "return the complete repaired file" while blind to the file
-- can only hallucinate. The worked demo pins the wire contract: whole file
-- back, edits confined to the flagged lines — delete fully-flagged import
-- statements; rewrite a partially-used one to keep exactly its used names
-- (the rewrite line is given verbatim; inventing formatting is not a
-- repair). A live run demonstrated why the prose alone is not enough: the
-- model once wiped the file and obeyed the letter of the deletions rule.
liveInstruction :: Source -> [Text] -> Maybe (Int, Text) -> Signature DiagnosticsIn RepairOut
liveInstruction orig notes mRewrite =
  setDemos [example] $
    setInstruction
      ( getInstruction repairSignature
          <> "\n\nThe current content of the file being fixed:\n"
          <> sourceText orig
          <> "\nReply with the repaired field holding the complete file after "
          <> "deleting exactly the flagged lines and nothing else"
          <> rewriteClause
          <> ". No commentary, no fences — the field is the file."
          <> (if null notes then "" else "\n\nLessons learned earlier in this campaign (obey them):\n" <> T.unlines (map ("- " <>) notes))
      )
      repairSignature
  where
    rewriteClause = case mRewrite of
      Nothing -> ""
      Just (ln, txt) ->
        ", except that line " <> T.pack (show ln)
          <> " must read exactly: " <> txt
    example =
      Demo
        ( DiagnosticsIn
            (Field "widget.py")
            (Field ["W-unused-import unused import 'os' at line 2"])
        )
        (RepairOut (Field "import sys\n\n\ndef size(w):\n    return len(w)\n"))

-- | Publish a human query's awakeable id to the outside world. Must be
-- idempotent: like jitsurei's webhook publisher, its action has
-- at-least-once execution across the action-to-journal crash window.
type HumanQueryPublisher es = AwakeableId -> Eff es ()

-- | The demo's typed attempt budget.
defaultMaxAttempts :: Int
defaultMaxAttempts = 3

-- ---------------------------------------------------------------------------
-- The decision step: run the shikumi fixer under the supplied engine
-- ---------------------------------------------------------------------------

-- | Run one LM fix attempt against a cell, with recalled memory as extra
-- guidance. Step actions get full IOE, so the stub-or-live engine stack runs
-- right here. The program is 'guidedFixer' — the original bound in as the
-- guard's ground truth, the lessons folded into the instruction — and the
-- engine supplies the model behind it. Returns the repaired source when the
-- proposal passed both the no-regression guard and the surgical guard; the
-- first failed attempt (live run 22d) was a whole-file wipe — a valid
-- subsequence the deletion-only guard waved through — so the campaign layer
-- adds the diagnosis-coupled constraint before anything reaches a journal.
runFixAttempt ::
  (IOE :> es) =>
  AttemptEngine ->
  Source ->
  -- | the cell's repair contract, as data
  RepairRules ->
  -- | the cell's path — the syntax check reports against it
  SourcePath ->
  DiagnosticsIn ->
  [Text] ->
  Int ->
  Eff es (Maybe Source)
runFixAttempt engine orig rules path input notes n = go notes (0 :: Int)
  where
    -- The taught retry: a guard rejection is fed back as an extra lesson
    -- ("obey them" — 'guidedFixer' folds notes into the instruction), so the
    -- next engine call tells the model what it did wrong. The engine's own
    -- inner retries stay blind, as they must: they guard the wire shape and
    -- the subsequence check inside the program, which see no oracle. Two
    -- guards feed back: the surgical guard (deletions outside the flagged
    -- statements, or a non-canonical rewrite) and the syntax floor
    -- ('pythonSyntaxCheck' — a partial deletion can leave the file
    -- unparseable, which the AST-free oracle cannot see).
    go ns k
      | k >= 3 = pure Nothing
      | otherwise = do
          m <- liftIO (engine n (guidedFixer orig ns (rrRewrite rules)) input ns)
          case m of
            Nothing -> pure Nothing
            Just rep -> case surgicalRepair orig rules rep of
              Left err -> retryWith ns k (surgicalMsg err)
              Right _ -> do
                mSyn <- liftIO (pythonSyntaxCheck path rep)
                case mSyn of
                  Nothing -> pure (Just rep)
                  Just syn -> retryWith ns k ("your previous reply does not parse as Python — " <> syn)
    retryWith ns k why = do
      liftIO $ putStrLn "    [guard] rejection — fed back as a lesson"
      go
        ( ns
            <> [ "Your previous reply was rejected: " <> why
                   <> " Return the complete file with ONLY the flagged import statements removed (rewriting a partially-used statement to keep its used names is allowed)."
               ]
        )
        (k + 1)
    surgicalMsg err = case err of
      ValidationFailure t -> t
      _ -> T.pack (show err)

-- | The surgical guard, as two admissible paths over the cell's repair
-- contract ('RepairRules', computed by 'repairRulesFor' from the same
-- parser the oracle flags with):
--
--   1. /Pure deletion/ — every deleted line is a droppable line (a
--      fully-flagged import statement, whole; or a non-import flagged line,
--      the toy-marker cells' contract) or a blank line; deletions are
--      recovered by aligning the repair against the original (the
--      subsequence guard already ran, so the alignment is exact). The
--      partially-used statement's span is /not/ droppable — deleting it
--      whole would silently remove used names.
--   2. /Canonical rewrite/ — when the cell has a partially-used statement,
--      the repair may equal the original with that statement's span
--      replaced by the contract's exact rewrite line and the droppable
--      lines deleted. Nothing else may differ, so the "rewrite" cannot
--      smuggle in reformatting or invented code.
--
-- A repair following neither path is rejected: the unused-import oracle
-- cannot see a missing function, so a degenerate "repair" that gutted the
-- file would otherwise clear.
surgicalRepair :: Source -> RepairRules -> Source -> Either ShikumiError Source
surgicalRepair orig rules (Source new)
  | null (rrDroppableLines rules) && rrRewrite rules == Nothing = Right (Source new)
  | Just ds <- alignment, all allowed ds, not keptLineDeleted = Right (Source new)
  | otherwise =
      Left
        ( ValidationFailure
            "the repair is not the contract's minimal edit: delete only the \
            \flagged lines the contract marks droppable, or replace a \
            \partially-used import with exactly the prescribed kept-name line"
        )
  where
    RepairRules {rrDroppableLines = droppable, rrRewrite = mRewrite} = rules
    origLines = T.lines (sourceText orig)
    newLines = T.lines new
    -- Align the repair against the original. A mismatched original line is
    -- a /deletion/ — unless it is the rewrite target and the repair's next
    -- line is exactly the canonical text, which is the admissible
    -- /replacement/. Repair lines left unconsumed are invented content:
    -- alignment fails outright (Nothing), which is what makes the rewrite
    -- path strict — the model cannot smuggle edits past the one permitted
    -- replacement.
    alignment :: Maybe [Int]
    alignment = go 1 origLines newLines
      where
        go _ [] ys = if null ys then Just [] else Nothing
        -- The repair ended early: every remaining original line is a
        -- deletion (the missing clause once crashed a live drive round).
        go n (x : xs) [] = (n :) <$> go (n + 1) xs []
        go n (x : xs) (y : ys)
          | x == y = go (n + 1) xs ys
          | Just (rn, txt) <- mRewrite, n == rn, y == txt = go (n + 1) xs ys
          | otherwise = (n :) <$> go (n + 1) xs (y : ys)
    allowed n = n `elem` droppable || T.null (T.strip (origLines !! (n - 1)))
    -- The rewrite target's line must survive as itself or as the canonical
    -- replacement (alignment consumes it one way or the other); a repair
    -- that deletes it whole silently removes the used names.
    keptLineDeleted = case mRewrite of
      Just (rn, _) -> maybe True (rn `elem`) alignment
      Nothing -> False

-- | One attempt, as a step action: recall lessons (a kioku read, journaled
-- into the record — replay never re-recalls), run the engine, apply the guard.
-- The oracle decides the diagnostics, the original, and hence the program.
attemptRecord ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es) =>
  Cell ->
  CellOracle ->
  Namespace ->
  AttemptEngine ->
  Int ->
  Eff es FixAttempt
attemptRecord cell oracle ns engine n = do
  let orig = oracleOriginal oracle (cellPath cell) (cellCurrent cell)
      beforeDiags = oracleCheck oracle (cellPath cell) (cellCurrent cell)
      before = map showDiagnostic beforeDiags
      -- The repair contract, as data: droppable lines and the canonical
      -- rewrite for a partially-used statement — computed from the same
      -- parser the oracle flags with.
      rules = repairRulesFor orig (map diagLine beforeDiags)
      -- The keywords the diagnostics themselves suggest: the memory consulted
      -- is a function of the task, not of the caller.
      diagKws = concat [keywordsOf d | d <- before]
  notes <- if null diagKws then pure [] else concat <$> mapM (recallNotesForKeyword ns) diagKws
  let input =
        DiagnosticsIn
          (Field (cellPath cell))
          (Field before)
  mRepaired <- runFixAttempt engine orig rules (cellPath cell) input notes n
  case mRepaired of
    Nothing ->
      pure
        FixAttempt
          { faAttempt = n,
            faSucceeded = False,
            faDiagnosticsBefore = before,
            faDiagnosticsAfter = before,
            faRecallNotes = notes,
            faRepaired = Nothing
          }
    Just repaired -> do
      let after = map showDiagnostic (oracleCheck oracle (cellPath cell) repaired)
          ok = null after
      pure
        FixAttempt
          { faAttempt = n,
            faSucceeded = ok,
            faDiagnosticsBefore = before,
            faDiagnosticsAfter = after,
            faRecallNotes = notes,
            faRepaired = Just (sourceText repaired)
          }
  where
    -- Diagnostic-kind keywords to recall lessons for. The oracles' codes are
    -- the vocabulary; a real campaign would map its own diagnostics.
    keywordsOf d
      | "W-todo" `T.isInfixOf` d = ["todo"]
      | "W-unused-import" `T.isInfixOf` d = ["unused", "import"]
      | "W-unused" `T.isInfixOf` d = ["unused"]
      | otherwise = []

-- ---------------------------------------------------------------------------
-- The workflow
-- ---------------------------------------------------------------------------

-- | Pacing between attempts. A real campaign's inter-attempt delay is the
-- build/boot itself; the journal semantics are identical.
interAttemptDelay :: NominalDiffTime
interAttemptDelay = 1

-- | The one-cell campaign. @maxAttempts@ is the typed attempt budget; the
-- responder supplies the "model"; the publisher hands human-query ids to the
-- outside world; the oracle owns ground truth; @ns@ is the project's memory
-- namespace. The final result is a verdict line.
cellCampaignWorkflow ::
  (Workflow :> es, KirokuStoreResource :> es, Store :> es, IOE :> es) =>
  AttemptEngine ->
  HumanQueryPublisher es ->
  Cell ->
  CellOracle ->
  Namespace ->
  Int ->
  Eff es Text
cellCampaignWorkflow engine publishHumanQuery cell oracle ns maxAttempts = do
  -- 1) Journal the oracle's initial verdict for the cell as received.
  _initial <- step (StepName "verify-initial") (pure initialDiags)
  if null initialDiags
    then pure "passed: cell was already clean"
    else go 1
  where
    initialDiags = map showDiagnostic (oracleCheck oracle (cellPath cell) (cellCurrent cell))
    go n
      | n > maxAttempts = budgetExhausted
      | otherwise = do
          -- 2) One durable LM attempt, journaled with its repair...
          attempt <-
            step (StepName ("propose-fix-" <> T.pack (show n))) (attemptRecord cell oracle ns engine n)
          -- 3) ...paced by a durable timer...
          sleepNamed (StepName ("settle-" <> T.pack (show n))) interAttemptDelay
          -- 4) ...then the oracle decides: done, or another attempt.
          if faSucceeded attempt && null (faDiagnosticsAfter attempt)
            then pure ("passed: fix attempt " <> T.pack (show n) <> " cleared the cell")
            else go (n + 1)

    -- Budget exhausted, cell still failing: park on the human seam.
    budgetExhausted = do
      (awakeableId, awaitVerdict) <- awakeableNamed humanQueryStepName
      _publication <-
        step (StepName "publish-human-query") (publishHumanQuery awakeableId)
      verdict <- awaitVerdict
      case verdict of
        VerdictApproved -> pure "human-approved: cell remains failing; verdict recorded"
        VerdictRejected -> pure "human-rejected: cell remains failing; verdict recorded"

-- ---------------------------------------------------------------------------
-- The registry
-- ---------------------------------------------------------------------------

-- | The application-supplied registry the resume worker re-invokes through.
-- Two workflow names: the toy corpus's cells (marker oracle, @toy@ namespace)
-- and the real project cells (unused-import oracle, per-project namespace).
-- The project cells are supplied at construction; both rebuild bodies from
-- the id alone.
campaignRegistry ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es) =>
  -- | the real project cells, read from the checkouts
  [ProjectCell] ->
  -- | extra toy cells beyond the corpus (the live acts' @live:@-prefixed
  -- instances of the same corpus)
  [Cell] ->
  -- | how attempts run given a task (oracle + cell): a stub factory or a
  -- live engine that ignores both (the program carries the task)
  EngineFor ->
  HumanQueryPublisher es ->
  WorkflowRegistry es
campaignRegistry projectCells extraCells engine publishHumanQuery =
  Map.fromList
    [ ( cellCampaignWorkflowName,
        WorkflowDef $ \wid ->
          case lookupCell (campaignIdFromWf wid) of
            Nothing -> error ("campaignRegistry: unknown cell " <> T.unpack (unCellId (campaignIdFromWf wid)))
            Just cell ->
              cellCampaignWorkflow
                (engine markerOracle cell)
                (raise . publishHumanQuery)
                cell
                markerOracle
                campaignNamespace
                defaultMaxAttempts
      ),
      ( projectCampaignWorkflowName,
        WorkflowDef $ \wid ->
          case projectCellFromWf wid of
            Nothing -> error ("campaignRegistry: malformed project workflow id")
            Just (proj, path) ->
              case find (\pc -> pcProject pc == proj && pcPath pc == path) projectCells of
                Nothing -> error ("campaignRegistry: unknown project cell " <> T.unpack (proj <> ":" <> path))
                Just pc ->
                  let pcell =
                        Cell
                          { cellId = CellId (proj <> ":" <> pcPath pc),
                            cellPath = pcPath pc,
                            cellOriginal = pcSource pc,
                            cellCurrent = pcSource pc
                          }
                   in cellCampaignWorkflow
                        (engine unusedImportOracle pcell)
                        (raise . publishHumanQuery)
                        pcell
                        unusedImportOracle
                        (projectNamespaceSafe proj)
                        defaultMaxAttempts
      )
    ]
  where
    -- Corpus cells by id, plus the caller's extra cells (the live acts run
    -- the same corpus under a @live:@ journal prefix — same bytes, fresh
    -- campaign, no replay collision with the offline acts).
    lookupCell cid = cellForId cid <|> find ((== unCellId cid) . unCellId . cellId) extraCells
