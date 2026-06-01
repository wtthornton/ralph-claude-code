#!/usr/bin/env bats
# TAP-2735: the exit_signal_quorum must FAIL CLOSED. Ralph's agent can emit
# EXIT_SIGNAL: true while the Linear backlog still has actionable issues; three
# such false signals reach exit_signal_quorum (3) and could halt a campaign with
# real work left. The quorum is now honored only when a fresh, authoritative
# Linear open-count == 0 is confirmed; an unverified count never exits; and a
# loop flagged mcp_disconnect=true never casts an exit_signal vote.
#
# These cover the two harness primitives the loop's three quorum sites depend on:
#   - ralph_backlog_verified_empty    (3-state verification gate)
#   - update_exit_signals_from_status (mcp_disconnect vote suppression)

bats_require_minimum_version 1.5.0

REPO_ROOT_FIXED="${BATS_TEST_DIRNAME}/../.."

setup() {
    export TEST_TEMP_DIR="$(mktemp -d "${BATS_TEST_TMPDIR:-/tmp}/exit_fc.XXXXXX")"
    cd "$TEST_TEMP_DIR"
    mkdir -p .ralph/logs
    export RALPH_DIR="$TEST_TEMP_DIR/.ralph"
    export LOG_DIR="$RALPH_DIR/logs"
    export DRY_RUN=false
    export RALPH_COORDINATOR_DISABLED=true
    set --
    # shellcheck disable=SC1090
    source "$REPO_ROOT_FIXED/ralph_loop.sh"
    # Defensive: ralph_loop.sh registers `trap cleanup EXIT` at top level. It is
    # inert in tests (guarded by loop_count>0), but clear it so nothing from the
    # harness's signal handling can fire when the bats process exits.
    trap - EXIT SIGINT SIGTERM
    # Keep EXIT_SIGNALS_FILE inside the temp scope (set at source time from RALPH_DIR).
    EXIT_SIGNALS_FILE="$RALPH_DIR/.exit_signals"
}

teardown() {
    cd /
    [[ -n "${TEST_TEMP_DIR:-}" && "$TEST_TEMP_DIR" == */exit_fc.* ]] && rm -rf "$TEST_TEMP_DIR"
    return 0
}

_seed_exit_signals() {
    printf '%s\n' '{"test_only_loops":[],"done_signals":[],"completion_indicators":[]}' \
        > "$RALPH_DIR/.exit_signals"
}

_indicators_len() {
    jq -r '.completion_indicators | length' "$RALPH_DIR/.exit_signals"
}

# ---------------------------------------------------------------------------
# ralph_backlog_verified_empty: 3-state fail-closed gate
# ---------------------------------------------------------------------------

@test "ralph_backlog_verified_empty: file mode returns 0 (out of scope, prior behavior)" {
    export RALPH_TASK_SOURCE=file
    run ralph_backlog_verified_empty
    [[ "$status" -eq 0 ]] || fail "file mode must return 0 (verified empty), got $status"
}

@test "ralph_backlog_verified_empty: linear + open_count 0 -> 0 (verified empty, exit OK)" {
    export RALPH_TASK_SOURCE=linear
    linear_get_open_count() { echo "0"; return 0; }
    run ralph_backlog_verified_empty
    [[ "$status" -eq 0 ]] || fail "open=0 must return 0, got $status"
}

@test "ralph_backlog_verified_empty: linear + open_count 5 -> 1 (verified non-empty, false exit)" {
    export RALPH_TASK_SOURCE=linear
    linear_get_open_count() { echo "5"; return 0; }
    run ralph_backlog_verified_empty
    [[ "$status" -eq 1 ]] || fail "open>0 must return 1, got $status"
}

@test "ralph_backlog_verified_empty: linear + count unavailable (rc!=0) -> 2 (fail closed)" {
    export RALPH_TASK_SOURCE=linear
    linear_get_open_count() { return 1; }
    run ralph_backlog_verified_empty
    [[ "$status" -eq 2 ]] || fail "unavailable count must return 2 (fail closed), got $status"
}

@test "ralph_backlog_verified_empty: linear + non-numeric count -> 2 (fail closed)" {
    export RALPH_TASK_SOURCE=linear
    linear_get_open_count() { echo "garbage"; return 0; }
    run ralph_backlog_verified_empty
    [[ "$status" -eq 2 ]] || fail "non-numeric count must return 2, got $status"
}

# ---------------------------------------------------------------------------
# update_exit_signals_from_status: mcp_disconnect loops cast no exit_signal vote
# ---------------------------------------------------------------------------

@test "update_exit_signals_from_status: exit_signal=true normal loop CASTS a vote" {
    _seed_exit_signals
    printf '%s\n' '{"exit_signal":"true","status":"COMPLETE","tasks_completed":0,"files_modified":0,"work_type":"IMPLEMENTATION","loop_count":7,"mcp_disconnect":false}' \
        > "$RALPH_DIR/status.json"
    update_exit_signals_from_status
    [[ "$(_indicators_len)" -eq 1 ]] || fail "normal exit_signal must add one completion indicator, got $(_indicators_len)"
}

@test "update_exit_signals_from_status: exit_signal=true + mcp_disconnect=true casts NO vote" {
    _seed_exit_signals
    printf '%s\n' '{"exit_signal":"true","status":"BLOCKED","tasks_completed":0,"files_modified":0,"work_type":"IMPLEMENTATION","loop_count":7,"mcp_disconnect":true}' \
        > "$RALPH_DIR/status.json"
    update_exit_signals_from_status
    [[ "$(_indicators_len)" -eq 0 ]] || fail "mcp_disconnect loop must NOT add a completion indicator, got $(_indicators_len)"
}

@test "update_exit_signals_from_status: missing mcp_disconnect field defaults to casting a vote" {
    _seed_exit_signals
    printf '%s\n' '{"exit_signal":"true","status":"COMPLETE","tasks_completed":0,"files_modified":0,"work_type":"IMPLEMENTATION","loop_count":9}' \
        > "$RALPH_DIR/status.json"
    update_exit_signals_from_status
    [[ "$(_indicators_len)" -eq 1 ]] || fail "absent mcp_disconnect must behave as false (vote cast), got $(_indicators_len)"
}

# ---------------------------------------------------------------------------
# Structural: the three quorum sites are gated by the verification helper
# ---------------------------------------------------------------------------

@test "the exit_signal_quorum halt sites call ralph_backlog_verified_empty (fail-closed wiring)" {
    # Per-loop quorum, sentinel honor, and project_complete branch must all gate
    # on the helper — guards against a future edit re-introducing the say-so exit.
    local n
    n=$(grep -c "ralph_backlog_verified_empty" "$REPO_ROOT_FIXED/ralph_loop.sh")
    [[ "$n" -ge 4 ]] || fail "expected >=4 references (defn + 3 gated sites), found $n"
}
