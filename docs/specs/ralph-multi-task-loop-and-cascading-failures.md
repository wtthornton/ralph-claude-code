# Ralph Incident: Multi-Task Loop Violation and Cascading Failures

**Severity:** High (silent loop termination, wasted API cost, undetected permission issues)
**Date observed:** 2026-03-21 07:59-08:09 UTC-7
**Affected components:**
- `~/.ralph/PROMPT.md` (loop execution contract)
- `~/.ralph/ralph_loop.sh` (stream extraction, exit condition logic)
- `~/.ralph/lib/response_analyzer.sh` (dual-result handling, permission denial extraction)
- `.ralphrc` (ALLOWED_TOOLS gaps)
- `.claude/settings.json` (startup hook, MCP server config)

**Related spec:** `ralph-jsonl-crash-bug.md` (JSONL parser crash — root cause for silent termination)

---

## Summary

A single Ralph loop invocation on 2026-03-21 exhibited five interconnected failures:

1. **Claude completed 2 tasks in one loop** instead of the mandated 1, violating the execution contract
2. **Two `result` objects in one NDJSON stream** amplified the existing JSONL crash bug
3. **Permission denials went undetected** because analysis crashed before extracting them
4. **ALLOWED_TOOLS patterns had gaps** that caused 5 permission denials during execution
5. **Infrastructure failures** (MCP servers, startup hook) degraded the session silently

Net result: Ralph logged "Analyzing Claude Code response..." then exited to shell. No error was logged. No loop completion was recorded. The next loop never started.

## Timeline

```
07:59:02  Ralph starts Loop #1, Call 1/100
07:59:02  SessionStart hook fails: "/bin/sh: 1: powershell: not found" (exit 127)
07:59:03  MCP servers: tapps-mcp FAILED, docs-mcp FAILED, playwright connected
07:59:03  Live output mode enabled, Claude Code starts
~08:01    Claude begins F-0.3b (ConnectionIndicator + EventLog)
~08:02    Permission denied: find command (not in ALLOWED_TOOLS)
~08:04    Permission denied: git -C /path add ... (3 attempts, pattern mismatch)
~08:05    Claude works around: uses git add with relative paths
~08:05    F-0.3b complete. Claude emits RALPH_STATUS (TASKS_COMPLETED: 1, EXIT_SIGNAL: false)
~08:05    Claude does NOT stop. Says "Moving to the next task."
~08:05    Claude begins B-0.7 (SSE token auth)
~08:07    Permission denied: grep -r in Bash (within subagent, pattern mismatch)
~08:08    B-0.7 complete. Claude emits second RALPH_STATUS (TASKS_COMPLETED: 2, EXIT_SIGNAL: false)
08:08:44  Claude Code exits. Result JSON written to stream.
08:08:44  Stream extraction FAILS SILENTLY (see ralph-jsonl-crash-bug.md)
08:08:44  Ralph logs "Analyzing Claude Code response..."
08:08:44  analyze_response called on 5249-line NDJSON file
08:08:44  parse_json_response corrupts variables (5249 values per field)
08:08:44  .response_analysis never written. Script exits silently.
          No "Completed Loop #1" logged. No next loop started.
```

**Total API cost:** $2.60 ($1.48 Opus for F-0.3b, $1.12 Opus + Haiku for B-0.7)
**Files committed:** 11 across 2 commits (both tasks DID succeed, just the loop control broke)

---

## Issue 1: Multi-Task Loop Violation

### Problem

PROMPT.md's execution contract states:

> "ONE task per loop -- focus on the most important thing"
> "Do the FIRST unchecked item. Nothing else."

Scenario 5 describes what happens when a task completes with more work remaining:

> **Given:** Current task is done and checked off `[x]`, but unchecked `[ ]` items remain.
> **Then:** Set `STATUS: IN_PROGRESS`, `EXIT_SIGNAL: false`, `TASKS_COMPLETED_THIS_LOOP: 1`.
> **Ralph's Action:** Continues loop with next unchecked item.

