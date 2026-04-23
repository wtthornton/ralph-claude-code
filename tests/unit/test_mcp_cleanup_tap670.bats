#!/usr/bin/env bats
# Unit Tests for TAP-670: ralph_cleanup_orphaned_mcp parent-alive check
# Verifies orphan detection works via kill -0 fallback, not just PPID==1.

load '../helpers/test_helper'

RALPH_LOOP="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

setup() {
    export TEST_TEMP_DIR="$(mktemp -d)"
    cd "$TEST_TEMP_DIR"
    export RALPH_DIR=".ralph"
    mkdir -p "$RALPH_DIR"

    # Extract just the cleanup function via awk brace-counting (sed gets
    # confused by the inner PSEOF heredoc when using /^}/ as a terminator).
    awk '
        /^ralph_cleanup_orphaned_mcp\(\)/ { in_fn = 1 }
        in_fn {
            print
            # Count opening and closing braces outside heredoc
            for (i = 1; i <= length($0); i++) {
                c = substr($0, i, 1)
                if (c == "{") depth++
                else if (c == "}") {
                    depth--
                    if (depth == 0 && found_open) { exit }
                }
            }
            if (depth > 0) found_open = 1
        }
    ' "$RALPH_LOOP" > /tmp/mcp_cleanup_fn_$$.sh
    # Stub log_status to a no-op (function depends on it)
    log_status() { :; }
    export -f log_status
    # shellcheck disable=SC1091
    source /tmp/mcp_cleanup_fn_$$.sh
    rm -f /tmp/mcp_cleanup_fn_$$.sh
}

teardown() {
    # Best-effort: kill any leftover mock processes from the test
    pkill -f 'ralph-test-tapps-mcp-serve-XXXXXXX' 2>/dev/null || true
    cd /
    rm -rf "$TEST_TEMP_DIR"
}

# Skip the whole file on platforms that can't run the Unix branch
setup_file() {
    if ! command -v pgrep >/dev/null 2>&1; then
        skip "pgrep not available (Windows/MINGW path tested elsewhere)"
    fi
}

@test "TAP-670: cleanup preserves MCP server whose parent is still alive" {
    # Spawn a mock MCP process as a direct child of this test (alive parent).
    # argv must match the pgrep regex: '(tapps-mcp|docsmcp).*serve'
    bash -c 'exec -a "tapps-mcp-ralph-test-tapps-mcp-serve-XXXXXXX serve" sleep 30' &
    local mock_pid=$!

    # Give the exec a moment to rewrite argv
    sleep 0.2

    # Confirm it is visible to pgrep
    pgrep -f '(tapps-mcp|docsmcp).*serve' | grep -q "$mock_pid" || {
        kill "$mock_pid" 2>/dev/null
        skip "pgrep could not find mock process (argv rewriting unsupported)"
    }

    run ralph_cleanup_orphaned_mcp
    [ "$status" -eq 0 ]

    # Parent (this shell) is still alive, so the mock must NOT have been killed
    kill -0 "$mock_pid" 2>/dev/null
    [ "$?" -eq 0 ]

    kill "$mock_pid" 2>/dev/null || true
    wait "$mock_pid" 2>/dev/null || true
}

@test "TAP-670: cleanup kills orphan reparented to PID 1 after parent dies" {
    # Start a wrapper that spawns the MCP mock and then exits, leaving the child
    # reparented to init (PID 1).
    local pid_file
    pid_file=$(mktemp)

    bash -c '
        # Spawn the "MCP server" as a grandchild and write its PID
        setsid bash -c "exec -a \"tapps-mcp-ralph-test-tapps-mcp-serve-XXXXXXX serve\" sleep 60" </dev/null >/dev/null 2>&1 &
        echo $! > "$1"
        # Parent exits immediately; child is reparented to PID 1
    ' _ "$pid_file"

    # Wait for wrapper to exit and grandchild to be reparented
    sleep 0.5

    local mock_pid
    mock_pid=$(cat "$pid_file")
    rm -f "$pid_file"

    # Confirm it's running and its parent has become the namespace init (PID 1 in
    # most setups; on systemd-user a different reaper PID — either way we want
    # cleanup to kill it).
    if ! kill -0 "$mock_pid" 2>/dev/null; then
        skip "Mock process died before reparenting check"
    fi

    local ppid
    ppid=$(ps -o ppid= -p "$mock_pid" 2>/dev/null | tr -d ' ')
    [ -n "$ppid" ]
    # Parent must be either PID 1 (classic) or a living reaper — in both cases
    # ralph_cleanup_orphaned_mcp should kill the process after our fix.

    run ralph_cleanup_orphaned_mcp
    [ "$status" -eq 0 ]

    # Give kill a moment to land
    sleep 0.2

    # Process should be gone
    if kill -0 "$mock_pid" 2>/dev/null; then
        # Show why we failed
        echo "Mock $mock_pid still alive after cleanup. ppid=$ppid"
        ps -o pid,ppid,comm,args -p "$mock_pid" 2>/dev/null || true
        # Clean up before failing
        kill "$mock_pid" 2>/dev/null || true
        return 1
    fi
}

@test "TAP-670: cleanup handles empty ppid without killing unrelated processes" {
    # This guards the defensive '[[ -z \"\$ppid\" ]] && continue' branch.
    # We can't easily create a process whose ppid is unreadable, so instead
    # we verify the function tolerates zero matches cleanly.
    run ralph_cleanup_orphaned_mcp
    [ "$status" -eq 0 ]
    # No output on empty case (log_status is stubbed)
    [ -z "$output" ]
}
