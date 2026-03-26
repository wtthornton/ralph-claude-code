# Epic: Loop Stability & Analysis Resilience

**Epic ID:** RALPH-LOOP
**Priority:** Critical
**Status:** Done
**Affects:** Autonomous loop continuity, live mode reliability, WSL production stability
**Components:** `ralph_loop.sh`, `lib/response_analyzer.sh`, `lib/circuit_breaker.sh`, `.ralphrc` template
**Related specs:** `epic-jsonl-stream-resilience.md` (Phase 0), `epic-multi-task-cascading-failures.md` (Phase 0)

---

## Problem Statement

Phase 0 epics (RALPH-JSONL, RALPH-MULTI) were implemented and marked Done on 2026-03-21,
but production testing on TheStudio project (2026-03-21) reveals that **the same class of
failures persists**. The ralph.log across 20+ runs shows Ralph has **never reached Loop #2**
— the script silently dies during `analyze_response` after every Claude Code execution,
restarts from `main()`, and repeats. Each restart resets `loop_count` to 1 and clears exit
signals, so Ralph does exactly one task per script invocation instead of the designed N.

### Evidence (from TheStudio `.ralph/logs/ralph.log`)

```
[09:42:52] SUCCESS ✅ Claude Code execution completed successfully
[09:42:52] INFO 🔍 Analyzing Claude Code response...
[LOG ENDS — no "=== Completed Loop #1 ===" ever appears]
```

This pattern repeats for ALL 20+ runs across March 20-21. Every run shows:
1. `main()` re-initializing (load_ralphrc, check_claude_version, "🚀 Ralph loop starting")
2. Loop #1 only — never Loop #2
3. `status.json` frozen at `"executing"/"running"` — `execute_claude_code()` never returns

### Root Causes (3 distinct bugs, all confirmed)

1. **`jq -s` memory crash:** RALPH-JSONL-1 chose `jq -s 'length'` for JSONL detection
   (implementation note: "avoids `wc -l` false positives"). This call loads ALL 1,447
   streaming JSONL objects into memory, crashing the bash process on WSL `/mnt/c/`. The
   crash is silent — no error logged, no status update, no cleanup.

2. **Multi-result permission denial masking:** RALPH-MULTI-2 added pre-analysis scan using
   `grep ... | tail -1` (last result object). But background agents produce ADDITIONAL
   result objects with empty `permission_denials: []`. The FIRST result (with actual
   denials) is ignored. In the March 21 output, the first result had 2 denials but the
   last had 0.

3. **Compound command denial:** RALPH-MULTI-3 added `Bash(find *)`, `Bash(grep *)`,
   `Bash(cd *)` to defaults. But Claude constructs compound commands like
   `cd /path && git add file && git commit -m "..."` and `find ... | xargs ls -la`.
   Claude Code's permission matcher evaluates these as whole strings or by sub-command,
   causing denials even when individual patterns match.

### Why Phase 0 didn't fix it

| Phase 0 Story | What it did | What's still broken |
|---------------|-------------|---------------------|
| JSONL-1 | Added JSONL detection via `jq -s 'length' > 1` | `jq -s` IS the crash — loads 1447 objects into memory |
| MULTI-2 | Pre-scan with `grep \| tail -1` | Takes LAST result; misses denials in FIRST result |
| MULTI-3 | Added `find`, `grep`, `cd` patterns | Compound `&&`/`\|` commands still denied |

## Stories

| Story | Title | Priority | Effort | Status |
|-------|-------|----------|--------|--------|
| [RALPH-LOOP-1](story-loop-1-streaming-json-count.md) | Replace `jq -s` with streaming JSON counting | Critical | Small | **Done** |
| [RALPH-LOOP-2](story-loop-2-aggregate-permission-denials.md) | Aggregate permission denials across all result objects | High | Small | **Done** |
| [RALPH-LOOP-3](story-loop-3-compound-command-patterns.md) | Handle compound bash command permissions | High | Trivial | **Done** |
| [RALPH-LOOP-4](story-loop-4-post-analysis-error-handling.md) | Add error handling to post-analysis pipeline | Medium | Small | **Done** |
| [RALPH-LOOP-5](story-loop-5-loop-crash-diagnostics.md) | Add loop crash diagnostics and recovery | Medium | Small | **Done** |

## Implementation Order

1. **RALPH-LOOP-1** (Critical) — Eliminates the crash entirely. Can ship alone and unblocks everything.
2. **RALPH-LOOP-3** (High, Trivial) — Config change, zero code risk. Ship with or immediately after #1.
3. **RALPH-LOOP-2** (High) — Ensures denials are visible across multi-result streams.
4. **RALPH-LOOP-4** (Medium) — Defense-in-depth: prevents silent failures in post-analysis functions.
5. **RALPH-LOOP-5** (Medium) — Adds diagnostic logging and recovery for future crashes.

Stories 1+3 together eliminate the crash and permission denial loops.
Stories 2+4+5 are defense-in-depth and observability improvements.

## Acceptance Criteria (Epic-level)

- [ ] Ralph `--live` survives 10+ consecutive loops without silent termination on WSL `/mnt/c/`
- [ ] `ralph.log` shows "=== Completed Loop #N ===" and "=== Starting Loop #N+1 ===" progression
- [ ] Permission denials from ALL result objects (not just the last) are detected and logged
- [ ] Compound commands (`cd && git`, `find | xargs`) execute without permission denial
- [ ] `status.json` correctly transitions from "executing" → "completed" → "executing" across loops
- [ ] No `jq -s` (slurp mode) calls remain in the JSONL processing paths

## Relationship to Phase 0

This epic is a **regression fix** for Phase 0. The Phase 0 epics correctly identified the
problems but their implementations had gaps:
- JSONL-1's `jq -s` detection method IS the crash source
- MULTI-2's `tail -1` extraction misses denials when background agents produce additional results
- MULTI-3's individual patterns don't cover compound commands

This epic should be inserted as **Phase 0.5** in the execution plan — it must be completed
before Phase 1 (RALPH-HOOKS) because hooks depend on a stable loop.

## Out of Scope

- Moving Ralph's working directory off NTFS to native ext4 (operational change)
- Claude Code CLI permission matching improvements (upstream)
- Hooks infrastructure (Phase 1 — RALPH-HOOKS)
- Response analyzer removal (Phase 3 — SKILLS-3)
