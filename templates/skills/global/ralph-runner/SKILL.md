---
name: ralph-runner
description: >
  Run, monitor, and continuously improve Ralph (autonomous dev loop for
  Claude Code) against a Linear backlog. Use when the user says
  "run ralph", "start ralph", "ralph campaign", "monitor ralph",
  "restart ralph", "ralph against TAP-### / ENG-### / <ISSUE-ID>", or
  wants Ralph to chew through filed epics autonomously with the
  orchestrator filing follow-up Linear issues for the friction patterns
  it observes. Encodes proven startup, monitor-filter, kill-safety, and
  subagent-delegation patterns. Keeps the orchestrator's context window
  tiny by delegating Linear writes, commit verification, and bulk log
  analysis to subagents.
version: 1.1.0
ralph: true
ralph_version_min: "2.17.0"
attribution: "Authored for Ralph operator-side autonomous-loop orchestration"
user-invocable: true
disable-model-invocation: false
allowed-tools:
  - Bash
  - Read
  - Grep
  - Glob
  - Task
  - Agent
---

# ralph-runner

Orchestrate a [Ralph](https://github.com/wtthornton/ralph-claude-code) campaign end-to-end: start Ralph fully detached, stream its events, react to outcomes, and feed observed friction back into Linear so Ralph can fix itself on subsequent loops.

## When to invoke

Trigger this skill when the user asks to run, monitor, restart, or continuously orchestrate Ralph. Common phrasings:

- "Run ralph against TAP-#### / ENG-#### / <ISSUE-ID> / against the backlog"
- "Start a ralph campaign"
- "Monitor ralph for me"
- "Restart ralph"
- "Ralph the rest of this epic"
- Anything implying autonomous, multi-loop Ralph execution with observation

Do **not** trigger for one-off `git`/`ralph` lookups, or when the user is doing manual story work themselves.

## Core principle — keep the orchestrator's context tiny

The user explicitly wants Ralph to run "almost continuously" without bloating the main conversation. Every operation that would dump >3 file reads, multi-line Linear payloads, or full log scans into the main context **MUST** be delegated to a subagent. The orchestrator reads only short structured summaries.

Subagent boundaries:
- **Linear writes** (file issue, post comment, update status) → spawn `general-purpose` agent, instruct it to use the `linear-issue` skill if present (TappsMCP installs it); return one line: `Filed <ISSUE-ID>`
- **Commit verification** (did `<ISSUE-ID>` land on main, is origin synced) → spawn `general-purpose`, return one line: `verified` or `missing`
- **Bulk log analysis** (top friction patterns over last N loops) → spawn `Explore` (or `ralph-explorer` if TappsMCP installed it), return ≤10 bullets
- **Skill / config creation** → spawn `general-purpose`
- Main session does: pre-flight, Ralph startup, Monitor arming, event triage, stop decisions

## Project lane discipline — only touch THIS project's Ralph

When multiple projects each have their own Ralph running, **every session is responsible for exactly one lane: its own project**. The orchestrator must NEVER read, kill, or mutate Ralph state that belongs to a different project. Cross-lane bleed has cost real time the hard way (sessions killing siblings' processes, tailing the wrong log, filing Linear issues against the wrong team).

At Phase 0, capture and lock the lane:

```bash
PROJECT_ROOT="$(pwd)"
PROJECT_NAME="$(basename "$PROJECT_ROOT")"
LIVE_LOG="/tmp/ralph-live-${PROJECT_NAME}.log"
```

Use those three variables in every subsequent operation — no exceptions.

**Process inspection (ps / pstree / kill).** When listing Ralph processes, filter to those whose CWD matches `$PROJECT_ROOT`:

```bash
for pid in $(pgrep -f ralph_loop.sh); do
  cwd=$(readlink /proc/$pid/cwd 2>/dev/null || true)
  [[ "$cwd" == "$PROJECT_ROOT"* ]] && echo "in-lane: $pid"
done
```

Any `ralph_loop.sh` outside the lane is **not yours** — do NOT `pstree` it, do NOT `kill` it, do NOT inspect its `.ralph/` state. At most, report a one-line aggregate to the user: `"3 other Ralph instances running in other projects (out of scope — I won't touch them)"`.

**Log paths.** The historical `/tmp/ralph-live.log` is a shared file — concurrent projects clobber each other. ALWAYS use `$LIVE_LOG` (project-scoped). Monitor only tails this one file. Never glob `/tmp/ralph-live-*.log` — that pulls in other lanes.

**Per-project state.** Read `$PROJECT_ROOT/.ralph/status.json`, `$PROJECT_ROOT/.ralph/.circuit_breaker_state`, `$PROJECT_ROOT/.ralph/logs/ralph.log`. If you ever find yourself reaching for `~/code/<other-project>/.ralph/...`, stop — that's a different lane.

**Subagent briefs.** Every delegation MUST lead with `PROJECT_ROOT=<path>` and the instruction `Operate ONLY inside this directory. Do not read, write, run commands, or file tickets against sibling repos.` The brief templates in Phase 4 below already enforce this — preserve the prefix verbatim.

**The one acceptable cross-lane surface** is read-only aggregate telemetry: "how many Ralph campaigns are running right now?" → answer with `pgrep -f ralph_loop.sh | wc -l` and stop. Do not enumerate names, do not look up their projects, do not interact with their state.

**Identity check for the user when in doubt.** If a process, log file, Linear issue, or commit is ambiguous — *was that mine or another lane's?* — refuse to act and ask the user to confirm the lane. Never default to "act anyway, it's probably mine."

## Workflow

### Phase 0 — Pre-flight sanity (parallel in one Bash)

```bash
# Lock the lane first — see "Project lane discipline" above.
PROJECT_ROOT="$(pwd)"
PROJECT_NAME="$(basename "$PROJECT_ROOT")"
LIVE_LOG="/tmp/ralph-live-${PROJECT_NAME}.log"
echo "---lane---" && echo "root=$PROJECT_ROOT name=$PROJECT_NAME log=$LIVE_LOG"
echo "---remote---" && git remote -v
echo "---files---" && ls -la .ralphrc CLAUDE.md 2>&1 && (ls pyproject.toml package.json 2>/dev/null || echo "no manifest")
echo "---agent-flag---" && grep "^RALPH_USE_AGENT=true" .ralphrc || echo "AGENT MODE NOT SET"
echo "---tools---" && which ralph claude
# Detect other-lane ralph processes — count only, do not enumerate or interact.
echo "---other-lanes---" && {
  in=0; other=0
  for pid in $(pgrep -f ralph_loop.sh 2>/dev/null); do
    cwd=$(readlink /proc/$pid/cwd 2>/dev/null || true)
    if [[ "$cwd" == "$PROJECT_ROOT"* ]]; then in=$((in+1)); else other=$((other+1)); fi
  done
  echo "in-lane=$in other-lanes=$other (other lanes are out of scope — I will not touch them)"
}
# Optional: probe local brain if .mcp.json wires tapps-brain HTTP
if grep -q 'tapps-brain' .mcp.json 2>/dev/null; then curl -s -o /dev/null -w "brain-health=%{http_code}\n" http://127.0.0.1:8080/health; fi
```

Stop if any fail. Surface exactly which check failed. **Don't start Ralph on partial sanity.** If `in-lane >= 1`, a Ralph is already running in THIS project — do not double-spawn; instead reattach the Monitor in Phase 4 to the existing `$LIVE_LOG` and skip Phase 3.

Note: `tapps-brain` (if your project uses it) exposes `/health`, NOT `/healthz` — using the wrong name returns 404 even when the service is up.

### Phase 1 — (Optional) pre-Ralph config tweaks

If the campaign requires `.ralphrc` edits, **hand the user a sed command** — do NOT edit `.ralphrc` directly. Project hooks block agent writes to it.

Pattern: anchor the sed to the exact current value so it's a no-op if anything has drifted:

```bash
sed -i 's|^KEY=oldval$|KEY=newval|' .ralphrc && grep -n '^KEY=' .ralphrc
```

Wait for the user to reply `done` before proceeding.

### Phase 2 — Linear credential check

**Skip the LINEAR_API_KEY runbook.** Linear in Claude Code is OAuth via `mcp__plugin_linear_linear__*` (token in `~/.claude/.credentials.json`). The plugin powers Ralph's `list_issues`/`save_issue`/`save_comment` calls. A `LINEAR_API_KEY` is only useful for the planned standalone poller (rarely wired). The startup "Linear count unavailable" WARN is cosmetic.

Only intervene if `mcp__plugin_linear_linear__list_users` fails — then surface the OAuth re-auth flow (`claude /mcp`).

### Phase 3 — Start Ralph FULLY DETACHED

Use `setsid + nohup` so Ralph survives the orchestrator's bash wrapper dying. The redirect target is `$LIVE_LOG` (the per-project path from Phase 0) — never the shared `/tmp/ralph-live.log`:

```bash
: > "$LIVE_LOG" && \
  nohup setsid ralph --live </dev/null >"$LIVE_LOG" 2>&1 &
sleep 2 && ps -eo pid,sid,pgid,etime,cmd | grep [r]alph_loop
```

Verify the new `ralph_loop.sh` PID == SID == PGID (independent session, separate from the orchestrator's shell SID). Confirm its CWD matches `$PROJECT_ROOT` via `readlink /proc/<pid>/cwd` — if it doesn't, something is very wrong; stop and surface.

**CRITICAL:** Never redirect into `.ralph/` — pre-tool-use hooks (`.ralph/hooks/validate-command.sh`) BLOCK all writes to that directory. Always use the per-project `$LIVE_LOG` under `/tmp/`.

### Phase 4 — Monitor

Arm a persistent Monitor on `$LIVE_LOG` (the per-project path locked at Phase 0 — never glob `/tmp/ralph-live-*.log`, that would pull in other lanes):

```
tail -F "$LIVE_LOG" 2>/dev/null | grep -E --line-buffered \
"Loop #|=== Starting|=== Completed|Working <ISSUE-ID>|Selected task|LINEAR_ISSUE:|LOCALITY HINT|save_issue|In Review|BLOCKED|passed|failed|PASSED|FAILED|Traceback|FATAL|circuit breaker|Falling back to legacy|RALPH_STATUS|EXIT_SIGNAL|TASKS_COMPLETED|FILES_MODIFIED|RECOMMENDATION:|reviewer:|Reviewer verdict|hook error|hook block"
```

`persistent: true`, `timeout_ms: 3600000` (or longer for multi-hour campaigns).

### Phase 4 — Event triage (what to do per event class)

| Event signature | Action | Delegation |
|---|---|---|
| `Working <ISSUE-ID>` / `Selected task` | 1-line ack to user with issue id | none |
| `=== Completed Loop #N` + `RALPH_STATUS` block | parse, update tally, post 1-line summary | none |
| `feat(<ISSUE-ID>):` or `fix(<ISSUE-ID>):` commit | verify landed on main | **subagent: `git log main --grep='<ISSUE-ID>'` + `git rev-list --left-right --count origin/main...main`** |
| `hook error / BLOCKED:` (e.g., python3 -c blocked, write to .ralph/ blocked) | catalogue as friction | **subagent: file Linear improvement issue** |
| `Workflow anomaly`: PROMPT.md deviation, post-commit edits, reviewer short-circuit, push-without-PR concern | catalogue | **subagent: file Linear improvement issue** |
| `InputValidationError` / one-off tool error | noise, ignore | none |
| `circuit breaker tripped` | **STOP**, surface reason from log tail | none |
| `STATUS: BLOCKED` + P0/Urgent story | **STOP** for human review | none |
| Mid-epic scoped pytest failure | continue (Ralph self-handles) | none |

### Phase 4 — Subagent brief templates

**Linear-write subagent (use for ALL Linear writes):**

```
PROJECT_ROOT=<path captured at Phase 0>
Operate ONLY inside this directory. Do not read, write, run commands, or
file tickets against sibling repos.

File a Linear issue about <ONE-LINE TOPIC>.

Prefer the `linear-issue` skill if present (TappsMCP installs it).
Otherwise call `mcp__plugin_linear_linear__save_issue` directly and apply
the assignee-default (agent user, not the OAuth human), the `## Acceptance`
checkbox rule, and the `file.ext:LINE-RANGE` anchor rule inline.

Project: <PROJECT_NAME — read from RALPH_LINEAR_PROJECT in .ralphrc;
         fall back to .tapps-mcp.yaml `linear_project` if Ralph+TappsMCP>
Team:    <TEAM_KEY — same fallback chain>
Assignee: agent user (resolve via `list_users` → match `agent`/`bot`/`claude`
          or .tapps-mcp.yaml `agent_user`). Never the OAuth human.
Parent epic: <PARENT_EPIC_ID if part of an existing improvement epic, else none>

Title: '<observed pattern>: <one-line problem>'
Description: include the observed pattern, log excerpt as evidence (≤10 lines),
recommended fix, and priority (Medium for friction, High for blockers, Urgent for P0).

Reply with EXACTLY one line: "Filed <ISSUE-ID> — <title>". No other prose.
```

**Commit-verification subagent:**

```
PROJECT_ROOT=<path captured at Phase 0>
Operate ONLY inside this directory. Do not read, write, or run commands
against sibling repos.

Verify <ISSUE-ID> work landed on main. Run from $PROJECT_ROOT:
  git log main --oneline --grep='<ISSUE-ID>' | head -5
  git rev-list --left-right --count origin/main...main
Report exactly one line: "verified: N commits, origin sync=ok" OR "missing: <reason>".
```

**Reflection subagent (run every N loops, e.g., 5):**

```
PROJECT_ROOT=<path captured at Phase 0>
LIVE_LOG=<per-project log path from Phase 0>
Operate ONLY inside $PROJECT_ROOT. Read only $LIVE_LOG — never glob
/tmp/ralph-live-*.log, never read sibling repos' state.

Read the tail of $LIVE_LOG (last ~500 lines). Identify the top 3
recurring friction patterns (hook blocks, tool validation errors, workflow
deviations from .ralph/PROMPT.md, push-without-PR moments, etc).

For each pattern: count occurrences, capture one representative log excerpt
(≤8 lines), recommend a fix.

If any pattern occurred ≥3 times AND has a fix that Ralph could ship, spawn a
nested subagent to file it via the linear-issue skill (or save_issue direct
if linear-issue isn't installed). The nested subagent inherits the same
PROJECT_ROOT lane discipline.

Report: 3-line summary back to orchestrator (one per pattern), plus
"Filed <ISSUE-ID>, <ISSUE-ID>, ..." line listing any tickets filed.
```

### Phase 6 — Auto-restart (optional)

If Ralph dies mid-campaign (detect via absence of in-lane `ralph_loop.sh` in `ps` — apply the Phase 0 lane filter, do NOT restart because another project's Ralph died), restart with the same setsid+nohup pattern, writing to `$LIVE_LOG`. Cap at **3 restarts** before declaring "Ralph is broken — needs human." Each restart, capture the death reason (last 30 lines of `$LIVE_LOG`) before truncating.

### Phase 7 — Final summary

End with:

- Loops shipped, stories Done, wall-clock total
- Epic progress per filed epic (e.g., 4/15 `<EPIC-ID>`, 0/24 `<EPIC-ID>`)
- Top 3 friction patterns + Linear tickets filed for them
- Any open follow-ups for the user (config tweaks they need to apply, PROMPT.md contradictions, push-policy decisions)

## Exit criteria

The campaign ends — and the orchestrator yields control back to the user — on the **first** of these to fire:

- All in-scope epic children Done → emit Phase 7 success summary
- 5 consecutive no-commit loops → Ralph trips its own circuit breaker; surface the breaker reason from log tail
- Any P0/Urgent story emits `STATUS: BLOCKED` or its tests fail twice → STOP for human review
- User sends `stop` or Ctrl+C
- Phase 6 auto-restart cap (3) exhausted → STOP, "Ralph is broken — needs human"

In all cases, write the Phase 7 final summary before yielding.

## Anti-patterns to avoid (each cost time the hard way)

### A. `ralph_loop.sh` is ONE process that LOOKS LIKE TWO in `ps` — AND it might belong to a different lane

The outer `ralph_loop.sh` forks an inner subshell (also named `ralph_loop.sh`) for the loop body. Parent/child of the same instance.

**Before any `kill`, do TWO checks in order:**

1. **Lane check** — `readlink /proc/<PID>/cwd` must equal `$PROJECT_ROOT`. If it doesn't, refuse: that process belongs to a different project's lane. Even if it looks orphaned, hung, or runaway — that's the other lane's problem, not yours.
2. **Family check** — `pstree -p <outer-PID>`. If the second PID is a child of the first, they're one instance — do NOT kill either. Killing the parent orphans the child, which keeps running, but the wrapper bash dying later may take the whole tree down via SIGHUP propagation.

### B. SIGTERM may be no-op at first, then take effect minutes later

When the wrapper bash exits naturally, its orphaned children can be reaped. If you sent SIGTERM and "nothing happened", don't assume it stuck. **Use `setsid+nohup` to fully detach Ralph from any wrapper bash.**

### C. Pre-tool-use hooks BLOCK writes to `.ralph/`

`: > .ralph/foo`, `echo … > .ralph/foo`, even temp files. Always use `/tmp/`.

### D. NEVER use angle-bracketed placeholders in shell commands

`<paste-key-here>` looks like input redirection to bash. The export silently breaks. Use obvious fakes like `lin_api_REPLACE_ME` and explicitly call out the substitution step in the user-facing message.

### E. OAuth via the Linear plugin is canonical

Never propose creating `LINEAR_API_KEY` or `~/.config/claude-agent/linear.env`. The plugin's OAuth (in `~/.claude/.credentials.json`) powers `list_issues`/`save_issue`/`save_comment`. The harness's "Linear count unavailable" startup WARN is cosmetic telemetry.

### F. The first selected issue is often the branch-name issue

Ralph's coordinator has a cache-locality optimizer that initially picks the issue matching the current branch name (e.g. `feat/tap-1691-foo` → TAP-1691, or `eng/eng-42-bar` → ENG-42). The agent then re-polls Linear and self-corrects to the highest-priority story in the same loop. **Report the FINAL selection, not the initial guess.**

### G. Don't sweep without the lane filter

`pgrep -f ralph_loop.sh`, `ls /tmp/ralph-live-*.log`, `find ~/code -name .ralph`, and `ps -ef | grep ralph` all return cross-lane results by default. Every such sweep MUST be followed by a CWD filter against `$PROJECT_ROOT` before you act on any entry. Reading another lane's state to "just check" is the easiest way to drift — the next command after the read often *acts* on what was read.

Specifically forbidden:
- Tailing `/tmp/ralph-live-*.log` with a glob — only `$LIVE_LOG`.
- Reading `~/code/<other-project>/.ralph/status.json` to compare with this lane's status.
- Killing a `ralph_loop.sh` PID whose `readlink /proc/$pid/cwd` is not `$PROJECT_ROOT`.
- Filing a Linear issue about friction observed in another lane's log.
- "Helpfully" restarting a different project's Ralph because it looks idle.

If the user asks about a cross-lane situation explicitly ("is the AgentForge Ralph still running?"), give a one-line aggregate (`pgrep -f ralph_loop.sh | wc -l` count, no enumeration) and tell them to open Claude Code in that project's directory to handle it.

### H. tapps-brain MCP auth is independent of tapps-mcp *(only if your project uses tapps-brain)*

If your `.mcp.json` wires `tapps-brain`: it lives at `http://127.0.0.1:8080/mcp/` and requires Bearer auth via `$TAPPS_BRAIN_AUTH_TOKEN`. A mismatched token causes startup WARN "MCP probe: tapps-brain NOT reachable" but does **not** block Ralph — the agent reaches tapps-brain indirectly via `mcp__tapps-mcp__tapps_memory(...)`, which proxies through `tapps-mcp`'s BrainBridge (HTTP mode, `http://127.0.0.1:8080/v1/*`). Surface as warning, don't stop.

## Continuous-improvement loop (the "almost continuously" part)

The skill's value compounds when it files Linear issues for the friction it observes, because Ralph picks those up on subsequent loops. Net effect: Ralph fixes Ralph.

**Reflection cadence:** every 5 loops OR whenever an event class fires for the 3rd time, spawn a reflection subagent (template above). It batches similar friction into single issues to avoid Linear-spam.

**Categories worth filing:**

- Hook block patterns (e.g., `python3 -c` consistently blocked) → propose hook relaxation or PROMPT.md guidance to use script files
- Workflow contradictions (`PROMPT.md` says X in one place, Y elsewhere) → propose canonical resolution
- Self-merge / self-push events → if the user hasn't blessed direct-to-main pushes, propose PR-gating via branch protection
- Reviewer short-circuits (agent proceeds to In Review without addressing reviewer feedback) → propose stricter gate in PROMPT.md
- Coordinator cache-locality misfires (initial issue id is wrong) → propose tuning of the locality weight in `.ralphrc`

## Quick reference — the minimum viable orchestration

If you just need to "run ralph and tell me what happens" without the full continuous-improvement layer:

1. Run Phase 0 sanity checks
2. Phase 3 startup (`setsid + nohup`)
3. Phase 4 Monitor armed
4. Report each event as it lands; spawn verification subagent on commits
5. Stop on user signal or circuit breaker
6. End-of-run: epic progress + commits-shipped table

Skip the reflection subagents and Linear-write subagents if the campaign is short (<3 loops).
