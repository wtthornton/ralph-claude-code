# Ralph Claude Code — Epic & Story Index

> **Generated:** 2026-03-21 | **Total Epics:** 7 | **Total Stories:** 37 (37 Done, 0 Open)

---

## Execution Plan Overview

```
Phase 0 (DONE)     Phase 0.5 (DONE)    Phase 1 (DONE)       Phase 2 (DONE)       Phase 3 (DONE)       Phase 4 (DONE)
┌──────────────┐   ┌──────────────┐   ┌──────────────┐    ┌──────────────┐    ┌──────────────┐    ┌──────────────┐
│ RALPH-JSONL  │──▶│ RALPH-LOOP   │──▶│ RALPH-HOOKS  │───▶│RALPH-SUBAGENTS│──▶│ RALPH-SKILLS │──▶│ RALPH-TEAMS  │
│ 4/4 Done     │   │ 5/5 Done     │   │ 6/6 Done     │    │ 5/5 Done      │   │ 5/5 Done     │   │ 5/5 Done     │
│              │   │              │   │              │    │               │   │              │   │              │
│ RALPH-MULTI  │   │ Critical     │   │ Critical     │    │ Important     │   │ Important    │   │ Nice-to-have │
│ 6/6 Done     │   │ P0 Regrssion │   │ Foundation   │    │ Sub-agents    │   │ -1,368 lines │   │ Experimental │
└──────────────┘   └──────────────┘   └──────────────┘    └──────────────┘    └──────────────┘    └──────────────┘
```

---

## Phase 0 — Complete (Foundation Fixes)

### RALPH-JSONL: JSONL Stream Processing Resilience
**Priority:** Critical | **Status:** Done | **Stories:** 4/4 Done

| ID | Story | Priority | Status | Effort |
|----|-------|----------|--------|--------|
| JSONL-1 | Add JSONL Detection to parse_json_response | Critical | **Done** | Small |
| JSONL-2 | Fix parse_json_response Return Code | Important | **Done** | Trivial |
| JSONL-3 | Add WSL2/NTFS Filesystem Resilience | Defensive | **Done** | Small |
| JSONL-4 | Add Fallback JSONL Extraction in ralph_loop | Defensive | **Done** | Small |

### RALPH-MULTI: Multi-Task Loop Violation and Cascading Failures
**Priority:** High | **Status:** Done | **Stories:** 6/6 Done

| ID | Story | Priority | Status | Effort |
|----|-------|----------|--------|--------|
| MULTI-1 | Strengthen PROMPT.md Stop Instruction | Critical | **Done** | Trivial |
| MULTI-2 | Add Pre-Analysis Permission Denial Scan | High | **Done** | Small |
| MULTI-3 | Fix ALLOWED_TOOLS Template Patterns | High | **Done** | Trivial |
| MULTI-4 | Reset Circuit Breaker State on Startup | Low | **Done** | Trivial |
| MULTI-5 | Warn on Multiple Result Objects in Stream | Medium | **Done** | Trivial |
| MULTI-6 | Fix Startup Hook and Add MCP Pre-Flight Check | Medium | **Done** | Small |

---

## Phase 0.5 — Complete (P0 Regression Fixes)

### RALPH-LOOP: Loop Stability & Analysis Resilience
**Priority:** Critical | **Status:** Done | **Target:** v0.12.0 | **Dependencies:** None

| # | ID | Story | Priority | Effort | Status |
|---|-----|-------|----------|--------|--------|
| 1 | LOOP-1 | Replace `jq -s` with Streaming JSON Counting | Critical | Small | **Done** |
| 2 | LOOP-3 | Handle Compound Bash Command Permissions | High | Trivial | **Done** |
| 3 | LOOP-2 | Aggregate Permission Denials Across All Result Objects | High | Small | **Done** |
| 4 | LOOP-4 | Add Error Handling to Post-Analysis Pipeline | Medium | Small | **Done** |
| 5 | LOOP-5 | Add Loop Crash Diagnostics and Recovery | Medium | Small | **Done** |

---

## Phase 1 — Complete (Hooks Foundation)

### RALPH-HOOKS: Hooks + Agent Definition
**Priority:** Critical | **Status:** Done | **Target:** v1.0.0 | **Dependencies:** RALPH-LOOP (Phase 0.5)

