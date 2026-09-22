# Testing & Verification Strategy — Steps of COMBINED_ECOSYSTEM_PLAN

> **Status**: Plan (drafted 2026-09-22).
> **Companions**: [`COMBINED_ECOSYSTEM_PLAN.md`](COMBINED_ECOSYSTEM_PLAN.md) (the steps under test), [`VERIFICATION_LADDER.md`](VERIFICATION_LADDER.md) (seven forms + honesty invariant), [`CODE_HANDLING.md`](CODE_HANDLING.md) (four testbed contracts), [`CODE_INGESTION_NATIVISATION.md`](CODE_INGESTION_NATIVISATION.md) (strategy B architecture), [`CAMPAIGN_GENERALIZATION.md`](CAMPAIGN_GENERALIZATION.md) (oracle DSL + phases), [`WORKQUEUE.md`](WORKQUEUE.md) (live portfolio matrix), [`HARNESS_CLONE_QUEUE.md`](HARNESS_CLONE_QUEUE.md) (harness sources).
> **Scope**: What is tested at each layer of the plan (code quality → unit/property → component → loop → code-intelligence acceptance → ladder forms → meta), who owns the gate, and the enablement order aligned with Tier 1–4 and 4a–4g.

---

## 1. Executive Summary

The plan is three halves (code intelligence × decision orchestration × verification gating) plus a closed autonomous loop. Testing maps onto **six layers** that nest from milliseconds to hours:

| Layer | Gate | Cadence | Owner |
| :--- | :--- | :--- | :--- |
| **L0 — Static** | fourmolu / hlint / cabal-fmt / `-Wall` | Every commit (`pre-commit`) | `Makefile` + hook (landed) |
| **L1 — Unit & property** | Pure oracles, Dhall schemas, attestation hashes | Every build | New `test-suite`s (QuickCheck/hedgehog) |
| **L2 — Component** | Manifest discovery, receipt admission, MCP/CLI, journal resume | Every build + smoke | Existing exes + scripted probes |
| **L3 — Loop** | Observe→retrieve→decide→act→persist→validate→gate, end-to-end | Nightly / on-demand | `campaign-demo` acts + negative controls |
| **L4 — Code-graph acceptance** | Four testbed contracts + required-language scanners | On ingestion changes | SQL/façade queries vs fixture + live repos |
| **L5 — Ladder forms (Tier 4a–4g)** | Formal / boot / stress / fixpoint / network / cluster / crash | Per rung, failed-first | Campaign units + external drivers |
| **L6 — Meta (tests-of-the-gates)** | Oracle sensitivity, mutation metrics, honesty negative controls | Weekly / on oracle change | Property suites + optional mutatest |

**Invariants every layer must preserve** (from the plan thesis + honesty invariant):

1. **LLMs never grade.** A negative control must show that swapping a tool verdict for an LLM prose answer is structurally impossible (facts-only manifests; interpreters own verdicts).
2. **Manifests are facts, not code.** Typecheck rejects executable payloads; a forged `command`/`successMarkers` pair cannot invent a pass without the real tool output.
3. **Receipts/attestations are evidence, not verdicts.** Re-derivation under the named `CellOracle` is the sole establishment path; orphan/tampered receipts refuse (already proven for repair receipts and attestations).
4. **Known-fails separate noise from regressions.** `knownFailuresFor` ∪ `waiveBaseline` must waive only named failures; unnamed failures still fail (CLASSIFY negative control pattern).

---

## 2. Layer Map Against Plan Steps

### 2.1 L0 — Static quality (already landed)

Maps to **no roadmap tier** (pre-existing hygiene) but underwrites every later layer.

| Check | Command | Failure signal |
| :--- | :--- | :--- |
| Format (Haskell) | `fourmolu --mode check` | exit 100 |
| Lint | `hlint .` | any hint (exit 1) |
| Format (cabal) | `cabal-fmt --check` | non-zero |
| Warnings | `cabal build all` with `-Wall` | any `warning: [GHC-…]` |

**Where**: `Makefile` targets `fmt-check`, `lint`, `cabal-fmt-check`, `wall`, aggregate `check`; `.git/hooks/pre-commit` runs `pre-commit` (fast three; wall is manual/`check`).

**Coverage gap**: none for the four arena packages. Ecosystem siblings keep their own policies (out of scope).

