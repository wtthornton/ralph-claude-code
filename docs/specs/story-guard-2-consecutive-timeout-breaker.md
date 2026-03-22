# Story GUARD-2: Consecutive Timeout Circuit Breaker

**Epic:** [Loop Progress Detection & Guard Rails](epic-loop-guard-rails.md)
**Priority:** Critical
**Status:** Pending
**Effort:** Small
**Component:** `ralph_loop.sh`

---

## Problem

Ralph has no mechanism to detect repeated timeouts. Each 30-minute timeout is evaluated independently. Even 19 consecutive timeouts (9.5 hours, ~$50+ in API costs) don't trigger any safety mechanism because each one passes the stale file-change check (see GUARD-1).

Even after GUARD-1 fixes the stale detection, a secondary guard is needed: if Claude genuinely times out N times in a row (even with real changes), something is fundamentally wrong — the task is too large, Claude is stuck in a loop, or the timeout is too short.

**Root cause confirmed by:** TheStudio logs 2026-03-22, 02:10–11:45.

## Solution

Add a `MAX_CONSECUTIVE_TIMEOUTS` counter that opens the circuit breaker after N consecutive unproductive timeouts. Reset the counter on any successful (non-timeout) completion or a timeout with verified real progress.

## Implementation

### Step 1: Add configuration

```bash
# In .ralphrc template and defaults in ralph_loop.sh
MAX_CONSECUTIVE_TIMEOUTS=${MAX_CONSECUTIVE_TIMEOUTS:-5}
```

### Step 2: Add counter tracking

```bash
# Near the top of the main loop, initialize counter
CONSECUTIVE_TIMEOUT_COUNT=0

# In the timeout handler:
handle_timeout() {
    if ralph_has_real_changes; then
        log "INFO" "Timeout but real changes detected — resetting timeout counter"
        CONSECUTIVE_TIMEOUT_COUNT=0
    else
        CONSECUTIVE_TIMEOUT_COUNT=$((CONSECUTIVE_TIMEOUT_COUNT + 1))
        log "WARN" "Unproductive timeout ($CONSECUTIVE_TIMEOUT_COUNT/$MAX_CONSECUTIVE_TIMEOUTS)"

        if [[ "$CONSECUTIVE_TIMEOUT_COUNT" -ge "$MAX_CONSECUTIVE_TIMEOUTS" ]]; then
            log "ERROR" "Hit $MAX_CONSECUTIVE_TIMEOUTS consecutive unproductive timeouts — opening circuit breaker"
            log "ERROR" "Possible causes: task too large, Claude stuck in loop, timeout too short"
            log "ERROR" "Actions: increase CLAUDE_TIMEOUT_MINUTES, simplify fix_plan.md tasks, or run with --reset-circuit"
            cb_trip "consecutive_timeouts"
            return 1
        fi
    fi
}

# On any successful completion, reset the counter:
CONSECUTIVE_TIMEOUT_COUNT=0
```

### Step 3: Add actionable error messaging

When the breaker trips due to consecutive timeouts, log specific remediation steps:

```bash
cb_trip_consecutive_timeouts() {
    local msg="Circuit breaker opened: $MAX_CONSECUTIVE_TIMEOUTS consecutive unproductive timeouts"
    log "ERROR" "$msg"
    log "ERROR" "Remediation options:"
    log "ERROR" "  1. Increase timeout: CLAUDE_TIMEOUT_MINUTES=45 in .ralphrc"
    log "ERROR" "  2. Break down tasks: split large tasks in fix_plan.md"
    log "ERROR" "  3. Reset and retry: ralph --reset-circuit"
    log "ERROR" "  4. Check if Claude is stuck: review last claude_output_*.log"

    # Write to status.json for monitor visibility
    write_status "HALTED" "consecutive_timeouts" "$msg"
}
```

## Design Notes

- **Default of 5**: Conservative — 5 × 30min = 2.5 hours of timeouts before halting. Enough to tolerate occasional legitimate long tasks but catches runaway loops.
- **Real changes reset counter**: If Claude genuinely makes progress despite timing out, the counter resets. This allows long-running productive sessions to continue.
- **Complements GUARD-1**: Even if GUARD-1's baseline detection has edge cases, this provides a hard upper bound.
- **Configurable**: Power users running complex architectual tasks can set `MAX_CONSECUTIVE_TIMEOUTS=10` in `.ralphrc`.
- **Kubernetes parallel**: Similar to `progressDeadlineSeconds` — if the system doesn't make forward progress within a budget, it fails.
- **AWS parallel**: Similar to Step Functions `HeartbeatSeconds` — if no heartbeat (progress) within N intervals, the task is considered failed.

## Acceptance Criteria

- [ ] `MAX_CONSECUTIVE_TIMEOUTS` is configurable via `.ralphrc` (default: 5)
- [ ] Counter increments on each timeout with no real changes (per GUARD-1)
- [ ] Counter resets to 0 on successful completion or timeout with real changes
- [ ] Circuit breaker opens when counter reaches threshold
- [ ] Error message includes specific remediation steps
- [ ] `status.json` reflects the halt reason as `consecutive_timeouts`

## Test Plan

```bash
@test "consecutive timeout counter increments on unproductive timeout" {
    source "$RALPH_DIR/ralph_loop.sh"
    CONSECUTIVE_TIMEOUT_COUNT=0
    MAX_CONSECUTIVE_TIMEOUTS=3

    # Mock ralph_has_real_changes to return failure (no changes)
    ralph_has_real_changes() { return 1; }

    handle_timeout
    assert_equal "$CONSECUTIVE_TIMEOUT_COUNT" "1"

    handle_timeout
    assert_equal "$CONSECUTIVE_TIMEOUT_COUNT" "2"
}

@test "consecutive timeout counter resets on real changes" {
    source "$RALPH_DIR/ralph_loop.sh"
    CONSECUTIVE_TIMEOUT_COUNT=3

    # Mock ralph_has_real_changes to return success (changes detected)
    ralph_has_real_changes() { return 0; }

    handle_timeout
    assert_equal "$CONSECUTIVE_TIMEOUT_COUNT" "0"
}

@test "circuit breaker opens at MAX_CONSECUTIVE_TIMEOUTS" {
    source "$RALPH_DIR/ralph_loop.sh"
    CONSECUTIVE_TIMEOUT_COUNT=4
    MAX_CONSECUTIVE_TIMEOUTS=5
    CB_TRIPPED=false

    ralph_has_real_changes() { return 1; }
    cb_trip() { CB_TRIPPED=true; }

    handle_timeout
    assert_equal "$CB_TRIPPED" "true"
}

@test "MAX_CONSECUTIVE_TIMEOUTS reads from .ralphrc" {
    echo 'MAX_CONSECUTIVE_TIMEOUTS=10' > "$TEST_DIR/.ralphrc"
    source "$TEST_DIR/.ralphrc"
    assert_equal "$MAX_CONSECUTIVE_TIMEOUTS" "10"
}
```

## References

- [Kubernetes progressDeadlineSeconds](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#progress-deadline-seconds)
- [AWS Step Functions HeartbeatSeconds](https://docs.aws.amazon.com/step-functions/latest/dg/sfn-stuck-execution.html)
- [Resilience4j CircuitBreaker — minimumNumberOfCalls](https://resilience4j.readme.io/docs/circuitbreaker)
- [AWS Builders Library — Timeouts, retries, and backoff with jitter](https://aws.amazon.com/builders-library/timeouts-retries-and-backoff-with-jitter/)
