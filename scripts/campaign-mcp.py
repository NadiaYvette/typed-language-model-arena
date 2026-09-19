#!/usr/bin/env python3
"""
Model Context Protocol (MCP) server and CLI bridge for shikumi-campaign.

Exposes typed verification tools over standard JSON-RPC 2.0 (stdio) for AI
assistants (Antigravity, Claude Code, Cursor, Zed, Aider) and direct CLI commands
for human reviewers.

Zero third-party Python dependencies — uses standard library only.
"""

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional

REPO_ROOT = Path("/home/nyc/src/typed-language-model-arena")
CAMPAIGN_DIR = REPO_ROOT / "shikumi-campaign"
SOCKET_PATH = Path("/home/nyc/.local/state/shikumi-campaign-pg.sock")

# Candidate binary locations
CANDIDATE_BINS = [
    REPO_ROOT / "dist-newstyle/build/x86_64-linux/ghc-9.12.4/shikumi-campaign-0.1.0.0/x/campaign-demo/noopt/build/campaign-demo/campaign-demo",
]

_CACHED_BIN: Optional[Path] = None


def find_campaign_binary() -> Path:
    """Find or resolve the compiled campaign-demo executable."""
    global _CACHED_BIN
    if _CACHED_BIN and _CACHED_BIN.is_file() and os.access(_CACHED_BIN, os.X_OK):
        return _CACHED_BIN

    for p in CANDIDATE_BINS:
        if p.is_file() and os.access(p, os.X_OK):
            _CACHED_BIN = p
            return p

    # Fallback to cabal list-bin
    try:
        res = subprocess.run(
            ["cabal", "list-bin", "campaign-demo"],
            cwd=str(CAMPAIGN_DIR),
            capture_output=True,
            text=True,
            check=True,
            timeout=30,
        )
        for line in res.stdout.strip().splitlines():
            cand = Path(line.strip())
            if cand.is_file() and os.access(cand, os.X_OK):
                _CACHED_BIN = cand
                return cand
    except Exception:
        pass

    raise RuntimeError(
        "Could not locate compiled campaign-demo binary. Please run 'cabal build' in shikumi-campaign."
    )


def run_campaign_cmd(
    env_vars: Dict[str, str], timeout: int = 120
) -> subprocess.CompletedProcess:
    """Run campaign-demo binary with specified environment variables."""
    bin_path = find_campaign_binary()
    env = os.environ.copy()
    env.update(env_vars)
    # Default to socket if PG_CONNECTION_STRING not set
    if "PG_CONNECTION_STRING" not in env:
        env["PG_CONNECTION_STRING"] = (
            f"host={SOCKET_PATH} port=5432 user=campaign dbname=campaign"
        )
    return subprocess.run(
        [str(bin_path)],
        cwd=str(CAMPAIGN_DIR),
        env=env,
        capture_output=True,
        text=True,
        timeout=timeout,
    )


# ---------------------------------------------------------------------------
# Tool Implementations
# ---------------------------------------------------------------------------


def tool_status() -> Dict[str, Any]:
    """Check campaign store, PostgreSQL, and portfolio status."""
    proc = run_campaign_cmd({"SERVER": "status"}, timeout=15)
    lines = [
        l for l in proc.stdout.splitlines() if l.strip().startswith("[server]")
    ]

    # Check git status
    git_res = subprocess.run(
        ["git", "status", "--short", "--branch"],
        cwd=str(REPO_ROOT),
        capture_output=True,
        text=True,
    )

    socket_exists = SOCKET_PATH.exists()
    return {
        "server_status": "\n".join(lines) if lines else proc.stdout.strip(),
        "postgres_socket": str(SOCKET_PATH),
        "postgres_socket_alive": socket_exists,
        "git_status": git_res.stdout.strip(),
        "success": proc.returncode == 0,
    }


