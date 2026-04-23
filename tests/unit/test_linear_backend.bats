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

@test "linear_check_configured: TAP-741 succeeds in push-mode (no API key, project set)" {
    export RALPH_LINEAR_PROJECT="My Project"
    run linear_check_configured
    assert_success
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

@test "linear_get_open_count: TAP-536/TAP-741 fails in push-mode when no status.json exists" {
    export RALPH_LINEAR_PROJECT="My Project"
    export RALPH_DIR="$TEST_TEMP_DIR/.ralph-absent"
    run linear_get_open_count
    assert_failure
    [[ "$output" != *"0"* ]] || fail "must not silently emit a zero count in push-mode bootstrap"
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

@test "linear_get_done_count: TAP-536/TAP-741 fails in push-mode when no status.json exists" {
    export RALPH_LINEAR_PROJECT="My Project"
    export RALPH_DIR="$TEST_TEMP_DIR/.ralph-absent"
    run linear_get_done_count
    assert_failure
    [[ "$output" != *"0"* ]] || fail "must not silently emit a zero count in push-mode bootstrap"
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

# ---------------------------------------------------------------------------
# PREFLIGHT-EMPTY-PLAN (Linear backend) — Bug 3 regression tests.
# These exercise should_exit_gracefully from ralph_loop.sh directly, with the
# linear_get_open_count / linear_get_done_count functions stubbed in bash.
# Three contracts to verify:
#   (a) open=0   \u2192 exit "plan_complete"     (legitimate empty backlog)
#   (b) open>0   \u2192 continue (return "")     (work to do)
#   (c) error    \u2192 abstain (return "")      (TAP-536 fail-loud)
# ---------------------------------------------------------------------------

# Helper: invoke the live should_exit_gracefully with a Linear stub.
_run_should_exit_with_linear_stub() {
    local open_exit=$1 open_value=$2 done_exit=$3 done_value=$4

    local ralph_dir="$TEST_TEMP_DIR/.ralph"
    mkdir -p "$ralph_dir"
    printf '%s' '{"test_only_loops": [], "done_signals": [], "completion_indicators": []}' \
        > "$ralph_dir/.exit_signals"
    printf '%s' '{"loop_count": 1, "exit_signal": "false"}' > "$ralph_dir/status.json"
    printf '%s' '{"state":"CLOSED","consecutive_no_progress":0,"consecutive_permission_denials":0,"total_opens":0}' \
        > "$ralph_dir/.circuit_breaker_state"

    bash -c "
set +u
RALPH_DIR='$ralph_dir'
EXIT_SIGNALS_FILE='$ralph_dir/.exit_signals'
RALPH_TASK_SOURCE=linear
RALPH_LINEAR_PROJECT='Test Project'
MAX_CONSECUTIVE_TEST_LOOPS=3
MAX_CONSECUTIVE_DONE_SIGNALS=2
CB_PERMISSION_DENIAL_THRESHOLD=2
RALPH_USE_AGENT=false
log_status() { :; }
check_agent_support() { return 1; }
linear_get_open_count() { echo '$open_value'; return $open_exit; }
linear_get_done_count() { echo '$done_value'; return $done_exit; }
source <(awk '/^should_exit_gracefully\\(\\) \\{/,/^\\}/' '${BATS_TEST_DIRNAME}/../../ralph_loop.sh')
should_exit_gracefully 2>/dev/null
"
}

@test "PREFLIGHT (Linear): open=0 returns plan_complete (legitimate empty backlog)" {
    run _run_should_exit_with_linear_stub 0 0 0 5
    assert_success
    assert_output "plan_complete"
}

@test "PREFLIGHT (Linear): open=0 done=0 returns plan_complete (project has no issues at all)" {
    # Edge case: brand-new project with nothing seeded. Same outcome \u2014 exit clean.
    run _run_should_exit_with_linear_stub 0 0 0 0
    assert_success
    assert_output "plan_complete"
}

@test "PREFLIGHT (Linear): open>0 continues (returns empty string)" {
    run _run_should_exit_with_linear_stub 0 3 0 7
    assert_success
    assert_output ""
}

@test "PREFLIGHT (Linear): linear_get_open_count failure ABSTAINS (TAP-536 fail-loud)" {
    # When the API errors, the backend exits non-zero and the gate must NOT
    # interpret \"unknown\" as \"empty\" \u2014 we abstain (return empty) so the
    # next loop can retry. CRITICAL: a transient outage must not trip plan_complete.
    run _run_should_exit_with_linear_stub 1 "" 0 5
    assert_success
    assert_output ""
}

@test "PREFLIGHT (Linear): linear_get_done_count failure ABSTAINS (TAP-536 fail-loud)" {
    # Same contract for done_count.
    run _run_should_exit_with_linear_stub 0 0 1 ""
    assert_success
    assert_output ""
}

# =============================================================================
# TAP-741: push-mode (status.json fallback, no LINEAR_API_KEY)
# =============================================================================

# Helper: write a status.json with the given linear_open_count / _done_count /
# linear_counts_at, using jq so the file is always valid JSON even when a field
# is omitted.
_write_push_status() {
    local dir="$1" open="$2" done_c="$3" ts="$4"
    mkdir -p "$dir"
    jq -n \
        --arg open "$open" \
        --arg done "$done_c" \
        --arg ts "$ts" \
        '{
            timestamp: (if $ts == "" then null else $ts end),
            linear_open_count: (if $open == "" then null else ($open|tonumber) end),
            linear_done_count: (if $done == "" then null else ($done|tonumber) end),
            linear_counts_at: (if $ts == "" then null else $ts end)
        }' > "$dir/status.json"
}

@test "TAP-741 push-mode: open_count returns value from fresh status.json" {
    unset LINEAR_API_KEY
    export RALPH_LINEAR_PROJECT="My Project"
    export RALPH_DIR="$TEST_TEMP_DIR/.ralph-push"
    _write_push_status "$RALPH_DIR" "7" "3" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    run linear_get_open_count
    assert_success
    assert_output "7"
}

@test "TAP-741 push-mode: done_count returns value from fresh status.json" {
    unset LINEAR_API_KEY
    export RALPH_LINEAR_PROJECT="My Project"
    export RALPH_DIR="$TEST_TEMP_DIR/.ralph-push"
    _write_push_status "$RALPH_DIR" "7" "3" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    run linear_get_done_count
    assert_success
    assert_output "3"
}

@test "TAP-741 push-mode: abstains when status.json is missing (iter-1 bootstrap)" {
    unset LINEAR_API_KEY
    export RALPH_LINEAR_PROJECT="My Project"
    export RALPH_DIR="$TEST_TEMP_DIR/.ralph-fresh"
    # Do NOT create status.json

    run --separate-stderr linear_get_open_count
    assert_failure
    assert_output ""  # stdout empty — TAP-536 fail-loud contract
    [[ "$stderr" == *"reason=no_status_file"* ]] || \
        fail "expected structured stderr with reason=no_status_file, got: $stderr"
}

@test "TAP-741 push-mode: abstains when status.json has no count field" {
    unset LINEAR_API_KEY
    export RALPH_LINEAR_PROJECT="My Project"
    export RALPH_DIR="$TEST_TEMP_DIR/.ralph-nocount"
    mkdir -p "$RALPH_DIR"
    echo '{"timestamp":"2026-04-20T18:00:00Z"}' > "$RALPH_DIR/status.json"

    run --separate-stderr linear_get_open_count
    assert_failure
    assert_output ""
    [[ "$stderr" == *"reason=no_hook_count"* ]] || fail "expected no_hook_count, got: $stderr"
}

@test "TAP-741 push-mode: abstains when status.json is malformed" {
    unset LINEAR_API_KEY
    export RALPH_LINEAR_PROJECT="My Project"
    export RALPH_DIR="$TEST_TEMP_DIR/.ralph-broken"
    mkdir -p "$RALPH_DIR"
    echo 'not valid json {{{' > "$RALPH_DIR/status.json"

    run --separate-stderr linear_get_open_count
    assert_failure
    assert_output ""
    [[ "$stderr" == *"reason=status_json_malformed"* ]] || fail "expected status_json_malformed, got: $stderr"
}

@test "TAP-741 push-mode: abstains when counts are stale (older than max age)" {
    unset LINEAR_API_KEY
    export RALPH_LINEAR_PROJECT="My Project"
    export RALPH_DIR="$TEST_TEMP_DIR/.ralph-stale"
    export RALPH_LINEAR_COUNTS_MAX_AGE_SECONDS=60
    # Timestamp 1 hour in the past — far outside the 60s window
    local stale_ts
    stale_ts=$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
             || date -u -r $(( $(date +%s) - 3600 )) +%Y-%m-%dT%H:%M:%SZ)
    _write_push_status "$RALPH_DIR" "12" "4" "$stale_ts"

    run --separate-stderr linear_get_open_count
    assert_failure
    assert_output ""
    [[ "$stderr" == *"reason=counts_stale"* ]] || fail "expected counts_stale, got: $stderr"
}

@test "TAP-741 push-mode: abstains when linear_counts_at is missing" {
    unset LINEAR_API_KEY
    export RALPH_LINEAR_PROJECT="My Project"
    export RALPH_DIR="$TEST_TEMP_DIR/.ralph-nots"
    _write_push_status "$RALPH_DIR" "5" "2" ""

    run linear_get_open_count
    assert_failure
}

@test "TAP-741 push-mode: abstains when count value is not a non-negative integer" {
    unset LINEAR_API_KEY
    export RALPH_LINEAR_PROJECT="My Project"
    export RALPH_DIR="$TEST_TEMP_DIR/.ralph-badnum"
    mkdir -p "$RALPH_DIR"
    echo '{"linear_open_count":"seven","linear_counts_at":"2026-04-20T18:00:00Z"}' \
        > "$RALPH_DIR/status.json"

    run linear_get_open_count
    assert_failure
}

@test "TAP-741 push-mode: accepts count of zero (valid done-plan signal)" {
    unset LINEAR_API_KEY
    export RALPH_LINEAR_PROJECT="My Project"
    export RALPH_DIR="$TEST_TEMP_DIR/.ralph-zero"
    _write_push_status "$RALPH_DIR" "0" "42" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    run linear_get_open_count
    assert_success
    assert_output "0"
}

# =============================================================================
# linear_get_in_progress_task (5 tests)
# =============================================================================

@test "linear_get_in_progress_task: fails when LINEAR_API_KEY is not set (no push-mode)" {
    export RALPH_LINEAR_PROJECT="My Project"
    run linear_get_in_progress_task
    assert_failure
}

@test "linear_get_in_progress_task: returns highest-priority started issue" {
    export LINEAR_API_KEY="lin_api_test123"
    export RALPH_LINEAR_PROJECT="My Project"
    mock_curl_success '{"data":{"issues":{"nodes":[
        {"id":"a","identifier":"RC-5","title":"Stuck low prio","priority":4},
        {"id":"b","identifier":"RC-3","title":"Stuck urgent","priority":1},
        {"id":"c","identifier":"RC-4","title":"Stuck high","priority":2}
    ]}}}'
    run linear_get_in_progress_task
    restore_curl
    assert_output "RC-3: Stuck urgent"
}

