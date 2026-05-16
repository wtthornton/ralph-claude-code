#!/usr/bin/env bats
# TAP-1877: exec_log_execution_stats must NOT print multi-zero counters
# in the post-run Execution stats line. The original inline implementation
# in exec_run_live paired `grep -c | ... || echo 0` with `tr -d '[:space:]'`,
# which collapsed grep's "0\n0" no-match output into the literal "00" that
# leaked through to the WARN line ("(00 scope, N system)" — observed on 9
# of 50 lines in the 2026-05-15 → 2026-05-16 tapps-brain ralph.log).

bats_require_minimum_version 1.5.0

PROJECT_ROOT="${BATS_TEST_DIRNAME}/../.."

setup() {
    export TEST_DIR="$(mktemp -d "${BATS_TEST_TMPDIR:-/tmp}/exec_post_run.XXXXXX")"
    # Stub log_status so we can capture the emitted line in stdout.
    log_status() {
        # First arg is the level (INFO|WARN|ERROR); rest is the message.
        printf '%s: %s\n' "$1" "$2"
    }
    export -f log_status

    # shellcheck disable=SC1090
    source "$PROJECT_ROOT/lib/exec_helpers.sh"
}

teardown() {
    rm -rf "$TEST_DIR" 2>/dev/null || true
}

# Build a synthetic Claude NDJSON stream with a given number of is_error:true
# entries, optionally one of them matching a tool-scope pattern.
#
# Usage: make_stream <output_path> <total_errors> <scope_matches>
make_stream() {
    local out="$1"
    local total="${2:-0}"
    local scope_matches="${3:-0}"

    : > "$out"
    local i=0
    while (( i < scope_matches )); do
        # Pair the scope-pattern line with the is_error sentinel so the
        # `grep -B1 '"is_error":true' | grep -ciE 'permission|...'` filter
        # picks it up. grep -B1 emits the preceding line + the matching
        # line, then the inner grep matches the scope pattern on either.
        printf '{"type":"tool_result","content":"permission denied to write /etc/foo"}\n' >> "$out"
        printf '{"type":"tool_result","is_error":true}\n' >> "$out"
        i=$(( i + 1 ))
    done
    local non_scope=$(( total - scope_matches ))
    while (( non_scope > 0 )); do
        printf '{"type":"tool_result","content":"connection reset by peer"}\n' >> "$out"
        printf '{"type":"tool_result","is_error":true}\n' >> "$out"
        non_scope=$(( non_scope - 1 ))
    done
}

@test "TAP-1877: zero errors → INFO line, no scope/system counters" {
    local stream="$TEST_DIR/stream.log"
    make_stream "$stream" 0 0

    run exec_log_execution_stats "$stream" 7 1 0
    [[ "$status" -eq 0 ]] || fail "expected zero exit, got $status: $output"
    [[ "$output" == *"INFO: Execution stats: Tools=7 Agents=1 Errors=0"* ]] \
        || fail "expected INFO line with Errors=0, got: $output"
    [[ "$output" != *"scope"* ]] \
        || fail "INFO line should not mention scope/system, got: $output"
}

@test "TAP-1877: errors with zero scope matches prints '(0 scope, N system)' — NOT '(00 scope, …)'" {
    # This is the canonical regression case the ticket cites: 2 is_error
    # entries, neither matching the scope pattern. The buggy code would
    # emit `(00 scope, 2 system)`; the fixed code emits `(0 scope, 2 system)`.
    local stream="$TEST_DIR/stream.log"
    make_stream "$stream" 2 0

    run exec_log_execution_stats "$stream" 5 0 2
    [[ "$status" -eq 0 ]] || fail "expected zero exit, got $status: $output"
    [[ "$output" == *"(0 scope, "* ]] \
        || fail "expected '(0 scope, ' in WARN line, got: $output"
    [[ "$output" != *"(00 scope"* ]] \
        || fail "double-zero leak still present, got: $output"
    [[ "$output" == *"(0 scope, 2 system)"* ]] \
        || fail "expected '(0 scope, 2 system)' suffix, got: $output"
}

@test "TAP-1877: mixed scope + system errors splits the count correctly" {
    local stream="$TEST_DIR/stream.log"
    # 3 total errors — 1 scope-pattern match (permission denied), 2 system.
    make_stream "$stream" 3 1

    run exec_log_execution_stats "$stream" 4 0 3
    [[ "$status" -eq 0 ]] || fail "expected zero exit, got $status: $output"
    [[ "$output" == *"Errors=3"* ]] \
        || fail "expected Errors=3, got: $output"
    [[ "$output" == *"(1 scope, 2 system)"* ]] \
        || fail "expected '(1 scope, 2 system)' suffix, got: $output"
}

@test "TAP-1877: system clamps to 0 when scope count exceeds error count" {
    # Defensive: if grep -B1 matches both a context line AND its is_error
    # sentinel for the same record, scope could nominally exceed total.
    # The arithmetic clamp must keep system_errors >= 0.
    local stream="$TEST_DIR/stream.log"
    # 1 error, but the scope pattern appears on both the context line and
    # the is_error line — `grep -ciE` returns 2.
    {
        printf '{"type":"tool_result","content":"permission denied to write"}\n'
        printf '{"type":"tool_result","is_error":true,"content":"permission denied"}\n'
    } > "$stream"

    run exec_log_execution_stats "$stream" 1 0 1
    [[ "$status" -eq 0 ]] || fail "expected zero exit, got $status: $output"
    # The system value MUST never go negative regardless of grep arithmetic.
    [[ "$output" != *"-1 system"* && "$output" != *"-2 system"* ]] \
        || fail "system_errors leaked negative value, got: $output"
}

@test "TAP-1877: missing output_file falls back to '0 scope' without crashing" {
    # Defensive: grep on a non-existent file returns 1 with empty stdout.
    # `tr -cd '0-9'` empties to "", `${var:-0}` defaults to 0.
    run exec_log_execution_stats "$TEST_DIR/does-not-exist.log" 0 0 2
    [[ "$status" -eq 0 ]] || fail "expected zero exit on missing file, got $status: $output"
    [[ "$output" == *"(0 scope, 2 system)"* ]] \
        || fail "expected '(0 scope, 2 system)' on missing file, got: $output"
    [[ "$output" != *"(00 scope"* ]] \
        || fail "double-zero leak on missing file path, got: $output"
}