Claude misinterpreted "Ralph's Action: Continues loop with next unchecked item" as a
self-instruction to keep working, rather than a description of what the Ralph harness
does externally (re-invoking Claude in a new loop iteration).

### Evidence

From the Claude output log (`claude_output_2026-03-21_07-59-02.log`):

**Turn 1 completion (line 3312) — correct behavior:**
```
Task: F-0.3b complete.
Files changed: 7
---RALPH_STATUS---
STATUS: IN_PROGRESS
TASKS_COMPLETED_THIS_LOOP: 1
EXIT_SIGNAL: false
RECOMMENDATION: Proceed with B-0.7 (SSE auth token via query param)
---END_RALPH_STATUS---
```

**Immediate continuation (line 3316+) — violation:**
```
F-0.3b is done and committed. Moving to the next task.
Task: B-0.7 -- Auth token on SSE endpoint via ?token= query param...
```

Claude then spent another ~3 minutes and 22 API turns implementing B-0.7, emitting
a second `result` object at the end.

### Impact

- **Cost waste potential:** In a "stuck" scenario, Claude could burn through the entire
  context window doing multiple tasks before Ralph's circuit breaker has any chance to
  detect problems.
- **No checkpoint between tasks:** If B-0.7 had failed, there would be no clean
  rollback point. Both tasks share one commit history within one Claude session.
- **Dual result objects:** Amplifies the JSONL crash bug (see Issue 2).

### Fix: Strengthen PROMPT.md stop instruction

Add explicit stop language that cannot be misread as self-instruction:

```markdown
## Execution Contract (Per Loop)
...
9. Commit implementation + fix_plan update together.
10. Output your RALPH_STATUS block.
11. **STOP. End your response immediately after the status block.**
    Do NOT start another task. Do NOT say "moving to the next task."
    The Ralph harness will re-invoke you for the next item.
    Your response MUST end with the closing \`\`\` of the status block.
```

Remove or reword the "Ralph's Action" lines from the exit scenarios, as they describe
harness behavior but Claude reads them as instructions to itself:

```markdown
### Scenario 5: Task Completed, More Work Remains (MOST COMMON)
**Given**: Current task is done and checked off `[x]`, but unchecked `[ ]` items remain.
**Then**: Set `STATUS: IN_PROGRESS`, `EXIT_SIGNAL: false`, `TASKS_COMPLETED_THIS_LOOP: 1`.
**Your action**: STOP. The harness handles re-invocation. Do not continue.
```

---

## Issue 2: Dual Result Objects in NDJSON Stream

### Problem

When Claude completes 2 tasks in one invocation, the NDJSON output contains two
`type: "result"` entries. This is a direct amplification of the JSONL crash bug
documented in `ralph-jsonl-crash-bug.md`.

The stream extraction code at `ralph_loop.sh:1350` uses `grep | tail -1` to extract
the last result line, which correctly handles multiple results. But since the stream
extraction itself failed silently (Layer 1 of the JSONL bug), the dual results
compounded the parsing crash.

### Evidence

```bash
$ grep -c '"type".*"result"' claude_output_2026-03-21_07-59-02.log
2
```

**Result 1 (NDJSON line 3316):** F-0.3b completion
```json
{
  "type": "result",
  "subtype": "success",
  "num_turns": 36,
  "total_cost_usd": 1.48,
  "result": "...TASKS_COMPLETED_THIS_LOOP: 1...EXIT_SIGNAL: false...",
  "permission_denials": [4 entries]
}
```

**Result 2 (NDJSON line 5249):** B-0.7 completion
```json
{
  "type": "result",
  "subtype": "success",
  "num_turns": 22,
  "total_cost_usd": 2.60,
  "result": "...TASKS_COMPLETED_THIS_LOOP: 2...EXIT_SIGNAL: false...",
  "permission_denials": [1 entry]
}
```

