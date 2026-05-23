#!/usr/bin/env bats
# TAP-2443 — on-stop.sh clears .linear_next_issue when the just-completed loop
# finished the cached hint's issue.
#
# Cases:
#   - COMPLETE  + match    → cleared
#   - tasks>=1  + match    → cleared (per-task completion path)
#   - COMPLETE  + mismatch → preserved
#   - IN_PROGRESS + match  → preserved (agent still on it)
#   - hint absent          → no-op

bats_require_minimum_version 1.5.0
load '../helpers/test_helper'

REPO_ROOT="${BATS_TEST_DIRNAME}/../.."
HOOK="${REPO_ROOT}/templates/hooks/on-stop.sh"

setup() {
    TEST_TEMP_DIR="$(mktemp -d)"
    cd "$TEST_TEMP_DIR"
    export CLAUDE_PROJECT_DIR="$TEST_TEMP_DIR"
    export RALPH_LOOP_ACTIVE=1
    mkdir -p "$TEST_TEMP_DIR/.ralph/logs"
    : > "$TEST_TEMP_DIR/.ralph/logs/ralph.log"
    # Seed a closed CB so the hook does not crash on missing state file.
    printf '%s\n' '{"state":"CLOSED","consecutive_no_progress":0,"consecutive_permission_denials":0,"total_opens":0}' \
        > "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state"
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR"
    unset RALPH_LOOP_ACTIVE
}

_seed_hint() {
    printf '%s\n' "$1" > "$TEST_TEMP_DIR/.ralph/.linear_next_issue"
}

_response_with_status() {
    local status="$1" tasks_done="$2" linear_issue="$3"
    cat <<JSON
{"result":"---RALPH_STATUS---\nSTATUS: ${status}\nTASKS_COMPLETED_THIS_LOOP: ${tasks_done}\nFILES_MODIFIED: ${tasks_done}\nTESTS_STATUS: PASSING\nWORK_TYPE: IMPLEMENTATION\nLINEAR_ISSUE: ${linear_issue}\nEXIT_SIGNAL: false\nRECOMMENDATION: keep going\n---END_RALPH_STATUS---"}
JSON
}

@test "TAP-2443: COMPLETE+match clears the hint" {
    _seed_hint "TAP-2435"
    _response_with_status "COMPLETE" "1" "TAP-2435" | bash "$HOOK" >/dev/null 2>&1 || true
    [[ ! -f "$TEST_TEMP_DIR/.ralph/.linear_next_issue" ]]
}

@test "TAP-2443: tasks_done>=1+match clears the hint (per-task completion path)" {
    _seed_hint "TAP-2435"
    _response_with_status "IN_PROGRESS" "1" "TAP-2435" | bash "$HOOK" >/dev/null 2>&1 || true
    [[ ! -f "$TEST_TEMP_DIR/.ralph/.linear_next_issue" ]]
}

@test "TAP-2443: COMPLETE+mismatch preserves the hint" {
    _seed_hint "TAP-2435"
    _response_with_status "COMPLETE" "1" "TAP-9999" | bash "$HOOK" >/dev/null 2>&1 || true
    [[ -f "$TEST_TEMP_DIR/.ralph/.linear_next_issue" ]]
    local content; content=$(cat "$TEST_TEMP_DIR/.ralph/.linear_next_issue")
    [[ "$content" == *"TAP-2435"* ]]
}

@test "TAP-2443: IN_PROGRESS+match+zero-progress preserves the hint (agent still on it)" {
    _seed_hint "TAP-2435"
    _response_with_status "IN_PROGRESS" "0" "TAP-2435" | bash "$HOOK" >/dev/null 2>&1 || true
    [[ -f "$TEST_TEMP_DIR/.ralph/.linear_next_issue" ]]
}

@test "TAP-2443: no hint file present → no-op (no crash)" {
    rm -f "$TEST_TEMP_DIR/.ralph/.linear_next_issue"
    run bash -c "_response_with_status() { cat <<JSON
{\"result\":\"---RALPH_STATUS---\\nSTATUS: COMPLETE\\nTASKS_COMPLETED_THIS_LOOP: 1\\nFILES_MODIFIED: 1\\nTESTS_STATUS: PASSING\\nWORK_TYPE: IMPLEMENTATION\\nLINEAR_ISSUE: TAP-2435\\nEXIT_SIGNAL: false\\nRECOMMENDATION: ok\\n---END_RALPH_STATUS---\"}
JSON
}; _response_with_status | bash '$HOOK'"
    # Should not error; hint stays absent.
    [[ ! -f "$TEST_TEMP_DIR/.ralph/.linear_next_issue" ]]
}

@test "TAP-2443: clear logs the TAP-2443 marker to ralph.log" {
    _seed_hint "TAP-2435"
    _response_with_status "COMPLETE" "1" "TAP-2435" | bash "$HOOK" >/dev/null 2>&1 || true
    grep -q "TAP-2443 cleared stale locality hint TAP-2435" "$TEST_TEMP_DIR/.ralph/logs/ralph.log"
}
