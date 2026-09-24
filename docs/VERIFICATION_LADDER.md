# Verification Ladder — Forms of Testing & Their Place in the Campaign

> **Status**: Design assessment (drafted 2026-09-22).
> **Companions**: [`CAMPAIGN_GENERALIZATION.md`](CAMPAIGN_GENERALIZATION.md) (oracle DSL, worker federation, roadmap phases), [`WORKQUEUE.md`](WORKQUEUE.md) (live harness status), [`COMBINED_ECOSYSTEM_PLAN.md`](COMBINED_ECOSYSTEM_PLAN.md) (code intelligence feeding repair), [`CODE_INGESTION_NATIVISATION.md`](CODE_INGESTION_NATIVISATION.md).
> **Scope**: Seven concrete verification/testing forms — where they fit in the shikumi-campaign architecture, what barriers exist to using them as gates on implementation states, and what must be built to enable each.

---

## 1. Executive Summary

The campaign stack already has the right seams for all seven forms: Dhall target discovery, evidence-driven scheduling (failed → unknown → passed), keiro durable workflows, kiroku journals, honest non-opinionated oracles, kioku lessons, `REAL_LIVE`/`REAL_LIMIT` gates, human review, MCP/`/campaign` tools. **Scheduling, journaling, memory, and budget gates are kind-agnostic** — once a unit can be discovered, commanded, and given a deterministic verdict, it rides the whole loop for free.

What blocks the seven forms is not the loop but **four concrete barriers** in today's `shikumi-campaign`, plus one invariant that constrains every oracle design.

---

## 2. The Four Barriers

| # | Barrier | Location | Effect |
| :--- | :--- | :--- | :--- |
| **1** | **Closed kind vocabulary** | `Campaign/Real.hs` manifest allow-list `["host-verify","qemu-boot-matrix"]` (anything else is skipped); `runRealUnit` branches on exactly those two | New verification *shapes* (console-driven boot, fixpoints, fault injection) cannot be declared in a manifest |
| **2** | **Uninterpreted oracle facts** | `TargetManifest` reserves `logSchema`, `proofHygiene`, `timeoutSeconds` — declared in comments/types, **never interpreted** (`hostVerdictFromProj` = exit code × text markers only) | Proof hygiene and structured (TAP/JSON/JUnit) results cannot gate anything until interpreters exist |
| **3** | **Process-spawn-only execution** | One synchronous `readProcess` per cell; no VM lifecycle, serial/PTY, expect, tftp, device socket, or nemesis layer anywhere in the package | Console interaction, mid-run failure injection, and multi-node orchestration are new machinery |
| **4** | **Capability & budget discovery** | Toolchain probes exist (`command -v qemu-system-*`, cross-gcc); no privilege/VM-farm caps; timeouts owned by external drivers; soak/proof durations fight fixed budgets | Long proofs, soaks, and privileged fault injection need worker capability flags + pacing (CAMPAIGN_GENERALIZATION Vector E) |

### The honesty invariant

Language models **never** grade. Every gate must be a deterministic tool verdict — exit code, success banner, `sorryAx` scan, fsck status, checker output — with documented known-fails baselines (`knownFailuresFor`, manifest `waiveBaseline`) separating environment noise from novel regressions. Manifests are facts; the orchestrator interprets; a verdict is never embedded as executable payload.

---

## 3. The Seven Forms — Assessment

### 3.1 Formal verification (Lean / Rocq / Iris / Isabelle / Verus / CBMC / Kani)

| | |
| :--- | :--- |
| **Fits today via** | `tessera/host@proof` (`lake build`, zero `sorryAx`); `tessera/host@cbmc-sanity` (`SUITE OK`); `tessera/ci.sh` (`CI OK`/`CI FAIL`) is a textbook host-verify marker; Verus, Iris, Isabelle (`seL4/l4v`), Kani all exist under `~/src/` |
| **Barriers** | Mostly **#2**: `proofHygiene` uninterpreted (axiom/`Admitted` hygiene beyond Lean's built-in marker); toolchain/opam-switch pinning (Rocq↔gpfsl `.vo` skew currently blocks green `ci.sh`); WORKQUEUE gaps: `tessera/host@iris` and `telix/host@verus` not first-class units |
| **Enablement** | ① Dhall manifests for `iris`, `verus`, `ci-sh` units. ② **Interpret `proofHygiene`**: scan proof dependency trees for `sorryAx` / `Admitted` / unexpected axioms; corroborate with exit+marker floor. ③ Keep keiro durability for multi-hour proof resume (already designed for this). ④ Capability probes: `opam_switch`, `lake`, `verus` binary on path |

**Gate role:** Tier-2/3 of the ladder — long, expensive, resumable; regression here outranks guest-boot noise under failed-first scheduling.

### 3.2 Simulator testbooting with console interaction (QEMU, tftpboot, serial/stdio/sockets)

