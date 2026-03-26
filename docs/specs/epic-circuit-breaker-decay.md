# Epic: Circuit Breaker Failure Decay

**Epic ID:** RALPH-CBDECAY
**Priority:** High
**Status:** Done
**Affects:** Loop continuity, false halt prevention, unattended operation
**Components:** `lib/circuit_breaker.sh`, `ralph_loop.sh` (session reinitialization)
**Related specs:** [epic-multi-task-cascading-failures.md](epic-multi-task-cascading-failures.md), [epic-loop-stability.md](epic-loop-stability.md)
**Depends on:** None
**Target Version:** v1.9.0

---

## Problem Statement

Two related issues cause the circuit breaker to behave incorrectly:

### Issue 1: Stale Failure State Causes False Trips

The circuit breaker accumulates failure counts that persist across session boundaries. Old failures from hours earlier contribute to the threshold, causing the CB to trip during periods that include successful executions. Both TheStudio and tapps-brain experienced false CB trips where the loop was making progress but got halted due to stale failure counts.

### Issue 2: Empty Session State After CB Reset

After a circuit breaker trip resets the session, `.ralph_session` has empty `session_id`, `created_at`, and `last_used` fields. The session was reset but never properly reinitialized, leaving the loop in a state where session continuity is broken.

### Evidence

- **tapps-brain 2026-03-21**: CB tripped at 23:36 after only 3 loops in a new session — accumulated state from an earlier 40-failure burst was not cleared
- **tapps-brain 2026-03-22**: CB tripped at 01:13 after 18 productive loops — stale failure counts contributed
- **Both projects**: `.ralph_session` shows `session_id: ""`, `created_at: ""`, `last_used: ""` after CB trip

## Research-Informed Adjustments

### Sliding Window Circuit Breakers (2025 Best Practices)

Production circuit breakers use **sliding windows** rather than cumulative counters:

**Resilience4j defaults** (industry standard):

| Parameter | Default | Description |
|-----------|---------|-------------|
| `slidingWindowType` | COUNT_BASED | Evaluate last N calls, not all-time |
| `slidingWindowSize` | 100 | Window size |
| `failureRateThreshold` | 50% | Trip when >50% of window is failures |
| `minimumNumberOfCalls` | 100 | Don't evaluate until N calls made |

**Time-based sliding window**: Only count failures within the last N minutes. Older failures decay naturally.

**Weighted decay**: Recent failures count more than old ones. A failure 5 minutes ago has full weight; a failure 60 minutes ago has near-zero weight.

Reference: [Resilience4j CircuitBreaker](https://resilience4j.readme.io/docs/circuitbreaker), [Martin Fowler — CircuitBreaker](https://martinfowler.com/bliki/CircuitBreaker.html), [Microsoft Azure — Circuit Breaker Pattern](https://learn.microsoft.com/en-us/azure/architecture/patterns/circuit-breaker)

### Atomic Session State (2025 Best Practices)

- **Write-to-temp, fsync, rename**: Atomic state writes prevent partial/corrupt state files
- **npm/write-file-atomic**: Production pattern — write to `.tmp.$$`, sync, rename over target
- **Session lifecycle**: Reset → Initialize → Validate must be atomic

Reference: [npm/write-file-atomic](https://github.com/npm/write-file-atomic), [LWN.net — Atomic File Writes](https://lwn.net/Articles/789600/)

## Stories

| Story | Title | Priority | Effort | Status |
|-------|-------|----------|--------|--------|
| [CBDECAY-1](story-cbdecay-1-sliding-window.md) | Time-Weighted Sliding Window | High | Medium | Pending |
| [CBDECAY-2](story-cbdecay-2-session-reinitialization.md) | Session State Reinitialization After CB Reset | Medium | Small | Pending |

## Implementation Order

1. **CBDECAY-1** (High) — Fixes the root cause: stale failures contributing to threshold.
2. **CBDECAY-2** (Medium) — Fixes the symptom: broken session state after CB trip.

## Acceptance Criteria (Epic-level)

- [ ] Failures older than `CB_FAILURE_DECAY_MINUTES` do not contribute to the failure threshold
- [ ] Circuit breaker does not trip during productive periods due to stale state
- [ ] Session state is fully reinitialized after CB reset (no empty fields)
- [ ] `--reset-circuit` clears both failure history and session state
- [ ] All fixes have BATS tests

## Out of Scope

- Consecutive timeout detection (covered in RALPH-GUARD)
- CB state persistence format changes (current JSON format is adequate)
- Distributed circuit breaker (Ralph is single-host)

---

## 2026 Research Addendum

**Added:** 2026-03-22 | **Source:** Phase 14 research review

This epic's sliding window circuit breaker aligns well with 2026 best practices. Two additional patterns have emerged:

1. **Multi-provider failover chains**: Organizations mix Claude, OpenAI, and self-hosted models with circuit breaker chains for automatic failover. Traefik Labs announced composable safety pipelines with multi-provider resilience in March 2026. Ralph is Claude-only; multi-provider support is a future consideration.

2. **FAILURE.md protocol**: The FAILURE.md open specification provides a standard format for documenting circuit breaker behavior, failure modes, and recovery procedures. Ralph's CB behavior should be documented in this format.

**Related Phase 14 epic:** [RALPH-FAILSPEC](epic-failure-protocol.md) documents circuit breaker behavior in FAILURE.md standard format.