@test "linear_get_in_progress_task: returns empty string when no started issues" {
    export LINEAR_API_KEY="lin_api_test123"
    export RALPH_LINEAR_PROJECT="My Project"
    mock_curl_success '{"data":{"issues":{"nodes":[]}}}'
    run linear_get_in_progress_task
    restore_curl
    assert_success
    assert_output ""
}

@test "linear_get_in_progress_task: treats priority 0 as lowest" {
    export LINEAR_API_KEY="lin_api_test123"
    export RALPH_LINEAR_PROJECT="My Project"
    mock_curl_success '{"data":{"issues":{"nodes":[
        {"id":"a","identifier":"RC-2","title":"No priority","priority":0},
        {"id":"b","identifier":"RC-1","title":"Normal prio","priority":3}
    ]}}}'
    run linear_get_in_progress_task
    restore_curl
    assert_output "RC-1: Normal prio"
}

@test "linear_get_in_progress_task: fails loudly on curl failure" {
    export LINEAR_API_KEY="lin_api_test123"
    export RALPH_LINEAR_PROJECT="My Project"
    mock_curl_failure
    run linear_get_in_progress_task
    restore_curl
    assert_failure
}

@test "TAP-741 push-mode: API-key path takes precedence over status.json" {
    # With the API key set, the hook-count read must NOT be consulted —
    # preserves the existing TAP-536 contract for API-key deployments.
    export LINEAR_API_KEY="lin_api_test123"
    export RALPH_LINEAR_PROJECT="My Project"
    export RALPH_DIR="$TEST_TEMP_DIR/.ralph-hybrid"
    _write_push_status "$RALPH_DIR" "999" "999" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    mock_curl_success '{"data":{"issues":{"nodes":[{"id":"1"},{"id":"2"}]}}}'
    run linear_get_open_count
    restore_curl
    assert_success
    assert_output "2"  # from the API mock, NOT from the 999 in status.json
}

