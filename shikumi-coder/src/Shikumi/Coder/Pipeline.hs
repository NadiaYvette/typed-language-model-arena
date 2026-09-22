{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The shikumi pipeline for AI codegen over a real codebase.
--
-- Three stages, composed with '>>>' into one inspectable program:
--
--   1. @analyze@ is /not/ a model call: the task already carries a
--      deterministic 'CodeFact' extracted by a real tool. Ground truth enters
--      the pipeline as data, the way toy-fixer bound the original source in.
--   2. @propose@ is the single model call: given the fact and the policy,
--      produce a 'PatchPlan' (one exact-match replacement edit, all scalar
--      fields).
--   3. @apply@ is /not/ a model call either: 'applyPlan' enforces the guards
--      (exact-once matching) and fails with a typed 'ShikumiError' carrying
--      the specific 'EditFailure'.
--
-- 'coder' wraps the whole thing in @retry 3@: a guard failure or a decode
-- failure re-asks the model. The offline wiring's retry is blind (the stub
-- answers correctly on any attempt); the demo shows the /informed/ variant by
-- scripting a failing first turn and appending 'failureReport' to the
-- rendered request on the second — which is the entire trick behind making
-- exact-match patch application work with real models.
module Shikumi.Coder.Pipeline
  ( -- * The program
    coder,
    coderOnce,

    -- * Signatures and I/O types
    ProposeIn (..),
    proposeSignature,
    PatchResult (..),

    -- * Failure feedback (the informed-retry payload)
    failureReport,
  )
where

import Data.Text (Text)
import Data.Text qualified as T
import Effectful.Error.Static (throwError)
import GHC.Generics (Generic)
import Shikumi.Adapter (ToPrompt)
import Shikumi.Coder.Task
  ( CodeTask (..),
    EditFailure (..),
    PatchPlan (..),
    applyPlan,
    renderEditFailure,
  )
import Shikumi.Combinator (retry, (>>>))
import Shikumi.Error (ShikumiError (..))
import Shikumi.Module (predict)
import Shikumi.Program (Program, embed)
import Shikumi.Schema (FromModel)
import Shikumi.Schema.Types (Field (..))
import Shikumi.Signature (Signature, mkSignature)

-- ---------------------------------------------------------------------------
-- Signatures and I/O types
-- ---------------------------------------------------------------------------

-- | Input to the propose stage: the task and its fact, pre-rendered.
data ProposeIn = ProposeIn
  { piPath :: !(Field "File to edit" Text),
    piTitle :: !(Field "Change requested" Text),
    piWhy :: !(Field "Why this change is correct" Text),
    piFact :: !(Field "The relevant lines, verbatim from the file (with line numbers)" Text)
  }
  deriving stock (Generic, Show, Eq)
  deriving anyclass (FromModel, ToPrompt)

-- | The pipeline's output: the applied result plus the plan for review.
data PatchResult = PatchResult
  { prFile :: !(Field "The file after the change" Text),
    prPlan :: !PatchPlan,
    prTask :: !CodeTask
  }
  deriving stock (Generic, Show, Eq)

-- | The policy the model is asked to follow. Deliberately close to unified
-- diff conventions the model already knows — but exact-match, no fuzz.
proposeSignature :: Signature ProposeIn PatchPlan
proposeSignature =
  mkSignature
    "You are a careful code editor. You are shown relevant lines of one file, \
    \verbatim, with line numbers. Produce ONE minimal edit: the exact existing \
    \lines to replace and their replacement. The old lines must occur exactly \
    \once in the file. Indentation is supplied by the harness: give the first \
    \line of each block unindented, and keep interior lines verbatim. Do not \
    \invent context, do not reorder code, do not reformat anything you are \
    \not changing."

-- ---------------------------------------------------------------------------
-- The program
-- ---------------------------------------------------------------------------

-- | One pass: propose, then apply under guard. Guard or decode failures are
-- typed 'ShikumiError's.
coderOnce :: CodeTask -> Program ProposeIn PatchResult
coderOnce task =
  propose >>> applyStage
  where
    propose = predict proposeSignature
    applyStage =
      embed $ \plan -> do
        newText <- either (throwError . planError) pure (applyPlan (taskFile task) plan)
        pure (PatchResult (Field newText) plan task)
    planError f =
      ValidationFailure ("patch plan rejected: " <> renderEditFailure f)

-- | The retry payload: what a driver appends to the rendered request when a
-- pass fails, so the model's second attempt is informed by the specific
-- failure rather than re-rolled blind.
failureReport :: EditFailure -> Text
failureReport f =
  T.unlines
    [ "Your previous patch plan was rejected: " <> renderEditFailure f,
      "Copy the old lines from the file as shown (first line unindented; ",
      "interior lines verbatim) and keep the replacement minimal."
    ]

-- | The full driver: up to three attempts. Offline, the stub answers
-- correctly on any attempt, so this equals 'coderOnce' there; with a real
-- model the typed guard failures re-ask.
coder :: CodeTask -> Program ProposeIn PatchResult
coder task = retry 3 (coderOnce task)
