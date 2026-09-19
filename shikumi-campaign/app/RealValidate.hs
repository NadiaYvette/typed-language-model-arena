{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Offline validation of the real-cell verdict classifier: run
-- 'classifyCellLog' over a directory of historical matrix logs and print
-- one verdict per log. Point it at a past run's output directory (e.g.
-- ~/src/pgcl/matrix-80cell-20260529-170150) and compare against the record
-- — the classifier's verdicts must reproduce what actually happened, or
-- the live mode's scoreboard is not trustworthy.
--
-- Usage: real-validate [LOG_DIR]
module Main (main) where

import Campaign.Real (classifyCellLogArch)
import Data.List (sort)
import Data.Text qualified as T
import System.Directory (listDirectory)
import System.Environment (getArgs)
import System.FilePath ((</>), takeExtension, takeFileName)

main :: IO ()
main = do
  args <- getArgs
  let dir = case args of
        (d : _) -> d
        [] -> "/home/nyc/src/pgcl/matrix-80cell-20260529-170150"
  fs <- listDirectory dir
  let logs = sort (filter ((== ".log") . takeExtension) fs)
  results <-
    mapM
      ( \f -> do
          b <- readFile (dir </> f)
          let arch = T.pack (takeWhile (/= '_') (takeFileName f))
          pure (f, classifyCellLogArch arch (T.pack b))
      )
      logs
  mapM_ (\(f, v) -> putStrLn (takeFileName f <> ": " <> T.unpack v)) results
  let tally k = show (length [() | (_, v) <- results, T.unpack v == k]) <> " " <> k
  putStrLn ("=== " <> show (length results) <> " log(s): " <> intercalate ", " [tally "passed", tally "passed-waived", tally "failed", tally "skipped"])
  where
    intercalate sep (x : xs) = x ++ concatMap (sep ++) xs
    intercalate _ [] = []