# =============================================================================
# TAP-664: project name → ID resolution (startup bootstrap)
# =============================================================================

@test "TAP-664: linear_resolve_project_id fails without API key" {
    export RALPH_LINEAR_PROJECT="Ralph"
    run linear_resolve_project_id
    assert_failure
    [[ "$output" != *"linear_api_error"* ]] || true  # error goes to stderr
}

@test "TAP-664: linear_resolve_project_id fails without project name" {
    export LINEAR_API_KEY="lin_api_test"
    run linear_resolve_project_id
    assert_failure
}

@test "TAP-664: linear_resolve_project_id returns UUID on exact single match" {
    export LINEAR_API_KEY="lin_api_test"
    export RALPH_LINEAR_PROJECT="Ralph Continuous Coding"
    mock_curl_success '{"data":{"projects":{"nodes":[{"id":"73125846-2148-4fd0-8a8e-902e7cc6b36c","name":"Ralph Continuous Coding"}]}}}'
    run linear_resolve_project_id
    restore_curl
    assert_success
    assert_output "73125846-2148-4fd0-8a8e-902e7cc6b36c"
}

@test "TAP-664: linear_resolve_project_id fails loudly when project not found" {
    export LINEAR_API_KEY="lin_api_test"
    export RALPH_LINEAR_PROJECT="Ralph Continuous Coding "  # trailing space
    mock_curl_success '{"data":{"projects":{"nodes":[]}}}'
    # --separate-stderr: stderr carries the structured linear_api_error line
    # while stdout must stay empty (no UUID leaked on failure).
    run --separate-stderr linear_resolve_project_id
    restore_curl
    assert_failure
    [[ -z "$output" ]] || fail "must not print a UUID on stdout on failure: '$output'"
    [[ "$stderr" == *"linear_api_error"* ]]
    [[ "$stderr" == *"project_not_found"* ]]
}

