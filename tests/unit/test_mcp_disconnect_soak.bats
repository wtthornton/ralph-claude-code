#!/usr/bin/env bats
# TAP-2777 soak verification — the merged fix (ralph_reap_orphaned_claude_workers
# + ralph_cleanup_orphaned_mcp on the MCP-disconnect retry path) must keep a long
# disconnect-heavy campaign from accumulating leaked `claude --agent ralph`
# workers and `uv run … serve` MCP servers (the 2026-06-01 incident: 13 workers +
# 28 MCP servers, host load 56).
#
# This is a DETERMINISTIC soak (the ticket's preferred shape over a real live
# run): the process layer is mocked via an in-memory process table so the test
# drives N disconnect→reap cycles without spawning real processes, then asserts
# the live counts stay bounded. A negative-control test proves the soak would
# catch a regression that removed the reap.

REPO_ROOT_FIXED="${BATS_TEST_DIRNAME}/../.."

setup() {
    export TEST_TEMP_DIR="$(mktemp -d "${BATS_TEST_TMPDIR:-/tmp}/mcp_soak.XXXXXX")"
    cd "$TEST_TEMP_DIR"
    mkdir -p .ralph/logs
    export RALPH_DIR="$TEST_TEMP_DIR/.ralph"
    export LOG_DIR="$RALPH_DIR/logs"
    export DRY_RUN=false
    export RALPH_COORDINATOR_DISABLED=true
    set --
    # shellcheck disable=SC1090
    source "$REPO_ROOT_FIXED/ralph_loop.sh"

    # --- Mock process table -------------------------------------------------
    # One line per process: PID|PPID|COMM|CMDLINE
    export PTABLE="$TEST_TEMP_DIR/ptable"
    : > "$PTABLE"

    _pt_add() { printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" >> "$PTABLE"; }
    _pt_exists() { grep -q "^$1|" "$PTABLE" 2>/dev/null; }
    _pt_remove() { grep -v "^$1|" "$PTABLE" > "$PTABLE.tmp" 2>/dev/null || true; mv -f "$PTABLE.tmp" "$PTABLE" 2>/dev/null || true; }
    _pt_field() { awk -F'|' -v p="$1" -v c="$2" '$1==p{print $c}' "$PTABLE" 2>/dev/null; }
    _pt_count() { awk -F'|' -v re="$1" '$4 ~ re' "$PTABLE" 2>/dev/null | grep -c . || true; }

    # Mock pgrep: `-f PATTERN` (cmdline regex) and `-P PPID` (children).
    pgrep() {
        if [[ "$1" == "-f" ]]; then
            awk -F'|' -v re="$2" '$4 ~ re {print $1}' "$PTABLE" 2>/dev/null
        elif [[ "$1" == "-P" ]]; then
            awk -F'|' -v pp="$2" '$2==pp {print $1}' "$PTABLE" 2>/dev/null
        fi
    }

    # Mock ps: `-o ppid= -p PID` and `-o comm= -p PID`.
    ps() {
        local field="$2" pid="$4"
        case "$field" in
            ppid=) _pt_field "$pid" 2 ;;
            comm=) _pt_field "$pid" 3 ;;
        esac
    }

    # Mock kill: `-0 PID` (liveness), `-TERM/-KILL PID [kids...]`, plain `kill PID`.
    kill() {
        local a sig="" pids=()
        for a in "$@"; do
            case "$a" in
                -0) sig="0" ;;
                -*) sig="term" ;;
                *) pids+=("$a") ;;
            esac
        done
        if [[ "$sig" == "0" ]]; then
            _pt_exists "${pids[0]}" && return 0 || return 1
        fi
        local p
        for p in "${pids[@]}"; do _pt_remove "$p"; done
        return 0
    }

    sleep() { :; }  # never actually wait in the reap kill-confirm loop
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR" 2>/dev/null || true
}

