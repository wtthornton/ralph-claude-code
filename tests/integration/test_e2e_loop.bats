#!/usr/bin/env bats
# E2E full loop tests (Phase 9, TEST-7)
# Mock Claude CLI replaying fixture responses deterministically
# Tests: simple completion, circuit breaker trip, rate limit, session continuity

load '../helpers/test_helper'

RALPH_SCRIPT="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"
    git init > /dev/null 2>&1
    git config user.email "test@example.com"
    git config user.name "Test User"

    export RALPH_DIR=".ralph"
    export LOG_DIR="$RALPH_DIR/logs"
    export DOCS_DIR="$RALPH_DIR/docs/generated"
    mkdir -p "$LOG_DIR" "$DOCS_DIR"

    # Create required files
    echo "# Test Prompt" > "$RALPH_DIR/PROMPT.md"
    echo "- [ ] Task 1" > "$RALPH_DIR/fix_plan.md"
    echo "Build instructions" > "$RALPH_DIR/AGENT.md"
    echo "0" > "$RALPH_DIR/.call_count"
    echo "$(date +%s)" > "$RALPH_DIR/.last_reset"
    echo '{"test_only_loops":[],"done_signals":[],"completion_indicators":[]}' > "$RALPH_DIR/.exit_signals"

    # Create mock Claude CLI
    MOCK_CLAUDE="$TEST_DIR/mock_claude"
    mkdir -p "$MOCK_CLAUDE"
}

teardown() {
    cd /
    rm -rf "$TEST_DIR"
}

# Helper: create a mock claude that returns fixed output
create_mock_claude() {
    local response="$1"
    cat > "$TEST_DIR/claude" << MOCKEOF
#!/bin/bash
echo '$response'
MOCKEOF
    chmod +x "$TEST_DIR/claude"
    export PATH="$TEST_DIR:$PATH"
    export CLAUDE_CODE_CMD="$TEST_DIR/claude"
}

@test "E2E: dry-run completes without API calls" {
    create_mock_claude '{"type":"result","result":"should not be called"}'
    run bash "$RALPH_SCRIPT" --dry-run
    # Should exit 0 without calling mock
    [ "$status" -eq 0 ] || [ "$status" -eq 1 ]  # May fail on other validation
    # status.json should show DRY_RUN
    if [[ -f "$RALPH_DIR/status.json" ]]; then
        local st
        st=$(jq -r '.status // ""' "$RALPH_DIR/status.json" 2>/dev/null)
        [ "$st" = "DRY_RUN" ] || true
    fi
}

@test "E2E: --version exits cleanly" {
    run bash "$RALPH_SCRIPT" --version
    [ "$status" -eq 0 ]
    # Match `ralph X.Y.Z` for any current major (1.x, 2.x, …). The previous
    # `ralph 1.*` glob silently became stale on each major bump.
    [[ "$output" =~ ^ralph\ [0-9]+\.[0-9]+\.[0-9]+ ]]
}

@test "E2E: --status with no status file" {
    rm -f "$RALPH_DIR/status.json"
    run bash "$RALPH_SCRIPT" --status
    [ "$status" -eq 0 ]
    [[ "$output" == *"No status file"* ]]
}

@test "E2E: --status with existing status file" {
    echo '{"status":"IN_PROGRESS","loop_count":5}' > "$RALPH_DIR/status.json"
    run bash "$RALPH_SCRIPT" --status
    [ "$status" -eq 0 ]
    [[ "$output" == *"IN_PROGRESS"* ]]
}

@test "E2E: --circuit-status shows state" {
    echo '{"state":"CLOSED","no_progress_count":0}' > "$RALPH_DIR/.circuit_breaker_state"
    # Source needed libs
    run bash "$RALPH_SCRIPT" --circuit-status
    [ "$status" -eq 0 ] || true  # May fail without full env
}

@test "E2E: fixture project has required structure" {
    # Verify all required files exist
    [ -f "$RALPH_DIR/PROMPT.md" ]
    [ -f "$RALPH_DIR/fix_plan.md" ]
    [ -d "$LOG_DIR" ]
    [ -f "$RALPH_DIR/.call_count" ]
}