@test "TAP-664: linear_resolve_project_id fails loudly on ambiguous match (>1)" {
    export LINEAR_API_KEY="lin_api_test"
    export RALPH_LINEAR_PROJECT="Ralph"
    mock_curl_success '{"data":{"projects":{"nodes":[{"id":"a","name":"Ralph"},{"id":"b","name":"Ralph"}]}}}'
    run linear_resolve_project_id
    restore_curl
    assert_failure
}

@test "TAP-664: linear_init is a no-op in push-mode (no API key)" {
    export RALPH_LINEAR_PROJECT="Ralph Continuous Coding"
    run linear_init
    assert_success
    # _LINEAR_PROJECT_ID must remain empty — nothing to resolve
    [[ -z "$_LINEAR_PROJECT_ID" ]]
}

@test "TAP-664: linear_init caches the resolved ID for subsequent queries" {
    export LINEAR_API_KEY="lin_api_test"
    export RALPH_LINEAR_PROJECT="Ralph Continuous Coding"
    mock_curl_success '{"data":{"projects":{"nodes":[{"id":"cached-id-123","name":"Ralph Continuous Coding"}]}}}'
    linear_init
    restore_curl
    [[ "$_LINEAR_PROJECT_ID" == "cached-id-123" ]]
}

@test "TAP-664: linear_init returns 1 on resolution failure (whitespace drift)" {
    export LINEAR_API_KEY="lin_api_test"
    export RALPH_LINEAR_PROJECT="Ralph Continuous Coding "
    mock_curl_success '{"data":{"projects":{"nodes":[]}}}'
    run linear_init
    restore_curl
    assert_failure
}

