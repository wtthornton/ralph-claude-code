#!/usr/bin/env bats
# Unit tests for lib/linear_backend.sh
# Uses bash function overriding to mock curl — no real HTTP calls are made.

bats_require_minimum_version 1.5.0
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
    local http_code="${2:-200}"
    MOCK_BIN_DIR="$(mktemp -d)"
    printf '%s' "$response" > "$MOCK_BIN_DIR/_response"
    printf '%s' "$http_code" > "$MOCK_BIN_DIR/_http_code"
    # The lib uses `curl -w '\n%{http_code}'` and splits the body from the
    # trailing code. Mock that contract regardless of which arg looks like -w.
    cat > "$MOCK_BIN_DIR/curl" << 'SCRIPT'
#!/bin/bash
cat "$(dirname "$0")/_response"
printf '\n%s' "$(cat "$(dirname "$0")/_http_code")"
exit 0
SCRIPT
    chmod +x "$MOCK_BIN_DIR/curl"
    export PATH="$MOCK_BIN_DIR:$PATH"
}

mock_curl_failure() {
    local exit_code="${1:-1}"
    MOCK_BIN_DIR="$(mktemp -d)"
    printf '%s' "$exit_code" > "$MOCK_BIN_DIR/_exit_code"
    cat > "$MOCK_BIN_DIR/curl" << 'SCRIPT'
#!/bin/bash
exit "$(cat "$(dirname "$0")/_exit_code")"
SCRIPT
    chmod +x "$MOCK_BIN_DIR/curl"
    export PATH="$MOCK_BIN_DIR:$PATH"
}

# TAP-536: simulate HTTP error response (e.g. 401 Unauthorized, 503 Server)
mock_curl_http_error() {
    local http_code="$1"
    local body="${2:-}"
    mock_curl_success "$body" "$http_code"
}

