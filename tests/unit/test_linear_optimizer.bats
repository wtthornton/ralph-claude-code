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

# ---------------------------------------------------------------------------
# TAP-592 helpers
# ---------------------------------------------------------------------------

# _write_import_graph — Write a fake import graph cache.
# Args: a JSON string of {file: [imports...]}.
_write_import_graph() {
    local graph="$1"
    printf '%s' "$graph" > "$RALPH_DIR/.import_graph.json"
}

# Source import_graph.sh helpers so import_graph_predecessors is available.
_setup_import_graph_lib() {
    source "${BATS_TEST_DIRNAME}/../../lib/import_graph.sh"
}

# =============================================================================
# TAP-592 TEST 1: Candidate demoted when its file imports another open issue's file
# =============================================================================

@test "TAP-592: candidate demoted when it imports another open issue's file" {
    _setup_import_graph_lib

    # Two open candidates:
    #   TAP-A owns src/foo.py  (high score — same module as last-completed)
    #   TAP-B owns tests/test_foo.py — but tests/test_foo.py imports src/foo.py
    # Even though TAP-B has the higher locality score, it must be demoted because
    # src/foo.py is owned by TAP-A (still open).
    printf 'tests/test_foo.py\n' > "$RALPH_DIR/.last_completed_files"

    local node_a node_b
    node_a=$(_issue_node "id-a" "TAP-A" "Implement foo" 2 "Edit src/foo.py")
    node_b=$(_issue_node "id-b" "TAP-B" "Test foo" 2 "Edit tests/test_foo.py")

    local mock_json
    mock_json=$(_build_issues_json "[${node_a},${node_b}]")
    _linear_run_issues_query() { printf '%s\n' "$mock_json"; return 0; }

    # Import graph: tests/test_foo.py imports src/foo.py
    _write_import_graph '{"tests/test_foo.py":["src/foo.py"]}'

    linear_optimizer_run

    local first_line
    first_line=$(head -1 "$RALPH_DIR/.linear_next_issue")
    # TAP-B locality-wins (last-completed is tests/test_foo.py) but is demoted
    # because tests/test_foo.py imports src/foo.py owned by still-open TAP-A.
    [[ "$first_line" == "TAP-A" ]]
}

# =============================================================================
# TAP-592 TEST 2: When the dependency owner is Done, no demotion happens
# =============================================================================

@test "TAP-592: no demotion when the dependency owner is Done (out of fetch)" {
    _setup_import_graph_lib

    # Same setup as TEST 1 but TAP-A is omitted from the fetch result, simulating
    # it being Done (the optimizer only fetches Backlog/Todo/Started). The graph
    # still says tests/test_foo.py imports src/foo.py, but src/foo.py is no
    # longer "owned by an open issue" because TAP-A isn't in the candidate set.
    printf 'tests/test_foo.py\n' > "$RALPH_DIR/.last_completed_files"

    local node_b
    node_b=$(_issue_node "id-b" "TAP-B" "Test foo" 2 "Edit tests/test_foo.py")

    local mock_json
    mock_json=$(_build_issues_json "[${node_b}]")
    _linear_run_issues_query() { printf '%s\n' "$mock_json"; return 0; }

    _write_import_graph '{"tests/test_foo.py":["src/foo.py"]}'

    linear_optimizer_run

    local first_line
    first_line=$(head -1 "$RALPH_DIR/.linear_next_issue")
    [[ "$first_line" == "TAP-B" ]]
}

# =============================================================================
# TAP-592 TEST 3: Missing import graph cache — no crash, no demotion
# =============================================================================

@test "TAP-592: no import-graph cache → falls through to score-based pick" {
    _setup_import_graph_lib

    printf 'tests/test_foo.py\n' > "$RALPH_DIR/.last_completed_files"

    local node_a node_b
    node_a=$(_issue_node "id-a" "TAP-A" "Implement foo" 2 "Edit src/foo.py")
    node_b=$(_issue_node "id-b" "TAP-B" "Test foo" 2 "Edit tests/test_foo.py")

    local mock_json
    mock_json=$(_build_issues_json "[${node_a},${node_b}]")
    _linear_run_issues_query() { printf '%s\n' "$mock_json"; return 0; }

    # NO import graph cache written
    rm -f "$RALPH_DIR/.import_graph.json" 2>/dev/null || true

    run linear_optimizer_run
    [[ "$status" -eq 0 ]]

    local first_line
    first_line=$(head -1 "$RALPH_DIR/.linear_next_issue")
    # Without the graph, locality wins → TAP-B (matches last-completed)
    [[ "$first_line" == "TAP-B" ]]
}

