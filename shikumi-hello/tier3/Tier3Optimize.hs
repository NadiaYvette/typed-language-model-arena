{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Tier 3: optimize a program against data, then serialize and reload the result.
--
-- The optimizers treat a @Program@ as /data whose parameters are searchable/:
-- demos and instructions are first-class, optimizable values. 'labeledFewShot'
-- is the simplest strategy — each training example is a candidate demonstration;
-- candidate size-k demo sets are scored by evaluating the program with them
-- attached, and the best set is kept. The result is a @CompiledProgram@:
-- the structural template plus a tuned parameter vector.
--
-- That parameter vector serializes on its own: 'encodeCompiled' saves it and
-- 'decodeCompiledOnto' loads it back onto the template. Everything below runs
-- offline against the deterministic stub — which always answers "positive", so
-- the scores do not move; the point is the mechanics. With a real model, the
-- same calls would raise (or measure) real quality.
module Main (main) where

import Data.Aeson (ToJSON)
import Data.Text (Text)
import Data.Text.IO qualified as TIO
import GHC.Generics (Generic)
import Shikumi.Adapter (ToPrompt)
import Shikumi.Compile (CompiledProgram (..), decodeCompiledOnto, encodeCompiled)
import Shikumi.Eval (Dataset, dataset, evaluatePure, exactMatch, example, renderReportText)
import Shikumi.Module (predict)
import Shikumi.Optimize (labeledFewShot, optimize)
import Shikumi.Program (Program)
import Shikumi.Schema (FromModel, ToSchema, Validatable)
import Shikumi.Signature (Signature, mkSignature)
import Shikumi.Testing (markerResponse, runStubEval)

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
    [ example (Review "Loved it, would buy again") (Label "positive"),
      example (Review "Total waste of money") (Label "negative"),
      example (Review "Exceeded my expectations") (Label "positive"),
      example (Review "Broke on day one") (Label "negative")
    ]

main :: IO ()
main = do
  putStrLn "tier3-optimize: search for demos, score, then save and reload the params\n"

  -- Baseline score before optimization.
  base <-
    runStubEval
      (const (markerResponse [("label", "positive")]))
      (evaluatePure trainset exactMatch classify)
  case base of
    Left err -> putStrLn $ "baseline evaluation failed: " <> show err
    Right report -> do
      putStrLn "baseline:"
      TIO.putStr (renderReportText report)

  -- Optimize: search size-2 labelled demo sets, scored by evaluating the
  -- program over the trainset with each candidate attached.
  result <-
    runStubEval
      (const (markerResponse [("label", "positive")]))
      (optimize (labeledFewShot 2) trainset exactMatch classify)
  case result of
    Left err -> putStrLn $ "optimization failed: " <> show err
    Right compiled -> do
      putStrLn "optimized a CompiledProgram (template + tuned demos)."

      -- The tuned parameter vector round-trips through JSON on its own...
      let bytes = encodeCompiled compiled
      case decodeCompiledOnto classify bytes of
        Left err -> putStrLn $ "reload failed: " <> err
        Right reloaded -> do
          putStrLn "...serialized and reloaded onto the structural template. OK"

          -- The reloaded program is runnable like any other:
          scored <-
            runStubEval
              (const (markerResponse [("label", "positive")]))
              (evaluatePure trainset exactMatch (compiledProgram reloaded))
          putStrLn "reloaded:"
          either print (TIO.putStr . renderReportText) scored
