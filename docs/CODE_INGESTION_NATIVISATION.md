# Code Ingestion Nativeisation — Design Notes

> **Status**: Design notes / decision record (drafted 2026-09-22).
> **Companions**: [`COMBINED_ECOSYSTEM_PLAN.md`](COMBINED_ECOSYSTEM_PLAN.md) (merged architecture), [`CODE_HANDLING.md`](CODE_HANDLING.md) (original Hermes replication), [`ECOSYSTEM_INTEGRATION_PLAN.md`](ECOSYSTEM_INTEGRATION_PLAN.md) (decision stack).
> **Scope**: How the arena ingests code intelligence natively (Haskell/effectful/servant) versus consuming off-the-shelf components; where from-scratch reimplementation is justified.

---

## 1. Context

`COMBINED_ECOSYSTEM_PLAN.md` positions **CodeGraph** (MCP/SQLite/tree-sitter) as the Tier 1 code-intelligence substrate feeding Shikumi's decisions. This document records the follow-up investigation of the actual checkouts under `~/src/`, the backend-neutrality question, integration friction with the arena's Haskell stack, and per-component reimplementation verdicts.

**Working-tree note**: an initial start on the ecosystem campaign worker (`shikumi-campaign/app/Worker.hs` + `pgmq-core`/`pgmq-effectful` deps in `shikumi-campaign.cabal`) was stashed as `stash@{0}: wip: worker executable + pgmq deps (ecosystem campaign start)` to keep it retrievable when that area is revisited.

---

## 2. Repository Assessment

| Repo | What it is | Fit for arena |
| :--- | :--- | :--- |
| **`~/src/codegraph/`** | TypeScript/Node + Rust napi tree-sitter kernel (`@colbymchenry/codegraph`). MCP (`codegraph serve --mcp`), loopback HTTP API (`codegraph ui`), CLI, library exports. SQLite via `node:sqlite` only (thin `SqliteDatabase` adapter, single backend). | Core retrieval engine; consume as **sidecar**, not link in-process. **No Haskell/Mercury/Julia/Lean/Coq/Sail support.** |
| **`~/src/ctags/`** | Universal-ctags (C). Generation is **CLI-only**: `--output-format=json` JSONL, `--_interactive` REPL. `libreadtags` reads tags but does not extract. 119 parsers including `haskell.c`, `julia.c`, `rust.c`, `python.c`, `ocaml.c`. **No Mercury parser.** | Tier-1 ingestion subprocess for symbol names; JSONL → store. |
| **`~/src/haskell-tree-sitter/`** | Official tree-sitter org bindings, BSD-3. Raw CST, **no Query API**, self-declared "unstable — don't depend", quiet since Sep 2024, GHC ≤ 9.8 (containers bound). | Weak — won't build on arena's pinned GHC 9.12.4 without bound patches; missing Query API you'd want for extraction. |
| **`~/src/hs-tree-sitter/`** | Wen Kokke's bindings, **AGPL-3.0**. ForeignPtr-safe, full Query API, WIP typed-AST generator (`hs-tree-sitter-generate-ast`), GHC 8.10–**9.12**, on Hackage (Jul 2025). Only 2 grammars ship (javascript, toy while). | Best native-Haskell option technically; **AGPL vs arena BSD-3** blocks vendoring as a library — isolate as separate process/service if used. |
| **`~/src/microsoft-graph-explorer-v4/`** | Microsoft Graph REST API explorer (React/MSAL). | **Red herring** — unrelated to code graphs. Drop from consideration. |

### 2.1 The coverage inversion

codegraph's 41-language matrix is **web/apps-weighted** (typescript, vue, swift, dart, cobol, …) and **omits Haskell, Mercury, Julia, Lean, Coq, and Sail** — i.e. most of the arena's verification-target languages (mowgli, organ-bank, peirce, tessera, mercury, frankenstein). ctags covers several of these as *symbol names only* (no structure, signatures, or call-graphs) and lacks Mercury entirely.

**Required language set (non-exhaustive, will grow):** Haskell, Mercury, Julia, Lean, Coq, Sail — **and more** as verification targets are added. Any ingestion plan must treat this set as first-class and open-ended, not as an afterthought to a web-language index.

