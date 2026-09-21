# Phase 6 Draft — Mapping seihou migration receipts onto Radicle signed verification attestations

- Status: **DRAFT (Track 10, milestone 5)** — design mapping, no code
- Date: 2026-09-21
- Upstream substrate: `seihou` v0.8.0.0 (Nadeem Bitar, BSD-3-Clause), ADRs 0001/0002/0003/0007/0011
- Phase 6 target (CAMPAIGN_GENERALIZATION.md): "Emit signed cryptographic verification receipts to Radicle seed nodes."
- Campaign identities: `did:key:z6Mkv2YCY2vx7ax92q8RzmPJLQv2x2cpEaFDV6vn7FaoFzB8`; repo `rad:z3sERP1qYmgKUQzWwhquEnzFJu7fj`

## 1. The alignment

Seihou's receipt model and the campaign's review-gate model are the same shape, and that shape is exactly what invariant #4 requires:

| Seihou (ADR 0011) | Campaign (milestone 3, commit `198591d`) |
| --- | --- |
| A migration receipt asserts **an edge has been attended to** — a claim about the project, not a verdict | A `RepairReceipt` records the pass→fail→pass trajectory — **evidence, never a verdict** |
| The receipt stops an edge re-running; it does not prove the build passes | A receipt is admissible only because `approveBranch`'s `CellOracle` **re-verifies** every changed file |
| Admissibility = identity match + receipt re-derivation | Admissibility = `admitReceipt` re-derives every claim (replay byte-exactness, diagnostics re-run, faithful deletions) under the named oracle |
| The two ways of establishing a receipt (earned / marked) are deliberately indistinguishable once written — and an assertion is *not* verified | Stricter still: the campaign has only the earned path — oracle re-derivation is the sole establishment mechanism |

The mapping below takes seihou's provenance machinery — the part that says *how much of a claim you can actually prove, honestly* — and re-expresses it for the campaign's attestation seam.

## 2. Receipt identity (from ADR 0002)

Seihou identity = origin URL + artifact name; a receipt for a blueprint migration edge is identified by (owning blueprint origin+name, edge from, edge to) — deliberately excluding the blueprint's own version and the timestamp, "because an edge is the same edge no matter which release declared it." Two records of the same work are the same record only under that identity; a wrong guess "matches nothing — worse than no receipt, because it looks like one."

Campaign analogue — the identity of a repair attestation:

- **owning blueprint origin + name**: the campaign repo identity (`rad:z3sERP1qYmgKUQzWwhquEnzFJu7fj`) + the blueprint name (`alpha-todo-strip`)
- **edge from → to**: the before-state identity → after-state identity, where state identity is the **SHA-256 of the source bytes** recorded in the receipt (before-state bytes are fixed by the blueprint; after-state bytes are re-derived by replay — the hash is a re-derivation output, not an assertion)
- **oracle id**: the named `CellOracle` that judges admissibility (`toy-markers`)

Version and timestamp are excluded from identity for the same reason seihou excludes them: the same repair re-run under a newer oracle build is the *same* attestation if the state identities match. A receipt filed under a different oracle id or a different before-state hash matches nothing and is refused.

## 3. Trust levels (from ADR 0002's three-constructor sum)

Seihou models provenance as a sum — `RemoteOrigin` (git URL + name: provable), `ProjectOrigin` (project-relative path: self-identifying), `LocalOrigin` (name only: **honest "unverifiable"**) — and refuses to fabricate a URL, because "fabricating a URL for such an artifact would be a lie that later verification would act on."

Campaign analogue — where the attestation was produced:

