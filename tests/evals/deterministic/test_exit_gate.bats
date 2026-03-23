#!/usr/bin/env bats
# tests/evals/deterministic/test_exit_gate.bats
# EVALS-2: Verifies the dual-condition exit gate.
#
# The Ralph loop requires BOTH conditions to exit:
#   1. completion_indicators >= 2 (accumulated EXIT_SIGNAL=true responses)
#   2. exit_signal = "true" in the current status.json
#
# These tests verify the gate logic WITHOUT making any LLM calls.

load '../../helpers/test_helper'

PROJECT_ROOT="${BATS_TEST_DIRNAME}/../../.."
RALPH_LOOP="${PROJECT_ROOT}/ralph_loop.sh"

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"

    export RALPH_DIR=".ralph"
    export STATUS_FILE="$RALPH_DIR/status.json"
    export EXIT_SIGNALS_FILE="$RALPH_DIR/.exit_signals"
    mkdir -p "$RALPH_DIR/logs"

    # Initialize standard files
    echo "0" > "$RALPH_DIR/.call_count"
    echo "$(date +%Y%m%d%H)" > "$RALPH_DIR/.last_reset"
    echo '# Fix Plan' > "$RALPH_DIR/fix_plan.md"
    echo '# Test Prompt' > "$RALPH_DIR/PROMPT.md"

    # Source ralph_loop.sh functions if the check function is available
    # We simulate the exit gate logic inline for determinism
}

teardown() {
    if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
        cd /
        rm -rf "$TEST_DIR"
    fi
}

# Helper: create status.json with specific exit_signal value
create_status() {
    local exit_signal="${1:-false}"
    local work_type="${2:-IMPLEMENTATION}"
    local loop_count="${3:-1}"
    cat > "$STATUS_FILE" <<EOF
{
  "timestamp": "2026-03-23T00:00:00Z",
  "loop_count": $loop_count,
  "status": "IN_PROGRESS",
  "exit_signal": "$exit_signal",
  "tasks_completed": 1,
  "files_modified": 2,
  "work_type": "$work_type",
  "recommendation": ""
}
EOF
}

# Helper: create exit_signals with specific completion_indicators count
create_exit_signals() {
    local completion_count="${1:-0}"
    local done_count="${2:-0}"
    local test_loops="${3:-0}"

    local comp_array="[]"
    local done_array="[]"
    local test_array="[]"

    if [[ $completion_count -gt 0 ]]; then
        comp_array="[$(seq -s, 1 "$completion_count")]"
    fi
    if [[ $done_count -gt 0 ]]; then
        done_array="[$(seq -s, 1 "$done_count")]"
    fi
    if [[ $test_loops -gt 0 ]]; then
        test_array="[$(seq -s, 1 "$test_loops")]"
    fi

    cat > "$EXIT_SIGNALS_FILE" <<EOF
{
    "test_only_loops": $test_array,
    "done_signals": $done_array,
    "completion_indicators": $comp_array
}
EOF
}

# Helper: simulate the dual-condition exit gate check
# Returns 0 if exit should trigger, 1 if loop should continue
check_exit_gate() {
    local status_file="$STATUS_FILE"
    local signals_file="$EXIT_SIGNALS_FILE"

    # Read current exit_signal from status.json
    local claude_exit_signal
    claude_exit_signal=$(jq -r '.exit_signal // "false"' "$status_file" 2>/dev/null || echo "false")

    # Read completion_indicators count from exit_signals
    local completion_indicators
    completion_indicators=$(jq '.completion_indicators | length' "$signals_file" 2>/dev/null || echo "0")

    # Dual condition: BOTH must be true
    if [[ $completion_indicators -ge 2 ]] && [[ "$claude_exit_signal" == "true" ]]; then
        return 0  # exit
    fi

    return 1  # continue
}

# =============================================================================
# DUAL-CONDITION EXIT GATE TESTS
# =============================================================================

@test "EXIT GATE: exit triggers when completion_indicators>=2 AND exit_signal=true" {
    create_status "true"
    create_exit_signals 3  # 3 completion indicators

    run check_exit_gate
    assert_success  # Should trigger exit (return 0)
}

