{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | The domain of the toy code fixer: what a source file is, what a diagnostic
-- is, and the /deterministic/ parts of the pipeline — the seeded corpus, the
-- checker, and the diff. Everything here is pure Haskell: no LM, no effects.
--
-- The design keeps the LM out of the write path entirely (shikumi tools are
-- deliberately confined to the @(LLM, Error ShikumiError)@ row — no @IOE@):
-- the model submits /whole-file sources/, and this module owns the ground
-- truth — rejecting any submission that loses a fix or changes a line it
-- shouldn't.
module Toy.Fixer.Domain
  ( -- * Sources and diagnostics
    Source (..),
    Diagnostic (..),
    SourcePath,
    showDiagnostic,

    -- * The checker (the toy compiler)
    checkSource,

    -- * The seeded corpus: three broken sources, each fixable in one turn
    corpus,
    sourcesOf,
    pathOf,
    expectedOf,

    -- * Diffing (for observations and review)
    sourceDiff,
  )
where

import Data.Algorithm.Diff (PolyDiff (..), getGroupedDiff)
import Data.Text (Text)
import Data.Text qualified as T
import GHC.Generics (Generic)

-- ---------------------------------------------------------------------------
-- Sources and diagnostics
-- ---------------------------------------------------------------------------

-- | A source file under repair.
newtype Source = Source {sourceText :: Text}
  deriving stock (Generic, Show, Eq)

type SourcePath = Text

-- | One complaint from the toy compiler, in the fixed
-- @\<file\>:\<line\>: warning: [W-code] message@ shape the model is asked to
-- repair against.
data Diagnostic = Diagnostic
  { diagPath :: !SourcePath,
    diagLine :: !Int,
    diagCode :: !Text,
    diagMsg :: !Text
  }
  deriving stock (Generic, Show, Eq)

showDiagnostic :: Diagnostic -> Text
showDiagnostic (Diagnostic p l c m) =
  p <> ":" <> T.pack (show l) <> ": warning: [" <> c <> "] " <> m

-- ---------------------------------------------------------------------------
-- The checker: the deterministic "compiler" of the toy
-- ---------------------------------------------------------------------------

-- | Scan a source for the toy warnings. Real and cheap: this is the ground
-- truth the metric is computed from and the submission guard is enforced
-- against — the LM's opinion never enters the loop.
checkSource :: SourcePath -> Source -> [Diagnostic]
checkSource path (Source body) =
  [ Diagnostic path n code (msgFor code)
  | (n, line) <- zip [1 ..] (T.lines body),
    Just code <- [warningOf line]
  ]
  where
    warningOf line
      | "TODO" `T.isInfixOf` line = Just "W-todo"
      | "var1" `T.isInfixOf` line, "-- unused" `T.isSuffixOf` line = Just "W-unused"
      | otherwise = Nothing

    msgFor = \case
      "W-todo" -> "found a TODO marker"
      "W-unused" -> "unused binding var1"
      c -> "unknown warning code " <> c

-- ---------------------------------------------------------------------------
-- The seeded corpus: three broken sources, three expected fixed sources
-- ---------------------------------------------------------------------------

-- | Two TODO lines in a row: the minimal diff removes both.
seedTodos :: Text
seedTodos =
  T.unlines
    [ "def alpha():",
      "    # TODO: implement alpha",
      "    # TODO: also handle the edge case",
      "    return 1"
    ]

fixedTodos :: Text
fixedTodos =
  T.unlines
    [ "def alpha():",
      "    return 1"
    ]

-- | One unused binding: the minimal diff deletes the marked line.
seedUnused :: Text
seedUnused =
  T.unlines
    [ "def beta():",
      "    var1 = 9  -- unused",
      "    return 2"
    ]

fixedUnused :: Text
fixedUnused =
  T.unlines
    [ "def beta():",
      "    return 2"
    ]

-- | The mixed case: one TODO and one unused binding, two kinds in one file.
seedMixed :: Text
seedMixed =
  T.unlines
    [ "def gamma():",
      "    var1 = 3  -- unused",
      "    # TODO: check bounds",
      "    return 3"
    ]

fixedMixed :: Text
fixedMixed =
  T.unlines
    [ "def gamma():",
      "    return 3"
    ]

-- | The toy corpus: @[(path, broken source, expected fixed source)]@. This is
-- all the \"dataset\" the fixer trains and evaluates against.
corpus :: [(SourcePath, Source, Source)]
corpus =
  [ ("alpha.py", Source seedTodos, Source fixedTodos)
  , ("beta.py", Source seedUnused, Source fixedUnused)
  , ("gamma.py", Source seedMixed, Source fixedMixed)
  ]

sourcesOf :: [(SourcePath, Source, Source)] -> [Source]
sourcesOf = map (\(_, s, _) -> s)

pathOf :: (SourcePath, Source, Source) -> SourcePath
pathOf (p, _, _) = p

expectedOf :: (SourcePath, Source, Source) -> Source
expectedOf = \(_, _, e) -> e

-- ---------------------------------------------------------------------------
-- Diffing (for observations and review)
-- ---------------------------------------------------------------------------

-- | A uniform unified-ish diff, computed from the grouped line diff. Used for
-- the observation a model (or a human reviewer) reads: exactly what the
-- repair changed and nothing else.
sourceDiff :: Source -> Source -> Text
sourceDiff (Source before) (Source after) =
  T.intercalate "\n" (concatMap renderGroup (getGroupedDiff (T.lines before) (T.lines after)))
  where
    renderGroup = \case
      First ls -> map ("- " <>) ls
      Second ls -> map ("+ " <>) ls
      Both ls _ -> map ("  " <>) ls