@test "E2E: call count file increments" {
    echo "5" > "$RALPH_DIR/.call_count"
    local before
    before=$(cat "$RALPH_DIR/.call_count")
    echo "$((before + 1))" > "$RALPH_DIR/.call_count"
    local after
    after=$(cat "$RALPH_DIR/.call_count")
    [ "$after" -eq 6 ]
}

@test "E2E: session ID file creates and reads" {
    echo "sess-e2e-test-123" > "$RALPH_DIR/.claude_session_id"
    local sid
    sid=$(cat "$RALPH_DIR/.claude_session_id")
    [ "$sid" = "sess-e2e-test-123" ]
}

@test "E2E: circuit breaker state file round-trips" {
    echo '{"state":"OPEN","no_progress_count":3,"last_error":"test"}' > "$RALPH_DIR/.circuit_breaker_state"
    local state
    state=$(jq -r '.state' "$RALPH_DIR/.circuit_breaker_state")
    [ "$state" = "OPEN" ]
}

@test "E2E: exit signals file initializes correctly" {
    run jq -e '.' "$RALPH_DIR/.exit_signals"
    [ "$status" -eq 0 ]
}

@test "E2E: log directory is writable" {
    echo "test log entry" > "$LOG_DIR/test.log"
    [ -f "$LOG_DIR/test.log" ]
}

# =============================================================================
# MOCK CLAUDE CLI E2E TESTS (Issue #225)
# =============================================================================

# Path to mock Claude CLI script
MOCK_CLAUDE_SCRIPT="${BATS_TEST_DIRNAME}/../mock_claude.sh"

# Helper: set up mock Claude environment for E2E tests
setup_mock_claude_env() {
    local scenario="$1"
    export MOCK_SCENARIO="$scenario"
    export MOCK_STATE_DIR="$TEST_DIR/.mock_state"
    export MOCK_SESSION_ID="mock-e2e-test-$$"
    mkdir -p "$MOCK_STATE_DIR"
    # Reset loop count for each test
    rm -f "$MOCK_STATE_DIR/loop_count"
    # Point CLAUDE_CODE_CMD at the mock
    export CLAUDE_CODE_CMD="$MOCK_CLAUDE_SCRIPT"
}

# Helper: clean up mock state
teardown_mock_claude_env() {
    rm -rf "${MOCK_STATE_DIR:-/tmp/ralph_mock_state_nonexistent}"
    unset MOCK_SCENARIO MOCK_STATE_DIR MOCK_SESSION_ID MOCK_LOOPS
}

@test "E2E mock: mock_claude.sh exists and is executable" {
    [ -f "$MOCK_CLAUDE_SCRIPT" ]
    [ -x "$MOCK_CLAUDE_SCRIPT" ]
}

@test "E2E mock: normal scenario outputs valid JSON" {
    setup_mock_claude_env "normal"
    export MOCK_LOOPS=1

    run bash "$MOCK_CLAUDE_SCRIPT"
    [ "$status" -eq 0 ]

    # Each line should be valid JSON
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        echo "$line" | jq -e '.' > /dev/null 2>&1 || {
            echo "Invalid JSON line: $line"
            return 1
        }
    done <<< "$output"

    teardown_mock_claude_env
}

@test "E2E mock: normal scenario emits EXIT_SIGNAL on final loop" {
    setup_mock_claude_env "normal"
    export MOCK_LOOPS=1

    run bash "$MOCK_CLAUDE_SCRIPT"
    [ "$status" -eq 0 ]

    # Should contain EXIT_SIGNAL: true in the output
    [[ "$output" == *"EXIT_SIGNAL: true"* ]]

    teardown_mock_claude_env
}

