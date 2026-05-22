#!/usr/bin/env bats
# TAP-1899: Halt detector must NOT increment .no_status_block_count on a
# truncated-but-productive loop. Field driver was the AgentForge 2026-05-21
# incident — a 30-min adaptive-timeout killed Claude before the
# `---RALPH_STATUS---` footer was emitted, but `.files_modified_this_loop`
# (maintained by the PreToolUse hook) recorded 15 real file changes. The
# pre-TAP-1899 hook saw the empty status block and tripped no_status_block_3x
# at the start of the next loop, halting a productive campaign.

bats_require_minimum_version 1.5.0
load '../helpers/test_helper'

REPO_ROOT="${BATS_TEST_DIRNAME}/../.."
TEMPLATE_HOOK="${REPO_ROOT}/templates/hooks/on-stop.sh"

setup() {
    export TEST_TEMP_DIR="$(mktemp -d)"
    cd "$TEST_TEMP_DIR"
    export CLAUDE_PROJECT_DIR="$TEST_TEMP_DIR"
    mkdir -p "$TEST_TEMP_DIR/.ralph"
    # The halt detector defaults to threshold=3; pin it for explicitness.
    export RALPH_HALT_NO_STATUS_BLOCK_THRESHOLD=3
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR"
}

# A response payload with NO RALPH_STATUS block — simulates the truncation
# pattern from a timeout. The hook will set _status_block="" downstream.
_no_status_block_input() {
    cat <<'JSON'
{"result":"Did a lot of work but the timeout killed the stream before the status footer."}
JSON
}

# Seed .files_modified_this_loop with N unique paths — this is how the
# PreToolUse on-file-change hook records actual edits during a loop.
_seed_files_modified() {
    local count="$1"
    local f="$TEST_TEMP_DIR/.ralph/.files_modified_this_loop"
    : > "$f"
    local i
    for (( i = 1; i <= count; i++ )); do
        printf 'src/file_%03d.py\n' "$i" >> "$f"
    done
}

# =============================================================================
# TAP-1899: the actual fix
# =============================================================================

@test "TAP-1899: empty status block + files_modified>=1 RESETS the counter (does NOT increment)" {
    # Pre-seed counter at 2 — the pre-fix hook would tip to 3 and halt on this loop.
    printf '%s\n' "2" > "$TEST_TEMP_DIR/.ralph/.no_status_block_count"
    _seed_files_modified 15

    run --separate-stderr bash "$TEMPLATE_HOOK" <<<"$(_no_status_block_input)"
    assert_success

    # Counter must be cleared (file removed), NOT incremented.
    [[ ! -f "$TEST_TEMP_DIR/.ralph/.no_status_block_count" ]] || \
        fail "counter file should have been removed on productive loop, but contains: $(cat "$TEST_TEMP_DIR/.ralph/.no_status_block_count")"

    # Halt sentinel must NOT be written.
    [[ ! -f "$TEST_TEMP_DIR/.ralph/.harness_halt_reason" ]] || \
        fail "halt sentinel was written despite productive loop: $(cat "$TEST_TEMP_DIR/.ralph/.harness_halt_reason")"
}

@test "TAP-1899: empty status block + zero productivity STILL increments + trips at threshold (regression guard)" {
    # Pre-seed at threshold-1 so this loop trips. No .files_modified_this_loop —
    # zero productivity is the real stall case the detector must still catch.
    printf '%s\n' "2" > "$TEST_TEMP_DIR/.ralph/.no_status_block_count"

    run --separate-stderr bash "$TEMPLATE_HOOK" <<<"$(_no_status_block_input)"
    assert_success

    # Halt sentinel must be written.
    [[ -f "$TEST_TEMP_DIR/.ralph/.harness_halt_reason" ]] || \
        fail "halt sentinel was NOT written despite zero-productivity third strike"
    run cat "$TEST_TEMP_DIR/.ralph/.harness_halt_reason"
    [[ "$output" == no_status_block_3x* ]] || \
        fail "halt reason wrong format: $output"
}

@test "TAP-1899: empty status block + first occurrence + zero productivity increments to 1 (does NOT trip)" {
    # No pre-seed — fresh counter. One strike, no halt yet.
    run --separate-stderr bash "$TEMPLATE_HOOK" <<<"$(_no_status_block_input)"
    assert_success

    run cat "$TEST_TEMP_DIR/.ralph/.no_status_block_count"
    assert_output "1"
    [[ ! -f "$TEST_TEMP_DIR/.ralph/.harness_halt_reason" ]] || \
        fail "halt sentinel must NOT be written on first strike"
}

@test "TAP-1899: empty status block + files_modified=0 + zero counter does NOT create an empty counter file" {
    # Defensive: confirm fresh-state path is sane even with no .files_modified_this_loop.
    run --separate-stderr bash "$TEMPLATE_HOOK" <<<"$(_no_status_block_input)"
    assert_success

    # Counter file IS created (counter=1 after this run).
    [[ -f "$TEST_TEMP_DIR/.ralph/.no_status_block_count" ]] || \
        fail "counter file should exist after first strike"
    run cat "$TEST_TEMP_DIR/.ralph/.no_status_block_count"
    assert_output "1"
}
