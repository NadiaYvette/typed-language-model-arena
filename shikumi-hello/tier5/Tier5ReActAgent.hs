{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Tier 5: typed tools and a ReAct agent loop.
--
-- A tool is an ordinary function over record types; its argument schema is
-- Generic-derived (the same @ToSchema@ engine as everything else) and lowered
-- to baikai's wire tool. @reactWithTrajectory@ builds a @Program@ whose
-- embedded loop alternates thought -> action -> observation until the model
-- finishes or a bound is hit, then extracts the typed answer — recording a
-- structured 'Trajectory' throughout. The whole agent is itself a first-class,
-- composable @Program@.
--
-- Offline, a /script/ of model turns drives the loop. Two agents run:
--
--   1. a clean run: propose a tool call, finish, extract the typed answer;
--   2. a recovery run: the agent mis-formats its first tool call (the registry
--      rejects the arguments), /reads the rendered error from the observation/,
--      corrects itself, and finishes — the fail-open error philosophy applied
--      to tool use. (The scripted turns simulate the model's behaviour; the
--      argument rejection is the real registry code path.)
module Main (main) where

import Data.Aeson (ToJSON)
import Data.Text (Text)
import Data.Vector qualified as V
import GHC.Generics (Generic)
import Shikumi.Adapter (ToPrompt)
import Shikumi.Agent.ReAct
  ( Action (..),
    Step (..),
    Trajectory (..),
    defaultReActConfig,
    reactWithTrajectory,
  )
import Shikumi.Schema (FromModel, ToSchema, Validatable)
import Shikumi.Signature (Signature, mkSignature)
import Shikumi.Testing (mkTextResponse, runAgent)
import Shikumi.Tool (SomeTool (..), Tool, ToolRegistry, mkRegistry, mkTool)

-- ---------------------------------------------------------------------------
-- A tool's request/response are records; the agent's question/answer too.
-- ---------------------------------------------------------------------------

data WeatherReq = WeatherReq {city :: !Text, units :: !Text}
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToSchema, FromModel, ToPrompt)

instance Validatable WeatherReq

data WeatherResp = WeatherResp {tempC :: !Double, summary :: !Text}
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToSchema, FromModel, ToPrompt, ToJSON)

instance Validatable WeatherResp

newtype AskWeather = AskWeather {question :: Text}
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToPrompt)

-- A pure typed tool: it returns a fixed forecast (the demo only needs
-- determinism, not a real lookup).
weatherTool :: Tool WeatherReq WeatherResp
weatherTool =
  mkTool "get_weather" "Look up the current weather for a city." $ \_req ->
    pure (WeatherResp {tempC = 12.0, summary = "mild"})

weatherRegistry :: ToolRegistry
weatherRegistry = mkRegistry [SomeTool weatherTool]

weatherSignature :: Signature AskWeather WeatherResp
weatherSignature = mkSignature "Answer the user's weather question, using tools when helpful."

-- The scripted model turns for the clean run: propose a tool call, then
-- finish, then extract the typed answer.
cleanScript :: [Text]
cleanScript =
  [ "{\"thought\": \"I should look up Paris.\", \"action\": {\"tool\": \"get_weather\", \"args\": {\"city\": \"Paris\", \"units\": \"c\"}}}",
    "{\"thought\": \"I have the forecast.\", \"action\": {\"finish\": true}}",
    "{\"tempC\": 12.0, \"summary\": \"mild\"}"
  ]

-- The recovery run's script: a call whose args do not decode against the
-- tool's schema (the registry rejects them and feeds the rendered error back
-- as the observation), then a corrected call, then finish, then extract.
recoveryScript :: [Text]
recoveryScript =
  [ "{\"thought\": \"I should look up Paris.\", \"action\": {\"tool\": \"get_weather\", \"args\": {\"town\": \"Paris\"}}}",
    "{\"thought\": \"The schema wants city and units; retrying.\", \"action\": {\"tool\": \"get_weather\", \"args\": {\"city\": \"Paris\", \"units\": \"c\"}}}",
    "{\"thought\": \"I have the forecast.\", \"action\": {\"finish\": true}}",
    "{\"tempC\": 12.0, \"summary\": \"mild\"}"
  ]

printTrajectory :: Trajectory -> IO ()
printTrajectory traj = do
  putStrLn $ "termination -> " <> show (termination traj)
  putStrLn "steps:"
  mapM_ printStep (V.toList (steps traj))
  where
    printStep s =
      putStrLn $
        "  - "
          <> describe (action s)
          <> maybe "" (\o -> "  (observed: " <> show o <> ")") (observation s)
    describe (CallTool nm _) = "call " <> show nm
    describe Finish = "finish"
    describe Summarized = "summary"

main :: IO ()
main = do
  putStrLn "tier5-react-agent: a typed tool + ReAct agent loop\n"

  -- (1) Clean run: thought -> tool call -> observation -> finish -> typed answer.
  putStrLn "[clean] script of 3 model turns:"
  cleanResult <-
    runAgent
      (map mkTextResponse cleanScript)
      (reactWithTrajectory weatherSignature weatherRegistry defaultReActConfig)
      (AskWeather "What's the weather in Paris?")
  case cleanResult of
    Left err -> putStrLn $ "agent failed: " <> show err
    Right (answer, traj) -> do
      putStrLn $ "answer -> " <> show answer
      printTrajectory traj

  -- (2) Recovery run: a bad tool call is a recoverable observation, not a crash.
  putStrLn "\n[recovery] first turn calls the tool with invalid args:"
  recoveryResult <-
    runAgent
      (map mkTextResponse recoveryScript)
      (reactWithTrajectory weatherSignature weatherRegistry defaultReActConfig)
      (AskWeather "What's the weather in Paris?")
  case recoveryResult of
    Left err -> putStrLn $ "agent failed: " <> show err
    Right (answer, traj) -> do
      putStrLn $ "answer -> " <> show answer
      printTrajectory traj
