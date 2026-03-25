#!/usr/bin/env bats
# Unit Tests for Circuit Breaker Auto-Recovery (Issue #160)
# Tests cooldown timer, auto-reset, and parse_iso_to_epoch

load '../helpers/test_helper'

SCRIPT_DIR="${BATS_TEST_DIRNAME}/../../lib"

setup() {
    # Create temp test directory
    export TEST_TEMP_DIR="$(mktemp -d)"
    cd "$TEST_TEMP_DIR"

    export RALPH_DIR=".ralph"
    export CB_STATE_FILE="$RALPH_DIR/.circuit_breaker_state"
    export CB_HISTORY_FILE="$RALPH_DIR/.circuit_breaker_history"
    export RESPONSE_ANALYSIS_FILE="$RALPH_DIR/.response_analysis"
    mkdir -p "$RALPH_DIR"

    # Source the actual library files
    source "$SCRIPT_DIR/date_utils.sh"
    source "$SCRIPT_DIR/circuit_breaker.sh"
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR"
}

# Helper: Create an OPEN state file with a specific opened_at timestamp
create_open_state() {
    local opened_at="${1:-$(get_iso_timestamp)}"
    local total_opens="${2:-1}"
    cat > "$CB_STATE_FILE" << EOF
{
    "state": "OPEN",
    "last_change": "$(get_iso_timestamp)",
    "consecutive_no_progress": 5,
    "consecutive_same_error": 0,
    "consecutive_permission_denials": 0,
    "last_progress_loop": 2,
    "total_opens": $total_opens,
    "reason": "No progress detected in 5 consecutive loops",
    "current_loop": 7,
    "opened_at": "$opened_at"
}
EOF
    echo '[]' > "$CB_HISTORY_FILE"
}

# Helper: Create an OPEN state file WITHOUT opened_at (old format)
create_old_format_open_state() {
    local last_change="${1:-$(get_iso_timestamp)}"
    cat > "$CB_STATE_FILE" << EOF
{
    "state": "OPEN",
    "last_change": "$last_change",
    "consecutive_no_progress": 5,
    "consecutive_same_error": 0,
    "consecutive_permission_denials": 0,
    "last_progress_loop": 2,
    "total_opens": 1,
    "reason": "No progress detected in 5 consecutive loops",
    "current_loop": 7
}
EOF
    echo '[]' > "$CB_HISTORY_FILE"
}

# Helper: Create a CLOSED state file
create_closed_state() {
    cat > "$CB_STATE_FILE" << EOF
{
    "state": "CLOSED",
    "last_change": "$(get_iso_timestamp)",
    "consecutive_no_progress": 0,
    "consecutive_same_error": 0,
    "consecutive_permission_denials": 0,
    "last_progress_loop": 0,
    "total_opens": 0,
    "reason": ""
}
EOF
    echo '[]' > "$CB_HISTORY_FILE"
}

# Helper: Get ISO timestamp for N minutes ago
get_past_timestamp() {
    local minutes_ago=$1
    local seconds_ago=$((minutes_ago * 60))
    local past_epoch=$(($(date +%s) - seconds_ago))
    # Use GNU date if available, otherwise BSD date
    if date -d "@$past_epoch" -Iseconds 2>/dev/null; then
        return
    fi
    date -u -r "$past_epoch" +"%Y-%m-%dT%H:%M:%S+00:00" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%S+00:00"
}

# =============================================================================
# COOLDOWN TIMER TESTS
# =============================================================================

@test "OPEN state with cooldown NOT elapsed stays OPEN" {
    # Opened 10 minutes ago, cooldown is 30 minutes
    local recent_timestamp
    recent_timestamp=$(get_past_timestamp 10)
    create_open_state "$recent_timestamp"
    export CB_COOLDOWN_MINUTES=30
    export CB_AUTO_RESET=false

    init_circuit_breaker

    local state
    state=$(jq -r '.state' "$CB_STATE_FILE")
    [[ "$state" == "OPEN" ]]
}

@test "OPEN state with cooldown elapsed transitions to HALF_OPEN" {
    # Opened 35 minutes ago, cooldown is 30 minutes
    local old_timestamp
    old_timestamp=$(get_past_timestamp 35)
    create_open_state "$old_timestamp"
    export CB_COOLDOWN_MINUTES=30
    export CB_AUTO_RESET=false

    init_circuit_breaker

    local state
    state=$(jq -r '.state' "$CB_STATE_FILE")
    [[ "$state" == "HALF_OPEN" ]]
}

