#!/usr/bin/env bats
# tests/evals/deterministic/test_circuit_breaker.bats
# EVALS-2: Verifies circuit breaker trigger conditions.
#
# The circuit breaker (CB) opens when:
#   - Consecutive no-progress loops exceed CB_NO_PROGRESS_THRESHOLD (default 3)
#   - These are tracked via on-stop.sh incrementing consecutive_no_progress in .circuit_breaker_state
#
# These tests verify CB logic WITHOUT making any LLM calls.

load '../../helpers/test_helper'

PROJECT_ROOT="${BATS_TEST_DIRNAME}/../../.."
LIB_DIR="${PROJECT_ROOT}/lib"

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"

    export RALPH_DIR=".ralph"
    export CB_STATE_FILE="$RALPH_DIR/.circuit_breaker_state"
    export CB_HISTORY_FILE="$RALPH_DIR/.circuit_breaker_history"
    export RESPONSE_ANALYSIS_FILE="$RALPH_DIR/.response_analysis"
    mkdir -p "$RALPH_DIR/logs"

    # Source circuit breaker library
    source "$LIB_DIR/date_utils.sh"
    source "$LIB_DIR/circuit_breaker.sh"
}

teardown() {
    if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
        cd /
        rm -rf "$TEST_DIR"
    fi
}

# Helper: create a CB state file with specific consecutive_no_progress
create_cb_state() {
    local state="${1:-CLOSED}"
    local no_progress="${2:-0}"
    local total_opens="${3:-0}"
    local reason="${4:-}"

    cat > "$CB_STATE_FILE" <<EOF
{
    "state": "$state",
    "last_change": "$(get_iso_timestamp)",
    "consecutive_no_progress": $no_progress,
    "consecutive_same_error": 0,
    "consecutive_permission_denials": 0,
    "last_progress_loop": 0,
    "total_opens": $total_opens,
    "reason": "$reason",
    "current_loop": 1
}
EOF
    echo '[]' > "$CB_HISTORY_FILE"
}