def tool_discover(
    project: Optional[str] = None, kind: Optional[str] = None
) -> Dict[str, Any]:
    """List all available verification units across the portfolio."""
    proc = run_campaign_cmd({"DISCOVER": "json"}, timeout=15)
    if proc.returncode != 0:
        return {"error": proc.stderr.strip() or proc.stdout.strip(), "units": []}

    units = json.loads(proc.stdout)
    if project:
        p_lower = project.lower().strip()
        units = [u for u in units if u.get("ruProject", "").lower() == p_lower]
    if kind:
        k_lower = kind.lower().strip()
        units = [u for u in units if u.get("ruKind", "").lower() == k_lower]

    for u in units:
        u["cell_key"] = f"{u['ruProject']}/{u['ruArch']}@{u['ruConfig']}"

    # Group counts
    by_project = {}
    for u in units:
        p = u["ruProject"]
        by_project[p] = by_project.get(p, 0) + 1

    return {
        "total_units": len(units),
        "by_project": by_project,
        "units": units,
    }


def tool_schedule(
    limit: Optional[int] = None, tier: Optional[str] = None
) -> Dict[str, Any]:
    """Return the memory-ranked execution schedule from Kioku lessons."""
    proc = run_campaign_cmd({"SCHEDULE": "json"}, timeout=30)
    if proc.returncode != 0:
        return {
            "error": proc.stderr.strip() or proc.stdout.strip(),
            "schedule": [],
        }

    raw = json.loads(proc.stdout)
    rows = raw.get("schRows", [])
    for r in rows:
        u = r.get("seUnit", {})
        r["cell_key"] = f"{u.get('ruProject')}/{u.get('ruArch')}@{u.get('ruConfig')}"

    if tier:
        t_lower = tier.lower().strip()
        filtered = []
        for r in rows:
            why = r.get("seWhy", "").lower()
            if t_lower == "failed" and "failed" in why:
                filtered.append(r)
            elif t_lower == "passed" and "passed" in why:
                filtered.append(r)
            elif t_lower == "unknown" and (
                "no evidence" in why or "unknown" in why
            ):
                filtered.append(r)
        rows = filtered

    if limit and limit > 0:
        rows = rows[:limit]

    return {
        "total_scheduled": len(rows),
        "schedule": rows,
    }


def tool_verify(
    unit: str,
    live: bool = True,
    include_log: bool = True,
    log_tail_lines: int = 50,
) -> Dict[str, Any]:
    """Execute real verification for a cell and return ground truth verdict and logs."""
    env = {
        "ACTS": "23",
        "REAL_UNIT": unit.strip(),
        "REAL_LIVE": "1" if live else "0",
    }
    # Allow up to 300s for live execution
    timeout = 300 if live else 30
    proc = run_campaign_cmd(env, timeout=timeout)

    output = proc.stdout
    verdict = "unknown"
    log_path = None
    cmd = None
    mode = "live" if live else "plan"

    for line in output.splitlines():
        line_s = line.strip()
        if unit in line_s and ("[" in line_s or "Completed" in line_s):
            if "passed" in line_s:
                verdict = "passed"
            elif "failed" in line_s:
                verdict = "failed"
            elif "passed-waived" in line_s:
                verdict = "passed-waived"
            elif "skipped" in line_s:
                verdict = "skipped"
            elif "planned" in line_s:
                verdict = "planned"

        if "log:" in line_s:
            parts = line_s.split("log:")
            if len(parts) > 1:
                log_path = parts[1].strip()

        if line_s.startswith("cmd:"):
            cmd = line_s[len("cmd:") :].strip()

    log_tail = None
    if include_log and log_path and Path(log_path).is_file():
        try:
            with open(log_path, "r", encoding="utf-8", errors="replace") as f:
                all_lines = f.readlines()
                log_tail = "".join(all_lines[-log_tail_lines:])
        except Exception as e:
            log_tail = f"(error reading log: {e})"

    return {
        "unit": unit,
        "mode": mode,
        "verdict": verdict,
        "command": cmd,
        "log_path": log_path,
        "log_tail": log_tail,
        "exit_code": proc.returncode,
        "success": verdict in ("passed", "passed-waived", "planned"),
    }


