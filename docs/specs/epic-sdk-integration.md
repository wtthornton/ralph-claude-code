# Epic: Agent SDK Integration (Phase 6)

**Epic ID:** RALPH-SDK
**Priority:** High
**Affects:** Core architecture, TheStudio interoperability, standalone/embedded execution modes
**Components:** `ralph_loop.sh`, `lib/`, `.claude/agents/ralph.md`, new `sdk/` directory
**Related specs:** `IMPLEMENTATION_PLAN.md` (§Phase 2)
**Target Version:** v1.3.0
**Status:** Superseded by v2.0.0
**Depends on:** None (foundational)

---

## Problem Statement

Ralph currently operates exclusively as a bash CLI wrapper around Claude Code. While this architecture is proven and reliable (v1.2.0, 736+ tests), it limits Ralph's ability to:

1. **Run as an embedded agent** inside TheStudio's 9-step pipeline as the Primary Agent
2. **Expose custom tools** (rate limiting, status reporting, circuit breaking) as SDK-native capabilities
3. **Receive structured inputs** like TheStudio's TaskPackets instead of only reading fix_plan.md

The Agent SDK migration must support **dual-mode operation**: Ralph continues to work as a standalone CLI tool for individual developers, while also being embeddable into TheStudio for teams that want the full platform experience (intake, intent, expert routing, verification gates, QA, publishing).

## TheStudio Relationship

This epic is the **bridge** between Ralph standalone and TheStudio premium. The hybrid architecture (SDK-3) is the key story — it defines the interface contract that allows Ralph to:
- Run standalone: reads fix_plan.md, manages its own loop, writes status.json
- Run embedded: receives TaskPackets from TheStudio, emits signals to Outcome Ingestor, returns results to Verification Gate

TheStudio already uses Claude Agent SDK natively. Ralph adopting SDK makes integration natural rather than requiring adapter layers.

## Stories

| Story | Title | Priority | Effort | Status |
|-------|-------|----------|--------|--------|
| [SDK-1](story-sdk-1-proof-of-concept.md) | Agent SDK Proof of Concept | High | Medium | **Superseded** |
| [SDK-2](story-sdk-2-custom-tools.md) | Define Custom Tools for Agent SDK | High | Medium | **Superseded** |
| [SDK-3](story-sdk-3-hybrid-architecture.md) | Implement Hybrid CLI/SDK Architecture | Critical | Large | **Superseded** |
| [SDK-4](story-sdk-4-migration-strategy.md) | Document SDK Migration Strategy | Medium | Small | **Superseded** |

## Implementation Order

1. **SDK-1 (High)** — PoC first to validate feasibility and identify friction points
2. **SDK-2 (High)** — Define tools while PoC learnings are fresh; can partially overlap with SDK-1
3. **SDK-3 (Critical)** — Core architecture work; depends on SDK-1 and SDK-2 findings
4. **SDK-4 (Medium)** — Document after architecture is proven; captures decisions from SDK-1 through SDK-3

## Verification Criteria

- [ ] Ralph runs successfully in standalone CLI mode (existing behavior preserved)
- [ ] Ralph runs successfully via Agent SDK entry point
- [ ] Custom tools (rate limit, status, circuit breaker) are callable from SDK
- [ ] TheStudio can instantiate Ralph as Primary Agent with a TaskPacket input
- [ ] All 736+ existing tests continue to pass
- [ ] Migration strategy document covers standalone, embedded, and hybrid modes

## Rollback

Revert to pure CLI mode by removing SDK entry points. The bash CLI remains the primary interface throughout migration — SDK is additive, not replacing.
