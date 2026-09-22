{-# LANGUAGE GHC2024 #-}
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
--
-- The checker is deliberately a little meaner than the first corpus: markers
-- inside string literals don't count, unused bindings are recognized by name
-- (not a hard-coded variable), duplicate class definitions are flagged on the
-- /second/ header, and a returned name that was never defined is an error —
-- which the metric treats as voiding the repair, however many warnings it
-- cleared.
module Toy.Fixer.Domain
  ( -- * Sources and diagnostics
    Source (..),
    Diagnostic (..),
    SourcePath,
    showDiagnostic,

    -- * The checker (the toy compiler)
    checkSource,

    -- * The seeded corpus: broken sources and their expected repairs
    corpus,
    sourcesOf,
    pathOf,
    expectedOf,

    -- * Diffing (for observations and review)
    sourceDiff,
  )
where

import Data.Algorithm.Diff (PolyDiff (..), getGroupedDiff)
import Data.Char (isAlpha, isAlphaNum)
import Data.List (sortBy)
import Data.Ord (comparing)
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
-- repair against. @E-@ codes are errors rather than warnings.
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

-- | Scan a source for the toy diagnostics. Real and cheap: this is the ground
-- truth the metric is computed from and the submission guard is enforced
-- against — the LM's opinion never enters the loop.
--
--   * @W-todo@ — a TODO marker outside a string literal;
--   * @W-unused@ — a line carrying the @-- unused@ marker, named;
--   * @W-dup@ — a class header repeating an earlier definition (flagged on
--     the second header: keep the first);
--   * @E-undef@ — @return X@ where @X@ was never defined: an error, and the
--     metric below voids any repair that introduces one.
checkSource :: SourcePath -> Source -> [Diagnostic]
checkSource path (Source body) =
  sortBy (comparing diagLine) (lineDiags ++ dupDiags ++ undefDiags)
  where
    numberedLines = zip [1 ..] (T.lines body)

    lineDiags =
      [ Diagnostic path n code msg
      | (n, raw) <- numberedLines,
        let masked = maskStrings raw,
        (code, msg) <-
          [ ("W-todo", "found a TODO marker")
          | "TODO" `T.isInfixOf` masked
          ]
            ++ [ ("W-unused", "unused binding " <> nm)
               | Just nm <- [unusedName raw]
               ]
      ]

    -- Duplicate class headers: the second and later headers are flagged.
    dupDiags = go [] numberedLines
      where
        go _ [] = []
        go seen ((n, raw) : rest) =
          case className raw of
            Just cname
              | cname `elem` seen ->
                  Diagnostic path n "W-dup" ("duplicate class " <> cname)
                    : go seen rest
              | otherwise -> go (cname : seen) rest
            Nothing -> go seen rest

    -- `return X` where X is not a defined name (identifiers only; literal
    -- returns are skipped).
    undefDiags =
      [ Diagnostic path n "E-undef" ("undefined reference to " <> t)
      | (n, raw) <- numberedLines,
        let stripped = T.strip raw,
        Just rhs <- [T.stripPrefix "return " stripped],
        let t = T.takeWhile (\c -> isAlphaNum c || c == '_') (T.strip rhs),
        isIdent t,
        t `notElem` definedNames
      ]

    -- Names any line defines: the identifier left of the first '='.
    definedNames =
      [nm | (_, raw) <- numberedLines, Just nm <- [definedName raw]]

    isIdent t = not (T.null t) && isAlpha (T.head t)

-- | Mask the contents of double-quoted string spans, so markers inside
-- strings (a TODO in user-visible text, say) don't count.
maskStrings :: Text -> Text
maskStrings = T.pack . go False . T.unpack
  where
    go _ [] = []
    go inQ (c : cs)
      | c == '"' = '"' : go (not inQ) cs
      | inQ = ' ' : go inQ cs
      | otherwise = c : go inQ cs

-- | The name an @-- unused@ marker line declares, if the line carries the
-- marker at all (judged on the masked line, so string content can't fake it).
unusedName :: Text -> Maybe Text
unusedName raw = do
  let masked = maskStrings raw
      stripped = T.strip masked
  (lhs, rest) <- if "-- unused" `T.isInfixOf` stripped then Just (T.breakOn "=" stripped) else Nothing
  guardEq rest
  let nm = T.takeWhile (\c -> isAlphaNum c || c == '_') (T.strip lhs)
  if T.null nm then Nothing else Just nm
  where
    guardEq r = if T.null r then Nothing else Just ()

-- | The name a line defines: the identifier left of the first @=@.
definedName :: Text -> Maybe Text
definedName raw =
  let stripped = T.strip raw
      (lhs, rest) = T.breakOn "=" stripped
   in if T.null rest
        then Nothing
        else
          let nm = T.takeWhile (\c -> isAlphaNum c || c == '_') (T.strip lhs)
           in if T.null nm then Nothing else Just nm

-- | The name a @class@ header declares, if the line is one.
className :: Text -> Maybe Text
className raw = do
  base <- T.stripPrefix "class " (T.strip raw)
  let nm = T.takeWhile (\c -> isAlphaNum c || c == '_') base
  if T.null nm then Nothing else Just nm

-- ---------------------------------------------------------------------------
-- The seeded corpus: broken sources and their expected repairs
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

-- | Harder: both warnings sit on ONE line — one deletion clears two
-- diagnostics of different kinds.
seedSameLine :: Text
seedSameLine =
  T.unlines
    [ "def delta():",
      "    var2 = 5  -- unused  # TODO: wire it in",
      "    return 4"
    ]

fixedSameLine :: Text
fixedSameLine =
  T.unlines
    [ "def delta():",
      "    return 4"
    ]

-- | Harder: three TODOs scattered among lines that must stay, and a
-- definition (@grand@) whose /only/ role is to be referenced by the return —
-- over-deleting it breaks the reference, which voids the repair. (Note
-- @total = 0@ deliberately gets away with deleting it in our toy checker —
-- @total = total + i@ still defines @total@, though a real compiler would
-- flag the uninitialized use. Definitions and references differ.)
seedScatter :: Text
seedScatter =
  T.unlines
    [ "def epsilon():",
      "    # TODO: validate input",
      "    grand = compute()",
      "    total = 0",
      "    for i in range(10):",
      "        # TODO: skip negatives",
      "        total = total + i",
      "    # TODO: cache results",
      "    return grand + total"
    ]

fixedScatter :: Text
fixedScatter =
  T.unlines
    [ "def epsilon():",
      "    grand = compute()",
      "    total = 0",
      "    for i in range(10):",
      "        total = total + i",
      "    return grand + total"
    ]

-- | Harder: a duplicated class. The diagnostic sits on the /second/ header;
-- the minimal fix deletes the duplicate block — and its stray TODO, so
-- deleting the wrong (first) block cannot reach a perfect score.
seedDuplicate :: Text
seedDuplicate =
  T.unlines
    [ "class Widget:",
      "    def size(self):",
      "        return 1",
      "",
      "class Widget:",
      "    def size(self):",
      "        return 2  # TODO: match production"
    ]

fixedDuplicate :: Text
fixedDuplicate =
  T.unlines
    [ "class Widget:",
      "    def size(self):",
      "        return 1",
      ""
    ]

-- | The negative control: a TODO inside a string literal is not a warning.
-- The correct repair is to change nothing at all.
seedString :: Text
seedString =
  T.unlines
    [ "def eta():",
      "    s = \"# TODO: this is just a string\"",
      "    return s"
    ]

fixedString :: Text
fixedString = seedString

-- | The toy corpus: @[(path, broken source, expected fixed source)]@. This is
-- all the \"dataset\" the fixer trains and evaluates against.
corpus :: [(SourcePath, Source, Source)]
corpus =
  [ ("alpha.py", Source seedTodos, Source fixedTodos),
    ("beta.py", Source seedUnused, Source fixedUnused),
    ("gamma.py", Source seedMixed, Source fixedMixed),
    ("delta.py", Source seedSameLine, Source fixedSameLine),
    ("epsilon.py", Source seedScatter, Source fixedScatter),
    ("zeta.py", Source seedDuplicate, Source fixedDuplicate),
    ("eta.py", Source seedString, Source fixedString)
  ]

sourcesOf :: [(SourcePath, Source, Source)] -> [Source]
sourcesOf = map (\(_, s, _) -> s)

pathOf :: (SourcePath, Source, Source) -> SourcePath
pathOf (p, _, _) = p

expectedOf :: (SourcePath, Source, Source) -> Source
expectedOf (_, _, e) = e

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