### Impact

- The text-parsing fallback in `response_analyzer.sh:489-511` greps for `STATUS:` and
  `EXIT_SIGNAL:` across the entire NDJSON file, matching embedded RALPH_STATUS blocks
  from BOTH results. `cut -d: -f2 | xargs` joins them: `exit_sig="false false"`.
  This doesn't match `"true"`, so `exit_signal` defaults to false (correct by accident).

- If one task had set `EXIT_SIGNAL: true` and the other `false`, the text parser would
  produce `exit_sig="true false"` or `"false true"`, which wouldn't match `"true"` —
  potentially suppressing a valid completion signal.

### Fix: Validate result count after extraction

In the JSONL detection code (from `ralph-jsonl-crash-bug.md` Fix 1), add a warning
when multiple result objects are found:

```bash
# After extracting result_obj in the JSONL handler
local result_count
result_count=$(jq -c 'select(.type == "result")' "$output_file" 2>/dev/null | wc -l)
if [[ $result_count -gt 1 ]]; then
    log_status "WARN" "Multiple result objects found ($result_count). Claude may have " \
               "completed multiple tasks in one loop. Using last result."
fi
```

---

## Issue 3: Permission Denial Masking

### Problem

Claude Code records permission denials in the `result` JSON:

```json
"permission_denials": [
  {"tool_name": "Bash", "tool_input": {"command": "git -C /path add ..."}}
]
```

Ralph's `should_exit_gracefully()` function (`ralph_loop.sh:520-531`) checks
`.response_analysis` for `has_permission_denials: true` and halts with actionable
guidance. This worked correctly on 2026-03-20 (the March 20 session halted properly
with "Permission denied for 3 command(s)").

But on 2026-03-21, the analysis crash (Issue 2 / JSONL bug) meant `.response_analysis`
was never written. The permission denial check at the top of the next loop iteration
never ran. The 5 permission denials in this session went completely undetected.

### Evidence

**March 20 (working):**
```
[17:07:07] [WARN] Permission denied for 3 command(s): Bash(mkdir -p ...), Bash(git -C ...), Bash(cd ... && git add ...)
[17:07:07] [WARN] Update ALLOWED_TOOLS in .ralphrc to include the required tools
[17:07:07] [ERROR] Permission denied - halting loop
[17:07:07] [INFO] Session reset: permission_denied
```

**March 21 (broken):**
```
[08:08:44] [INFO] Analyzing Claude Code response...
<EOF>
```

No permission denial detected despite 5 denials in the result JSON (4 in result 1,
1 in result 2).

### Impact

- User gets no feedback about ALLOWED_TOOLS gaps
- Same permission denials recur on next run
- Claude wastes API turns retrying denied commands

### Fix: Pre-analysis permission denial check

Add a lightweight permission denial check that runs BEFORE `analyze_response`, directly
on the raw output file. This bypasses the JSONL crash entirely:

```bash
# ralph_loop.sh -- add after line 1521 ("Claude Code execution completed"), before analyze_response

# Quick permission denial scan (runs on raw output, independent of response analysis)
# This catches denials even when analyze_response crashes on JSONL input
if [[ -f "$output_file" ]]; then
    local raw_denial_count
    raw_denial_count=$(grep -c '"permission_denials"' "$output_file" 2>/dev/null || echo "0")
    if [[ $raw_denial_count -gt 0 ]]; then
        # Extract denied commands from the last result object
        local last_result
        last_result=$(grep -E '"type"[[:space:]]*:[[:space:]]*"result"' "$output_file" 2>/dev/null | tail -1)
        if [[ -n "$last_result" ]]; then
            local denial_count
            denial_count=$(echo "$last_result" | jq '.permission_denials | length' 2>/dev/null || echo "0")
            if [[ $denial_count -gt 0 ]]; then
                local denied_cmds
                denied_cmds=$(echo "$last_result" | jq -r '[.permission_denials[] | if .tool_name == "Bash" then "Bash(\(.tool_input.command // "?" | split("\n")[0] | .[0:60]))" else .tool_name end] | join(", ")' 2>/dev/null || echo "unknown")
                log_status "WARN" "Permission denied for $denial_count command(s): $denied_cmds"
                log_status "WARN" "Update ALLOWED_TOOLS in .ralphrc to include the required tools"
            fi
        fi
    fi
fi
```

