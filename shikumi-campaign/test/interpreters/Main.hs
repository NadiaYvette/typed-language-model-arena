{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}

-- | L1 interpreter tests for reserved oracle facts (Tier 4a): proofHygiene
-- and logSchema over golden fixtures — test-first before live manifests.
module Main (main) where

import Campaign.LogSchema
  ( LogFormat (..),
    LogSummary (..),
    interpretLogSchema,
    logSchemaOk,
  )
import Campaign.ProofHygiene
  ( ProofHygieneFinding (..),
    ProofHygieneVerdict (..),
    interpretProofHygiene,
    proofHygieneOk,
  )
import Data.Text (Text)
import Data.Text qualified as T
import System.IO.Unsafe (unsafePerformIO)
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

-- | Fixture bodies are small and immutable; reading once at startup keeps
-- the suite free of per-test IO plumbing while remaining honest files.
-- cabal runs the suite with CWD = the package root (shikumi-campaign/).
readFixture :: FilePath -> Text
readFixture rel = unsafePerformIO (T.pack <$> readFile ("test/fixtures/" <> rel))

cleanProof :: Text
cleanProof = readFixture "proof-hygiene-clean.log"

dirtyProof :: Text
dirtyProof = readFixture "proof-hygiene-dirty.log"

tapPass :: Text
tapPass = readFixture "log-schema-tap-pass.tap"

tapFail :: Text
tapFail = readFixture "log-schema-tap-fail.tap"

tapEmpty :: Text
tapEmpty = readFixture "log-schema-tap-empty.tap"

jsonPass :: Text
jsonPass = readFixture "log-schema-counters-pass.json"

jsonFail :: Text
jsonFail = readFixture "log-schema-counters-fail.json"

jsonNot :: Text
jsonNot = readFixture "log-schema-not-json.log"

junitPass :: Text
junitPass = readFixture "log-schema-junit-pass.xml"

junitFail :: Text
junitFail = readFixture "log-schema-junit.xml"

junitMissing :: Text
junitMissing = readFixture "log-schema-junit-missing.xml"

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests =
  testGroup
    "interpreters"
    [ testGroup
        "proofHygiene (Tier 4a)"
        [ testCase "clean proof → ProofHygieneClean" $
            interpretProofHygiene cleanProof @?= ProofHygieneClean,
          testCase "dirty proof → findings for sorryAx / axiom / admit" $ do
            case interpretProofHygiene dirtyProof of
              ProofHygieneClean -> assertBool "must be dirty" False
              ProofHygieneDirty fs -> do
                assertBool "sorryAx" (any ((== "sorryAx") . phPattern) fs)
                assertBool "axiom" (any ((== "axiom ") . phPattern) fs)
                assertBool "admit" (any ((== "admit") . phPattern) fs),
          testCase "proofHygieneOk mirrors the verdict" $ do
            proofHygieneOk (interpretProofHygiene cleanProof) @?= True
            proofHygieneOk (interpretProofHygiene dirtyProof) @?= False
        ],
      testGroup
        "logSchema — tap"
        [ testCase "pass tap → LogTap, failed=0, ok" $ do
            case interpretLogSchema "tap" tapPass of
              Left err -> assertBool (T.unpack err) False
              Right s -> do
                lsFormat s @?= LogTap
                lsFailed s @?= 0
                lsPassed s @?= 1
                logSchemaOk s @?= True,
          testCase "fail tap → named failures, not ok" $ do
            case interpretLogSchema "tap" tapFail of
              Left err -> assertBool (T.unpack err) False
              Right s -> do
                lsFailed s @?= 1
                lsNamedFailures s @?= ["red"]
                logSchemaOk s @?= False,
          testCase "empty tap → honest parse error" $
            case interpretLogSchema "tap" tapEmpty of
              Left _ -> pure ()
              Right _ -> assertBool "must fail" False
        ],
      testGroup
        "logSchema — json-counters"
        [ testCase "pass counters → ok" $ do
            case interpretLogSchema "json-counters" jsonPass of
              Left err -> assertBool (T.unpack err) False
              Right s -> do
                lsFormat s @?= LogJsonCounters
                lsFailed s @?= 0
                logSchemaOk s @?= True,
          testCase "fail counters → named failures" $ do
            case interpretLogSchema "json-counters" jsonFail of
              Left err -> assertBool (T.unpack err) False
              Right s -> do
                lsFailed s @?= 2
                lsNamedFailures s @?= ["fork04", "mincore04"]
                logSchemaOk s @?= False,
          testCase "not JSON → honest parse error" $
            case interpretLogSchema "json-counters" jsonNot of
              Left _ -> pure ()
              Right _ -> assertBool "must fail" False
        ],
      testGroup
        "logSchema — junit"
        [ testCase "pass junit → ok" $ do
            case interpretLogSchema "junit" junitPass of
              Left err -> assertBool (T.unpack err) False
              Right s -> do
                lsFormat s @?= LogJUnit
                lsFailed s @?= 0
                logSchemaOk s @?= True,
          testCase "fail junit → failed count from failures attr" $ do
            case interpretLogSchema "junit" junitFail of
              Left err -> assertBool (T.unpack err) False
              Right s -> do
                lsFailed s @?= 1
                logSchemaOk s @?= False,
          testCase "missing testsuite → honest parse error" $
            case interpretLogSchema "junit" junitMissing of
              Left _ -> pure ()
              Right _ -> assertBool "must fail" False
        ],
      testGroup
        "logSchema — unknown fact id"
        [ testCase "unknown id → Left (never a silent pass)" $
            case interpretLogSchema "bogus" tapPass of
              Left err -> assertBool "names the id" ("bogus" `T.isInfixOf` err)
              Right _ -> assertBool "must fail" False
        ]
    ]
