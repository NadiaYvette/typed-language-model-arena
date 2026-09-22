{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE OverloadedStrings #-}
-- corpus is a compile-time constant, non-empty by construction
{-# OPTIONS_GHC -Wno-incomplete-uni-patterns #-}

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
import Data.List (find)
import Data.Maybe (fromMaybe)
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
    prediction,
    renderReportText,
    unScore,
  )
import Shikumi.Program (Program, embed, runProgram)
import Shikumi.Schema.Types (Field (..))
import Shikumi.Testing (markerResponse, runStubEval)
import Toy.Fixer.Domain (Source (..), checkSource, corpus, showDiagnostic, sourceDiff, sourceText)
import Toy.Fixer.Program
  ( DiagnosticsIn (..),
    FixResult (..),
    RepairOut (..),
    Submission (..),
    buildSubmission,
    fixAndReport,
    fixSource,
    fixesSource,
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
    ( fromMaybe "" (c ^. #systemPrompt)
        : [t | UserMessage p <- V.toList (c ^. #messages), UserText (TextContent t) <- V.toList (p ^. #content)]
    )

-- | Identify which corpus file the rendered request is about (its first
-- diagnostic line, and its path, appear in the rendered context) and answer
-- with that file's expected repair. Deterministic, keyed on what the model
-- reads. @sabotage@ appends an invented line — the guard's job to catch.
responderWith :: (Text -> Text) -> Context -> Response
responderWith sabotage c = case [(p, e) | (p, s, e) <- corpus, matches p s] of
  ((_, e) : _) -> markerResponse [("repaired", sabotage (sourceText e))]
  [] -> markerResponse [("repaired", "")]
  where
    sys = renderedContext c
    matches p s = p `T.isInfixOf` sys && firstDiag p s `T.isInfixOf` sys

responder :: Context -> Response
responder = responderWith id

-- | A deliberately bad repair: the expected fix plus one invented line — the
-- no-regression guard must reject it.
sabotagedResponder :: Context -> Response
sabotagedResponder = responderWith (<> "import os\n")

-- | A subtler bad repair: a perfectly clean-looking over-deletion. It clears
-- every warning and trips no guard — but it deletes a line another line
-- references, so the checker reports E-undef and the metric voids the repair.
overEagerResponder :: Context -> Response
overEagerResponder c =
  case [(p, e) | (p, s, e) <- corpus, matches p s] of
    ((_, e) : _) -> markerResponse [("repaired", T.unlines (dropTodoKeepBody (T.lines (sourceText e))))]
    [] -> markerResponse [("repaired", "")]
  where
    sys = renderedContext c
    matches p s = p `T.isInfixOf` sys && firstDiag p s `T.isInfixOf` sys
    -- Drop the first line that defines a name ("x = ..."), if the expected
    -- repair still contains a later `return <that name>`. On epsilon.py this
    -- removes `total = 0` while `return total` survives -> E-undef.
    dropTodoKeepBody ls =
      case [(i, nm) | (i, l) <- zip [0 ..] ls, Just nm <- [T.stripPrefix "    " l >>= stripDef . T.strip], nm `elem` returnedNames ls] of
        ((i, _) : _) -> take i ls ++ drop (i + 1) ls
        [] -> ls
    stripDef l = do
      (lhs, r) <- pure (T.breakOn "=" l)
      if T.null r then Nothing else Just (T.takeWhile (\ch -> ch /= ' ' && ch /= '=') lhs)
    returnedNames ls =
      [nm | l <- ls, Just r <- [T.stripPrefix "return " (T.strip l)], Just nm <- [Just (T.takeWhile (\ch -> ch /= ' ' && ch /= '\n') r)]]

firstDiag :: Text -> Source -> Text
firstDiag p s = case map showDiagnostic (checkSource p s) of
  (d : _) -> d
  [] -> p

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

diagnosticsIn :: Text -> Source -> DiagnosticsIn
diagnosticsIn p s =
  DiagnosticsIn
    (Field p)
    (Field (map showDiagnostic (checkSource p s)))

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
  mapM_ ((TIO.putStrLn . ("  diagnostic: " <>)) . showDiagnostic) (checkSource p0 s0)
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

  -- Act 5 — the trap and the negative control -------------------------------
  putStrLn "\n[act 5] a clean-looking over-deletion is voided by the checker:"
  let Just (_, sEps, _) = find ((== "epsilon.py") . fst3) corpus
  r5 <- runStubEval overEagerResponder (runProgram (fixAndReport sEps) (diagnosticsIn "epsilon.py" sEps))
  case r5 of
    Left err -> putStrLn $ "  typed error -> " <> show err
    Right out -> do
      let repairedText = unRepaired (result out)
      putStrLn "  diff of what the over-eager repair did:"
      TIO.putStr (indented (sourceDiff sEps (Source repairedText)))
      putStrLn "  checker on the repair -> "
      mapM_ ((TIO.putStrLn . ("    " <>)) . showDiagnostic) (checkSource "epsilon.py" (Source repairedText))
      putStrLn $ "  metric score for this repair -> " <> show (scoreFor sEps repairedText)

  putStrLn "\n[act 5b] the negative control: a string-literal TODO needs no repair:"
  let Just (_, sEta, eEta) = find ((== "eta.py") . fst3) corpus
      dsEta0 = map showDiagnostic (checkSource "eta.py" sEta)
  putStrLn $ "  diagnostics on the broken file -> " <> (if null dsEta0 then "[] (correct: nothing to fix)" else show dsEta0)
  r5b <- runStubEval responder (runProgram (fixAndReport sEta) (diagnosticsIn "eta.py" sEta))
  case r5b of
    Left err -> putStrLn $ "  typed error -> " <> show err
    Right out ->
      -- Note: the marker-section wire format trims the reply's trailing
      -- newline, so identity is compared modulo that — a real (if tiny)
      -- integration fact a round-trip test should pin down.
      putStrLn $
        "  repair is the identity (modulo the wire's trailing-newline trim) -> "
          <> show (T.stripEnd (sourceText eEta) == T.stripEnd (unRepaired (result out)))
          <> "; metric -> "
          <> show (scoreFor sEta (unRepaired (result out)))
  where
    fst3 (a, _, _) = a

-- | Score a candidate repair for one file, for the walkthrough's printing.
scoreFor :: Source -> Text -> Double
scoreFor orig t = unScore (fixesSource (FixResult orig (RepairOut (Field t))) (prediction (FixResult orig (RepairOut (Field t)))))
