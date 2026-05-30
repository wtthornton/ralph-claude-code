#!/usr/bin/env bats
# Behavior contract for ralph_compute_adaptive_timeout — the main-loop
# adaptive timeout (ADAPTIVE-1). Same right-censoring + ceiling-p95 corrections
# applied to the coordinator timeout in TAP-1682 / Issue 2:
#   1. Censored samples (exit_code 124, recorded ≈ the timeout budget) are
#      inflated 1.5× before the percentile is taken — without this, the
#      adaptive value caps at the current too-tight budget and can never grow.
#   2. Ceiling p95 index instead of integer floor — picks the slow tail, not
#      the median, for small sample sets.
#   3. Legacy plain-integer LATENCY_LOG files are auto-migrated to JSONL on
#      first ralph_record_latency write.

bats_require_minimum_version 1.5.0
load '../helpers/test_helper'

RALPH_LOOP_SH="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

setup() {
    export TEST_TEMP_DIR="$(mktemp -d)"
    export RALPH_DIR="$TEST_TEMP_DIR/.ralph"
    mkdir -p "$RALPH_DIR"
    export LATENCY_LOG="$RALPH_DIR/.invocation_latencies"

    # Knob defaults — mirror ralph_loop.sh declarations.
    export ADAPTIVE_TIMEOUT_ENABLED="true"
    export ADAPTIVE_TIMEOUT_MULTIPLIER=2
    export ADAPTIVE_TIMEOUT_MIN_MINUTES=10
    export ADAPTIVE_TIMEOUT_MAX_MINUTES=60
    export ADAPTIVE_TIMEOUT_MIN_SAMPLES=5
    export CLAUDE_TIMEOUT_MINUTES=15

    local slice="$TEST_TEMP_DIR/_slice.sh"
    {
        echo 'log_status() { :; }'
        echo "LATENCY_LOG='$LATENCY_LOG'"
        awk '/^ralph_record_latency\(\) \{/,/^\}/' "$RALPH_LOOP_SH"
        awk '/^ralph_compute_adaptive_timeout\(\) \{/,/^\}/' "$RALPH_LOOP_SH"
    } > "$slice"
    source "$slice"
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR"
}

# Write a sample directly to the log (bypass the recorder so we control format).
_sample() {  # $1 duration   $2 exit_code
    printf '{"ts":%s,"duration_seconds":%s,"exit_code":%s}\n' \
        "$(date -u +%s)" "$1" "${2:-0}" >> "$LATENCY_LOG"
}

# =============================================================================
# Disabled / sparse-sample paths
# =============================================================================

@test "ADAPTIVE-1: disabled flag returns the static CLAUDE_TIMEOUT_MINUTES" {
    export ADAPTIVE_TIMEOUT_ENABLED="false"
    export CLAUDE_TIMEOUT_MINUTES=22
    [[ "$(ralph_compute_adaptive_timeout)" == "22" ]]
}

@test "ADAPTIVE-1: fewer than ADAPTIVE_TIMEOUT_MIN_SAMPLES returns static default" {
    _sample 60 0; _sample 90 0   # 2 < 5
    [[ "$(ralph_compute_adaptive_timeout)" == "15" ]]
}

# =============================================================================
# Issue 2 ports: censor inflation + ceiling p95 + clamps
# =============================================================================

@test "ADAPTIVE-1: a timed-out (censored) tail sample is inflated 1.5x before x2" {
    # Tail = 900s censored → 1350 inflated → ×2 = 2700s = 45m (within 10–60m).
    _sample 60 0; _sample 120 0; _sample 180 0; _sample 240 0; _sample 900 124
    [[ "$(ralph_compute_adaptive_timeout)" == "45" ]]
}

@test "ADAPTIVE-1: success-only control — same tail value is NOT inflated" {
    # Tail = 900s face-value → ×2 = 1800s = 30m.
    _sample 60 0; _sample 120 0; _sample 180 0; _sample 240 0; _sample 900 0
    [[ "$(ralph_compute_adaptive_timeout)" == "30" ]]
}

@test "ADAPTIVE-1: ceiling p95 index picks the tail, not the median (small n)" {
    # 5 samples, all uncensored. Ceiling index = (5*95+99)/100 = 5 → picks 900.
    # ×2 = 1800s = 30m. (Old floor index 4 would pick 480 → 16m.)
    _sample 60 0; _sample 120 0; _sample 240 0; _sample 480 0; _sample 900 0
    [[ "$(ralph_compute_adaptive_timeout)" == "30" ]]
}

@test "ADAPTIVE-1: computed value clamped at the 60m ceiling" {
    # Each sample 3000s × ADAPTIVE_TIMEOUT_MULTIPLIER=2 = 6000s = 100m → clamp 60.
    for d in 3000 3000 3000 3000 3000; do _sample "$d" 0; done
    [[ "$(ralph_compute_adaptive_timeout)" == "60" ]]
}

@test "ADAPTIVE-1: computed value floored at the 10m floor" {
    for d in 5 6 7 8 9; do _sample "$d" 0; done
    [[ "$(ralph_compute_adaptive_timeout)" == "10" ]]
}

# =============================================================================
# Legacy-format migration (plain int → JSONL)
# =============================================================================

@test "ADAPTIVE-1: legacy plain-integer log is migrated to JSONL on first write" {
    # Seed a legacy log (no exit_code, no timestamp).
    printf '%s\n' 60 90 120 150 > "$LATENCY_LOG"
    # First new write triggers migration + appends one fresh entry.
    ralph_record_latency 200 0
    # Every surviving line must now be JSON with the expected fields.
    run jq -es 'all(.[]; has("duration_seconds") and has("exit_code") and has("ts"))' "$LATENCY_LOG"
    [[ "$status" -eq 0 ]] || fail "expected all lines JSONL, got: $(cat "$LATENCY_LOG")"
    # All migrated legacy lines are recorded as uncensored (exit_code 0).
    local legacy_censored
    legacy_censored=$(head -4 "$LATENCY_LOG" | jq -s 'map(.exit_code) | unique | length')
    [[ "$legacy_censored" == "1" ]] || fail "migrated legacy samples should all be exit_code 0"
}

@test "ADAPTIVE-1: ralph_record_latency caps the file at the last 50 samples" {
    local i
    for i in $(seq 1 60); do ralph_record_latency "$i" 0; done
    run wc -l < "$LATENCY_LOG"
    local count
    count=$(echo "$output" | tr -d '[:space:]')
    [[ "$count" -le 50 ]] || fail "expected ≤50 samples after cap, got $count"
}