@test "TAP-2777 soak: N disconnect-retry cycles keep claude workers ~1 and MCP servers from accumulating" {
    # A legitimately-busy worker with a live, non-reaper parent: must survive
    # every reap (proves the reap is selective, not a blanket kill).
    _pt_add 5000 0 bash "bash ralph supervisor"
    _pt_add 9001 5000 claude "claude --agent ralph ACTIVE invocation"

    local N=10 loop w s max_workers=0 max_servers=0
    for ((loop = 1; loop <= N; loop++)); do
        # Each disconnect loop: the just-disconnected worker hangs and is
        # reparented to init (ppid=1), along with its uv-run MCP servers.
        _pt_add $((1000 + loop)) 1 claude "claude --agent ralph (disconnected loop $loop)"
        _pt_add $((2000 + loop)) 1 uv "uv run tapps-mcp serve"
        _pt_add $((3000 + loop)) 1 uv "uv run docsmcp serve"

        # The retry path reaps before respawn (ralph_loop.sh, mcp_disconnect branch).
        ralph_reap_orphaned_claude_workers
        ralph_cleanup_orphaned_mcp

        w=$(_pt_count 'claude.*--agent ralph')
        s=$(_pt_count '(tapps-mcp|docsmcp).*serve')
        (( w > max_workers )) && max_workers=$w
        (( s > max_servers )) && max_servers=$s
    done

    # Across all N loops the live worker count never exceeds the single active
    # invocation, and orphaned MCP servers never accumulate.
    [[ "$max_workers" -le 1 ]] || fail "claude --agent ralph workers accumulated to $max_workers over $N loops (expected <=1)"
    [[ "$max_servers" -eq 0 ]] || fail "orphaned uv-run MCP servers accumulated to $max_servers over $N loops (expected 0)"

    # The live-parent worker survived every reap.
    run _pt_count 'claude --agent ralph ACTIVE'
    [[ "$output" == "1" ]] || fail "the live-parent worker must not be reaped (got $output)"
}

@test "TAP-2777 soak negative control: WITHOUT the reap, workers and MCP servers climb to N" {
    # Same induced leaks, but skip the reap — proves the positive soak above is
    # not vacuous: a regression that drops ralph_reap_orphaned_claude_workers
    # from the retry path makes the counts grow unbounded.
    local N=10 loop
    for ((loop = 1; loop <= N; loop++)); do
        _pt_add $((1000 + loop)) 1 claude "claude --agent ralph (disconnected loop $loop)"
        _pt_add $((2000 + loop)) 1 uv "uv run tapps-mcp serve"
        # (no reap)
    done

    run _pt_count 'claude.*--agent ralph'
    [[ "$output" == "$N" ]] || fail "expected $N leaked workers without reap, got $output"
    run _pt_count '(tapps-mcp|docsmcp).*serve'
    [[ "$output" == "$N" ]] || fail "expected $N leaked MCP servers without reap, got $output"
}

@test "TAP-2777 soak: mixed live + orphaned workers — only orphans are reaped each cycle" {
    # Two live-parent workers (legit) plus a growing pile of orphans; after the
    # reap only the two legit workers remain, regardless of loop count.
    _pt_add 5000 0 bash "bash supervisor"
    _pt_add 9001 5000 claude "claude --agent ralph legit-A"
    _pt_add 9002 5000 claude "claude --agent ralph legit-B"

    local loop
    for ((loop = 1; loop <= 6; loop++)); do
        _pt_add $((1000 + loop)) 1 claude "claude --agent ralph orphan $loop"
        ralph_reap_orphaned_claude_workers
        run _pt_count 'claude.*--agent ralph'
        [[ "$output" == "2" ]] || fail "loop $loop: expected 2 legit survivors, got $output"
    done
}

@test "TAP-2777 wiring: the mcp_disconnect retry branch reaps before continue" {
    # Structural guard: in ralph_loop.sh the MCP-disconnect retry branch must
    # call ralph_reap_orphaned_claude_workers (and cleanup) before the `continue`,
    # so a disconnect retry can never respawn without first reaping.
    run awk '
        /ralph_loop_was_mcp_disconnect/ { inbranch = 1 }
        inbranch && /ralph_reap_orphaned_claude_workers/ { reap = 1 }
        inbranch && /ralph_cleanup_orphaned_mcp/ { cleanup = 1 }
        inbranch && /continue/ {
            if (reap && cleanup) { print "OK"; exit 0 }
            print "MISSING"; exit 1
        }
    ' "$REPO_ROOT_FIXED/ralph_loop.sh"
    [[ "$status" -eq 0 ]] || fail "reap/cleanup not wired before continue in mcp_disconnect branch"
    [[ "$output" == "OK" ]]
}

@test "TAP-2777 wiring: a disconnect-flagged loop gets the short hard timeout, not the full adaptive" {
    # ralph_mcp_disconnect_timeout caps a post-disconnect retry so a wedged
    # worker cannot linger up to the 60m adaptive budget and leak.
    RALPH_MCP_DISCONNECT_TIMEOUT_SECONDS=120 run ralph_mcp_disconnect_timeout 3600 2
    [[ "$status" -eq 0 ]]
    [[ "$output" == "120" ]] || fail "expected short cap 120 on a disconnect retry, got $output"
}