@test "Cooldown recovery logs transition in history" {
    local old_timestamp
    old_timestamp=$(get_past_timestamp 35)
    create_open_state "$old_timestamp"
    export CB_COOLDOWN_MINUTES=30
    export CB_AUTO_RESET=false

    init_circuit_breaker

    # Check history has a transition entry
    local history_count
    history_count=$(jq 'length' "$CB_HISTORY_FILE")
    [[ $history_count -ge 1 ]]

    # Verify the transition details
    local from_state to_state
    from_state=$(jq -r '.[-1].from_state' "$CB_HISTORY_FILE")
    to_state=$(jq -r '.[-1].to_state' "$CB_HISTORY_FILE")
    [[ "$from_state" == "OPEN" ]]
    [[ "$to_state" == "HALF_OPEN" ]]
}

@test "HALF_OPEN from cooldown + progress recovers to CLOSED" {
    skip "record_loop_result removed (SKILLS-5) — progress detection handled by on-stop.sh hook"
}

@test "HALF_OPEN from cooldown + no progress re-trips to OPEN" {
    skip "record_loop_result removed (SKILLS-5) — progress detection handled by on-stop.sh hook"
}

@test "CB_COOLDOWN_MINUTES=0 means immediate recovery attempt" {
    # Opened just now, but cooldown is 0
    create_open_state "$(get_iso_timestamp)"
    export CB_COOLDOWN_MINUTES=0
    export CB_AUTO_RESET=false

    init_circuit_breaker

    local state
    state=$(jq -r '.state' "$CB_STATE_FILE")
    [[ "$state" == "HALF_OPEN" ]]
}

@test "Old state file without opened_at falls back to last_change" {
    # Create old-format state file (no opened_at field)
    local old_timestamp
    old_timestamp=$(get_past_timestamp 35)
    create_old_format_open_state "$old_timestamp"
    export CB_COOLDOWN_MINUTES=30
    export CB_AUTO_RESET=false

    init_circuit_breaker

    # Should still recover using last_change as fallback
    local state
    state=$(jq -r '.state' "$CB_STATE_FILE")
    [[ "$state" == "HALF_OPEN" ]]
}

@test "Clock skew (negative elapsed time) stays OPEN safely" {
    # Create state with a future timestamp (simulating clock skew)
    local future_epoch=$(($(date +%s) + 7200))
    local future_timestamp
    if future_timestamp=$(date -d "@$future_epoch" -Iseconds 2>/dev/null); then
        : # success
    else
        future_timestamp=$(date -u -r "$future_epoch" +"%Y-%m-%dT%H:%M:%S+00:00" 2>/dev/null || skip "Cannot create future timestamp")
    fi
    create_open_state "$future_timestamp"
    export CB_COOLDOWN_MINUTES=30
    export CB_AUTO_RESET=false

    init_circuit_breaker

    # Should stay OPEN due to negative elapsed time
    local state
    state=$(jq -r '.state' "$CB_STATE_FILE")
    [[ "$state" == "OPEN" ]]
}

# =============================================================================
# AUTO-RESET TESTS
# =============================================================================

@test "CB_AUTO_RESET=true resets OPEN to CLOSED on init" {
    create_open_state "$(get_iso_timestamp)"
    export CB_AUTO_RESET=true

    init_circuit_breaker

    local state
    state=$(jq -r '.state' "$CB_STATE_FILE")
    [[ "$state" == "CLOSED" ]]
}

@test "CB_AUTO_RESET=true preserves total_opens count" {
    create_open_state "$(get_iso_timestamp)" 3
    export CB_AUTO_RESET=true

    init_circuit_breaker

    local total_opens
    total_opens=$(jq -r '.total_opens' "$CB_STATE_FILE")
    [[ "$total_opens" == "3" ]]
}

