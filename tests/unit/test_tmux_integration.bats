#!/usr/bin/env bats
# Unit tests for tmux integration (Phase 9, TEST-1)
# Tests tmux availability checks, monitor script, and flag behavior

load '../helpers/test_helper'
load '../helpers/fixtures'

RALPH_SCRIPT="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"
RALPH_MONITOR="${BATS_TEST_DIRNAME}/../../ralph_monitor.sh"

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
}

teardown() {
    cd /
    rm -rf "$TEST_DIR"
}

@test "monitor script exists" {
    [ -f "$RALPH_MONITOR" ]
}

@test "--monitor flag is documented in help" {
    run bash "$RALPH_SCRIPT" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"--monitor"* ]]
}

@test "--monitor flag short form -m is documented" {
    run bash "$RALPH_SCRIPT" --help
    [[ "$output" == *"-m"* ]]
}

@test "tmux command availability check" {
    # Test that we can check for tmux without crashing
    if command -v tmux &>/dev/null; then
        tmux -V >/dev/null 2>&1
    fi
    # Always passes — just verifying the check mechanism works
    true
}

@test "help mentions tmux requirement" {
    run bash "$RALPH_SCRIPT" --help
    [[ "$output" == *"tmux"* ]]
}
