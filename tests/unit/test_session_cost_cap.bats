#!/usr/bin/env bats
# TAP-2500: opt-in per-session cost hard-cap kill switch.
#
# Tests the bash-level conditional that drives the halt — we run a tiny
# wrapper script that exercises the same code path ralph_loop.sh main loop
# uses (read session_cost_usd from status.json, compare against the env cap,
# write .cost_cap_hit sentinel, exit).

bats_require_minimum_version 1.5.0
load '../helpers/test_helper'

REPO_ROOT="${BATS_TEST_DIRNAME}/../.."

setup() {
    export TEST_TEMP_DIR="$(mktemp -d)"
    cd "$TEST_TEMP_DIR"
    export RALPH_DIR="$TEST_TEMP_DIR/.ralph"
    mkdir -p "$RALPH_DIR"
    # Stub status.json with configurable session_cost_usd
    cat > "$RALPH_DIR/status.json" <<EOF
{"session_cost_usd": 5.0}
EOF
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR"
}

# Helper: exercise the same conditional used in ralph_loop.sh main loop.
# Returns 0 if the cap would trigger a halt, 1 otherwise; writes the sentinel.
_run_cap_check() {
    local _sess_cost _cap_hit
    [[ -z "${RALPH_SESSION_COST_HARD_CAP_USD:-}" ]] && return 1
    _sess_cost=$(jq -r '.session_cost_usd // 0' "$RALPH_DIR/status.json" 2>/dev/null)
    _cap_hit=$(awk -v c="$_sess_cost" -v cap="$RALPH_SESSION_COST_HARD_CAP_USD" 'BEGIN { print (c+0 >= cap+0) ? "1" : "0" }')
    if [[ "$_cap_hit" == "1" ]]; then
        printf '%s' "$_sess_cost" > "$RALPH_DIR/.cost_cap_hit"
        return 0
    fi
    return 1
}

# =============================================================================
# 1. Cost below cap → no halt, no sentinel
# =============================================================================
@test "TAP-2500: session_cost=5 < cap=10 → continues, no sentinel" {
    export RALPH_SESSION_COST_HARD_CAP_USD=10
    run _run_cap_check
    assert_failure
    [[ ! -f "$RALPH_DIR/.cost_cap_hit" ]] || { echo "sentinel should be absent"; return 1; }
}

# =============================================================================
# 2. Cost over cap → halt + sentinel
# =============================================================================
@test "TAP-2500: session_cost=12 > cap=10 → halt with sentinel" {
    # Bump cost
    jq '.session_cost_usd = 12' "$RALPH_DIR/status.json" > "$RALPH_DIR/status.tmp" && mv "$RALPH_DIR/status.tmp" "$RALPH_DIR/status.json"
    export RALPH_SESSION_COST_HARD_CAP_USD=10
    run _run_cap_check
    assert_success
    [[ -f "$RALPH_DIR/.cost_cap_hit" ]] || { echo "sentinel should be present"; return 1; }
    local _saved
    _saved=$(cat "$RALPH_DIR/.cost_cap_hit")
    [[ "$_saved" == "12" ]] || { echo "expected 12 in sentinel, got $_saved"; return 1; }
}

# =============================================================================
# 3. Cost exactly at cap → halt (>= semantics)
# =============================================================================
@test "TAP-2500: session_cost=10 == cap=10 → halt fires (>= semantics)" {
    jq '.session_cost_usd = 10' "$RALPH_DIR/status.json" > "$RALPH_DIR/status.tmp" && mv "$RALPH_DIR/status.tmp" "$RALPH_DIR/status.json"
    export RALPH_SESSION_COST_HARD_CAP_USD=10
    run _run_cap_check
    assert_success
}

# =============================================================================
# 4. Cap unset → no halt regardless of cost (default-off)
# =============================================================================
@test "TAP-2500: RALPH_SESSION_COST_HARD_CAP_USD unset → no halt at any cost" {
    jq '.session_cost_usd = 100' "$RALPH_DIR/status.json" > "$RALPH_DIR/status.tmp" && mv "$RALPH_DIR/status.tmp" "$RALPH_DIR/status.json"
    unset RALPH_SESSION_COST_HARD_CAP_USD
    run _run_cap_check
    assert_failure
}

# =============================================================================
# 5. Fractional cap values work (awk-based float comparison)
# =============================================================================
@test "TAP-2500: session_cost=1.5 > cap=1.0 (fractional comparison)" {
    jq '.session_cost_usd = 1.5' "$RALPH_DIR/status.json" > "$RALPH_DIR/status.tmp" && mv "$RALPH_DIR/status.tmp" "$RALPH_DIR/status.json"
    export RALPH_SESSION_COST_HARD_CAP_USD=1.0
    run _run_cap_check
    assert_success
}