@test "CB_AUTO_RESET=true logs transition in history" {
    create_open_state "$(get_iso_timestamp)"
    export CB_AUTO_RESET=true

    init_circuit_breaker

    local history_count
    history_count=$(jq 'length' "$CB_HISTORY_FILE")
    [[ $history_count -ge 1 ]]

    local to_state reason
    to_state=$(jq -r '.[-1].to_state' "$CB_HISTORY_FILE")
    reason=$(jq -r '.[-1].reason' "$CB_HISTORY_FILE")
    [[ "$to_state" == "CLOSED" ]]
    [[ "$reason" == *"Auto-reset"* ]]
}

@test "CB_AUTO_RESET=false (default) uses normal cooldown behavior" {
    # Opened recently, cooldown not elapsed
    create_open_state "$(get_iso_timestamp)"
    export CB_AUTO_RESET=false
    export CB_COOLDOWN_MINUTES=30

    init_circuit_breaker

    local state
    state=$(jq -r '.state' "$CB_STATE_FILE")
    [[ "$state" == "OPEN" ]]
}

@test "CLOSED state is not affected by auto-recovery logic" {
    create_closed_state
    export CB_AUTO_RESET=true
    export CB_COOLDOWN_MINUTES=0

    init_circuit_breaker

    local state
    state=$(jq -r '.state' "$CB_STATE_FILE")
    [[ "$state" == "CLOSED" ]]
}

# =============================================================================
# opened_at FIELD TESTS
# =============================================================================

@test "Entering OPEN state sets opened_at field" {
    skip "record_loop_result removed (SKILLS-5) — state transitions handled by on-stop.sh hook"
}

@test "Staying OPEN preserves opened_at field" {
    # Use a recent timestamp (5 minutes ago) so cooldown doesn't trigger
    local fixed_timestamp
    fixed_timestamp=$(get_past_timestamp 5)
    create_open_state "$fixed_timestamp"
    export CB_COOLDOWN_MINUTES=30

    # Record another result while OPEN
    record_loop_result 8 0 "false" 100 || true

    local opened_at
    opened_at=$(jq -r '.opened_at' "$CB_STATE_FILE")
    [[ "$opened_at" == "$fixed_timestamp" ]]
}

# =============================================================================
# parse_iso_to_epoch TESTS
# =============================================================================

@test "parse_iso_to_epoch handles valid ISO timestamp" {
    local result
    result=$(parse_iso_to_epoch "2025-01-15T10:30:00+00:00")
    [[ "$result" =~ ^[0-9]+$ ]]

    # Should be roughly in the right range (2025 is ~1736899200 epoch)
    [[ $result -gt 1700000000 ]]
    [[ $result -lt 1800000000 ]]
}

