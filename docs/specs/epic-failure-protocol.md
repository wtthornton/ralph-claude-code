# Epic: Failure Protocol Compliance (Phase 14)

**Epic ID:** RALPH-FAILSPEC
**Priority:** Critical
**Status:** Done
**Affects:** Reliability, compliance, audit readiness, emergency controls
**Components:** `ralph_loop.sh`, `lib/circuit_breaker.sh`, new `FAILURE.md`, new `FAILSAFE.md`, new `KILLSWITCH.md`
**Related specs:** [epic-loop-guard-rails.md](epic-loop-guard-rails.md), [epic-circuit-breaker-decay.md](epic-circuit-breaker-decay.md), [epic-brain-security-design.md](epic-brain-security-design.md)
**Target Version:** v2.0.0
**Depends on:** None

---

## Problem Statement

Ralph has robust circuit breaker, guard rail, and hook-based safety mechanisms (Phases 0-13). However, these are **ad-hoc implementations** without a standardized failure protocol. Three 2026 developments make standardization critical:

### 1. FAILURE.md / FAILSAFE.md / KILLSWITCH.md Open Standards

A twelve-file AI agent safety stack has emerged as an open specification:
- **FAILURE.md**: Defines failure modes, detection signals, response procedures, escalation targets
- **FAILSAFE.md**: Defines safe fallback behaviors when primary systems fail
- **KILLSWITCH.md**: Defines emergency stop triggers and procedures

Ralph's existing circuit breaker and guard rails implement many of these concepts but aren't documented in the standard format. Adopting the standard makes Ralph's safety mechanisms discoverable, auditable, and composable with other tools.

### 2. EU AI Act Enforcement (August 2, 2026)

The EU AI Act enters major enforcement phases through 2026, with broad enforcement starting **August 2, 2026**. Requirements include:
- Documented error handling and predictable behavior under adverse conditions
- Retained inventories, access policies, approvals, change logs, incident reports, and postmortems
- Compliance frameworks: ISO 42001, NIST AI RMF

Ralph's autonomous operation (making decisions without human oversight for hours) falls under scrutiny. Structured failure documentation and audit logging demonstrate compliance.

### 3. Standardized Failure Mode Documentation

Production AI agents need machine-readable failure mode definitions. Ralph's circuit breaker can trip, but the failure modes, detection heuristics, and recovery procedures are scattered across bash code comments and epic specs — not in a standard, discoverable location.

## Stories

| Story | Title | Priority | Effort | Status |
|-------|-------|----------|--------|--------|
| [FAILSPEC-1](story-failspec-1-failure-md.md) | Implement FAILURE.md Specification | Critical | Medium | **Done** |
| [FAILSPEC-2](story-failspec-2-failsafe-md.md) | Implement FAILSAFE.md Safe Fallback Behaviors | Critical | Small | **Done** |
| [FAILSPEC-3](story-failspec-3-killswitch-md.md) | Implement KILLSWITCH.md Emergency Stop | Critical | Small | **Done** |
| [FAILSPEC-4](story-failspec-4-audit-logging.md) | Structured Audit Log for Compliance | High | Medium | **Done** |

## Implementation Order

1. **FAILSPEC-1** (Critical) — Define all failure modes, detection signals, and response procedures
2. **FAILSPEC-2** (Critical) — Define safe fallback behaviors for each failure mode
3. **FAILSPEC-3** (Critical) — Define emergency stop triggers and procedures
4. **FAILSPEC-4** (High) — Add structured audit logging for compliance readiness

## Research-Informed Design

### FAILURE.md Specification Structure

```yaml
failure_modes:
  - name: api_rate_limit
    severity: medium
    detection:
      signals: ["exit_code_124", "rate_limit_event_in_stream", "quota_exceeded_text"]
      latency: "<5s"
    response:
      action: "backoff_and_retry"
      backoff: "exponential_with_jitter"
      max_retries: 3
      fallback: "circuit_breaker_open"
    notification:
      level: "warn"
      channels: ["log", "webhook"]
    escalation:
      after: "3_consecutive"
      target: "circuit_breaker"
```

Reference: [FAILURE.md Specification](https://failure.md/), [FAILSAFE.md Specification](https://failsafe.md/), [KILLSWITCH.md Specification](https://killswitch.md/)

### Audit Log Requirements (EU AI Act)

| Field | Description | Example |
|-------|-------------|---------|
| `timestamp` | ISO 8601 | `2026-03-22T14:30:00Z` |
| `event_type` | Action category | `loop_iteration`, `circuit_breaker_trip`, `killswitch_activated` |
| `actor` | Who/what triggered | `ralph_loop`, `user_sigint`, `watchdog` |
| `decision` | What was decided | `continue`, `halt`, `fallback_to_haiku` |
| `reason` | Why | `timeout_count_exceeded_threshold` |
| `trace_id` | OTel correlation | UUID |
| `outcome` | Result | `success`, `failure`, `degraded` |

Reference: [EU AI Act — Technical Documentation Requirements](https://artificialintelligenceact.eu/), [ISO 42001](https://www.iso.org/standard/81230.html)

## Acceptance Criteria (Epic-level)

- [ ] `FAILURE.md` documents all Ralph failure modes with detection, response, and escalation
- [ ] `FAILSAFE.md` documents safe fallback behaviors for each failure mode
- [ ] `KILLSWITCH.md` documents emergency stop triggers and procedures
- [ ] Structured audit log captures all safety-relevant decisions
- [ ] Audit log format supports compliance review (ISO 42001, EU AI Act)
- [ ] Existing circuit breaker and guard rail behavior unchanged — specs document existing behavior + new audit logging
- [ ] All three spec files are machine-readable (YAML frontmatter + markdown)

## Rollback

FAILURE.md / FAILSAFE.md / KILLSWITCH.md are documentation files — no code changes required for the specs themselves. Audit logging (FAILSPEC-4) is additive and can be disabled via `RALPH_AUDIT_LOG_ENABLED=false`.
