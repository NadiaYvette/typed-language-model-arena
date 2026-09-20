# Workqueue & Portfolio Infrastructure — typed-language-model-arena

Living workqueue and architecture reference for the typed language model ecosystem (shikumi decides, keiro journals, kioku remembers).
Scheduler ground truth: `REAL_LIMIT=0 ACTS=23 cabal run campaign-demo` — currently schedules 99 real units (95 kernel matrix cells across 19 architectures + 4 portfolio host verification units) from memory evidence.
Last updated: 2026-09-20 (added Tracks 8/9 — `kuroko` & `smirk` — as AWAITING REVIEW open-ended tracks; kuroko policy matcher moved to smirk; kuroko Dhall config fixed + env-var variant added; smirk split into core + effectful + polysemy packages).

See also [Campaign Generalization Architecture](CAMPAIGN_GENERALIZATION.md) for the strategic generalization roadmap (declarative target manifests, distributed worker federation via `pgmq`, autonomous bisection, and sovereign forge integration).

---

## 1. Portfolio Architecture & Ecosystem Map

The ecosystem operates as a 4-layer typed language model execution stack, with domain projects providing ground-truth verification targets.

```
+-----------------------------------------------------------------------------------+
| Layer 4: Verification Targets & Domain Substrates                                 |
|   * pgcl: Linux Page Clustering matrix (19 architectures × 5 kernel configs)      |
|   * telix: Verified multikernel operating system (Rust kernel-v2, Verus, Rocq)    |
|   * tessera: Hardware memory model (Sail -> Rocq, Lean 4, Iris Coq 8.20, CBMC)    |
|   * organ-bank: Compiler IR harvesting (25 donor corpses -> OrganIR JSON)         |
|   * frankenstein: Polyglot compiler (GHC/mmc/rustc -> Koka Core -> MLIR -> LLVM)  |
|   * mowgli: Multimodal logic programming in Mercury (PLP, CTL, DTMC, Kripke)      |
|   * peirce: Large Semiotic Model in Julia/Python (10 sign classes, Brandom GNN)   |
|   * mercury: Compiler promotion campaign & bootstrap verification                 |
+-----------------------------------------------------------------------------------+
                                         |
                                         v
+-----------------------------------------------------------------------------------+
| Layer 3: Campaign Orchestration (shikumi-campaign / typed-language-model-arena)   |
|   * Act 23: Real verification dispatch (gated by REAL_LIVE & REAL_LIMIT)          |
|   * Evidence-driven scheduling: failed first, then unknown, then passed (by cost) |
|   * Non-opinionated verdicts: read strictly from tool-written logs & exit codes   |
+-----------------------------------------------------------------------------------+
                                         |
                                         v
+-----------------------------------------------------------------------------------+
| Layer 2: Memory & Execution Substrates                                            |
|   * keiro: Resumable, durable typed workflow engine with PostgreSQL journal       |
|   * kioku: L0/L1/L2/L3 episodic and semantic memory with namespace isolation      |
|   * pgmq-hs / shibuya-pgmq-adapter: Message queue persistence                     |
+-----------------------------------------------------------------------------------+
                                         |
                                         v
+-----------------------------------------------------------------------------------+
| Layer 1: Core Algebra & Effectful Streams                                         |
|   * shikumi: Typed agent decision runtime & patch planning                        |
|   * baikai: Protocol mediation & session lifecycles                               |
|   * keiki: Event schema definitions & telemetry                                   |
|   * kiroku: Append-only event sourcing store                                      |
|   * shibuya: Async streaming & effectful pipelines                                |
+-----------------------------------------------------------------------------------+
```

### Portfolio Repository & Verification Matrix