def tool_evidence(namespace: str = "all") -> Dict[str, Any]:
    """Query Kioku memory lessons across portfolio namespaces."""
    env = {
        "EVIDENCE": namespace.strip(),
        "EVIDENCE_FORMAT": "json",
    }
    proc = run_campaign_cmd(env, timeout=20)
    if proc.returncode != 0:
        return {
            "error": proc.stderr.strip() or proc.stdout.strip(),
            "evidence": {},
        }
    try:
        evidence = json.loads(proc.stdout)
    except Exception as e:
        return {"error": f"Failed to parse JSON: {e}", "raw": proc.stdout}

    counts = {k: len(v) for k, v in evidence.items()}
    return {
        "counts": counts,
        "namespaces": evidence,
    }


def tool_review(
    action: str = "list",
    project: str = "mowgli",
    branch: Optional[str] = None,
    awakeable: Optional[str] = None,
    verdict: Optional[str] = None,
    reason: Optional[str] = None,
) -> Dict[str, Any]:
    """Inspect and operate the human-in-the-loop campaign review branches."""
    env = {
        "REVIEW": action.strip(),
        "CAMPAIGN_APP_PROJECT": project.strip(),
    }
    if action == "list":
        env["REVIEW_FORMAT"] = "json"
        proc = run_campaign_cmd(env, timeout=15)
        if proc.returncode != 0:
            return {"error": proc.stderr.strip(), "branches": []}
        try:
            branches = json.loads(proc.stdout)
        except Exception:
            branches = []
        return {"project": project, "branches": branches}

    if branch:
        env["CAMPAIGN_REVIEW_BRANCH"] = branch.strip()
    if awakeable:
        env["CAMPAIGN_HUMAN_AWAKEABLE"] = awakeable.strip()
    if verdict:
        env["CAMPAIGN_HUMAN_VERDICT"] = verdict.strip()
    if reason:
        env["CAMPAIGN_REVIEW_REASON"] = reason.strip()

    proc = run_campaign_cmd(env, timeout=60)
    return {
        "action": action,
        "project": project,
        "branch": branch,
        "exit_code": proc.returncode,
        "stdout": proc.stdout.strip(),
        "stderr": proc.stderr.strip(),
        "success": proc.returncode == 0,
    }


def tool_classify(spec: str) -> Dict[str, Any]:
    """Run ground truth oracle classifier on a log file."""
    env = {"CLASSIFY": spec.strip()}
    proc = run_campaign_cmd(env, timeout=15)
    return {
        "spec": spec,
        "output": proc.stdout.strip(),
        "exit_code": proc.returncode,
        "success": proc.returncode == 0,
    }


# ---------------------------------------------------------------------------
# MCP Server Protocol Handler
# ---------------------------------------------------------------------------

