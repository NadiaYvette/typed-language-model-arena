{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The task layer of the codegen driver: what a change task is, what the
-- model is asked to produce (one exact-match replacement edit), and the
-- deterministic guards that decide whether the model's edit may touch the
-- file.
--
-- Design rules, learned from the toy-fixer and scaled up here:
--
--   * the model never issues commands — it returns /data/ (a replacement
--     edit) we can check before anything happens;
--   * the edit's @old@ block must identify exactly one place in the target
--     file — a stale plan cannot corrupt anything, and model-invented context
--     cannot apply. Exact-once matching is deliberately a /guard/, not a
--     quality metric: zero or several matches is a model mistake we surface
--     as a typed error (and @retry@ re-asks) rather than a heuristic guess;
--   * WIRE-FORMAT CONSTRAINT (discovered by this demo): the marker fallback
--     adapter strips each section's edge whitespace, so @old@ arrives without
--     its first line's indentation (interior lines keep theirs) and @new@
--     likewise. Matching is therefore modulo edge whitespace, and the
--     replacement's first line inherits the replaced line's indentation — a
--     deterministic convention stated in the prompt; interior lines of @new@
--     are applied verbatim;
--   * the wire format is all scalars (four marker sections) — no nested
--     records — so the fallback adapter decodes it robustly;
--   * a change needing several edits is /several tasks/ (or composed program
--     stages), not one mega-prompt: each edit stays independently guardable,
--     and the batch is exactly what the evaluation harness drives.
module Shikumi.Coder.Task
  ( -- * Code facts and tasks
    CodeFact (..),
    CodeTask (..),
    mkCodeTask,
    codeFactLines,

    -- * The model's edit (one exact-match replacement)
    PatchPlan (..),

    -- * Application: guards first, then the (pure) edit
    EditFailure (..),
    renderEditFailure,
    applyPlan,
    occurrences,

    -- * Diffing (for review and tests)
    sourceDiff,
  )
where

import Data.Algorithm.Diff (PolyDiff (..), getGroupedDiff)
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)
import Shikumi.Adapter (ToPrompt)
import Shikumi.Schema (FromModel, ToSchema, Validatable (..))
import Shikumi.Schema.Types (Field (..), unField)

-- ---------------------------------------------------------------------------
-- Code facts and tasks
-- ---------------------------------------------------------------------------

-- | A deterministic fact about the code, extracted by a real tool (here: a
-- grep over options.m). Ground truth in; the model is never asked to guess
-- what the code contains.
data CodeFact = CodeFact
  { factPath :: !Text,
    factPattern :: !Text,
    factMatches :: ![(Int, Text)] -- (1-based line, text)
  }
  deriving stock (Generic, Show, Eq)

-- | One change task: a fact, why it should change, what "correct" means, and
-- the current file contents the edit will be applied to (read from the
-- worktree in real use; a fixture in tests).
data CodeTask = CodeTask
  { taskPath :: !Text,
    taskTitle :: !Text,
    taskWhy :: !Text,
    taskFact :: !CodeFact,
    taskFile :: !Text
  }
  deriving stock (Generic, Show, Eq)

mkCodeTask :: Text -> Text -> Text -> CodeFact -> Text -> CodeTask
mkCodeTask = CodeTask

-- | The numbered fact lines, as the model sees them.
codeFactLines :: CodeFact -> Text
codeFactLines (CodeFact _ _ ms) =
  T.unlines [T.pack (show n) <> ": " <> l | (n, l) <- ms]

-- ---------------------------------------------------------------------------
-- The model's edit (one exact-match replacement)
-- ---------------------------------------------------------------------------

-- | One replacement: @ppOld@ (must be non-empty, and match exactly once) is
-- replaced by @ppNew@ (empty = deletion). Insertion is expressed by anchoring
-- on a real line and keeping it in @ppNew@, which keeps every edit exactly
-- checkable.
data PatchPlan = PatchPlan
  { ppOld :: !(Field "The exact existing lines to replace, copied verbatim" Text),
    ppNew :: !(Field "The replacement lines (empty = delete those lines)" Text),
    ppWhy :: !(Field "Why this edit implements the change" Text),
    ppNote :: !(Field "One sentence on the overall change" Text)
  }
  deriving stock (Generic, Show, Eq)
  deriving anyclass (ToSchema, FromModel, ToPrompt)

