#!/usr/bin/env bats
# MCP-DISCONNECT-RETRY (2026-06-01): ralph_loop.sh side of the transient
# MCP-disconnect handling. on-stop.sh sets status.json .mcp_disconnect=true; the
# main loop reads it via ralph_loop_was_mcp_disconnect, resets the session, and
# retries with a fresh Claude invocation (backoff via ralph_mcp_retry_backoff)
# instead of counting the loop toward the no-progress circuit breaker.

bats_require_minimum_version 1.5.0

REPO_ROOT_FIXED="${BATS_TEST_DIRNAME}/../.."

setup() {
    export TEST_TEMP_DIR="$(mktemp -d "${BATS_TEST_TMPDIR:-/tmp}/mcp_dc.XXXXXX")"
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

# ---------------------------------------------------------------------------
# ralph_loop_was_mcp_disconnect: reads the structured flag from status.json
# ---------------------------------------------------------------------------
@test "ralph_loop_was_mcp_disconnect: true when status.json .mcp_disconnect=true" {
    _write_status '{"mcp_disconnect":true,"files_modified":0,"tasks_completed":0}'
    run ralph_loop_was_mcp_disconnect
    [[ "$status" -eq 0 ]] || fail "expected disconnect detected"
}

@test "ralph_loop_was_mcp_disconnect: false when .mcp_disconnect=false" {
    _write_status '{"mcp_disconnect":false,"files_modified":0,"tasks_completed":0}'
    run ralph_loop_was_mcp_disconnect
    [[ "$status" -ne 0 ]] || fail "expected no disconnect"
}

@test "ralph_loop_was_mcp_disconnect: false when field absent (older status.json)" {
    _write_status '{"files_modified":0,"tasks_completed":0}'
    run ralph_loop_was_mcp_disconnect
    [[ "$status" -ne 0 ]] || fail "missing field must not be treated as disconnect"
}

@test "ralph_loop_was_mcp_disconnect: false when status.json missing" {
    rm -f "$RALPH_DIR/status.json"
    run ralph_loop_was_mcp_disconnect
    [[ "$status" -ne 0 ]] || fail "missing status.json must not be treated as disconnect"
}

# ---------------------------------------------------------------------------
# ralph_mcp_retry_backoff: escalating 2s/5s/10s schedule (stub sleep)
# ---------------------------------------------------------------------------
@test "ralph_mcp_retry_backoff: escalates 2s, 5s, 10s, capped" {
    # Stub sleep so the test does not actually wait, and capture the argument.
    sleep() { echo "$1" >> "$TEST_TEMP_DIR/.sleeps"; }
    ralph_mcp_retry_backoff 1
    ralph_mcp_retry_backoff 2
    ralph_mcp_retry_backoff 3
    ralph_mcp_retry_backoff 7
    run cat "$TEST_TEMP_DIR/.sleeps"
    [[ "${lines[0]}" == "2" ]]  || fail "attempt 1 -> 2s, got ${lines[0]}"
    [[ "${lines[1]}" == "5" ]]  || fail "attempt 2 -> 5s, got ${lines[1]}"
    [[ "${lines[2]}" == "10" ]] || fail "attempt 3 -> 10s, got ${lines[2]}"
    [[ "${lines[3]}" == "10" ]] || fail "attempt 7 -> 10s (cap), got ${lines[3]}"
}

# ---------------------------------------------------------------------------
# ralph_mcp_health_gate: no-op (returns 0) unless explicitly enabled
# ---------------------------------------------------------------------------
@test "ralph_mcp_health_gate: no-op return 0 when RALPH_MCP_HEALTH_GATE unset" {
    unset RALPH_MCP_HEALTH_GATE
    # Fail loudly if it tries to probe — the gate must short-circuit first.
    ralph_probe_mcp_servers() { echo "PROBE RAN" >&2; return 1; }
    run ralph_mcp_health_gate
    [[ "$status" -eq 0 ]] || fail "gate should be a no-op returning 0"
    [[ "$output" != *"PROBE RAN"* ]] || fail "gate must not probe when disabled"
}

@test "ralph_mcp_health_gate: returns 0 once tapps probe reports reachable" {
    export RALPH_MCP_HEALTH_GATE=true
    ralph_probe_mcp_servers() { export RALPH_MCP_TAPPS_AVAILABLE=true; }
    run ralph_mcp_health_gate
    [[ "$status" -eq 0 ]] || fail "healthy probe should return 0"
}
