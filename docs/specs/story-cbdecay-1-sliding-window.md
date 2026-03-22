# Story CBDECAY-1: Time-Weighted Sliding Window

**Epic:** [Circuit Breaker Failure Decay](epic-circuit-breaker-decay.md)
**Priority:** High
**Status:** Pending
**Effort:** Medium
**Component:** `lib/circuit_breaker.sh`

---

## Problem

The circuit breaker uses a simple cumulative failure counter. Failures from hours ago contribute equally to the threshold as failures from the last 5 minutes. This causes false trips when:
1. A burst of failures occurs (e.g., 40 failures from concurrent instances)
2. The session is reset and new loops begin successfully
3. A single new failure pushes the cumulative count over the threshold
4. CB trips even though recent failure rate is low

**Root cause confirmed by:** tapps-brain logs, CB trip at 23:36 after only 3 loops — prior 40-failure burst still in the counter.

## Solution

Replace the cumulative failure counter with a **time-based sliding window**. Only failures within the last `CB_FAILURE_DECAY_MINUTES` contribute to the threshold. Older failures are automatically excluded from the failure rate calculation.

## Implementation

### Step 1: Add failure event log

Replace the single counter with a timestamped event log:

```bash
CB_FAILURE_LOG="${RALPH_DIR}/.circuit_breaker_events"
CB_FAILURE_DECAY_MINUTES=${CB_FAILURE_DECAY_MINUTES:-30}
CB_FAILURE_THRESHOLD=${CB_FAILURE_THRESHOLD:-5}
CB_MIN_CALLS=${CB_MIN_CALLS:-3}  # Don't evaluate until N calls in window

# Record a failure event with timestamp
cb_record_failure() {
    local now
    now=$(date +%s)
    echo "$now fail" >> "$CB_FAILURE_LOG"
    cb_evaluate
}

# Record a success event
cb_record_success() {
    local now
    now=$(date +%s)
    echo "$now ok" >> "$CB_FAILURE_LOG"
    # Prune old entries beyond the window
    cb_prune_old_events
}
```

### Step 2: Implement sliding window evaluation

```bash
cb_prune_old_events() {
    local now cutoff
    now=$(date +%s)
    cutoff=$((now - CB_FAILURE_DECAY_MINUTES * 60))

    if [[ -f "$CB_FAILURE_LOG" ]]; then
        awk -v cutoff="$cutoff" '$1 >= cutoff' "$CB_FAILURE_LOG" > "${CB_FAILURE_LOG}.tmp"
        mv "${CB_FAILURE_LOG}.tmp" "$CB_FAILURE_LOG"
    fi
}

cb_get_window_stats() {
    local now cutoff total failures
    now=$(date +%s)
    cutoff=$((now - CB_FAILURE_DECAY_MINUTES * 60))

    if [[ ! -f "$CB_FAILURE_LOG" ]]; then
        echo "0 0"
        return
    fi

    total=$(awk -v cutoff="$cutoff" '$1 >= cutoff' "$CB_FAILURE_LOG" | wc -l)
    failures=$(awk -v cutoff="$cutoff" '$1 >= cutoff && $2 == "fail"' "$CB_FAILURE_LOG" | wc -l)
    echo "$total $failures"
}

cb_evaluate() {
    local stats total failures
    stats=$(cb_get_window_stats)
    total=$(echo "$stats" | cut -d' ' -f1)
    failures=$(echo "$stats" | cut -d' ' -f2)

    # Don't evaluate until minimum calls reached
    if [[ "$total" -lt "$CB_MIN_CALLS" ]]; then
        return 0
    fi

    if [[ "$failures" -ge "$CB_FAILURE_THRESHOLD" ]]; then
        log "WARN" "Circuit breaker threshold reached: $failures failures in last ${CB_FAILURE_DECAY_MINUTES}m (window: $total calls)"
        cb_trip "failure_threshold"
        return 1
    fi

    return 0
}
```

### Step 3: Update --reset-circuit to clear event log

```bash
cb_reset() {
    log "INFO" "Resetting circuit breaker — clearing failure event log"
    : > "$CB_FAILURE_LOG"  # Truncate event log
    # ... existing reset logic ...
}
```

### Step 4: Add configuration

```bash
# In .ralphrc template:
# CB_FAILURE_DECAY_MINUTES=30   # Failures older than this are ignored
# CB_FAILURE_THRESHOLD=5        # Failures within window to trip CB
# CB_MIN_CALLS=3                # Minimum calls before evaluating
```

### Step 5: Add window stats to --status output

```bash
# In --status handler:
local stats total failures
stats=$(cb_get_window_stats)
total=$(echo "$stats" | cut -d' ' -f1)
failures=$(echo "$stats" | cut -d' ' -f2)
echo "Circuit Breaker: $(cb_get_state) ($failures failures / $total calls in last ${CB_FAILURE_DECAY_MINUTES}m)"
```

## Design Notes

- **Time-based vs count-based window**: Time-based is better for Ralph because loop intervals are variable (2s between loops, but 30+ minutes per invocation). A count-based window of 10 could span 5 hours. Time-based ensures failures decay predictably.
- **File-based event log**: Simple append-only log file. Pruned on each success to prevent unbounded growth. Worst case (100 calls/hour × 24 hours) = 2,400 lines × ~20 bytes = ~50KB.
- **CB_MIN_CALLS=3**: Prevents tripping on the first 2-3 calls of a new session. Matches Resilience4j's `minimumNumberOfCalls` pattern.
- **Backwards compatibility**: Old `.circuit_breaker_state` file is still read for state (CLOSED/OPEN/HALF_OPEN). The event log augments it with time-aware failure counting.
- **Resilience4j parity**: This implementation mirrors Resilience4j's TIME_BASED `slidingWindowType` with `failureRateThreshold` replaced by `CB_FAILURE_THRESHOLD` (absolute count, simpler for bash).

