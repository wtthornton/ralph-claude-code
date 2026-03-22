# Epic: Adaptive Timeout Strategy

**Epic ID:** RALPH-ADAPTIVE
**Priority:** High
**Affects:** Loop throughput, API efficiency, unattended operation
**Components:** `ralph_loop.sh` (timeout calculation, latency tracking)
**Related specs:** [epic-loop-guard-rails.md](epic-loop-guard-rails.md)
**Depends on:** RALPH-GUARD (consecutive timeout detection provides the safety net)
**Target Version:** v1.9.0

---

## Problem Statement

Ralph uses a static `CLAUDE_TIMEOUT_MINUTES=30` for all invocations. This is wrong in both directions:

- **Too short for complex tasks**: QA suites, architectural work, and multi-agent sessions routinely need 35-45 minutes. TheStudio had 19 consecutive 30-minute timeouts — many were likely productive sessions killed prematurely.
- **Too long for simple tasks**: A small file edit that normally completes in 2 minutes shouldn't wait 30 minutes before being considered timed out.

### Evidence (from TheStudio logs, 2026-03-22)

- 19 consecutive timeouts at exactly 30 minutes
- Tool counts ranged from 21 to 165 per timeout — wildly different workload sizes hitting the same fixed deadline
- Agent counts ranged from 2 to 8 — multi-agent sessions need proportionally more time

## Research-Informed Adjustments

### Percentile-Based Adaptive Timeouts (2025 Best Practices)

Production systems set timeouts based on **observed latency** rather than fixed values:

- **P99 × multiplier**: Track completion times, compute 99th percentile, multiply by 2x for timeout. This adapts automatically to workload changes.
- **AWS Builders Library**: "Choose timeout values based on the measured latency of the downstream dependency, not guesses."
- **Kubernetes `progressDeadlineSeconds`**: Dynamically evaluates whether forward progress is being made, not just elapsed time.

Reference: [AWS Builders Library — Timeouts and retries](https://aws.amazon.com/builders-library/timeouts-retries-and-backoff-with-jitter/)

### Deadline Propagation (gRPC Pattern)

gRPC converts absolute deadlines to relative timeouts at each hop:
- Client sets deadline: "complete by T+45s"
- Each service computes `remaining = deadline - now`
- If remaining < expected work, fail fast

Reference: [gRPC Deadlines](https://grpc.io/docs/guides/deadlines/)

### Layered Resilience

AWS recommends layering: `TIMEOUT → RETRY → CIRCUIT BREAKER → DEADLINE`. The timeout is the innermost layer, adjusted dynamically based on observed behavior.

Reference: [Codecentric — Resilience Design Patterns](https://www.codecentric.de/en/knowledge-hub/blog/resilience-design-patterns-retry-fallback-timeout-circuit-breaker)

## Stories

| Story | Title | Priority | Effort | Status |
|-------|-------|----------|--------|--------|
| [ADAPTIVE-1](story-adaptive-1-percentile-timeout.md) | Percentile-Based Adaptive Timeout | High | Medium | Pending |
| [ADAPTIVE-2](story-adaptive-2-sub-agent-deadline-budget.md) | Sub-Agent Deadline Budget | High | Medium | Pending |

## Implementation Order

1. **ADAPTIVE-1** (High) — Replaces fixed timeout with adaptive P95-based timeout.
2. **ADAPTIVE-2** (High) — Passes deadline to sub-agents so they adapt their operations to remaining time. Prevents exit 143 cascade during QA.

## Acceptance Criteria (Epic-level)

- [ ] Timeout adjusts based on historical completion times
- [ ] Short tasks get shorter timeouts (faster failure detection)
- [ ] Long tasks get longer timeouts (fewer premature kills)
- [ ] `CLAUDE_TIMEOUT_MINUTES` in `.ralphrc` still works as an override/cap
- [ ] `--status` shows current adaptive timeout value
- [ ] BATS tests verify adaptive behavior

## Out of Scope

- Heartbeat-based timeout (would require Claude CLI changes)
- Dynamic timeout adjustment mid-execution (would require streaming analysis)
- Pre-QA deployment verification (covered in RALPH-DEPLOY)

---

## 2026 Research Addendum

**Added:** 2026-03-22 | **Source:** Phase 14 research review

This epic's adaptive timeout strategy aligns with 2026 best practices. Two complementary patterns have emerged:

1. **Context window management**: Research shows agent success rate decreases after 35 minutes and doubling duration quadruples failure rate. Ralph's adaptive timeout should be combined with task decomposition — if P95 exceeds 35 minutes, the task should be split rather than given more time.

2. **Continue-As-New pattern**: From Temporal — when a session exceeds a threshold, atomically save state, end the session, and start a fresh one. This prevents context exhaustion in long sessions.

**Related Phase 14 epic:** [RALPH-CTXMGMT](epic-context-management.md) adds task decomposition signals and Continue-As-New pattern to complement adaptive timeouts.
