---
name: shikumi-campaign
description: >-
  Use this skill when auditing, inspecting, verifying, scheduling, or reviewing
  verification units across the portfolio (pgcl, telix, tessera, organ-bank,
  mowgli, peirce, mercury). Exposes typed campaign tools to discover units, inspect
  memory-ranked schedules, run ground-truth host/kernel verification, query Kioku
  lessons, and operate the human-in-the-loop review seam.
---

# Shikumi Campaign: Verification & Review Runbook

This skill connects the AI assistant REPL directly to the durable verification runtime,
memory substrate (Kioku), workflow engine (Keiro), and domain repositories.

External reviewers and operators can interrogate ground truth, reproduce verification
claims, run live host checks, and review landed repair branches with full auditability.

---

## 1. Core Invariants

* **Zero Hallucinated Verdicts**: All verification verdicts are derived strictly from process
  logs and exit codes written by the tools (`make verify`, `lake build`, `cabal test`,
  `python3`, `matrix-driver-all.sh`). The assistant never infers success from model opinions.
* **Durable Event Journals**: Every attempt, schedule rationale, and operator action is
  persisted in append-only PostgreSQL streams (`Keiro.Workflow`). Replays never re-execute
  completed work uninvited.
* **Memory-Driven Scheduling**: Cells are ordered by Kioku lessons across portfolio namespaces
  (failed first to reproduce early, unknown second, passed last; cheapest first within tier).
* **Two Execution Modes**:
  * `plan`: Offline dry run. Records the exact shell command that would run, journals discovery,
    and returns `planned`. Safe for whole-matrix scans.
  * `live`: Spawns the real process, captures stdout/stderr into `/tmp/real-cells-<ts>/...`,
    classifies the verdict, and journals the outcome into memory.

---

## 2. Available Tools (MCP & CLI)

The campaign tools are accessible both via MCP JSON-RPC (`campaign_*`) and directly via the
CLI bridge (`./scripts/campaign-cli.py` or `./scripts/campaign-mcp.py`):

| Tool Name | CLI Command | Purpose |
| :--- | :--- | :--- |
| `campaign_status` | `./scripts/campaign-cli.py status` | Check PostgreSQL daemon, socket liveness, and git workspace |
| `campaign_discover` | `./scripts/campaign-cli.py discover [-p <proj>] [-k <kind>]` | List all 99 verification units across the 5 domains |
| `campaign_schedule` | `./scripts/campaign-cli.py schedule [-n <limit>] [--tier <tier>]` | View memory-prioritized execution order and rationales |
| `campaign_verify` | `./scripts/campaign-cli.py verify <unit> [--live\|--plan]` | Execute verification cell, return verdict, duration, and log tail |
| `campaign_evidence` | `./scripts/campaign-cli.py evidence [namespace]` | Query remembered lessons and baselines from Kioku |
| `campaign_review` | `./scripts/campaign-cli.py review <list\|approve\|reject\|answer>` | Inspect, approve/merge, or reject human review branches |
| `campaign_classify` | `./scripts/campaign-cli.py classify [arch:]<log>` | Classify a raw log file using ground-truth oracle rules |

---

## 3. Standard Reviewer Workflows

### Workflow A: Health Check & Environment Verification

When an external reviewer opens the repo, verify that the durable store and PostgreSQL
socket are alive:

```bash
./scripts/campaign-cli.py status
```
*Expected*: Socket `/home/nyc/.local/state/shikumi-campaign-pg.sock` is `ALIVE`, server is `UP`.

### Workflow B: Target Discovery

To see what verification targets exist:

* **All host-verify units**:
  ```bash
  ./scripts/campaign-cli.py discover --kind host-verify
  ```
  Returns:
  * `telix/host@verify`: Telix microkernel unit tests and kernel format check (`make -C ~/src/telix verify`)
  * `tessera/host@proof`: Lean 4 formal semantics proof build (`lake --dir ~/src/tessera/proof build`)
  * `organ-bank/host@organ-ir`: Organ-IR Haskell compiler test suite (`cabal test organ-ir`)
  * `mowgli/host@film-fixture`: Mowgli Python film episode & annotation tests (`pytest ...`)

* **Kernel matrix cells for an architecture**:
  ```bash
  ./scripts/campaign-cli.py discover --project pgcl
  ```

### Workflow C: Verify Single Unit (Live Execution)

To reproduce a specific verification claim with real process execution:

```bash
./scripts/campaign-cli.py verify telix/host@verify --live
```
Or via MCP tool:
```json
{
  "name": "campaign_verify",
  "arguments": {
    "unit": "telix/host@verify",
    "live": true,
    "include_log": true
  }
}
```
*Output includes*: Verdict (`PASSED`), command executed, log path, and trailing log output.

### Workflow D: Inspect Memory & Lessons

To inspect what Kioku has remembered about a specific project or cell:

```bash
./scripts/campaign-cli.py evidence telix
```
To inspect lessons across all namespaces:
```bash
./scripts/campaign-cli.py evidence all
```

### Workflow E: Review Landed Campaign Branches

When automated agents or campaigns propose repairs, they land on `campaign/<run>` branches.
The human merge seam lets reviewers inspect and sanction merges:

1. **List pending branches**:
   ```bash
   ./scripts/campaign-cli.py review list --project tessera
   ```
2. **Approve and merge** (re-verifies touched files against clean parent before merge):
   ```bash
   ./scripts/campaign-cli.py review approve --project tessera --branch campaign/app-app1789582192
   ```
3. **Reject** (removes branch & worktree; journals reason to Kioku memory):
   ```bash
   ./scripts/campaign-cli.py review reject --project mowgli --branch campaign/... --reason "violates style pin"
   ```

---

## 4. Troubleshooting

* **PostgreSQL socket down**: Run `SERVER=status cabal run campaign-demo` or check `/home/nyc/.local/state/shikumi-campaign/`.
* **Stale journal conflict**: If testing an act that requires a fresh journal, use a fresh database or timestamped run tags (Act 23 automatically indexes run workflows by timestamp).