MCP_TOOLS = [
    {
        "name": "campaign_status",
        "description": "Check the health and connection status of the shikumi-campaign store, PostgreSQL daemon, and portfolio workspace.",
        "inputSchema": {
            "type": "object",
            "properties": {},
        },
    },
    {
        "name": "campaign_discover",
        "description": "Discover all 99 real verification units across domain projects (pgcl, telix, tessera, organ-bank, mowgli, peirce, mercury). Filters by project or kind.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "project": {
                    "type": "string",
                    "description": "Optional project filter (e.g. 'telix', 'tessera', 'organ-bank', 'mowgli', 'pgcl')",
                },
                "kind": {
                    "type": "string",
                    "description": "Optional kind filter ('host-verify' or 'qemu-boot-matrix')",
                },
            },
        },
    },
    {
        "name": "campaign_schedule",
        "description": "Inspect the memory-driven execution schedule ordered by Kioku lessons (failed first, then unknown, then passed; cheapest first within tier).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "limit": {
                    "type": "integer",
                    "description": "Maximum number of rows to return (default: all)",
                },
                "tier": {
                    "type": "string",
                    "description": "Filter by evidence tier: 'failed', 'unknown', or 'passed'",
                },
            },
        },
    },
    {
        "name": "campaign_verify",
        "description": "Execute real verification for a portfolio cell (e.g. 'telix/host@verify', 'tessera/host@proof', 'organ-bank/host@organ-ir', 'mowgli/host@film-fixture', or a pgcl kernel cell like 'pgcl/x86_64@0'). Live execution runs real processes and returns ground-truth logs and verdicts.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "unit": {
                    "type": "string",
                    "description": "Cell key to verify (e.g. 'telix/host@verify', 'tessera/host@proof', 'organ-bank/host@organ-ir', 'mowgli/host@film-fixture', 'pgcl/x86_64@0')",
                },
                "live": {
                    "type": "boolean",
                    "description": "Whether to run live execution (default: true). Set false for planning mode without running builds.",
                },
                "include_log": {
                    "type": "boolean",
                    "description": "Whether to include a snippet of the tool's process log (default: true)",
                },
                "log_tail_lines": {
                    "type": "integer",
                    "description": "Number of trailing log lines to include (default: 50)",
                },
            },
            "required": ["unit"],
        },
    },
    {
        "name": "campaign_evidence",
        "description": "Query Kioku memory lessons and baselines across portfolio namespaces ('all', 'pgcl', 'telix', 'tessera', 'organ-bank', 'mowgli', 'peirce', 'mercury').",
        "inputSchema": {
            "type": "object",
            "properties": {
                "namespace": {
                    "type": "string",
                    "description": "Memory namespace to query (default: 'all')",
                },
            },
        },
    },
    {
        "name": "campaign_review",
        "description": "Inspect and operate campaign review branches (the human-in-the-loop merge seam). List open branches, re-verify and merge approved repairs, or reject with journaled rationale.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "action": {
                    "type": "string",
                    "enum": ["list", "approve", "reject", "answer"],
                    "description": "Review action to perform",
                },
                "project": {
                    "type": "string",
                    "description": "Project name (e.g. 'mowgli', 'tessera', 'telix')",
                },
                "branch": {
                    "type": "string",
                    "description": "Campaign branch (e.g. 'campaign/app-app1789582192') required for approve/reject",
                },
                "awakeable": {
                    "type": "string",
                    "description": "Awakeable UUID for action 'answer'",
                },
                "verdict": {
                    "type": "string",
                    "enum": ["approve", "reject"],
                    "description": "Verdict for action 'answer'",
                },
                "reason": {
                    "type": "string",
                    "description": "Operator reason for action 'reject'",
                },
            },
            "required": ["action"],
        },
    },
    {
        "name": "campaign_classify",
        "description": "Run the ground truth oracle classifier on any log file to determine its verdict ('passed', 'failed', 'passed-waived', 'skipped').",
        "inputSchema": {
            "type": "object",
            "properties": {
                "spec": {
                    "type": "string",
                    "description": "Specification in the format '[arch:]<log_path>'",
                },
            },
            "required": ["spec"],
        },
    },
]