## Acceptance Criteria

- [ ] Failures older than `CB_FAILURE_DECAY_MINUTES` do not count toward threshold
- [ ] Success events are recorded (for accurate failure rate calculation)
- [ ] `CB_MIN_CALLS` prevents premature evaluation
- [ ] `--reset-circuit` clears the event log
- [ ] `--status` shows current window stats (failures/total in last Nm)
- [ ] Event log is pruned on each success (bounded growth)
- [ ] Configurable via `.ralphrc`: `CB_FAILURE_DECAY_MINUTES`, `CB_FAILURE_THRESHOLD`, `CB_MIN_CALLS`

## Test Plan

```bash
@test "cb_record_failure adds timestamped entry" {
    source "$RALPH_DIR/lib/circuit_breaker.sh"
    CB_FAILURE_LOG="$TEST_DIR/events"
    CB_FAILURE_THRESHOLD=999  # Won't trip in this test

    cb_record_failure
    assert [ -f "$CB_FAILURE_LOG" ]
    assert_equal "$(wc -l < "$CB_FAILURE_LOG" | tr -d ' ')" "1"
    assert_output_contains "fail" "$(cat "$CB_FAILURE_LOG")"
}

@test "cb_prune_old_events removes entries outside window" {
    source "$RALPH_DIR/lib/circuit_breaker.sh"
    CB_FAILURE_LOG="$TEST_DIR/events"
    CB_FAILURE_DECAY_MINUTES=5

    local old_time=$(($(date +%s) - 600))  # 10 minutes ago
    local recent_time=$(date +%s)

    echo "$old_time fail" > "$CB_FAILURE_LOG"
    echo "$recent_time fail" >> "$CB_FAILURE_LOG"

    cb_prune_old_events
    assert_equal "$(wc -l < "$CB_FAILURE_LOG" | tr -d ' ')" "1"
}

@test "cb_evaluate does not trip below threshold" {
    source "$RALPH_DIR/lib/circuit_breaker.sh"
    CB_FAILURE_LOG="$TEST_DIR/events"
    CB_FAILURE_THRESHOLD=5
    CB_MIN_CALLS=1
    CB_FAILURE_DECAY_MINUTES=30

    local now=$(date +%s)
    echo "$now fail" > "$CB_FAILURE_LOG"
    echo "$now ok" >> "$CB_FAILURE_LOG"

    run cb_evaluate
    assert_success
}

@test "cb_evaluate trips at threshold" {
    source "$RALPH_DIR/lib/circuit_breaker.sh"
    CB_FAILURE_LOG="$TEST_DIR/events"
    CB_FAILURE_THRESHOLD=3
    CB_MIN_CALLS=1
    CB_FAILURE_DECAY_MINUTES=30
    CB_TRIPPED=false
    cb_trip() { CB_TRIPPED=true; }

    local now=$(date +%s)
    for i in 1 2 3; do
        echo "$now fail" >> "$CB_FAILURE_LOG"
    done

    cb_evaluate
    assert_equal "$CB_TRIPPED" "true"
}

@test "cb_evaluate respects minimum calls" {
    source "$RALPH_DIR/lib/circuit_breaker.sh"
    CB_FAILURE_LOG="$TEST_DIR/events"
    CB_FAILURE_THRESHOLD=2
    CB_MIN_CALLS=5
    CB_FAILURE_DECAY_MINUTES=30

    local now=$(date +%s)
    echo "$now fail" > "$CB_FAILURE_LOG"
    echo "$now fail" >> "$CB_FAILURE_LOG"

    run cb_evaluate
    assert_success  # Only 2 calls, min is 5
}

@test "old failures outside window are ignored" {
    source "$RALPH_DIR/lib/circuit_breaker.sh"
    CB_FAILURE_LOG="$TEST_DIR/events"
    CB_FAILURE_THRESHOLD=3
    CB_MIN_CALLS=1
    CB_FAILURE_DECAY_MINUTES=5

    local old=$(($(date +%s) - 600))  # 10 min ago (outside 5 min window)
    local now=$(date +%s)

    # 5 old failures + 1 recent success
    for i in 1 2 3 4 5; do echo "$old fail" >> "$CB_FAILURE_LOG"; done
    echo "$now ok" >> "$CB_FAILURE_LOG"

    run cb_evaluate
    assert_success  # Old failures excluded, only 1 recent call (success)
}
```

## References

- [Resilience4j — CircuitBreaker Configuration](https://resilience4j.readme.io/docs/circuitbreaker)
- [Martin Fowler — CircuitBreaker](https://martinfowler.com/bliki/CircuitBreaker.html)
- [Microsoft Azure — Circuit Breaker Pattern](https://learn.microsoft.com/en-us/azure/architecture/patterns/circuit-breaker)
- [Netflix Hystrix — How It Works](https://github.com/netflix/hystrix/wiki/how-it-works)
- [AWS — Circuit Breaker Pattern](https://docs.aws.amazon.com/prescriptive-guidance/latest/cloud-design-patterns/circuit-breaker.html)
- [Failsafe — Circuit Breaker](https://failsafe.dev/circuit-breaker/)
