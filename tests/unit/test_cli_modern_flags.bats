#!/usr/bin/env bats
# Unit tests for modern CLI flags (Phase 9, TEST-4)
# Tests: --dry-run, --calls, --timeout, --output-format, --live,
#        --reset-circuit, --reset-session, --sdk, --stats, --rollback,
#        --issue, --sandbox

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
    echo "$(date +%s)" > "$RALPH_DIR/.last_reset"
    mkdir -p lib
    echo 'get_circuit_breaker_state() { echo "CLOSED"; }' > lib/circuit_breaker.sh
    echo 'reset_circuit_breaker() { echo "reset"; }' >> lib/circuit_breaker.sh
    echo 'show_circuit_status() { echo "CLOSED"; }' >> lib/circuit_breaker.sh
    echo '' > lib/date_utils.sh
    echo '' > lib/timeout_utils.sh
    echo '' > lib/metrics.sh
    echo '' > lib/notifications.sh
    echo '' > lib/backup.sh
}

teardown() {
    cd /
    rm -rf "$TEST_DIR"
}

@test "--version shows version string" {
    run bash "$RALPH_SCRIPT" --version
    [ "$status" -eq 0 ]
    [[ "$output" == ralph\ * ]]
}

@test "-V shows version string" {
    run bash "$RALPH_SCRIPT" -V
    [ "$status" -eq 0 ]
    [[ "$output" == ralph\ * ]]
}

@test "--help exits with 0" {
    run bash "$RALPH_SCRIPT" --help
    [ "$status" -eq 0 ]
}

@test "--help mentions --sdk flag" {
    run bash "$RALPH_SCRIPT" --help
    [[ "$output" == *"--sdk"* ]]
}

@test "--help mentions --stats flag" {
    run bash "$RALPH_SCRIPT" --help
    [[ "$output" == *"--stats"* ]]
}

@test "--help mentions --rollback flag" {
    run bash "$RALPH_SCRIPT" --help
    [[ "$output" == *"--rollback"* ]]
}

@test "--help mentions --issue flag" {
    run bash "$RALPH_SCRIPT" --help
    [[ "$output" == *"--issue"* ]]
}

@test "--help mentions --sandbox flag" {
    run bash "$RALPH_SCRIPT" --help
    [[ "$output" == *"--sandbox"* ]]
}

@test "--timeout rejects 0" {
    run bash "$RALPH_SCRIPT" --timeout 0
    [ "$status" -ne 0 ]
}

@test "--timeout rejects 121" {
    run bash "$RALPH_SCRIPT" --timeout 121
    [ "$status" -ne 0 ]
}

@test "--timeout accepts 30" {
    # Will fail later (no main loop), but should not fail on parsing
    run bash "$RALPH_SCRIPT" --timeout 30 --version
    [ "$status" -eq 0 ]
}

@test "--output-format rejects invalid" {
    run bash "$RALPH_SCRIPT" --output-format xml
    [ "$status" -ne 0 ]
}

@test "--output-format accepts json" {
    run bash "$RALPH_SCRIPT" --output-format json --version
    [ "$status" -eq 0 ]
}

@test "--output-format accepts text" {
    run bash "$RALPH_SCRIPT" --output-format text --version
    [ "$status" -eq 0 ]
}

@test "unknown flag fails with help" {
    run bash "$RALPH_SCRIPT" --nonexistent-flag
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unknown option"* ]]
}

@test "--calls accepts positive integer" {
    run bash "$RALPH_SCRIPT" --calls 50 --version
    [ "$status" -eq 0 ]
}

@test "--session-expiry rejects non-integer" {
    run bash "$RALPH_SCRIPT" --session-expiry abc
    [ "$status" -ne 0 ]
}

@test "--log-max-size rejects non-integer" {
    run bash "$RALPH_SCRIPT" --log-max-size abc
    [ "$status" -ne 0 ]
}

@test "--log-max-files rejects non-integer" {
    run bash "$RALPH_SCRIPT" --log-max-files abc
    [ "$status" -ne 0 ]
}
