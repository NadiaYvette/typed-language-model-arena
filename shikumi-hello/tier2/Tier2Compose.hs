{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Tier 2a: compose typed programs with '(>>>)'.
--
-- Each stage is a @Program i o@; @(>>>)@ chains them and typechecks only
-- because each stage's output type equals the next stage's input type — swap
-- two stages and this file stops compiling. That is the whole trick: pipeline
-- structure is ordinary typechecking, not runtime wiring.
--
-- Offline, one stub responder serves every stage by branching on the per-stage
-- instruction (each stage's instruction is rendered into its request's system
-- prompt).
module Main (main) where

import Baikai (Context, Response)
import Data.Text (Text)
import GHC.Generics (Generic)
import Shikumi.Adapter (ToPrompt)
import Shikumi.Combinator ((>>>))
import Shikumi.Module (predict)
import Shikumi.Program (Program)
import Shikumi.Schema (FromModel, ToSchema, Validatable (..))
import Shikumi.Schema.Types (Field, field, unField)
import Shikumi.Signature (mkSignature)
import Shikumi.Testing (markerResponse, runStub, systemContains)

-- ---------------------------------------------------------------------------
-- One record type per pipeline boundary.
-- ---------------------------------------------------------------------------

data Article = Article
  { title :: !(Field "The article's headline" Text),
    body :: !(Field "The full article text" Text)
  }
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToSchema, FromModel, ToPrompt)

data Summary = Summary
  { headline :: !(Field "A one-line summary" Text),
    bullets :: !(Field "Three to five key points" [Text])
  }
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToSchema, FromModel, ToPrompt)

-- A domain rule on the intermediate type: the decoder of stage 1 enforces it
-- before stage 2 ever sees the value.
instance Validatable Summary where
  validate s
    | n < 3 || n > 5 = Left "bullets: must have 3 to 5 items"
    | otherwise = Right s
    where
      n = length (unField (bullets s))

data Moderation = Moderation
  { publish :: !Bool,
    reason :: !Text
  }
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToSchema, FromModel, ToPrompt)

instance Validatable Moderation

-- ---------------------------------------------------------------------------
-- Two typed stages, chained into one program.
-- ---------------------------------------------------------------------------

summarize :: Program Article Summary
summarize = predict (mkSignature "Summarize the article into a headline and key points.")

moderate :: Program Summary Moderation
moderate = predict (mkSignature "Decide whether the summary is publishable: harmless, on-topic, and complete.")

-- The whole pipeline. Its type, Program Article Moderation, is enforced by the
-- chain: replace `moderate` with `summarize` here and the compiler rejects it.
pipeline :: Program Article Moderation
pipeline = summarize >>> moderate

sampleArticle :: Article
sampleArticle =
  Article
    { title = field "Typed LM programs",
      body = field "Shikumi makes LM calls behave like ordinary typed software."
    }

-- One responder for both stages: branch on the stage's instruction (it is
-- rendered into the request's system prompt). Each stage decodes only its own
-- fields, so a response carrying just that stage's markers is enough.
responder :: Context -> Response
responder ctx
  | systemContains "Summarize" ctx =
      markerResponse
        [ ("headline", "Shikumi types LM programs"),
          ("bullets", "[\"records in\", \"records out\", \"errors are typed\"]")
        ]
  | otherwise =
      markerResponse
        [ ("publish", "true"),
          ("reason", "on-topic, harmless, and complete")
        ]

main :: IO ()
main = do
  putStrLn "tier2-compose: typed pipeline, mismatches are compile errors\n"
  result <- runStub responder pipeline sampleArticle
  case result of
    Left err -> putStrLn $ "pipeline failed: " <> show err
    Right decision -> do
      putStrLn "Article >>> Summary >>> Moderation"
      putStrLn $ "decision -> " <> show decision
