{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The ReAct fixer: the same campaign cell, fixed by an agent with tools.
--
-- The whole-file fixer asks the model for the complete repaired file and
-- guards the reply. The ReAct fixer instead gives the model /hands/ — typed
-- tools over one file — and lets it work:
--
--   * @read_file@         — see the file, lines numbered from 1.
--   * @delete_lines@      — remove lines by number. This is the /only/
--                           mutation tool, so the campaign's delete-only
--                           policy is structural: there is nothing else the
--                           agent /can/ do. (The whole-file fixer had to
--                           check this after the fact with a guard.)
--   * @check_diagnostics@ — re-run the real oracle on the current state; the
--                           agent consults the checker mid-loop instead of
--                           being told the verdict only at the end.
--
-- The loop is shikumi's 'reactWithTrajectory' — an ordinary inspectable
-- @Program@ — with a final typed extract ('FixDone'). The engine decides
-- success by running the checker on the resulting state; the model's own
-- @done@ claim is recorded in the trajectory, never trusted.
--
-- Tool bodies run in shikumi's @(LLM, Error ShikumiError)@ row — no IO — but
-- the world here is one file's bytes, which live in a closed-over 'IORef'
-- mutated through 'unsafeEff_' (IO genuinely runs beneath 'runEff'; the row
-- just doesn't name it). The parent checkout is never touched: like act 11,
-- the world is a captured 'Source', and landing the result remains
-- Campaign.Landing's job.
module Campaign.ReactFixer
  ( -- * The agent's task and result
    FixTask (..),
    FixDone (..),

    -- * The world and the program
    WorkEnv (..),
    reactFixer,

    -- * Engines
    scriptedReactEngine,
    reactEngineFor,

    -- * Trajectory reporting
    renderSteps,
  )
where

import Data.Aeson (ToJSON)
import Control.Monad (when)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (nub, sort)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Vector qualified as V
import Effectful (Eff)
import Effectful.Internal.Monad (unsafeEff)
import GHC.Generics (Generic)

import Shikumi.Agent.ReAct
  ( Action (..),
    ReActConfig (..),
    Step (..),
    ToolProtocol (..),
    Trajectory (..),
    defaultReActConfig,
    reactWithTrajectory,
  )
import Shikumi.Error (ShikumiError)
import Shikumi.Schema (FromModel, ToSchema, Validatable)
import Shikumi.Schema.Types (Field (..))
import Shikumi.Signature (Signature, mkSignature, setInstruction)
import Shikumi.Adapter (ToPrompt)
import Shikumi.Program (Program)
import Shikumi.Testing (mkTextResponse, runAgent)
import Shikumi.Tool (SomeTool (..), Tool, ToolRegistry, mkRegistry, mkTool)

import Kioku.AI.Config (AIFeature (..))
import Kioku.AI.Runtime (AIRuntime, runAIProgram)

import Campaign.Cell (Cell (..), unCellId)
import Campaign.Oracle (CellOracle (..))
import Campaign.Workflow (AttemptEngine)
import Toy.Fixer.Domain (Diagnostic (..), Source (..), SourcePath, showDiagnostic, sourceText)
import Toy.Fixer.Program (DiagnosticsIn (..), RepairOut)

-- ---------------------------------------------------------------------------
-- Task in, typed report out
-- ---------------------------------------------------------------------------

-- | One fixing task: the file (identified and captured as bytes — never read
-- from disk here), the oracle's diagnostics, and which project it belongs to.
data FixTask = FixTask
  { ftProject :: !Text,
    ftPath :: !SourcePath,
    ftContent :: !Text,
    ftDiagnostics :: !Text
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ToPrompt)

-- | The agent's final typed report. @fdDone@ is the /model's/ claim; the
-- engine re-checks the state itself and never trusts it.
data FixDone = FixDone
  { fdSummary :: !(Field "one sentence: what you deleted and why" Text),
    fdDone :: !(Field "true when you believe every diagnostic is cleared" Bool)
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ToSchema, FromModel, ToPrompt, Validatable)

-- ---------------------------------------------------------------------------
-- The world: one file's lines in an IORef, plus the real checker
-- ---------------------------------------------------------------------------

-- | Everything a tool needs: the mutable world (the file's current lines)
-- and the immutable ground truth (the oracle, bound to this cell's path).
-- Constructed per attempt by the engines below.
data WorkEnv = WorkEnv
  { weState :: !(IORef [Text]),
    weCheck :: !([Text] -> [Diagnostic]),
    weNotes :: ![Text]
  }

-- | The signature: the campaign lessons ride the instruction, exactly like
-- the whole-file fixer's instruction folds them in.
fixSignature :: WorkEnv -> Signature FixTask FixDone
fixSignature env =
  setInstruction
    ( T.unlines
        [ "You are fixing one file of a research codebase, working with tools.",
          "The diagnostics flag lines to remove. Work like this: read_file to",
          "see the file with numbered lines; delete_lines to remove exactly the",
          "flagged lines (deletion is the ONLY change you can make, by design);",
          "check_diagnostics to re-run the checker; then finish with a one-",
          "sentence report. Never rewrite or reformat code — this campaign's",
          "repairs are delete-only, and the checker has the final word.",
          if null (weNotes env)
            then ""
            else
              "\nLessons learned earlier in this campaign (obey them):\n"
                <> T.unlines (map ("- " <>) (weNotes env))
        ]
    )
    fixSig
  where
    fixSig :: Signature FixTask FixDone
    fixSig = mkSignature "Fix the file using the tools until the diagnostics are cleared, then finish."

-- ---------------------------------------------------------------------------
-- The typed tools
-- ---------------------------------------------------------------------------

-- | Tool outputs are plain records (compact-JSON observation text); 'Field'
-- is a prompt/schema annotation, not an observation annotation.
data ReadFileOut = ReadFileOut
  { rfoContent :: !Text
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ToJSON)

data CheckArgs = CheckArgs
  { caPath :: !Text
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ToSchema, FromModel)

instance Validatable CheckArgs

data CheckOut = CheckOut
  { coClean :: !Bool,
    coDiagnostics :: ![Text]
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ToJSON)

data DeleteLinesArgs = DeleteLinesArgs
  { dlaLineNumbers :: !(Field "1-based line numbers to delete" [Int])
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ToSchema, FromModel)

instance Validatable DeleteLinesArgs

data DeleteLinesOut = DeleteLinesOut
  { dloDeleted :: ![Text],
    dloRejected :: ![Text],
    dloRemaining :: !Int
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ToJSON)

data ReadFileArgs = ReadFileArgs
  { rfaPath :: !Text
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ToSchema, FromModel)

instance Validatable ReadFileArgs

-- | The numbered rendering the agent sees.
numbered :: [Text] -> Text
numbered ls = T.unlines [T.pack (show n) <> ": " <> l | (n, l) <- zip [1 :: Int ..] ls]

-- | The three tools over one 'WorkEnv'. Bodies run through 'unsafeEff'
-- (the IO-capable primitive beneath every effectful stack) because the world
-- is a plain 'IORef'; the checks are the same pure oracle the whole-file
-- campaign used.
reactToolsFor :: WorkEnv -> ToolRegistry
reactToolsFor env =
  mkRegistry
    [ SomeTool readFileTool,
      SomeTool deleteLinesTool,
      SomeTool checkTool
    ]
  where
    readFileTool :: Tool ReadFileArgs ReadFileOut
    readFileTool =
      mkTool
        "read_file"
        "Read the task's file, with 1-based line numbers."
        $ \ReadFileArgs {} ->
          unsafeEff $ \_k -> do
            ls <- readIORef (weState env)
            pure (ReadFileOut (numbered ls))

    deleteLinesTool :: Tool DeleteLinesArgs DeleteLinesOut
    deleteLinesTool =
      mkTool
        "delete_lines"
        "Delete the given 1-based lines. Deletion is the only mutation available."
        $ \(DeleteLinesArgs (Field nums)) ->
          unsafeEff $ \_k -> do
            ls0 <- readIORef (weState env)
            let n = length ls0
                wanted = reverse . sort . nub $ nums
                (ok, bad) = partition wanted
                partition [] = ([], [])
                partition (k : ks)
                  | k >= 1 && k <= n = prependOk k (partition ks)
                  | otherwise = prependBad k (partition ks)
                prependOk k (oks, bads) = (k : oks, bads)
                prependBad k (oks, bads) =
                  (oks, ("out of range 1.." <> T.pack (show n) <> ": " <> T.pack (show k)) : bads)
                deleteAt k xs = take (k - 1) xs <> drop k xs
                ls1 = foldl (flip deleteAt) ls0 ok
                deletedDesc = [T.pack (show k) <> ": " <> (ls0 !! (k - 1)) | k <- ok]
            modifyIORef' (weState env) (const ls1)
            let remaining = length (weCheck env ls1)
            pure (DeleteLinesOut deletedDesc bad remaining)

    checkTool :: Tool CheckArgs CheckOut
    checkTool =
      mkTool
        "check_diagnostics"
        "Re-run the diagnostics checker on the file's current state."
        $ \CheckArgs {} ->
          unsafeEff $ \_k -> do
            ls <- readIORef (weState env)
            let diags = map showDiagnostic (weCheck env ls)
            pure (CheckOut (null diags) diags)

-- ---------------------------------------------------------------------------
-- The program
-- ---------------------------------------------------------------------------

-- | The ReAct fixer as an ordinary shikumi @Program@. The live run uses the
-- prompt protocol: these free-tier models' native tool-calling is unreliable
-- (empty assistant replies), while the explicit action grammar survives.
reactFixer :: WorkEnv -> Program FixTask (FixDone, Trajectory)
reactFixer env =
  reactWithTrajectory
    (fixSignature env)
    (reactToolsFor env)
    defaultReActConfig {maxIters = 8, protocol = ProtocolPrompt}

-- | One-line renderings of a trajectory's steps, for the driver's log.
renderSteps :: Trajectory -> [Text]
renderSteps traj =
  [ renderStep s
  | s <- V.toList (steps traj)
  ]
  where
    renderStep s =
      "  - "
        <> (case action s of
              CallTool nm _ -> "call " <> nm
              Finish -> "finish"
              _ -> "summary")
        <> maybe "" (\o -> " -> " <> T.take 200 o) (observation s)

-- ---------------------------------------------------------------------------
-- The shared runner: one agent attempt over one captured world
-- ---------------------------------------------------------------------------

-- | Run one agent attempt against a one-shot runner (script or live model),
-- then decide success the honest way: the real oracle on the final world.
-- Returns the repaired source when the checker is satisfied.
runReactAttempt ::
  -- | run the agent program on the task (Nothing = typed failure)
  (Program FixTask (FixDone, Trajectory) -> FixTask -> IO (Maybe (FixDone, Trajectory))) ->
  CellOracle ->
  Cell ->
  [Text] ->
  -- | the diagnostics the decision step saw (drive the scripted policy)
  [Text] ->
  IO (Maybe Source)
runReactAttempt runAgentAttempt oracle cell notes diags = do
  let orig = oracleOriginal oracle (cellPath cell) (cellCurrent cell)
  ref <- newIORef (T.lines (sourceText orig))
  let env =
        WorkEnv
          { weState = ref,
            weCheck = \ls -> oracleCheck oracle (cellPath cell) (Source (T.unlines ls)),
            weNotes = notes
          }
      task =
        FixTask
          { ftProject = unCellId (cellId cell),
            ftPath = cellPath cell,
            ftContent = sourceText orig,
            ftDiagnostics = T.unlines diags
          }
  mResult <- runAgentAttempt (reactFixer env) task
  case mResult of
    Nothing -> pure Nothing
    Just (done, traj) -> do
      putStrLn ("    [react] model claims " <> (if unFieldB done.fdDone then "done" else "not-done") <> "; steps:")
      mapM_ (putStrLn . T.unpack) (renderSteps traj)
      ls <- readIORef ref
      let final = Source (T.unlines ls)
          stillBad = oracleCheck oracle (cellPath cell) final
          -- The minimality contract, enforced as data: the final state must
          -- be exactly the original minus the flagged lines. A live agent
          -- that deletes extra "helpful" lines along with the flagged one
          -- fails this check even though the checker is clean — the campaign
          -- repairs are minimal by definition, not merely clean.
          origLines = T.lines (sourceText orig)
          expected = foldl (flip deleteAtLine) origLines (flaggedLines diags)
          minimal = ls == expected
      if null stillBad && minimal
        then pure (Just final)
        else do
          when (null stillBad && not minimal) $
            putStrLn
              ( "    [react] checker clean but the diff is not minimal — rejected"
                  <> " (deleted lines must be exactly the flagged ones: "
                  <> show (flaggedLines diags) <> ")"
              )
          pure Nothing
  where
    unFieldB (Field b) = b
    deleteAtLine k xs = take (k - 1) xs <> drop k xs

-- | The flagged 1-based line numbers, parsed from the oracle's own rendered
-- diagnostics (@path:LINE: warning: [code] message@) — the scripted policy
-- derives its move from the task, exactly like the live model must.
flaggedLines :: [Text] -> [Int]
flaggedLines = mapMaybe' lineOf
  where
    mapMaybe' f xs = [y | Just y <- f <$> xs]
    lineOf d = case T.splitOn ":" d of
      (_ : n : _) -> readMaybeInt (T.strip n)
      _ -> Nothing
    readMaybeInt t = case reads (T.unpack t) of
      [(n, "")] -> Just n
      _ -> Nothing

-- | The scripted ReAct engine: a deterministic model that works exactly like
-- the campaign wants — read, delete the flagged lines, check, finish — by
-- reading the rendered request (the loop's user message carries the task and
-- the accumulated history). Offline, journaled, and honest about the loop's
-- shape: five turns, one trajectory.
scriptedReactEngine :: CellOracle -> Cell -> AttemptEngine
scriptedReactEngine oracle cell _n _wholeFileProg (DiagnosticsIn _ (Field diags)) notes =
  runReactAttempt runAttempt oracle cell notes (map (T.takeWhile (/= '\n')) diags)
  where
    flagged = flaggedLines (map (T.takeWhile (/= '\n')) diags)
    runAttempt :: Program FixTask (FixDone, Trajectory) -> FixTask -> IO (Maybe (FixDone, Trajectory))
    runAttempt prog task = do
      let script =
            [ -- 1: see the file
              mkTextResponse "{\"thought\": \"Read the file to locate the flagged lines.\", \"action\": {\"tool\": \"read_file\", \"args\": {\"rfaPath\": \"the task's file\"}}}",
              -- 2: delete exactly the flagged lines (the only mutation there is)
              mkTextResponse
                ( "{\"thought\": \"Delete exactly the flagged lines.\", \"action\": {\"tool\": \"delete_lines\", \"args\": {\"dlaLineNumbers\": "
                    <> tshow flagged
                    <> "}}}"
                ),
              -- 3: consult the checker mid-loop
              mkTextResponse "{\"thought\": \"Verify the deletion cleared every diagnostic.\", \"action\": {\"tool\": \"check_diagnostics\", \"args\": {\"caPath\": \"the task's file\"}}}",
              -- 4: finish
              mkTextResponse "{\"thought\": \"The checker is satisfied.\", \"action\": {\"finish\": true}}",
              -- 5: the typed extract
              mkTextResponse
                ( "{\"fdSummary\": \"deleted the flagged lines "
                    <> tshow flagged
                    <> " from "
                    <> ftPath task
                    <> "\", \"fdDone\": true}"
                )
            ]
      runAgent script prog task >>= eitherToMaybe
    tshow = T.pack . show
    eitherToMaybe ::
      Either ShikumiError (FixDone, Trajectory) ->
      IO (Maybe (FixDone, Trajectory))
    eitherToMaybe (Left e) = Nothing <$ putStrLn ("    [react] typed error: " <> show e)
    eitherToMaybe (Right r) = pure (Just r)

-- | The live ReAct engine: the same agent program through kioku's
-- 'runAIProgram' — the sanctioned live seam — with the tier-1 bounded retry.
reactEngineFor :: AIRuntime -> CellOracle -> Cell -> AttemptEngine
reactEngineFor air oracle cell _n _wholeFileProg (DiagnosticsIn _ (Field diags)) notes =
  runReactAttempt runAttempt oracle cell notes (map (T.takeWhile (/= '\n')) diags)
  where
    runAttempt prog task = do
      let once =
            runAIProgram air Extraction prog task >>= \case
              Right r -> pure (Just r)
              Left err -> Nothing <$ putStrLn ("    [react] typed error: " <> show err)
          go 0 = once
          go k =
            once >>= \case
              Nothing -> go (k - 1)
              ok -> pure ok
      go (3 :: Int)
