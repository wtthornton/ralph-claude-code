#!/usr/bin/env bats
# TAP-2444 — build_loop_context emits a canonical MCP tool list to pre-warm
# the deferred-tool surface and cut the per-loop ToolSearch tax.

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
    unset RALPH_MCP_DOCS_AVAILABLE RALPH_MCP_TAPPS_AVAILABLE RALPH_MCP_BRAIN_AVAILABLE
    unset RALPH_TASK_SOURCE RALPH_LINEAR_PROJECT
}

_source_build_loop_context() {
    log_status() { :; }
    ralph_sanitize_prompt_text() { local n="${1:-300}"; tr -d '\0' | head -c "$n"; }
    linear_get_open_count()        { return 1; }
    linear_get_in_progress_task()  { echo ""; }
    linear_get_next_task()         { echo ""; }
    ralph_inject_continue_state()  { echo ""; }
    ralph_probe_mcp_servers()      { :; }
    # Default: classify task as docs-related to exercise docs-mcp branch.
    ralph_task_is_docs_related()   { [[ "${MOCK_DOCS_TASK:-1}" == "1" ]]; }
    export -f log_status ralph_sanitize_prompt_text \
              linear_get_open_count linear_get_in_progress_task \
              linear_get_next_task ralph_inject_continue_state \
              ralph_probe_mcp_servers ralph_task_is_docs_related

    eval "$(awk '/^build_loop_context\(\) \{$/,/^\}$/' "$REPO_ROOT/ralph_loop.sh")"

    export RALPH_DIR="$TEST_TEMP_DIR/.ralph"
    export RALPH_CONTINUE_STATE_FILE="$TEST_TEMP_DIR/.ralph/.nonexistent"
    export SCRIPT_DIR="$REPO_ROOT"
}

@test "TAP-2444: emits CANONICAL MCP TOOLS directive when at least one server is available" {
    _source_build_loop_context
    export RALPH_TASK_SOURCE="linear"
    export RALPH_LINEAR_PROJECT="Ralph Continuous Coding"
    export RALPH_MCP_TAPPS_AVAILABLE=true
    export RALPH_MCP_DOCS_AVAILABLE=false
    export RALPH_MCP_BRAIN_AVAILABLE=false
    run build_loop_context 7
    assert_success
    [[ "$output" == *"CANONICAL MCP TOOLS (TAP-2444)"* ]]
    [[ "$output" == *"ToolSearch query=\"select:"* ]]
    [[ "$output" == *"mcp__tapps-mcp__tapps_session_start"* ]]
}

@test "TAP-2444: lists Linear plugin tools when RALPH_TASK_SOURCE=linear" {
    _source_build_loop_context
    export RALPH_TASK_SOURCE="linear"
    export RALPH_LINEAR_PROJECT="Ralph Continuous Coding"
    export RALPH_MCP_TAPPS_AVAILABLE=false
    export RALPH_MCP_DOCS_AVAILABLE=false
    export RALPH_MCP_BRAIN_AVAILABLE=false
    run build_loop_context 7
    assert_success
    [[ "$output" == *"mcp__plugin_linear_linear__list_issues"* ]]
    [[ "$output" == *"mcp__plugin_linear_linear__get_issue"* ]]
    [[ "$output" == *"mcp__plugin_linear_linear__save_issue"* ]]
}

@test "TAP-2444: omits Linear plugin tools when RALPH_TASK_SOURCE=file" {
    _source_build_loop_context
    export RALPH_TASK_SOURCE="file"
    export RALPH_MCP_TAPPS_AVAILABLE=true
    export RALPH_MCP_DOCS_AVAILABLE=false
    export RALPH_MCP_BRAIN_AVAILABLE=false
    # File-mode needs a fix_plan.md to satisfy the elif branch
    echo "- [ ] task" > "$TEST_TEMP_DIR/.ralph/fix_plan.md"
    run build_loop_context 7
    assert_success
    [[ "$output" != *"mcp__plugin_linear_linear__"* ]]
    # tapps-mcp tools still present
    [[ "$output" == *"mcp__tapps-mcp__tapps_session_start"* ]]
}

@test "TAP-2444: omits docs-mcp tools when task is not docs-related" {
    _source_build_loop_context
    export RALPH_TASK_SOURCE="linear"
    export RALPH_LINEAR_PROJECT="Ralph Continuous Coding"
    export RALPH_MCP_TAPPS_AVAILABLE=false
    export RALPH_MCP_DOCS_AVAILABLE=true
    export RALPH_MCP_BRAIN_AVAILABLE=false
    export MOCK_DOCS_TASK=0  # ralph_task_is_docs_related returns 1
    run build_loop_context 7
    assert_success
    [[ "$output" != *"mcp__docs-mcp__docs_generate_adr"* ]]
}

@test "TAP-2444: lists docs-mcp tools when task is docs-related" {
    _source_build_loop_context
    export RALPH_TASK_SOURCE="linear"
    export RALPH_LINEAR_PROJECT="Ralph Continuous Coding"
    export RALPH_MCP_TAPPS_AVAILABLE=false
    export RALPH_MCP_DOCS_AVAILABLE=true
    export RALPH_MCP_BRAIN_AVAILABLE=false
    export MOCK_DOCS_TASK=1
    run build_loop_context 7
    assert_success
    [[ "$output" == *"mcp__docs-mcp__docs_generate_adr"* ]]
}

@test "TAP-2444: omits directive entirely when no servers available and task source is file" {
    _source_build_loop_context
    export RALPH_TASK_SOURCE="file"
    export RALPH_MCP_TAPPS_AVAILABLE=false
    export RALPH_MCP_DOCS_AVAILABLE=false
    export RALPH_MCP_BRAIN_AVAILABLE=false
    echo "- [ ] task" > "$TEST_TEMP_DIR/.ralph/fix_plan.md"
    run build_loop_context 7
    assert_success
    [[ "$output" != *"CANONICAL MCP TOOLS"* ]]
}

@test "TAP-2444: lists brain tools when RALPH_MCP_BRAIN_AVAILABLE=true" {
    _source_build_loop_context
    export RALPH_TASK_SOURCE="linear"
    export RALPH_LINEAR_PROJECT="Ralph Continuous Coding"
    export RALPH_MCP_TAPPS_AVAILABLE=false
    export RALPH_MCP_DOCS_AVAILABLE=false
    export RALPH_MCP_BRAIN_AVAILABLE=true
    run build_loop_context 7
    assert_success
    [[ "$output" == *"mcp__tapps-brain__brain_recall"* ]]
    [[ "$output" == *"mcp__tapps-brain__brain_remember"* ]]
}