---

## 3. Is SQLite Mandatory?

**No.** Two independent seams:

1. **Inside codegraph**: `src/db/sqlite-adapter.ts` defines a `SqliteDatabase` interface explicitly so "the rest of the codebase is storage-agnostic" — but only one implementation (`node-sqlite`) exists. Not a real multi-backend story today.
2. **At the Haskell boundary (the right seam for the arena)**: define an effectful **`CodeGraphStore`** effect over the `nodes`/`edges` schema with two carriers:
   - **SQLite** — embedded, per-repo; matches `CODE_HANDLING.md` §5's `repo_graph.sqlite` testbed contracts verbatim.
   - **Postgres** — the campaign engine already bootstraps an owned cluster (`Campaign/Bootstrap.hs`) and runs keiro/kiroku/pgmq on it; graph tables slot in beside them, giving cross-campaign shared indexing, WAL/concurrency, and operational familiarity for free.

Schema (`nodes`, `edges`, FTS) ports directly; SQLite FTS5 → Postgres `tsvector`/`pg_trgm` is the only rewrite.

---

## 4. Integration Strategies (Haskell / effectful / servant)

| | Strategy | Effort | Notes |
| :--- | :--- | :--- | :--- |
| **A** | **Sidecar / process** — `servant-client` against codegraph's loopback HTTP API, or stdio MCP client for `codegraph serve --mcp`; ctags as a process effect (`ctags --output-format=json` → JSONL parse) | Days | Zero FFI, zero license entanglement. Limitation: no Haskell/Mercury/Lean/Coq/Sail structure (codegraph lacks them; ctags is names-only). |
| **B** | **Backend-neutral store + mixed ingestion** — `CodeGraphStore` effect (SQLite + Postgres carriers); ingest via codegraph sidecar (its ~40 langs) + ctags JSONL (Haskell, Julia, …) + custom scanners (Mercury preds, DOIs, markdown); thin MCP/servant façade, Mori-validated wire types | ~1–2 weeks | **Sweet spot for Tier 1.** Clients wrap cleanly in `liftIO`/effectful. |
| **C** | **Native Haskell extraction** — `hs-tree-sitter` (GHC 9.12, Query API) + grammar packaging + port of per-language extractors | Multi-week, license-gated | Technically best fit; **AGPL** requires isolation as a separate process/service or relicensing review — not a BSD library dep. `haskell-tree-sitter` is the license-clean fallback but needs GHC bound patches, submodule init, and you write extraction yourself. |

**Servant caveat** (any in-process tree-sitter): `Tree` is not thread-safe — serialize parses or `treeCopy` per warp worker.

**Recommendation**: **B now** (sidecar ingest where coverage exists + neutral `CodeGraphStore` over existing Postgres + ctags subprocess + custom scanners for the required language set); defer **C** until dropping the Node sidecar is concretely needed — and if/when C happens, treat `hs-tree-sitter` as a separate AGPL service, not a BSD library dependency.

---

## 5. From-Scratch Reimplementation Verdicts

Principle: **reimplement seams and domain semantics; don't reimplement long-tail coverage.** A component's value is either a maintenance treadmill (parsers across dozens of languages, framework quirks) or your specific domain logic (small, high-leverage, license-clean). Only the latter is worth owning.

### 5.1 Reimplement (yes)

| Component | Why | Effort |
| :--- | :--- | :--- |
| `nodes`/`edges` schema + **`CodeGraphStore` effect** (SQLite + Postgres carriers) | Thin, license-clean, backend-neutral, Mori-typed; Postgres cluster already bootstrapped | 2–5 days |
| **DOI/citation + markdown-concept layers** | Not in codegraph at all — custom in the Hermes replication (`CODE_HANDLING.md` §3); pure Haskell | 1–2 days |
| **Mercury `:- pred`/`:- func` extractor** | Nobody has it: codegraph lacks Mercury, ctags lacks a Mercury parser | 1–3 days |
| **Haskell symbol extractor** (modules, imports, top-level sigs, classes/instances) | codegraph lacks Haskell; ctags gives names only, no structure/sigs | 1–2 weeks via tree-sitter queries |
| **MCP server / servant façade** | Once you own the store, the wire surface (`find_symbol`, `callers`, `callees`, `trace_path`) is small; validates naturally under Mori | 2–4 days |

