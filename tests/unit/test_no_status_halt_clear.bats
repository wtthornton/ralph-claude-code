#!/usr/bin/env bats
# TAP-2636: ralph_no_status_halt_is_benign() — startup safety net that
# auto-clears a no_status_block_Nx halt sentinel when the prior loop's
# status.json shows the campaign actually did work (the missing RALPH_STATUS
# footer was cosmetic, not a genuine stall). Genuine no-progress halts keep
# the hard halt.

bats_require_minimum_version 1.5.0

REPO_ROOT_FIXED="${BATS_TEST_DIRNAME}/../.."

setup() {
    export TEST_TEMP_DIR="$(mktemp -d "${BATS_TEST_TMPDIR:-/tmp}/nsb_clear.XXXXXX")"
    cd "$TEST_TEMP_DIR"
    mkdir -p .ralph/logs
    export RALPH_DIR="$TEST_TEMP_DIR/.ralph"
    export LOG_DIR="$RALPH_DIR/logs"
    export DRY_RUN=false
    export RALPH_COORDINATOR_DISABLED=true
    set --
    # shellcheck disable=SC1090
    source "$REPO_ROOT_FIXED/ralph_loop.sh"
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR" 2>/dev/null || true
}

_write_status() {
    printf '%s\n' "$1" > "$RALPH_DIR/status.json"
}

@test "TAP-2636: benign when tasks_completed >= 1" {
    _write_status '{"tasks_completed":1,"files_modified":0,"exit_signal":"false"}'
    run ralph_no_status_halt_is_benign
    [[ "$status" -eq 0 ]] || fail "tasks_completed>=1 should be benign"
}

@test "TAP-2636: benign when files_modified >= 1" {
    _write_status '{"tasks_completed":0,"files_modified":3,"exit_signal":"false"}'
    run ralph_no_status_halt_is_benign
    [[ "$status" -eq 0 ]] || fail "files_modified>=1 should be benign"
}

@test "TAP-2636: benign when exit_signal == true" {
    _write_status '{"tasks_completed":0,"files_modified":0,"exit_signal":"true"}'
    run ralph_no_status_halt_is_benign
    [[ "$status" -eq 0 ]] || fail "exit_signal=true should be benign"
}

@test "TAP-2636: NOT benign on a genuine no-progress loop (all zero/false)" {
    _write_status '{"tasks_completed":0,"files_modified":0,"exit_signal":"false"}'
    run ralph_no_status_halt_is_benign
    [[ "$status" -eq 1 ]] || fail "zero-progress loop must keep the hard halt"
}

@test "TAP-2636: NOT benign when status.json is missing" {
    rm -f "$RALPH_DIR/status.json"
    run ralph_no_status_halt_is_benign
    [[ "$status" -eq 1 ]] || fail "missing status.json must keep the hard halt"
}

@test "TAP-2636: NOT benign on malformed status.json (defaults to zero)" {
    _write_status 'not json at all'
    run ralph_no_status_halt_is_benign
    [[ "$status" -eq 1 ]] || fail "malformed status.json must keep the hard halt"
}