---

### 2.2 L1 — Unit & property tests (tests-of-the-gates)

Maps to **§2.4 Tests-of-the-gates**, **§6 Tier 4g**, and CAMPAIGN_GENERALIZATION Phase 2 (oracle DSL).

Arena packages currently ship **zero** `test-suite`s (unlike shikumi’s per-package suites). Add suites in priority order:

| Suite (proposed) | Package | Properties / cases |
| :--- | :--- | :--- |
| `oracle-tests` | `shikumi-campaign` | `classifyCellLogBaseline`: named-waive → `passed-waived`; unnamed → `failed`; wrong-name baseline → `failed`; empty baseline + failures → `failed`. `verdictFromBaseline` exit×marker matrix. `hostVerdictFromProj` marker precedence. |
| `manifest-tests` | `shikumi-campaign` | Dhall typecheck accept/reject; unknown `kind` reported+skipped; replace-vs-add merge for built-in keys; facts threaded into command text. |
| `receipt-tests` | `shikumi-campaign` | `admitReceipt`: real alpha receipt admits; three tamper classes (fake before-diags, forged after-state, invalid op) each refuse with the *distinct* documented reason. |
| `attestation-tests` | `shikumi-campaign` | Canonical trailer format round-trip; `sha256` recompute matches; orphan receipt / forged diagnostic / back-compat no-receipt refuse without merge. |
| `mori-schema-tests` | (schema pkg or campaign) | Every façade/tool wire type valid under Mori; invalid payloads rejected **before** execution. |
| `dhall-prompt-tests` | `shikumi-campaign` | `prompts/package.dhall` typechecks (RC=0); vars validation rejects bad `when`/guidance shapes. |

**Frameworks**: QuickCheck / hedgehog (clone-queue §6.8; both are also L6 inputs). Prefer pure functions already exported (`classifyCellLogBaseline`, `admitReceipt`, attestation formatter) so tests do not need Postgres.

**Acceptance**: `cabal test all` green; each suite includes ≥1 **negative control** per invariant in §1.

---

### 2.3 L2 — Component / integration probes

Maps to **§5 loop steps 1–6** (pre-ladder) and WORKQUEUE live matrix.

| Probe | Method | Pass signal | Status |
| :--- | :--- | :--- | :--- |
| Manifest discovery flip | `DISCOVER=json` with/without `shikumi-campaign/targets/` | count 99 ↔ 100; both manifest cells present | Live (Track 10) |
| Facts-only authority | Journaled `verify-plan` contains manifest-only marker | marker present; built-in command not used | Live |
| Waiver gate | `CLASSIFY=<arch>@<names>:<log>` on real archived pgcl log | failed → passed-waived → failed (wrong name) | Live |
| Repair receipt validator | `repair-receipt` exe + fixtures | ADMISSIBLE + 3 tamper refusals | Live |
| Attestation E2E | disposable fixture merge | trailer hash recompute 3/3; kioku row matches `keiro://` ref; 3 negative controls refuse | Live (Phase 6 steps 1–2) |
| MCP / CLI smoke | `campaign-mcp.py` / `campaign-cli.py` stdio | 7 typed tools return schema-valid JSON; 4 host units verify live | Live (Track 6 closed) |
| Scheduler ground truth | `REAL_LIMIT=0 ACTS=23 cabal run campaign-demo` | 100 real units (95 matrix + 5 host; 99 without manifests) | Live |
| Journal resume | Kill mid-`run-cell`, restart | resume pass; no double-execution; 0 stale workflows | Regression suite |

**How**: script these as `scripts/verify-l2.sh` (or `make l2`) calling existing exes/JSON modes — no new Haskell required. Fail = non-zero or assertion on JSON field.

---

### 2.4 L3 — Closed-loop (autonomous integration flow)

Maps to **§5 steps 1–7** as one end-to-end scenario, not seven unit tests.

**Scenario A — pass-to-fail repair (already modeled; keep as regression):**
1. Seed corpus cell fails (toy-fixer / unused-import oracle).
2. Kioku returns lesson/known-fail context; CodeGraphStore returns `find_symbol`/`get_callers` for the failing site (once Tier 1 lands — stub with fixture SQLite until then).
3. Shikumi emits `RepairBlueprint`; Keiro journals steps; PGMQ enqueues; worker evals; Kiroku appends.
4. Mori validates every structured exchange (inject a bad schema → must refuse).
5. Ladder rung for that unit returns fail → failed-first reschedule + bisection stub → back to 2b with diagnostics.
6. Human `Campaign.Review` + receipt admission → attest merge.

