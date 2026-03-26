# Epic: Context Window Management (Phase 14)

**Epic ID:** RALPH-CTXMGMT
**Priority:** High
**Status:** Done
**Affects:** Loop success rate, token efficiency, long-running session stability
**Components:** `ralph_loop.sh`, `.claude/agents/ralph.md`, `.claude/hooks/on-session-start.sh`
**Related specs:** [epic-adaptive-timeout.md](epic-adaptive-timeout.md), [epic-plan-optimization.md](epic-plan-optimization.md)
**Target Version:** v2.1.0
**Depends on:** None

---

## Problem Statement

Context window management is the **single hardest problem** for long-running AI agents in 2026. Ralph's loop sessions can run for hours, and research shows:

- **Success rate decreases after 35 minutes** of continuous agent operation
- **Doubling task duration quadruples failure rate**
- Claude Opus 4.6 supports 1M tokens, but filling the context degrades quality

Ralph currently has no active context management:
1. No monitoring of context utilization during a session
2. No task decomposition signals when tasks are too large
3. No "Continue-As-New" pattern when context grows stale
4. Session continuity (`--resume`) appends indefinitely without pruning

### Evidence

- TheStudio logs show 19 consecutive 30-minute timeouts — likely context exhaustion after extended sessions
- Factory.ai research: "Agents that maintain well-managed context windows outperform those that pack context to capacity"
- SparkCo research: "Enable compression at 50% of context limit, preserve first 3 and last 4 turns"

## Research-Informed Design

### Progressive Context Loading

Load information in layers by stability:
1. **Static identity** (always first): Agent definition, tool config
2. **Semantic memory**: Top 3-5 relevant past observations (from RALPH-AGENTMEM)
3. **Project notes**: PROMPT.md, AGENT.md, current fix_plan section
4. **Conversation history**: Only recent turns, compressed earlier turns

### Task Decomposition Signals

Detect when a task should be split before it begins:
- Task description mentions 5+ files
- Task text is >500 words
- Task has been retried 2+ times
- Similar tasks historically took >35 minutes

### Continue-As-New Pattern

When context grows too large or stale, atomically:
1. Save essential state (current task, progress, key findings)
2. End current session
3. Start new session with saved state injected
4. Resume from where the old session left off

Reference: [Temporal Continue-As-New](https://docs.temporal.io/workflows#continue-as-new), [Zylos Research — Long-Running AI Agents](https://zylos.ai/research/2026-01-16-long-running-ai-agents)

## Stories

| Story | Title | Priority | Effort | Status |
|-------|-------|----------|--------|--------|
| [CTXMGMT-1](story-ctxmgmt-1-progressive-loading.md) | Progressive Context Loading Strategy | High | Medium | **Done** |
| [CTXMGMT-2](story-ctxmgmt-2-task-decomposition.md) | Task Decomposition Signals | High | Small | **Done** |
| [CTXMGMT-3](story-ctxmgmt-3-continue-as-new.md) | Continue-As-New Pattern for Long Sessions | Medium | Medium | **Done** |

## Implementation Order

1. **CTXMGMT-2** (High) — Quick win: detect too-large tasks before they start
2. **CTXMGMT-1** (High) — Restructure what goes into context and in what order
3. **CTXMGMT-3** (Medium) — Session reset pattern when context is exhausted

## Acceptance Criteria (Epic-level)

- [x] Context loading follows progressive strategy (stable → project → variable)
- [x] Tasks flagged as "too large" before execution with decomposition suggestion
- [x] Session reset triggers when context utilization exceeds threshold
- [x] State preserved across session resets (current task, progress, findings)
- [x] All strategies configurable and disableable
- [x] No regression in loop behavior for sessions under 35 minutes

## Rollback

All strategies are opt-in or advisory. Disabling reverts to current "pack everything into context" behavior.
