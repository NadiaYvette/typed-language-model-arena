{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Tier 4: caching, tracing, and deterministic replay.
--
-- Each is an @interpose@ over the same @LLM@ effect, so you opt into them by
-- stacking interpreters — the program is untouched. This example runs one typed
-- program three ways:
--
--   1. /cached/ — the in-memory cache serves repeated identical calls, so the
--      provider is contacted once no matter how often the program re-runs;
--   2. /traced/ — @tracedLLM@ + @runTrace@ capture a hierarchical span tree
--      with timings and usage, which we render and persist to disk;
--   3. /replayed/ — @runLLMReplay@ re-runs the program from the stored trace
--      alone, fail-closed, contacting no provider at all.
module Main (main) where

import Baikai (Context, Response)
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text.IO qualified as TIO
import Effectful (Eff, IOE, liftIO, runEff, type (:>))
import Effectful.Concurrent (runConcurrent)
import Effectful.Dispatch.Dynamic (interpret)
import Effectful.Error.Static (runErrorNoCallStack)
import Effectful.Prim (runPrim)
import GHC.Generics (Generic)

import Shikumi.Adapter (ToPrompt)
import Shikumi.Cache (cachedLLM)
import Shikumi.Cache.Backend.Memory (newMemoryCache, runCacheMemory)
import Shikumi.Effect.Time (runTime)
import Shikumi.Error (ShikumiError)
import Shikumi.LLM (LLM (..))
import Shikumi.Module (predict)
import Shikumi.Program (Program, runProgram)
import Shikumi.Schema (FromModel, ToSchema, Validatable)
import Shikumi.Signature (Signature, mkSignature)
import Shikumi.Testing (markerResponse, runStubLLM)
import Shikumi.Trace (SpanKind (ProgramSpan), renderTree, runTrace, tracedLLM, withSpan)
import Shikumi.Trace.Replay (runLLMReplay)
import Shikumi.Trace.Store (readTraceFile, replayIndex, writeTraceFile)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)

newtype Question = Question {question :: Text}
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToSchema, FromModel, ToPrompt)

newtype Answer = Answer {answer :: Text}
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToSchema, FromModel, ToPrompt)

instance Validatable Answer

qa :: Program Question Answer
qa = predict (mkSignature "Answer the question concisely." :: Signature Question Answer)

input, otherInput :: Question
input = Question "What does shikumi turn LM calls into?"
otherInput = Question "What effect does the cache interpose on?"

responder :: Context -> Response
responder = const (markerResponse [("answer", "typed, traceable, replayable programs")])

main :: IO ()
main = withSystemTempDirectory "shikumi-hello" $ \dir -> do
  putStrLn "tier4-trace-replay: cache, trace, and replay one program\n"

  -- (1) Caching: repeated identical runs, one provider call. The counter sits
  -- BELOW the cache, so it only counts calls that actually reach the
  -- transport; a content-addressed hit never gets that far. A different input
  -- is a different key, so it is a real miss.
  cache <- newMemoryCache
  calls <- newIORef (0 :: Int)
  let counting :: forall es a. (IOE :> es) => Eff (LLM : es) a -> Eff es a
      counting = interpret $ \_ -> \case
        Complete _ c _ -> do
          liftIO (atomicModifyIORef' calls (\n -> (n + 1, ())))
          pure (responder c)
        Stream {} -> pure []

  cached <-
    runEff . runConcurrent . runTime . runCacheMemory cache . counting
      . runErrorNoCallStack @ShikumiError . cachedLLM $ do
        a <- runProgram qa input
        b <- runProgram qa input
        c <- runProgram qa otherInput
        pure (a, b, c)
  n <- readIORef calls
  putStrLn $ "[cache]  three runs (two identical) -> " <> show cached
  putStrLn $ "[cache]  provider calls -> " <> show n <> " (the repeat was served from cache)\n"

  -- (2) Tracing: capture, render, and persist a hierarchical span tree.
  (traced, tree) <-
    runEff . runPrim . runTime . runTrace . runStubLLM responder . tracedLLM $
      runErrorNoCallStack @ShikumiError (withSpan ProgramSpan "qa" (runProgram qa input))
  putStrLn "[trace]  span tree:"
  TIO.putStr (renderTree tree)
  putStrLn $ "[trace]  result -> " <> show traced
  let tracePath = dir </> "qa-trace.json"
  writeTraceFile tracePath tree

  -- (3) Replay: re-run from the stored trace alone, zero provider calls.
  loaded <- readTraceFile tracePath
  case loaded of
    Left err -> TIO.putStrLn ("[replay] could not read trace: " <> err)
    Right tree' ->
      case replayIndex tree' of
        Left err -> TIO.putStrLn ("[replay] index error: " <> err)
        Right idx -> do
          replayed <-
            runEff . runErrorNoCallStack @ShikumiError . runLLMReplay idx $
              runProgram qa input
          putStrLn $ "\n[replay] from trace only -> " <> show replayed
