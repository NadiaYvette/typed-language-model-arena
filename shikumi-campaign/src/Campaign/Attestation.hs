{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Phase 6 attestation record (docs/ATTESTATION_MAPPING_DRAFT.md, step 1).
--
-- A campaign attestation is the signed-verification receipt bound to an
-- approved merge commit. Per the resolved design:
--
--   * it RIDES as a git commit trailer on the merge commit (Q1 — heartwood
--     round-trips external trailers in the message's last paragraph),
--   * the trailer is a POINTER, not the record: it carries the attestation
--     hash and the self-describing journal reference (Q2),
--   * the full record is re-derived by the verifier from the journal +
--     checked-in receipts — invariant #4: the oracle judges, the attestation
--     is evidence, never a verdict,
--   * within one identity (project, branch, oracle, file set, journal ref)
--     a newer attestation supersedes an older one by the merge commit's
--     committer date (Q3); no revocation records.
--
-- The attested time is deliberately NOT in the hashed canonical form: the
-- trailer is written as the merge commit is being made, so anything that
-- only exists afterwards (the merge commit's hash, its exact committer
-- timestamp) cannot be in what is signed. The committer date is public at
-- exactly the place the trailer sits, and it is the Q3 supersede key.
module Campaign.Attestation
  ( -- * The record
    Attestation (..),
    JournalRef (..),
    journalRefText,
    attestationCanonical,
    attestationHash,
    didKeyFromRaw,

    -- * Trailer emission (Q1)
    VerificationTrailer (..),
    verificationTrailerText,
    appendVerificationTrailer,
  )
where

import Crypto.Hash.SHA256 (hash)
import Data.Aeson (ToJSON (..), object, (.=))
import Data.Base16.Types (extractBase16)
import Data.ByteString qualified as B
import Data.ByteString.Base16 (encodeBase16')
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding (decodeUtf8, encodeUtf8)
import GHC.Generics (Generic)

-- | The Kioku/Keiro reference an attestation is replayed from. Self-
-- describing (Q2): the memory space, the (sanitized) project namespace and
-- the deterministic verdict-session name are embedded directly — no uuid,
-- no hash, no side lookup table. The session is the one 'journalVerdict'
-- creates for the verdict ("review <branch>" in the project's review
-- namespace), so the ref names the session it will describe; the act range
-- is the verdict session's fix turns.
data JournalRef = JournalRef
  { -- | the campaign memory space id ("shikumi-campaign")
    jrMemorySpace :: !Text,
    -- | the sanitized project namespace
    jrNamespace :: !Text,
    -- | the fix-session name ("review <branch>")
    jrSession :: !Text,
    -- | first fix turn of the verdict session (1)
    jrFromAct :: !Int,
    -- | last fix turn of the verdict session (2)
    jrToAct :: !Int
  }
  deriving stock (Eq, Show, Generic)

-- | The keiro:// reference string: the trailer's @ref:@ value and the
-- journal= line of the canonical form, so a verifier reading one can replay
-- the other.
journalRefText :: JournalRef -> Text
journalRefText j =
  "keiro://"
    <> jrMemorySpace j
    <> "/"
    <> jrNamespace j
    <> "/"
    <> jrSession j
    <> "#acts"
    <> T.pack (show (jrFromAct j))
    <> "-"
    <> T.pack (show (jrToAct j))

-- | The attestation record: one identity per approved merge of one branch.
-- Field order is identity order; 'attFiles' is sorted so the file set is
-- comparison-stable.
data Attestation = Attestation
  { attProject :: !Text,
    attBranch :: !Text,
    attOracleId :: !Text,
    attFiles :: ![Text],
    attJournal :: !JournalRef
  }
  deriving stock (Eq, Show, Generic)

-- | The canonical form the hash is computed over: one field per line in
-- identity order. A verifier recomputes it from git (project, branch, the
-- merged file set), the gate's oracle, and the trailer's own ref — every
-- input is public where the trailer sits.
attestationCanonical :: Attestation -> Text
attestationCanonical a =
  T.unlines
    [ "project=" <> attProject a,
      "branch=" <> attBranch a,
      "oracle=" <> attOracleId a,
      "files=" <> T.intercalate "," (attFiles a),
      "journal=" <> journalRefText (attJournal a)
    ]

didKeyFromRaw :: B.ByteString -> Text
didKeyFromRaw raw32 = "did:key:z" <> T.pack (b58encode (B.singleton 0xED <> B.singleton 0x01 <> raw32))

b58encode :: B.ByteString -> String
b58encode bs =
  let leadZeros = length (takeWhile (== 0) (B.unpack bs))
      go b
        | B.null b = ""
        | otherwise =
            let iv = toInt b
                (q, r) = iv `divMod` 58
             in go (fromInt q) ++ [b58chars !! fromIntegral r]
      toInt :: B.ByteString -> Integer
      toInt = foldl' (\acc x -> acc * 256 + fromIntegral x) 0 . B.unpack
      fromInt :: Integer -> B.ByteString
      fromInt n
        | n <= 0 = B.empty
        | otherwise = B.cons (fromIntegral (n `mod` 256)) (fromInt (n `div` 256))
      b58first = case b58chars of
        c : _ -> c
        [] -> '1'
   in take leadZeros (replicate leadZeros b58first) <> go (B.dropWhile (== 0) bs)

b58chars :: String
b58chars = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"

-- | SHA-256 of the canonical form, hex-encoded, prefixed `sha256:` — the
-- value the `Verification:` trailer carries.
attestationHash :: Attestation -> Text
attestationHash a =
  "sha256:" <> decodeUtf8 (extractBase16 . encodeBase16' . hash . encodeUtf8 $ attestationCanonical a)

-- | The trailer block appended to the merge commit message (Q1). Token
-- charset (heartwood `Token::try_from`): alphanumerics + `-` only, so
-- `Verification` is a legal token; the value splits on the FIRST `": "`
-- which is why the hash keeps its `sha256:` prefix inside the value. The
-- signer (the campaign's `did:key`) will be a second line under the same
-- token (step 3 — DID signing); heartwood keeps multiple values per token.
data VerificationTrailer = VerificationTrailer
  { -- | 'attestationHash'
    vtHash :: !Text,
    vtJournal :: !JournalRef,
    -- | the campaign's did:key (None until step 3)
    vtSigner :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)

verificationTrailerText :: VerificationTrailer -> Text
verificationTrailerText vt =
  T.unlines
    ( "Verification: " <> vtHash vt <> " ref:" <> journalRefText (vtJournal vt)
        : maybe [] (\s -> ["Verification: signer=" <> s]) (vtSigner vt)
    )

-- | Append the trailer block to a commit message: blank line separator,
-- trailer lines, single trailing newline — the exact last-paragraph shape
-- heartwood's `parse_body` recognises as a trailer block (and whose
-- `Display` impl round-trips verbatim).
appendVerificationTrailer :: Text -> VerificationTrailer -> Text
appendVerificationTrailer msg vt =
  T.stripEnd msg <> "\n\n" <> verificationTrailerText vt <> "\n"

instance ToJSON Attestation where
  toJSON a =
    object
      [ "project" .= attProject a,
        "branch" .= attBranch a,
        "oracle" .= attOracleId a,
        "files" .= attFiles a,
        "journal" .= journalRefText (attJournal a),
        "hash" .= attestationHash a
      ]

instance ToJSON JournalRef where
  toJSON j =
    object
      [ "memorySpace" .= jrMemorySpace j,
        "namespace" .= jrNamespace j,
        "session" .= jrSession j,
        "fromAct" .= jrFromAct j,
        "toAct" .= jrToAct j
      ]
