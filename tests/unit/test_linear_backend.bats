#!/usr/bin/env bats
# Unit tests for lib/linear_backend.sh
# Uses bash function overriding to mock curl — no real HTTP calls are made.

load '../helpers/test_helper'

LINEAR_BACKEND="${BATS_TEST_DIRNAME}/../../lib/linear_backend.sh"

setup() {
    export TEST_TEMP_DIR="$(mktemp -d)"
    cd "$TEST_TEMP_DIR"

    # Clear any stale env vars
    unset LINEAR_API_KEY
    unset RALPH_LINEAR_PROJECT
    unset MOCK_CURL_RESPONSE
    unset MOCK_CURL_EXIT

    source "$LINEAR_BACKEND"
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR"
}

# ---------------------------------------------------------------------------
# Helper: install a curl mock script that shadows the real curl via PATH
# ---------------------------------------------------------------------------
MOCK_BIN_DIR=""

mock_curl_success() {
    local response="$1"
    MOCK_BIN_DIR="$(mktemp -d)"
    # Write the response to a file so the script can read it without quoting issues
    printf '%s' "$response" > "$MOCK_BIN_DIR/_response"
    cat > "$MOCK_BIN_DIR/curl" << 'SCRIPT'
#!/bin/bash
cat "$(dirname "$0")/_response"
exit 0
SCRIPT
    chmod +x "$MOCK_BIN_DIR/curl"
    export PATH="$MOCK_BIN_DIR:$PATH"
}

mock_curl_failure() {
    MOCK_BIN_DIR="$(mktemp -d)"
    cat > "$MOCK_BIN_DIR/curl" << 'SCRIPT'
#!/bin/bash
exit 1
SCRIPT
    chmod +x "$MOCK_BIN_DIR/curl"
    export PATH="$MOCK_BIN_DIR:$PATH"
}

restore_curl() {
    if [[ -n "$MOCK_BIN_DIR" && -d "$MOCK_BIN_DIR" ]]; then
        rm -rf "$MOCK_BIN_DIR"
        MOCK_BIN_DIR=""
    fi
    # Remove mock dir from PATH — strip the leading entry we added
    export PATH="${PATH#*:}"
}

# =============================================================================
# linear_check_configured (3 tests)
# =============================================================================

@test "linear_check_configured: fails when LINEAR_API_KEY is not set" {
    export RALPH_LINEAR_PROJECT="My Project"
    run linear_check_configured
    assert_failure
}

@test "linear_check_configured: fails when RALPH_LINEAR_PROJECT is not set" {
    export LINEAR_API_KEY="lin_api_test123"
    run linear_check_configured
    assert_failure
}

@test "linear_check_configured: succeeds when both vars are set" {
    export LINEAR_API_KEY="lin_api_test123"
    export RALPH_LINEAR_PROJECT="My Project"
    run linear_check_configured
    assert_success
}

# =============================================================================
# linear_get_open_count (4 tests)
# =============================================================================

@test "linear_get_open_count: returns 0 when LINEAR_API_KEY is not set" {
    export RALPH_LINEAR_PROJECT="My Project"
    run linear_get_open_count
    assert_output "0"
}

@test "linear_get_open_count: returns correct count from API response" {
    export LINEAR_API_KEY="lin_api_test123"
    export RALPH_LINEAR_PROJECT="My Project"
    mock_curl_success '{"data":{"issues":{"nodes":[{"id":"1"},{"id":"2"},{"id":"3"}]}}}'
    run linear_get_open_count
    restore_curl
    assert_output "3"
}

@test "linear_get_open_count: returns 0 when API response has empty nodes" {
    export LINEAR_API_KEY="lin_api_test123"
    export RALPH_LINEAR_PROJECT="My Project"
    mock_curl_success '{"data":{"issues":{"nodes":[]}}}'
    run linear_get_open_count
    restore_curl
    assert_output "0"
}

@test "linear_get_open_count: returns 0 on curl failure (fail-open)" {
    export LINEAR_API_KEY="lin_api_test123"
    export RALPH_LINEAR_PROJECT="My Project"
    mock_curl_failure
    run linear_get_open_count
    restore_curl
    assert_output "0"
}