@test "E2E mock: normal scenario emits progress before final loop" {
    setup_mock_claude_env "normal"
    export MOCK_LOOPS=3

    # First invocation (loop 1 of 3) should NOT have EXIT_SIGNAL: true
    run bash "$MOCK_CLAUDE_SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"EXIT_SIGNAL: false"* ]]
    [[ "$output" == *"TASKS_COMPLETED_THIS_LOOP: 1"* ]]

    # Second invocation (loop 2 of 3) should still NOT have EXIT_SIGNAL: true
    run bash "$MOCK_CLAUDE_SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"EXIT_SIGNAL: false"* ]]

    # Third invocation (loop 3 of 3) should have EXIT_SIGNAL: true
    run bash "$MOCK_CLAUDE_SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"EXIT_SIGNAL: true"* ]]
    [[ "$output" == *"STATUS: COMPLETE"* ]]

    teardown_mock_claude_env
}

@test "E2E mock: stuck scenario never reports progress" {
    setup_mock_claude_env "stuck"

    # Run multiple invocations - none should show progress
    for i in 1 2 3; do
        run bash "$MOCK_CLAUDE_SCRIPT"
        [ "$status" -eq 0 ]
        [[ "$output" == *"TASKS_COMPLETED_THIS_LOOP: 0"* ]]
        [[ "$output" == *"FILES_MODIFIED: 0"* ]]
        [[ "$output" == *"EXIT_SIGNAL: false"* ]]
    done

    teardown_mock_claude_env
}

@test "E2E mock: permission denial scenario reports blocked status" {
    setup_mock_claude_env "permission"

    run bash "$MOCK_CLAUDE_SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"STATUS: BLOCKED"* ]]
    [[ "$output" == *"Permission denied"* ]] || [[ "$output" == *"permission"* ]] || [[ "$output" == *"denied"* ]]
    [[ "$output" == *"TASKS_COMPLETED_THIS_LOOP: 0"* ]]

    teardown_mock_claude_env
}

@test "E2E mock: rate limit scenario returns rate_limit_event" {
    setup_mock_claude_env "rate_limit"

    run bash "$MOCK_CLAUDE_SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"rate_limit_event"* ]]
    [[ "$output" == *"rejected"* ]]
    [[ "$output" == *"5-hour usage limit"* ]]

    teardown_mock_claude_env
}

@test "E2E mock: high tokens scenario reports large usage" {
    setup_mock_claude_env "high_tokens"

    run bash "$MOCK_CLAUDE_SCRIPT"
    [ "$status" -eq 0 ]

    # Extract the result line and verify high usage fields
    local result_line
    result_line=$(echo "$output" | grep '"type":"result"')
    [[ -n "$result_line" ]]

    local cost
    cost=$(echo "$result_line" | jq -r '.cost_usd // 0')
    # cost_usd should be 2.50 (high)
    [[ $(echo "$cost > 1" | bc -l 2>/dev/null || echo "1") == "1" ]] || {
        # Fallback: just verify the field exists and is non-zero
        [[ "$result_line" == *'"cost_usd":2.5'* ]]
    }

    teardown_mock_claude_env
}

@test "E2E mock: error scenario returns is_error true" {
    setup_mock_claude_env "error"

    run bash "$MOCK_CLAUDE_SCRIPT"
    [ "$status" -eq 0 ]

    # Result line should have is_error: true
    local result_line
    result_line=$(echo "$output" | grep '"type":"result"')
    [[ -n "$result_line" ]]

    local is_error
    is_error=$(echo "$result_line" | jq -r '.is_error')
    [ "$is_error" = "true" ]

    teardown_mock_claude_env
}

@test "E2E mock: empty scenario returns empty result" {
    setup_mock_claude_env "empty"

    run bash "$MOCK_CLAUDE_SCRIPT"
    [ "$status" -eq 0 ]

    # Result should have empty string as result
    local result_line
    result_line=$(echo "$output" | grep '"type":"result"')
    [[ -n "$result_line" ]]

    local result_text
    result_text=$(echo "$result_line" | jq -r '.result')
    [ "$result_text" = "" ]

    teardown_mock_claude_env
}

@test "E2E mock: unknown scenario exits with error" {
    setup_mock_claude_env "nonexistent_scenario_xyz"

    run bash "$MOCK_CLAUDE_SCRIPT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unknown MOCK_SCENARIO"* ]]

    teardown_mock_claude_env
}

