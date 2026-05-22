#!/usr/bin/env bats
# T3 / 2.15.8: ralph-monitor sub-agent avg/loop soft-warn

bats_require_minimum_version 1.5.0

REPO_ROOT_FIXED="${BATS_TEST_DIRNAME}/../.."

setup() {
    export TEST_TEMP_DIR="$(mktemp -d "${BATS_TEST_TMPDIR:-/tmp}/sa_warn.XXXXXX")"
    cd "$TEST_TEMP_DIR"
    mkdir -p .ralph/logs
    export RALPH_DIR="$TEST_TEMP_DIR/.ralph"
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR" 2>/dev/null || true
}

write_status() {
    cat > "$RALPH_DIR/status.json"
}

@test "T3: monitor warns when sub-agent session avg > 5/loop" {
    # 3 loops, 20 sub-agents total → avg 6.67 > 5
    write_status <<'EOF'
{
    "loop_count": 3,
    "status": "RUNNING",
    "loop_subagents": {"ralph-explorer": 4, "ralph-tester": 1},
    "session_subagents": {"ralph-explorer": 12, "ralph-tester": 4, "ralph-reviewer": 4},
    "circuit_breaker_state": "CLOSED"
}
EOF
    run timeout 10 "$REPO_ROOT_FIXED/ralph_monitor.sh" --once 2>&1
    [[ "$status" -eq 0 ]] || skip "monitor exited $status; output: ${output:0:200}"
    [[ "$output" == *"WARN"* && "$output" == *"sub-agent avg"* ]] \
        || fail "expected WARN sub-agent avg in output, got: ${output:0:400}"
}

@test "T3: monitor does NOT warn when sub-agent session avg <= 5/loop" {
    # 5 loops, 15 sub-agents → avg 3.0 ≤ 5
    write_status <<'EOF'
{
    "loop_count": 5,
    "status": "RUNNING",
    "loop_subagents": {"ralph-tester": 1},
    "session_subagents": {"ralph-explorer": 5, "ralph-tester": 5, "ralph-reviewer": 5},
    "circuit_breaker_state": "CLOSED"
}
EOF
    run timeout 10 "$REPO_ROOT_FIXED/ralph_monitor.sh" --once 2>&1
    [[ "$status" -eq 0 ]] || skip "monitor exited $status"
    [[ "$output" != *"sub-agent avg"* ]] \
        || fail "unexpected WARN at avg=3.0/loop, got: ${output:0:400}"
}

@test "T3: RALPH_SUBAGENT_AVG_WARN env var raises the threshold" {
    write_status <<'EOF'
{
    "loop_count": 3,
    "status": "RUNNING",
    "loop_subagents": {"ralph-explorer": 4},
    "session_subagents": {"ralph-explorer": 12, "ralph-tester": 4, "ralph-reviewer": 4},
    "circuit_breaker_state": "CLOSED"
}
EOF
    # avg 6.67 > 5 default, but with WARN=10 should be silent
    RALPH_SUBAGENT_AVG_WARN=10 run timeout 10 "$REPO_ROOT_FIXED/ralph_monitor.sh" --once 2>&1
    [[ "$status" -eq 0 ]] || skip "monitor exited $status"
    [[ "$output" != *"sub-agent avg"* ]] \
        || fail "WARN fired despite RALPH_SUBAGENT_AVG_WARN=10, got: ${output:0:400}"
}