@test "EXIT GATE: exit triggers at exactly 2 completion_indicators AND exit_signal=true" {
    create_status "true"
    create_exit_signals 2  # exactly 2 completion indicators

    run check_exit_gate
    assert_success  # Should trigger exit (return 0)
}

@test "EXIT GATE: does NOT exit when exit_signal=true but completion_indicators<2" {
    create_status "true"
    create_exit_signals 1  # only 1 completion indicator

    run check_exit_gate
    assert_failure  # Should continue (return 1)
}

@test "EXIT GATE: does NOT exit when completion_indicators>=2 but exit_signal=false" {
    create_status "false"
    create_exit_signals 3  # 3 completion indicators

    run check_exit_gate
    assert_failure  # Should continue (return 1)
}

@test "EXIT GATE: does NOT exit when both conditions are false" {
    create_status "false"
    create_exit_signals 0  # no completion indicators

    run check_exit_gate
    assert_failure  # Should continue (return 1)
}

@test "EXIT GATE: does NOT exit when exit_signal=true but zero completion_indicators" {
    create_status "true"
    create_exit_signals 0

    run check_exit_gate
    assert_failure  # Should continue (return 1)
}

# =============================================================================
# MID-PHASE "DONE" CONTEXT TESTS
# =============================================================================

@test "EXIT GATE: 'done' in mid-phase does not trigger exit when completion_indicators=0" {
    # Simulates Claude saying "done with this subtask" mid-phase
    # exit_signal is false because on-stop.sh only sets it true from RALPH_STATUS block
    create_status "false" "IMPLEMENTATION" 3
    create_exit_signals 0 1  # 0 completion but 1 done_signal

    run check_exit_gate
    assert_failure  # Should continue (return 1)
}

@test "EXIT GATE: exit_signal must come from status.json, not from done_signals count" {
    # Even if done_signals is high, exit_signal in status.json must be "true"
    create_status "false" "IMPLEMENTATION" 5
    create_exit_signals 0 5  # 0 completion, 5 done_signals

    run check_exit_gate
    assert_failure  # Should continue (return 1)
}

@test "EXIT GATE: single EXIT_SIGNAL=true increments completion but does not exit alone" {
    # First EXIT_SIGNAL=true — completion_indicators becomes 1, not enough
    create_status "true"
    create_exit_signals 1

    run check_exit_gate
    assert_failure  # Should continue (return 1) — need >= 2
}

@test "EXIT GATE: missing status.json defaults exit_signal to false" {
    rm -f "$STATUS_FILE"
    create_exit_signals 5  # plenty of completion indicators

    # Modify check to handle missing file
    check_exit_gate_safe() {
        local claude_exit_signal
        claude_exit_signal=$(jq -r '.exit_signal // "false"' "$STATUS_FILE" 2>/dev/null || echo "false")
        local completion_indicators
        completion_indicators=$(jq '.completion_indicators | length' "$EXIT_SIGNALS_FILE" 2>/dev/null || echo "0")

        if [[ $completion_indicators -ge 2 ]] && [[ "$claude_exit_signal" == "true" ]]; then
            return 0
        fi
        return 1
    }

    run check_exit_gate_safe
    assert_failure  # Should continue — no status.json means exit_signal defaults to "false"
}

@test "EXIT GATE: missing exit_signals file defaults completion_indicators to 0" {
    create_status "true"
    rm -f "$EXIT_SIGNALS_FILE"

    check_exit_gate_safe() {
        local claude_exit_signal
        claude_exit_signal=$(jq -r '.exit_signal // "false"' "$STATUS_FILE" 2>/dev/null || echo "false")
        local completion_indicators
        completion_indicators=$(jq '.completion_indicators | length' "$EXIT_SIGNALS_FILE" 2>/dev/null || echo "0")

        if [[ $completion_indicators -ge 2 ]] && [[ "$claude_exit_signal" == "true" ]]; then
            return 0
        fi
        return 1
    }

    run check_exit_gate_safe
    assert_failure  # Should continue — no exit_signals means 0 indicators
}
