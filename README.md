# typed-language-model-arena

A playground, driver laboratory, and durable orchestration engine built on **Nadeem Bitar's typed language model framework** (`shikumi`, `keiro`, `kioku`, `baikai`).

## Ecosystem Overview

The arena synthesizes Nadeem Bitar's four-layer typed LM stack:

| Layer | Repository | Role |
| :--- | :--- | :--- |
| **Provider** | [`baikai`](https://github.com/shinzui/baikai) | Typed LLM transport, model definitions, token accounting, and cost models. |
| **Structured LM** | [`shikumi`](https://github.com/shinzui/shikumi) | Typed schemas, `Program` type, combinators, dataset generators, and prompt evaluation. |
| **Workflow / Event Store** | [`keiro`](https://github.com/shinzui/keiro) / [`keiki`](https://github.com/shinzui/keiki) / [`kiroku`](https://github.com/shinzui/kiroku) | Durable workflow runtime over append-only PostgreSQL event streams. |
| **Agent Memory** | [`kioku`](https://github.com/shinzui/kioku) | Event-sourced hierarchical agent memory: L0 sessions → L1 lessons → L2/L3 persona. |

### Packages in this Workspace

- **[`shikumi-hello`](shikumi-hello)** — Progressive tutorial rungs (Tiers 1–7): compose, evaluate, optimize, trace/replay, ReAct agent, CLI, and streaming.
- **[`shikumi-coder`](shikumi-coder)** — Guarded, exact-match code editing engine with strict AST and symbol preservation.
- **[`toy-fixer`](toy-fixer)** — Autonomous code-repair agent loop over guarded edits.
- **[`shikumi-campaign`](shikumi-campaign)** — 25-act durable orchestration engine managing verification cells across Linux kernel matrix boots, formal proofs, workflow timers, and promotion campaigns.
- **[`docs/WORKQUEUE.md`](docs/WORKQUEUE.md)** — Living scheduler queue, portfolio roadmap, failure baseline records, and commit ledger.
- **[`docs/CAMPAIGN_GENERALIZATION.md`](docs/CAMPAIGN_GENERALIZATION.md)** — Architectural blueprint for campaign generalization, declarative manifests, distributed workers, and sovereign forge integration.

---

## Reconstituting the Workspace

Because the arena connects with unreleased versions of Nadeem Bitar's ecosystem packages across multiple repositories, it is designed for a multi-repo workspace layout.

### Quickstart

1. **Clone this repository**:
   ```bash
   git clone https://github.com/NadiaYvette/typed-language-model-arena.git
   cd typed-language-model-arena
   ```

2. **Reconstitute sibling dependencies**:
   Run the reconstitution script to clone and pin all 9 sibling repositories at tested commit hashes in the parent directory:
   ```bash
   ./scripts/reconstitute.sh --build
   ```

3. **Requirements**:
   - GHC 9.12.4 (installable via `ghcup`)
   - Cabal 3.10+
   - PostgreSQL (`initdb` and `pg_ctl` in PATH; the campaign engine automatically bootstraps an owned, isolated socket cluster if `PG_CONNECTION_STRING` is unset)

---

## Running Demos & Testbeds

### 1. Shikumi Tutorial Rungs
```bash
cabal run tier1-compose
cabal run tier2-evaluate
cabal run tier3-optimize
cabal run tier4-trace-replay
cabal run tier5-react-agent
cabal run tier6-cli
cabal run tier7-streaming
```

### 2. Guarded Code Editing
```bash
cabal run coder-demo
cabal run toy-fixer-demo
```

### 3. Campaign & Durable Verification Engine
```bash
# Dry-run schedule inspection (Act 23 real-cell scheduler)
REAL_LIMIT=0 ACTS=23 cabal run campaign-demo

# Mercury compiler promotion replay (Act 25)
REPLAY=mercury cabal run campaign-demo

# Offline verdict validation over matrix logs
cabal run real-validate -- /path/to/logs
```

---

## Repository Mirrors & Identity

- **GitHub**: [`https://github.com/NadiaYvette/typed-language-model-arena`](https://github.com/NadiaYvette/typed-language-model-arena)
- **Disroot**: `git@git.disroot.org:NadiaYvette/typed-language-model-arena.git`
- **Framagit**: [`https://framagit.org/NadiaYvette/typed-language-model-arena`](https://framagit.org/NadiaYvette/typed-language-model-arena)
- **GitCode**: `git@gitcode.com:NadiaYvette/typed-language-model-arena.git`
- **Radicle**: `rad:z3sERP1qYmgKUQzWwhquEnzFJu7fj` (DID: `did:key:z6Mkv2YCY2vx7ax92q8RzmPJLQv2x2cpEaFDV6vn7FaoFzB8`)