| | |
| :--- | :--- |
| **Fits today via** | pgcl's proven pattern: **external bash driver** (`matrix-driver-all.sh`) owns QEMU + serial console (`-nographic`, `ttyS0`/`ttyAMA0`, embedded initramfs init); arena only classifies the captured log afterward. No tftp/PXE harness exists |
| **Barriers** | **#1** — need a kind beyond `qemu-boot-matrix` for interactive/expect-style boots; **#3** if send/expect logic is to live in Haskell; zero tftpboot/PXE automation in-tree |
| **Enablement** | **Preferred: driver-owns-console** (extend the pgcl pattern). New kind `vm-console-boot`; manifest `command` = driver script embedding expect/serial sequences; oracle stays markers + exit on the captured console log; console script parameters (send strings, expect patterns, timeouts) become manifest facts. Defer in-process PTY/expect (#3) until a driver script genuinely cannot express the interaction. tftpboot/PXE: new driver responsibility, same log contract |

**Gate role:** Tier-4 — structural "does it actually boot and behave" evidence; cheaper than fault injection, stronger than host-verify alone.

### 3.3 Binary compatibility & stress tests inside simulated environments

| | |
| :--- | :--- |
| **Fits today via** | LTP already rides inside pgcl's initramfs — including `fsstress`, `fsx-linux`, syscall suites; verdicts via LTP subtotals + `LTP FAIL LIST` names vs per-arch waives; classification proven offline by `real-validate` |
| **Barriers** | Exposing LTP *subsets* as separate units; soak duration vs budgets (**#4**); structured TAP/JSON parsing needs `logSchema` (**#2**); `timeoutSeconds` uninterpreted |
| **Enablement** | ① New units reusing `qemu-boot-matrix` with different args, **or** kind `stress-soak` for duration-bound runs. ② **Interpret `logSchema`** for TAP/JUnit/JSON oracles (structured schema oracle — already Vector B in CAMPAIGN_GENERALIZATION). ③ Per-suite known-fails baselines. ④ Honor `timeoutSeconds` in driver contract rather than assuming harness-owned timeouts |

**Gate role:** Tier-4/5 — in-guest realism; pairs naturally with 3.2 (same boot, richer guest suite).

### 3.4 Compiler bootstrap fixpoints (stage-N fixed point + compile-and-run)

| | |
| :--- | :--- |
| **Fits today via** | Mercury promotion campaign (`Campaign/Mercury.hs`, `REPLAY=mercury`): staged bootstrap rounds (`configure → … → compiler`), wall-clock probes, new binary's `--help` must list promoted options, **negative control** on pre-promotion binary; all journaled/resumable via keiro |
| **Barriers** | No true **stage-2 ≡ stage-3** binary comparison; naive binary diff is dishonest (build-ids, timestamps, path strings); needs a new kind + multi-stage workflow shape |
| **Enablement** | ① New kind `bootstrap-fixpoint`. ② Keiro workflow: stage-1 build → stage-2 build (stage-1 drives it) → stage-3 build (stage-2 drives it) as separate journaled steps (crash-resumable). ③ **Normalized equality oracle**: strip build-id/debug info (`objcopy`) or compare canonical dumps / `--version` + behavioral corpus — never raw bytes. ④ Their test program: stage-N compiler compiles test programs that must then **execute correctly** — host-verify sub-unit or guest run under 3.2/3.3. ⑤ Optional known-fails for documented non-determinism |

**Gate role:** Tier-6 — promotion/release precondition; mercury campaign is the template for the workflow shape.

### 3.5 Network interoperation / protocol correctness

| | |
| :--- | :--- |
| **Fits today via** | LTP network suites inside pgcl guests (incl. NFS stress); **no** packetdrill, netperf, or salvo checkout under `~/src/` |
| **Barriers** | **#3** for topologies beyond what guest init provides (veth/namespaces, privileges); no protocol-checker oracle pattern yet |
| **Enablement** | **Phase A (days):** LTP network subset as `qemu-boot-matrix` unit — zero new machinery. **Phase B:** vendor packetdrill/netperf; guest init runs them; oracle = tool exit + TAP (`logSchema`); capability flag if host-side namespaces are required |

**Gate role:** Tier-4/5 — protocol suites as first-class units once Phase A proves the manifest wiring.

### 3.6 Cluster node bonding + failure injection (disorderly shutdowns, partitions)

| | |
| :--- | :--- |
| **Fits today via** | **Nothing** — no Jepsen-style testbed anywhere under `~/src/`; pgmq/keiro/kioku are *infrastructure*, not nemesis harnesses |
| **Barriers** | Largest **#3 + #4** gap: multi-node lifecycle, deterministic fault schedules, linearizability/consistency checkers, privileged workers, capability registration |
| **Enablement** | ① Start small: **two-node** Postgres/pgmq unit reusing `Campaign/Bootstrap.hs` patterns — scripted nemesis (kill -9, restart, reorder/delay) as manifest facts; oracle = journal/checker consistency tool, not log vibes. ② Composite multi-cell unit or standalone experiment runner (keiro workflow orchestrating N guest cells). ③ Worker capability `has_fault_injection` before any privileged nemesis. ④ Only then Jepsen-class ambitions |

**Gate role:** Tier-6/7 — highest cost, highest signal; never a per-edit gate; scheduled failed-first on regressions only.

### 3.7 Filesystem stress + disorderly shutdown (recoverable structure)

| | |
| :--- | :--- |
| **Fits today via** | `fsstress` / `fsx-linux` / `racer` / `fs_maim` exist inside LTP-in-initramfs; **no** xfstests or pjdfstest checkout; no power-cut/crash-reboot harness |
| **Barriers** | Crash-consistency loop absent: workload → QEMU kill/reset mid-run → reboot → **fsck/mount oracle**; needs new kind + driver; xfstests not vendored |
| **Enablement** | ① New kind `vm-crash-consistency`. ② Driver embeds: workload + kill schedule (facts) + reboot + probe mount. ③ Oracle = post-reboot `fsck` exit 0 / clean-mount markers + optional known-fails for documented races. ④ Later: xfstests as guest suite (new checkout + packaging into initramfs or virtio share) |

**Gate role:** Tier-5/6 — pairs with 3.3 (same guest, adversarial lifecycle); valuable for kernel/config changes in pgcl matrix.

---

## 4. The Verification Ladder (staging into campaigns)

Manifests declare membership; the evidence scheduler orders by history, not by ladder position — the ladder is how *promotion acts* and budgets should **gate**, not how the scheduler ranks:

```
edit
 └─ unit / lint floor            (CellOracle: markers, syntax check)
     └─ host-verify              (fast proofs, unit tests, on-disk fsck)
         └─ formal tiers         (Lean / Rocq / Iris / Verus — long, keiro-resumable)
             └─ guest boots      (qemu-boot-matrix / vm-console-boot)
                 └─ in-guest suites   (LTP, binary-compat, protocol — logSchema)
                     └─ adversarial  (crash-consistency, nemesis/cluster, soak)
                         └─ fixpoint (bootstrap-fixpoint before promotion/release)
```

### Insertion mechanics

| Stage step | Mechanism | Status |
| :--- | :--- | :--- |
| **Declare** | Dhall `TargetManifest` in `shikumi-campaign/targets/*.dhall` with `kind` + oracle facts | Works for 2 kinds; **open the allow-list** (barrier #1) |
| **Discover / schedule** | `realUnitCells` + capability probes + evidence ranking | Kind-agnostic; add capability flags (barrier #4) |
| **Execute** | *Host tools* = `readProcess`; *boots/faults* = **external driver owns console/timeouts/kill**, writes log file (pgcl contract) | pgcl pattern is the template; only promote to in-Haskell console layer when drivers become unmaintainable (barrier #3) |
| **Verdict** | Interpreter: exit × markers × baselines **plus** `proofHygiene`, `logSchema`, `timeoutSeconds`, fsck/fixpoint fact kinds | **Implement the reserved facts** (barrier #2); new fact kinds as needed |
| **Gate** | Promotion acts (mercury-style), attestation receipts (Phase 6) binding commit → ladder results, review seam on failures; any rung regression → failed-first + bisection (Vector D) | Review seam + attestations already landed/planned |

---

## 5. Recommended Enablement Order

1. **Quick wins (barrier #2 only):** interpret `proofHygiene` + `logSchema`; Dhall manifests for `tessera/host@iris`, `tessera/host@ci` (wrap `ci.sh`), `telix/host@verus` — **item 3.1 largely done**.
2. **Open the kind set + driver contract (barrier #1):** document `vm-console-boot`, `stress-soak`, `bootstrap-fixpoint`, `vm-crash-consistency` as kinds; write the driver conformance contract (stdout/stderr log path, exit-code semantics, timeout ownership, fact inputs).
3. **Bootstrap fixpoint (3.4):** staged keiro workflow + normalized-equality oracle + compile-and-run sub-check — pure addition; Mercury campaign is the template.
4. **Crash-consistency & guest stress (3.7, 3.3):** new guest drivers reusing LTP/initramfs + crash-reboot loop; keep console/fault logic outside Haskell.
5. **Network (3.5):** LTP-net subset now; packetdrill/netperf later behind capability flags.
6. **Cluster/nemesis (3.6) last:** prototype two-node pgmq/Postgres kill-restart with a real consistency checker before any Jepsen-class scope; requires multi-node + nemesis + checker design behind `has_fault_injection`.

None of this fights the architecture: **3.1 and 3.4** are mostly interpreters and manifests; **3.2, 3.3, 3.5, 3.7** are driver-script discipline (not new Haskell runtimes); only **3.6** (and expect-heavy corners of **3.2**) force genuine new execution machinery — gated behind capability flags, after the kind and oracle seams are open.

---

## 6. Current Harness Inventory (as of this draft)

| Form | Live in arena today | Present in `~/src/` but not a unit | Absent |
| :--- | :--- | :--- | :--- |
| Formal | `tessera/host@proof`, `tessera/host@cbmc-sanity` | Iris, Verus, Isabelle/seL4-l4v, Kani, full `ci.sh`, bedrock2, herd7, Dat3M | First-class units for the left column |
| Simulator boot | 95-cell `pgcl` qemu-boot-matrix | tessera qemu-diff, QEMU checkouts, telix bare-metal (milestone) | tftp/PXE automation |
| In-guest stress/compat | LTP subset inside pgcl (implicit) | LTP full tree, fsx, fsstress as standalone suites | Dedicated soak/binary-compat units, xfstests |
| Bootstrap fixpoint | Mercury promotion + `--help` probe (one-level self-application) | mercury in-tree bootstrap docs | stage-2≡stage-3 normalized fixpoint harness |
| Network | LTP net suites inside pgcl (implicit) | LTP network/NFS stress | packetdrill, netperf, salvo |
| Cluster failure injection | — | — | Entire category (no Jepsen-style testbed) |
| FS crash consistency | — | fsstress/fsx *workloads* only (inside LTP) | Crash-reboot driver + fsck oracle unit |

---

## 7. Related Roadmap Touchpoints

- **CAMPAIGN_GENERALIZATION** Phase 1 (manifests) / Phase 2 (oracle DSL — *in progress*, covers structured + proof-hygiene oracles) / Phase 4 (bisection on any rung regression) / Phase 5 (remote workers for #4 capabilities) / Phase 6 (attestations binding ladder results to commits).
- **WORKQUEUE** existing milestones that are steps on this ladder: `telix/host@verus`, `tessera/host@iris`, `tessera/host@cbmc`, telix QEMU bare-metal boot, Rocq↔gpfsl switch sync for green `ci.sh`.
- **COMBINED_ECOSYSTEM_PLAN / CODE_INGESTION_NATIVISATION**: code intelligence (CodeGraphStore, façade) supplies the *repair* side once any ladder rung fails — scheduler evidence feeds Shikumi diagnostics with exact edit sites.

This ladder and its barrier list are the standing answer to "what forms of verification can gate implementation states, and what must exist before they can."

### New Verification Kinds (Tier 4+)

The following verification kinds are now documented and can be declared in 
`TargetManifest` Dhall files. Each kind has an associated driver contract.

#### `vm-console-boot`
- **Purpose**: Interactive/console-style boot verification
- **Driver contract**: 
  - stdout/stderr captured to log file
  - Exit code semantics: 0 = pass, non-zero = fail
  - Timeout ownership: external driver (harness provides `timeoutSeconds`)
  - Console script parameters (send strings, expect patterns) become manifest facts
  - Defer in-process PTY/expect until driver script cannot express the interaction
- **Manifest format**: `kind: "vm-console-boot"`, `command` = driver script path
- **Oracle facts**: `proofHygiene`, `logSchema`, `timeoutSeconds` (honored in driver contract)

#### `stress-soak`
- **Purpose**: Duration-bound stress test
- **Driver contract**:
  - Runs for specified duration (documented in `timeoutSeconds`)
  - Periodic health checks logged
  - Exit code: 0 = all iterations pass, non-zero = failure
  - Timeout: harness-owned but documented in manifest
  - Known-fail baselines documented per suite
- **Manifest format**: `kind: "stress-soak"`, `timeoutSeconds` = duration in seconds
- **Oracle facts**: `logSchema` (TAP/JUnit structured), `timeoutSeconds` (honored verdict: pass/fail/timeout)

#### `bootstrap-fixpoint`
- **Purpose**: Nested/compiler bootstrap verification
- **Driver contract**:
  - Stage-1 build → stage-2 build (stage-1 drives it) → stage-3 build (stage-2 drives it)
  - Separate journaled steps, crash-resumable
  - Exit code: 0 = all stages pass
  - Normalized equality oracle (strip build-ids, debug info)
  - Known-fails for documented non-determinism
- **Manifest format**: `kind: "bootstrap-fixpoint"`, staged commands
- **Oracle facts**: `proofHygiene` (scan for Admitted/sorryAx), normalized equality

#### `vm-crash-consistency`
- **Purpose**: Crash consistency + reboot loop verification
- **Driver contract**:
  - Workload → QEMU kill/reset mid-run → reboot → fsck/mount probe
  - Post-reboot `fsck` exit 0 / clean-mount markers
  - Optional known-fails for documented races
  - Driver embeds: workload + kill schedule (facts) + reboot + probe mount
- **Manifest format**: `kind: "vm-crash-consistency"`, command + kill schedule
- **Oracle facts**: `fsck` exit 0 / clean-mount markers, `proofHygiene` for documented races


### `bootstrap-fixpoint` Kind

- **Purpose**: Verify nested/compiler bootstrap chains (e.g., GHC bootstrapping itself,
  or Mercury compiler bootstrapping from an existing version).
- **Driver contract** (staged keiro workflow):
  1. **Stage 1**: Build base compiler/interpreter from source
  2. **Stage 2**: Build target using stage-1 compiler
  3. **Stage 3**: Verify target produces correct output
  - Each stage is a separate journaled keiro step, crash-resumable
  - Exit code 0 = all stages pass
  - Build artifacts preserved between stages for reproducibility
- **Normalized equality oracle**:
  - Strip build-ids, debug info via `objcopy --strip-debug` / `objcopy --strip-all`
  - Compare canonical dumps or use `--version` + behavioral corpus
  - Never compare raw bytes (build-ids, timestamps, path strings differ)
- **Known-fails**: Documented non-determinism (e.g., timestamp-dependent outputs)
- **Manifest format**: `kind: "bootstrap-fixpoint"`, staged commands with
  `stage1_cmd`, `stage2_cmd`, `stage3_cmd` fields
- **Oracle facts**: `proofHygiene` (scan for Admitted/sorryAx in generated code),
  normalized equality of build outputs
- **Example**: Mercury compiler bootstrapping from v1 to v2, verifying ABI compatibility


### `vm-crash-consistency` Kind

- **Purpose**: Verify crash consistency of filesystems/partitions across reboots.
  Workload → QEMU kill/reset mid-run → reboot → fsck/mount probe.
- **Driver contract**:
  1. **Execute workload** under QEMU/Virtualization with root filesystem
  2. **Mid-run kill**: QEMU sends SIGKILL or power-off at arbitrary point
  3. **Reboot**: Virtual machine reboots (firmware-assisted or save/restore)
  4. **Probe mount**: Run `fsck` on returned state; check for clean-mount markers
  5. **Driver embeds**: workload + kill schedule (facts) + reboot + probe mount
- **Oracle facts**:
  - `fsck` exit code 0 = filesystem consistent
  - Clean-mount markers in dmesg/journal (e.g., `EXT4-fs: mounted filesystem with ordered option`)
  - Optional `proofHygiene` for documented races / non-deterministic corruption
- **Known-fail baselines**: Documented known race conditions, e.g., 
  specific interleavings that cause benign corruption
- **Manifest format**: `kind: "vm-crash-consistency"`, command + kill_schedule
  fields specifying when to interrupt the workload
- **Example**: LTP (Linux Test Project) subset run across reboot cycle, 
  checking `fsck` exit 0 and clean-mount markers


### Network Interop (Step 4e)

- **Purpose**: Verify network connectivity and protocol handling across diverse 
  network topologies and stack configurations.
- **Driver contract**:
  - **Phase A (LTP-net subset)**: Linux Test Project network subset as existing kind;
    runs `npf-test`, `ddt`, `iptables` subsets as checkpoint rungs
  - **Phase B**: `packetdrill` and `netperf` behind capability flags (`has_fault_injection`)
    - `packetdrill`: packet rate testing, loss injection, latency measurement
    - `netperf`: TCP/throughput, RPC, latency benchmarks
  - Capability probe: `has_fault_injection` gates worker assignment
  - Network namespace isolation for test containment
  - `timeoutSeconds` documented per-suite; external driver owns kill schedule
- **Manifest format**: `kind: "network-interop"`, `capability_flags` field
  containing `has_fault_injection`, `has_qemu`, etc.
- **Oracle facts**: `logSchema` (structured TAP/JUnit from npf/ddt outputs),
  `timeoutSeconds` (honored verdict), custom `packetdrill`/`netperf` fact kinds
- **Known-fail baselines**: Documented protocol-specific interoperability issues,
  middlebox behaviors, version skew effects
- **Example**: LTP `npf-test` suite across 3 network configurations, 
  `packetdrill` latency/loss targets, `netperf` TCP throughput targets


### Cluster / Nemesis (Step 4f)

- **Purpose**: Multi-cell cluster fault injection and nemesis testing for 
  resilience verification across distributed state.
- **Driver contract**:
  - **Two-node Postgres/pgmq kill-restart**: Coordinated primary/secondary 
    failure scenarios using pgmq message queue for failure coordination
  - **Composite multi-cell keiro workflow**: Staged workflow across multiple 
    keiro-managed cells, each with independent state and fault injection
  - Capability `has_fault_injection` gates worker assignment to cluster-capable nodes
  - Folded test: single-cell keiro workflow with composite fault patterns
  - `timeoutSeconds` per-rung documented; external driver owns kill schedule
- **Oracle facts**: `proofHygiene` (scan for Admitted/sorryAx in composite 
  workflow outputs), `logSchema` (workflow step completion TAP markers),
  `timeoutSeconds` (per-rung honored), custom `pgmq` fact kinds for message 
  queue state
- **Known-fail baselines**: Documented split-brain scenarios, split-session 
  timeouts, quorum loss conditions, STONITH fencing edge cases
- **Manifest format**: `kind: "cluster-nemesis"`, `cell_count` field, 
  `fault_schedule` (jornaled pgmq messages), `capability_flags`
- **Example**: 3-cell keiro workflow with partitioned primary, 
  `pgmq` message-mediated failure coordination, `fault-injection` gated workers


### `4g` Deep Ladder Stage & Autonomous Loop

- **Purpose**: Full autonomous integration verification — the complete
  observe→retrieve→decide→act→persist→validate→(ladder)gate→promote loop
  under realistic conditions, with all substrates active and interacting.
- **Scope**: All seven verification forms staged as a ladder; four barriers
  fully open; harness clones assessed and fed into driver contracts; Kioku
  lessons ranking evidence for evidence-driven scheduling; Mori-Schema 
  middleware validates all structured exchanges including CodeGraphStore
  façade responses and Kiroku journal entries.
- **Postgres carrier parity**: All SQL contracts verified against both
  SQLite testbed (`docs/fixtures/test_repo_graph.sqlite`) and Postgres
  campaign database (`Campaign/Matrix.hs` carries; `CodeGraphStore` effect
  carriers). Four cornerstone contracts verified:
  1. **Node/edge existence**: `SELECT COUNT(*) FROM nodes WHERE repo=$1`
     matches between SQLite and Postgres result sets
  2. **Predicate/citation lookup**: `SELECT * FROM edges WHERE relation='cites'`
     AND `source_id IN (SELECT id FROM nodes WHERE repo=$1)`
  3. **FTS5 search**: `SELECT * FROM nodes WHERE nodes MATQ 'acpi*'`
     between SQLite `fts5` virtual table and Postgres `tsvector`/`pg_trgm`
  4. **Full node/edge round-trip**: INSERT → SELECT → DELETE idempotency
     across both carriers; mutation events journaled through Kiroku
- **Autonomous loop scenarios**:
  - **Scenario 1 (Repair-after-failure)**: Test failure → Kioku lesson lookup
    → Shikumi repair blueprint → Keiro durable workflow → PGMQ enqueue →
    Worker execution → Mori-Schema validation → Ladder rung grade → Promote
    or failed-first reschedule + bisection (Vector D) → Shikumi diagnostics
    with CodeGraphStore context → Kiroku journal → Kioku evidence ranking
  - **Scenario 2 (Kind-promotion)**: New kind `vm-console-boot` declared in
    manifest → Driver conformance check → Ladder grade → If pass, promote
    with attestation receipt → Kiroku journal → Kioku lesson for future
    runs → CodeGraphStore context for repair blueprint grounding
  - **Scenario 3 (Capability upgrade)**: Worker upgraded with `has_fault_injection`
    capability → Kind `stress-soak` re-evaluated → Driver contract re-validated
    → Ladder re-grade → If pass, promote → Kiroku journal → Kioku lesson
  - **Scenario 4 (Meta-verification)**: QuickCheck/hedgehog property tests
    for oracle sensitivity (proofHygiene, logSchema, timeoutSeconds,
    fsck/fixpoint fact kinds), CodeGraphStore façade accuracy, Mori-Schema
    schema validity → If all pass, promote ladder-wide confidence → Kiroku
    journal → Kioku evidence for future ladder-wide confidence decay
- **Driver contract** (autonomous loop seam):
  - All tool calls validated through Mori-Schema before execution
  - All structured exchanges (tool calls, workflow events, CodeGraph queries)
    journaled through Kiroku append-only
  - Ladder gate outcomes (pass/fail/unknown) journaled through Kiroku;
    evidence ranking through Kioku
  - All CodeGraphStore façade queries Mori-validated for schema compliance
  - All driver kill schedules and timeoutSeconds honored per manifest
  - All known-fail baselines documented per-suite; waiver rationale journaled
- **Ladder outcome flow**: Outcomes flow back into Kioku as lessons/waivers
  (Step 7 → next run's evidence ranking); raw driver logs (and optionally
  `rr` replays) land in L0 — closing observe→repair→gate→remember loop.
- **Meta-verification**: Property tests (QuickCheck/hedgehog) for oracle
  sensitivity, CodeGraphStore façade accuracy, Mori-Schema schema validity;
  optional mutation metrics (`cargo-mutants`/`mutatest`) to measure oracle
  sensitivity; sandbox (nsjail/bubblewrap/runc) wraps any agent-proposed
  binary before it executes; LLMs never grade a rung.


### Postgres Carrier Parity Setup (Step 4g)

The `CodeGraphStore` effect carries two backend carriers: SQLite (local testbed)
and Postgres (campaign-shared). Full carrier parity means all standard SQL
contracts yield identical results across both carriers, verified as a gating
step before any ladder rung may promote.

#### Carrier Parity Contracts (verified against SQLite `repo_graph.sqlite`
and Postgres campaign DB):

**C1 — Node existence by repo**: 
`SELECT COUNT(*) FROM nodes WHERE repo=$1` 
must return identical counts in SQLite and Postgres.

**C2 — Predicate/citation edges**: 
`SELECT COUNT(*) FROM edges WHERE relation='cites' AND source_id IN 
(SELECT id FROM nodes WHERE repo=$1)` 
must return identical counts.

**C3 — FTS5/ trigram search**: 
`SELECT COUNT(*) FROM nodes WHERE nodes MATCH 'acpi*'` (SQLite FTS5) must
return identical count to `SELECT COUNT(*) FROM nodes WHERE nodes 
MATCH 'acpi*'` using Postgres `tsvector`/`pg_trgm` similarity.

**C4 — Full round-trip idempotency**: 
INSERT a test node/edge, SELECT it back, DELETE it, then verify both
carriers return the same final state (empty/no-orphans). Mutation events
journaled through Kiroku for audit.

**C5 — FTS5 trigram index consistency**: 
The `pg_trgm` extension provides `similarity(`text,text``) operator in
Postgres, which must match SQLite's `MATCH` operator equivalence class
for the same query patterns.

**Parity verification command**:
```
cd docs/fixtures && sqlite3 test_repo_graph.sqlite < parity_contracts.sql
psql -d campaign -f parity_contracts.sql
```
Both outputs must be identical row-by-row. Differences trigger a
carrier-parity failure, blocking ladder promotion until resolved.

#### Parity Gates (before ladder promotion)

| Gate | Query | SQLite | Postgres | Requirement |
|------|-------|--------|----------|-------------|
| G1 | `SELECT COUNT(*) FROM nodes WHERE repo='mowgli'` | N | N | Must match |
| G2 | `SELECT * FROM edges WHERE relation='cites' LIMIT 1` | N | N | Must match |
| G3 | FTS5/MATCH equivalence | N | N | Must match |
| G4 | Round-trip insert-select-delete | N | N | Must match |

Parity failure blocks all ladder promotion until carriers reconciled.

#### Parity Maintenance

- **Scheduled reconciliation**: Monthly parity check runs as Keiro durable
  workflow; discrepancies logged through Kiroku, evidence ranked through Kioku.
- **Migration scripts**: If carrier schema diverges, migration scripts in
  `Campaign/Bootstrap.hs` reconcile differences; failing parity triggers
  automatic rollback to last known-good carrier state.
- **Test hook**: `carrierParityTests` in `test/codegraph/Main.hs` runs as
  part of Tier 1 acceptance gates; failure stops all promotion.


### Enhanced Meta-Verification (Step 4h)

- **Purpose**: Comprehensive property-based verification of all oracle facts,
  CodeGraphStore façade accuracy, Mori-Schema schema validity, and driver contract
  compliance to ensure the entire verification stack is trustworthy.
- **Property Tests** (QuickCheck/hedgehog):
  - **Oracle Sensitivity**: Rapidly generate test cases with varying exit codes,
    marker patterns, known-fail baselines, and timeout values to verify that
    interpreter verdicts are deterministic and consistent.
  - **CodeGraphStore Façord Accuracy**: Generate façade queries with edge cases
    (missing nodes, invalid predicates, out-of-range line numbers) and verify
    that Mori-validated responses are either correct or properly rejected.
  - **Mori-Schema Schema Validity**: Generate Mori exchange payloads that span
    the full schema space and verify that validation passes for valid inputs
    and fails for invalid inputs.
  - **Driver Contract Compliance**: Generate driver contract scenarios
    (timeout expirations, kill schedule violations, known-fail baseline
    violations) and verify that driver behavior is consistent with the contract.
- **Mutation Testing** (cargo-mutants/mutatest, optional):
  - Measure oracle sensitivity by applying mutations to interpreter logic
  - Verify that property tests detect the mutations (high sensitivity = good oracle)
  - Measure CodeGraphStore façade accuracy by mutating query results
  - Track mutation detection rate as an oracle quality metric
- **Sandbox Verification**:
  - All agent-proposed binaries wrapped in nsjail/bubblewrap/runc before execution
  - No LLM verdicts; all rung outcomes from deterministic tool verdicts only
  - Sandbox audit logs journaled through Kiroku
  - `rr` replays optionally stored in Kioku L0 for post-mortem analysis
- **Meta-Outcome Flow**:
  - Property test results flow back into Kioku as lessons/evidence weights
  - Mutation testing results inform oracle sensitivity metrics
  - Sandbox audit outcomes flow back into Kioku as risk assessments
  - All outcomes affect future run evidence ranking and worker capability assignment
- **Gate Implications**:
  - If property tests fail for any oracle, that oracle is marked "sensitive-susceptible"
  - Mutation testing results inform oracle sensitivity scoring
  - Sandbox failures trigger automatic worker quarantine and capability reassignment
  - All meta-verification outcomes journaled through Kiroku for future reference


### Full Autonomous Loop Deployment (Step 4i)

- **Purpose**: Deploy the complete observe→retrieve→decide→act→persist→validate→(ladder)gate→promote
  loop across the entire campaign ecosystem with all substrates active and interacting.
- **Integration Points**:
  - **Shikumi Decision**: Receives diagnostics from Kioku lessons + CodeGraphStore context
    + generates typed "Repair Blueprints" validated through Mori-Schema
  - **Keiro Orchestration**: Executes blueprints as durable workflows with crash-resumable
    stages, journaled through Kiroku
  - **PGMQ/Shibuya Transport**: Moves blueprints between orchestration layers via PGMQ
    queues, validated by Mori-Schema at each hand-off point
  - **Kioku Memory**: Auto-updates evidence rankings and evidence weights based on
    rung outcomes, meta-verification results, and sandbox audit logs
  - **Kiroku Journal**: Append-only store for all structured exchanges, outcomes, and
    meta-verification results; serves as the source of truth for evidence ranking
  - **Mori-Schema Middleware**: Validates all structured exchanges (tool calls, workflow
    events, CodeGraph queries, driver contract outputs) at every seam in the loop
  - **Driver Contract**: All driver interactions (kill schedules, timeoutSeconds, fact
    inputs, known-fail baselines) validated against manifest declarations before execution
  - **Capability Flags**: `has_fault_injection`, `has_qemu`, `has_sandbox`, `has_fsck`
    gate worker assignment and determine which ladder rungs a worker may execute
  - **Harness Clones**: Assessed harness clones (from HARNESS_CLONE_QUEUE.md) feed into
    driver contract declarations and capability flag assignments
- **Full Loop Scenario**:
  1. **Trigger**: Hermes detects event (test failure, symbol change, verification gate miss)
  2. **2a. Context Retrieval — Kioku**: Query episodic/semantic memory for historical
    precedents, known-fails, lessons.
  3. **2b. Code Context Retrieval — CodeGraphStore + façade**: query façade for
    `find_symbol`/`get_callers`/`get_callees`/`trace_path`; Mori-validate wire types
  4. **3. Decision — Shikumi**: Invoke Shikumi Decision Tool with diagnostics + Kioku
    lessons + code-graph context → typed "Repair Blueprint".
  5. **4. Action — Keiro / PGMQ / Shibuya-PGMQ**: 
     Keiro Durable Workflow Plugin receives blueprint.
     Shibuya-PGMQ Adapter enqueues blueprint via PGMQ.
     Worker event loop (Shikumi-Eval) processes blueprint and journals results
     back via Kiroku.
  6. **5. Persistence — Kiroku / Kioku**: 
     Kiroku journals the event append-only; on completion, Kioku updates the final
     result for future reference.
  7. **6. Verification — Mori-Schema (+ graph contracts)**: All structured exchanges
     validated through Mori-Schema middleware: workflow events, tool calls, AND
     CodeGraph node/edge/tool response schemas. Graph mutation events also journaled
     through Kiroku.
  7. **7. Ladder gate — honest rungs (VERIFICATION_LADDER)**: Deterministic oracle
     interpreters grade the changed unit against its declared ladder membership.
     • pass / passed-waived → eligible to promote (attestation receipt)
     • fail / unknown → failed-first reschedule + bisection (Vector D) → back to
       step 2b with CodeGraph diagnostics → Shikumi repair blueprint → human
       review (Campaign.Review) → re-run the same rung.
  8. **8. Ladder outcome flow**: Outcomes flow back into Kioku as lessons/waivers
     (step 7 → next run's evidence ranking); raw driver logs (and optionally `rr`
     replays) land in L0 — closing observe→repair→gate→remember loop.
  9. **9. Meta-verification**: Property tests (QuickCheck/hedgehog) for oracle
     sensitivity, CodeGraphStore façade accuracy, Mori-Schema schema validity;
     optional mutation metrics (cargo-mutants/mutatest) to measure oracle sensitivity;
     sandbox (nsjail/bubblewrap/runc) wraps any agent-proposed binary before it
     executes; LLMs never grade a rung.
- **Ecosystem-Wide Integration**: The autonomous loop operates across all campaign
  portfolio repositories (pgcl, telix, tessera, organ-bank, mowgli, peirce, mercury,
  and others), with carrier parity ensured through C1-C5 Postgres↔SQLite contracts,
  capability flags gating worker assignment, and Kioku evidence ranking informing
  future run prioritization.
- **Full Deployment Checklist**:
  - [ ] All 7 verification forms active and gated
  - [ ] All 4 barriers open (1-4)
  - [ ] All carrier parity contracts (C1-C5) verified
  - [ ] All driver conformance contracts declared and validated
  - [ ] All meta-property tests passing
  - [ ] All sandbox protections in place
  - [ ] All Kioku evidence rankings current
  - [ ] All Kiroku journals up to date
  - [ ] All harness clones assessed and integrated
  - [ ] All capability flags assigned and verified

