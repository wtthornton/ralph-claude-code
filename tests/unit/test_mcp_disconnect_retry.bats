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
# ralph_mcp_health_gate (TAP-2786: default ON, self-skips when tapps not used)
# ---------------------------------------------------------------------------
@test "ralph_mcp_health_gate: default ON (no env) — structural default is :-true" {
    # Guard against a silent revert of the TAP-2786 default flip.
    run grep -E 'RALPH_MCP_HEALTH_GATE:-true' "$REPO_ROOT_FIXED/ralph_loop.sh"
    [[ "$status" -eq 0 ]] || fail "expected RALPH_MCP_HEALTH_GATE default to be :-true"
}

@test "ralph_mcp_health_gate: explicit opt-out (=false) is a no-op, no probe" {
    export RALPH_MCP_HEALTH_GATE=false
    export RALPH_MCP_TAPPS_EXPECTED=true
    ralph_probe_mcp_servers() { echo "PROBE RAN" >&2; return 1; }
    run ralph_mcp_health_gate
    [[ "$status" -eq 0 ]] || fail "opt-out should return 0"
    [[ "$output" != *"PROBE RAN"* ]] || fail "gate must not probe when opted out"
}

@test "ralph_mcp_health_gate: default ON but tapps not expected — self-skip, no probe" {
    unset RALPH_MCP_HEALTH_GATE
    export RALPH_MCP_TAPPS_EXPECTED=false   # file-mode / no-tapps-mcp project
    ralph_probe_mcp_servers() { echo "PROBE RAN" >&2; return 1; }
    run ralph_mcp_health_gate
    [[ "$status" -eq 0 ]] || fail "self-skip should return 0"
    [[ "$output" != *"PROBE RAN"* ]] || fail "gate must not probe a non-tapps project"
}

@test "ralph_mcp_health_gate: default ON + tapps expected + reachable — returns 0 (does probe)" {
    unset RALPH_MCP_HEALTH_GATE
    export RALPH_MCP_TAPPS_EXPECTED=true
    ralph_probe_mcp_servers() { echo "PROBE RAN" >&2; export RALPH_MCP_TAPPS_AVAILABLE=true; }
    run ralph_mcp_health_gate
    [[ "$status" -eq 0 ]] || fail "healthy probe should return 0"
    [[ "$output" == *"PROBE RAN"* ]] || fail "gate should probe when tapps is expected"
}

@test "ralph_mcp_health_gate: tapps expected but unreachable — returns 0 after retries" {
    export RALPH_MCP_HEALTH_GATE=true
    export RALPH_MCP_TAPPS_EXPECTED=true
    export RALPH_MCP_RETRY_MAX=2
    sleep() { :; }  # don't actually back off
    ralph_probe_mcp_servers() { export RALPH_MCP_TAPPS_AVAILABLE=false; }
    run ralph_mcp_health_gate
    [[ "$status" -eq 0 ]] || fail "must always return 0 even when still down"
    [[ "$output" == *"unreachable"* ]] || fail "expected an unreachable WARN"
}

# ---------------------------------------------------------------------------
# TAP-2777: MCP-disconnect worker-leak guards
# ---------------------------------------------------------------------------

# ralph_mcp_disconnect_timeout: cap a post-disconnect retry's timeout
@test "ralph_mcp_disconnect_timeout: caps to short value when prior loop disconnected" {
    RALPH_MCP_DISCONNECT_TIMEOUT_SECONDS=120 run ralph_mcp_disconnect_timeout 900 2
    [[ "$status" -eq 0 ]]
    [[ "$output" == "120" ]] || fail "expected short cap 120, got: $output"
}

@test "ralph_mcp_disconnect_timeout: keeps nominal when not a disconnect retry (count 0)" {
    RALPH_MCP_DISCONNECT_TIMEOUT_SECONDS=120 run ralph_mcp_disconnect_timeout 900 0
    [[ "$output" == "900" ]] || fail "expected nominal 900, got: $output"
}

@test "ralph_mcp_disconnect_timeout: keeps nominal when it is already shorter than the cap" {
    RALPH_MCP_DISCONNECT_TIMEOUT_SECONDS=120 run ralph_mcp_disconnect_timeout 90 3
    [[ "$output" == "90" ]] || fail "expected nominal 90, got: $output"
}

