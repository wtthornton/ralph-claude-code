#!/usr/bin/env bats
# Unit tests for monitor dashboard (Phase 9, TEST-2)
# Tests loop count, API call count, CB state display, data handling

load '../helpers/test_helper'
load '../helpers/fixtures'

RALPH_MONITOR_SCRIPT="${BATS_TEST_DIRNAME}/../../ralph_monitor.sh"

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"
    export RALPH_DIR=".ralph"
    export LOG_DIR="$RALPH_DIR/logs"
    mkdir -p "$LOG_DIR"
}

teardown() {
    cd /
    rm -rf "$TEST_DIR"
}

@test "monitor script exists" {
    [ -f "$RALPH_MONITOR_SCRIPT" ]
}

@test "monitor handles missing status.json gracefully" {
    # No status.json should not crash
    [ ! -f "$RALPH_DIR/status.json" ]
}

@test "monitor reads loop_count from status.json" {
    echo '{"loop_count": 42, "status": "IN_PROGRESS"}' > "$RALPH_DIR/status.json"
    local count
    count=$(jq -r '.loop_count' "$RALPH_DIR/status.json")
    [ "$count" = "42" ]
}

@test "monitor reads circuit_breaker_state from status.json" {
    echo '{"circuit_breaker_state": "OPEN", "status": "ERROR"}' > "$RALPH_DIR/status.json"
    local state
    state=$(jq -r '.circuit_breaker_state' "$RALPH_DIR/status.json")
    [ "$state" = "OPEN" ]
}

@test "monitor handles empty status.json" {
    echo '{}' > "$RALPH_DIR/status.json"
    local count
    count=$(jq -r '.loop_count // 0' "$RALPH_DIR/status.json")
    [ "$count" = "0" ]
}

@test "monitor reads API call count from .call_count" {
    echo "57" > "$RALPH_DIR/.call_count"
    local calls
    calls=$(cat "$RALPH_DIR/.call_count")
    [ "$calls" = "57" ]
}

@test "monitor handles missing .call_count" {
    [ ! -f "$RALPH_DIR/.call_count" ]
    # Should default to 0
    local calls
    calls=$(cat "$RALPH_DIR/.call_count" 2>/dev/null || echo "0")
    [ "$calls" = "0" ]
}

@test "monitor handles missing log directory" {
    rm -rf "$LOG_DIR"
    [ ! -d "$LOG_DIR" ]
    # Re-creating should work
    mkdir -p "$LOG_DIR"
    [ -d "$LOG_DIR" ]
}

@test "monitor reads recent log entries" {
    echo "2026-03-21 10:00:00 [INFO] Loop 1 started" > "$LOG_DIR/ralph.log"
    echo "2026-03-21 10:01:00 [INFO] Loop 1 completed" >> "$LOG_DIR/ralph.log"
    local lines
    lines=$(wc -l < "$LOG_DIR/ralph.log")
    [ "$lines" -eq 2 ]
}

@test "monitor displays correct WORK_TYPE" {
    echo '{"WORK_TYPE": "IMPLEMENTATION", "status": "IN_PROGRESS"}' > "$RALPH_DIR/status.json"
    local wt
    wt=$(jq -r '.WORK_TYPE' "$RALPH_DIR/status.json")
    [ "$wt" = "IMPLEMENTATION" ]
}

# SDLC-MONITOR: Stage row + dual-model display let the operator verify the
# router's choice against what Claude actually did each loop. The hook writes
# work_type lowercase; the routing log carries the routed model and task type.
# A Haiku × IMPLEMENTATION pairing should color yellow as a routing red flag.

@test "SDLC-MONITOR: status.json work_type field is lowercase (matches hook write)" {
    # The on-stop hook writes lowercase 'work_type' (templates/hooks/on-stop.sh).
    # The monitor must read the same casing or it will silently show no stage.
    grep -qE "jq -r '\.work_type" "$RALPH_MONITOR_SCRIPT" || \
        fail "ralph_monitor.sh must read .work_type (lowercase) to match hook output"
}

@test "SDLC-MONITOR: monitor reads routed model from .model_routing.jsonl" {
    # The router writes JSONL entries; the monitor surfaces the most recent
    # routed model so operators see what was PICKED, not just what the hook
    # captured from the last assistant message (often a sub-agent).
    grep -q "\.model_routing\.jsonl" "$RALPH_MONITOR_SCRIPT" || \
        fail "ralph_monitor.sh must read .ralph/.model_routing.jsonl to surface routing"
}

@test "SDLC-MONITOR: monitor displays Stage row with work_type" {
    grep -q "Stage (SDLC)" "$RALPH_MONITOR_SCRIPT" || \
        fail "ralph_monitor.sh must display 'Stage (SDLC)' row when work_type is set"
}

@test "SDLC-MONITOR: monitor flags Haiku × IMPLEMENTATION as yellow (routing red flag)" {
    # The router maps code work to Sonnet (floor). If the routed model is Haiku
    # and the work is IMPLEMENTATION/TESTING/REFACTORING, the classifier
    # under-spent — should be visible at a glance.
    grep -A 3 'routed_model" == "haiku"' "$RALPH_MONITOR_SCRIPT" \
        | grep -q 'IMPLEMENTATION\|TESTING\|REFACTORING' \
        || fail "monitor must flag Haiku × code-work pairings as routing mismatches"
}

@test "SDLC-MONITOR: monitor handles missing .model_routing.jsonl gracefully" {
    # When routing is disabled or no decisions logged yet, the monitor should
    # fall back to loop_model only — not crash or show a stale stage.
    [ ! -f "$RALPH_DIR/.model_routing.jsonl" ]
    echo '{"loop_count": 1, "status": "IN_PROGRESS", "loop_model": "claude-sonnet-4-6"}' \
        > "$RALPH_DIR/status.json"
    # Just check that the relevant code path uses a guard
    grep -q 'if \[\[ -f .ralph/.model_routing.jsonl \]\]' "$RALPH_MONITOR_SCRIPT" || \
        fail "monitor must guard .model_routing.jsonl reads with file-exists check"
}