| Project | Role | Verification Harness | Verdict Criteria | Status |
| :--- | :--- | :--- | :--- | :--- |
| **`arena`** | Orchestration Arena | `cabal test all` / `cabal run campaign-demo` | Clean compile, act passes | Active (`main`) |
| **`pgcl`** | Page Clustering Matrix | `bash matrix-driver-all.sh ARCH CONFIG` | Initramfs LTP subtotal banner | 95 cells active |
| **`telix`** | Verified Multikernel OS | `make -C ~/src/telix verify` | `"Telix-side checks passed."` | Active (`host@verify`) |
| **`tessera`** | HW Memory Model & Proofs | `lake --dir ~/src/tessera/proof build` | `"Build completed successfully."` | Active (`host@proof`) |
| **`organ-bank`** | Compiler IR Harvesting | `cabal --project-dir=~/src/organ-bank test organ-ir` | 7 test suites pass | Active (`host@organ-ir`) |
| **`mowgli`** | Mercury Multimodal Logic | `make -C ~/src/mowgli film_*_test && ...` | `"all checks passed"` | Active (`host@film-fixture`) |
| **`frankenstein`** | Polyglot MLIR Compiler | `cabal run frankenstein -- --demo` | Demo factorial binary emit | Task #386 active |
| **`peirce`** | Large Semiotic Model | `julia --project=. evaluate.jl` | 0% trichotomy violations | Phase 2 active |
| **`mercury`** | Compiler Promotion | `REPLAY=mercury cabal run campaign-demo` | Stage promotion verified | Closed / proven |

---

## 2. Track 1: `pgcl` (Linux Page Clustering Matrix)

The Linux page clustering kernel verification matrix tests memory subsystem stability under QEMU across 19 architectures and 5 kernel configuration tiers (`mainline`, `0`, `2`, `4`, `6`).