@test "ralph_mcp_disconnect_timeout: non-numeric blocked count treated as 0 (no cap)" {
    RALPH_MCP_DISCONNECT_TIMEOUT_SECONDS=120 run ralph_mcp_disconnect_timeout 900 ""
    [[ "$output" == "900" ]] || fail "expected nominal 900, got: $output"
}

# portable_timeout: --kill-after wiring (TAP-2777)
@test "portable_timeout: passes --kill-after when RALPH_TIMEOUT_KILL_AFTER set" {
    mkdir -p "$TEST_TEMP_DIR/bin"
    printf '#!/usr/bin/env bash\necho "ARGS:$*"\n' > "$TEST_TEMP_DIR/bin/timeout"
    chmod +x "$TEST_TEMP_DIR/bin/timeout"
    PATH="$TEST_TEMP_DIR/bin:$PATH"
    reset_timeout_detection
    export RALPH_TIMEOUT_KILL_AFTER=15s
    run portable_timeout 60s echo hi
    [[ "$output" == *"--kill-after=15s"* ]] || fail "expected --kill-after in: $output"
    [[ "$output" == *"60s"* ]] || fail "expected duration in: $output"
}

@test "portable_timeout: omits --kill-after when RALPH_TIMEOUT_KILL_AFTER unset" {
    mkdir -p "$TEST_TEMP_DIR/bin"
    printf '#!/usr/bin/env bash\necho "ARGS:$*"\n' > "$TEST_TEMP_DIR/bin/timeout"
    chmod +x "$TEST_TEMP_DIR/bin/timeout"
    PATH="$TEST_TEMP_DIR/bin:$PATH"
    reset_timeout_detection
    unset RALPH_TIMEOUT_KILL_AFTER
    run portable_timeout 60s echo hi
    [[ "$output" != *"--kill-after"* ]] || fail "did not expect --kill-after in: $output"
}

# ralph_reap_orphaned_claude_workers: safety + kill behavior via mocks
_install_reaper_mocks() {
    # Mock pgrep: -f returns $FAKE_CLAUDE_PID, -P returns nothing.
    # Mock ps:   -o ppid= echoes $FAKE_PPID, -o comm= echoes $FAKE_PCOMM.
    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/pgrep" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "-f" ]] && { echo "${FAKE_CLAUDE_PID}"; exit 0; }
exit 0
EOF
    cat > "$TEST_TEMP_DIR/bin/ps" <<'EOF'
#!/usr/bin/env bash
case "$2" in
  ppid=) echo "${FAKE_PPID}" ;;
  comm=) echo "${FAKE_PCOMM}" ;;
esac
EOF
    chmod +x "$TEST_TEMP_DIR/bin/pgrep" "$TEST_TEMP_DIR/bin/ps"
    PATH="$TEST_TEMP_DIR/bin:$PATH"
}

@test "ralph_reap_orphaned_claude_workers: no-op (returns 0) when no workers match" {
    _install_reaper_mocks
    export FAKE_CLAUDE_PID=""   # pgrep -f returns nothing
    run ralph_reap_orphaned_claude_workers
    [[ "$status" -eq 0 ]] || fail "reaper must always return 0"
}

@test "ralph_reap_orphaned_claude_workers: does NOT kill a worker with a live non-reaper parent" {
    _install_reaper_mocks
    sleep 300 &
    local target=$!
    export FAKE_CLAUDE_PID="$target"
    export FAKE_PPID="$$"        # live, non-reaper parent
    export FAKE_PCOMM="bash"
    ralph_reap_orphaned_claude_workers
    kill -0 "$target" 2>/dev/null || fail "non-orphan worker must NOT be killed"
    kill "$target" 2>/dev/null || true
}

@test "ralph_reap_orphaned_claude_workers: kills an orphaned (ppid=1) worker" {
    _install_reaper_mocks
    sleep 300 &
    local target=$!
    export FAKE_CLAUDE_PID="$target"
    export FAKE_PPID="1"         # reparented to init => orphan
    export FAKE_PCOMM="init"
    ralph_reap_orphaned_claude_workers
    sleep 0.2
    if kill -0 "$target" 2>/dev/null; then
        kill "$target" 2>/dev/null || true
        fail "orphaned worker must be killed"
    fi
}
