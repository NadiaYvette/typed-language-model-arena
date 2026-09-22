# Combined Ecosystem Plan — Code Handling × Ecosystem Integration

> **Merges**: [`docs/CODE_HANDLING.md`](CODE_HANDLING.md) (Shinzui/Nadeem code-graph retrieval architecture, Nadia's 5 repos, Hermes replication with verification) and [`docs/ECOSYSTEM_INTEGRATION_PLAN.md`](ECOSYSTEM_INTEGRATION_PLAN.md) (Nadeem Bitar Haskell ecosystem → Hermes roles, autonomous loop, tiered roadmap).
>
> **Nativeisation**: storage, façade, and required-language ingestion are further specified by [`docs/CODE_INGESTION_NATIVISATION.md`](CODE_INGESTION_NATIVISATION.md) (repo assessments, backend neutrality, reimplementation verdicts, strategy B).
>
> **Thesis**: Shikumi decides over code the code-intelligence substrate has already indexed; nothing is re-read as raw text. Code retrieval and agent orchestration are one stack, not two — owned natively at the Haskell/effectful/servant boundary, not delegated wholesale to a Node sidecar.

---

## 1. Executive Summary

This document presents the unified architecture for the **typed-language-model-arena** / Hermes Agent stack: a deterministic, zero-token code-intelligence substrate feeding a durable, typed decision-and-action loop.

Two complementary halves:

| Half | Source | Answers |
| :--- | :--- | :--- |
| **Code Intelligence** | `CODE_HANDLING.md` + `CODE_INGESTION_NATIVISATION.md` | *How does the agent see the code?* — Offline knowledge graph over a backend-neutral `CodeGraphStore` effect (SQLite testbeds / Postgres campaign), mixed ingestion (ctags JSONL, tree-sitter queries, custom scanners for the **required language set**: Haskell, Mercury, Julia, Lean, Coq, Sail, **and more**), thin MCP/servant façade, sub-millisecond lookup. |
| **Decision Orchestration** | `ECOSYSTEM_INTEGRATION_PLAN.md` | *How does it decide and act?* — Shikumi plans, Keiro journals, Kioku remembers, Seihou scaffolds, PGMQ/Shibuya transport, Mori validates, Shomei signs, Kiroku audits. |

Integrated, they form a single closed loop: **observe → retrieve code context + episodic lessons → decide → act → persist → validate**, with every structured exchange schema-enforced and every decision journaled.

**Nativeisation stance** (from `CODE_INGESTION_NATIVISATION.md`): codegraph's stock 41-language matrix is web/apps-weighted and **omits the arena's verification-target languages**; strategy **B** applies now — own the store effect, façade, and required-language scanners in Haskell; consume codegraph as a sidecar only where its coverage helps; do not port its long-tail extractor matrix or reimplement tree-sitter/ctags parsers.

---

## 2. Core Architectural Mapping

### 2.1 Decision & Memory Stack

| Haskell Component | Hermes Role | Technical Definition |
| :--- | :--- | :--- |
| **Shikumi** | Decision/Planning | Logic Plugin: Evaluates states, generates repair blueprints, and decides next actions. |
| **Keiro** | Durable Orchestration | Workflow Runner: Ensures persistence, resumability, and state-machine integrity. |
| **Kioku** | Memory Backend | Episodic/Semantic Memory: Provides the context store for lessons, history, and known-fails. |

### 2.2 Code Intelligence Substrate (nativeised)

Owned at the Haskell boundary per `CODE_INGESTION_NATIVISATION.md` §5–6 (strategy B):

| Component | Hermes Role | Technical Definition |
| :--- | :--- | :--- |
| **`CodeGraphStore` effect** | Relational Graph Substrate | Backend-neutral effectful effect over `nodes` (id, repo, path, name, type, line_start, line_end) / `edges` (source_id, target_id, relation); carriers: **SQLite** (local, matches `repo_graph.sqlite` testbed contracts) and **Postgres** (campaign-shared, beside keiro/kiroku/pgmq; FTS5 → `tsvector`/`pg_trgm`). |
| **MCP / servant façade** | Context Retrieval | Thin wire surface (`find_symbol`, `get_callers`, `get_callees`, `trace_path`) over the store; Mori-validated types; feeds precise diagnostics to Shikumi with zero raw-tree token crawl. |
| **Mixed ingestion pipeline** | Multi-Paradigm Ingestion | (1) **universal-ctags** subprocess → JSONL (haskell, julia, rust, c, python, ocaml, …); (2) **tree-sitter queries** for structure/sigs/callers on core languages; (3) **codegraph sidecar** only where its coverage helps (optional, not load-bearing). |
| **Custom domain scanners** | Required Languages & Provenance | **Required, open-ended set**: Mercury `:- pred`/`:- func`, **Haskell, Julia, Lean, Coq, Sail** symbol/structure scanners (and more as targets are added); academic DOI (`10.xxxx/...`) parsing; markdown concept headers. |
| **Keiro reindex workflow** | Incremental Sync | mtime+hash reindex orchestrated as a durable workflow — no bespoke file watcher. |
| **graph_explorer** | Topology Visualizer | `vis-network` interactive canvas over the same node/edge store; filters citations, predicates, concepts, functions. |

**Not owned** (consume, don't port): tree-sitter runtime/grammars, ctags' 119 parsers, codegraph's long-tail language matrix and framework synthesizers, FTS engines, visualizer stack — see `CODE_INGESTION_NATIVISATION.md` §5.4.

### 2.3 Infrastructure & Auxiliary Components

| Haskell Component | Hermes Role | Technical Definition |
| :--- | :--- | :--- |
| **Seihou** | Agent Scaffolding | Dhall-Typed Config Tool: Injects strictly-typed orchestration policies. |
| **Shomei** | Security/Identity | Security Tool: Handles passkey/signing operations within the campaign. |
| **Kiroku** | Event Sourcing Store | Memory/Logging Tool: Append-only store for auditing decisions and events. |
| **Mori-Schema** | Protocol Enforcement | Validation Tool: Enforces input/output JSON schemas for agent tool calls — **including CodeGraph node/edge/tool responses**. |
| **PGMQ-HS** | Communication Backbone | Message Queue: Facilitates reliable inter-agent messaging. |
| **Shibuya-PGMQ Adapter** | Transport Bridge | Adapter: Links Shibuya pipelines to PGMQ queues. |
| **Shibuya** | Data Pipeline Processor | Effectful Pipeline Tool: Manages async streams and transformation flows. |
| **baikai** | Provider Transport | Typed LLM transport, model definitions, token accounting, and cost models. |

---

## 3. Shinzui's 4-Tier Code Retrieval Architecture (reference)

The code-intelligence half is grounded on Nadeem Bitar (Shinzui)'s insight. The diagram below is the **source architecture from the Hermes replication** (`CODE_HANDLING.md`); the arena **nativeises** Tiers 1–3 as specified in §2.2 and `CODE_INGESTION_NATIVISATION.md` (CodeGraphStore effect, mixed ingestion, required-language scanners) while leaving the conceptual tiering intact:

> *"Codebases are deterministic relational graphs, not unstructured streams of text. An LLM should never be used to do what an indexed relational database does in 0.5 milliseconds."*

```
┌────────────────────────────────────────────────────────────────────────────────┐
│              SHINZUI'S 4-TIER CODEBASE RETRIEVAL ARCHITECTURE                 │
├────────────────────────────────────────────────────────────────────────────────┤
│ [ Tier 1: Multi-Paradigm Ingestion Engine ]                                   │
│   • Universal Ctags (C, Rust, Python, Haskell symbols)                        │
│   • AST Tree-Sitter (call-graphs, definitions, type signatures)               │
│   • Custom Logic/DOI Scanners (Mercury :- pred, academic DOIs)                │
│                                    │                                           │
│                                    ▼                                           │
│ [ Tier 2: Relational Graph Substrate (CodeGraphStore) ]                       │
│   • Native: CodeGraphStore effect → SQLite | Postgres (nodes, edges, …)       │
│   • (Hermes reference: repo_graph.sqlite WAL + FTS5 trigram index)            │
│   • Concurrency: SQLite read pool | Postgres pool for sub-ms queries          │
│                                    │                                           │
│                                    ▼                                           │
│ [ Tier 3: Zero-Token Model Interface (MCP / servant façade) ]                 │
│   • Thin façade over CodeGraphStore (stdio MCP and/or servant endpoints)      │
│   • Tools: find_symbol, get_callers, get_callees, trace_path                  │
│   • Zero LLM tokens during discovery; results injected on-demand              │
│                                    │                                           │
│                                    ▼                                           │
│ [ Tier 4: Interactive Topology Visualizer ]                                   │
│   • vis-network.min.js + graph_data.js (graph_explorer.html)                  │
│   • Live sidebar filtering: Citations, Predicates, Concepts, Functions        │
└────────────────────────────────────────────────────────────────────────────────┘
```

**Ingestion layers** (all normalized into the same `nodes`/`edges` schema):

1. **Layer 1 — Code AST**: Functions, structs, classes, call graphs — via ctags JSONL + tree-sitter queries on the required language set (Haskell, Mercury, Julia, Lean, Coq, Sail, **and more**); codegraph sidecar only where it covers a language.
2. **Layer 2 — Exotic Logic**: Mercury predicates (`pred`, `func`) — e.g. `mowgli`'s `all_in`, `check`, `bounded_loop` (custom scanner; no off-the-shelf parser exists).
3. **Layer 3 — Academic Citations**: DOIs (`10.xxxx/...`) linking papers to implementing modules (custom, pure Haskell).
4. **Layer 4 — Markdown Concepts**: Architectural specification headers (`#`, `##`).

---

## 4. Verification Targets: Nadia Yvette's 5 Research Repositories

The code substrate is indexed and verified across five Framagit repositories (also campaign verification targets per `WORKQUEUE.md`):

| Repository | Primary Language | Domain | Key Architectural Challenge |
| :--- | :--- | :--- | :--- |
| **mowgli** | Mercury (Logic/Func) | CTL temporal logic & formal model checking | Non-C-family syntax (`:- pred`, `:- func`) |
| **frankenstein** | Polyglot (C/Haskell) | Multi-pass compiler & ASTs | Complex multi-phase lexical/parser pipelines |
| **telix** | Rust | Microkernel OS, ACPI & hardware isolation | User-space driver isolation & atomic IPC |
| **kuroko** | C | Bytecode VM & dynamic language runtime | Low-level VM dispatch & GC-managed state |
| **smirk** | Haskell | Linear-time automata, Glushkov/Thompson NFA | Regex engine without backtracking (ReDoS-safe) |

### Replication steps (summary)

1. **Clone** all 5 into `repos/`.
2. **Ingest** all 4 layers: `codegraph init repos/ && codegraph index repos/` → 1.17 GB `codegraph.db`; ctags → `ctags_symbols.jsonl`; Mercury preds; DOIs + markdown headers; consolidate into `~/.hermes/memory/repo_graph.sqlite`.
3. **Visualize**: generate `graph_explorer.html` + `graph_data.js`.

Full commands and paths: [`CODE_HANDLING.md` §4](CODE_HANDLING.md).

---

## 5. Autonomous Integration Flow (Merged Loop)

The agent loop inserts the **code-intelligence substrate (`CodeGraphStore` + façade) as a parallel context-retrieval tier** alongside Kioku, so Shikumi's repair blueprints are grounded in both historical lessons *and* exact structural code context — before any action is journaled or validated.

```
1. Observability (Trigger)
   Hermes detects an event: test failure, symbol change, verification gate miss.

2a. Context Retrieval — Kioku
   Query episodic/semantic memory for historical precedents, known-fails, lessons.

2b. Code Context Retrieval — CodeGraphStore + façade   ← NEW (from CODE_HANDLING)
   find_symbol / get_callers / get_callees / trace_path
   (servant/MCP over CodeGraphStore; SQLite | Postgres)
   → exact file, line range, callers — zero token crawl of raw source trees.

3. Decision — Shikumi (scaffolded by Seihou)
   Invoke Shikumi Decision Tool with diagnostics + Kioku lessons + code-graph context
   → typed "Repair Blueprint".

4. Action — Keiro / PGMQ / Shibuya-PGMQ
   Agent calls Keiro Durable Workflow Plugin.
   Shibuya-PGMQ Adapter enqueues blueprint via PGMQ.
   Separate worker event loop (Shikumi-Eval) processes blueprint
   and journals results back via Kiroku.

5. Persistence — Kiroku / Kioku
   Kiroku journals the event append-only;
   on completion, Kioku updates the final result for future reference.

6. Verification — Mori-Schema (+ graph contracts)
   All structured exchanges validated via Mori-Schema middleware:
   workflow events, tool calls, AND CodeGraph node/edge/tool response schemas.
   Graph mutation events also journaled through Kiroku.
```

### Why both retrieval tiers?

| | Kioku (Episodic) | CodeGraphStore (Structural) |
| :--- | :--- | :--- |
| **Answers** | *What happened last time?* | *Where is the code and how is it wired?* |
| **Store** | L0 logs → L1 episodes → L2 lessons → L3 priors | SQLite \| Postgres `nodes`/`edges`, FTS, line ranges |
| **Cost** | Distilled memory lookup | <150 tokens per façade query |
| **Feeds** | Shikumi priors, known-fails | Shikumi diagnostics, exact edit sites |

---

## 6. Implementation Roadmap (Tiered, Merged)

### Tier 1 — Foundations
- Integrate **Seihou** (Dhall-typed scaffolding).
- **Implement the `CodeGraphStore` effect** (SQLite + Postgres carriers) as a first-class context substrate alongside Seihou — decisions require code context before orchestration (`CODE_INGESTION_NATIVISATION.md` strategy B).
- **Stand up mixed ingestion**: ctags JSONL subprocess + tree-sitter queries for core languages + **custom scanners for the required language set (Haskell, Mercury, Julia, Lean, Coq, Sail, and more)** + DOI/markdown layers; codegraph as optional sidecar only where coverage helps.
- **Expose the MCP/servant façade** (`find_symbol`, `callers`, `callees`, `trace_path`) over the store; Mori-validate wire types.
- Index the 5 verification repos (+ arena workspace targets) via the façade into the store (SQLite gate queries / Postgres campaign view).
- Implement **Orchestrator-Worker Transport Bridge** (Shibuya-PGMQ Adapter).
- Implement **Asynchronous Worker Event Loop** (consuming PGMQ, evaluating via Shikumi-Eval).

**Tier 1 acceptance gates** (from `CODE_HANDLING.md` §5 verification contracts; run against the SQLite carrier):

| # | Contract | Gate Query (against SQLite `repo_graph.sqlite` or store-equivalent) |
| :--- | :--- | :--- |
| 1 | Formal logic (`mowgli` preds) vs. microkernel concurrency (`telix` sched) | `nodes WHERE repo='mowgli' AND type='pred' AND name IN ('all_in','check')` ≥ 2 |
| 2 | Linear regex invariants (`smirk`) vs. compiler AST (`frankenstein`) | `nodes WHERE repo='smirk' AND name='compileRegex'` = 1 |
| 3 | Academic literature → code traceability | `nodes WHERE type='citation'` returns DOI↔module edges |
| 4 | Microkernel ACPI & driver isolation (`telix`) | `nodes WHERE path LIKE '%acpi_srv.rs' AND type='struct'` returns `MadtOverride`, `TableEntry`, `AcpiState` |

### Tier 2 — Governance / Security
- Integrate **Shomei** (security/identity, passkey/signing).
- Integrate **Mori-Schema** (validation) — extend schemas to cover façade tool I/O (symbol nodes, edge responses, predicate/citation types) so retrieval results are typed end-to-end.

### Tier 3 — Audit / Provenance
- Integrate **Kiroku** (event sourcing/auditing) — journal graph mutations, repair-blueprint lifecycle, and retrieval queries as append-only events.
- Optional: wire graph topology diffs into the human review seam (`Campaign.Review` from `CAMPAIGN_GENERALIZATION.md`).

### Deferred / out of scope (see `CODE_INGESTION_NATIVISATION.md`)
- **Native extraction service (strategy C)**: port per-language extractors onto `hs-tree-sitter` — only if/when the Node sidecar must be dropped; AGPL → separate process/service, never a BSD library dep.
- **Do not reimplement**: tree-sitter grammars, ctags parsers, codegraph's 40-lang extractor matrix / framework synthesizers, search stack, visualizer.

---

## 7. Synthesis: Why This Replaces Brute-Force Context Loading

| Metric | Brute-Force File Reading | Shinzui / Hermes Database Retrieval |
| :--- | :--- | :--- |
| **Token Cost per Discovery** | 25,000 – 60,000 tokens | **< 150 tokens** (façade tool query + result) |
| **Query Latency** | 8 – 25 seconds (read + parse) | **0.5 – 3 milliseconds** (SQLite/Postgres index) |
| **Exotic Syntax Visibility** | Missed by standard LLM tokenizers | **100% captured** via custom type classifiers |
| **Academic Traceability** | Inferred probabilistically | **Deterministic relational edges** (DOI → Code) |
| **Hardware Memory Footprint** | Bloats context to 64K+ (high VRAM) | **Zero VRAM overhead** (database in CPU RAM) |

Combined with the decision stack: **Shikumi never plans from raw text** — it plans from Kioku's distilled lessons *and* the store's exact line ranges, executes through Keiro's durable journals, and passes every exchange through Mori's schemas.

---

## 8. Operational Status & Related Documents

**Code substrate — Hermes replication reference (`CODE_HANDLING.md` §7):**
- 1.17 GB code graph indexed at `repos/.codegraph/codegraph.db` (stock codegraph sidecar).
- Relational graph synchronized at `~/.hermes/memory/repo_graph.sqlite`.
- Interactive visualizer live at `graph_explorer.html`.
- All 4 testbed verification gates pass with exit code 0.

**Code substrate — arena nativeisation (`CODE_INGESTION_NATIVISATION.md`):** design/decision record; `CodeGraphStore` + mixed ingestion + façade are Tier 1 work items (not yet implemented). Target: ~3–6 weeks to parity with the four testbed contracts while covering the required language set stock codegraph misses.

**Decision stack roadmap:** see `ECOSYSTEM_INTEGRATION_PLAN.md` §4 (original tiers) and this document §6 (merged tiers).

**Related living documents:**
- [`CODE_INGESTION_NATIVISATION.md`](CODE_INGESTION_NATIVISATION.md) — repo assessments, backend neutrality, integration strategies A/B/C, reimplementation verdicts, narrow arena-native indexer.
- [`WORKQUEUE.md`](WORKQUEUE.md) — scheduler ground truth, portfolio roadmap, failure baselines, commit ledger.
- [`CAMPAIGN_GENERALIZATION.md`](CAMPAIGN_GENERALIZATION.md) — declarative target manifests, distributed workers, sovereign forge integration.
- [`ATTESTATION_MAPPING_DRAFT.md`](ATTESTATION_MAPPING_DRAFT.md) — attestation record, receipts-as-gate-input, DID-key signing.

This architecture is the empirical foundation for **Iteration 3 (Research 2.0)** and the campaign engine's durable verification runtime.
