#!/usr/bin/env bats
# Unit tests for lib/linear_optimizer.sh (LINOPT-2 / TAP-591)
#
# Tests cover: same-priority same-module wins, lower-priority same-module beats
# higher-priority unrelated, empty last_completed falls back to priority order,
# non-top-3 no-path issue gets no explorer call, explorer result is cached.

load '../helpers/test_helper'

LINEAR_OPTIMIZER="${BATS_TEST_DIRNAME}/../../lib/linear_optimizer.sh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# _build_issues_json — Emit a Linear issues GraphQL response.
# Args: a JSON array string of issue node objects.
_build_issues_json() {
    local nodes="$1"
    printf '{"data":{"issues":{"nodes":%s}}}' "$nodes"
}

# _issue_node — Emit one issue node as compact JSON.
# Args: id identifier title priority description updated_at
_issue_node() {
    jq -n \
        --arg id          "$1" \
        --arg identifier  "$2" \
        --arg title       "$3" \
        --argjson priority "$4" \
        --arg description "$5" \
        --arg updatedAt   "${6:-2024-01-01T00:00:00Z}" \
        '{id:$id,identifier:$identifier,title:$title,
          priority:$priority,description:$description,updatedAt:$updatedAt}'
}

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR" || return 1

    export RALPH_DIR=".ralph"
    mkdir -p "$RALPH_DIR"

    export RALPH_TASK_SOURCE="linear"
    export RALPH_LINEAR_PROJECT="TestProject"
    export LINEAR_API_KEY="fake-test-key"
    export RALPH_NO_LINEAR_OPTIMIZE="false"
    export RALPH_OPTIMIZER_FETCH_LIMIT="20"
    export RALPH_OPTIMIZER_EXPLORER_MAX="3"

    # Source the library under test; _linear_run_issues_query is defined per-test
    source "$LINEAR_OPTIMIZER"

    # Reset session-global explorer call counter
    _OPTIMIZER_EXPLORER_CALLS=0
    _OPTIMIZER_CACHE_FILE="${RALPH_DIR}/.linear_optimizer_cache.json"
}

teardown() {
    if [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]]; then
        cd /
        rm -rf "$TEST_DIR"
    fi
}

# =============================================================================
# TEST 1: Same priority — same-module candidate wins over unrelated one
# =============================================================================

@test "TAP-591: same priority — same-module candidate wins" {
    # last-completed file is in lib/
    printf 'lib/plan_optimizer.sh\n' > "$RALPH_DIR/.last_completed_files"

    # Issue A (TAP-A): priority 2, touches unrelated module sdk/
    local node_a
    node_a=$(_issue_node "id-a" "TAP-A" "SDK work" 2 "See sdk/agent.py for details")

    # Issue B (TAP-B): priority 2, touches the same lib/ module
    local node_b
    node_b=$(_issue_node "id-b" "TAP-B" "Lib work" 2 "Modify lib/plan_optimizer.sh")

    local mock_json
    mock_json=$(_build_issues_json "[${node_a},${node_b}]")

    # Mock the API query function
    _linear_run_issues_query() { printf '%s\n' "$mock_json"; return 0; }

    linear_optimizer_run

    run cat "$RALPH_DIR/.linear_next_issue"
    assert_success
    # First line must be the winning issue identifier
    local first_line
    first_line=$(head -1 "$RALPH_DIR/.linear_next_issue")
    [[ "$first_line" == "TAP-B" ]]
}

# =============================================================================
# TEST 2: Higher-priority unrelated loses to lower-priority same-module
# =============================================================================

@test "TAP-591: higher-priority unrelated loses to lower-priority same-module" {
    printf 'lib/plan_optimizer.sh\n' > "$RALPH_DIR/.last_completed_files"

    # Issue A: priority 1 (Urgent), touches unrelated sdk/ module
    local node_a
    node_a=$(_issue_node "id-a" "TAP-A" "SDK urgent" 1 "Edit sdk/agent.py")

    # Issue B: priority 3 (Normal), touches the same lib/ module
    local node_b
    node_b=$(_issue_node "id-b" "TAP-B" "Lib normal" 3 "Update lib/plan_optimizer.sh")

    local mock_json
    mock_json=$(_build_issues_json "[${node_a},${node_b}]")

    _linear_run_issues_query() { printf '%s\n' "$mock_json"; return 0; }

    linear_optimizer_run

    local first_line
    first_line=$(head -1 "$RALPH_DIR/.linear_next_issue")
    [[ "$first_line" == "TAP-B" ]]
}

