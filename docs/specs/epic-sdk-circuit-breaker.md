# Epic: Active Circuit Breaker (HIGH-3)

**Epic ID:** RALPH-SDK-CB
**Priority:** High
**Phase:** 2 — Async + Core (v1.5.0)
**Affects:** Loop stability, failure recovery, no-progress detection
**Components:** New `sdk/ralph_sdk/circuit_breaker.py`, `sdk/ralph_sdk/agent.py`
**Reference:** `lib/circuit_breaker.sh` (bash implementation)
**Related specs:** [RFC-001 §4 HIGH-3](../../TheStudio/docs/architecture/RFC-001-ralph-sdk-integration.md), `epic-sdk-state-backend.md`
**Depends on:** Epic 2 (State Backend Protocol)
**Target Version:** v1.5.0

---

## Problem Statement

The SDK's `CircuitBreakerState` (status.py:91-172) is a **passive data model**. It has
`trip()`, `half_open()`, `close()`, and `reset()` methods, but **the agent loop never
calls them**. The `check_circuit_breaker()` method reads state and returns a bool but
doesn't trigger transitions.

Meanwhile, the bash implementation (`lib/circuit_breaker.sh`) has full active management:
- Sliding window failure detection (only recent failures count)
- Automatic CLOSED → OPEN on threshold breach
- Cooldown-based OPEN → HALF_OPEN transition
- Success-based HALF_OPEN → CLOSED transition
- No-progress detection (consecutive zero-work loops)

### Why This Benefits Standalone Ralph

Active circuit breaking is valuable for all Ralph users:
- Prevents infinite loops when Claude repeatedly fails
- Automatically recovers after transient API issues
- Detects stuck loops (no files changed, no tasks completed)
- Matches the proven bash behavior that has been stable across 736+ tests

The SDK currently relies on the bash loop for circuit breaker management. When running
`ralph --sdk`, circuit breaker transitions never happen — the SDK just reads stale state.

## Stories

| Story | Title | Priority | Effort | Status |
|-------|-------|----------|--------|--------|
| [RALPH-SDK-CB-1](story-sdk-cb-1-class.md) | Implement CircuitBreaker class with state machine | Critical | Medium | Pending |
| [RALPH-SDK-CB-2](story-sdk-cb-2-success.md) | Implement record_success() — HALF_OPEN → CLOSED | High | Small | Pending |
| [RALPH-SDK-CB-3](story-sdk-cb-3-failure.md) | Implement record_failure() with sliding window | Critical | Medium | Pending |
| [RALPH-SDK-CB-4](story-sdk-cb-4-no-progress.md) | Implement record_no_progress() detection | High | Small | Pending |
| [RALPH-SDK-CB-5](story-sdk-cb-5-can-proceed.md) | Implement can_proceed() with cooldown check | Critical | Small | Pending |
| [RALPH-SDK-CB-6](story-sdk-cb-6-wire-agent.md) | Wire CircuitBreaker into RalphAgent loop | High | Small | Pending |
| [RALPH-SDK-CB-7](story-sdk-cb-7-bash-parity.md) | Verify behavior matches lib/circuit_breaker.sh | High | Small | Pending |

## Implementation Order

1. **CB-1** — Core class with state machine and constructor.
2. **CB-3** — `record_failure()` with sliding window (most complex piece).
3. **CB-5** — `can_proceed()` with cooldown check.
4. **CB-2** — `record_success()` (simpler transition).
5. **CB-4** — `record_no_progress()` (simpler detection).
6. **CB-6** — Wire into agent loop.
7. **CB-7** — Bash parity verification.

## Design Decisions

### State Machine

```
CLOSED --[failures >= threshold in window]--> OPEN
OPEN   --[cooldown elapsed]-------------------> HALF_OPEN
HALF_OPEN --[success]-------------------------> CLOSED
HALF_OPEN --[failure]-------------------------> OPEN
```

### Sliding Window

Failures are timestamped. Only failures within `window_minutes` count toward the
threshold. Old failures expire naturally. This prevents a single bad hour from
permanently tripping the breaker.

### Persists via State Backend

All state changes flow through `RalphStateBackend`:
- `save_circuit_breaker(state)` after every transition
- `record_circuit_event(event)` for audit trail
- `load_circuit_breaker()` on `can_proceed()` check

This means `FileStateBackend` writes to `.circuit_breaker_state` (compatible with bash),
`NullStateBackend` keeps state in memory, and TheStudio's backend writes to PostgreSQL.

### Config from RalphConfig

Circuit breaker thresholds come from `RalphConfig`:
- `cb_no_progress_threshold` (default: 3)
- `cb_same_error_threshold` (default: 5) — mapped to `failure_threshold`
- `cb_cooldown_minutes` (default: 30)
- `cb_auto_reset` (default: false)

No new configuration needed.

## Acceptance Criteria (Epic-level)

- [ ] State transitions happen automatically based on `record_success/failure/no_progress`
- [ ] `can_proceed()` handles cooldown check (OPEN → HALF_OPEN after cooldown)
- [ ] Sliding window: only failures within `window_minutes` count toward threshold
- [ ] No-progress detection: `no_progress_threshold` consecutive zero-work loops trip the breaker
- [ ] All state changes persisted via `RalphStateBackend`
- [ ] Agent loop uses `CircuitBreaker` instead of passive state check
- [ ] Behavior matches `lib/circuit_breaker.sh` for common scenarios
- [ ] `ralph --sdk` works with active circuit breaker
- [ ] Backward compatible: `.circuit_breaker_state` file format unchanged

## Out of Scope

- Circuit breaker dashboard/UI (TheStudio responsibility)
- Multi-instance circuit breaker coordination (TheStudio responsibility)
- Changes to bash circuit breaker (`lib/circuit_breaker.sh` unchanged)
