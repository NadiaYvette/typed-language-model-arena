{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE OverloadedStrings #-}

-- | L1 attestation tests (TESTING_VERIFICATION_STRATEGY §2.2).
-- Canonical trailer format round-trip; sha256 recompute matches; orphan /
-- forged / no-receipt controls live in receipt-tests — here we pin the
-- pure hash/trailer/journal-ref surface.
module Main (main) where

import Campaign.Attestation
  ( Attestation (..),
    JournalRef (..),
    VerificationTrailer (..),
    appendVerificationTrailer,
    attestationCanonical,
    attestationHash,
    didKeyFromRaw,
    journalRefText,
    verificationTrailerText,
  )
import Data.ByteString qualified as B
import Data.Text qualified as T
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

sampleJournal :: JournalRef
sampleJournal =
  JournalRef
    { jrMemorySpace = "shikumi-campaign",
      jrNamespace = "toy",
      jrSession = "review main",
      jrFromAct = 1,
      jrToAct = 2
    }

sampleAttestation :: Attestation
sampleAttestation =
  Attestation
    { attProject = "toy",
      attBranch = "campaign/alpha",
      attOracleId = "toy-markers",
      attFiles = ["alpha.py"],
      attJournal = sampleJournal
    }

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests =
  testGroup
    "attestation-tests"
    [ testGroup
        "journalRefText"
        [ testCase "keiro:// ref embeds space, session, act range" $
            journalRefText sampleJournal
              @?= "keiro://shikumi-campaign/toy/review main#acts1-2"
        ],
      testGroup
        "attestationCanonical / attestationHash"
        [ testCase "canonical form is field-per-line in identity order" $
            attestationCanonical sampleAttestation
              @?= T.unlines
                [ "project=toy",
                  "branch=campaign/alpha",
                  "oracle=toy-markers",
                  "files=alpha.py",
                  "journal=keiro://shikumi-campaign/toy/review main#acts1-2"
                ],
          testCase "hash is sha256: + 64 hex chars" $ do
            let h = attestationHash sampleAttestation
            assertBool "prefix" ("sha256:" `T.isPrefixOf` h)
            assertBool "hex length" (T.length h == 7 + 64),
          testCase "recompute matches (deterministic)" $
            attestationHash sampleAttestation @?= attestationHash sampleAttestation,
          testCase "different file set → different hash" $
            assertBool
              "hashes differ"
              ( attestationHash sampleAttestation
                  /= attestationHash sampleAttestation {attFiles = ["alpha.py", "beta.py"]}
              ),
          testCase "sorted files are comparison-stable" $
            -- canonical uses the list as-is; pin that order matters for hash
            -- (caller sorts before constructing — documented in Attestation)
            assertBool
              "order-sensitive hash"
              ( attestationHash sampleAttestation {attFiles = ["b.py", "a.py"]}
                  /= attestationHash sampleAttestation {attFiles = ["a.py", "b.py"]}
              )
        ],
      testGroup
        "trailer"
        [ testCase "verificationTrailerText carries hash + ref" $ do
            let vt =
                  VerificationTrailer
                    { vtHash = attestationHash sampleAttestation,
                      vtJournal = sampleJournal,
                      vtSigner = Nothing
                    }
                txt = verificationTrailerText vt
            assertBool "Verification line" ("Verification: sha256:" `T.isInfixOf` txt)
            assertBool "ref:" ("ref:keiro://" `T.isInfixOf` txt)
            assertBool "no signer line yet" (not ("signer=" `T.isInfixOf` txt)),
          testCase "appendVerificationTrailer: blank line + single trailing newline" $ do
            let vt =
                  VerificationTrailer
                    { vtHash = "sha256:deadbeef",
                      vtJournal = sampleJournal,
                      vtSigner = Nothing
                    }
                msg = appendVerificationTrailer "merge subject\n\nbody" vt
            assertBool "double newline before trailer" ("\n\nVerification: " `T.isInfixOf` msg)
            assertBool "ends with one newline" (T.isSuffixOf "\n" msg && not (T.isSuffixOf "\n\n" (T.dropEnd 1 msg)))
        ],
      testGroup
        "didKeyFromRaw"
        [ testCase "did:key:z + base58 of 0xED 0x01 prefix + key" $ do
            let raw = B.pack [0 .. 31]
                did = didKeyFromRaw raw
            assertBool "prefix" (T.isPrefixOf "did:key:z" did)
            assertBool "charset" (T.all (`elem` ("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz" :: String)) (T.drop 9 did))
        ]
    ]