This is informational only (logs a warning). The actual halt decision still goes through
`should_exit_gracefully` after analysis completes. But if analysis crashes, the user
at least sees the warning in the log.

---

## Issue 4: ALLOWED_TOOLS Pattern Gaps

### Problem

The `.ralphrc` ALLOWED_TOOLS configuration has pattern gaps that caused 5 permission
denials across the session:

| Denied Command | Pattern Needed | Why It Failed |
|----------------|----------------|---------------|
| `find /path -type f -name "*.tsx"` | `Bash(find *)` | `find` IS in ALLOWED_TOOLS, but denied anyway (likely subagent scope issue) |
| `git -C /path add file1 file2...` (x3) | `Bash(git -C *)` | ALLOWED_TOOLS has `Bash(git add *)` but `git -C` is a different command prefix |
| `grep -r "pattern" /path` | `Bash(grep *)` | `grep` not in ALLOWED_TOOLS (subagent ran it via Bash instead of Grep tool) |

### Root cause: `git -C` pattern mismatch

The most impactful gap is `git -C`. Claude Code's permission matcher compares the
beginning of the command string against ALLOWED_TOOLS patterns. The pattern
`Bash(git add *)` matches commands starting with `git add`, but NOT `git -C /path add`.

Claude tried `git -C /path add` three times before working around it with:
```bash
cd /path && git add ...     # denied (cd not in ALLOWED_TOOLS?)
git add ../relative/path    # succeeded (matches Bash(git add *))
```

### Fix: Update ALLOWED_TOOLS in .ralphrc

```bash
# Add these patterns to ALLOWED_TOOLS in .ralphrc:
ALLOWED_TOOLS="...,Bash(git -C *),Bash(grep *),Bash(cd *)"
```

Alternatively, consolidate git patterns:
```bash
# Replace individual git patterns with a broad git pattern:
# Old: Bash(git add *),Bash(git commit *),Bash(git diff *),Bash(git log *),...
# New: Bash(git *)
#
# Note: .ralphrc previously avoided Bash(git *) to prevent destructive commands
# like git clean, git rm, git reset --hard. If broad access is unacceptable,
# add git -C specifically:
ALLOWED_TOOLS="...,Bash(git -C *)"
```

### Workaround applied by Claude

Claude adapted after the denials by avoiding `git -C` and using `git add` with
relative paths from the repo root. This worked but wasted 4 API turns on retries,
adding ~$0.10 in unnecessary API cost and ~30 seconds of wall time.

---

## Issue 5: Infrastructure Failures

### 5a: SessionStart Hook Failure

**Log entry:**
```
hook_name: "SessionStart:startup"
stderr: "/bin/sh: 1: powershell: not found"
exit_code: 127
outcome: "error"
```

The startup hook is configured to run a PowerShell command, but Ralph executes via
`/bin/sh` (WSL/bash). The hook fails silently on every session start.

**Fix:** Either:
- Rewrite the hook in bash: `bash -c "..."`
- Gate on shell availability: `command -v powershell && powershell -Command "..." || echo "skip"`
- Remove the hook if it's not needed for headless operation

### 5b: MCP Server Failures

From the `system:init` event:
```json
"mcp_servers": [
  {"name": "tapps-mcp", "status": "failed"},
  {"name": "docs-mcp", "status": "failed"},
  {"name": "playwright", "status": "connected"},
  {"name": "claude.ai Google Calendar", "status": "failed"},
  {"name": "claude.ai Gmail", "status": "failed"}
]
```