# =============================================================================
# linear_get_done_count (4 tests)
# =============================================================================

@test "linear_get_done_count: returns 0 when LINEAR_API_KEY is not set" {
    export RALPH_LINEAR_PROJECT="My Project"
    run linear_get_done_count
    assert_output "0"
}

@test "linear_get_done_count: returns correct count from API response" {
    export LINEAR_API_KEY="lin_api_test123"
    export RALPH_LINEAR_PROJECT="My Project"
    mock_curl_success '{"data":{"issues":{"nodes":[{"id":"10"},{"id":"11"}]}}}'
    run linear_get_done_count
    restore_curl
    assert_output "2"
}

@test "linear_get_done_count: returns 0 on curl failure (fail-open)" {
    export LINEAR_API_KEY="lin_api_test123"
    export RALPH_LINEAR_PROJECT="My Project"
    mock_curl_failure
    run linear_get_done_count
    restore_curl
    assert_output "0"
}

@test "linear_get_done_count: returns 0 when nodes array is absent" {
    export LINEAR_API_KEY="lin_api_test123"
    export RALPH_LINEAR_PROJECT="My Project"
    mock_curl_success '{"data":{"issues":{}}}'
    run linear_get_done_count
    restore_curl
    assert_output "0"
}

# =============================================================================
# linear_get_next_task (7 tests)
# =============================================================================

@test "linear_get_next_task: returns empty string when LINEAR_API_KEY is not set" {
    export RALPH_LINEAR_PROJECT="My Project"
    run linear_get_next_task
    assert_output ""
}

@test "linear_get_next_task: returns single issue as IDENTIFIER: title" {
    export LINEAR_API_KEY="lin_api_test123"
    export RALPH_LINEAR_PROJECT="My Project"
    mock_curl_success '{"data":{"issues":{"nodes":[
        {"id":"abc","identifier":"RC-1","title":"Fix the login bug","priority":2}
    ]}}}'
    run linear_get_next_task
    restore_curl
    assert_output "RC-1: Fix the login bug"
}

@test "linear_get_next_task: returns highest priority issue (lower number = higher priority)" {
    export LINEAR_API_KEY="lin_api_test123"
    export RALPH_LINEAR_PROJECT="My Project"
    mock_curl_success '{"data":{"issues":{"nodes":[
        {"id":"a","identifier":"RC-3","title":"Low prio task","priority":4},
        {"id":"b","identifier":"RC-1","title":"Urgent task","priority":1},
        {"id":"c","identifier":"RC-2","title":"High prio task","priority":2}
    ]}}}'
    run linear_get_next_task
    restore_curl
    assert_output "RC-1: Urgent task"
}

@test "linear_get_next_task: treats priority 0 (no priority) as lowest" {
    export LINEAR_API_KEY="lin_api_test123"
    export RALPH_LINEAR_PROJECT="My Project"
    mock_curl_success '{"data":{"issues":{"nodes":[
        {"id":"a","identifier":"RC-2","title":"No priority task","priority":0},
        {"id":"b","identifier":"RC-1","title":"Normal task","priority":3}
    ]}}}'
    run linear_get_next_task
    restore_curl
    assert_output "RC-1: Normal task"
}

@test "linear_get_next_task: returns empty string when no open issues" {
    export LINEAR_API_KEY="lin_api_test123"
    export RALPH_LINEAR_PROJECT="My Project"
    mock_curl_success '{"data":{"issues":{"nodes":[]}}}'
    run linear_get_next_task
    restore_curl
    assert_output ""
}

@test "linear_get_next_task: returns empty string on curl failure (fail-open)" {
    export LINEAR_API_KEY="lin_api_test123"
    export RALPH_LINEAR_PROJECT="My Project"
    mock_curl_failure
    run linear_get_next_task
    restore_curl
    assert_output ""
}

@test "linear_get_next_task: handles missing nodes key gracefully" {
    export LINEAR_API_KEY="lin_api_test123"
    export RALPH_LINEAR_PROJECT="My Project"
    mock_curl_success '{"data":{"issues":{}}}'
    run linear_get_next_task
    restore_curl
    assert_output ""
}