**Scenario B — honest promotion:**
1. Unit passes rung; receipt+attestation generated.
2. Verifier CLI (Phase 6 step 5) re-derives trailer hash and journal ref without trusting embedded claims.
3. Waiver path: named known-fail only → `passed-waived`; novel failure → fail.

**Pass criteria**: every step emits a journal event; no step’s verdict is free-text LLM output; a single injected fault (schema, receipt, marker) blocks promotion.

---

### 2.5 L4 — Code-intelligence acceptance (Tier 1 gates)

Maps to **§6 Tier 1** and **CODE_HANDLING §5** (the four contracts). These are the *definition of done* for `CodeGraphStore` + mixed ingestion + façade (strategy B).

Run against **SQLite fixture** (CI-speed) **and** live `~/repos` graph (parity):

| # | Contract | Assertion |
| :--- | :--- | :--- |
| 1 | Formal logic vs concurrency | `nodes WHERE repo='mowgli' AND type='pred' AND name IN ('all_in','check')` ≥ 2; non-empty `line_start`/`line_end`; edge to defining module. |
| 2 | Regex invariant symbol | `nodes WHERE repo='smirk' AND name='compileRegex'` = 1; façade `find_symbol` returns same id/line range. |
| 3 | DOI → module | `nodes WHERE type='citation'` > 0; ≥1 edge `citation → module` with resolvable path. |
| 4 | ACPI structs | `path LIKE '%acpi_srv.rs' AND type='struct'` returns `MadtOverride`, `TableEntry`, `AcpiState` (exact names). |

**Additional Tier-1 gates (required-language set — the coverage inversion the plan calls out):**

| Scanner | Fixture assertion |
| :--- | :--- |
| Mercury `:- pred`/`:- func` | mowgli `all_in`/`check`/`bounded_loop` as `type='pred'`; no false positives on comments. |
| Haskell structure | smirk `compileRegex :: …` signature node; module/import edges; class/instance nodes if present. |
| Julia / Lean / Coq / Sail | Symbol counts ≥1 per language on fixture trees (peirce, tessera, organ-bank samples); unknown syntax → explicit miss, not wrong node. |
| ctags JSONL path | `ctags --output-format=json` parse → node upsert; ids stable across reindex (mtime+hash). |
| Markdown concepts | `#`/`##` headers → `type='concept'` with line ranges. |
| Incremental reindex | Touch one file → only that file’s nodes/edges rewritten; unchanged ids preserved. |

**Façade contract**: `find_symbol` / `get_callers` / `get_callees` / `trace_path` — Mori-valid responses; empty-result on unknown symbol (no throw); latency budget from §7 (<3 ms local SQLite is aspirational — record p95, don’t gate on it initially).

**Backend neutrality**: same four contracts pass on SQLite carrier **and** Postgres carrier (campaign DB beside keiro); FTS query equivalence smoke (one symbol search each).

---

### 2.6 L5 — Verification ladder forms (Tier 4a–4g)