-- | Structural pre-checks that need no file: an edit must anchor on real
-- lines. (The file-dependent exact-once check lives in 'applyPlan', where the
-- target text is in scope — so the failure message can name the count.)
instance Validatable PatchPlan where
  validate p
    | T.null (T.strip (unField (ppOld p))) = Left (renderEditFailure EditUnanchored)
    | otherwise = Right p

-- ---------------------------------------------------------------------------
-- Application: guards first, then the (pure) edit
-- ---------------------------------------------------------------------------

-- | Why an edit could not be applied. All of these are /model mistakes/
-- surfaced as data, not exceptions.
data EditFailure
  = -- | @old@ matched no line in the file.
    EditNoMatch
  | -- | @old@ matched more than once — ambiguous.
    EditAmbiguous !Int
  | -- | @old@ is empty: an unanchored insertion.
    EditUnanchored
  deriving stock (Generic, Show, Eq)

renderEditFailure :: EditFailure -> Text
renderEditFailure = \case
  EditNoMatch -> "the old text matched no line in the file (stale or invented context)"
  EditAmbiguous k -> "the old text matched " <> T.pack (show k) <> " places; it must be unique"
  EditUnanchored -> "an edit must replace existing lines; anchor insertions on a real line"

-- | Lines compare equal after trimming — required, not leniency: the marker
-- wire strips each section's edge whitespace (see the module header), so the
-- model's @old@ block arrives without its first line's indentation. The
-- exact-once count still pins the position: interior lines compare trimmed
-- too, but the block as a whole must identify one place, and the applied
-- @new@ text's interior lines are used verbatim.
sameLine :: Text -> Text -> Bool
sameLine a b = T.strip a == T.strip b

-- | Count occurrences of a block of lines in a file. Empty pattern: 0.
occurrences :: [Text] -> [Text] -> Int
occurrences [] _ = 0
occurrences pat haystack =
  length [() | i <- [0 .. length haystack - length pat], matchAt i]
  where
    matchAt i = and (zipWith sameLine pat (drop i haystack))

-- | Apply the plan's single replacement under the guards. Left: guard
-- failure (a typed 'ShikumiError' upstream; @retry@ re-asks).
applyPlan :: Text -> PatchPlan -> Either EditFailure Text
applyPlan fileText (PatchPlan (Field o) (Field n) _ _) =
  if T.null (T.strip o)
    then Left EditUnanchored
    else case [j | j <- [0 .. length ls - length pat], matchAt j] of
      [] -> Left EditNoMatch
      [j] -> Right (T.unlines (take j ls ++ newLines j ++ drop (j + length pat) ls))
      ks -> Left (EditAmbiguous (length ks))
  where
    ls = T.lines fileText
    pat = T.lines o
    matchAt j = and (zipWith sameLine pat (drop j ls))
    -- The wire stripped the replacement's leading whitespace, so the first
    -- line inherits the replaced line's indentation (a convention the prompt
    -- states); interior lines are the model's verbatim. An empty @new@ is a
    -- deletion.
    newLines j = case T.lines n of
      [] -> []
      (l : rest) -> (indentOf (ls !! j) <> T.stripStart l) : rest
    indentOf = T.takeWhile (== ' ')

-- ---------------------------------------------------------------------------
-- Diffing (for review and tests)
-- ---------------------------------------------------------------------------

-- | A uniform unified-ish diff, for review output and expected-vs-actual
-- diagnostics: exactly what the edit changed and nothing else.
sourceDiff :: Text -> Text -> Text
sourceDiff before after =
  T.intercalate "\n" (concatMap renderGroup (getGroupedDiff (T.lines before) (T.lines after)))
  where
    renderGroup = \case
      First ls' -> map ("- " <>) ls'
      Second ls' -> map ("+ " <>) ls'
      Both ls' _ -> map ("  " <>) ls'
