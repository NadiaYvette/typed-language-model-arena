{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Hello world for shikumi: records in, records out, typed errors.
--
-- Two modes, same program value, only the bottom interpreter differs:
--
--  * Default: fully offline against the deterministic stub LM from
--    @shikumi-testing@ — no API key, no network.
--
--  * @SHIKUMI_LIVE=1@: the identical program runs through the real transport
--    — an OpenAI Chat Completions endpoint configured from the environment
--    (@OPENAI_API_BASE@ / @OMNIROUTE_BASE_URL@, model @OMNIROUTE_CHAT_MODEL@,
--    key @OMNIROUTE_API_KEY@) — with ambient routing and the resilience stack.
module Main (main) where

import Control.Monad (unless)
import Data.Aeson (Value (Null), object, (.=))
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text.IO
import GHC.Generics (Generic)

import Baikai (ApiKeySource (ApiKeyEnv), Api (OpenAIChatCompletions), Model (..), Options (..), emptyOptions, flattenAssistantBlocks, flattenAssistantText, globalProviderRegistry, mkModel)
import Control.Lens ((^.))
import Baikai.Provider.OpenAI.Api qualified as OpenAI
import Effectful (Eff, IOE, liftIO, runEff, type (:>))
import Effectful.Concurrent (runConcurrent)
import Effectful.Dispatch.Dynamic (interpose)
import Effectful.Error.Static (runErrorNoCallStack)
import System.Environment (lookupEnv)
import System.Exit (exitSuccess)
import Data.Maybe (fromMaybe)
import Text.Printf (printf)

import Shikumi.Adapter (ToPrompt (..))
import Shikumi.Error (ShikumiError)
import Shikumi.LLM (defaultLLMConfig, runLLMResilient)
import Shikumi.LLM qualified as L
import Shikumi.LLM.Defaults (RequestDefaults (defaultMaxTokens), emptyRequestDefaults, withRequestDefaults)
import Shikumi.Module (predict)
import Shikumi.Program (Program, runProgram)
import Shikumi.Program qualified as P (Demo (..), Params (..), emptyParams, mapParams)
import Shikumi.Routing (routeLLM, runRouting)
import Shikumi.Schema (FromModel, ToSchema, Validatable (..))
import Shikumi.Schema.Types (Field, field, unField)
import Shikumi.Signature (Signature, mkSignature)
import Shikumi.Testing (markerResponse, runStub)
import Shikumi.Testing.Responses (withTransportOptions)

-- ---------------------------------------------------------------------------
-- 1. The types are the program. A one-line description per field via the
--    @Field "desc" a@ wrapper; the schema, the decode, and the prompt rendering
--    all derive from these records.
-- ---------------------------------------------------------------------------

data Article = Article
  { title :: Field "The article's headline" Text
  , body  :: Field "The full article text" Text
  }
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToSchema, FromModel, ToPrompt)

data Sentiment = Positive | Neutral | Negative
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToSchema, FromModel)

data Summary = Summary
  { headline  :: Field "A one-line summary" Text
  , bullets   :: Field "Three to five key points" [Text]
  , sentiment :: Sentiment        -- an enum-like sum
  , note      :: Maybe Text       -- optional / nullable
  }
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToSchema, FromModel, ToPrompt)

-- 2. A domain rule, enforced on decode in every runner: a bad reply surfaces
--    as a typed ValidationFailure, not an exception.
instance Validatable Summary where
  validate s
    | n < 3 || n > 5 = Left "bullets: must have 3 to 5 items"
    | otherwise      = Right s
    where
      n = length (unField (bullets s))

-- ---------------------------------------------------------------------------
-- 3. Signature + program: @predict@ turns the typed task into a runnable
--    @Program@ value. Nothing below mentions a provider or a prompt format.
-- ---------------------------------------------------------------------------

summarizeSig :: Signature Article Summary
summarizeSig = mkSignature "Summarize the article into a headline and key points."

summarize :: Program Article Summary
summarize = predict summarizeSig

-- | A worked example attached as a program parameter. Demos live in the
-- node's 'Params' (as JSON, uniform across nodes), and 'effectiveSignature'
-- splices them into the prompt at run time — this is the mechanism the
-- optimizers drive. In the marker (prompt-fallback) wire format the demo is
-- rendered with each field in exactly the syntax the parser expects, in
-- particular @bullets@ as a JSON array of strings, which pins the list format
-- far more reliably than the prose output guide alone.
demoParams :: P.Params
demoParams =
  P.emptyParams
    { P.demos =
        [ P.Demo
            { input =
                object
                  [ "title" .= ("Compound interest" :: Text)
                  , "body" .= ("Compound interest grows savings faster than simple interest, because interest itself earns interest." :: Text)
                  ]
            , output =
                object
                  [ "headline" .= ("Compound interest beats simple interest" :: Text)
                  , "bullets" .= (["Interest earns interest over time", "Growth accelerates the longer you save"] :: [Text])
                  , "sentiment" .= ("Neutral" :: Text)
                  , "note" .= Null
                  ]
            }
        ]
    }

summarizeP :: Program Article Summary
summarizeP = P.mapParams (const demoParams) summarize

sampleArticle :: Article
sampleArticle =
  Article
    { title = field "Typed LM programs"
    , body = field "Shikumi makes LM calls behave like ordinary typed software."
    }

