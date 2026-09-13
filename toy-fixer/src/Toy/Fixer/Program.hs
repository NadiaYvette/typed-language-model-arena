{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The LM-facing half of the toy fixer: the signature, the program, and the
-- metric.
--
-- The contract with the model is deliberately minimal: read the diagnostics,
-- return the whole repaired file as text. Three deterministic checks wrap it:
--
--   1. /Decode/: the reply must carry a @repaired@ field (a malformed reply is
--      a typed 'ShikumiError', never an exception).
--   2. /Guard/: the repair must be a subset of the original (pure deletions) —
--      'applyRepair' enforces this with the original in scope, and a rejected
--      repair is a typed 'ShikumiError' too, so program-level 'retry' re-asks.
--   3. /Metric/: the checker — not an LM judge — re-scores what survived.
--
-- That's why 'fixSource' is a function of the original 'Source': the ground
-- truth is /bound into the program/, and the same program value serves the
-- demo, the evaluation harness, and (with a different bottom interpreter) a
-- live provider.
module Toy.Fixer.Program
  ( -- * The LM contract
    DiagnosticsIn (..),
    RepairOut (..),
    repairSignature,
    fixSource,
    applyRepair,

    -- * The reported program and its metric
    FixResult (..),
    fixAndReport,
    fixesSource,

    -- * Stub plumbing (offline testing)
    Submission (..),
    buildSubmission,
    stripMarkers,
  )
where

import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)

import Shikumi.Adapter (ToPrompt)
import Shikumi.Combinator ((>>>))
import Shikumi.Eval (Metric, customMetric, mkScore, predictionPrimary)
import Shikumi.Error (ShikumiError (..))
import Shikumi.Module (predict)
import Shikumi.Program (Program, embed)
import Shikumi.Schema (FromModel, ToSchema, Validatable (..))
import Shikumi.Schema.Types (Field (..), unField)
import Shikumi.Signature (Signature, mkSignature)

import Toy.Fixer.Domain
  ( Source (..),
    checkSource,
    sourceText,
  )

import Effectful.Error.Static (throwError)

-- ---------------------------------------------------------------------------
-- The LM contract: diagnostics in, repaired source out
-- ---------------------------------------------------------------------------

newtype DiagnosticsIn = DiagnosticsIn
  { diagnostics :: Field "Compiler diagnostics, one per line" [Text]
  }
  deriving stock (Generic, Show, Eq)
  deriving anyclass (FromModel, ToPrompt)

newtype RepairOut = RepairOut
  { repaired :: Field "The complete repaired source" Text
  }
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToSchema, FromModel, ToPrompt, Validatable)

-- | The signature: minimum edit, whole file back.
repairSignature :: Signature DiagnosticsIn RepairOut
repairSignature =
  mkSignature
    "You fix source files. You are given compiler diagnostics for one file. \
    \Return the complete repaired file with the minimum edit that clears every \
    \diagnostic. Delete the offending lines; do not add, reorder, or reformat \
    \anything else."

-- | Apply the model's repair to the original, enforcing the no-regression
-- guard: the repaired source must be a /subset/ of the original (pure
-- deletions, in order). Invented code or reordered lines are rejected with a
-- typed 'ShikumiError' — data the harness and 'retry' can act on, not a crash.
applyRepair :: Source -> RepairOut -> Either ShikumiError Source
applyRepair (Source orig) (RepairOut (Field new))
  | T.null (T.strip new) = Left (ValidationFailure "the repaired source is empty")
  | isSubsequenceOf (T.lines new) (T.lines orig) =
      Right (Source new)
  | otherwise =
      Left
        ( ValidationFailure
            "the repaired source is not a subset of the original: every line \
            \must appear in order in the original (additions and reordering \
            \are not allowed)"
        )
  where
    isSubsequenceOf [] _ = True
    isSubsequenceOf _ [] = False
    isSubsequenceOf xs'@(x : xs) (y : ys)
      | x == y = isSubsequenceOf xs ys
      | otherwise = isSubsequenceOf xs' ys

-- | The fixer as an ordinary typed 'Program'. The original source — the ground
-- truth — is a plain Haskell argument: it is /bound into the program/, which is
-- exactly how shikumi wants deterministic context to enter the LM path.
fixSource :: Source -> Program DiagnosticsIn RepairOut
fixSource orig =
  predict repairSignature
    >>> embed (\out -> either throwError (\_ -> pure out) (applyRepair orig out))

-- ---------------------------------------------------------------------------
-- The reported program and its metric
-- ---------------------------------------------------------------------------

-- | The program's /reported/ output: what the metric needs in order to be a
-- pure function of the output alone — the original source rides along. The LM
-- contract ('DiagnosticsIn' -> 'RepairOut') is untouched: this record only
-- wraps the program boundary, and the 'beforeSource' field is carried by
-- 'embed' (which renders no schema, so nothing extra reaches the model).
data FixResult = FixResult
  { beforeSource :: !Source,
    result :: !RepairOut
  }
  deriving stock (Generic, Show, Eq)

-- | 'fixSource' plus the report wrapper: one program over a corpus entry.
fixAndReport :: Source -> Program DiagnosticsIn FixResult
fixAndReport orig = fixSource orig >>> embed (\out -> pure (FixResult orig out))

-- | Score = (diagnostics before − diagnostics after) / diagnostics before,
-- computed by the deterministic checker — never by an LM judge. A repair that
-- clears some diagnostics earns partial credit; a failed guard (or any other
-- 'ShikumiError') never reaches the metric — the harness scores it by its
-- failure policy, 0 by default.
fixesSource :: Metric FixResult
fixesSource = customMetric (\_ p -> mkScore (rate (predictionPrimary p)))
  where
    rate (FixResult orig out) =
      let before = count (sourceText orig)
          after = count (unField (repaired out))
       in if before == 0 then bool01 (after == 0) else fromIntegral (before - after) / fromIntegral before
    count t = length (checkSource "input.py" (Source t))
    bool01 True = 1
    bool01 False = 0

-- ---------------------------------------------------------------------------
-- Stub plumbing: the scripted "model" for the offline runs
-- ---------------------------------------------------------------------------

-- | The stub's canned answer: the repaired text. (The stub type is never
-- decoded or encoded — it exists only to be rendered into a marker body.)
newtype Submission = Submission
  { repairedText :: Text
  }
  deriving stock (Generic, Show, Eq)

-- | Render a 'Submission' as the marker-section body the prompt-fallback
-- adapter decodes — the stub LM's reply.
buildSubmission :: Submission -> Text
buildSubmission (Submission body) =
  T.unlines
    [ "[[ ## repaired ## ]]",
      body,
      "[[ ## completed ## ]]"
    ]

-- | Strip marker lines from a rendered submission (so the demo can show the
-- clean text the model "wrote").
stripMarkers :: Text -> Text
stripMarkers =
  T.unlines
    . filter (\l -> not ("[[ ##" `T.isPrefixOf` T.stripStart l && "## ]]" `T.isSuffixOf` T.stripStart l))
    . T.lines