### Current Status
- **Reachable Catalog**: 95 cells planned against host reality (19 toolchains, 16 QEMU binaries, defconfigs, and initramfs).
- **Catalog Audit (`pgcl/matrix-catalog-audit.sh`)**: **CLOSED** (exit code 0; toolchains, QEMU binaries, machines, initramfs, and defconfig remappings verified).
- **Alpha Tier Baseline (QEMU Clipper)**:
  - Initial live run confirmed all 5 configs build and boot into QEMU Clipper cleanly (rc=0, 73 LTP passed).
  - Root-caused missing LTP failure names in serial UART backpressure and an outdated April `init` script.
  - Rebuilt `initramfs-alpha.cpio.gz` and `initramfs-arm.cpio.gz` with current `init` (restores immediate fail dump and `LTP FAIL LIST`).
  - Established known-failure baseline: sole failing test across configs is `mmap3: FAIL (exit=2)` (identical to May baseline).
  - Added `knownFailuresFor "alpha" = ["mmap3"]` to [`Campaign.Real.hs`](file:///home/nyc/src/typed-language-model-arena/shikumi-campaign/src/Campaign/Real.hs).
- **LoongArch Baseline**: 3 consecutive runs fail identical set `["fork07", "fork09", "fork13", "mmap3"]` under la464 emulation (`knownFailuresFor "loongarch64"`).

### Next Milestones
1. **Live Alpha Tier Batch**: Execute `REAL_LIVE=1 REAL_UNIT=pgcl/alpha@*` to verify that refreshed initramfs emits `LTP FAIL LIST: mmap3` and promotes all 5 cells to `passed-waived`.
2. **`arm-lpae` Tier Execution**: Next 5 cells in queue (`arm-lpae@0`, `arm-lpae@2`, `arm-lpae@4`, `arm-lpae@6`, `arm-lpae@mainline`).
3. **`hppa` / `hppa64` Baseline Harvest**: June logs show single LTP failures; run two repeat boots each to establish documented known-fails baselines.
4. **Full Catalog Campaign**: Sequential live execution across `microblaze`, `mips64`, `or1k`, `xtensa`, `sh4`, `riscv32`, `sparc64`, `s390x`, `ppc64`.

---

## 3. Track 2: `telix` (Verified Multikernel Operating System)

Telix is a formally verified multikernel operating system designed for hardware-isolated computing.

### Current Status
- **Host Verification (`telix/host@verify`)**: Integrated into [`Campaign.Real`](file:///home/nyc/src/typed-language-model-arena/shikumi-campaign/src/Campaign/Real.hs). Runs `make -C ~/src/telix verify` (kernel-v2 host unit tests + formatting check in 1.2s; verified live with `"Telix-side checks passed."`).
- **Subsystems**:
  - `kernel-v2`: Second-round verified kernel in a clean Cargo workspace (`tools/build-kernel-v2.sh`).
  - `telix-verus`: Verus formal verification of memory isolation and page table manipulation in Rust.
  - `verify-rocq`: Rocq/Iris machine specifications (pending K1 machine-interface layer in `tessera/hardware/rocq`).

### Next Milestones
1. **Verus Unit Integration**: Add `telix/host@verus` unit to execute Verus proofs over verified kernel crates.
2. **QEMU Bare-Metal Boot**: Wire bare-metal QEMU boot test for `telix-mini` and `kernel-v2` across `aarch64` and `x86_64`.
3. **Tessera Machine Interface Seam**: Connect Rocq kernel specs in `tessera/hardware/rocq` once K1 definitions land.

---

## 4. Track 3: `tessera` (Hardware Memory Model & Verification)

Tessera specifies hardware memory consistency, TLB shootdown, and page table walks using Sail, Lean 4, Rocq, and CBMC.

### Current Status
- **Lean 4 Proof Track (`tessera/host@proof`)**: Integrated into [`Campaign.Real`](file:///home/nyc/src/typed-language-model-arena/shikumi-campaign/src/Campaign/Real.hs). Runs `lake --dir ~/src/tessera/proof build` (66/66 modules pass in <1s; verified live with `"Build completed successfully."`).
- **Axiom Hygiene**: Zero `sorryAx` across the entire import tree; theorem `Tessera.WF_split_at` depends strictly on Lean 4 standard axioms `[propext, Quot.sound]`.
- **Property-2 Iris Coq 8.20 (`property2/coq`)**: 12 concurrent memory models verified (`HelloIris`, `mp`, `tlb_shootdown`, `rmap_defer`, `refcount_race`, `pin_ledger`, `swap_device`, `batch_free`, `stale_put`, `quarantine`, `floor_at_present`, `ref_floor`).
- **Property-2 CBMC Regressions (`property2/cbmc`)**: 14 bounded model checking properties verified (`SUITE OK`).
- **Hardware QEMU Differential Testing (`hardware/qemu-diff`)**: LoongArch `check_ps` / `match` / `PA` differential tests pass against Sail model.

### Next Milestones
1. **Fix MIPS QEMU Differential Test Harness**: Fix C argument signature in `hardware/qemu-diff/mips_decode_diff.c` (`compute_pagemask(&env, ...)` vs `compute_pagemask(val)`).
2. **Rocq 9.2 vs GPFSL Opam Switch Sync**: Recompile `third_party/gpfsl` under Rocq 9.2 switch to resolve .vo version mismatch (82000 vs 90299) and achieve clean `CI OK` on `tessera/ci.sh`.
3. **Multi-Track Campaign Units**: Expose `tessera/host@iris` and `tessera/host@cbmc` as first-class campaign units.

---

## 5. Track 4: `organ-bank` & `frankenstein` (Polyglot Compiler Infrastructure)

Organ Bank harvests intermediate representations from compiler corpses into a uniform JSON format (`OrganIR`). Frankenstein consumes OrganIR and lowers multi-language programs to MLIR and LLVM.

### Current Status
- **OrganIR Verification (`organ-bank/host@organ-ir`)**: Integrated into [`Campaign.Real`](file:///home/nyc/src/typed-language-model-arena/shikumi-campaign/src/Campaign/Real.hs). Runs `cabal --project-dir=~/src/organ-bank test organ-ir` (verified live; all 7 test suites pass including roundtrip, transform, fuzz-parse, large-file 1000-definition stress test).
- **25 Donor Shims**: GHC Core, rustc MIR, mmc HLDS, idris2, lean4 LCNF, erlc, purs CoreFn, ocaml, koka, swift SIL, agda, fsharp, scala3, julia, zig, c, cpp, fortran, ada, sml, cl, scheme, prolog.
- **6 Independent Frontends**: SML, Erlang, Scheme, Prolog, Lua, Forth.
- **Frankenstein Core Pipeline**: Reuses donor ASTs through a Koka-inspired Core IR with Perceus reference counting and MLIR emission (`func`, `arith`, `scf`, `cf`).

### Next Milestones
1. **Task #386 (Plotkin Self-Compiler Hang)**:
   - Root cause: In `MlirEmit/Emitter.hs`, generic closure-indirect call paths (`EApp`) emit a single `llvm.call` for curried functions returning functions, causing PAP wrappers to be passed as `Int` arguments in `emitLambdaLift`.
   - Fix: Implement oversaturated multi-step dispatch on the `EApp` closure-indirect path matching direct function calls.
2. **Frankenstein Cabal Alignment**: Restore `default-language: GHC2024` in `frankenstein.cabal` to support GHC 9.14 API alignment.
3. **End-to-End Campaign Unit (`frankenstein/host@demo`)**: Wire `cabal run frankenstein -- --demo` into the campaign once Task #386 lands.

---

## 6. Track 5: `mowgli` & `peirce` (Logic Programming & Semiotic Models)

Mowgli explores multimodal logic programming in Mercury. Peirce implements a Large Semiotic Model in Julia and Python.

### Current Status
- **Mowgli Verification (`mowgli/host@film-fixture`)**: Integrated into [`Campaign.Real`](file:///home/nyc/src/typed-language-model-arena/shikumi-campaign/src/Campaign/Real.hs). Runs `src/logic/film_episode_test` and `src/logic/film_annotation_fixture_test` (verified live with `"all checks passed"`). Adapter in `src/adapters/llada_interface.py`.
- **Mowgli Core Modules**: 12 Mercury modules and 14 runnable demos combining semirings, PLP (Sato semantics), CTL model checking, DTMC value iteration, multimodal Kripke structures (S5/S4/KD), and Kowalski-Sergot event calculus.
- **Citation Verification**: `tools/verify_citations.py` automatically checks identifiers against Crossref, arXiv, and DBLP APIs.
- **Peirce Large Semiotic Model**: Full pipeline operating over Peircean sign structures; 0% trichotomy violations on Phase 1 checkpoint; 33,517 training text chunks across literature and scientific corpora.

### Next Milestones
1. **Mowgli Grand Unified Demo Unit (`mowgli/host@demos`)**: Add campaign unit running all 14 logic demos (`make run`).
2. **Peirce Evaluation Unit (`peirce/host@eval`)**: Wire `julia --project=. evaluate.jl` downstream evaluation suite into campaign memory.

---

## 7. Track 6: Reviewer Accessibility & AI Coding Assistant REPL Integration (MCP, Skills, & Plugins)

External interlocutors and reviewers evaluating the portfolio should be able to query, verify, and inspect the state of any project directly from their interactive AI coding assistant REPL (Antigravity, Claude Code, Cursor, Windsurf, Aider) without needing to memorize raw shell commands (`REAL_LIMIT=0 ACTS=23 cabal run campaign-demo`) or manually probe PostgreSQL sockets.

### Objectives & Surface Area
- **Model Context Protocol (MCP) Server (`shikumi-campaign-mcp`)**:
  - Implement an MCP server exposing typed JSON-RPC tools:
    - `campaign_discover`: List discovered portfolio verification units and host toolchain requirements.
    - `campaign_schedule`: Inspect the memory-ranked schedule, priorities, and evidence rationale.
    - `campaign_run`: Dispatch real verification units (single cell, budget-capped, or full matrix) with live log capture.
    - `campaign_evidence`: Query Kioku memory lessons, documented known-fails baselines, and execution durations.
    - `campaign_review_branches`: List candidate repair branches from autonomous fixers, display unified diffs, and record human approve/reject verdicts.
- **Packaged Assistant Skill (`/campaign`)**:
  - Provide an assistant skill specification (`skills/shikumi-campaign/SKILL.md`) enabling natural conversational workflows:
    - Reviewer: *"What is our regression baseline for LoongArch?"* -> Assistant queries Kioku memory via `campaign_evidence`.
    - Reviewer: *"Run the Lean 4 proof verification in Tessera"* -> Assistant dispatches `tessera/host@proof` via `campaign_run` and reports the real log verdict.
    - Reviewer: *"Show me candidate repairs on Mowgli"* -> Assistant inspects review branches and displays diffs.
- **Editor & IDE Integration**:
  - Status lenses in Cursor / VS Code / Neovim for managed portfolio projects.

## 7. Track 6: Reviewer Accessibility & AI Coding Assistant REPL Integration (MCP, Skills, & Plugins) — CLOSED

- **Proven in arena commit `eb168d7`**:
  - MCP stdio server [`scripts/campaign-mcp.py`](file:///home/nyc/src/typed-language-model-arena/scripts/campaign-mcp.py) exposing 7 typed tools (`campaign_status`, `campaign_discover`, `campaign_schedule`, `campaign_verify`, `campaign_evidence`, `campaign_review`, `campaign_classify`).
  - Human/reviewer CLI bridge [`scripts/campaign-cli.py`](file:///home/nyc/src/typed-language-model-arena/scripts/campaign-cli.py) supporting formatted text tables and `--json`.
  - Packaged Antigravity workspace skill ([`.agents/skills/shikumi-campaign/SKILL.md`](file:///home/nyc/src/typed-language-model-arena/.agents/skills/shikumi-campaign/SKILL.md)) and plugin bundle ([`.agents/plugins/shikumi-campaign/`](file:///home/nyc/src/typed-language-model-arena/.agents/plugins/shikumi-campaign/)).
  - Preconfigured cross-assistant endpoints ([`.mcp.json`](file:///home/nyc/src/typed-language-model-arena/.mcp.json) for Claude Code / open standard, [`.cursor/mcp.json`](file:///home/nyc/src/typed-language-model-arena/.cursor/mcp.json) for Cursor, [`.agents/mcp_config.json`](file:///home/nyc/src/typed-language-model-arena/.agents/mcp_config.json) for Antigravity).
  - All 4 domain host verification units (`telix`, `tessera`, `organ-bank`, `mowgli`) verified live through the CLI and MCP stdio pipes with verified exit codes and logs.

---

## 8. Track 7: `mercury` (Compiler Promotion Campaign) — CLOSED

- Proven in arena commit `2216b59`: `REPLAY=mercury cabal run campaign-demo`.
- Verified live engine, replay engine, scripted drama, and parent-commit verification geometry end to end.

---

## 8b. Track 8: `kuroko` (Autonomous Agent Sidecar) — AWAITING REVIEW

Kuroko is an unobtrusive, effectful autonomous coding agent runtime (< 1,500 LOC) built on `effectful`, extensible records (vinyl/docrecords), `persistent-effectful` + SQLite, and Dhall-typed configuration.

### Current Status
- **Status**: **Awaiting review** — open-ended track; goals not yet firmed up beyond the landed scaffolding.
- **Policy & config hardening (landed)**:
  - Tool policy pattern rules now use **smirk** (pure Haskell glob + ReDoS-safe fuel-bounded PCRE) instead of `Glob` + `regex-with-pcre`, dropping the C FFI dependency from the arg-scanning path.
  - `config/agent.dhall` is now a valid, self-contained default (includes the required `policy` block: budget cap, rate cap, glob/PCRE `patternRules`). Previously it was missing `policy` and failed typechecking.
  - `config/agent-env.dhall` demonstrates Dhall-native env-var imports (`env:KUROKO_MODEL as Text`) for deployment overrides.
- **Dhall config grammar reference** (verified against dhall 1.42.3, kept as a workqueue note since it bit hard):
  - Empty list literals require an annotation: `[] : List Text`.
  - `None` is a polymorphic builtin — write it applied: `None { maxCallsPerWindow : Natural, windowSeconds : Double }`.
  - Union *values* are projections of the union type: with `let verdict = < AllowAuto | Denied : Text | … >`, write `verdict.Denied "…"`, not `<Denied> "…"`.
  - `env:VAR` splices the value **as Dhall code** by default; `env:VAR as Text` treats it as a raw string literal. Missing var → hard "Missing environment variable" error (all-or-nothing, no `${VAR:-default}`).

### Next Milestones (open-ended, pick as reviewed)
1. **Reviewer pass on the policy/config changes** (see "Awaiting review" note below).
2. Decide whether `kuroko` should become a first-class campaign verification unit (`kuroko/host@verify`: `cabal build && cabal test` wired into `Campaign.Real`), or remain a portfolio library tracked only here.
3. Optional: expose MCP `campaign_*` tools over kuroko's own agent loop (kuroko currently *serves* MCP; the arena orchestrates it).
4. Optional: ReDoS-fuel tuning for `matchArgPCRE` (currently `Unlimited`; smirk's `StepBudget` is available if arg payloads ever grow adversarial).

---

## 8c. Track 9: `smirk` (Pure PCRE + Glob Engine) — AWAITING REVIEW

Smirk is a 100% native Haskell, step-bounded (ReDoS-safe), pausable/resumable PCRE engine with glob compilation and optional algebraic-effect interpreters.

### Package Layout (landed)
Split into three packages so effect interfaces don't drag each other in (module paths unchanged; each effect package lives in its own subdirectory because cabal rejects multiple `.cabal` files in one directory):
| Package | Cabal file | Contents |
| :--- | :--- | :--- |
| **`smirk`** (core) | `smirk.cabal` (root) | PCRE parser/AST/bytecode/VM, glob engine, sequence polymorphism, quasiquoters — no effect-system deps |
| **`smirk-effectful`** | `effectful/smirk-effectful.cabal` | `Smirk.Effect.Effectful` (`RegexEngine` as an `effectful` effect) + `smirk-effectful-test` |
| **`smirk-polysemy`** | `polysemy/smirk-polysemy.cabal` | `Smirk.Effect.Polysemy` (`RegexEngine` as a `polysemy` effect) + `smirk-polysemy-test` |
Effect tests moved out of the core `smirk-test` into the per-interface suites. Dev compiler pinned to `ghc-9.12.4` (`cabal.project`); older-GHC compat deferred to productisation. Note: `cabal test all` also runs the local `../polysemy` dep's own suite, which currently fails to build ("Could not find test program") — pre-existing, unrelated to smirk; test the three `smirk*` suites individually.

### Current Status
- **Status**: **Awaiting review** — open-ended track; goals not yet firmed up.
- **New consumer (landed)**: `kuroko`'s tool-policy matcher (`Kuroko.Effect.Policy.matchToolGlob` / `matchArgPCRE`) now uses smirk **core** only (no polysemy/effectful drag-in for kuroko).
- **Engine surface**: PCRE parse (lookarounds, named groups, backrefs, `(?i)/(?s)/(?m)`), glob → AST (path-aware `**`, brace expansion, char classes), fuel-bounded VM, mono-traversable sequence polymorphism (Text, ByteString, Seq, Vector, NonEmpty).

### Next Milestones (open-ended, pick as reviewed)
1. **Reviewer pass on the kuroko integration** (shared with Track 8).
2. Decide smirk's verification story: does it get a `smirk/host@test` campaign unit, or is its `smirk-test` suite (`ParserSpec`, `VMSpec`, `GlobSpec`, …) sufficient and tracked here?
3. Optional: differential testing smirk's VM against a reference PCRE backend (e.g. `regex-with-pcre`) over a shared pattern corpus, to catch semantic drift in lookarounds/backrefs.
4. Optional: `Smirk.Effect.Polysemy`/`Smirk.Effect.Effectful` are now separate packages — decide which (if either) kuroko should adopt as its default effect interface (kuroko currently uses its own `effectful` policy layer + smirk core only).

---

### Review Status Convention (Tracks 8 & 9)
Both new tracks are marked **AWAITING REVIEW** deliberately: they are seeded with concrete, verified landed work but **without definite goals** — the "Next Milestones" lists are proposals to be chosen/edited during review, not committed targets. A track leaves AWAITING REVIEW when a reviewer (human or assistant) has confirmed the landed changes and picked (or deferred) its next milestones.

---

## 9. Living Commit & Mirror Ledger

### Remotes & Key IDs
- **User Remotes**: Nadia Yvette Chambers (`NadiaYvette` on GitHub, Disroot, Framagit, GitCode).
- **Radicle Identity**: `did:key:z6Mkv2YCY2vx7ax92q8RzmPJLQv2x2cpEaFDV6vn7FaoFzB8`.
- **Radicle Repositories**:
  - `typed-language-model-arena`: `rad:z3sERP1qYmgKUQzWwhquEnzFJu7fj`
  - `telix`: `rad:z2aN26h56wT3bYspR1hSksuS76tM1`
  - `tessera`: `rad:z4YXir8Ly9E92ypGii45SkJS6HtPd`
  - `mowgli`: `rad:z2jiunVzMrWnfcefCFN52VRo5mudp`

### Recent Ledger
- **arena** — Added Tracks 8 (`kuroko`) & 9 (`smirk`) to the workqueue as **AWAITING REVIEW** open-ended tracks (seeded with landed work, goals to be picked at review), plus a review-status convention and a verified Dhall config-grammar reference.
- **kuroko** — Tool policy pattern matching now uses **smirk** (pure glob + ReDoS-safe fuel-bounded PCRE); dropped `Glob` + `regex-with-pcre` deps. Fixed `config/agent.dhall` (was missing required `policy` block → typecheck failure); added `config/agent-env.dhall` demonstrating `env:VAR as Text` Dhall env imports.
- **smirk** — Split into 3 packages: core `smirk` (no effect-system deps, root `smirk.cabal`), `effectful/smirk-effectful.cabal`, `polysemy/smirk-polysemy.cabal`; effect tests moved to per-interface suites (commit `f17d488`). First in-ecosystem production consumer: `Kuroko.Effect.Policy.matchToolGlob` / `matchArgPCRE` (core only; kuroko's closure verified free of polysemy & regex-with-pcre).
- **kuroko** — Policy matcher via smirk core + fixed/extended Dhall configs, commit `2ed7a20`.
- **smirk / kuroko** — Dev compiler pinned to recent 9.12 series (smirk `cabal.project`: `ghc-9.12.4`; kuroko stays `9.12.2`); older-GHC compatibility deferred to productisation. Maintainer line standardized to `Nadia Chambers <nadia.yvette.chambers@ik.me>`.
- **arena** — Built and verified complete AI Assistant REPL & Reviewer integration:
  - Landed [`scripts/campaign-mcp.py`](file:///home/nyc/src/typed-language-model-arena/scripts/campaign-mcp.py) and [`scripts/campaign-cli.py`](file:///home/nyc/src/typed-language-model-arena/scripts/campaign-cli.py) exposing 7 typed tools (`status`, `discover`, `schedule`, `verify`, `evidence`, `review`, `classify`).
  - Added native JSON query modes to `shikumi-campaign` (`DISCOVER=json`, `SCHEDULE=json`, `EVIDENCE_FORMAT=json`, `REVIEW_FORMAT=json`, `SERVER_FORMAT=json`) with clean stderr log separation.
  - Packaged Antigravity workspace skill ([`.agents/skills/shikumi-campaign/SKILL.md`](file:///home/nyc/src/typed-language-model-arena/.agents/skills/shikumi-campaign/SKILL.md)), Antigravity plugin ([`.agents/plugins/shikumi-campaign/`](file:///home/nyc/src/typed-language-model-arena/.agents/plugins/shikumi-campaign/)), and cross-assistant MCP configs ([`.mcp.json`](file:///home/nyc/src/typed-language-model-arena/.mcp.json), [`.cursor/mcp.json`](file:///home/nyc/src/typed-language-model-arena/.cursor/mcp.json)).
  - Verified live execution of all 4 domain host units (`telix`, `tessera`, `organ-bank`, `mowgli`) through the CLI and MCP stdio protocols.
- **arena** — Multi-project real verification dispatch landed in [`Campaign.Real`](file:///home/nyc/src/typed-language-model-arena/shikumi-campaign/src/Campaign/Real.hs): discovered and verified `telix`, `tessera`, `organ-bank`, and `mowgli` host units live.
- **arena** — Extended [`scripts/reconstitute.sh`](file:///home/nyc/src/typed-language-model-arena/scripts/reconstitute.sh) to pin all 7 portfolio domain repositories alongside the 9 Shinzui framework repositories.
- **arena** — Added `knownFailuresFor "alpha" = ["mmap3"]` and arch-scoped classifier to `Campaign.Real.hs` and `real-validate`.
- **pgcl** — Rebuilt `initramfs-alpha.cpio.gz` and `initramfs-arm.cpio.gz` with current `init` (restored immediate fail dump, `LTP FAIL LIST`).
- **arena** — Fixed stale workflow wart (`CLEANUP=stale`); 0 discovered / 0 unregistered on resume pass.
- **pgcl `542bf6e`** — riscv32 row fix (`defconfig 32-bit.config`) + `matrix-catalog-audit.sh`.
- **arena `2216b59`** — Mercury replay demo: compiler promotion campaign verified end to end.
- **arena `29c444d`** — Ground-truth driver discovery pointed at `matrix-driver-all.sh`.
