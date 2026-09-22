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
