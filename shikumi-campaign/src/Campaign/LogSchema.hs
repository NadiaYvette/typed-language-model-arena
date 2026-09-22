{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Reserved oracle fact @logSchema@ (Tier 4a, barrier #2).
--
-- Parses a tool log into a structured summary (format, pass/fail counts,
-- named failures) so a TargetManifest can require a schema-shaped log
-- without embedding executable verdict logic. Supported shapes: TAP
-- (proven, kani, cbmc-style @ok@/@not ok@ lines), a JSON object with
-- @passed@/@failed@ counters, and a minimal JUnit @testsuite@ summary.
-- Unknown shapes are an honest parse error — never a silent pass.
module Campaign.LogSchema
  ( LogFormat (..),
    LogSummary (..),
    interpretLogSchema,
    logSchemaOk,
  )
where

import Data.Aeson qualified as Aeson
import Data.Aeson.Types qualified as AesonTypes
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Text.Read (readMaybe)

-- | The wire schema id a manifest may declare (the fact's /name/).
data LogFormat
  = LogTap
  | LogJsonCounters
  | LogJUnit
  deriving stock (Eq, Show)

-- | Parsed summary: format, counts, and the named failures (for baselines).
data LogSummary = LogSummary
  { lsFormat :: !LogFormat,
    lsPassed :: !Int,
    lsFailed :: !Int,
    lsSkipped :: !Int,
    lsNamedFailures :: ![Text]
  }
  deriving stock (Eq, Show)

-- | Interpret @logSchema = Some "tap" | Some "json-counters" | Some "junit"@
-- over a log body. @Nothing@ (fact absent) is the caller's job to skip —
-- this function always interprets when asked.
interpretLogSchema :: Text -> Text -> Either Text LogSummary
interpretLogSchema "tap" body = parseTap body
interpretLogSchema "json-counters" body = parseJsonCounters body
interpretLogSchema "junit" body = parseJUnit body
interpretLogSchema other _ =
  Left ("unknown logSchema fact id: " <> other <> " (supported: tap, json-counters, junit)")

-- | A schema-shaped log passes only when the failed count is zero (named
-- failures feed baselines upstream; this fact is about shape + clean run).
logSchemaOk :: LogSummary -> Bool
logSchemaOk s = lsFailed s == 0

-- ---------------------------------------------------------------------------
-- TAP:  ok 1 - name / not ok 2 - name / 1..N  (YAML diagnostics ignored)
-- ---------------------------------------------------------------------------

parseTap :: Text -> Either Text LogSummary
parseTap body =
  let ls = T.lines body
      oks = [name | l <- ls, Just name <- [tapLine True l]]
      notOks = [name | l <- ls, Just name <- [tapLine False l]]
      plan = [n | l <- ls, Just n <- [tapPlan l]] :: [Int]
      nPass = length oks
      nFail = length notOks
      nSkip =
        length
          [ ()
          | l <- ls,
            "ok" `T.isPrefixOf` T.stripStart l,
            "# skip" `T.isInfixOf` T.toLower l
          ]
   in if nPass + nFail + nSkip == 0 && null plan
        then Left "tap: no ok/not-ok lines and no plan"
        else
          Right
            LogSummary
              { lsFormat = LogTap,
                lsPassed = nPass,
                lsFailed = nFail,
                lsSkipped = nSkip,
                lsNamedFailures = notOks
              }
  where
    -- Strip the TAP point number ("2 - red" → "red") when present.
    stripPoint s = case T.breakOn " - " s of
      (pre, rest)
        | not (T.null rest),
          all (`elem` ("0123456789" :: String)) (T.unpack (T.strip pre)) ->
            T.strip (T.drop 3 rest)
      _ -> T.strip s
    tapLine wantOk l =
      let s = T.stripStart l
       in if wantOk
            then case T.stripPrefix "ok " s of
              Just rest
                | not ("# skip" `T.isInfixOf` T.toLower rest) ->
                    Just
                      ( stripPoint
                          (T.replace "# SKIP" "" (T.replace "# skip" "" rest))
                      )
              _ -> Nothing
            else case T.stripPrefix "not ok " s of
              Just rest -> Just (stripPoint rest)
              Nothing -> Nothing
    tapPlan l =
      case T.stripStart l of
        s | "1.." `T.isPrefixOf` s -> readMaybe (T.unpack (T.drop 2 s))
        _ -> Nothing

-- ---------------------------------------------------------------------------
-- JSON counters: {"passed":N,"failed":M,"skipped":K,"failures":[…]}
-- ---------------------------------------------------------------------------

parseJsonCounters :: Text -> Either Text LogSummary
parseJsonCounters body = case Aeson.eitherDecodeStrict' (TE.encodeUtf8 body) of
  Left err -> Left ("json-counters: " <> T.pack err)
  Right val -> case AesonTypes.parseEither parseCounters val of
    Left err -> Left ("json-counters: " <> T.pack err)
    Right s -> Right s
  where
    parseCounters = AesonTypes.withObject "LogSummary" $ \o -> do
      passed <- o Aeson..:? "passed" Aeson..!= (0 :: Int)
      failed <- o Aeson..:? "failed" Aeson..!= (0 :: Int)
      skipped <- o Aeson..:? "skipped" Aeson..!= (0 :: Int)
      failures <- o Aeson..:? "failures" Aeson..!= ([] :: [Text])
      pure
        LogSummary
          { lsFormat = LogJsonCounters,
            lsPassed = passed,
            lsFailed = failed,
            lsSkipped = skipped,
            lsNamedFailures = failures
          }

-- ---------------------------------------------------------------------------
-- JUnit: first <testsuite … tests=… failures=… errors=… skipped=…> attrs
-- ---------------------------------------------------------------------------

parseJUnit :: Text -> Either Text LogSummary
parseJUnit body =
  case [l | l <- T.lines body, "<testsuite" `T.isInfixOf` l] of
    (tag : _) -> do
      let attrs = parseAttrs tag
          n k d = fromMaybe d (lookup k attrs >>= readMaybe . T.unpack)
      pure
        LogSummary
          { lsFormat = LogJUnit,
            lsPassed = max 0 (n "tests" 0 - n "failures" 0 - n "errors" 0 - n "skipped" 0),
            lsFailed = n "failures" 0 + n "errors" 0,
            lsSkipped = n "skipped" 0,
            lsNamedFailures = [nm | l <- T.lines body, "<testcase" `T.isInfixOf` l, Just nm <- [testcaseFailureName l]]
          }
    [] -> Left "junit: no <testsuite> element"
  where
    -- Split tag body on whitespace-separated key="value" pairs (naive but
    -- sufficient for the first <testsuite …> line; values may not contain
    -- spaces in our fixtures).
    parseAttrs tag =
      [ (k, v)
      | (k0, rest0) <- splitOnSpace (T.dropWhile (/= '<') tag),
        let k = T.dropWhile (== '<') (T.strip k0),
        not (T.null k),
        Just v <- [unquoteValue rest0]
      ]
    splitOnSpace s =
      case T.break (== '=') s of
        (before, eqRest)
          | not (T.null eqRest) ->
              let afterEq = T.drop 1 eqRest
                  (val, rest) = case T.stripPrefix "\"" afterEq of
                    Just quoted ->
                      let (v, r0) = T.break (== '"') quoted
                       in (v, T.drop 1 r0)
                    Nothing ->
                      let (v, r) = T.break (== ' ') afterEq
                       in (v, r)
               in (before, val) : splitOnSpace (T.stripStart rest)
          | otherwise -> [(before, "")]
    unquoteValue v =
      Just $ case T.stripPrefix "\"" =<< T.stripSuffix "\"" (T.strip v) of
        Just inner -> inner
        Nothing -> T.strip v
    testcaseFailureName l =
      case T.breakOn "message=" l of
        (_, rest)
          | not (T.null rest) ->
              let raw = T.drop 8 rest
               in Just (T.strip (T.takeWhile (/= '"') (T.dropWhile (== '"') raw)))
        _ -> Nothing