Each form gets **oracle unit tests** (L1) + **one live smoke unit** (L5) + **driver conformance** (barrier #1/#3 work). Sequence follows VERIFICATION_LADDER §5 / plan §6 4a–4g.

| Step | Barrier | Oracle to implement + test | Live smoke unit | Harness source |
| :--- | :--- | :--- | :--- | :--- |
| **4a Quick wins** | #2 | `proofHygiene`: scan for `sorryAx`/`Admitted`/unexpected axioms → boolean + finding list (corroborate exit+marker). `logSchema`: TAP/JSON/JUnit parse → pass/fail counts + named failures. | `tessera/host@iris`, `tessera/host@ci` (wrap `ci.sh`), `telix/host@verus` Dhall manifests | Form-1 set already landed |
| **4b Kinds + driver contract** | #1, #3 | Kind allow-list accepts `vm-console-boot`, `stress-soak`, `bootstrap-fixpoint`, `vm-crash-consistency`; unknown kind → recorded, never run. Driver contract doc: log path, exit semantics, `timeoutSeconds` ownership, fact inputs — **conformance test** = driver fixture that violates each rule must be rejected. | One `vm-console-boot` prototype (pgcl-style expect driver script) | `avocado`/`avocado-vt` reference; pgcl/syzkaller/expect in-tree |
| **4c Bootstrap fixpoint** | #1 | `bootstrap-fixpoint` kind; normalized-equality oracle (strip build-id via `objcopy` / diffoscope / behavioral `--version`+corpus) — **never raw bytes**. Property: stage-2 ≡ stage-3 under normalization; negative: unnormalized diff fails. | Mercury campaign already template; add stage-N compile-and-run sub-unit | `stage0-posix`+`mes`, diffoscope/csmith/creduce landed |
| **4d Guest stress + crash-consistency** | #1, #2 | `stress-soak` + `timeoutSeconds` honored (driver kills at bound → `timeout` verdict, not hang). `vm-crash-consistency`: kill schedule facts → reboot → `fsck` exit 0 / clean-mount markers; known-fails for documented races. | LTP subset unit; one crash-reboot cell on ext4 | LTP/initramfs; clone `lkl`, `lvm2`; xfstests/crashmonkey/e2fsprogs landed |
| **4e Network interop** | #1 | Phase A: LTP-net as existing kind (no new oracle). Phase B: packetdrill/netperf behind capability flags; TAP via `logSchema`. | One LTP-net unit; later packetdrill behind `has_net_ns` | packetdrill/netperf/nfstest landed; clone `nfs-utils`, `nghttp2` |
| **4f Cluster / nemesis** | #3, #4 | Two-node Postgres/pgmq kill-restart: nemesis schedule as facts; oracle = journal/checker consistency (**porcupine/elle**, not log vibes). Capability `has_fault_injection` gates assignment. | `patroni` or raw two-node pgmq unit first | jepsen/maelstrom/porcupine/toxiproxy landed; clone patroni, corosync+pacemaker, `spin` |
| **4g Diagnostics & meta** | — | `rr` replays into kioku L0 (replayability test: same failure → same classification). QuickCheck/hedgehog suites for every interpreter above. Optional mutation score (mutatest) as oracle-sensitivity metric. | N/A (meta) | clone `rr`, QuickCheck, hedgehog |

**Per-form test pattern** (repeatable):
1. **Oracle unit** (L1): pure interpreter over golden logs / fixtures.
2. **Positive smoke**: real tool run → pass.
3. **Negative controls** (≥2): missing marker; named-but-wrong baseline; timeout; forged receipt — each → fail/refuse.
4. **Driver conformance** (if kind is new): broken driver (no log file, wrong exit, missing timeout) → rejected before run.
5. **Journal proof**: verdict + facts recorded; resume mid-run does not double-count.

---

### 2.7 L6 — Meta verification (tests-of-the-gates)

Maps to plan §2.4 last row + HARNESS_CLONE_QUEUE §3/§6.8–6.9.

| Meta-check | Method | Signal |
| :--- | :--- | :--- |
| Honesty negative control | Attempt to submit LLM-generated “PASS” string as verdict without tool exit/markers | Refused at interpreter (no code path accepts free-text as pass) |
| Facts-only enforcement | Dhall manifest with embedded script/`$(…)` in oracle field | Typecheck/schema reject |
| Receipt/attestation tamper | Reuse L1 fixtures in CI | Distinct refusal reasons stable across refactors |
| Oracle mutation sensitivity | mutatest / cargo-mutants (optional) on interpreter modules | Mutation kill-rate ≥ threshold before trusting a new fact kind |
| Baseline drift | Diff `knownFailuresFor` + manifest `waiveBaseline` against last green campaign run | Unexpected waive/fail delta → review |
| Capability honesty | Worker claims `has_qemu` but probe fails | Assignment skipped; no silent pass |
| Sandbox before exec | Agent-proposed binary without `sandbox_provider` | Rung refuses to spawn (Tier 2 seam) |

---

## 3. Enablement Order (aligned with plan Tiers)

| Order | Work | Layer | Depends on |
| :--- | :--- | :--- | :--- |
| **0** | Keep L0 green (already landed); add `make test` → `cabal test all` once suites exist | L0→L1 | — |
| **1** | Port live L2 probes (discovery flip, CLASSIFY, receipts, attestation, scheduler count) into `make l2` / `scripts/verify-l2.sh` | L2 | nothing new |
| **2** | Add `oracle-tests` + `receipt-tests` + `attestation-tests` (pure; no DB) | L1 | exports already present |
| **3** | **Tier 4a**: implement `proofHygiene` + `logSchema` interpreters **with** L1 golden tests + first live manifests (`iris`, `ci`, `verus`) | L1+L5 | barrier #2 |
| **4** | **Tier 4b**: open kind allow-list + write driver contract + conformance fixture tests | L1+L5 | barriers #1/#3 docs |
| **5** | **Tier 1 CodeGraphStore**: SQLite carrier + four L4 contracts + required-language scanner fixtures **before** wiring loop step 2b | L4 | strategy B design |
| **6** | Façade + Mori wire tests; Postgres carrier parity on same contracts | L4 | step 5 |
| **7** | L3 Scenario A/B with **fixture** graph (no live prover) — proves loop shape | L3 | steps 2, 5–6 stubs |
| **8** | **4c–4e**: fixpoint / crash / network oracles + one smoke each | L5 | 4a–4b seams |
| **9** | **4f** two-node pgmq + checker behind capability flag | L5 | #3/#4 |
| **10** | **4g** rr + property suites + optional mutation metrics; wire `make check` → include L1/L2 | L6 | all interpreters stable |

**Rule**: never land a new fact kind or ladder rung without (a) L1 interpreter tests, (b) one positive smoke, (c) ≥2 negative controls, (d) driver conformance if execution shape is new.

---

## 4. What We Deliberately Do Not Test Here

- **Hosting-server CI** — out of scope (local `pre-commit` + `make` only).
- **LLM-as-judge benchmarks** — forbidden by honesty invariant; agent quality is measured by downstream rung outcomes and review-seam acceptance rates, not by prose graders.
- **Tree-sitter/ctags/codegraph long-tail parsers** — consumed as black boxes; we test *our* node/edge contracts, not their internals (strategy B / do-not-reimplement).
- **Sibling repo unit suites** — shikumi/keiro/etc. own theirs; arena only gates via portfolio host-verify units already in WORKQUEUE.

---

## 5. Concrete Near-Term Checklist (next implementation slice)

1. [ ] `make test` target → `cabal test all` (even if suites are empty, establishes the hook).
2. [ ] `scripts/verify-l2.sh`: discovery count, CLASSIFY triple, `repair-receipt`, attestation hash recompute — exit non-zero on any regression.
3. [ ] `oracle-tests` suite covering `classifyCellLogBaseline` + `verdictFromBaseline` with the m68k archived log fixture (same cases as Milestone 2).
4. [ ] `receipt-tests` + `attestation-tests` reusing `shikumi-campaign/repairs/*` fixtures (ADMISSIBLE + three tamper reasons).
5. [ ] Draft `proofHygiene` / `logSchema` interpreter modules **with** golden logs from `tessera/host@proof` and a TAP snippet — even before full 4a manifests, so Tier 4a is test-first.
6. [ ] Skeleton `CodeGraphStore` property laws (id stability, edge referential integrity, reindex idempotence) as hedgehog generators over a tiny fixture graph — runs before full ingestion lands.
7. [ ] Record L4 contract SQL as `docs/fixtures/codegraph-contracts.sql` so Tier 1 acceptance is copy-paste runnable against SQLite and Postgres.

---

## 6. Success Metrics

| Metric | Target |
| :--- | :--- |
| L0 | `make check` green on `main` (already true) |
| L1 | ≥3 suites; every interpreter change forces a new property or golden case |
| L2 | `verify-l2.sh` green; used as pre-push (optional) gate |
| L4 | All four CODE_HANDLING contracts + ≥6 required-language scanner fixtures green on SQLite **and** Postgres |
| L5 | Per landed rung: 1 positive + ≥2 negative controls in-repo; driver conformance doc referenced from manifest |
| L6 | Mutation kill-rate reported (even if informational) before any new oracle fact kind is trusted |

This strategy is the standing answer to “how do we know each step of COMBINED_ECOSYSTEM_PLAN works — and how do we know the gates themselves are honest.”
