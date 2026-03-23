#!/usr/bin/env bats
# tests/evals/deterministic/test_hooks.bats
# EVALS-2: Verifies hook execution, specifically that on-stop.sh produces
# valid status.json from mock input.
#
# The on-stop.sh hook:
#   - Reads Claude's response from stdin (JSON)
#   - Extracts RALPH_STATUS fields
#   - Writes .ralph/status.json
#   - Updates circuit breaker state
#
# These tests verify hook behavior WITHOUT making any LLM calls.

load '../../helpers/test_helper'

PROJECT_ROOT="${BATS_TEST_DIRNAME}/../../.."
ON_STOP="${PROJECT_ROOT}/templates/hooks/on-stop.sh"

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"

    export RALPH_DIR=".ralph"
    export CLAUDE_PROJECT_DIR="$TEST_DIR"
    export STATUS_FILE="$RALPH_DIR/status.json"
    mkdir -p "$RALPH_DIR/logs"

    # Ensure on-stop.sh exists
    [[ -f "$ON_STOP" ]] || skip "on-stop.sh not found"

    # Initialize circuit breaker state
    cat > "$RALPH_DIR/.circuit_breaker_state" <<'EOF'
{
    "state": "CLOSED",
    "last_change": "2026-03-23T00:00:00Z",
    "consecutive_no_progress": 0,
    "consecutive_same_error": 0,
    "consecutive_permission_denials": 0,
    "last_progress_loop": 0,
    "total_opens": 0,
    "reason": ""
}
EOF
}

teardown() {
    if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
        cd /
        rm -rf "$TEST_DIR"
    fi
}

# Helper: simulate on-stop.sh with a mock response containing RALPH_STATUS block
run_on_stop_with_status() {
    local exit_signal="${1:-false}"
    local status="${2:-IN_PROGRESS}"
    local tasks_done="${3:-0}"
    local files_modified="${4:-0}"
    local work_type="${5:-IMPLEMENTATION}"
    local recommendation="${6:-Continue working}"

    local mock_response
    mock_response=$(cat <<RESP_EOF
Here is my analysis of the changes made.

---RALPH_STATUS---
EXIT_SIGNAL: $exit_signal
STATUS: $status
TASKS_COMPLETED_THIS_LOOP: $tasks_done
FILES_MODIFIED: $files_modified
WORK_TYPE: $work_type
RECOMMENDATION: $recommendation
---END_RALPH_STATUS---
RESP_EOF
)

    local input_json
    input_json=$(jq -n --arg result "$mock_response" '{"result": $result}')
    echo "$input_json" | bash "$ON_STOP"
}

# Helper: simulate on-stop.sh with a raw text response (no RALPH_STATUS block)
run_on_stop_with_text() {
    local text="$1"
    local input_json
    input_json=$(jq -n --arg result "$text" '{"result": $result}')
    echo "$input_json" | bash "$ON_STOP"
}

# =============================================================================
# STATUS.JSON PRODUCTION FROM RALPH_STATUS BLOCK
# =============================================================================

@test "HOOKS: on-stop.sh produces valid status.json from RALPH_STATUS block" {
    run run_on_stop_with_status "true" "COMPLETE" 3 5 "IMPLEMENTATION" "All tasks done"
    assert_success

    # Verify status.json exists and is valid JSON
    [[ -f "$STATUS_FILE" ]]
    jq empty "$STATUS_FILE"
}

@test "HOOKS: on-stop.sh extracts exit_signal correctly" {
    run_on_stop_with_status "true" "COMPLETE" 1 2 "IMPLEMENTATION"

    local actual
    actual=$(jq -r '.exit_signal' "$STATUS_FILE")
    assert_equal "$actual" "true"
}

@test "HOOKS: on-stop.sh extracts exit_signal=false correctly" {
    run_on_stop_with_status "false" "IN_PROGRESS" 1 2 "IMPLEMENTATION"

    local actual
    actual=$(jq -r '.exit_signal' "$STATUS_FILE")
    assert_equal "$actual" "false"
}

@test "HOOKS: on-stop.sh extracts work_type correctly" {
    run_on_stop_with_status "false" "IN_PROGRESS" 0 1 "TESTING"

    local actual
    actual=$(jq -r '.work_type' "$STATUS_FILE")
    assert_equal "$actual" "TESTING"
}

@test "HOOKS: on-stop.sh extracts tasks_completed correctly" {
    run_on_stop_with_status "false" "IN_PROGRESS" 5 3 "IMPLEMENTATION"

    local actual
    actual=$(jq -r '.tasks_completed' "$STATUS_FILE")
    assert_equal "$actual" "5"
}

