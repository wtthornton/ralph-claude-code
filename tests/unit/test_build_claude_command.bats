#!/usr/bin/env bats
# TAP-1988 — Tool Search BETA opt-in via ANTHROPIC_BETA env var.
#
# build_claude_command exports `ANTHROPIC_BETA` (read by the Anthropic SDK,
# forwarded as the `anthropic-beta` HTTP header) so the API serves the
# deferred-tool catalog. The escape hatch is `RALPH_BETA_TOOL_SEARCH=false`.

bats_require_minimum_version 1.5.0
load '../helpers/test_helper'

REPO_ROOT="${BATS_TEST_DIRNAME}/../.."
TOOL_SEARCH_BETA="advanced-tool-use-2025-11-20"

setup() {
    TEST_TEMP_DIR="$(mktemp -d)"
    cd "$TEST_TEMP_DIR"
    export CLAUDE_PROJECT_DIR="$TEST_TEMP_DIR"
    export RALPH_LOOP_ACTIVE=1
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR"
    unset RALPH_LOOP_ACTIVE
    unset RALPH_BETA_TOOL_SEARCH
    unset ANTHROPIC_BETA
}

# Stub build_claude_command's dependencies and `eval` just the function body
# extracted from ralph_loop.sh — same pattern as test_plan_mode_high_risk.
_source_build_claude_command() {
    log_status() { :; }
    ralph_scope_prompt_for_service() { cat; }
    ralph_build_progressive_context() { echo ""; }
    ralph_classify_task_type() { echo "code"; }
    ralph_select_model() { echo "sonnet"; }
    ralph_should_skip_resume() { return 1; }
    portable_timeout() { :; }
    check_agent_support() { return 0; }
    export -f log_status ralph_scope_prompt_for_service \
              ralph_build_progressive_context ralph_classify_task_type \
              ralph_select_model ralph_should_skip_resume portable_timeout \
              check_agent_support

    eval "$(awk '/^build_claude_command\(\) \{$/,/^}$/' "$REPO_ROOT/ralph_loop.sh")"

    export RALPH_DIR="$TEST_TEMP_DIR/.ralph"
    export CLAUDE_CODE_CMD="claude"
    export CLAUDE_OUTPUT_FORMAT="json"
    export CLAUDE_USE_CONTINUE="false"
    export RALPH_AGENT_NAME="ralph"
    declare -ga CLAUDE_CMD_ARGS=()
    echo "do work" > "$TEST_TEMP_DIR/PROMPT.md"
}

@test "TAP-1988: default invocation exports ANTHROPIC_BETA with tool-search header" {
    _source_build_claude_command
    unset RALPH_BETA_TOOL_SEARCH
    unset ANTHROPIC_BETA

    build_claude_command "$TEST_TEMP_DIR/PROMPT.md" "" "" 1 >/dev/null 2>&1 || true

    [[ "${ANTHROPIC_BETA:-}" == *"$TOOL_SEARCH_BETA"* ]]
}

@test "TAP-1988: RALPH_BETA_TOOL_SEARCH=false skips the export entirely" {
    _source_build_claude_command
    unset ANTHROPIC_BETA
    export RALPH_BETA_TOOL_SEARCH=false

    build_claude_command "$TEST_TEMP_DIR/PROMPT.md" "" "" 1 >/dev/null 2>&1 || true

    [[ -z "${ANTHROPIC_BETA:-}" ]]
}

@test "TAP-1988: operator-set ANTHROPIC_BETA is preserved and appended to" {
    _source_build_claude_command
    unset RALPH_BETA_TOOL_SEARCH
    export ANTHROPIC_BETA="some-other-beta-2025-01-01"

    build_claude_command "$TEST_TEMP_DIR/PROMPT.md" "" "" 1 >/dev/null 2>&1 || true

    # Original beta preserved
    [[ "${ANTHROPIC_BETA}" == *"some-other-beta-2025-01-01"* ]]
    # Tool-search beta appended
    [[ "${ANTHROPIC_BETA}" == *"$TOOL_SEARCH_BETA"* ]]
}

@test "TAP-1988: repeated build_claude_command calls do not duplicate the beta" {
    _source_build_claude_command
    unset RALPH_BETA_TOOL_SEARCH
    unset ANTHROPIC_BETA

    build_claude_command "$TEST_TEMP_DIR/PROMPT.md" "" "" 1 >/dev/null 2>&1 || true
    build_claude_command "$TEST_TEMP_DIR/PROMPT.md" "" "" 1 >/dev/null 2>&1 || true
    build_claude_command "$TEST_TEMP_DIR/PROMPT.md" "" "" 1 >/dev/null 2>&1 || true

    # Count occurrences of the beta token in the env var — must be exactly 1.
    local count
    count=$(awk -v t="$TOOL_SEARCH_BETA" 'BEGIN { n=split(ENVIRON["ANTHROPIC_BETA"], a, ","); c=0; for (i=1;i<=n;i++) if (a[i]==t) c++; print c }')
    [ "$count" -eq 1 ]
}

@test "TAP-1988: operator-set ANTHROPIC_BETA that already includes the tool-search header is left unchanged" {
    _source_build_claude_command
    unset RALPH_BETA_TOOL_SEARCH
    export ANTHROPIC_BETA="some-other-beta,$TOOL_SEARCH_BETA"
    local before="$ANTHROPIC_BETA"

    build_claude_command "$TEST_TEMP_DIR/PROMPT.md" "" "" 1 >/dev/null 2>&1 || true

    [ "${ANTHROPIC_BETA}" = "$before" ]
}

@test "TAP-1988: ralphrc.template documents the override env var" {
    grep -q "RALPH_BETA_TOOL_SEARCH" "$REPO_ROOT/templates/ralphrc.template"
    grep -q "$TOOL_SEARCH_BETA" "$REPO_ROOT/templates/ralphrc.template"
}
