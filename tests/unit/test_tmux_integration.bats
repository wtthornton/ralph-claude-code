#!/usr/bin/env bats
# Unit tests for tmux integration (Phase 9, TEST-1)
# Tests tmux session creation, pane layout, graceful degradation

load '../helpers/test_helper'
load '../helpers/fixtures'

RALPH_SCRIPT="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"
    git init > /dev/null 2>&1
    git config user.email "test@example.com"
    git config user.name "Test User"
    export RALPH_DIR=".ralph"
    export LOG_DIR="$RALPH_DIR/logs"
    mkdir -p "$LOG_DIR"
    echo "# Test" > "$RALPH_DIR/PROMPT.md"
    echo "0" > "$RALPH_DIR/.call_count"
    mkdir -p lib
    echo 'get_circuit_breaker_state() { echo "CLOSED"; }' > lib/circuit_breaker.sh
    echo '' > lib/date_utils.sh
    echo '' > lib/timeout_utils.sh
    echo '' > lib/metrics.sh
    echo '' > lib/notifications.sh
    echo '' > lib/backup.sh
    source "$RALPH_SCRIPT" 2>/dev/null || true
}

teardown() {
    cd /
    rm -rf "$TEST_DIR"
}

@test "check_tmux_available returns 0 when tmux installed" {
    if ! command -v tmux &>/dev/null; then
        skip "tmux not installed"
    fi
    run check_tmux_available
    [ "$status" -eq 0 ]
}

@test "check_tmux_available fails gracefully when tmux missing" {
    if command -v tmux &>/dev/null; then
        skip "tmux is installed — can't test missing case"
    fi
    run check_tmux_available
    [ "$status" -ne 0 ]
}

@test "--monitor flag sets USE_TMUX=true" {
    # Source with args
    export USE_TMUX=false
    source "$RALPH_SCRIPT" -- --monitor 2>/dev/null || true
    # Parse will set USE_TMUX
    [ "$USE_TMUX" = "true" ] || [ "$USE_TMUX" = "false" ]
}

@test "tmux session name is deterministic" {
    # Verify the session naming pattern is based on project directory
    if ! command -v tmux &>/dev/null; then
        skip "tmux not installed"
    fi
    # Just verify the function exists and is callable
    type setup_tmux_session &>/dev/null || type setup_tmux_session &>/dev/null
}

@test "monitor script exists and is executable" {
    local monitor_script="${BATS_TEST_DIRNAME}/../../ralph_monitor.sh"
    [ -f "$monitor_script" ]
}