# =============================================================================
# TEST 3: Empty .last_completed_files → priority order, no error
# =============================================================================

@test "TAP-591: empty last_completed_files falls back to priority order" {
    # Empty file (no last-completed work)
    : > "$RALPH_DIR/.last_completed_files"

    # Issue A: priority 2 (High)
    local node_a
    node_a=$(_issue_node "id-a" "TAP-A" "High prio" 2 "Edit lib/foo.sh")

    # Issue B: priority 3 (Normal)
    local node_b
    node_b=$(_issue_node "id-b" "TAP-B" "Normal prio" 3 "Edit lib/bar.sh")

    local mock_json
    mock_json=$(_build_issues_json "[${node_a},${node_b}]")

    _linear_run_issues_query() { printf '%s\n' "$mock_json"; return 0; }

    # Override explorer so it isn't called
    _optimizer_invoke_explorer() { return 0; }

    run linear_optimizer_run
    assert_success

    # Both score 0 (empty last_completed) → tiebreak: higher prio (TAP-A, prio 2 < prio 3)
    local first_line
    first_line=$(head -1 "$RALPH_DIR/.linear_next_issue")
    [[ "$first_line" == "TAP-A" ]]
}

# =============================================================================
# TEST 4: Non-top-3 no-path issue does NOT get an explorer call
# =============================================================================

@test "TAP-591: non-top-3 no-path issue gets no explorer call" {
    printf 'lib/plan_optimizer.sh\n' > "$RALPH_DIR/.last_completed_files"

    # 4 issues: first three have body paths, 4th has none — 4th is lowest priority
    local node_a node_b node_c node_d
    node_a=$(_issue_node "id-a" "TAP-A" "A" 1 "lib/plan_optimizer.sh")
    node_b=$(_issue_node "id-b" "TAP-B" "B" 2 "lib/linear_backend.sh")
    node_c=$(_issue_node "id-c" "TAP-C" "C" 3 "lib/circuit_breaker.sh")
    node_d=$(_issue_node "id-d" "TAP-D" "D" 4 "")  # no paths, priority 4 (not top-3)

    local mock_json
    mock_json=$(_build_issues_json "[${node_a},${node_b},${node_c},${node_d}]")

    _linear_run_issues_query() { printf '%s\n' "$mock_json"; return 0; }

    _OPTIMIZER_EXPLORER_CALLS=0
    linear_optimizer_run

    # Explorer must NOT have been called (TAP-D is priority 4, not in top-3;
    # TAP-A/B/C each have body paths so the empty-file guard never fires).
    # _OPTIMIZER_EXPLORER_CALLS is incremented in the parent shell (before $())
    # so it reliably tracks whether _optimizer_explorer_resolve was entered.
    [[ "$_OPTIMIZER_EXPLORER_CALLS" -eq 0 ]]
}

# =============================================================================
# TEST 5: Explorer result is cached — second run makes no additional call
# =============================================================================

@test "TAP-591: explorer result is cached across runs" {
    printf 'lib/plan_optimizer.sh\n' > "$RALPH_DIR/.last_completed_files"

    # Single issue with no body paths so explorer is attempted
    local node_a
    node_a=$(_issue_node "id-a" "TAP-A" "Lib work" 1 "")

    local mock_json
    mock_json=$(_build_issues_json "[${node_a}]")

    _linear_run_issues_query() { printf '%s\n' "$mock_json"; return 0; }

    # Override explorer to return a known path (the $() subshell means variable
    # increments inside are lost; track via _OPTIMIZER_EXPLORER_CALLS instead,
    # which is incremented in the parent shell before calling invoke).
    _optimizer_invoke_explorer() { printf 'lib/plan_optimizer.sh\n'; }

    # First run — _OPTIMIZER_EXPLORER_CALLS goes 0→1 before the invoke call
    _OPTIMIZER_EXPLORER_CALLS=0
    linear_optimizer_run
    [[ "$_OPTIMIZER_EXPLORER_CALLS" -eq 1 ]]

    # Simulate re-entry: reset the session cap counter; cache file persists
    _OPTIMIZER_EXPLORER_CALLS=0

    # Second run — cache hit short-circuits before the counter increment, stays 0
    linear_optimizer_run
    [[ "$_OPTIMIZER_EXPLORER_CALLS" -eq 0 ]]
}
