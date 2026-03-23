# Epic: SDK Context Management — Progressive Loading, Prompt Cache, and Session Lifecycle

**Epic ID:** RALPH-SDK-CONTEXT
**Priority:** P0–P2 (mixed; progressive context loading is P0)
**Affects:** Token efficiency, context window utilization, session durability, cost reduction
**Components:** `ralph_sdk/agent.py`, `ralph_sdk/config.py`, `ralph_sdk/state.py`
**Related specs:** [epic-context-management.md](epic-context-management.md), [epic-adaptive-timeout.md](epic-adaptive-timeout.md)
**Depends on:** None (new SDK modules)
**Target Version:** SDK v2.1.0
**Source:** [ralph-sdk-upgrade-evaluation.md](../../../TheStudio/docs/ralph-sdk-upgrade-evaluation.md) §1.2, §1.8, §1.10

---

## Problem Statement

Three context-related gaps between the CLI and SDK cause token waste and session fragility:

1. **Progressive context loading**: The CLI's `lib/context_management.sh` trims `fix_plan.md` to only the current epic section + next N unchecked items. The SDK loads the entire plan every iteration. TheStudio fix plans can span multiple epics with 50+ tasks — loading all of them wastes context window tokens and confuses the agent with irrelevant completed work.

2. **Prompt cache optimization**: The CLI's `ralph_build_cacheable_prompt()` separates prompts into a stable prefix (identity, build instructions, tool permissions) and a dynamic suffix (loop count, progress, current task). This maximizes Claude's prompt cache hits, which can reduce input token costs by up to 90% for repeated prefixes. The SDK rebuilds the full prompt each iteration with no cache awareness.

3. **Session lifecycle management**: The CLI tracks session history, enforces expiry (`CLAUDE_SESSION_EXPIRY_HOURS=24`), and is implementing Continue-As-New for long sessions (CTXMGMT-3). The SDK persists session IDs but never expires or rotates them. TheStudio's `clear_session_if_stale(ttl_seconds=7200)` in `ralph_state.py` is a workaround for this SDK gap.

### Evidence

- TheStudio fix plans: 50+ tasks across multiple epics
- CTXMGMT-3 (Continue-As-New): Open, "single most impactful unfinished story" per evaluation
- Claude prompt caching: up to 90% input token cost reduction for stable prefixes
- TheStudio workaround: `clear_session_if_stale()` implements TTL that should be in the SDK

## Research Context (March 2026)

**Prompt caching**: Claude's prompt caching uses `cache_control` breakpoints in the messages array. Content before the breakpoint is cached for 5 minutes (extended to 1 hour with certain plans). For multi-loop agents, the system prompt and tool definitions are ideal cache candidates — they're identical across iterations. The SDK should structure prompts to maximize cache reuse.

**Context windows**: Claude Opus 4.6 supports 200K tokens (1M with extended thinking). Claude Sonnet 4.6 supports 200K tokens. Even with large windows, loading 50+ completed tasks wastes budget and degrades response quality due to attention dilution.

**Continue-As-New**: The Temporal pattern of atomically ending a workflow execution and starting a fresh one with carried-over state is directly applicable. When a Ralph session exceeds N iterations, context fills with stale tool outputs and failed attempts. Resetting the session while carrying only essential state (current task, progress summary, key findings) restores agent effectiveness. Research shows agent success rate decreases after ~35 minutes and doubles failure rate with doubled duration.

**Token counting**: Anthropic's tokenizer uses ~4 characters per token as a rough heuristic. The `anthropic` Python SDK includes a `count_tokens()` method for precise counting, but the 4-char heuristic is sufficient for budget awareness during prompt building.

## Stories

| Story | Title | Priority | Effort | Status |
|-------|-------|----------|--------|--------|
| [SDK-CONTEXT-1](story-sdk-context-1-progressive-loading.md) | Progressive Context Loading | P0 | 1–2 days | Pending |
| [SDK-CONTEXT-2](story-sdk-context-2-prompt-cache.md) | Prompt Cache Optimization | P2 | 1 day | Pending |
| [SDK-CONTEXT-3](story-sdk-context-3-session-lifecycle.md) | Session Lifecycle Management and Continue-As-New | P2 | 2 days | Pending |

## Implementation Order

1. **SDK-CONTEXT-1** (P0) — `ContextManager` class. Immediate token savings for TheStudio.
2. **SDK-CONTEXT-2** (P2) — `PromptParts` split. Builds on context manager output.
3. **SDK-CONTEXT-3** (P2) — Session rotation and Continue-As-New. Depends on state backend.

## Acceptance Criteria (Epic-level)

- [ ] SDK trims fix plans to current section + N unchecked items
- [ ] Elided sections show summary markers (e.g., `(15 completed items above)`)
- [ ] Token estimation available for budget-aware prompt building
- [ ] Prompt is split into stable prefix and dynamic suffix for cache optimization
- [ ] Sessions expire after configurable TTL (default 24 hours)
- [ ] Session rotation occurs automatically on expiry
- [ ] Continue-As-New resets context after N iterations, carrying essential state
- [ ] Session history (previous session IDs with timestamps) is tracked
- [ ] All settings configurable via `RalphConfig`
- [ ] pytest tests verify progressive loading, cache split, and session rotation

## Out of Scope

- Anthropic tokenizer integration (4-char heuristic is sufficient)
- Prompt template design (TheStudio controls prompt content; SDK controls structure)
- Streaming-based context trimming (would require real-time token counting)