# =============================================================================
# TAP-592 TEST 4: All candidates have open deps → fewest-deps wins
# =============================================================================

@test "TAP-592: all candidates have deps → picks fewest-deps fallback" {
    _setup_import_graph_lib

    # All three candidates import another candidate's file.
    # TAP-A imports 1 (src/foo.py owned by TAP-B), score baseline
    # TAP-B imports 2 (src/foo.py owned by TAP-C, src/bar.py owned by TAP-C)
    # TAP-C imports 3 (a.py, b.py, c.py owned by TAP-A)
    printf '__no_match__\n' > "$RALPH_DIR/.last_completed_files"

    local node_a node_b node_c
    node_a=$(_issue_node "id-a" "TAP-A" "A" 2 "Edit src/a.py")
    node_b=$(_issue_node "id-b" "TAP-B" "B" 2 "Edit src/foo.py")
    node_c=$(_issue_node "id-c" "TAP-C" "C" 2 "Edit src/c.py")

    local mock_json
    mock_json=$(_build_issues_json "[${node_a},${node_b},${node_c}]")
    _linear_run_issues_query() { printf '%s\n' "$mock_json"; return 0; }

    # Graph: A imports foo (1 dep on B); B imports c (1 dep on C); C imports a (1 dep on A)
    # All three have exactly 1 cross-issue dep → fallback by score (all 0) → first by priority
    _write_import_graph '{"src/a.py":["src/foo.py"],"src/foo.py":["src/c.py"],"src/c.py":["src/a.py"]}'

    linear_optimizer_run

    # All three demoted. Fallback fires. Either A, B, or C — assert non-empty.
    [[ -s "$RALPH_DIR/.linear_next_issue" ]]
    local first_line
    first_line=$(head -1 "$RALPH_DIR/.linear_next_issue")
    [[ "$first_line" == "TAP-A" || "$first_line" == "TAP-B" || "$first_line" == "TAP-C" ]]
}

# =============================================================================
# TAP-592 TEST 5: RALPH_NO_DEP_DEMOTE=true bypasses dependency check
# =============================================================================

@test "TAP-592: RALPH_NO_DEP_DEMOTE=true bypasses demotion phase" {
    _setup_import_graph_lib

    printf 'tests/test_foo.py\n' > "$RALPH_DIR/.last_completed_files"

    local node_a node_b
    node_a=$(_issue_node "id-a" "TAP-A" "Implement foo" 2 "Edit src/foo.py")
    node_b=$(_issue_node "id-b" "TAP-B" "Test foo" 2 "Edit tests/test_foo.py")

    local mock_json
    mock_json=$(_build_issues_json "[${node_a},${node_b}]")
    _linear_run_issues_query() { printf '%s\n' "$mock_json"; return 0; }

    _write_import_graph '{"tests/test_foo.py":["src/foo.py"]}'

    # Opt out of demotion — locality should win like in TEST 3
    export RALPH_NO_DEP_DEMOTE=true
    linear_optimizer_run
    unset RALPH_NO_DEP_DEMOTE

    local first_line
    first_line=$(head -1 "$RALPH_DIR/.linear_next_issue")
    [[ "$first_line" == "TAP-B" ]]
}

# =============================================================================
# TAP-594 TEST 1: API error preserves existing hint, emits linear_api_error
# =============================================================================

@test "TAP-594: Linear API error preserves existing hint, records linear_api_error" {
    # Pre-existing hint that must NOT be deleted
    printf 'TAP-EXISTING\n' > "$RALPH_DIR/.linear_next_issue"

    # Mock fetcher returns non-zero (simulating API timeout)
    _linear_run_issues_query() { return 1; }

    linear_optimizer_run

    # Hint must be preserved
    [[ -s "$RALPH_DIR/.linear_next_issue" ]]
    local first_line
    first_line=$(head -1 "$RALPH_DIR/.linear_next_issue")
    [[ "$first_line" == "TAP-EXISTING" ]]

    # Telemetry: monthly file should contain a fallback_reason=linear_api_error record
    local mfile
    mfile="$RALPH_DIR/metrics/linear_optimizer_$(date -u '+%Y-%m').jsonl"
    [[ -s "$mfile" ]]
    grep -q '"fallback_reason":"linear_api_error"' "$mfile"
}

# =============================================================================
# TAP-594 TEST 2: Stale hint pointing at not-open issue is cleaned up
# =============================================================================