**Impact:**
- `tapps-mcp` failure means the TAPPS quality pipeline is completely unavailable.
  PROMPT.md instructs Claude to call `tapps_session_start(quick=true)` on every loop
  and `tapps_quick_check()` after editing Python files. These calls would fail or
  be skipped.
- `docs-mcp` failure means `tapps_lookup_docs()` is unavailable, increasing risk of
  hallucinated library APIs.

**Fix:** These are Docker-based MCP servers. Ensure Docker containers are running
before starting Ralph:
```bash
# Add to Ralph startup sequence or pre-flight check
docker compose -f path/to/mcp-docker-compose.yml up -d
```

Or add a `.ralphrc` option to skip MCP-dependent PROMPT.md steps when servers are down.

---

## Issue 6: Circuit Breaker State Leak

### Problem

The circuit breaker state file (`.ralph/.circuit_breaker_state`) retains state from
the March 20 session:

```json
{
  "consecutive_permission_denials": 1,
  "last_progress_loop": 5,
  "current_loop": 5
}
```

When Ralph started the March 21 session, it reset exit signals but NOT the circuit
breaker state. The `consecutive_permission_denials: 1` from March 20 is stale.

If the March 21 analysis had succeeded and detected the 5 new permission denials,
the circuit breaker would have tripped immediately (threshold is 1, since
`should_exit_gracefully` returns `permission_denied` on ANY `has_permission_denials:
true` — it's not cumulative).

### Impact

Low for this specific incident (analysis crashed before reaching the check). But the
stale `current_loop: 5` could confuse circuit breaker thresholds in future sessions.

### Fix

Reset circuit breaker counters during `startup` phase, not just exit signals:

```bash
# ralph_loop.sh startup section (near line 951)
# Reset circuit breaker per-session counters
if [[ -f "$CIRCUIT_BREAKER_FILE" ]]; then
    jq '.consecutive_no_progress = 0 | .consecutive_same_error = 0 |
        .consecutive_permission_denials = 0 | .current_loop = 0' \
        "$CIRCUIT_BREAKER_FILE" > "${CIRCUIT_BREAKER_FILE}.tmp" && \
        mv "${CIRCUIT_BREAKER_FILE}.tmp" "$CIRCUIT_BREAKER_FILE"
fi
```

---

## Summary of All Fixes

| # | Issue | Fix Location | Priority | Effort |
|---|-------|-------------|----------|--------|
| 1 | Multi-task loop violation | `PROMPT.md` — explicit stop instruction | **Critical** | Trivial |
| 2 | Dual result objects | `response_analyzer.sh` — count + warn | Medium | Trivial |
| 3 | Permission denial masking | `ralph_loop.sh` — pre-analysis scan | **High** | Small |
| 4a | `git -C` not in ALLOWED_TOOLS | `.ralphrc` — add pattern | **High** | Trivial |
| 4b | `grep` not in ALLOWED_TOOLS | `.ralphrc` — add pattern | Medium | Trivial |
| 5a | Startup hook runs PowerShell in bash | Hook config — rewrite or gate | Medium | Trivial |
| 5b | MCP servers not started | Startup check or docker-compose | Medium | Small |
| 6 | Circuit breaker state leak | `ralph_loop.sh` — reset on startup | Low | Trivial |

**Dependency:** Issues 2 and 3 are moot if `ralph-jsonl-crash-bug.md` Fix 1 (JSONL
detection in parser) is implemented. They provide defense-in-depth only.

**Highest leverage fix:** Issue 1 (PROMPT.md stop instruction). This prevents the
multi-task violation entirely, which eliminates the dual-result amplification and
reduces the window for permission denial accumulation.

---

## Appendix A: Full Log Trace

### ralph.log (March 21 session — complete)

```
[07:58:59] [INFO] Loaded configuration from .ralphrc
[07:59:00] [INFO] Claude CLI version 2.1.80 (>= 2.0.76) - modern features enabled
[07:59:00] [INFO] Claude CLI update available: 2.1.80 -> 2.1.81. Attempting auto-update...
[07:59:01] [SUCCESS] Claude CLI updated: 2.1.80 -> 2.1.80
[07:59:01] [SUCCESS] Ralph loop starting with Claude Code
[07:59:01] [INFO] Max calls per hour: 100
[07:59:02] [INFO] Reset exit signals for fresh start
[07:59:02] [INFO] Starting main loop...
[07:59:02] [INFO] Loop #1 - calling init_call_tracking...
[07:59:02] [INFO] Call counter reset for new hour: 2026032107
[07:59:02] [LOOP] === Starting Loop #1 ===
[07:59:02] [LOOP] Executing Claude Code (Call 1/100)
[07:59:02] [INFO] Starting Claude Code execution... (timeout: 20m)
[07:59:03] [INFO] Using modern CLI mode (json output)
[07:59:03] [INFO] Live output mode enabled - showing Claude Code streaming...
[08:08:44] [SUCCESS] Claude Code execution completed successfully
[08:08:44] [INFO] Analyzing Claude Code response...
<EOF -- no further entries>
```

### State files after crash

| File | Content | Interpretation |
|------|---------|----------------|
| `progress.json` | `{"status": "completed", "timestamp": "2026-03-21 08:08:44"}` | Claude execution completed (not project completion) |
| `.exit_signals` | `{"test_only_loops": [], "done_signals": [], "completion_indicators": []}` | Clean — never updated |
| `.response_analysis` | **Does not exist** | Analysis crashed before writing |
| `.json_parse_result` | **Does not exist** | Parse crashed or was cleaned up |
| `.circuit_breaker_state` | `{"state": "CLOSED", "consecutive_permission_denials": 1}` | Stale from March 20 |
| `.call_count` | `1` | Only 1 Claude invocation |
| `.loop_start_sha` | `13a4505` | Correct pre-loop HEAD |

### Output file statistics

```
File:    claude_output_2026-03-21_07-59-02.log
Size:    1,960,029 bytes (1.87 MB)
Lines:   5,249 (raw NDJSON, never reduced)
Results: 2 (type: "result" objects at lines 3316 and 5249)
Turns:   22 API turns total (36 for F-0.3b + 22 for B-0.7, with session init between)
Denials: 5 total (4 in result 1, 1 in result 2)
Model:   claude-opus-4-6[1m] (primary) + claude-haiku-4-5-20251001 (subagents)
```

---

## Appendix B: Comparison with Working Session

| Attribute | March 20 16:23 (working) | March 21 07:59 (broken) |
|-----------|-------------------------|------------------------|
| Tasks per loop | 1 | 2 (violation) |
| Result objects | 1 per loop | 2 in one invocation |
| `_stream.log` created | Yes | No |
| `.response_analysis` written | Yes | No |
| "Completed Loop" logged | Yes | No |
| Permission denials detected | Yes (loop 6) | No (masked by crash) |
| SESSION_CONTINUITY | true | false |
| Loops completed | 5 (halted on 6th) | 0 (crashed on 1st) |

---

## References

- JSONL crash root cause: `docs/specs/ralph-jsonl-crash-bug.md`
- Ralph source: `~/.ralph/ralph_loop.sh` (2174 lines, modified 2026-03-20 16:26)
- Response analyzer: `~/.ralph/lib/response_analyzer.sh` (932 lines)
- Timeout utils: `~/.ralph/lib/timeout_utils.sh` (146 lines)
- Prompt contract: `.ralph/PROMPT.md` (128 lines)
- Project config: `.ralphrc` (67 lines)
- Claude output log: `.ralph/logs/claude_output_2026-03-21_07-59-02.log` (5249 lines)
- Ralph log: `.ralph/logs/ralph.log` (239 lines)