- **journal-origin** (strongest): the repair session's acts are present in the append-only Keiro journal (the campaign's equivalent of the install cache's `.seihou-origin.json`). The attestation cites journal stream + act range; a verifier replays against the journal to re-establish the trajectory.
- **repo-origin**: the blueprint + receipt are checked in to the campaign repo (its ADR 0001 — machine-independent, reviewable artifact). Provenance is the checked-in bytes; weaker than journal-origin because the trajectory was not observed, but the *claims* are still re-derivable.
- **local-origin** (name only, honest): a receipt authored outside both the journal and the repo. **Verifiers must report this as `UNVERIFIABLE`, never as `assumed valid`** — seihou's exact rule, and the one that keeps the attestation seam from silently laundering unreviewed claims.

## 4. The substitution hard error (from ADR 0003)

Seihou: a stale or substituted artifact is a **hard error** — the manifest guard runs before anything is recorded, and a substituted blueprint would have "its edges recorded against this project's ledger under an identity that matches nothing."

Campaign analogue — three tamper classes, each a hard refusal at the attestation seam (all three are already exercised live by the milestone-3 validator's negative controls):

1. **State substitution**: the after-state bytes (or their hash) differ from the replay re-derivation → `REJECTED`. (validator: `tampered-after`)
2. **Claim substitution**: the recorded diagnostics don't match the oracle re-run on the recorded source → `REJECTED`. (validator: `fake-diags`)
3. **Operation substitution**: an op that is not a faithful deletion of an original line → `REJECTED`, and the replay mismatch follows. (validator: `tampered-op`)

A signed attestation must therefore bind **the re-derivation**, not the assertions: what gets signed is (identity from §2 + "oracle X re-derived this receipt on host Y at Z"), so a signature over substituted claims is detectable, and the signature adds the campaign's missing ingredient — *who* attested (the `did:key`), which seihou's local receipts deliberately do not carry.

## 5. Admissibility = earned, not asserted (from ADR 0011, stricter)

Seihou permits `--mark-applied`: a consumer may assert an edge was attended to by hand; the assertion is *not* verified and seihou "does not pretend otherwise"; `--rerun` is the remedy. The campaign's seam is stricter by design — invariant #4:

- **No `--mark-applied` analogue exists.** A repair attestation is established only by oracle re-verification in `approveBranch`. A reviewer "approving by hand" still triggers the re-verification; the approval is a decision, not an attestation.
- **Remedy**: if an attestation was established under a bug or a tampered oracle, the equivalent of `--rerun` is re-running the cell with the corrected oracle — the journal is append-only, so the old attestation remains, and the newer one supersedes it by timestamp-within-identity (same §2 identity, later re-derivation wins).

## 6. The attestation record (proposed shape)

```
CampaignAttestation {
  attIdentity    : { origin + blueprint name, beforeStateHash, afterStateHash, oracleId }   -- §2
  trustLevel     : journal-origin | repo-origin | local-origin                               -- §3 (local ⇒ UNVERIFIABLE)
  reDerivation   : { host, timestamp, oracle re-derivation output (admitted | refused) }     -- §4: what is signed
  journalRef     : Optional { streamName, actRange }                                          -- journal-origin evidence
  signer         : did:key                                                                    -- the campaign's addition over seihou
}
```

Phase 6 publishes `CampaignAttestation` to Radicle seed nodes bound to the merge commit that `approveBranch` produced; a Radicle patchset's verification evidence is then the *re-derivation claim + signer*, replayable by any verifier holding the checked-in blueprint + receipt and the oracle.

## 7. Open questions for review

1. Does Radicle's patchset-attestation surface accept an arbitrary DID-signed JSON payload, or must the attestation ride in a patch annotation (e.g. a `verification: <sha256>` trailer)? This determines whether `attIdentity` is a trailer or a linked note.
2. Should `journal-origin` attestations embed the Keiro stream name + act range directly, or a hash of that range (smaller, but requires journal access to replay)?
3. Supersede-by-timestamp within identity (§5) vs. explicit revocation: seihou has no revocation (receipts are additive); the campaign should decide whether a tamper-remedy attestation needs to *void* a prior one for downstream Radicle consumers.
