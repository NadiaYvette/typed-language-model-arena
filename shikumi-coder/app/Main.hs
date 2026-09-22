{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | AI codegen over a real codebase, driven by shikumi.
--
-- The worked task is a real Mercury compiler change: the private
-- @--dump-mlds@ option (currently registered with @priv_alt_arg_help@ in
-- compiler\/options.m) promoted to the public @alt_arg_help@ constructor —
-- the established registration for dump options, per the project goal that
-- IR dumps of any stage be selectable by plain command-line options with no
-- special compiler build.
--
-- The fixture (the relevant options.m region at master) is embedded, so the
-- demo runs anywhere. Acts, all offline unless @SHIKUMI_LIVE=1@:
--
--   0. fixture self-check: the exact-match guards' precondition;
--   1. the task and its deterministic fact (what the model is shown);
--   2. the full pipeline under a scripted model: propose -> guard -> apply,
--      printed as a diff and verified against the hand-written expected file;
--   3. a sabotaged edit (mangled indentation): the exact-once guard rejects
--      it with a typed error — nothing is applied;
--   4. informed retry: the first scripted turn fails the guard, the corrected
--      second turn lands — @retry 3@ driving;
--   5. the evaluation seam: the task as a one-example dataset with a
--      file-equality metric, rendered through the standard report;
--   6. @SHIKUMI_LIVE=1@: the same program value against the real provider
--      (OmniRoute), dry-run — the diff is printed, nothing is written.
module Main (main) where

import Baikai
  ( Api (OpenAIChatCompletions),
    ApiKeySource (ApiKeyEnv),
    Model (..),
    Options (..),
    Response,
    emptyOptions,
    globalProviderRegistry,
    mkModel,
  )
import Baikai.Provider.OpenAI.Api qualified as OpenAI
import Control.Monad (unless)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Effectful (Eff, IOE, runEff)
import Effectful.Concurrent (Concurrent, runConcurrent)
import Effectful.Error.Static (Error, runErrorNoCallStack)
import Effectful.Prim (Prim, runPrim)
import Shikumi.Coder.Pipeline (PatchResult (..), ProposeIn (..), coder, coderOnce)
import Shikumi.Coder.Task
  ( CodeFact (..),
    CodeTask (..),
    PatchPlan (..),
    codeFactLines,
    occurrences,
    sourceDiff,
  )
import Shikumi.Effect.Time (Time, runTime)
import Shikumi.Error (ShikumiError)
import Shikumi.Eval
  ( Dataset,
    EvalConfig (concurrency),
    Metric,
    boolScore,
    customMetric,
    dataset,
    defaultEvalConfig,
    evaluateWith,
    example,
    liftMetric,
    predictionPrimary,
    renderReportText,
  )
import Shikumi.LLM (LLM, defaultLLMConfig, runLLMResilient)
import Shikumi.LLM.Defaults (RequestDefaults (defaultMaxTokens), emptyRequestDefaults, withRequestDefaults)
import Shikumi.Program (Program, embed, runProgram)
import Shikumi.Routing (routeLLM, runRouting)
import Shikumi.Schema.Types (Field (..), unField)
import Shikumi.Testing (markerResponse, runStubEval)
import Shikumi.Testing.Responses (withTransportOptions)
import Shikumi.Testing.StubLLM (runScriptLLM)
import System.Environment (lookupEnv)

-- ---------------------------------------------------------------------------
-- The fixture: the relevant region of compiler/options.m (from the real
-- worktree at master), embedded so the demo runs anywhere.
-- ---------------------------------------------------------------------------

factLineNo :: Int
factLineNo = 6015

-- | The exact line the task targets.
factLine :: Text
factLine = "    priv_alt_arg_help(\"dump-mlds\", [\"mlds-dump\"], \"stage number or name\", ["

-- | The hand-written expected outcome: the same line, public constructor.
expectedLine :: Text
expectedLine = "    alt_arg_help(\"dump-mlds\", [\"mlds-dump\"], \"stage number or name\", ["

-- | The embedded fixture region of compiler\/options.m.
fixtureOptionsM :: Text
fixtureOptionsM =
  T.unlines
    [ "    help(\"dump-same-hlds\", [",
      "        w(\"Create a file for a HLDS stage even if the file notes only that\"),",
      "        w(\"this stage is identical to the previously dumped HLDS stage.\")])).",
      "optdb(oc_dev_dump,  dump_mlds,                         accumulating([]),",
      factLine,
      "        w(\"Dump the MLDS (medium level intermediate representation)\"),",
      "        w(\"after the specified stage, as C code, to\"),",
      "        help_text_texinfo(",
      "            [quote(\"<module>.c_dump.<num>-<name>\"), w(\"and\"),",
      "            quote(\"<module>.mih_dump.<num>-<name>\", \".\")],",
      "            [fixed(\"@samp{module}.c_dump.@samp{num}-@samp{name}\"), w(\"and\"),",
      "            fixed(\"@samp{module}.mih_dump.@samp{num}-@samp{name}.\")]),",
      "        w(\"Stage numbers range from 1-99.\"),",
      "        w(\"Multiple dump options accumulate.\"),",
      "        w(\"This option works only in MLDS grades that target C.\"]))."
    ]

-- | The expected file after the correct edit.
expectedFile :: Text
expectedFile = T.unlines (map promote (T.lines fixtureOptionsM))
  where
    promote l = if l == factLine then expectedLine else l

-- ---------------------------------------------------------------------------
-- The task and the pipeline input
-- ---------------------------------------------------------------------------

dumpMldsTask :: CodeTask
dumpMldsTask =
  mkTask
    "compiler/options.m"
    "Promote the private --dump-mlds option to a public one"
    ( T.unlines
        [ "The project goal is that IR dumps of any stage be selectable by plain",
          "command-line options, with no special compiler build required. The",
          "--dump-mlds option is currently registered with the private",
          "priv_alt_arg_help constructor (hidden from --help and the reference",
          "manual); the public alt_arg_help constructor is used by 63 other",
          "options, including --dump-hlds, so promoting this line is the",
          "established, minimal change."
        ]
    )
    ( CodeFact
        { factPath = "compiler/options.m",
          factPattern = "priv_alt_arg_help(\"dump-mlds\"",
          factMatches = [(factLineNo, factLine)]
        }
    )
    fixtureOptionsM
  where
    mkTask = CodeTask

-- | The propose stage's input, rendered from the task.
proposeIn :: CodeTask -> ProposeIn
proposeIn t =
  ProposeIn
    (Field (taskPath t))
    (Field (taskTitle t))
    (Field (taskWhy t))
    (Field (codeFactLines (taskFact t)))

-- | The program over a task (for the evaluation seam): bind the task into the
-- pipeline inside an embed node, keeping the LM-facing contract untouched.
coderProg :: Program CodeTask PatchResult
coderProg = embed (\t -> runProgram (coder t) (proposeIn t))

-- ---------------------------------------------------------------------------
-- Scripted model turns
-- ---------------------------------------------------------------------------

-- | The correct scripted answer: replace the fact line with the public one.
-- The section names are the 'PatchPlan' field labels verbatim (the same
-- derivation the JSON schema uses); the first replacement line is given
-- unindented, per the wire's edge-whitespace strip (it inherits the replaced
-- line's indentation at apply time).
goodResponse :: Response
goodResponse =
  markerResponse
    [ ("ppOld", T.stripStart factLine),
      ("ppNew", T.stripStart expectedLine),
      ("ppWhy", "the private constructor hides the option from --help; the public one is the established registration for dump options"),
      ("ppNote", "Promotes --dump-mlds to a public, documented option.")
    ]

-- | The sabotaged answer: a /stale old block/ — the model misremembers the
-- constructor name. No trimmed line matches, so the exact-once guard rejects
-- it and nothing is applied.
-- | The sabotaged answer: the old block with its indentation mangled —
-- it matches zero lines, so the guard must reject it.
badResponse :: Response
badResponse =
  markerResponse
    [ ("ppOld", T.replace "priv_alt_arg_help" "priv_arg_help" (T.stripStart factLine)),
      ("ppNew", T.stripStart expectedLine),
      ("ppWhy", "same edit, but from a stale memory of the constructor's name"),
      ("ppNote", "A stale first attempt.")
    ]

-- ---------------------------------------------------------------------------
-- Scripted runners
-- ---------------------------------------------------------------------------

-- | Run under a fixed script of model turns (an 'Shikumi.LLM.LLM' interpreter
-- that replays responses in order), with the same row @evaluateWith@ needs.
runScript :: [Response] -> Eff '[LLM, Concurrent, Error ShikumiError, Time, Prim, IOE] a -> IO (Either ShikumiError a)
runScript script =
  runEff
    . runPrim
    . runTime
    . runErrorNoCallStack
    . runConcurrent
    . runScriptLLM script

-- ---------------------------------------------------------------------------
-- The walkthrough
-- ---------------------------------------------------------------------------

main :: IO ()
main = do
  putStrLn "shikumi-coder: LLM codegen over a real codebase; the model decides, Haskell verifies\n"

  -- Act 0 — the fixture must support the task -------------------------------
  let fixtureLines = T.lines fixtureOptionsM
      nMatches = occurrences (T.lines factLine) fixtureLines
  putStrLn "[act 0] fixture self-check (the exact-once guard's precondition):"
  putStrLn $ "  fact line occurs " <> show nMatches <> " time(s) in the fixture"
  unless (nMatches == 1) $
    error "fixture drift: the embedded options.m region no longer matches factLine"
  putStrLn "  ok"

  -- Act 1 — the task ---------------------------------------------------------
  putStrLn "\n[act 1] the task, as the model will see it:"
  TIO.putStrLn ("  file:  " <> taskPath dumpMldsTask)
  TIO.putStrLn ("  title: " <> taskTitle dumpMldsTask)
  putStrLn "  why:"
  mapM_ (TIO.putStrLn . ("    " <>)) (T.lines (taskWhy dumpMldsTask))
  putStrLn "  fact:"
  TIO.putStr (T.unlines . map ("    " <>) . T.lines $ codeFactLines (taskFact dumpMldsTask))

  -- Act 2 — the full pipeline ------------------------------------------------
  putStrLn "\n[act 2] propose -> guard -> apply (scripted model):"
  r2 <- runScript [goodResponse] (runProgram (coder dumpMldsTask) (proposeIn dumpMldsTask))
  case r2 of
    Left err -> putStrLn $ "  failed: " <> show (err :: ShikumiError)
    Right out -> do
      let plan = prPlan out
          newFile = unField (prFile out)
      putStrLn $ "  plan: " <> T.unpack (unField (ppNote plan))
      putStrLn $ "  edit: " <> T.unpack (unField (ppWhy plan))
      putStrLn "  diff:"
      TIO.putStr (indented (sourceDiff fixtureOptionsM newFile))
      putStrLn $ "  matches expected file -> " <> show (newFile == expectedFile)

  -- Act 3 — the guard ---------------------------------------------------------
  putStrLn "\n[act 3] a stale edit (misremembered constructor) is rejected by the guard:"
  r3 <- runScript [badResponse] (runProgram (coderOnce dumpMldsTask) (proposeIn dumpMldsTask))
  case r3 of
    Left err -> putStrLn $ "  typed error -> " <> show (err :: ShikumiError)
    Right _ -> putStrLn "  unexpectedly applied"

  -- Act 4 — informed retry -----------------------------------------------------
  putStrLn "\n[act 4] retry 3 with a scripted bad first turn: the corrected turn lands:"
  r4 <- runScript [badResponse, goodResponse] (runProgram (coder dumpMldsTask) (proposeIn dumpMldsTask))
  case r4 of
    Left err -> putStrLn $ "  failed: " <> show (err :: ShikumiError)
    Right out ->
      putStrLn $
        "  succeeded after the rejected attempt; matches expected -> "
          <> show (unField (prFile out) == expectedFile)

  -- Act 5 — the evaluation seam ------------------------------------------------
  putStrLn "\n[act 5] the task as a one-example dataset with a file-equality metric:"
  let ds :: Dataset CodeTask PatchResult
      ds = dataset [example dumpMldsTask (expectedResult dumpMldsTask)]
      metric :: Metric PatchResult
      metric = customMetric (\e p -> boolScore (unField (prFile (predictionPrimary p)) == unField (prFile e)))
      cfg = defaultEvalConfig {concurrency = 1}
  r5 <- runStubEval (const goodResponse) (evaluateWith cfg ds (liftMetric metric) coderProg)
  case r5 of
    Left err -> putStrLn $ "  evaluation failed: " <> show err
    Right report -> TIO.putStr (renderReportText report)

  -- Act 6 — the live path --------------------------------------------------------
  live <- lookupEnv "SHIKUMI_LIVE"
  case live of
    Just "1" -> runLive
    _ -> putStrLn "\n(live provider skipped; set SHIKUMI_LIVE=1 to enable — dry run, nothing is written)"

-- | The hand-written expected result for the evaluation seam.
expectedResult :: CodeTask -> PatchResult
expectedResult =
  PatchResult
    (Field expectedFile)
    ( PatchPlan
        (Field factLine)
        (Field expectedLine)
        (Field "the private constructor hides the option; the public one is established")
        (Field "Promotes --dump-mlds to a public, documented option.")
    )

indented :: Text -> Text
indented = T.unlines . map ("    " <>) . T.lines

-- ---------------------------------------------------------------------------
-- The live path: the same program value, real provider, dry run.
-- (The wiring is tier-1's, verbatim; only the program and input differ.)
-- ---------------------------------------------------------------------------

runLive :: IO ()
runLive = do
  key <- lookupEnv "OMNIROUTE_API_KEY"
  unless (maybe False (not . null) key) $
    putStrLn "SHIKUMI_LIVE=1 is set, but OMNIROUTE_API_KEY is missing or empty; skipping."
  case key of
    Nothing -> pure ()
    Just _ -> do
      openAiBase <- lookupEnv "OPENAI_API_BASE"
      omniBase <- lookupEnv "OMNIROUTE_BASE_URL"
      modelId <-
        fmap (T.pack . fromMaybe "free-models") $
          lookupEnv "SHIKUMI_MODEL" >>= maybe (lookupEnv "OMNIROUTE_CHAT_MODEL") (pure . Just)
      let baseUrl = case (openAiBase, omniBase) of
            (Just b, _) -> T.pack b
            (_, Just b) -> T.pack b <> "/v1"
            _ -> "http://localhost:20128/v1"
          target =
            (mkModel OpenAIChatCompletions modelId baseUrl)
              { contextWindow = 1048576
              }
          creds =
            emptyOptions
              { apiKey = Just (ApiKeyEnv "OMNIROUTE_API_KEY"),
                timeoutMs = Just 120000
              }
          cfg = defaultLLMConfig globalProviderRegistry
          defaults = emptyRequestDefaults {defaultMaxTokens = Just 2048}

      OpenAI.register
      putStrLn ("live (" <> T.unpack modelId <> " via " <> T.unpack baseUrl <> "), dry run:")
      liveResult <-
        runEff
          . runConcurrent
          . runErrorNoCallStack @ShikumiError
          . runRouting target
          . runLLMResilient cfg
          . withTransportOptions creds
          . withRequestDefaults defaults
          . routeLLM
          $ runProgram (coder dumpMldsTask) (proposeIn dumpMldsTask)

      case liveResult of
        Left err -> print (err :: ShikumiError)
        Right out -> do
          let newFile = unField (prFile out)
              plan = prPlan out
          putStrLn $ "  plan: " <> T.unpack (unField (ppNote plan))
          putStrLn "  diff the model's edit would make (nothing written):"
          TIO.putStr (indented (sourceDiff fixtureOptionsM newFile))
          putStrLn $ "  matches expected file -> " <> show (newFile == expectedFile)
