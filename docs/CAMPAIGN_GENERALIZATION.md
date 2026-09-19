# Campaign Infrastructure Generalization & Integration Architecture

Living design and architecture reference for generalizing the `typed-language-model-arena` campaign infrastructure into an extensible, distributed, and sovereign verification runtime.
Date: 2026-09-19.

---

## 1. Executive Summary & Architectural Foundation

The campaign stack (`shikumi-campaign`, `keiro`, `kioku`, `kiroku`, `shikumi`) provides an execution and evaluation runtime designed for high-consequence, long-running, and expensive verification workloads.

Unlike conventional CI/CD runners (GitHub Actions, GitLab CI) and conversational AI test scripts, this architecture is grounded on five foundational invariants:

1. **Typed Durability (`keiro`)**: Every execution step is a typed state machine transition journaled to an append-only event store (`kiroku`). Long-running, expensive builds and boots survive interruptions and resume mid-flight without restarting from scratch.
2. **Episodic & Semantic Memory (`kioku`)**: Test results are not ephemeral console output. They are distilled into structured memory tiers (L0 raw logs, L1 episodic summaries, L2 generalizable lessons and heuristics, L3 behavioral priors) partitioned by safe namespaces.
3. **Evidence-Driven Scheduling**: The scheduler queries memory to rank work: **failed first** (reproduce fresh regressions), **unknown next** (explore uncharacterized surface area), and **passed last** (regression protection, ordered cheapest first).
4. **Honest, Non-Opinionated Oracles**: Language models *never* decide whether a test passed. Verdicts are derived strictly from guest log banners, process exit codes, dmesg audits, and documented known-fails baselines (`knownFailuresFor`).
5. **Human Merge Seam (`Campaign.Review`)**: Automated repair proposals land on isolated review branches; operator approvals/rejections feed back into memory distillation to refine subsequent planning rounds.

---

## 2. Generalization Architecture

```
               +-------------------------------------------------+
               |              Decentralized Forges               |
               |       (Radicle, ForgeFed, Disroot, Git)         |
               +-----------------------+-------------------------+
                                       | Git refs & patch events
                                       v
+---------------------------------------------------------------------------------+
|                         Generalised Campaign Daemon                             |
|                                                                                 |
|  +--------------------+   +-----------------------+   +----------------------+  |
|  | Target Discovery   |   | Evidence Scheduler    |   | Autonomous Synthesis |  |
|  | - Capability probe |   | - Failed-first        |   | - Git bisection      |  |
|  | - Target manifests |   | - Uncertainty score   |   | - Patch generation   |  |
|  | - Container/VM/HIL |   | - Budget pacing gate  |   | - Human review seam  |  |
|  +---------+----------+   +-----------+-----------+   +----------+-----------+  |
|            |                          |                          |              |
|            +--------------------------+--------------------------+              |
|                                       v                                         |
|  +---------------------------------------------------------------------------+  |
|  | Durable Execution & Memory Substrate                                      |  |
|  | - Keiro Workflows: Lease-managed, step-journaled state machines           |  |
|  | - Kioku Memory: L0 (logs) -> L1 (episodes) -> L2 (lessons) -> L3 (priors) |  |
|  +------------------------------------+--------------------------------------+  |
+---------------------------------------|-----------------------------------------+
                                        | Distributed tasks (pgmq / NATS)
                                        v
+---------------------------------------------------------------------------------+
|                              Execution Workers                                  |
|   +-------------------+   +--------------------+   +------------------------+   |
|   | Host / Containers |   | Bare-Metal Silicon |   | Cloud / GPU Nodes      |   |
|   | (Lean4, Coq, GHC) |   | (HIL, QEMU, PDUs)  |   | (vLLM, CBMC, Slurm)    |   |
|   +-------------------+   +--------------------+   +------------------------+   |
+---------------------------------------------------------------------------------+
```

### Vector A: Declarative Target Manifest Protocol (`target.yaml` / `CampaignTarget.toml`)
Currently, `Campaign.Real.hs` encodes target details as Haskell records (`RealUnit`). To generalize across any arbitrary repository without recompiling the orchestrator, targets become self-describing manifests colocated in projects:

```yaml
# Example: .campaign-target.yaml
project: tessera
units:
  - name: proof
    kind: host-verify
    workdir: proof
    command: lake build
    timeout: 300s
    oracle:
      type: text-marker
      marker: "Build completed successfully."
      exit_code: 0
    requirements:
      toolchains: ["lean4", "lake"]

  - name: iris
    kind: host-verify
    workdir: property2/coq
    command: bash build.sh
    timeout: 600s
    oracle:
      type: regex
      pattern: "^PASS: property2/coq"
    requirements:
      opam_switch: "surd"
      packages: ["coq-iris", "rocq-core"]
```

