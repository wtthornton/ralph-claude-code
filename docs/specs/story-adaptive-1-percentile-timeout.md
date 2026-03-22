# Story ADAPTIVE-1: Percentile-Based Adaptive Timeout

**Epic:** [Adaptive Timeout Strategy](epic-adaptive-timeout.md)
**Priority:** High
**Status:** Pending
**Effort:** Medium
**Component:** `ralph_loop.sh` (timeout calculation)

---

## Problem

Static `CLAUDE_TIMEOUT_MINUTES=30` kills productive long-running sessions and waits too long for stuck short sessions. 19 consecutive timeouts in TheStudio suggest the workload legitimately needs >30 minutes, but the timeout never adapts.

**Root cause confirmed by:** TheStudio logs 2026-03-22 — tool counts (21–165) and agent counts (2–8) varied wildly across timeouts, all hitting the same 30-minute wall.

## Solution

Track completion times for successful invocations and compute an adaptive timeout based on the P95 (95th percentile) multiplied by a safety factor. This automatically adjusts to the current workload's cadence.

## Implementation

### Step 1: Track completion latencies

```bash
LATENCY_LOG="${RALPH_DIR}/.invocation_latencies"
ADAPTIVE_TIMEOUT_ENABLED=${ADAPTIVE_TIMEOUT_ENABLED:-true}
ADAPTIVE_TIMEOUT_MULTIPLIER=${ADAPTIVE_TIMEOUT_MULTIPLIER:-2}
ADAPTIVE_TIMEOUT_MIN_MINUTES=${ADAPTIVE_TIMEOUT_MIN_MINUTES:-10}
ADAPTIVE_TIMEOUT_MAX_MINUTES=${ADAPTIVE_TIMEOUT_MAX_MINUTES:-60}
ADAPTIVE_TIMEOUT_MIN_SAMPLES=${ADAPTIVE_TIMEOUT_MIN_SAMPLES:-5}

# Record a successful invocation's duration (in seconds)
ralph_record_latency() {
    local duration_seconds="$1"
    echo "$duration_seconds" >> "$LATENCY_LOG"

    # Keep only the last 50 samples to bound file size
    if [[ $(wc -l < "$LATENCY_LOG" 2>/dev/null) -gt 50 ]]; then
        tail -50 "$LATENCY_LOG" > "${LATENCY_LOG}.tmp"
        mv "${LATENCY_LOG}.tmp" "$LATENCY_LOG"
    fi
}
```

### Step 2: Compute adaptive timeout

```bash
ralph_compute_adaptive_timeout() {
    # If adaptive timeout is disabled, use static setting
    if [[ "$ADAPTIVE_TIMEOUT_ENABLED" != "true" ]]; then
        echo "${CLAUDE_TIMEOUT_MINUTES:-30}"
        return
    fi

    # Need minimum samples before adapting
    local sample_count
    sample_count=$(wc -l < "$LATENCY_LOG" 2>/dev/null || echo "0")
    sample_count=$(echo "$sample_count" | tr -d '[:space:]')

    if [[ "$sample_count" -lt "$ADAPTIVE_TIMEOUT_MIN_SAMPLES" ]]; then
        log "DEBUG" "Adaptive timeout: only $sample_count samples (need $ADAPTIVE_TIMEOUT_MIN_SAMPLES) — using static ${CLAUDE_TIMEOUT_MINUTES:-30}m"
        echo "${CLAUDE_TIMEOUT_MINUTES:-30}"
        return
    fi

    # Compute P95
    local p95_index p95_seconds timeout_seconds timeout_minutes
    p95_index=$(( (sample_count * 95) / 100 ))
    [[ "$p95_index" -lt 1 ]] && p95_index=1

    p95_seconds=$(sort -n "$LATENCY_LOG" | sed -n "${p95_index}p")

    # Apply multiplier
    timeout_seconds=$((p95_seconds * ADAPTIVE_TIMEOUT_MULTIPLIER))
    timeout_minutes=$(( (timeout_seconds + 59) / 60 ))  # Round up

    # Clamp to min/max
    [[ "$timeout_minutes" -lt "$ADAPTIVE_TIMEOUT_MIN_MINUTES" ]] && timeout_minutes=$ADAPTIVE_TIMEOUT_MIN_MINUTES
    [[ "$timeout_minutes" -gt "$ADAPTIVE_TIMEOUT_MAX_MINUTES" ]] && timeout_minutes=$ADAPTIVE_TIMEOUT_MAX_MINUTES

    # Honor explicit override if it's lower (user wants a hard cap)
    if [[ -n "${CLAUDE_TIMEOUT_MINUTES_OVERRIDE:-}" ]] && \
       [[ "$CLAUDE_TIMEOUT_MINUTES_OVERRIDE" -lt "$timeout_minutes" ]]; then
        timeout_minutes=$CLAUDE_TIMEOUT_MINUTES_OVERRIDE
    fi

    log "DEBUG" "Adaptive timeout: P95=${p95_seconds}s × ${ADAPTIVE_TIMEOUT_MULTIPLIER} = ${timeout_minutes}m (range: ${ADAPTIVE_TIMEOUT_MIN_MINUTES}-${ADAPTIVE_TIMEOUT_MAX_MINUTES}m, samples: $sample_count)"
    echo "$timeout_minutes"
}
```

