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

**Prompt caching**: Claude's prompt caching uses `cache_control` breakpoints in the messages array. Content before the breakpoint is cached for 5 minutes (default) or 1 hour (2× write cost). Cache reads cost 0.1× the base input token price — a 90% discount. Cache writes cost 1.25× (5-min) or 2.0× (1-hr) the base input price but pay for themselves after just 1-2 cache reads. For multi-loop agents, the system prompt and tool definitions are ideal cache candidates — they're identical across iterations. Cached tokens also don't count against input tokens per minute (ITPM) rate limits, effectively increasing throughput.

**Context windows**: Both Claude Opus 4.6 and Sonnet 4.6 support 1M-token context windows natively with no long-context surcharge (GA March 13, 2026). Opus 4.6 supports up to 128K output tokens per response. Even with large windows, loading 50+ completed tasks wastes budget and degrades response quality due to attention dilution.

**Continue-As-New**: The Temporal pattern of atomically ending a workflow execution and starting a fresh one with carried-over state is directly applicable. When a Ralph session exceeds N iterations, context fills with stale tool outputs and failed attempts. Resetting the session while carrying only essential state (current task, progress summary, key findings) restores agent effectiveness. Research shows agent success rate decreases after ~35 minutes and doubles failure rate with doubled duration.

**Token counting**: Anthropic provides a free `POST /v1/messages/count_tokens` API endpoint (and `client.messages.count_tokens()` SDK method) for precise token counting including tools, images, and documents. The 4-char heuristic (~250 tokens per 1K chars) is sufficient for quick budget estimates during prompt building; the API endpoint should be used when accuracy matters.

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

- [x] SDK trims fix plans to current section + N unchecked items
- [x] Elided sections show summary markers (e.g., `(15 completed items above)`)
- [x] Token estimation available for budget-aware prompt building
- [x] Prompt is split into stable prefix and dynamic suffix for cache optimization
- [x] Sessions expire after configurable TTL (default 24 hours)
- [x] Session rotation occurs automatically on expiry
- [x] Continue-As-New resets context after N iterations, carrying essential state
- [x] Session history (previous session IDs with timestamps) is tracked
- [x] All settings configurable via `RalphConfig`
- [x] pytest tests verify progressive loading, cache split, and session rotation

## Out of Scope

- Direct Anthropic `count_tokens` API integration (the SDK uses the 4-char heuristic for budget estimates; embedders can call the API for precise counts)
- Prompt template design (TheStudio controls prompt content; SDK controls structure)
- Streaming-based context trimming (would require real-time token counting)
- Extended thinking token management (thinking blocks are automatically excluded from subsequent turns by the API)
