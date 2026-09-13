{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Tier 6: the CLI — a library of subcommand builders wired around YOUR task.
--
-- There is no generic "run any program" binary: a shikumi 'Program' is a typed
-- Haskell value, so the CLI is @cliMain yourRegistry@ — a handful of 'register'
-- calls bundling each task's program, dataset, metric, canonical input, offline
-- stub responder, and named optimizers. From that one wiring you get
--
-- > shikumi eval     --program classify
-- > shikumi record   --program classify --store-dir .shikumi
-- > shikumi trace    classify --store-dir .shikumi
-- > shikumi optimize --program classify --optimizer bootstrap-fewshot --out classify.json
-- > shikumi replay   classify --store-dir .shikumi
--
-- all offline by default (deterministic stub LM, no credentials) and all built
-- on the tiers you have already met: eval → tier-2 evaluation, record/trace/
-- replay → tier-4 tracing, optimize → tier-3 optimization.
--
-- This executable takes its subcommand from argv, so exercise it with
-- @cabal run tier6-cli -- <subcommand> …@ (see 'main' below for the full tour).
module Main (main) where

import Baikai (Context, Response)
import Data.Aeson (ToJSON)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import GHC.Generics (Generic)

import Shikumi.Adapter (ToPrompt)
import Shikumi.Cli (cliMain)
import Shikumi.Cli.Registry (Registry, Task (..), emptyRegistry, register)
import Shikumi.Eval (Dataset, Metric, dataset, exactMatch, example)
import Shikumi.Module (predict)
import Shikumi.Optimize (Optimizer, bootstrapFewShot, defaultBudget, labeledFewShot)
import Shikumi.Program (Program)
import Shikumi.Schema (FromModel, ToSchema, Validatable)
import Shikumi.Signature (Signature, mkSignature)
import Shikumi.Testing (markerResponse)

-- ---------------------------------------------------------------------------
-- The task: the tier-3 sentiment classifier, now CLI-addressable.
-- ---------------------------------------------------------------------------

newtype Review = Review {reviewText :: Text}
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToSchema, FromModel, ToPrompt, ToJSON)

newtype Label = Label {label :: Text}
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToSchema, FromModel, ToPrompt, ToJSON)

instance Validatable Label

classify :: Program Review Label
classify = predict (mkSignature "Classify the review sentiment as positive or negative." :: Signature Review Label)

trainset :: Dataset Review Label
trainset =
  dataset
    [ example (Review "Loved it, would buy again") (Label "positive")
    , example (Review "Total waste of money") (Label "negative")
    , example (Review "Exceeded my expectations") (Label "positive")
    , example (Review "Broke on day one") (Label "negative")
    ]

sentimentMetric :: Metric Label
sentimentMetric = exactMatch

-- The canonical input trace/replay run against.
canonicalInput :: Review
canonicalInput = Review "Loved it, would buy again"

-- The deterministic offline stub for this task (always "positive").
responder :: Context -> Response
responder = const (markerResponse [("label", "positive")])

-- Named optimizers the task exposes to the optimize subcommand.
optimizers :: Map.Map Text (Optimizer Review Label)
optimizers =
  Map.fromList
    [ ("bootstrap-fewshot", bootstrapFewShot classify defaultBudget)
    , ("labeled-fewshot", labeledFewShot 2)
    ]

myRegistry :: Registry
myRegistry =
  register
    "classify"
    (Task classify trainset sentimentMetric canonicalInput responder optimizers)
    emptyRegistry

main :: IO ()
main = cliMain myRegistry
