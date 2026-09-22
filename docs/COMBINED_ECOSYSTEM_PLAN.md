# Combined Ecosystem Plan — Code Handling × Ecosystem Integration

> **Merges**: [`docs/CODE_HANDLING.md`](CODE_HANDLING.md) (Shinzui/Nadeem code-graph retrieval architecture, Nadia's 5 repos, Hermes replication with verification) and [`docs/ECOSYSTEM_INTEGRATION_PLAN.md`](ECOSYSTEM_INTEGRATION_PLAN.md) (Nadeem Bitar Haskell ecosystem → Hermes roles, autonomous loop, tiered roadmap).
>
> **Thesis**: Shikumi decides over code the CodeGraph has already indexed; nothing is re-read as raw text. Code retrieval and agent orchestration are one stack, not two.

---

## 1. Executive Summary

This document presents the unified architecture for the **typed-language-model-arena** / Hermes Agent stack: a deterministic, zero-token code-intelligence substrate feeding a durable, typed decision-and-action loop.

Two complementary halves:

| Half | Source | Answers |
| :--- | :--- | :--- |
| **Code Intelligence** | `CODE_HANDLING.md` | *How does the agent see the code?* — Offline knowledge graph (`CodeGraph` + `universal-ctags` + SQLite WAL + MCP), multi-repo symbol/predicate/citation indexing, sub-millisecond lookup. |
| **Decision Orchestration** | `ECOSYSTEM_INTEGRATION_PLAN.md` | *How does it decide and act?* — Shikumi plans, Keiro journals, Kioku remembers, Seihou scaffolds, PGMQ/Shibuya transport, Mori validates, Shomei signs, Kiroku audits. |

Integrated, they form a single closed loop: **observe → retrieve code context + episodic lessons → decide → act → persist → validate**, with every structured exchange schema-enforced and every decision journaled.

---

## 2. Core Architectural Mapping

### 2.1 Decision & Memory Stack

| Haskell Component | Hermes Role | Technical Definition |
| :--- | :--- | :--- |
| **Shikumi** | Decision/Planning | Logic Plugin: Evaluates states, generates repair blueprints, and decides next actions. |
| **Keiro** | Durable Orchestration | Workflow Runner: Ensures persistence, resumability, and state-machine integrity. |
| **Kioku** | Memory Backend | Episodic/Semantic Memory: Provides the context store for lessons, history, and known-fails. |

### 2.2 Code Intelligence Substrate

| Component | Hermes Role | Technical Definition |
| :--- | :--- | :--- |
| **CodeGraph MCP** | Context Retrieval | Zero-token symbol/caller/callee/path-trace lookup (`find_symbol`, `get_callers`, `get_callees`, `trace_path`) feeding precise diagnostics to Shikumi. |
| **universal-ctags + Tree-sitter** | Multi-Paradigm Ingestion | Symbol extraction across polyglot trees (C, Rust, Haskell, Mercury); AST call-graphs, definitions, type signatures. |
| **SQLite WAL Knowledge Graph** | Relational Graph Substrate | `repo_graph.sqlite` / `codegraph.db` with `nodes` (id, repo, path, name, type, line_start, line_end), `edges` (source_id, target_id, relation), FTS5 trigram index, WAL concurrency. |
| **Custom Logic/Citation Scanners** | Exotic Syntax & Provenance | Mercury `:- pred`/`:- func` extraction, academic DOI (`10.xxxx/...`) parsing, markdown concept headers — layers standard tokenizers miss. |
| **graph_explorer** | Topology Visualizer | `vis-network` interactive canvas over the same node/edge store; filters citations, predicates, concepts, functions. |

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

## 3. Shinzui's 4-Tier Code Retrieval Architecture

The code-intelligence half is grounded on Nadeem Bitar (Shinzui)'s insight:

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
│ [ Tier 2: Relational Graph Substrate (SQLite WAL) ]                           │
│   • Database: repo_graph.sqlite (nodes, edges, citations, predicates)         │
│   • Indexes: FTS5 trigram full-text, B-tree path/symbol lookups               │
│   • Concurrency: Multi-threaded read pool for sub-ms queries                  │
│                                    │                                           │
│                                    ▼                                           │
│ [ Tier 3: Zero-Token Model Interface (MCP Server) ]                           │
│   • CodeGraph MCP Server over Stdio JSON-RPC / UNIX daemon.sock               │
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

1. **Layer 1 — Code AST**: Functions, structs, classes, call graphs.
2. **Layer 2 — Exotic Logic**: Mercury predicates (`pred`, `func`) — e.g. `mowgli`'s `all_in`, `check`, `bounded_loop`.
3. **Layer 3 — Academic Citations**: DOIs (`10.xxxx/...`) linking papers to implementing modules.
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

The agent loop inserts **CodeGraph as a parallel context-retrieval tier** alongside Kioku, so Shikumi's repair blueprints are grounded in both historical lessons *and* exact structural code context — before any action is journaled or validated.

```
1. Observability (Trigger)
   Hermes detects an event: test failure, symbol change, verification gate miss.

2a. Context Retrieval — Kioku
   Query episodic/semantic memory for historical precedents, known-fails, lessons.

2b. Code Context Retrieval — CodeGraph MCP          ← NEW (from CODE_HANDLING)
   find_symbol / get_callers / get_callees / trace_path
   → exact file, line range, callers — zero token crawl of raw source trees.

3. Decision — Shikumi (scaffolded by Seihou)
   Invoke Shikumi Decision Tool with diagnostics + Kioku lessons + CodeGraph context
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

| | Kioku (Episodic) | CodeGraph (Structural) |
| :--- | :--- | :--- |
| **Answers** | *What happened last time?* | *Where is the code and how is it wired?* |
| **Store** | L0 logs → L1 episodes → L2 lessons → L3 priors | SQLite nodes/edges, FTS5, line ranges |
| **Cost** | Distilled memory lookup | <150 tokens per MCP query |
| **Feeds** | Shikumi priors, known-fails | Shikumi diagnostics, exact edit sites |

---

## 6. Implementation Roadmap (Tiered, Merged)

### Tier 1 — Foundations
- Integrate **Seihou** (Dhall-typed scaffolding).
- **Deploy CodeGraph MCP as a first-class context tool** alongside Seihou — decisions require code context before orchestration.
- Index the 5 verification repos (+ arena workspace targets) into `repo_graph.sqlite`.
- Implement **Orchestrator-Worker Transport Bridge** (Shibuya-PGMQ Adapter).
- Implement **Asynchronous Worker Event Loop** (consuming PGMQ, evaluating via Shikumi-Eval).

**Tier 1 acceptance gates** (from `CODE_HANDLING.md` §5 verification contracts):

| # | Contract | Gate Query (against `repo_graph.sqlite`) |
| :--- | :--- | :--- |
| 1 | Formal logic (`mowgli` preds) vs. microkernel concurrency (`telix` sched) | `nodes WHERE repo='mowgli' AND type='pred' AND name IN ('all_in','check')` ≥ 2 |
| 2 | Linear regex invariants (`smirk`) vs. compiler AST (`frankenstein`) | `nodes WHERE repo='smirk' AND name='compileRegex'` = 1 |
| 3 | Academic literature → code traceability | `nodes WHERE type='citation'` returns DOI↔module edges |
| 4 | Microkernel ACPI & driver isolation (`telix`) | `nodes WHERE path LIKE '%acpi_srv.rs' AND type='struct'` returns `MadtOverride`, `TableEntry`, `AcpiState` |

### Tier 2 — Governance / Security
- Integrate **Shomei** (security/identity, passkey/signing).
- Integrate **Mori-Schema** (validation) — extend schemas to cover CodeGraph tool I/O (symbol nodes, edge responses, predicate/citation types) so retrieval results are typed end-to-end.

### Tier 3 — Audit / Provenance
- Integrate **Kiroku** (event sourcing/auditing) — journal graph mutations, repair-blueprint lifecycle, and retrieval queries as append-only events.
- Optional: wire CodeGraph topology diffs into the human review seam (`Campaign.Review` from `CAMPAIGN_GENERALIZATION.md`).

---

## 7. Synthesis: Why This Replaces Brute-Force Context Loading

| Metric | Brute-Force File Reading | Shinzui / Hermes Database Retrieval |
| :--- | :--- | :--- |
| **Token Cost per Discovery** | 25,000 – 60,000 tokens | **< 150 tokens** (MCP tool query + result) |
| **Query Latency** | 8 – 25 seconds (read + parse) | **0.5 – 3 milliseconds** (SQLite index) |
| **Exotic Syntax Visibility** | Missed by standard LLM tokenizers | **100% captured** via custom type classifiers |
| **Academic Traceability** | Inferred probabilistically | **Deterministic relational edges** (DOI → Code) |
| **Hardware Memory Footprint** | Bloats context to 64K+ (high VRAM) | **Zero VRAM overhead** (database in CPU RAM) |

Combined with the decision stack: **Shikumi never plans from raw text** — it plans from Kioku's distilled lessons *and* CodeGraph's exact line ranges, executes through Keiro's durable journals, and passes every exchange through Mori's schemas.

---

## 8. Operational Status & Related Documents

**Code substrate (CODE_HANDLING §7):**
- 1.17 GB code graph indexed at `repos/.codegraph/codegraph.db`.
- Relational graph synchronized at `~/.hermes/memory/repo_graph.sqlite`.
- Interactive visualizer live at `graph_explorer.html`.
- All 4 testbed verification gates pass with exit code 0.

**Decision stack roadmap:** see `ECOSYSTEM_INTEGRATION_PLAN.md` §4 (original tiers) and this document §6 (merged tiers).

**Related living documents:**
- [`WORKQUEUE.md`](WORKQUEUE.md) — scheduler ground truth, portfolio roadmap, failure baselines, commit ledger.
- [`CAMPAIGN_GENERALIZATION.md`](CAMPAIGN_GENERALIZATION.md) — declarative target manifests, distributed workers, sovereign forge integration.
- [`ATTESTATION_MAPPING_DRAFT.md`](ATTESTATION_MAPPING_DRAFT.md) — attestation record, receipts-as-gate-input, DID-key signing.

This architecture is the empirical foundation for **Iteration 3 (Research 2.0)** and the campaign engine's durable verification runtime.
