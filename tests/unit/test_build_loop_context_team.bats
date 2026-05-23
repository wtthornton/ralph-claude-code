#!/usr/bin/env bats
# TAP-2440 — build_loop_context injects RALPH_LINEAR_TEAM when set.
#
# When RALPH_LINEAR_TEAM is non-empty, the per-loop prompt must include a
# `TASK TEAM: '<team>'` directive so the agent passes the team to Linear MCP
# calls instead of guessing from the project name. When unset, the directive
# must be omitted (backwards-compat with projects where project prefixes team).

bats_require_minimum_version 1.5.0
load '../helpers/test_helper'

REPO_ROOT="${BATS_TEST_DIRNAME}/../.."

setup() {
    TEST_TEMP_DIR="$(mktemp -d)"
    cd "$TEST_TEMP_DIR"
    export CLAUDE_PROJECT_DIR="$TEST_TEMP_DIR"
    mkdir -p "$TEST_TEMP_DIR/.ralph/logs"
    : > "$TEST_TEMP_DIR/.ralph/logs/ralph.log"
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR"
    unset RALPH_LINEAR_TEAM
    unset RALPH_LINEAR_PROJECT
    unset RALPH_TASK_SOURCE
}

_source_build_loop_context() {
    log_status() { :; }
    ralph_sanitize_prompt_text() { local n="${1:-300}"; tr -d '\0' | head -c "$n"; }
    linear_get_open_count()        { return 1; }
    linear_get_in_progress_task()  { echo ""; }
    linear_get_next_task()         { echo ""; }
    ralph_inject_continue_state()  { echo ""; }
    ralph_probe_mcp_servers()      { :; }
    ralph_task_is_docs_related()   { return 1; }
    export -f log_status ralph_sanitize_prompt_text \
              linear_get_open_count linear_get_in_progress_task \
              linear_get_next_task ralph_inject_continue_state \
              ralph_probe_mcp_servers ralph_task_is_docs_related

    eval "$(awk '/^build_loop_context\(\) \{$/,/^\}$/' "$REPO_ROOT/ralph_loop.sh")"

    export RALPH_DIR="$TEST_TEMP_DIR/.ralph"
    export RALPH_TASK_SOURCE="linear"
    export RALPH_LINEAR_PROJECT="AgentForge Platform"
    export RALPH_CONTINUE_STATE_FILE="$TEST_TEMP_DIR/.ralph/.nonexistent"
    export RALPH_MCP_DOCS_AVAILABLE=false
    export RALPH_MCP_TAPPS_AVAILABLE=false
    export RALPH_MCP_BRAIN_AVAILABLE=false
    export SCRIPT_DIR="$REPO_ROOT"
}

@test "TAP-2440: build_loop_context injects TASK TEAM directive when RALPH_LINEAR_TEAM is set" {
    _source_build_loop_context
    export RALPH_LINEAR_TEAM="TappsCodingAgents"
    run build_loop_context 7
    assert_success
    [[ "$output" == *"TASK TEAM: 'TappsCodingAgents'"* ]]
    [[ "$output" == *"ALWAYS pass team='TappsCodingAgents' to Linear MCP calls"* ]]
}

@test "TAP-2440: build_loop_context omits TASK TEAM directive when RALPH_LINEAR_TEAM is unset" {
    _source_build_loop_context
    unset RALPH_LINEAR_TEAM
    run build_loop_context 7
    assert_success
    [[ "$output" != *"TASK TEAM:"* ]]
}

@test "TAP-2440: build_loop_context omits TASK TEAM directive when RALPH_LINEAR_TEAM is empty string" {
    _source_build_loop_context
    export RALPH_LINEAR_TEAM=""
    run build_loop_context 7
    assert_success
    [[ "$output" != *"TASK TEAM:"* ]]
}

@test "TAP-2440: TASK TEAM directive appears AFTER TASK SOURCE directive" {
    _source_build_loop_context
    export RALPH_LINEAR_TEAM="TappsCodingAgents"
    run build_loop_context 7
    assert_success
    # awk index of each marker; team must come after project so the agent
    # reads project context first.
    local src_pos team_pos
    src_pos=$(awk 'BEGIN{RS="\0"} {n=index($0,"TASK SOURCE:"); print n; exit}' <<<"$output")
    team_pos=$(awk 'BEGIN{RS="\0"} {n=index($0,"TASK TEAM:"); print n; exit}' <<<"$output")
    [[ "$src_pos" -gt 0 ]]
    [[ "$team_pos" -gt 0 ]]
    [[ "$team_pos" -gt "$src_pos" ]]
}