### 5.2 Reimplement — required language set (yes; open-ended)

| Component | Why | Effort |
| :--- | :--- | :--- |
| **Julia / Lean / Coq / Sail symbol scanners** | **Required** — along with Haskell and Mercury, and more as targets are added. ctags covers Julia (names only); Lean/Coq/Sail need thin custom scanners for tessera-class targets. Treat the set as growing, not fixed. | days each |

### 5.3 Partial reimplementation

| Component | Scope | Effort |
| :--- | :--- | :--- |
| Cross-file **reference resolution / call-graph** | Tractable for the **arena's 4–6 core languages**; full generality across 41 languages is codegraph's hard part and not worth porting | 2–4 weeks (scoped) |
| Incremental sync | mtime+hash reindex driven by a keiro workflow beats a bespoke file watcher | 1–2 days |

### 5.4 Do not reimplement (no)

| Component | Why |
| :--- | :--- |
| **tree-sitter runtime + grammars** | C ecosystem, decades of edge cases; consume `hs-tree-sitter` (AGPL→separate process) or vendored `.wasm` |
| **ctags' 119 parsers** | Absurd treadmill; invoke the binary (`--output-format=json` / `--_interactive`) |
| **codegraph's 40-lang extractor matrix + framework synthesizers** (Next/Vue/SvelteKit…) | Months to port, zero relevance to arena domains, ongoing grammar chase — and still missing the required language set |
| FTS / search | Postgres `tsvector` + `pg_trgm` |
| Visualizer | Point `graph_explorer` or codegraph's UI at your store/HTTP API |
| Rust napi kernel | Only accelerates codegraph's multi-lang extraction you're not porting |

---

## 6. Target Architecture: Narrow Arena-Native Indexer

Not a codegraph clone — a **scoped indexer owned in Haskell**, covering the required (and growing) language set:

```
ingestion:  ctags JSONL (haskell, julia, rust, c, python, ocaml, …)
          + tree-sitter queries (structure/sigs/callers for core langs)
          + custom scanners (Mercury :- pred, DOIs, markdown concepts,
            Lean/Coq/Sail/Julia symbols — required set, open-ended)
store:      CodeGraphStore effect → SQLite (testbed contracts) | Postgres (campaign-shared)
API:        thin MCP + servant façade, Mori-validated wire types
orchestrate: keiro workflow for reindex/refresh; kioku for retrieval lessons
```

Rough size: **3–6 weeks** to parity with what `CODE_HANDLING.md` §5's four testbed contracts actually verify — while covering the languages codegraph misses, which the stock tool never would.

The original Hermes hybrid (codegraph + ctags + custom scanners) remains valid as a **sidecar for languages codegraph does well**; nativeisation replaces only the parts where sidecar coverage and the typed/effectful stack's requirements diverge.

---

## 7. Bottom Line

1. **Reimplement** the seams and domain layers: `CodeGraphStore` effect, thin MCP/servant façade, Mercury/DOI/Haskell extractors, **Julia/Lean/Coq/Sail scanners (required, with Haskell and Mercury, and more)**, scoped resolution. Small, BSD-clean, fills real gaps.
2. **Don't reimplement** parsers en masse (ctags, tree-sitter grammars), codegraph's long-tail language matrix, framework synthesizers, search, or UI. Permanent maintenance bill for coverage you don't need — and it still misses the required set.
3. **SQLite is optional**; backend neutrality lives at the Haskell `CodeGraphStore` boundary (SQLite for local testbeds, Postgres for the campaign).
4. **Integration path**: strategy B now; sidecar A supplements; native C only if/when the Node sidecar must go — with `hs-tree-sitter` isolated as an AGPL service.
5. `CODE_HANDLING.md` §5's verification gates all sit in the *reimplement* column — the testbeds never exercised codegraph's web-language strengths anyway.
