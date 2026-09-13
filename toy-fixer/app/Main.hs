{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -Wno-incomplete-uni-patterns #-} -- corpus is a compile-time constant, non-empty by construction

-- | The toy fixer, act by act, fully offline.
--
-- Act 1 shows what the model is asked: diagnostics in, minimum-diff repair
-- out — including the raw marker body the scripted model replies with.
-- Act 2 runs the real 'fixSource' program under a deterministic stub responder
-- that /reconstructs the expected repair from the diagnostics it reads in the
-- rendered request/ — so decode, guard, and metric are all real framework code
-- and only the model's intelligence is scripted.
-- Act 3 shows the no-regression guard: a repair that adds a line is rejected
-- with a typed 'ShikumiError' (which program-level @retry@ would re-ask on).
-- Act 4 evaluates the same program over the seeded corpus with the
-- ground-truth metric and renders the standard report.
module Main (main) where

import Baikai (Context, Message (UserMessage), Response, TextContent (..), UserContent (..))
import Control.Lens ((^.))
import Data.Generics.Labels ()
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Data.Vector qualified as V

import Shikumi.Eval
  ( Dataset,
    EvalConfig (concurrency),
    dataset,
    defaultEvalConfig,
    evaluateWith,
    example,
    liftMetric,
    renderReportText,
  )
import Shikumi.Program (Program, embed, runProgram)
import Shikumi.Schema.Types (Field (..))
import Shikumi.Testing (markerResponse, runStubEval)

import Toy.Fixer.Domain (Source (..), checkSource, corpus, showDiagnostic, sourceText)
import Toy.Fixer.Program
  ( DiagnosticsIn (..),
    FixResult (..),
    RepairOut (..),
    Submission (..),
    buildSubmission,
    fixesSource,
    fixAndReport,
    fixSource,
  )

-- The dataset input: a corpus entry (path, broken source, expected repair).
type File = (Text, Source, Source)

-- ---------------------------------------------------------------------------
-- The scripted "model": reconstruct the expected repair from the request
-- ---------------------------------------------------------------------------

-- | The rendered request as one text blob: system prompt plus every user
-- text block. The stub "model" reads exactly what a real model would.
renderedContext :: Context -> Text
renderedContext c =
  T.intercalate
    "\n"
    ( maybe "" id (c ^. #systemPrompt)
        : [t | UserMessage p <- V.toList (c ^. #messages), UserText (TextContent t) <- V.toList (p ^. #content)]
    )

-- | Identify which corpus file the rendered request is about (its first
-- diagnostic line appears in the rendered context) and answer with that
-- file's expected repair. Deterministic, keyed on what the model reads.
responder :: Context -> Response
responder c = case [(p, e) | (p, s, e) <- corpus, firstDiag p s `T.isInfixOf` renderedContext c] of
  ((_, e) : _) -> markerResponse [("repaired", sourceText e)]
  [] -> markerResponse [("repaired", "")]

-- | A deliberately bad repair: the expected fix plus one invented line — the
-- no-regression guard must reject it.
sabotagedResponder :: Context -> Response
sabotagedResponder c =
  case [(p, e) | (p, s, e) <- corpus, firstDiag p s `T.isInfixOf` renderedContext c] of
    ((_, e) : _) -> markerResponse [("repaired", sourceText e <> "import os\n")]
    [] -> markerResponse [("repaired", "")]

firstDiag :: Text -> Source -> Text
firstDiag p s = case map showDiagnostic (checkSource p s) of
  (d : _) -> d
  [] -> p

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

diagnosticsIn :: Text -> Source -> DiagnosticsIn
diagnosticsIn p s = DiagnosticsIn (Field (map showDiagnostic (checkSource p s)))

numbered :: Text -> Text
numbered = T.unlines . zipWith (\n l -> T.pack (show (n :: Int)) <> "  " <> l) [1 ..] . T.lines

-- | One program over the whole corpus entry: bind each file's original
-- source into its own repair program, dispatching inside an embed node.
fixerFor :: Program File FixResult
fixerFor = embed (\(p, s, _) -> runProgram (fixAndReport s) (diagnosticsIn p s))

expectedOut :: File -> FixResult
expectedOut f@(_, _, e) = FixResult (f2src f) (RepairOut (Field (sourceText e)))

f2src :: File -> Source
f2src (_, s, _) = s

unRepaired :: RepairOut -> Text
unRepaired (RepairOut (Field t)) = t

wireReply :: Source -> Text
wireReply e = buildSubmission (Submission (sourceText e))

indented :: Text -> Text
indented = T.unlines . map ("    " <>) . T.lines

-- ---------------------------------------------------------------------------
-- The walkthrough
-- ---------------------------------------------------------------------------

main :: IO ()
main = do
  putStrLn "toy-fixer: an LM repairs seeded warnings; Haskell owns the ground truth\n"
  let files@((p0, s0, e0) : _) = corpus -- non-empty by construction

  -- Act 1 — the ask ---------------------------------------------------------
  putStrLn "[act 1] what the model is asked:"
  TIO.putStr (numbered (sourceText s0))
  mapM_ (TIO.putStrLn . ("  diagnostic: " <>)) (map showDiagnostic (checkSource p0 s0))
  putStrLn "\n  what the scripted model replies on the wire:"
  TIO.putStr (indented (wireReply e0))

  -- Act 2 — the real program, end to end ------------------------------------
  putStrLn "\n[act 2] run fixSource (decode -> guard -> typed result):"
  r2 <- runStubEval responder (runProgram (fixAndReport s0) (diagnosticsIn p0 s0))
  case r2 of
    Left err -> putStrLn $ "  failed: " <> show err
    Right out -> do
      putStrLn "  repaired source:"
      TIO.putStr (indented (unRepaired (result out)))

  -- Act 3 — the guard --------------------------------------------------------
  putStrLn "\n[act 3] a repair that adds a line is rejected by the guard:"
  r3 <- runStubEval sabotagedResponder (runProgram (fixSource s0) (diagnosticsIn p0 s0))
  case r3 of
    Left err -> putStrLn $ "  typed error -> " <> show err
    Right _ -> putStrLn "  unexpectedly accepted"
  putStrLn "  (program-level `retry 2 (fixSource src)` would re-ask on this)"

  -- Act 4 — evaluation over the corpus --------------------------------------
  putStrLn "\n[act 4] evaluate fixSource over the seeded corpus:"
  let ds :: Dataset File FixResult
      ds = dataset [example f (expectedOut f) | f <- files]
      cfg = defaultEvalConfig {concurrency = 1} -- scripted runs are sequential
  r4 <-
    runStubEval responder (evaluateWith cfg ds (liftMetric fixesSource) fixerFor)
  case r4 of
    Left err -> putStrLn $ "  evaluation failed: " <> show err
    Right report -> TIO.putStr (renderReportText report)