| # | ID | Story | Priority | Effort | Status |
|---|-----|-------|----------|--------|--------|
| 1 | HOOKS-1 | Create ralph.md Custom Agent Definition | Critical | Small | **Done** |
| 2 | HOOKS-2 | Create Hooks Configuration in settings.json | Critical | Medium | **Done** |
| 3 | HOOKS-6 | Add --agent ralph to build_claude_command() | Important | Small | **Done** |
| 4 | HOOKS-3 | Implement on-session-start.sh Hook | Important | Small | **Done** |
| 5 | HOOKS-5 | Implement File Protection PreToolUse Hooks | Important | Small | **Done** |
| 6 | HOOKS-4 | Implement on-stop.sh Hook | Critical | Medium | **Done** |

---

## Phase 2 — Complete (Sub-agents)

### RALPH-SUBAGENTS: Sub-agents
**Priority:** Important | **Status:** Done | **Target:** v1.0.0 | **Dependencies:** RALPH-HOOKS (Phase 1)

| # | ID | Story | Priority | Effort | Status |
|---|-----|-------|----------|--------|--------|
| 1 | SUBAGENTS-1 | Create ralph-explorer.md Agent Definition | Important | Small | **Done** |
| 2 | SUBAGENTS-2 | Create ralph-tester.md Agent with Worktree Isolation | Important | Small | **Done** |
| 3 | SUBAGENTS-3 | Create ralph-reviewer.md Agent Definition | Nice-to-have | Small | **Done** |
| 4 | SUBAGENTS-4 | Update ralph.md to Reference and Spawn Sub-agents | Important | Small | **Done** |
| 5 | SUBAGENTS-5 | Add Sub-agent Failure Handling and SubagentStop Hook | Important | Medium | **Done** |

---

## Phase 3 — Complete (Skills & Bash Reduction)

### RALPH-SKILLS: Skills + Bash Reduction
**Priority:** Important | **Status:** Done | **Target:** v1.0.0 | **Dependencies:** RALPH-HOOKS (Phase 1), RALPH-SUBAGENTS (Phase 2)
**Impact:** Removed ~1,368 lines of bash code.

| # | ID | Story | Priority | Effort | Status | Lines Removed |
|---|-----|-------|----------|--------|--------|---------------|
| 1 | SKILLS-1 | Create ralph-loop Skill | Important | Small | **Done** | — |
| 2 | SKILLS-2 | Create ralph-research Skill | Nice-to-have | Small | **Done** | — |
| 3 | SKILLS-4 | Remove file_protection.sh | Important | Trivial | **Done** | -58 |
| 4 | SKILLS-5 | Simplify circuit_breaker.sh | Important | Medium | **Done** | -375 |
| 5 | SKILLS-3 | Remove response_analyzer.sh | Important | Medium | **Done** | -935 |

---

## Phase 4 — Complete (Agent Teams, Experimental)

### RALPH-TEAMS: Agent Teams + Parallelism
**Priority:** Nice-to-have | **Status:** Done | **Target:** v1.1.0 | **Dependencies:** RALPH-HOOKS, RALPH-SUBAGENTS
**Risk:** High — feature is experimental, display issues on non-tmux terminals, potential instability.

| # | ID | Story | Priority | Effort | Status |
|---|-----|-------|----------|--------|--------|
| 1 | TEAMS-1 | Enable Agent Teams Configuration | Important | Small | **Done** |
| 2 | TEAMS-5 | Add Worktree Support and .gitignore Updates | Important | Trivial | **Done** |
| 3 | TEAMS-2 | Implement Team Spawning Strategy in ralph.md | Important | Medium | **Done** |
| 4 | TEAMS-3 | Create ralph-bg-tester.md Background Agent | Nice-to-have | Small | **Done** |
| 5 | TEAMS-4 | Add TeammateIdle and TaskCompleted Hooks | Important | Small | **Done** |

---

## Priority Summary

| Priority | Open | Done | Total |
|----------|------|------|-------|
| Critical | 0 | 11 | 11 |
| High | 0 | 4 | 4 |
| Important | 0 | 15 | 15 |
| Medium | 0 | 4 | 4 |
| Nice-to-have | 0 | 2 | 2 |
| Defensive/Low | 0 | 1 | 1 |
| **Total** | **0** | **37** | **37** |

## Critical Path

All phases complete. v1.0.0 epic/story goals achieved.

```
Phase 0 ──▶ Phase 0.5 ──▶ Phase 1 ──▶ Phase 2 ──▶ Phase 3 ──▶ Phase 4
  DONE         DONE          DONE        DONE        DONE        DONE
```