### Vector B: Pluggable Oracle DSL & Baseline Provenance
Oracles extend beyond substring matching:
- **Exit Code + Marker**: Process exit code 0 corroborated by tool-printed success banners.
- **Structured Schema Oracles**: Validating structured JSON, TAP, or JUnit XML outputs against JSON schemas.
- **Proof Hygiene Oracles**: Verifying that zero unproven assumptions (`sorryAx`, `Admitted`) appear in the proof dependency tree.
- **Documented Known-Fails Baselines**: Dynamic tracking of known-failures maps pinned to git tree hashes, distinguishing known environment bugs from novel regressions.

### Vector C: Distributed Worker Federation via `pgmq`
Decouple the orchestrator from local host processes using the existing `pgmq-hs` and `shibuya-pgmq-adapter` foundations:
- **Capability Registration**: Workers register their hardware profile (e.g., `arch=loongarch64`, `has_qemu_clipper=true`, `has_cbmc=true`, `gpus=4`).
- **Leased Workflow Steps**: Keiro workflow steps publish execution leases to PostgreSQL queues. Remote workers claim the lease, execute in an isolated container/VM, stream log chunks to `kiroku`, and complete the step.

### Vector D: Autonomous Bisection & Closed-Loop Repair
When a unit transitions from `passed` (or `passed-waived`) to `failed`:
- Keiro automatically spawns an autonomous **Bisection Workflow** across git history.
- The bisection workflow launches verification cells at each commit to locate the culprit revision.
- The culprit diff and failure transcript are fed into Shikumi’s patch synthesis engine to generate candidate repairs on a `campaign/<run>` branch for human operator review (`Campaign.Review`).

### Vector E: Information-Theoretic Active Scheduling
Upgrade the scheduling heuristic (`failed > unknown > passed`) to Bayesian active learning:
- When changes occur in shared specifications (e.g., `tessera` hardware models), the scheduler prioritizes dependent downstream cells in `pgcl` and `telix`.
- Work is scheduled to maximize information gain and reduce uncertainty across the entire portfolio graph.

---

## 3. Integration Ecosystems & Infrastructure Targets

### 1. Sovereign & Peer-to-Peer Code Forges (Radicle & ForgeFed)
- **Radicle CI Integration**: Connect the campaign runner directly to Radicle seed nodes (`rad:z3sERP1qYmgKUQzWwhquEnzFJu7fj`).
- **Cryptographic Attestations**: When a contributor submits a Radicle patch, Keiro executes the matrix and publishes signed verification attestations (cryptographic receipts binding the git commit to verified proof logs and test outcomes).

### 2. Formal Proof & Mechanized Verification Networks
- **Long-Running Proof Farms**: Proof checking in Lean 4, Rocq/Iris, Isabelle/HOL, and Verus requires heavy compute. Keiro’s durability ensures that interrupted multi-hour proof verification jobs resume from their last checked module.
- **Cross-Repository Proof Consistency**: Verifying that changes to foundational hardware specs (Sail/Rocq) preserve theorems in dependent operating system kernels (`telix`).

### 3. Linux Kernel & Operating System Validation Networks
- **KernelCI / Upstream Integration**: The 95-cell `pgcl` matrix (19 architectures × 5 kernel configs) integrates directly with KernelCI, LKFT (Linaro), and 0-Day bot matrices.
- **Hardware-in-the-Loop (HIL) Testbeds**: Testing real silicon (ARM SBCs, RISC-V development boards, FPGA soft-cores) connected via serial multiplexers and networked power distribution units (PDUs). Keiro’s timeout and lease mechanics handle cold power-cycle resets on hardware lockup.

### 4. Polyglot Compiler Pipelines & Differential Fuzzing
- **Differential Compilation Matrix**: Compilers like `frankenstein` and IR harvesters like `organ-bank` translate between 25 source languages and intermediate representations.
- A generalized campaign runner can cross-compile equivalent programs across compilers (GHC Core vs mmc HLDS vs Rust MIR vs MLIR) and verify observational equivalence (bisimulation) across all targets.

### 5. Autonomous Coding Agent Evaluation Arenas
- **Rigorous Benchmarking Harness**: Existing coding agent benchmarks (SWE-bench, WebArena) frequently suffer from brittle Python scripts, non-resumable container crashes, and hallucinated evaluations.
- Shikumi-campaign provides an enterprise-grade execution harness for benchmarking coding agents: typed durability, append-only PostgreSQL telemetry, verifiable non-opinionated oracles, and zero evaluation leakage.

---

## 4. Implementation Roadmap

| Phase | Milestone | Objective |
| :--- | :--- | :--- |
| **Phase 1** | In-Tree Target Manifests | Support `.campaign-target.yaml` discovery alongside hardcoded definitions |
| **Phase 2** | Standardized Oracle DSL | Implement structured log assertion rules (exit code, markers, JSON schema) |
| **Phase 3** | Autonomous Git Bisection | Add automated bisection workflows triggered on pass-to-fail regressions |
| **Phase 4** | Remote Worker Leasing | Connect `pgmq` queue consumers for distributed multi-machine execution |
| **Phase 5** | Radicle Attestation Seam | Emit signed cryptographic verification receipts to Radicle seed nodes |
