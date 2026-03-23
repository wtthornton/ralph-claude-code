# Epic: SDK Loop Safety — Stall Detection, Decomposition, and Exit Decay

**Epic ID:** RALPH-SDK-SAFETY
**Priority:** P0–P1 (mixed; stall detection is P0)
**Affects:** SDK loop reliability, budget waste prevention, production quality
**Components:** `ralph_sdk/circuit_breaker.py`, `ralph_sdk/agent.py`, `ralph_sdk/status.py`
**Related specs:** [epic-loop-guard-rails.md](epic-loop-guard-rails.md), [epic-multi-task-cascading-failures.md](epic-multi-task-cascading-failures.md)
**Depends on:** None (enhances existing SDK modules)
**Target Version:** SDK v2.1.0
**Source:** [ralph-sdk-upgrade-evaluation.md](../../../TheStudio/docs/ralph-sdk-upgrade-evaluation.md) §1.1, §1.3, §1.6

---

## Problem Statement

The bash CLI (v2.2.0) detects three categories of stuck loops that the Python SDK (v2.0.2) does not:

1. **Fast-trip detection**: Broken invocations that produce 0 tool uses and complete in <30 seconds trip the circuit breaker after 3 consecutive occurrences. The SDK retries indefinitely on broken tool access.

2. **Deferred-test stall**: TheStudio's epic-boundary QA strategy marks `TESTS_STATUS: DEFERRED` for mid-epic loops. If Ralph loops without progress while deferring tests, it burns budget silently. The CLI trips the CB after 5 consecutive deferred-test loops. The SDK has no awareness of `TESTS_STATUS: DEFERRED`. This caused production issue LOGFIX-6.

3. **Completion indicator decay**: The CLI resets `completion_indicators` to `[]` when productive work occurs (files modified or tasks completed) with `exit_signal=false`. The SDK's dual-condition exit gate doesn't decay stale indicators, so a false "done" signal early in a multi-loop run can combine with a later legitimate "done" to trigger premature exit.

Additionally, the CLI detects oversized tasks via a 4-factor heuristic (file count >= 5, previous timeout, complexity >= 4, consecutive no-progress >= 3). The SDK has no equivalent, meaning tasks that should be decomposed run until timeout instead.

### Evidence

- LOGFIX-6: Deferred-test stall burned budget in TheStudio production
- CLI `ralph_loop.sh:951-953`: Completion indicator reset on progress
- CLI `lib/circuit_breaker.sh`: `MAX_CONSECUTIVE_FAST_FAILURES=3`, `CB_MAX_DEFERRED_TESTS=5`, `MAX_CONSECUTIVE_TIMEOUTS=5`

## Research Context (March 2026)

Circuit breaker patterns for AI agent loops have matured significantly:

- **LangGraph** (v0.4+): Implements configurable recursion limits and conditional breakpoints, but no stall-specific detection.
- **CrewAI**: Added budget-aware loop guards in 2025 that halt agents exceeding spend thresholds.
- **AutoGen** (Microsoft): Implements conversation-level termination conditions but lacks per-iteration stall heuristics.
- **AWS Step Functions**: TimeoutSecondsPath enables dynamic per-step timeouts based on task metadata.

Ralph's multi-signal stall detection (fast-trip + deferred-test + no-progress) is more granular than any open-source framework as of March 2026. The SDK should match the CLI's capability.

## Stories

| Story | Title | Priority | Effort | Status |
|-------|-------|----------|--------|--------|
| [SDK-SAFETY-1](story-sdk-safety-1-stall-detection.md) | Stall Detection (fast-trip, deferred-test, consecutive timeout) | P0 | 1–2 days | Pending |
| [SDK-SAFETY-2](story-sdk-safety-2-task-decomposition.md) | Task Decomposition Detection | P1 | 1 day | Pending |
| [SDK-SAFETY-3](story-sdk-safety-3-completion-decay.md) | Completion Indicator Decay | P1 | 0.5 day | Pending |

## Implementation Order

1. **SDK-SAFETY-1** (P0) — Adds `FastTripDetector` and `StallDetector` to `circuit_breaker.py`. Must land first as it's the foundation.
2. **SDK-SAFETY-3** (P1) — Adds decay logic to `agent.py`. Small change, high impact for multi-loop correctness.
3. **SDK-SAFETY-2** (P1) — Adds `detect_decomposition_needed()`. Can land independently.

## Acceptance Criteria (Epic-level)

- [ ] SDK detects fast-trip failures (0-tool runs <30s) and trips CB after configurable threshold
- [ ] SDK detects deferred-test stalls and trips CB after configurable threshold
- [ ] SDK detects consecutive timeouts and trips CB after configurable threshold
- [ ] Completion indicators decay when productive work is detected
- [ ] SDK provides decomposition hints when tasks exceed complexity thresholds
- [ ] All thresholds are configurable via `RalphConfig`
- [ ] Existing circuit breaker behavior (sliding window, cooldown, auto-recovery) is not regressed
- [ ] pytest tests verify all stall detection paths

## Out of Scope

- Automatic task decomposition (detection only; the caller decides how to split)
- Changes to the bash CLI (these are SDK-only enhancements)
- Heartbeat-based stall detection (requires streaming, covered in SDK-OUTPUT epic)
