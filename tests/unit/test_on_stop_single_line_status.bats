#!/usr/bin/env bats
# TAP-2494: Single-line RALPH_STATUS parsing in templates/hooks/on-stop.sh.
#
# Root cause of the AgentForge 2026-05-23 idle-runaway ($23.31, 111 loops):
# the hook's field greps are line-anchored (`^[[:space:]]*EXIT_SIGNAL:`), but
# Claude emits the entire RALPH_STATUS block on a single line in many real
# campaigns (no embedded newlines, no ---END_RALPH_STATUS--- terminator).
# The anchor never matches → every field silently defaults → exit_signal=false
# even when the agent emitted true.
#
# Fix: block-normalize sed pass + value-restricted fallback grep. These tests
# pin down each parse shape so the regression cannot recur.

bats_require_minimum_version 1.5.0
load '../helpers/test_helper'

REPO_ROOT="${BATS_TEST_DIRNAME}/../.."
HOOK="${REPO_ROOT}/templates/hooks/on-stop.sh"
FIXTURES="${REPO_ROOT}/tests/fixtures/on_stop_single_line"

setup() {
    export TEST_TEMP_DIR="$(mktemp -d)"
    cd "$TEST_TEMP_DIR"
    # Hook keys off CLAUDE_PROJECT_DIR for the .ralph location.
    export CLAUDE_PROJECT_DIR="$TEST_TEMP_DIR"
    # Session guard: real ralph_loop.sh exports this; without it the hook no-ops.
    export RALPH_LOOP_ACTIVE=1
    mkdir -p "$TEST_TEMP_DIR/.ralph"
    # The hook reads .ralph/.ralph_run_id to detect new sessions; pre-seed.
    echo "test-run-$$" > "$TEST_TEMP_DIR/.ralph/.ralph_run_id"
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR"
}

# Helper: feed a fixture JSON to the hook and report parsed exit_signal value.
_run_hook_with_fixture() {
    local fixture=$1
    cat "$FIXTURES/$fixture" | bash "$HOOK" >/dev/null 2>"$TEST_TEMP_DIR/hook.stderr"
}

_status_field() {
    local field=$1
    jq -r ".$field // \"\"" "$TEST_TEMP_DIR/.ralph/status.json"
}

# =============================================================================
# 1. Documented multi-line shape — must continue to work (no regression)
# =============================================================================
@test "TAP-2494: multi-line ideal RALPH_STATUS parses EXIT_SIGNAL=true" {
    _run_hook_with_fixture "multi_line_ideal.json"
    run _status_field "exit_signal"
    assert_output "true"
}

# =============================================================================
# 2. AgentForge runaway shape — all fields on one line, no END marker
# =============================================================================
@test "TAP-2494: single-line block (no END marker) parses EXIT_SIGNAL=true" {
    _run_hook_with_fixture "single_line_no_end.json"
    run _status_field "exit_signal"
    assert_output "true"
}

@test "TAP-2494: single-line block parses STATUS=COMPLETE" {
    _run_hook_with_fixture "single_line_no_end.json"
    run _status_field "status"
    # status.json doesn't expose 'status' directly — check work_type as proxy
    run _status_field "work_type"
    assert_output "IMPLEMENTATION"
}

# =============================================================================
# 3. Single-line with terminator — common stream-truncation shape
# =============================================================================
@test "TAP-2494: single-line block (with END marker) parses TASKS_COMPLETED=1" {
    _run_hook_with_fixture "single_line_with_end.json"
    run _status_field "tasks_completed"
    assert_output "1"
}

@test "TAP-2494: single-line block (with END marker) parses FILES_MODIFIED=2" {
    _run_hook_with_fixture "single_line_with_end.json"
    run _status_field "files_modified"
    assert_output "2"
}

# =============================================================================
# 4. Indented multi-line — operator-edited fixtures sometimes have leading WS
# =============================================================================
@test "TAP-2494: multi-line block with indented fields parses EXIT_SIGNAL=true" {
    _run_hook_with_fixture "multi_line_indented.json"
    run _status_field "exit_signal"
    assert_output "true"
}

# =============================================================================
# 5. Prose collision — RECOMMENDATION mentions "EXIT_SIGNAL: false" in narrative
#    but the actual block emits EXIT_SIGNAL: true. The legitimate value must win.
# =============================================================================
@test "TAP-2494: prose-collision block — legit EXIT_SIGNAL=true wins over narrative" {
    _run_hook_with_fixture "field_in_prose.json"
    run _status_field "exit_signal"
    assert_output "true"
}

# =============================================================================
# 6. JSONL-escaped — stream output with literal \n characters in the result field
# =============================================================================
@test "TAP-2494: JSONL-escaped newlines parse EXIT_SIGNAL=true" {
    _run_hook_with_fixture "jsonl_escaped.json"
    run _status_field "exit_signal"
    assert_output "true"
}

# =============================================================================
# 7. Explicit EXIT_SIGNAL=false on single-line — must NOT be flipped to true
# =============================================================================
@test "TAP-2494: explicit EXIT_SIGNAL=false on single-line block stays false" {
    _run_hook_with_fixture "exit_false_explicit.json"
    run _status_field "exit_signal"
    assert_output "false"
}

# =============================================================================
# 8. Fallback parser INFO line — emitted ONLY when block-normalize couldn't
#    catch the single-line case via the primary line-anchored path
# =============================================================================
@test "TAP-2494: fallback parser INFO line absent for ideal multi-line input" {
    _run_hook_with_fixture "multi_line_ideal.json"
    # Primary line-anchored grep should catch the multi-line case; fallback
    # must NOT fire for ideal input (regression guard for over-eager fallback).
    run grep -c "fallback parser hit" "$TEST_TEMP_DIR/hook.stderr"
    [[ "$output" == "0" ]]
}
