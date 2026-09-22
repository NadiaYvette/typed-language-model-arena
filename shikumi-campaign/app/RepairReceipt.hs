{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Offline admission of repair receipts: load a receipt and its blueprint
-- from shikumi-campaign/repairs/, re-derive every claim under the named
-- oracle (toy-markers for the corpus examples), and report admissible or
-- the re-derivation failures. A built-in negative control tampers the
-- recorded after-diagnostics and asserts the tampered receipt is rejected —
-- proving the record is checked, not trusted, regardless of the real
-- receipt's outcome.
--
-- Usage: repair-receipt [REPAIRS_DIR]
module Main (main) where

import Campaign.Oracle (markerOracle)
import Campaign.RepairReceipt
  ( RepairBlueprint (..),
    RepairReceipt (..),
    SourceState (..),
    admitReceipt,
    loadRepairBlueprint,
    loadRepairReceipt,
  )
import Control.Monad (forM_)
import Data.List (nub)
import Data.Text qualified as T
import System.Directory (listDirectory)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.FilePath (takeExtension, (</>))

main :: IO ()
main = do
  args <- getArgs
  let dir = case args of
        (d : _) -> d
        [] -> "shikumi-campaign/repairs"
  fs <- nub . filter ((== ".dhall") . takeExtension) <$> listDirectory dir
  let receiptFiles = [f | f <- fs, "receipt" `T.isInfixOf` T.pack f]
  if null receiptFiles
    then do
      putStrLn ("no receipts found in " <> dir)
      exitFailure
    else do
      forM_ receiptFiles $ \f -> do
        putStrLn $ "== " <> f
        rc <- loadRepairReceipt (dir </> f)
        case rc of
          Left err -> fail $ "  load failed: " <> T.unpack err
          Right r -> do
            bp <- loadRepairBlueprint (dir </> (T.unpack (rcBlueprint r) <> ".dhall"))
            case bp of
              Left err -> fail $ "  blueprint load failed: " <> T.unpack err
              Right b -> do
                let oracle = markerOracle
                    result = admitReceipt oracle r
                putStrLn $ "  oracle=" <> T.unpack (rcOracleId r) <> " path=" <> T.unpack (rcPath r) <> " ops=" <> show (length (rcOperations r))
                -- cross-reference: blueprint and receipt must name the same
                -- cell/oracle/path (the receipt answers the blueprint).
                let xref =
                      [ "blueprint name mismatch (receipt names " <> T.unpack (rcBlueprint r) <> ", found " <> T.unpack (rbName b) <> ")"
                      | rcBlueprint r /= rbName b
                      ]
                        <> ["oracle mismatch" | rcOracleId r /= rbOracleId b]
                        <> ["path mismatch" | rcPath r /= rbPath b]
                case (xref, result) of
                  (x, Right ())
                    | null x -> putStrLn "  ADMISSIBLE — re-derived under the oracle: replay reproduces the after-state, diagnostics match, pass-to-fail-to-pass holds"
                    | otherwise -> putStrLn $ "  ADMITTED but blueprint cross-reference fails:\n" <> unlines ("    - " : x)
                  (_, Left fails) ->
                    putStrLn $ "  REJECTED — re-derivation failures:\n" <> T.unpack (T.unlines ("    - " : fails))
                -- negative control (always): tamper the recorded
                -- after-diagnostics; the same trajectory must now be
                -- rejected, because the recorded claim no longer re-derives.
                let tampered =
                      r
                        { rcAfter =
                            SourceState
                              { ssSource = ssSource (rcAfter r),
                                ssDiagnostics = ["alpha.py:2: warning: [W-todo] FOUND-AFTER-TAMPERING"]
                              }
                        }
                case admitReceipt oracle tampered of
                  Right () -> fail "  NEGATIVE CONTROL FAILED — tampered receipt was admitted"
                  Left _ -> putStrLn "  negative control held — tampered after-diagnostics are rejected"