def handle_mcp_message(msg: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    """Handle an incoming JSON-RPC 2.0 message."""
    method = msg.get("method")
    msg_id = msg.get("id")

    if method == "initialize":
        return {
            "jsonrpc": "2.0",
            "id": msg_id,
            "result": {
                "protocolVersion": "2024-11-05",
                "capabilities": {
                    "tools": {},
                },
                "serverInfo": {
                    "name": "shikumi-campaign",
                    "version": "0.1.0",
                },
            },
        }

    if method == "notifications/initialized":
        return None

    if method == "ping":
        return {"jsonrpc": "2.0", "id": msg_id, "result": {}}

    if method == "tools/list":
        return {
            "jsonrpc": "2.0",
            "id": msg_id,
            "result": {
                "tools": MCP_TOOLS,
            },
        }

    if method == "tools/call":
        params = msg.get("params", {})
        name = params.get("name")
        args = params.get("arguments", {})

        try:
            if name == "campaign_status":
                res = tool_status()
            elif name == "campaign_discover":
                res = tool_discover(args.get("project"), args.get("kind"))
            elif name == "campaign_schedule":
                res = tool_schedule(args.get("limit"), args.get("tier"))
            elif name == "campaign_verify":
                res = tool_verify(
                    unit=args.get("unit", ""),
                    live=args.get("live", True),
                    include_log=args.get("include_log", True),
                    log_tail_lines=args.get("log_tail_lines", 50),
                )
            elif name == "campaign_evidence":
                res = tool_evidence(args.get("namespace", "all"))
            elif name == "campaign_review":
                res = tool_review(
                    action=args.get("action", "list"),
                    project=args.get("project", "mowgli"),
                    branch=args.get("branch"),
                    awakeable=args.get("awakeable"),
                    verdict=args.get("verdict"),
                    reason=args.get("reason"),
                )
            elif name == "campaign_classify":
                res = tool_classify(args.get("spec", ""))
            else:
                return {
                    "jsonrpc": "2.0",
                    "id": msg_id,
                    "error": {
                        "code": -32601,
                        "message": f"Method or tool not found: {name}",
                    },
                }

            text_content = json.dumps(res, indent=2)
            return {
                "jsonrpc": "2.0",
                "id": msg_id,
                "result": {
                    "content": [
                        {
                            "type": "text",
                            "text": text_content,
                        }
                    ],
                    "isError": False,
                },
            }
        except Exception as e:
            return {
                "jsonrpc": "2.0",
                "id": msg_id,
                "result": {
                    "content": [
                        {
                            "type": "text",
                            "text": f"Error executing tool {name}: {str(e)}",
                        }
                    ],
                    "isError": True,
                },
            }

    return {
        "jsonrpc": "2.0",
        "id": msg_id,
        "error": {
            "code": -32601,
            "message": f"Unrecognized method: {method}",
        },
    }


def run_mcp_server():
    """Stdio loop for Model Context Protocol."""
    sys.stderr.write(
        "[campaign-mcp] starting stdio server for shikumi-campaign\n"
    )
    sys.stderr.flush()

    for line in sys.stdin:
        line_clean = line.strip()
        if not line_clean:
            continue
        try:
            req = json.loads(line_clean)
            resp = handle_mcp_message(req)
            if resp is not None:
                sys.stdout.write(json.dumps(resp) + "\n")
                sys.stdout.flush()
        except Exception as e:
            sys.stderr.write(f"[campaign-mcp] error processing message: {e}\n")
            sys.stderr.flush()


# ---------------------------------------------------------------------------
# Direct CLI Mode
# ---------------------------------------------------------------------------


def main_cli():
    parser = argparse.ArgumentParser(
        description="shikumi-campaign CLI and MCP server"
    )
    parser.add_argument(
        "--mcp",
        action="store_true",
        help="Run as standard MCP JSON-RPC 2.0 stdio server",
    )

    subparsers = parser.add_subparsers(dest="subcommand")

    # status
    subparsers.add_parser("status", help="Check server and database status")

    # discover
    p_disc = subparsers.add_parser(
        "discover", help="Discover verification units"
    )
    p_disc.add_argument("--project", "-p", help="Filter by project")
    p_disc.add_argument("--kind", "-k", help="Filter by kind")
    p_disc.add_argument("--json", action="store_true", help="Output raw JSON")

    # schedule
    p_sch = subparsers.add_parser(
        "schedule", help="Inspect memory-ranked schedule"
    )
    p_sch.add_argument(
        "--limit", "-n", type=int, default=10, help="Number of rows to show"
    )
    p_sch.add_argument(
        "--tier", choices=["failed", "unknown", "passed"], help="Filter by tier"
    )
    p_sch.add_argument("--json", action="store_true", help="Output raw JSON")

    # verify
    p_ver = subparsers.add_parser(
        "verify", help="Run verification for a specific cell"
    )
    p_ver.add_argument("unit", help="Cell key (e.g. 'telix/host@verify')")
    p_ver.add_argument(
        "--live",
        action="store_true",
        default=True,
        help="Execute live process (default: true)",
    )
    p_ver.add_argument(
        "--plan",
        dest="live",
        action="store_false",
        help="Run in planning mode without executing builds",
    )
    p_ver.add_argument("--json", action="store_true", help="Output raw JSON")

    # evidence
    p_evi = subparsers.add_parser(
        "evidence", help="Query Kioku memory lessons"
    )
    p_evi.add_argument("namespace", nargs="?", default="all", help="Namespace")
    p_evi.add_argument("--json", action="store_true", help="Output raw JSON")

    # review
    p_rev = subparsers.add_parser("review", help="Operate campaign review seam")
    p_rev.add_argument(
        "action",
        choices=["list", "approve", "reject", "answer"],
        help="Action",
    )
    p_rev.add_argument(
        "--project", "-p", default="mowgli", help="Project name"
    )
    p_rev.add_argument("--branch", "-b", help="Campaign branch name")
    p_rev.add_argument("--awakeable", "-a", help="Awakeable UUID for answer")
    p_rev.add_argument(
        "--verdict", "-v", choices=["approve", "reject"], help="Verdict"
    )
    p_rev.add_argument("--reason", "-r", help="Rejection reason")
    p_rev.add_argument("--json", action="store_true", help="Output raw JSON")

    # classify
    p_cla = subparsers.add_parser(
        "classify", help="Run oracle log classifier"
    )
    p_cla.add_argument("spec", help="[arch:]<log_path>")

    args = parser.parse_args()

    if args.mcp or args.subcommand is None:
        # If no subcommand provided and stdin is not a tty, run MCP server
        if args.subcommand is None and sys.stdin.isatty():
            parser.print_help()
            sys.exit(0)
        run_mcp_server()
        return

    # CLI subcommands
    if args.subcommand == "status":
        res = tool_status()
        print(f"PostgreSQL Socket: {res['postgres_socket']} ({'ALIVE' if res['postgres_socket_alive'] else 'DOWN'})")
        print(f"Server Status: {res['server_status']}")
        print(f"Git Status:\n{res['git_status']}")

    elif args.subcommand == "discover":
        res = tool_discover(args.project, args.kind)
        if args.json:
            print(json.dumps(res, indent=2))
        else:
            print(f"Total discovered units: {res['total_units']}")
            for p, count in res["by_project"].items():
                print(f"  {p}: {count} units")
            for u in res["units"][:15]:
                print(f"  - {u['cell_key']} ({u['ruKind']})")
            if len(res["units"]) > 15:
                print(f"  ... and {len(res['units']) - 15} more units")

    elif args.subcommand == "schedule":
        res = tool_schedule(args.limit, args.tier)
        if args.json:
            print(json.dumps(res, indent=2))
        else:
            print(f"Schedule (top {len(res['schedule'])}):")
            for r in res["schedule"]:
                print(f"  #{r['seRank']:<2} {r['cell_key']:<30} — {r['seWhy']}")

    elif args.subcommand == "verify":
        print(f"Verifying {args.unit} (live={args.live})...")
        res = tool_verify(args.unit, args.live)
        if args.json:
            print(json.dumps(res, indent=2))
        else:
            print(f"Verdict: {res['verdict'].upper()} (exit code {res['exit_code']})")
            if res["command"]:
                print(f"Command: {res['command']}")
            if res["log_path"]:
                print(f"Log:     {res['log_path']}")
            if res.get("log_tail"):
                print("\n--- Log tail ---")
                print(res["log_tail"].strip())
                print("----------------\n")

    elif args.subcommand == "evidence":
        res = tool_evidence(args.namespace)
        if args.json:
            print(json.dumps(res, indent=2))
        else:
            print("Kioku Memory Evidence:")
            for ns, lessons in res.get("namespaces", {}).items():
                print(f"\nNamespace [{ns}] ({len(lessons)} lessons):")
                for l in lessons:
                    print(f"  - {l}")

    elif args.subcommand == "review":
        res = tool_review(
            args.action,
            args.project,
            args.branch,
            args.awakeable,
            args.verdict,
            args.reason,
        )
        if args.json:
            print(json.dumps(res, indent=2))
        else:
            if args.action == "list":
                branches = res.get("branches", [])
                print(f"Review branches for {args.project} ({len(branches)} found):")
                if not branches:
                    print("  (none)")
                for b in branches:
                    status = "merged" if b.get("rbMerged") else "open"
                    print(f"  {b.get('rbBranch')} (+{b.get('rbCommitsAhead')} commits) [{status}]")
            else:
                print(f"Action '{args.action}' completed (success={res.get('success')}):")
                if res.get("stdout"):
                    print(res["stdout"])

    elif args.subcommand == "classify":
        res = tool_classify(args.spec)
        print(res.get("output", ""))


if __name__ == "__main__":
    main_cli()