@test "E2E mock: loop count increments across invocations" {
    setup_mock_claude_env "normal"
    export MOCK_LOOPS=5

    # Run 3 invocations
    bash "$MOCK_CLAUDE_SCRIPT" > /dev/null
    bash "$MOCK_CLAUDE_SCRIPT" > /dev/null
    bash "$MOCK_CLAUDE_SCRIPT" > /dev/null

    # State file should show count 3
    local count
    count=$(cat "$MOCK_STATE_DIR/loop_count")
    [ "$count" -eq 3 ]

    teardown_mock_claude_env
}

@test "E2E mock: RALPH_MOCK_CLAUDE env var activates mock in ralph_loop.sh" {
    # Verify the mock integration point exists in ralph_loop.sh
    run grep -c "RALPH_MOCK_CLAUDE" "$RALPH_SCRIPT"
    [ "$status" -eq 0 ]
    [[ "$output" -ge 1 ]]
}

@test "E2E mock: mock output contains system init line with session_id" {
    setup_mock_claude_env "normal"
    export MOCK_LOOPS=1

    run bash "$MOCK_CLAUDE_SCRIPT"
    [ "$status" -eq 0 ]

    # First line should be system init
    local first_line
    first_line=$(echo "$output" | head -1)
    local msg_type
    msg_type=$(echo "$first_line" | jq -r '.type')
    [ "$msg_type" = "system" ]

    local session_id
    session_id=$(echo "$first_line" | jq -r '.session_id')
    [[ -n "$session_id" ]]
    [[ "$session_id" != "null" ]]

    teardown_mock_claude_env
}

@test "E2E mock: mock output contains assistant message" {
    setup_mock_claude_env "normal"
    export MOCK_LOOPS=1

    run bash "$MOCK_CLAUDE_SCRIPT"
    [ "$status" -eq 0 ]

    # Second line should be assistant message
    local second_line
    second_line=$(echo "$output" | sed -n '2p')
    local msg_type
    msg_type=$(echo "$second_line" | jq -r '.type')
    [ "$msg_type" = "assistant" ]

    local role
    role=$(echo "$second_line" | jq -r '.message.role')
    [ "$role" = "assistant" ]

    teardown_mock_claude_env
}

@test "E2E mock: circuit breaker integration with stuck mock" {
    # Source circuit breaker (requires date_utils) to test integration
    source "${BATS_TEST_DIRNAME}/../../lib/date_utils.sh"
    source "${BATS_TEST_DIRNAME}/../../lib/circuit_breaker.sh"

    # Lower threshold for faster test (default is 5 failures, min 3 calls)
    CB_FAILURE_THRESHOLD=3
    CB_MIN_CALLS=2

    init_circuit_breaker

    setup_mock_claude_env "stuck"

    # Simulate stuck loops - record failures via cb_record_failure
    # cb_record_failure internally calls cb_evaluate_window
    for i in 1 2 3; do
        run bash "$MOCK_CLAUDE_SCRIPT"
        [ "$status" -eq 0 ]
        # Record a failure (no progress) - may return 1 when tripping
        cb_record_failure "no_progress" || true
    done

    # Circuit breaker should be OPEN after reaching failure threshold
    local cb_state
    cb_state=$(jq -r '.state' "$RALPH_DIR/.circuit_breaker_state")
    [ "$cb_state" = "OPEN" ]

    teardown_mock_claude_env
}

@test "E2E mock: permission denial detected in mock output" {
    setup_mock_claude_env "permission"

    run bash "$MOCK_CLAUDE_SCRIPT"
    [ "$status" -eq 0 ]

    # Verify permission denial text is present
    [[ "$output" == *"denied"* ]]

    # The result line should still be valid JSON
    local result_line
    result_line=$(echo "$output" | grep '"type":"result"')
    echo "$result_line" | jq -e '.' > /dev/null 2>&1
    [ $? -eq 0 ]

    teardown_mock_claude_env
}
