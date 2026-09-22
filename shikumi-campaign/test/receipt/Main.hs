{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}

-- | L1 receipt admission tests (TESTING_VERIFICATION_STRATEGY §2.2).
-- Real alpha receipt admits; three tamper classes each refuse with the
-- distinct documented reason (fake before-diags, forged after-state, invalid op).
module Main (main) where

import Campaign.Oracle (markerOracle)
import Campaign.RepairReceipt
  ( RepairOp (..),
    RepairReceipt (..),
    SourceState (..),
    admitReceipt,
    admitReceiptsForFiles,
    loadRepairReceipt,
    replayOps,
  )
import Data.Text qualified as T
import System.Exit (exitFailure)
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

-- | cabal runs the suite with CWD = the package root (shikumi-campaign/).
repairsDir :: FilePath
repairsDir = "repairs"

alphaReceipt :: IO RepairReceipt
alphaReceipt = do
  r <- loadRepairReceipt (repairsDir <> "/alpha-todo-strip-receipt.dhall")
  case r of
    Left err -> do
      putStrLn ("load failed: " <> T.unpack err)
      exitFailure
    Right rc -> pure rc

main :: IO ()
main = do
  rc <- alphaReceipt
  defaultMain (tests rc)

tests :: RepairReceipt -> TestTree
tests rc =
  testGroup
    "receipt-tests"
    [ testGroup
        "admitReceipt (positive + three tamper classes)"
        [ testCase "real alpha receipt is ADMISSIBLE" $
            admitReceipt markerOracle rc @?= Right (),
          testCase "tamper class 1: fake before-diagnostics → refuse" $ do
            let bad =
                  rc
                    { rcBefore =
                        (rcBefore rc)
                          { ssDiagnostics = ["alpha.py:1: warning: [W-todo] FORGED"]
                          }
                    }
            case admitReceipt markerOracle bad of
              Left fails -> assertBool "mentions before-diagnostics" (any ("before-diagnostics" `T.isInfixOf`) fails)
              Right () -> assertBool "must refuse" False,
          testCase "tamper class 2: forged after-state → refuse" $ do
            let bad =
                  rc
                    { rcAfter =
                        (rcAfter rc)
                          { ssSource = "def alpha():\n    # TODO: still here\n    return 1"
                          }
                    }
            case admitReceipt markerOracle bad of
              Left fails -> assertBool "replay mismatch or after-diags" (any (\f -> "replay" `T.isInfixOf` f || "after-diagnostics" `T.isInfixOf` f) fails)
              Right () -> assertBool "must refuse" False,
          testCase "tamper class 3: invalid op (wrong line text) → refuse" $ do
            let badOps = case rcOperations rc of
                  (o : rest) -> o {opText = "    # NOT THE REAL LINE"} : rest
                  [] -> [DeleteLine {opLine = 1, opText = "bogus"}]
                bad = rc {rcOperations = badOps}
            case admitReceipt markerOracle bad of
              Left fails -> assertBool "faithful-deletion or replay" (any (\f -> "faithful" `T.isInfixOf` f || "replay" `T.isInfixOf` f) fails)
              Right () -> assertBool "must refuse" False
        ],
      testGroup
        "replayOps (byte-exact deletion)"
        [ testCase "replay drops only named lines, no trailing newline" $ do
            let before = "line1\nline2\nline3"
                ops = [DeleteLine {opLine = 2, opText = "line2"}]
            replayOps before ops @?= "line1\nline3",
          testCase "ops that don't match original lines are not applied" $ do
            let before = "line1\nline2"
                ops = [DeleteLine {opLine = 1, opText = "WRONG"}]
            replayOps before ops @?= "line1\nline2"
        ],
      testGroup
        "admitReceiptsForFiles (coverage + orphans)"
        [ testCase "complete coverage admits" $
            admitReceiptsForFiles markerOracle [rc] [rcPath rc] @?= Right [(rcPath rc, rc)],
          testCase "uncovered changed file → incomplete evidence" $
            case admitReceiptsForFiles markerOracle [rc] ["other.py", rcPath rc] of
              Left fails -> assertBool "incomplete" (any ("no repair receipt" `T.isInfixOf`) fails)
              Right _ -> assertBool "must refuse" False,
          testCase "orphan receipt (file not in branch) → refuse" $
            case admitReceiptsForFiles markerOracle [rc] ["unrelated.py"] of
              Left fails -> assertBool "orphan" (any ("orphan" `T.isInfixOf`) fails)
              Right _ -> assertBool "must refuse" False
        ]
    ]