@test "TAP-594: stale hint pointing at not-open issue is cleaned up" {
    # Pre-existing hint pointing at TAP-OLD which is not in the open set
    printf 'TAP-OLD\n' > "$RALPH_DIR/.linear_next_issue"

    # Open issues do NOT include TAP-OLD — only TAP-NEW
    local node_new
    node_new=$(_issue_node "id-new" "TAP-NEW" "New work" 2 "Edit lib/foo.sh")
    local mock_json
    mock_json=$(_build_issues_json "[${node_new}]")

    _linear_run_issues_query() { printf '%s\n' "$mock_json"; return 0; }

    linear_optimizer_run

    # Hint should now reference TAP-NEW (the new pick), not TAP-OLD
    local first_line
    first_line=$(head -1 "$RALPH_DIR/.linear_next_issue")
    [[ "$first_line" == "TAP-NEW" ]]
}

# =============================================================================
# TAP-594 TEST 3: Stale lock from dead PID is auto-cleaned, second run acquires
# =============================================================================

@test "TAP-594: stale lock from dead PID is auto-cleaned" {
    # Write a lock with a PID that's almost certainly dead (PID 1 is init,
    # but on Linux we use PID 999999 which is unlikely to exist).
    mkdir -p "$RALPH_DIR"
    printf '999999\n' > "$RALPH_DIR/.linear_optimizer.lock"

    local node_a
    node_a=$(_issue_node "id-a" "TAP-A" "Work" 2 "Edit lib/foo.sh")
    local mock_json
    mock_json=$(_build_issues_json "[${node_a}]")
    _linear_run_issues_query() { printf '%s\n' "$mock_json"; return 0; }

    linear_optimizer_run

    # Run completed and picked TAP-A (lock was reclaimed)
    local first_line
    first_line=$(head -1 "$RALPH_DIR/.linear_next_issue")
    [[ "$first_line" == "TAP-A" ]]
    # Lock cleaned up at end of run
    [[ ! -f "$RALPH_DIR/.linear_optimizer.lock" ]]
}

# =============================================================================
# TAP-594 TEST 4: RALPH_NO_LINEAR_OPTIMIZE=true → no API calls, opt_out telemetry
# =============================================================================

@test "TAP-594: opt-out short-circuits before any API calls" {
    export RALPH_NO_LINEAR_OPTIMIZE=true

    local _api_called=0
    _linear_run_issues_query() { _api_called=1; return 0; }

    linear_optimizer_run
    unset RALPH_NO_LINEAR_OPTIMIZE

    [[ "$_api_called" -eq 0 ]]

    local mfile
    mfile="$RALPH_DIR/metrics/linear_optimizer_$(date -u '+%Y-%m').jsonl"
    [[ -s "$mfile" ]]
    grep -q '"fallback_reason":"opt_out"' "$mfile"
}

# =============================================================================
# TAP-594 TEST 5: Project-unset → ERROR log, project_unset telemetry, no crash
# =============================================================================

@test "TAP-594: project unset emits project_unset telemetry, no crash" {
    export RALPH_LINEAR_PROJECT=""

    local _api_called=0
    _linear_run_issues_query() { _api_called=1; return 0; }

    run linear_optimizer_run
    [[ "$status" -eq 0 ]]
    export RALPH_LINEAR_PROJECT="TestProject"

    [[ "$_api_called" -eq 0 ]]

    local mfile
    mfile="$RALPH_DIR/metrics/linear_optimizer_$(date -u '+%Y-%m').jsonl"
    [[ -s "$mfile" ]]
    grep -q '"fallback_reason":"project_unset"' "$mfile"
}

# =============================================================================
# TAP-594 TEST 6: Successful run writes a valid JSONL telemetry record
# =============================================================================

@test "TAP-594: successful run emits valid JSONL telemetry record" {
    printf 'lib/foo.sh\n' > "$RALPH_DIR/.last_completed_files"

    local node_a
    node_a=$(_issue_node "id-a" "TAP-A" "Work" 2 "Edit lib/foo.sh")
    local mock_json
    mock_json=$(_build_issues_json "[${node_a}]")
    _linear_run_issues_query() { printf '%s\n' "$mock_json"; return 0; }

    linear_optimizer_run

    local mfile
    mfile="$RALPH_DIR/metrics/linear_optimizer_$(date -u '+%Y-%m').jsonl"
    [[ -s "$mfile" ]]

    # The line must parse as JSON and have the expected fields
    local last_line
    last_line=$(tail -1 "$mfile")
    printf '%s' "$last_line" | jq -e '.hint_written == "TAP-A"' >/dev/null
    printf '%s' "$last_line" | jq -e '.fallback_reason == null' >/dev/null
    printf '%s' "$last_line" | jq -e '.candidates_evaluated == 1' >/dev/null
    printf '%s' "$last_line" | jq -e 'has("duration_ms")' >/dev/null
}
