# Story RALPH-MULTI-4: Reset Circuit Breaker State on Startup

**Epic:** [Multi-Task Loop Violation and Cascading Failures](epic-multi-task-cascading-failures.md)
**Priority:** Low
**Status:** Done
**Effort:** Trivial
**Component:** `ralph_loop.sh` (startup section, near line 1826)

---

## Problem

When Ralph starts a new session, it resets exit signals (line 1829):
```bash
echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": []}' > "$EXIT_SIGNALS_FILE"
```

But circuit breaker state (`.circuit_breaker_state`) is NOT reset. Stale counters
from the previous session persist:

```json
{
  "consecutive_permission_denials": 1,
  "last_progress_loop": 5,
  "current_loop": 5
}
```

In the March 21 incident, `consecutive_permission_denials: 1` was left over from
March 20. If analysis had succeeded, the stale `current_loop: 5` could confuse
the circuit breaker's loop-based thresholds.

## Solution

Add circuit breaker session-counter reset during startup, alongside the existing
exit signal reset. Preserve the circuit breaker `state` (CLOSED/HALF_OPEN/OPEN)
and `cooldown` fields, but reset per-session counters.

## Implementation

In `ralph_loop.sh`, add after the exit signals reset (near line 1829):

```bash
# Reset circuit breaker per-session counters (preserve state and cooldown config)
if [[ -f "$CIRCUIT_BREAKER_FILE" ]]; then
    jq '.consecutive_no_progress = 0 |
        .consecutive_same_error = 0 |
        .consecutive_permission_denials = 0 |
        .current_loop = 0 |
        .last_progress_loop = 0' \
        "$CIRCUIT_BREAKER_FILE" > "${CIRCUIT_BREAKER_FILE}.tmp" && \
        mv "${CIRCUIT_BREAKER_FILE}.tmp" "$CIRCUIT_BREAKER_FILE"
    log_status "INFO" "Reset circuit breaker counters for new session"
fi
```

## Design Notes

- **Preserve `state` field:** If the CB was in OPEN state due to a legitimate
  stagnation pattern, the user may want to see that on restart. However, most
  sessions reset exit signals on startup, implying a fresh start. Resetting
  counters while preserving `state` is a reasonable middle ground.
- **`last_progress_loop` reset:** This is relative to the current session's loop
  count. Stale values from the previous session's loop numbering are meaningless.
- **Atomic write:** `jq > .tmp && mv .tmp` prevents partial writes if interrupted.

## Acceptance Criteria

- [ ] Circuit breaker counters are reset to 0 on session startup
- [ ] Circuit breaker state (CLOSED/HALF_OPEN/OPEN) is preserved
- [ ] Reset is logged
- [ ] Reset uses atomic write pattern (tmp + mv)

## Test Plan

```bash
@test "circuit breaker counters reset on startup" {
    # Create stale circuit breaker state
    cat > "$TEST_DIR/.circuit_breaker_state" <<'EOF'
{"state":"CLOSED","consecutive_no_progress":3,"consecutive_same_error":2,"consecutive_permission_denials":1,"current_loop":5,"last_progress_loop":3}
EOF

    CIRCUIT_BREAKER_FILE="$TEST_DIR/.circuit_breaker_state"

    # Run the reset logic
    jq '.consecutive_no_progress = 0 | .consecutive_same_error = 0 |
        .consecutive_permission_denials = 0 | .current_loop = 0 |
        .last_progress_loop = 0' \
        "$CIRCUIT_BREAKER_FILE" > "${CIRCUIT_BREAKER_FILE}.tmp" && \
        mv "${CIRCUIT_BREAKER_FILE}.tmp" "$CIRCUIT_BREAKER_FILE"

    # Verify counters reset
    run jq -r '.consecutive_no_progress' "$CIRCUIT_BREAKER_FILE"
    assert_output "0"
    run jq -r '.consecutive_permission_denials' "$CIRCUIT_BREAKER_FILE"
    assert_output "0"
    run jq -r '.current_loop' "$CIRCUIT_BREAKER_FILE"
    assert_output "0"

    # Verify state preserved
    run jq -r '.state' "$CIRCUIT_BREAKER_FILE"
    assert_output "CLOSED"
}
```