main :: IO ()
main = do
  -- The stub LM plays the provider: it returns canned marker-format fields,
  -- which the derived FromModel decoder turns into a typed Summary.
  let stub _ctx =
        markerResponse
          [ ("headline", "Rates held steady")
          , ("bullets", "[\"point one\",\"point two\",\"point three\"]")
          , ("sentiment", "Neutral")
          ]

  result <- runStub stub summarizeP sampleArticle
  putStrLn "offline (stub):"
  case result of
    Right s  -> print s                     -- a fully-typed Summary
    Left err -> print (err :: ShikumiError) -- an enumerated failure

  -- The same program, but the stub replies with only two bullets: the derived
  -- decoder runs the Validatable rule and surfaces a typed ValidationFailure
  -- instead of an exception or a Maybe.
  let badStub _ctx =
        markerResponse
          [ ("headline", "Rates held steady")
          , ("bullets", "[\"point one\",\"point two\"]")
          , ("sentiment", "Neutral")
          ]

  bad <- runStub badStub summarizeP sampleArticle
  print (bad :: Either ShikumiError Summary)

  -- Optionally, run the *same program value* against a real provider.
  live <- lookupEnv "SHIKUMI_LIVE"
  case live of
    Just "1" -> runLive
    _ -> putStrLn "\n(live provider skipped; set SHIKUMI_LIVE=1 to enable)"

-- The provider is chosen by interpreters at the bottom of the effect stack;
-- `summarize` above is untouched. The target is a hand-rolled baikai 'Model'
-- pointing the OpenAI Chat Completions transport at an OpenAI-compatible
-- proxy (OmniRoute): base URL and model id come from the environment, the key
-- is read from OMNIROUTE_API_KEY at call time. Because the hand-rolled model
-- is not provider "openai", shikumi's router keeps the prompt-fallback
-- adapter (marker-format prompt) instead of native structured output — the
-- derived schema is still enforced, by the decoder. runRouting supplies the
-- ambient model; runLLMResilient adds retries / rate-limit / budget;
-- withTransportOptions injects credentials and a timeout into every request;
-- routeLLM stamps the ambient model onto each outgoing call.
runLive :: IO ()
runLive = do
  key <- lookupEnv "OMNIROUTE_API_KEY"
  unless (maybe False (not . null) key) $ do
    putStrLn "\nSHIKUMI_LIVE=1 is set, but OMNIROUTE_API_KEY is missing or empty; skipping the live run."
    exitSuccess

  openAiBase <- lookupEnv "OPENAI_API_BASE"
  omniBase <- lookupEnv "OMNIROUTE_BASE_URL"
  -- SHIKUMI_MODEL wins; otherwise OMNIROUTE_CHAT_MODEL; otherwise free-models.
  modelId <-
    fmap (Text.pack . fromMaybe "free-models") $
      lookupEnv "SHIKUMI_MODEL" >>= 
        maybe (lookupEnv "OMNIROUTE_CHAT_MODEL") (pure . Just)
  let baseUrl = case (openAiBase, omniBase) of
        (Just b, _) -> Text.pack b
        (_, Just b) -> Text.pack b <> "/v1"
        _ -> "http://localhost:20128/v1"
      target =
        (mkModel OpenAIChatCompletions modelId baseUrl)
          { contextWindow = 1048576
          }
      creds =
        emptyOptions
          { apiKey = Just (ApiKeyEnv "OMNIROUTE_API_KEY")
          , timeoutMs = Just 30000
          }
      cfg = defaultLLMConfig globalProviderRegistry
      defaults = emptyRequestDefaults {defaultMaxTokens = Just 1024}

  OpenAI.register
  putStrLn ("\nlive (" <> Text.unpack modelId <> " via " <> Text.unpack baseUrl <> "):")
  liveResult <-
    runEff
      . runConcurrent
      . runErrorNoCallStack @ShikumiError
      . runRouting target            -- supplies the ambient model
      . runLLMResilient cfg          -- retries / rate limit / budget
      . withTransportOptions creds   -- credentials + timeout on every request
      . teeLLM                       -- DEBUG: print each raw model reply
      . withRequestDefaults defaults -- cap output tokens for the demo
      . routeLLM                     -- stamps the ambient model onto calls
      $ runProgram summarizeP sampleArticle

  case liveResult of
    Right s  -> print s
    Left err -> print (err :: ShikumiError)

-- DEBUG: pass-through LLM interpreter that prints every raw completion.
teeLLM :: (IOE :> es, L.LLM :> es) => Eff es a -> Eff es a
teeLLM = interpose $ \_ -> \case
  L.Complete m ctx opts -> do
    liftIO $ do
      printf "\n---- request to %s (%s) ----\n" (show (modelId m)) (show (provider m))
      case ctx ^. #systemPrompt of
        Just sys -> Text.IO.putStrLn sys
        Nothing -> putStrLn "(no system prompt)"
      printf "---- %d messages ----\n" (length (ctx ^. #messages))
    r <- L.complete m ctx opts
    liftIO $ do
      printf "\n---- raw reply ----\n"
      Text.IO.putStrLn (flattenAssistantText (flattenAssistantBlocks r))
      putStrLn "---- end ----"
    pure r
  L.Stream m ctx opts -> L.stream m ctx opts