@test "parse_iso_to_epoch handles empty input with safe fallback" {
    local result current_epoch
    current_epoch=$(date +%s)
    result=$(parse_iso_to_epoch "")

    [[ "$result" =~ ^[0-9]+$ ]]
    # Should be close to current time (within 5 seconds)
    local diff=$(( result - current_epoch ))
    [[ ${diff#-} -lt 5 ]]
}

@test "parse_iso_to_epoch handles null input with safe fallback" {
    local result current_epoch
    current_epoch=$(date +%s)
    result=$(parse_iso_to_epoch "null")

    [[ "$result" =~ ^[0-9]+$ ]]
    local diff=$(( result - current_epoch ))
    [[ ${diff#-} -lt 5 ]]
}

# =============================================================================
# CLI FLAG TEST
# =============================================================================

@test "--auto-reset-circuit flag sets CB_AUTO_RESET=true" {
    local RALPH_SCRIPT="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

    # Create minimal environment for CLI parsing
    local CLI_TEST_DIR
    CLI_TEST_DIR="$(mktemp -d)"
    cd "$CLI_TEST_DIR"

    git init > /dev/null 2>&1
    git config user.email "test@example.com"
    git config user.name "Test User"

    export RALPH_DIR=".ralph"
    mkdir -p "$RALPH_DIR/logs"
    echo "# Test Prompt" > "$RALPH_DIR/PROMPT.md"
    echo "0" > "$RALPH_DIR/.call_count"
    echo "$(date +%Y%m%d%H)" > "$RALPH_DIR/.last_reset"
    echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": []}' > "$RALPH_DIR/.exit_signals"

    mkdir -p lib
    cat > lib/circuit_breaker.sh << 'CBEOF'
RALPH_DIR="${RALPH_DIR:-.ralph}"
CB_AUTO_RESET="${CB_AUTO_RESET:-false}"
reset_circuit_breaker() { echo "Circuit breaker reset: $1"; }
show_circuit_status() { echo "Circuit breaker status: CLOSED"; }
init_circuit_breaker() { :; }
record_loop_result() { :; }
CBEOF

    cat > lib/date_utils.sh << 'DUEOF'
get_iso_timestamp() { date -Iseconds 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S'; }
get_epoch_timestamp() { date +%s; }
DUEOF

    cat > lib/timeout_utils.sh << 'TUEOF'
portable_timeout() { shift; "$@"; }
TUEOF

    # Run with --auto-reset-circuit --help to parse the flag and exit
    run bash "$RALPH_SCRIPT" --auto-reset-circuit --help

    assert_success
    [[ "$output" == *"Usage:"* ]]
    # Verify the flag is documented in help
    [[ "$output" == *"--auto-reset-circuit"* ]]

    # Cleanup
    cd /
    rm -rf "$CLI_TEST_DIR"
}

# --- Current Loop Display Fix (Issue #194) ---

@test "init_circuit_breaker creates valid state file" {
    # Fresh init should create a valid state file
    rm -f "$CB_STATE_FILE"
    init_circuit_breaker

    local state
    state=$(jq -r '.state' "$CB_STATE_FILE")
    assert_equal "$state" "CLOSED"
}

@test "reset_circuit_breaker creates valid state file" {
    # After reset, state should be CLOSED
    reset_circuit_breaker "test reset"

    local state
    state=$(jq -r '.state' "$CB_STATE_FILE")
    assert_equal "$state" "CLOSED"
}

@test "show_circuit_status uses fallback for missing current_loop" {
    # Old state files without current_loop should show "N/A" not "null"
    cat > "$CB_STATE_FILE" << EOF
{
    "state": "$CB_STATE_CLOSED",
    "last_change": "$(get_iso_timestamp)",
    "consecutive_no_progress": 0,
    "consecutive_same_error": 0,
    "consecutive_permission_denials": 0,
    "last_progress_loop": 0,
    "total_opens": 0,
    "reason": ""
}
EOF

    run show_circuit_status
    assert_success
    # Should NOT contain "null" — should show "N/A" or "0"
    [[ "$output" != *"#null"* ]]
}

# =============================================================================
# USYNC-4: Permission Denial Tracking
# =============================================================================

@test "init_circuit_breaker includes consecutive_permission_denials field" {
    init_circuit_breaker

    local pd=$(jq -r '.consecutive_permission_denials // "MISSING"' "$CB_STATE_FILE")
    assert_equal "$pd" "0"
}

@test "reset_circuit_breaker resets consecutive_permission_denials to 0" {
    # Set up state with permission denials
    cat > "$CB_STATE_FILE" << EOF
{
    "state": "OPEN",
    "last_change": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "consecutive_no_progress": 5,
    "consecutive_permission_denials": 3,
    "total_opens": 2,
    "reason": "Permission denied 3 consecutive times"
}
EOF

    reset_circuit_breaker "Test reset"

    local pd=$(jq -r '.consecutive_permission_denials' "$CB_STATE_FILE")
    assert_equal "$pd" "0"

    local state=$(jq -r '.state' "$CB_STATE_FILE")
    assert_equal "$state" "CLOSED"
}

@test "show_circuit_status displays permission denial count when > 0" {
    cat > "$CB_STATE_FILE" << EOF
{
    "state": "CLOSED",
    "last_change": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "consecutive_no_progress": 0,
    "consecutive_permission_denials": 1,
    "total_opens": 0,
    "reason": ""
}
EOF

    run show_circuit_status
    assert_success
    [[ "$output" == *"Permission denials"* ]] || fail "Expected 'Permission denials' in output, got: $output"
    [[ "$output" == *"1 consecutive"* ]] || fail "Expected '1 consecutive' in output, got: $output"
}

@test "show_circuit_status hides permission denial line when count is 0" {
    cat > "$CB_STATE_FILE" << EOF
{
    "state": "CLOSED",
    "last_change": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
    "consecutive_no_progress": 0,
    "consecutive_permission_denials": 0,
    "total_opens": 0,
    "reason": ""
}
EOF

    run show_circuit_status
    assert_success
    [[ "$output" != *"Permission denials"* ]] || fail "Should not show 'Permission denials' when count is 0"
}
