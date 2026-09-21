-- | Campaign reviewer prompts — seihou AgentPrompt artifacts (Track 10, milestone 4).
--
-- These re-express the reviewer workflows in
-- `.agents/skills/shikumi-campaign/SKILL.md` (workflows A–E) as seihou-style
-- `prompt` artifacts — the Integration #6 substrate: a reusable agent-session
-- template with a name, a prompt body, typed variables, conditional guidance,
-- reference files, tags, and optional launch preferences.
--
-- Vendoring note: the `AgentPrompt` type below is a self-contained copy of
-- seihou's `schema/AgentPrompt.dhall` (with its `VarDecl` / `Prompt` /
-- `CommandVar` / `PromptGuidance` / `PromptFile` / `Launch` dependencies
-- inlined) so this bundle typechecks without the seihou checkout on the
-- import path. In production the arena would `let S = <pinned seihou>/schema
-- and name each artifact `S.AgentPrompt::{ ... }`, consuming the exact-revision
-- pin decided for milestone Q3 (decision #3) rather than this inline copy.
--
-- Verifying: `dhall normalize package.dhall` typechecks every artifact against
-- the AgentPrompt type; the arena's in-process dhall loader (Campaign.Real)
-- resolves the same shapes.

let VarDecl =
      { name : Text
      , type : Text
      , default : Optional Text
      , description : Optional Text
      , required : Bool
      , validation : Optional Text
      }

let Prompt =
      { var : Text
      , text : Text
      , when : Optional Text
      , choices : Optional (List Text)
      }

let CommandVar =
      { name : Text
      , run : Text
      , workDir : Optional Text
      , when : Optional Text
      , trim : Bool
      , maxBytes : Optional Natural
      }

let PromptGuidance =
      { title : Text
      , body : Text
      , when : Optional Text
      }

let PromptFile =
      { src : Text
      , description : Optional Text
      }

let Launch =
      { provider : Optional Text
      , model : Optional Text
      , effort : Optional Text
      , mode : Optional Text
      }

let AgentPrompt =
      { name : Text
      , version : Optional Text
      , description : Optional Text
      , prompt : Text
      , vars : List VarDecl
      , prompts : List Prompt
      , commandVars : List CommandVar
      , guidance : List PromptGuidance
      , files : List PromptFile
      , allowedTools : Optional (List Text)
      , tags : List Text
      , launch : Optional Launch
      }

-- ---------------------------------------------------------------------------
-- campaign-discover  (SKILL.md workflows A ++ B: health check ++ target discovery)
-- ---------------------------------------------------------------------------
let campaign-discover : AgentPrompt =
      { name = "campaign-discover"
      , version = Some "1.0.0"
      , description = Some "Verify the durable runtime is healthy, then list verification units by project or kind."
      , prompt =
          "You are operating the shikumi-campaign verification runtime. First confirm the durable store is alive, then list the verification units the caller asked for.\n\n"
          ++ "1. Run `./scripts/campaign-cli.py status`. The PostgreSQL socket `/home/nyc/.local/state/shikumi-campaign-pg.sock` must report ALIVE and the server UP. If it is down, stop and report that — do not proceed to discovery on a dead journal, because verdicts recorded here must be durable.\n"
          ++ "2. List units: all of them by default; filter by `project` (pgcl, telix, tessera, organ-bank, mowgli, peirce, mercury) and/or by `kind` (host-verify, qemu-boot-matrix) when the caller supplies one. Use `./scripts/campaign-cli.py discover [--project P] [--kind K]`.\n"
          ++ "3. Report each unit as `<project>/<arch>@<config>` with its kind and the exact command that would run. For a kernel-matrix query, summarise the architecture fan-out rather than dumping every cell."
      , vars =
          [ { name = "project", type = "text", default = None Text, description = Some "Limit discovery to one portfolio project.", required = False, validation = Some "one of: pgcl, telix, tessera, organ-bank, mowgli, peirce, mercury" }
          , { name = "kind", type = "text", default = None Text, description = Some "Limit discovery to one unit kind.", required = False, validation = Some "host-verify | qemu-boot-matrix" }
          ]
      , prompts = [] : List Prompt
      , commandVars = [] : List CommandVar
      , guidance =
          [ { title = "Health gate", body = "If the status socket is not ALIVE, stop and surface the outage; never report a discovered schedule as ground truth while the journal is down.", when = None Text }
          , { title = "Manifest-aware discovery", body = "Host-verify units are the union of built-ins and Dhall target manifests in shikumi-campaign/targets/; a manifest on an existing key is authoritative and one on a new key is added. Mention manifest-origin units when they appear.", when = Some "kind == host-verify" }
          ]
      , files = [] : List PromptFile
      , allowedTools = None (List Text)
      , tags = [ "campaign", "discover", "read-only" ]
      , launch = None Launch
      }

-- ---------------------------------------------------------------------------
-- campaign-verify  (SKILL.md workflow C: verify a single unit, live or plan)
-- ---------------------------------------------------------------------------
let campaign-verify : AgentPrompt =
      { name = "campaign-verify"
      , version = Some "1.0.0"
      , description = Some "Execute one verification cell in plan (offline) or live (real process) mode and report the oracle-derived verdict."
      , prompt =
          "You are reproducing a single verification claim on the shikumi-campaign runtime.\n\n"
          ++ "1. Take the unit (`<project>/<arch>@<config>`) and a mode. Default to `plan`: it records the exact shell command that would run, journals discovery, and returns `planned` — safe for whole-matrix scans. Use `live` only when the caller explicitly wants real execution: it spawns the process, captures stdout/stderr into a timestamped log, classifies the verdict, and journals the outcome to memory.\n"
          ++ "2. Run `./scripts/campaign-cli.py verify <unit> --plan` or `--live`.\n"
          ++ "3. Report the verdict, the exact command, the log path, and the trailing log lines. The verdict is derived strictly from the process log and exit code by the ground-truth oracle (success markers for host-verify cells; subtotal ++ LTP FAIL LIST ++ known-fail baseline for kernel cells). Do not infer success from your own opinion of the output."
      , vars =
          [ { name = "unit", type = "text", default = None Text, description = Some "The verification unit to run, e.g. telix/host@verify.", required = True, validation = Some "<project>/<arch>@<config>" }
          , { name = "mode", type = "text", default = Some "plan", description = Some "plan = offline dry run; live = real process execution.", required = False, validation = Some "plan | live" }
          ]
      , prompts =
          [ { var = "mode", text = "Run this cell as an offline dry run (plan) or execute the real process (live)?", when = None Text, choices = Some [ "plan", "live" ] }
          ]
      , commandVars = [] : List CommandVar
      , guidance =
          [ { title = "Verdict is oracle-derived", body = "A cell passes only when the oracle facts hold (every success marker present; for kernel cells, every named failure is on the documented baseline). Never upgrade a `failed` or `skipped` verdict to a pass because the model believes the change is correct.", when = None Text }
          , { title = "Live mode writes to memory", body = "Live verification journals the outcome into Kioku across the portfolio namespaces. If the caller asked for a throwaway check, prefer plan mode and say so.", when = Some "mode == live" }
          ]
      , files = [] : List PromptFile
      , allowedTools = None (List Text)
      , tags = [ "campaign", "verify" ]
      , launch = None Launch
      }

-- ---------------------------------------------------------------------------
-- campaign-review  (SKILL.md workflow E: review landed repair branches)
-- ---------------------------------------------------------------------------
let campaign-review : AgentPrompt =
      { name = "campaign-review"
      , version = Some "1.0.0"
      , description = Some "Inspect, approve (merge) or reject human-review campaign branches at the human merge seam."
      , prompt =
          "You are operating the human merge seam for the shikumi-campaign runtime. Automated repair agents land on `campaign/<run>` branches; a human reviewer sanctions merges.\n\n"
          ++ "1. List pending branches for a project: `./scripts/campaign-cli.py review list --project <p>`.\n"
          ++ "2. Approve and merge — `./scripts/campaign-cli.py review approve --project <p> --branch <b>`. Approval is not a formality: before merging, the runtime re-verifies every touched file against the clean parent using the cell's oracle (approveBranch). Only a clean re-verification merges. If the re-verification fails, do not merge and report which file failed which oracle check.\n"
          ++ "3. Reject — `./scripts/campaign-cli.py review reject --project <p> --branch <b> --reason \"...\"`. Rejection removes the branch and its worktree and journals the reason to Kioku memory so the same failure is recalled later.\n"
          ++ "4. Report what happened: merged (and the re-verification result), rejected (and the journaled reason), or left pending."
      , vars =
          [ { name = "project", type = "text", default = None Text, description = Some "The portfolio project owning the branch.", required = True, validation = Some "one of the campaign projects" }
          , { name = "branch", type = "text", default = None Text, description = Some "The campaign/<run> branch to act on.", required = True, validation = Some "campaign/..." }
          , { name = "action", type = "text", default = Some "list", description = Some "list | approve | reject | answer.", required = False, validation = Some "list | approve | reject | answer" }
          , { name = "reason", type = "text", default = None Text, description = Some "Why (required for reject; journaled to Kioku).", required = False, validation = None Text }
          ]
      , prompts =
          [ { var = "action", text = "What should be done with the branch?", when = None Text, choices = Some [ "list", "approve", "reject", "answer" ] }
          ]
      , commandVars = [] : List CommandVar
      , guidance =
          [ { title = "Receipts are evidence, not verdicts", body = "A repair blueprint/receipt accompanying a branch describes the trajectory; it does not make the repair admissible. Admissibility comes from the oracle re-verifying the changed files (invariant #4). Never merge on a receipt's own claim.", when = None Text }
          , { title = "Reject must journal a reason", body = "A rejection without a --reason is incomplete: the reason is what Kioku recalls on the next attempt of the same cell.", when = Some "action == reject" }
          ]
      , files = [] : List PromptFile
      , allowedTools = None (List Text)
      , tags = [ "campaign", "review", "human-seam" ]
      , launch = None Launch
      }

let allPrompts : List AgentPrompt = [ campaign-discover, campaign-verify, campaign-review ]

in  { AgentPrompt = AgentPrompt
    , campaign-discover = campaign-discover
    , campaign-verify = campaign-verify
    , campaign-review = campaign-review
    , allPrompts = allPrompts
    }
