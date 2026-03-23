# Epic: Cross-Session Agent Memory (Phase 14)

**Epic ID:** RALPH-AGENTMEM
**Priority:** Medium
**Affects:** Loop efficiency, task quality, codebase familiarity, repeat error prevention
**Components:** `.claude/agents/ralph.md`, new `.ralph/memory/`, `ralph_loop.sh`
**Related specs:** [epic-observability.md](epic-observability.md) (metrics as memory input)
**Target Version:** v2.2.0
**Depends on:** RALPH-OTEL (trace data feeds memory)

---

## Problem Statement

Ralph starts each session with zero knowledge of prior sessions. Every new loop re-discovers:
- Which files are in which modules
- What coding patterns the project uses
- Which approaches failed in previous sessions
- Which tasks required multiple retries

This wastes tokens on repeated exploration and risks repeating failed approaches. The 2026 research identifies four types of agent memory mirroring human cognition:

1. **Working Memory** — Current context window (Ralph has this via session continuity)
2. **Episodic Memory** — Past events: "last time I touched auth.py, the tests broke because of X"
3. **Semantic Memory** — Facts: "this project uses pytest, has 200 tests, CI runs on GitHub Actions"
4. **Procedural Memory** — Skills: "to add an API endpoint in this project, create route + handler + schema + test"

Ralph currently has only working memory. Adding episodic and semantic memory would reduce wasted exploration tokens and prevent repeating failed approaches.

## TheStudio Relationship

| Memory Type | Ralph Standalone | TheStudio Premium |
|-------------|-----------------|-------------------|
| Working | Context window | Context window + Hive Memory (R08) |
| Episodic | Local .ralph/memory/ | Graph DB + Reputation Engine |
| Semantic | Local project index | Global knowledge base + RAG |
| Procedural | Agent definition | Learned workflows + optimization |

## Stories

| Story | Title | Priority | Effort | Status |
|-------|-------|----------|--------|--------|
| [AGENTMEM-1](story-agentmem-1-episodic-memory.md) | Episodic Memory Store | Medium | Medium | **Done** |
| [AGENTMEM-2](story-agentmem-2-semantic-memory.md) | Codebase Pattern Memory (Semantic) | Medium | Medium | **Done** |
| [AGENTMEM-3](story-agentmem-3-memory-decay.md) | Memory Decay and Relevance Scoring | Medium | Small | **Done** |

## Implementation Order

1. **AGENTMEM-1** (Medium) — Record what worked and what failed per task
2. **AGENTMEM-2** (Medium) — Index project patterns and facts on first run
3. **AGENTMEM-3** (Medium) — Decay old memories, score relevance for context injection

## Acceptance Criteria (Epic-level)

- [x] Past session outcomes persisted to `.ralph/memory/`
- [x] Failed approaches recorded with enough context to avoid repetition
- [x] Project facts indexed and available to the agent without re-exploration
- [x] Memory injected into agent context at session start
- [x] Old/irrelevant memories decay over time
- [x] Memory does not exceed configurable size limit
- [x] Memory is project-scoped (not shared across projects)

## Rollback

Memory is additive. Deleting `.ralph/memory/` reverts to stateless behavior. `RALPH_MEMORY_ENABLED=false` disables memory injection.
