#!/usr/bin/env bats
# Issue 2: coordinator adaptive timeout must cover the coordinator's observed
# p95 (briefs complete in 150–250s). The harness already has an adaptive
# timeout (ralph_compute_coordinator_timeout); the field bug was that it
# under-computed (154s, 248s) and killed healthy briefs. Three defects fixed:
#   1. fallback/floor raised below the observed band → raised to 300/180.
#   2. right-censoring: a timed-out run records duration ≈ the (too-tight)
#      budget; that censored sample is now inflated 1.5× so the budget can
#      escape the censoring trap.
#   3. integer (n*95)/100 picked the MEDIAN for small n → ceiling index so
#      "p95" actually covers the slow tail.
# Plus: per-loop phase attribution (synthesis vs brain recall) is logged.

bats_require_minimum_version 1.5.0
load '../helpers/test_helper'

RALPH_LOOP_SH="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

setup() {
    export TEST_TEMP_DIR="$(mktemp -d)"
    export RALPH_DIR="$TEST_TEMP_DIR/.ralph"
    mkdir -p "$RALPH_DIR"
    export COORDINATOR_TIMINGS_LOG="$RALPH_DIR/.coordinator_timings.jsonl"
    export COORDINATOR_PHASE_TIMINGS_LOG="$RALPH_DIR/.coordinator_phase_timings.jsonl"
    export COORDINATOR_TIMING_SAMPLE_CAP=30
    # Clear any operator override leaking from the environment.
    unset RALPH_COORDINATOR_TIMEOUT_SECONDS RALPH_COORDINATOR_TIMEOUT_MIN_SECONDS \
          RALPH_COORDINATOR_TIMEOUT_MAX_SECONDS RALPH_COORDINATOR_TIMEOUT_FALLBACK_SECONDS \
          RALPH_COORDINATOR_TIMEOUT_MIN_SAMPLES

    local slice="$TEST_TEMP_DIR/_slice.sh"
    {
        echo 'log_status() { :; }'
        echo "COORDINATOR_TIMINGS_LOG='$COORDINATOR_TIMINGS_LOG'"
        echo "COORDINATOR_PHASE_TIMINGS_LOG='$COORDINATOR_PHASE_TIMINGS_LOG'"
        echo "COORDINATOR_TIMING_SAMPLE_CAP=30"
        awk '/^ralph_compute_coordinator_timeout\(\) \{/,/^\}/' "$RALPH_LOOP_SH"
        awk '/^ralph_record_coordinator_phase_timing\(\) \{/,/^\}/' "$RALPH_LOOP_SH"
    } > "$slice"
    source "$slice"
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR"
}

# Write a timings sample line.
_sample() { # $1 duration  $2 exit_code
    printf '{"ts":%s,"duration_seconds":%s,"exit_code":%s}\n' \
        "$(date -u +%s)" "$1" "${2:-0}" >> "$COORDINATOR_TIMINGS_LOG"
}

@test "Issue 2: operator override RALPH_COORDINATOR_TIMEOUT_SECONDS always wins" {
    export RALPH_COORDINATOR_TIMEOUT_SECONDS=99
    _sample 200 0; _sample 200 0; _sample 200 0
    [[ "$(ralph_compute_coordinator_timeout)" == "99" ]]
}

@test "Issue 2: sparse samples fall back to 300 (>= observed p95)" {
    _sample 200 0; _sample 200 0   # 2 < min_samples (3)
    [[ "$(ralph_compute_coordinator_timeout)" == "300" ]]
}

@test "Issue 2: adaptive value floored at 180 (never kills a healthy brief)" {
    _sample 10 0; _sample 10 0; _sample 10 0
    # 10 * 2 = 20, clamped up to the 180 floor.
    [[ "$(ralph_compute_coordinator_timeout)" == "180" ]]
}

@test "Issue 2: ceiling p95 index picks the tail, not the median (small n)" {
    _sample 60 0; _sample 100 0; _sample 250 0
    # Ceiling index → 250 (the tail), ×2 = 500. (Old floor index picked 100 → 200.)
    [[ "$(ralph_compute_coordinator_timeout)" == "500" ]]
}

@test "Issue 2: a timed-out (censored) tail sample is inflated 1.5x before x2" {
    _sample 40 0; _sample 50 0; _sample 60 0; _sample 70 0; _sample 100 124
    # Censored 100 → 150, tail sample ×2 = 300. (Face value would be 100×2=200.)
    [[ "$(ralph_compute_coordinator_timeout)" == "300" ]]
}

@test "Issue 2: success-only control — same durations are NOT inflated" {
    _sample 40 0; _sample 50 0; _sample 60 0; _sample 70 0; _sample 100 0
    # No censoring → 100×2 = 200 (still above the 180 floor).
    [[ "$(ralph_compute_coordinator_timeout)" == "200" ]]
}

@test "Issue 2: adaptive value clamped at the 600 ceiling" {
    _sample 400 0; _sample 500 0; _sample 600 0
    [[ "$(ralph_compute_coordinator_timeout)" == "600" ]]
}

# =============================================================================
# Phase attribution (synthesis vs brain recall)
# =============================================================================

@test "Issue 2: phase timing attributes a multi-second total to synthesis" {
    local stream="$TEST_TEMP_DIR/coord_stream.jsonl"
    cat > "$stream" <<'JSON'
{"type":"tool_use","name":"mcp__tapps-brain__brain_recall"}
{"type":"tool_use","name":"Read"}
{"type":"tool_use","name":"Write"}
JSON
    ralph_record_coordinator_phase_timing "$stream" 210 0 "brief"
    [[ -f "$COORDINATOR_PHASE_TIMINGS_LOG" ]] || fail "phase log not written"
    run jq -e '.dominant_phase == "synthesis" and .brain_recall_invoked == true and .total_seconds == 210 and .tool_calls == 3 and .brain_recall_calls == 1' \
        "$COORDINATOR_PHASE_TIMINGS_LOG"
    [[ "$status" -eq 0 ]] || fail "unexpected phase line: $(cat "$COORDINATOR_PHASE_TIMINGS_LOG")"
}

@test "Issue 2: phase timing labels a sub-5s run as startup" {
    local stream="$TEST_TEMP_DIR/coord_stream2.jsonl"
    printf '%s\n' '{"type":"tool_use","name":"Read"}' > "$stream"
    ralph_record_coordinator_phase_timing "$stream" 3 0 "brief"
    run jq -e '.dominant_phase == "startup" and .brain_recall_invoked == false' \
        "$COORDINATOR_PHASE_TIMINGS_LOG"
    [[ "$status" -eq 0 ]] || fail "unexpected phase line: $(cat "$COORDINATOR_PHASE_TIMINGS_LOG")"
}
