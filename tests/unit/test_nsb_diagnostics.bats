#!/usr/bin/env bats
# TAP-2441 — Diagnostic logging around the no_status_block_3x counter
# + productivity-guard fixture for AgentForge 2026-05-22 loop #5 shape
# (files_modified=29 reported, response_bytes=385 captured).

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
    printf '%s\n' '{"state":"CLOSED","consecutive_no_progress":0,"consecutive_permission_denials":0,"total_opens":0}' \
        > "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state"
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR"
    unset RALPH_LOOP_ACTIVE
}

@test "TAP-2441: diagnostic line written on no-status-block increment" {
    # Empty result text → no status block, no files_modified, no tasks_done →
    # counter increments → diagnostic should fire.
    printf '%s' '{"result":"just chatting, no status block here"}' | bash "$HOOK" >/dev/null 2>&1 || true
    grep -q "TAP-2441 nsb-increment-to-1" "$TEST_TEMP_DIR/.ralph/logs/ralph.log"
}

@test "TAP-2441: diagnostic line written on productivity-guard reset (truncated-but-productive)" {
    # Simulate the AgentForge 2026-05-22 loop #5 shape: response is small
    # (no status block in it) but .files_modified_this_loop has real entries.
    # Productivity guard fires → counter reset → diagnostic should fire.
    printf 'src/foo.py\nsrc/bar.py\n' > "$TEST_TEMP_DIR/.ralph/.files_modified_this_loop"
    # Pre-seed the counter so we can observe the reset path.
    printf '%s\n' "1" > "$TEST_TEMP_DIR/.ralph/.no_status_block_count"
    printf '%s' '{"result":"work done, stream truncated before status footer"}' \
        | bash "$HOOK" >/dev/null 2>&1 || true
    grep -q "TAP-2441 nsb-productivity-reset" "$TEST_TEMP_DIR/.ralph/logs/ralph.log"
    [[ ! -f "$TEST_TEMP_DIR/.ralph/.no_status_block_count" ]]
}

@test "TAP-2441: diagnostic line written on successful-parse reset" {
    # First call: trip counter to 1 (no status block).
    printf '%s' '{"result":"no block"}' | bash "$HOOK" >/dev/null 2>&1 || true
    [[ -f "$TEST_TEMP_DIR/.ralph/.no_status_block_count" ]]
    # Second call: valid status block → reset path → diagnostic fires.
    cat <<'JSON' | bash "$HOOK" >/dev/null 2>&1 || true
{"result":"---RALPH_STATUS---\nSTATUS: IN_PROGRESS\nTASKS_COMPLETED_THIS_LOOP: 0\nFILES_MODIFIED: 0\nTESTS_STATUS: NOT_RUN\nWORK_TYPE: IMPLEMENTATION\nEXIT_SIGNAL: false\nRECOMMENDATION: continuing\n---END_RALPH_STATUS---"}
JSON
    grep -q "TAP-2441 nsb-successful-parse-reset" "$TEST_TEMP_DIR/.ralph/logs/ralph.log"
    [[ ! -f "$TEST_TEMP_DIR/.ralph/.no_status_block_count" ]]
}

@test "TAP-2441: AgentForge loop #5 fixture — 29 files modified, productivity guard fires" {
    # The exact AgentForge symptom: status block reports FILES_MODIFIED: 29,
    # but the captured response_bytes is small. Even with the status block
    # present, the productivity guard at TAP-1899 should keep the counter at
    # zero on this loop (productive parse), and the no-status-block branch
    # must NOT fire its increment path.
    printf 'a.py\nb.py\nc.py\n' > "$TEST_TEMP_DIR/.ralph/.files_modified_this_loop"
    cat <<'JSON' | bash "$HOOK" >/dev/null 2>&1 || true
{"result":"---RALPH_STATUS---\nSTATUS: IN_PROGRESS\nTASKS_COMPLETED_THIS_LOOP: 2\nFILES_MODIFIED: 29\nTESTS_STATUS: PASSING\nWORK_TYPE: IMPLEMENTATION\nEXIT_SIGNAL: false\nRECOMMENDATION: continuing\n---END_RALPH_STATUS---"}
JSON
    # No counter file should exist (parse succeeded, status block found, reset path skipped because counter was never set).
    [[ ! -f "$TEST_TEMP_DIR/.ralph/.no_status_block_count" ]]
    # No halt-reason should have been written.
    [[ ! -f "$TEST_TEMP_DIR/.ralph/.harness_halt_reason" ]]
}

@test "TAP-2441: diagnostic includes response_bytes, files_modified_this_loop_present, actual_files" {
    printf 'one.py\ntwo.py\n' > "$TEST_TEMP_DIR/.ralph/.files_modified_this_loop"
    printf '%s' '{"result":"hello world this is some text without a status footer"}' \
        | bash "$HOOK" >/dev/null 2>&1 || true
    local line
    line=$(grep "TAP-2441 nsb-" "$TEST_TEMP_DIR/.ralph/logs/ralph.log" | tail -1)
    [[ "$line" == *"response_bytes="* ]]
    [[ "$line" == *"files_modified_this_loop_present=true"* ]]
    [[ "$line" == *"actual_files=2"* ]]
}
