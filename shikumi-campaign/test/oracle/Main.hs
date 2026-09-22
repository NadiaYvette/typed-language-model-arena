{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}

-- | L1 oracle tests-of-the-gates (TESTING_VERIFICATION_STRATEGY §2.2).
-- Covers classifyCellLogBaseline / verdictFromBaseline / hostVerdictFromProj
-- with the golden m68k/alpha/skip fixtures — the same controls the WORKQUEUE
-- Milestone 2 CLASSIFY probe recorded, plus exit×marker matrix negatives.
module Main (main) where

import Campaign.Real
  ( TargetManifest (..),
    classifyCellLogBaseline,
    hostVerdictFromProj,
    knownFailuresFor,
    verdictFromBaseline,
  )
import Data.Text (Text)
import Data.Text qualified as T
import System.Exit (ExitCode (..))
import System.IO.Unsafe (unsafePerformIO)
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (assertEqual, testCase, (@?=))

-- | Fixture bodies are small and immutable; reading once at startup keeps
-- the suite free of per-test IO plumbing while remaining honest files.
-- cabal runs the suite with CWD = the package root (shikumi-campaign/).
readFixture :: FilePath -> Text
readFixture rel = unsafePerformIO (T.pack <$> readFile ("test/fixtures/" <> rel))

m68kFail :: Text
m68kFail = readFixture "oracle-m68k-fail.log"

m68kWaived :: Text
m68kWaived = readFixture "oracle-m68k-waived.log"

alphaPass :: Text
alphaPass = readFixture "oracle-alpha-pass.log"

skipLog :: Text
skipLog = readFixture "oracle-skip.log"

-- m68k has an empty built-in baseline; the strategy's controls pass an
-- explicit baseline (as a manifest's waiveBaseline would, unioned upstream).
m68kBaseline :: [Text]
m68kBaseline = ["fork04", "mincore04"]

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests =
  testGroup
    "oracle-tests"
    [ testGroup
        "classifyCellLogBaseline"
        [ testCase "bare failures → failed (nothing waives)" $
            classifyCellLogBaseline "m68k" [] m68kFail @?= "failed",
          testCase "exact baseline names the failures → passed-waived" $
            classifyCellLogBaseline "m68k" m68kBaseline m68kWaived @?= "passed-waived",
          testCase "wrong-name baseline negative control → failed" $
            classifyCellLogBaseline "m68k" ["fork04", "wrongname"] m68kWaived @?= "failed",
          testCase "empty baseline + clean pass log → passed" $
            classifyCellLogBaseline "alpha" [] alphaPass @?= "passed",
          testCase "SKIP marker → skipped" $
            classifyCellLogBaseline "alpha" [] skipLog @?= "skipped",
          testCase "loongarch64 built-in baseline is non-empty" $
            assertEqual "knownFailuresFor loongarch64" ["fork07", "fork09", "fork13", "mmap3"] (knownFailuresFor "loongarch64"),
          testCase "alpha built-in baseline is mmap3 only" $
            knownFailuresFor "alpha" @?= ["mmap3"]
        ],
      testGroup
        "verdictFromBaseline (exit × classify)"
        [ testCase "pass + exit0 → passed" $
            verdictFromBaseline ExitSuccess "alpha" [] alphaPass @?= "passed",
          testCase "waived + exit0 → passed-waived" $
            verdictFromBaseline ExitSuccess "m68k" m68kBaseline m68kWaived @?= "passed-waived",
          testCase "waived + exit≠0 (timeout) → failed" $
            verdictFromBaseline (ExitFailure 124) "m68k" m68kBaseline m68kWaived @?= "failed",
          testCase "bare fail + exit0 → failed" $
            verdictFromBaseline ExitSuccess "m68k" [] m68kFail @?= "failed",
          testCase "skip → skipped regardless of exit" $
            verdictFromBaseline (ExitFailure 1) "alpha" [] skipLog @?= "skipped"
        ],
      testGroup
        "hostVerdictFromProj (markers × exit)"
        [ testCase "exit0 + built-in marker → passed" $
            hostVerdictFromProj "telix" ExitSuccess "Telix-side checks passed." Nothing @?= "passed",
          testCase "exit0 missing marker → failed" $
            hostVerdictFromProj "telix" ExitSuccess "partial run" Nothing @?= "failed",
          testCase "exit≠0 + marker → failed" $
            hostVerdictFromProj "telix" (ExitFailure 1) "Telix-side checks passed." Nothing @?= "failed",
          testCase "manifest markers authoritative (all must appear)" $
            hostVerdictFromProj
              "tessera"
              ExitSuccess
              "SUITE OK"
              (Just manifestSUITE)
              @?= "passed",
          testCase "manifest missing one marker → failed" $
            hostVerdictFromProj
              "tessera"
              ExitSuccess
              "SUITE OK"
              (Just manifestNeedsTwo)
              @?= "failed"
        ]
    ]
  where
    manifestSUITE = realManifest ["SUITE OK"] True
    manifestNeedsTwo = realManifest ["SUITE OK", "ALSO THIS"] True

-- | Build a TargetManifest for marker tests (fields not under test are empty).
realManifest :: [Text] -> Bool -> TargetManifest
realManifest markers exitOk =
  TargetManifest
    { project = "tessera",
      kind = "host-verify",
      arch = "host",
      config = "cbmc-sanity",
      workDir = "/tmp",
      command = "true",
      successMarkers = markers,
      waiveBaseline = [],
      logSchema = Nothing,
      proofHygiene = Nothing,
      exitMustSucceed = exitOk,
      timeoutSeconds = 1
    }