### Step 3: Integrate with main loop

```bash
# Before each Claude invocation:
local invocation_start invocation_end duration_seconds
local adaptive_timeout
adaptive_timeout=$(ralph_compute_adaptive_timeout)

invocation_start=$(date +%s)

# Use adaptive timeout instead of static
timeout $((adaptive_timeout * 60)) $CLAUDE_CMD ...
EXIT_CODE=$?

invocation_end=$(date +%s)
duration_seconds=$((invocation_end - invocation_start))

# Record latency on successful completion (not timeouts)
if [[ "$EXIT_CODE" -ne 124 ]]; then
    ralph_record_latency "$duration_seconds"
fi
```

### Step 4: Add to --status output

```bash
# In --status handler:
local current_timeout
current_timeout=$(ralph_compute_adaptive_timeout)
local sample_count
sample_count=$(wc -l < "$LATENCY_LOG" 2>/dev/null || echo "0")
echo "Timeout: ${current_timeout}m (adaptive, $sample_count samples)"
```

### Step 5: Add configuration

```bash
# In .ralphrc template:
# ADAPTIVE_TIMEOUT_ENABLED=true      # Enable adaptive timeout (default: true)
# ADAPTIVE_TIMEOUT_MULTIPLIER=2      # P95 × this = timeout (default: 2)
# ADAPTIVE_TIMEOUT_MIN_MINUTES=10    # Floor (default: 10)
# ADAPTIVE_TIMEOUT_MAX_MINUTES=60    # Ceiling (default: 60)
# ADAPTIVE_TIMEOUT_MIN_SAMPLES=5     # Samples needed before adapting (default: 5)
# CLAUDE_TIMEOUT_MINUTES=30          # Still works as static fallback
```

## Design Notes

- **P95 vs P99**: P95 is more responsive to workload changes. P99 would be dominated by outliers (one 45-minute session would keep the timeout high for 100 iterations).
- **2x multiplier**: Gives 100% headroom over normal P95. Aggressive enough to avoid premature kills but not so generous that stuck sessions run forever.
- **Min 10 minutes**: Even fast tasks need enough time for Claude to think, spawn agents, and write code. 10 minutes is a reasonable floor.
- **Max 60 minutes**: Hard safety cap. Beyond 60 minutes, the task should be decomposed rather than given more time.
- **Only successful completions**: Timeouts are excluded from the latency record to prevent a feedback loop where timeouts increase the P95, which increases the timeout, which increases P95...
- **50-sample window**: Covers roughly 1-2 days of operation at typical loop cadence. Old enough to capture variation, recent enough to adapt to workload changes.
- **CLAUDE_TIMEOUT_MINUTES backward compatibility**: If `ADAPTIVE_TIMEOUT_ENABLED=false`, the static value is used unchanged. Existing `.ralphrc` configs keep working.
- **AWS parallel**: This mirrors the AWS Builders Library recommendation: "Set timeouts based on measured latency distributions, not estimates."

## Acceptance Criteria

- [ ] Timeout adapts based on historical completion times (P95 × multiplier)
- [ ] Minimum 5 samples required before adaptive mode activates
- [ ] Timeout clamped to configurable min/max range (default: 10–60 minutes)
- [ ] Timeouts (exit code 124) are excluded from latency record
- [ ] `ADAPTIVE_TIMEOUT_ENABLED=false` reverts to static `CLAUDE_TIMEOUT_MINUTES`
- [ ] `--status` shows current adaptive timeout and sample count
- [ ] Latency log bounded to 50 entries
- [ ] All settings configurable via `.ralphrc`

## Test Plan