# TAP-536: simulate connection timeout (curl exit code 28)
mock_curl_timeout() {
    mock_curl_failure 28
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

@test "linear_get_open_count: TAP-536 fails when LINEAR_API_KEY is not set" {
    export RALPH_LINEAR_PROJECT="My Project"
    run linear_get_open_count
    assert_failure
    [[ "$output" != *"0"* ]] || fail "must not silently emit a zero count on missing API key"
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

@test "linear_get_open_count: TAP-536 fails loudly on curl failure (no longer fail-open)" {
    export LINEAR_API_KEY="lin_api_test123"
    export RALPH_LINEAR_PROJECT="My Project"
    mock_curl_failure
    run linear_get_open_count
    restore_curl
    assert_failure
    [[ "$output" != *"0"* ]] || fail "must not silently emit a zero count on curl failure"
}

# =============================================================================
# linear_get_done_count (4 tests)
# =============================================================================

@test "linear_get_done_count: TAP-536 fails when LINEAR_API_KEY is not set" {
    export RALPH_LINEAR_PROJECT="My Project"
    run linear_get_done_count
    assert_failure
    [[ "$output" != *"0"* ]] || fail "must not silently emit a zero count on missing API key"
}

@test "linear_get_done_count: returns correct count from API response" {
    export LINEAR_API_KEY="lin_api_test123"
    export RALPH_LINEAR_PROJECT="My Project"
    mock_curl_success '{"data":{"issues":{"nodes":[{"id":"10"},{"id":"11"}]}}}'
    run linear_get_done_count
    restore_curl
    assert_output "2"
}

@test "linear_get_done_count: TAP-536 fails loudly on curl failure (no longer fail-open)" {
    export LINEAR_API_KEY="lin_api_test123"
    export RALPH_LINEAR_PROJECT="My Project"
    mock_curl_failure
    run linear_get_done_count
    restore_curl
    assert_failure
    [[ "$output" != *"0"* ]] || fail "must not silently emit a zero count on curl failure"
}

@test "linear_get_done_count: returns 0 when nodes array is absent (default //[])" {
    export LINEAR_API_KEY="lin_api_test123"
    export RALPH_LINEAR_PROJECT="My Project"
    mock_curl_success '{"data":{"issues":{}}}'
    run linear_get_done_count
    restore_curl
    # `// []` defaults the missing nodes to an empty array, so length=0 is a
    # valid happy-path answer (not a parse error).
    assert_success
    assert_output "0"
}

# =============================================================================
# linear_get_next_task (7 tests)
# =============================================================================

@test "linear_get_next_task: TAP-536 fails when LINEAR_API_KEY is not set" {
    export RALPH_LINEAR_PROJECT="My Project"
    run linear_get_next_task
    assert_failure
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

@test "linear_get_next_task: TAP-536 fails loudly on curl failure (no longer fail-open)" {
    export LINEAR_API_KEY="lin_api_test123"
    export RALPH_LINEAR_PROJECT="My Project"
    mock_curl_failure
    run linear_get_next_task
    restore_curl
    assert_failure
}

# =============================================================================
# TAP-536: structured error logging + reason matrix (HTTP 401, 5xx, timeout, parse)
# =============================================================================

@test "TAP-536: 401 unauthorized returns non-zero with reason=http_401" {
    export LINEAR_API_KEY="lin_api_bad"
    export RALPH_LINEAR_PROJECT="My Project"
    mock_curl_http_error 401 '{"error":"unauthorized"}'
    run --separate-stderr linear_get_open_count
    restore_curl
    assert_failure
    # stdout must be empty (no silent zero count) — error info goes to stderr.
    [[ -z "$output" ]] || fail "expected empty stdout on 401, got: $output"
    [[ "$stderr" == *"linear_api_error"* && "$stderr" == *"reason=http_401"* ]] || \
        fail "expected 'linear_api_error: ... reason=http_401' on stderr, got: $stderr"
}

@test "TAP-536: 5xx server error returns non-zero with reason=http_503" {
    export LINEAR_API_KEY="lin_api_test123"
    export RALPH_LINEAR_PROJECT="My Project"
    mock_curl_http_error 503 '{"error":"service unavailable"}'
    run --separate-stderr linear_get_done_count
    restore_curl
    assert_failure
    [[ -z "$output" ]] || fail "expected empty stdout on 503, got: $output"
    [[ "$stderr" == *"reason=http_503"* ]] || \
        fail "expected reason=http_503 on stderr, got: $stderr"
}

@test "TAP-536: connection timeout returns non-zero with reason=timeout" {
    export LINEAR_API_KEY="lin_api_test123"
    export RALPH_LINEAR_PROJECT="My Project"
    mock_curl_timeout
    run --separate-stderr linear_get_open_count
    restore_curl
    assert_failure
    [[ -z "$output" ]] || fail "expected empty stdout on timeout, got: $output"
    [[ "$stderr" == *"reason=timeout"* ]] || \
        fail "expected reason=timeout on stderr, got: $stderr"
}

@test "TAP-536: malformed JSON returns non-zero with reason=parse" {
    export LINEAR_API_KEY="lin_api_test123"
    export RALPH_LINEAR_PROJECT="My Project"
    # HTTP 200 with body that lacks the .data.issues.nodes path entirely.
    # `.data.issues.nodes // []` defaults to []; jq returns "0" for length.
    # To force a parse failure we feed jq a body that is not valid JSON at all.
    mock_curl_success 'this is not json at all' 200
    run --separate-stderr linear_get_open_count
    restore_curl
    assert_failure
    [[ -z "$output" ]] || fail "expected empty stdout on parse error, got: $output"
    [[ "$stderr" == *"reason=parse"* ]] || \
        fail "expected reason=parse on stderr, got: $stderr"
}

@test "TAP-536: GraphQL error envelope (HTTP 200, .errors set) returns non-zero" {
    export LINEAR_API_KEY="lin_api_test123"
    export RALPH_LINEAR_PROJECT="My Project"
    mock_curl_success '{"errors":[{"message":"Schema field deprecated"}]}' 200
    run --separate-stderr linear_get_open_count
    restore_curl
    assert_failure
    [[ -z "$output" ]] || fail "expected empty stdout on GraphQL error, got: $output"
    [[ "$stderr" == *"reason=graphql_errors"* ]] || \
        fail "expected reason=graphql_errors on stderr, got: $stderr"
}

@test "TAP-536: structured error log does not leak the API key" {
    export LINEAR_API_KEY="lin_api_SECRET_TOKEN_xyz"
    export RALPH_LINEAR_PROJECT="MySecretProjectName"
    mock_curl_http_error 401 ''
    run --separate-stderr linear_get_open_count
    restore_curl
    assert_failure
    [[ "$stderr" != *"SECRET_TOKEN"* ]] || fail "API key leaked into stderr: $stderr"
    [[ "$stderr" != *"MySecretProjectName"* ]] || fail "Project name leaked into stderr: $stderr"
}

@test "TAP-536: empty backlog (HTTP 200, [] nodes) still succeeds and prints 0" {
    export LINEAR_API_KEY="lin_api_test123"
    export RALPH_LINEAR_PROJECT="My Project"
    mock_curl_success '{"data":{"issues":{"nodes":[]}}}'
    run linear_get_open_count
    restore_curl
    assert_success
    assert_output "0"
}

@test "linear_get_next_task: handles missing nodes key gracefully" {
    export LINEAR_API_KEY="lin_api_test123"
    export RALPH_LINEAR_PROJECT="My Project"
    mock_curl_success '{"data":{"issues":{}}}'
    run linear_get_next_task
    restore_curl
    assert_success
    assert_output ""
}