@test "TAP-664: open_count uses ID-filter when _LINEAR_PROJECT_ID is cached" {
    export LINEAR_API_KEY="lin_api_test"
    export RALPH_LINEAR_PROJECT="Ralph Continuous Coding"
    export _LINEAR_PROJECT_ID="resolved-uuid-xyz"
    # The mock returns 4 issues; we care about the query *shape*, so capture the
    # JSON POST body and assert it carries the ID filter, not the raw name.
    MOCK_BIN_DIR="$(mktemp -d)"
    mkdir -p "$MOCK_BIN_DIR"
    cat > "$MOCK_BIN_DIR/curl" << SCRIPT
#!/bin/bash
# Dump every arg + the stdin body for the test to inspect
for arg in "\$@"; do printf '%s\n' "\$arg"; done > "$MOCK_BIN_DIR/_args"
# curl reads POST body via --data-raw/--data — which shows up as an arg
printf '{"data":{"issues":{"nodes":[{"id":"1"},{"id":"2"}]}}}\n200\n'
SCRIPT
    chmod +x "$MOCK_BIN_DIR/curl"
    export PATH="$MOCK_BIN_DIR:$PATH"
    run linear_get_open_count
    # Must have invoked the query with an ID filter, not a name filter
    grep -q 'projectId' "$MOCK_BIN_DIR/_args" || fail "query must use projectId filter: $(cat $MOCK_BIN_DIR/_args)"
    grep -q 'resolved-uuid-xyz' "$MOCK_BIN_DIR/_args" || fail "query must carry the resolved UUID"
    restore_curl
    assert_success
    assert_output "2"
}

@test "TAP-664: open_count falls back to name-filter when cache is empty" {
    export LINEAR_API_KEY="lin_api_test"
    export RALPH_LINEAR_PROJECT="Ralph Continuous Coding"
    # _LINEAR_PROJECT_ID intentionally unset
    MOCK_BIN_DIR="$(mktemp -d)"
    mkdir -p "$MOCK_BIN_DIR"
    cat > "$MOCK_BIN_DIR/curl" << SCRIPT
#!/bin/bash
for arg in "\$@"; do printf '%s\n' "\$arg"; done > "$MOCK_BIN_DIR/_args"
printf '{"data":{"issues":{"nodes":[{"id":"1"}]}}}\n200\n'
SCRIPT
    chmod +x "$MOCK_BIN_DIR/curl"
    export PATH="$MOCK_BIN_DIR:$PATH"
    run linear_get_open_count
    # Back-compat: must still use the name filter when the cache is empty
    grep -q '"project":"Ralph Continuous Coding"' "$MOCK_BIN_DIR/_args" || true
    grep -q 'project:{name:{eq:' "$MOCK_BIN_DIR/_args" || fail "expected name filter fallback"
    restore_curl
    assert_success
}