@test "HOOKS: on-stop.sh extracts files_modified correctly" {
    run_on_stop_with_status "false" "IN_PROGRESS" 2 7 "IMPLEMENTATION"

    local actual
    actual=$(jq -r '.files_modified' "$STATUS_FILE")
    # files_modified is max of reported vs actual tracked files
    # Since we have no .files_modified_this_loop tracker, reported value is used
    [[ "$actual" -ge 7 ]]
}

@test "HOOKS: on-stop.sh increments loop_count" {
    # Run twice — loop_count should increment
    run_on_stop_with_status "false" "IN_PROGRESS" 1 1 "IMPLEMENTATION"
    local count1
    count1=$(jq -r '.loop_count' "$STATUS_FILE")

    run_on_stop_with_status "false" "IN_PROGRESS" 1 1 "IMPLEMENTATION"
    local count2
    count2=$(jq -r '.loop_count' "$STATUS_FILE")

    [[ "$count2" -gt "$count1" ]]
}

@test "HOOKS: on-stop.sh writes timestamp" {
    run_on_stop_with_status "false" "IN_PROGRESS" 0 0 "UNKNOWN"

    local ts
    ts=$(jq -r '.timestamp' "$STATUS_FILE")
    [[ -n "$ts" ]]
    [[ "$ts" != "null" ]]
}

# =============================================================================
# FALLBACK BEHAVIOR (no RALPH_STATUS block)
# =============================================================================

@test "HOOKS: on-stop.sh defaults to exit_signal=false when no RALPH_STATUS block" {
    run_on_stop_with_text "I made some progress on the task. Continuing with the next step."

    local actual
    actual=$(jq -r '.exit_signal' "$STATUS_FILE")
    assert_equal "$actual" "false"
}

@test "HOOKS: on-stop.sh defaults to work_type=UNKNOWN when no RALPH_STATUS block" {
    run_on_stop_with_text "I finished some work on the feature."

    local actual
    actual=$(jq -r '.work_type' "$STATUS_FILE")
    # May be UNKNOWN or inferred to IMPLEMENTATION if files were modified
    [[ "$actual" == "UNKNOWN" || "$actual" == "IMPLEMENTATION" ]]
}

@test "HOOKS: on-stop.sh still produces valid JSON with empty response" {
    run_on_stop_with_text ""

    [[ -f "$STATUS_FILE" ]]
    jq empty "$STATUS_FILE"
}

# =============================================================================
# CIRCUIT BREAKER UPDATES
# =============================================================================

@test "HOOKS: on-stop.sh resets CB no-progress on files_modified > 0" {
    # Set CB to have some no-progress
    cat > "$RALPH_DIR/.circuit_breaker_state" <<'EOF'
{
    "state": "CLOSED",
    "last_change": "2026-03-23T00:00:00Z",
    "consecutive_no_progress": 2,
    "consecutive_same_error": 0,
    "consecutive_permission_denials": 0,
    "last_progress_loop": 0,
    "total_opens": 0,
    "reason": ""
}
EOF

    run_on_stop_with_status "false" "IN_PROGRESS" 1 3 "IMPLEMENTATION"

    local no_progress
    no_progress=$(jq -r '.consecutive_no_progress' "$RALPH_DIR/.circuit_breaker_state")
    assert_equal "$no_progress" "0"
}

@test "HOOKS: on-stop.sh increments CB no-progress when no files modified and no tasks done" {
    cat > "$RALPH_DIR/.circuit_breaker_state" <<'EOF'
{
    "state": "CLOSED",
    "last_change": "2026-03-23T00:00:00Z",
    "consecutive_no_progress": 1,
    "consecutive_same_error": 0,
    "consecutive_permission_denials": 0,
    "last_progress_loop": 0,
    "total_opens": 0,
    "reason": ""
}
EOF

    run_on_stop_with_status "false" "IN_PROGRESS" 0 0 "UNKNOWN"

    local no_progress
    no_progress=$(jq -r '.consecutive_no_progress' "$RALPH_DIR/.circuit_breaker_state")
    assert_equal "$no_progress" "2"
}

# =============================================================================
# JSON-ESCAPED RALPH_STATUS (STREAM-3 compatibility)
# =============================================================================

@test "HOOKS: on-stop.sh handles JSON-escaped RALPH_STATUS (literal backslash-n)" {
    # Simulates response from JSONL stream extraction where newlines are literal \n
    local escaped_response='Some text\n---RALPH_STATUS---\nEXIT_SIGNAL: true\nSTATUS: COMPLETE\nTASKS_COMPLETED_THIS_LOOP: 2\nFILES_MODIFIED: 3\nWORK_TYPE: IMPLEMENTATION\nRECOMMENDATION: Done\n---END_RALPH_STATUS---'

    local input_json
    input_json=$(jq -n --arg result "$escaped_response" '{"result": $result}')
    echo "$input_json" | bash "$ON_STOP"

    local exit_signal
    exit_signal=$(jq -r '.exit_signal' "$STATUS_FILE")
    assert_equal "$exit_signal" "true"
}