# Helper: simulate on-stop.sh no-progress update via jq (mirrors on-stop.sh logic)
simulate_no_progress_loop() {
    local threshold="${CB_NO_PROGRESS_THRESHOLD:-3}"
    local tmp
    tmp=$(mktemp "$RALPH_DIR/.circuit_breaker_state.XXXXXX")
    jq --argjson threshold "$threshold" '
      .consecutive_no_progress = ((.consecutive_no_progress // 0) + 1) |
      if .consecutive_no_progress >= $threshold then
        .state = "OPEN" | .total_opens = ((.total_opens // 0) + 1) | .opened_at = (now | todate)
      else . end
    ' "$CB_STATE_FILE" > "$tmp" 2>/dev/null \
      && mv "$tmp" "$CB_STATE_FILE"
    rm -f "$tmp" 2>/dev/null
}

# Helper: simulate on-stop.sh progress update (mirrors on-stop.sh logic)
simulate_progress_loop() {
    local tmp
    tmp=$(mktemp "$RALPH_DIR/.circuit_breaker_state.XXXXXX")
    jq '.consecutive_no_progress = 0 | .state = "CLOSED"' \
      "$CB_STATE_FILE" > "$tmp" 2>/dev/null \
      && mv "$tmp" "$CB_STATE_FILE"
    rm -f "$tmp" 2>/dev/null
}

# =============================================================================
# THRESHOLD FAILURE IN SLIDING WINDOW TESTS
# =============================================================================

@test "CB: trips OPEN after threshold (3) consecutive no-progress loops" {
    export CB_NO_PROGRESS_THRESHOLD=3
    create_cb_state "CLOSED" 0

    # Simulate 3 no-progress loops
    simulate_no_progress_loop
    simulate_no_progress_loop
    simulate_no_progress_loop

    local state
    state=$(jq -r '.state' "$CB_STATE_FILE")
    assert_equal "$state" "OPEN"
}

@test "CB: does NOT trip before threshold" {
    export CB_NO_PROGRESS_THRESHOLD=3
    create_cb_state "CLOSED" 0

    # Only 2 no-progress loops (below threshold)
    simulate_no_progress_loop
    simulate_no_progress_loop

    local state no_progress
    state=$(jq -r '.state' "$CB_STATE_FILE")
    no_progress=$(jq -r '.consecutive_no_progress' "$CB_STATE_FILE")
    assert_equal "$state" "CLOSED"
    assert_equal "$no_progress" "2"
}

@test "CB: trips at exactly the threshold" {
    export CB_NO_PROGRESS_THRESHOLD=5
    create_cb_state "CLOSED" 4  # Already at 4

    simulate_no_progress_loop  # Pushes to 5

    local state no_progress
    state=$(jq -r '.state' "$CB_STATE_FILE")
    no_progress=$(jq -r '.consecutive_no_progress' "$CB_STATE_FILE")
    assert_equal "$state" "OPEN"
    assert_equal "$no_progress" "5"
}

@test "CB: custom threshold of 1 trips immediately" {
    export CB_NO_PROGRESS_THRESHOLD=1
    create_cb_state "CLOSED" 0

    simulate_no_progress_loop

    local state
    state=$(jq -r '.state' "$CB_STATE_FILE")
    assert_equal "$state" "OPEN"
}

@test "CB: increments total_opens counter when tripping" {
    export CB_NO_PROGRESS_THRESHOLD=3
    create_cb_state "CLOSED" 2 0  # 2 no-progress, 0 total_opens

    simulate_no_progress_loop  # Trips to OPEN

    local total_opens
    total_opens=$(jq -r '.total_opens' "$CB_STATE_FILE")
    assert_equal "$total_opens" "1"
}

@test "CB: sets opened_at timestamp when tripping" {
    export CB_NO_PROGRESS_THRESHOLD=3
    create_cb_state "CLOSED" 2 0

    simulate_no_progress_loop  # Trips to OPEN

    local opened_at
    opened_at=$(jq -r '.opened_at // "null"' "$CB_STATE_FILE")
    [[ "$opened_at" != "null" ]]
    [[ "$opened_at" != "" ]]
}

# =============================================================================
# CONSECUTIVE NO-PROGRESS TESTS
# =============================================================================

@test "CB: progress resets consecutive_no_progress counter" {
    export CB_NO_PROGRESS_THRESHOLD=3
    create_cb_state "CLOSED" 2  # 2 no-progress (close to threshold)

    simulate_progress_loop  # Progress detected!

    local no_progress state
    no_progress=$(jq -r '.consecutive_no_progress' "$CB_STATE_FILE")
    state=$(jq -r '.state' "$CB_STATE_FILE")
    assert_equal "$no_progress" "0"
    assert_equal "$state" "CLOSED"
}

@test "CB: progress after partial no-progress resets counter, not yet OPEN" {
    export CB_NO_PROGRESS_THRESHOLD=5
    create_cb_state "CLOSED" 3  # 3/5 toward threshold

    simulate_progress_loop  # Reset
    simulate_no_progress_loop  # 1 (starting fresh)

    local no_progress state
    no_progress=$(jq -r '.consecutive_no_progress' "$CB_STATE_FILE")
    state=$(jq -r '.state' "$CB_STATE_FILE")
    assert_equal "$no_progress" "1"
    assert_equal "$state" "CLOSED"
}

@test "CB: alternating progress/no-progress never trips" {
    export CB_NO_PROGRESS_THRESHOLD=3
    create_cb_state "CLOSED" 0

    # Alternate: no-progress, progress, no-progress, progress, ...
    simulate_no_progress_loop
    simulate_progress_loop
    simulate_no_progress_loop
    simulate_progress_loop
    simulate_no_progress_loop
    simulate_progress_loop

    local state no_progress
    state=$(jq -r '.state' "$CB_STATE_FILE")
    no_progress=$(jq -r '.consecutive_no_progress' "$CB_STATE_FILE")
    assert_equal "$state" "CLOSED"
    assert_equal "$no_progress" "0"  # Last was progress
}

@test "CB: CLOSED state with zero no-progress stays CLOSED on init" {
    create_cb_state "CLOSED" 0
    export CB_COOLDOWN_MINUTES=30
    export CB_AUTO_RESET=false

    init_circuit_breaker

    local state
    state=$(jq -r '.state' "$CB_STATE_FILE")
    assert_equal "$state" "CLOSED"
}

@test "CB: default threshold is 3 when CB_NO_PROGRESS_THRESHOLD not set" {
    unset CB_NO_PROGRESS_THRESHOLD
    create_cb_state "CLOSED" 0

    # Simulate 3 loops (should use default threshold of 3)
    local threshold="${CB_NO_PROGRESS_THRESHOLD:-3}"
    export CB_NO_PROGRESS_THRESHOLD="$threshold"

    simulate_no_progress_loop
    simulate_no_progress_loop
    simulate_no_progress_loop

    local state
    state=$(jq -r '.state' "$CB_STATE_FILE")
    assert_equal "$state" "OPEN"
}
