{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Reserved oracle fact @proofHygiene@ (Tier 4a, barrier #2).
--
-- Scans a proof/log body for Lean/Isabelle hygiene violations the fact
-- name promises: @sorryAx@, @Admitted@, and unexpected @axiom@ declarations.
-- The interpreter owns the verdict (invariant #4): a TargetManifest may
-- declare @proofHygiene = Some "lean-sorry"@ as a /fact id/, but interpreting
-- the fact is always this module's job — never the manifest's, never an LLM's.
module Campaign.ProofHygiene
  ( ProofHygieneFinding (..),
    ProofHygieneVerdict (..),
    interpretProofHygiene,
    proofHygieneOk,
  )
where

import Data.Text (Text)
import Data.Text qualified as T

-- | One hygiene violation: the 1-based line, the matched pattern, and the
-- stripped excerpt (for the journal / driver log).
data ProofHygieneFinding = ProofHygieneFinding
  { phLine :: !Int,
    phPattern :: !Text,
    phExcerpt :: !Text
  }
  deriving stock (Eq, Show)

-- | Clean means zero findings. Dirty is never \"maybe\" — the scan is total.
data ProofHygieneVerdict
  = ProofHygieneClean
  | ProofHygieneDirty ![ProofHygieneFinding]
  deriving stock (Eq, Show)

-- | Patterns that invalidate a \"hygienic\" proof. @sorryAx@ is Lean's
-- internal name for @sorry@'s axiom; @Admitted@ is Coq/Lean admission;
-- a bare @axiom@ /@constant ... : ...@ declaration is unexpected when the
-- target fact claims a closed proof — kept narrow so a comment mentioning
-- \"axiom\" in prose does not dirty a clean log (the excerpt still shows the
-- line so an operator can judge a false positive).
hygienePatterns :: [(Text, Text)]
hygienePatterns =
  [ ("sorryAx", "sorryAx"),
    ("Admitted", "Admitted"),
    ("admit", "admit"),
    ("axiom ", "axiom")
  ]

-- | Interpret a @proofHygiene@ fact over a log/proof body. Line-oriented;
-- @sorry@ alone (without @sorryAx@) is left to the target's own exit/markers
-- floor — this fact is the hygiene scan, not a replacement for the rung.
interpretProofHygiene :: Text -> ProofHygieneVerdict
interpretProofHygiene body =
  case [ ProofHygieneFinding n pat (T.strip line)
       | (n, line) <- zip [1 ..] (T.lines body),
         (pat, needle) <- hygienePatterns,
         needle `T.isInfixOf` line
       ] of
    [] -> ProofHygieneClean
    fs -> ProofHygieneDirty fs

-- | The boolean the ladder rung folds to (for exit × marker × fact gates).
proofHygieneOk :: ProofHygieneVerdict -> Bool
proofHygieneOk ProofHygieneClean = True
proofHygieneOk (ProofHygieneDirty _) = False