```bash
@test "ralph_compute_adaptive_timeout uses static when insufficient samples" {
    source "$RALPH_DIR/ralph_loop.sh"
    LATENCY_LOG="$TEST_DIR/latencies"
    ADAPTIVE_TIMEOUT_ENABLED="true"
    ADAPTIVE_TIMEOUT_MIN_SAMPLES=5
    CLAUDE_TIMEOUT_MINUTES=30

    echo "120" > "$LATENCY_LOG"  # Only 1 sample

    run ralph_compute_adaptive_timeout
    assert_output "30"
}

@test "ralph_compute_adaptive_timeout computes P95 with multiplier" {
    source "$RALPH_DIR/ralph_loop.sh"
    LATENCY_LOG="$TEST_DIR/latencies"
    ADAPTIVE_TIMEOUT_ENABLED="true"
    ADAPTIVE_TIMEOUT_MIN_SAMPLES=5
    ADAPTIVE_TIMEOUT_MULTIPLIER=2
    ADAPTIVE_TIMEOUT_MIN_MINUTES=1
    ADAPTIVE_TIMEOUT_MAX_MINUTES=120

    # 10 samples: 60-600s. P95 index = 9th value = 540s
    printf '%s\n' 60 120 180 240 300 360 420 480 540 600 > "$LATENCY_LOG"

    run ralph_compute_adaptive_timeout
    # P95 = 540s × 2 = 1080s = 18m
    assert_output "18"
}

@test "ralph_compute_adaptive_timeout respects min clamp" {
    source "$RALPH_DIR/ralph_loop.sh"
    LATENCY_LOG="$TEST_DIR/latencies"
    ADAPTIVE_TIMEOUT_ENABLED="true"
    ADAPTIVE_TIMEOUT_MIN_SAMPLES=5
    ADAPTIVE_TIMEOUT_MULTIPLIER=2
    ADAPTIVE_TIMEOUT_MIN_MINUTES=10
    ADAPTIVE_TIMEOUT_MAX_MINUTES=60

    # 5 very fast samples: 30s each. P95 = 30s × 2 = 1m → clamped to 10m
    printf '%s\n' 30 30 30 30 30 > "$LATENCY_LOG"

    run ralph_compute_adaptive_timeout
    assert_output "10"
}

@test "ralph_compute_adaptive_timeout respects max clamp" {
    source "$RALPH_DIR/ralph_loop.sh"
    LATENCY_LOG="$TEST_DIR/latencies"
    ADAPTIVE_TIMEOUT_ENABLED="true"
    ADAPTIVE_TIMEOUT_MIN_SAMPLES=5
    ADAPTIVE_TIMEOUT_MULTIPLIER=2
    ADAPTIVE_TIMEOUT_MIN_MINUTES=10
    ADAPTIVE_TIMEOUT_MAX_MINUTES=60

    # 5 very slow samples: 3600s each. P95 = 3600s × 2 = 120m → clamped to 60m
    printf '%s\n' 3600 3600 3600 3600 3600 > "$LATENCY_LOG"

    run ralph_compute_adaptive_timeout
    assert_output "60"
}

@test "ralph_compute_adaptive_timeout disabled falls back to static" {
    source "$RALPH_DIR/ralph_loop.sh"
    ADAPTIVE_TIMEOUT_ENABLED="false"
    CLAUDE_TIMEOUT_MINUTES=25

    run ralph_compute_adaptive_timeout
    assert_output "25"
}

@test "ralph_record_latency bounds file to 50 entries" {
    source "$RALPH_DIR/ralph_loop.sh"
    LATENCY_LOG="$TEST_DIR/latencies"

    for i in $(seq 1 60); do
        ralph_record_latency "$i"
    done

    local count
    count=$(wc -l < "$LATENCY_LOG" | tr -d ' ')
    assert [ "$count" -le 50 ]
}
```

## References

- [AWS Builders Library — Timeouts, retries, and backoff with jitter](https://aws.amazon.com/builders-library/timeouts-retries-and-backoff-with-jitter/)
- [AWS Architecture Blog — Exponential Backoff and Jitter](https://aws.amazon.com/blogs/architecture/exponential-backoff-and-jitter/)
- [gRPC — Deadlines](https://grpc.io/docs/guides/deadlines/)
- [Codecentric — Resilience Design Patterns](https://www.codecentric.de/en/knowledge-hub/blog/resilience-design-patterns-retry-fallback-timeout-circuit-breaker)
- [Kubernetes progressDeadlineSeconds](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#progress-deadline-seconds)
- [AWS Step Functions — TimeoutSecondsPath](https://docs.aws.amazon.com/step-functions/latest/dg/sfn-stuck-execution.html)
