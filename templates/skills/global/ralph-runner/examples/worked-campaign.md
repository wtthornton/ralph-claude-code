# Worked example — a short Ralph campaign

A transcript-style walk-through of the skill's expected behavior on a small
campaign (3 loops, one improvement issue filed). Times and ids are illustrative.

## User prompt

> Run ralph against the TappsCodingAgents backlog and monitor it for the next hour.

## What the orchestrator does

### Phase 0 — pre-flight + lane lock (one Bash call, ~1s)

```
---lane---
root=/home/user/code/myproject name=myproject log=/tmp/ralph-live-myproject.log
---remote---
origin  git@github.com:org/myproject.git (fetch)
origin  git@github.com:org/myproject.git (push)
---files---
-rw-r--r-- 1 user user 1.2K Jan 12 10:01 .ralphrc
-rw-r--r-- 1 user user 4.8K Jan 12 09:58 CLAUDE.md
package.json
---agent-flag---
RALPH_USE_AGENT=true
---tools---
/home/user/.local/bin/ralph
/home/user/.claude/local/claude
---other-lanes---
in-lane=0 other-lanes=2 (other lanes are out of scope — I will not touch them)
brain-health=200
```

All checks green → proceed. The 2 out-of-lane Ralph processes (perhaps an AgentForge campaign and a tapps-mcp campaign) are visible but the orchestrator will never inspect or interact with them.

### Phase 3 — detached startup (per-project log)

```
$ : > "$LIVE_LOG" && nohup setsid ralph --live </dev/null >"$LIVE_LOG" 2>&1 &
$ sleep 2 && ps -eo pid,sid,pgid,etime,cmd | grep [r]alph_loop
  84210  84210  84210  00:02 /bin/bash /home/user/.ralph/ralph_loop.sh
$ readlink /proc/84210/cwd
/home/user/code/myproject
```

PID == SID == PGID = 84210, CWD == $PROJECT_ROOT → fully detached AND in lane. Good.

### Phase 4 — monitor + triage (representative event sequence)

```
[loop 1] Working <ISSUE-ID:TAP-1234>      → ack: "Loop 1 started on TAP-1234"
[loop 1] feat(TAP-1234): add caching      → subagent verifies → "verified: 1 commit, origin sync=ok"
[loop 1] === Completed Loop #1 RALPH_STATUS{tasks_completed:1,files_modified:3}

[loop 2] Working <ISSUE-ID:TAP-1235>      → ack
[loop 2] hook block: write to .ralph/.brief.json → catalogue (1st occurrence — no file yet)
[loop 2] feat(TAP-1235): refactor X       → subagent verifies → "verified"

[loop 3] hook block: write to .ralph/.brief.json → 2nd occurrence, still wait
... (more loops elided)
[loop 5] hook block: write to .ralph/.brief.json → 3rd occurrence
  → reflection subagent fires:
    "Pattern: agent attempts coordinator-brief write, gets blocked by
     .ralph/ protection hook (3 occurrences in loops 2, 3, 5).
     Recommended fix: PROMPT.md should redirect to /tmp/<run-id>-brief.json.
     Filed TAP-1236 — fix(coordinator): redirect brief write off .ralph/"
```

### Phase 5 / Exit criteria — graceful end

After an hour (or when the user types `stop`), the orchestrator emits a
Phase 7 summary:

```
Campaign summary
================
Loops shipped:   5
Stories Done:    2  (TAP-1234, TAP-1235)
Wall-clock:      58m

Epic progress:
  6/15 EPIC-CACHE-IMPROVEMENTS

Friction filed:
  TAP-1236  fix(coordinator): redirect brief write off .ralph/

Follow-ups for you:
  • PROMPT.md still says "write brief.json under .ralph/" in §2 — TAP-1236
    proposes the fix but you may want to inline it before next run.
```

## What the orchestrator does NOT do

- It does NOT dump 500 lines of `ralph.log` into the main chat.
- It does NOT read every commit's diff — it asks `general-purpose` for a one-line verdict.
- It does NOT file a Linear ticket on the 1st occurrence of a friction pattern — waits for 3 occurrences AND a fix that Ralph could ship.
- It does NOT use `ralph-explorer` / `ralph-tester` / `ralph-reviewer` / `ralph-architect` directly — those are Ralph's *internal* subagents, fired by Ralph itself. The orchestrator uses Claude Code's built-in `Explore` or `general-purpose` agents for its OWN delegations.
