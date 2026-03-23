#!/usr/bin/env bats
# Unit tests for Hooks + Agent Definition (Phase 1)
# Tests HOOKS-1 through HOOKS-6 acceptance criteria

load '../helpers/test_helper'

PROJECT_ROOT="${BATS_TEST_DIRNAME}/../.."
RALPH_LOOP="${PROJECT_ROOT}/ralph_loop.sh"

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"
    mkdir -p .ralph/hooks .ralph/logs
    export RALPH_DIR=".ralph"
    export CLAUDE_PROJECT_DIR="$TEST_DIR"
}

teardown() {
    if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
        cd /
        rm -rf "$TEST_DIR"
    fi
}

# =============================================================================
# HOOKS-1: ralph.md agent definition
# =============================================================================

@test "HOOKS-1: ralph.md exists" {
    [[ -f "$PROJECT_ROOT/.claude/agents/ralph.md" ]]
}

@test "HOOKS-1: ralph.md has name: ralph" {
    grep -q "name: ralph" "$PROJECT_ROOT/.claude/agents/ralph.md"
}

@test "HOOKS-1: ralph.md has model: opus" {
    grep -q "model: opus" "$PROJECT_ROOT/.claude/agents/ralph.md"
}

@test "HOOKS-1: ralph.md has maxTurns" {
    grep -q "maxTurns:" "$PROJECT_ROOT/.claude/agents/ralph.md"
}

@test "HOOKS-1: ralph.md has permissionMode: acceptEdits" {
    grep -q "permissionMode: acceptEdits" "$PROJECT_ROOT/.claude/agents/ralph.md"
}

@test "HOOKS-1: ralph.md includes RALPH_STATUS template" {
    grep -q "RALPH_STATUS" "$PROJECT_ROOT/.claude/agents/ralph.md"
    grep -q "EXIT_SIGNAL" "$PROJECT_ROOT/.claude/agents/ralph.md"
}

@test "HOOKS-1: ralph.md disallows destructive commands" {
    grep -q "git clean" "$PROJECT_ROOT/.claude/agents/ralph.md"
    grep -q "git reset --hard" "$PROJECT_ROOT/.claude/agents/ralph.md"
    grep -q "rm -rf" "$PROJECT_ROOT/.claude/agents/ralph.md"
}

@test "HOOKS-1: ralph.md has STOP instruction" {
    grep -q "STOP" "$PROJECT_ROOT/.claude/agents/ralph.md"
}

# =============================================================================
# HOOKS-2: settings.json hook configuration
# =============================================================================

@test "HOOKS-2: settings.json is valid JSON" {
    jq empty "$PROJECT_ROOT/.claude/settings.json"
}

@test "HOOKS-2: settings.json declares SessionStart hook" {
    jq -e '.hooks.SessionStart' "$PROJECT_ROOT/.claude/settings.json" >/dev/null
}

@test "HOOKS-2: settings.json declares Stop hook" {
    jq -e '.hooks.Stop' "$PROJECT_ROOT/.claude/settings.json" >/dev/null
}

@test "HOOKS-2: settings.json declares PreToolUse hooks" {
    local count
    count=$(jq '.hooks.PreToolUse | length' "$PROJECT_ROOT/.claude/settings.json")
    [[ "$count" -ge 2 ]]
}

@test "HOOKS-2: settings.json declares PostToolUse hooks" {
    local count
    count=$(jq '.hooks.PostToolUse | length' "$PROJECT_ROOT/.claude/settings.json")
    [[ "$count" -ge 2 ]]
}

@test "HOOKS-2: settings.json declares SubagentStop hook" {
    jq -e '.hooks.SubagentStop' "$PROJECT_ROOT/.claude/settings.json" >/dev/null
}

@test "HOOKS-2: settings.json declares StopFailure hook" {
    jq -e '.hooks.StopFailure' "$PROJECT_ROOT/.claude/settings.json" >/dev/null
}

@test "HOOKS-2: hook scripts reference .ralph/hooks/ directory" {
    local non_ralph_hooks
    non_ralph_hooks=$(jq -r '.. | .command? // empty' "$PROJECT_ROOT/.claude/settings.json" | grep -v '.ralph/hooks/' | wc -l | tr -d '[:space:]')
    [[ "$non_ralph_hooks" -eq 0 ]]
}

# =============================================================================
# HOOKS-3: on-session-start.sh
# =============================================================================

@test "HOOKS-3: on-session-start.sh exists" {
    [[ -f "$PROJECT_ROOT/templates/hooks/on-session-start.sh" ]]
}

@test "HOOKS-3: on-session-start.sh exits 0 without .ralph dir" {
    CLAUDE_PROJECT_DIR="/nonexistent" run bash "$PROJECT_ROOT/templates/hooks/on-session-start.sh"
    assert_success
}

@test "HOOKS-3: on-session-start.sh emits loop context to stderr" {
    echo '{"loop_count": 5}' > .ralph/status.json
    printf -- '- [x] task 1\n- [ ] task 2\n- [ ] task 3\n' > .ralph/fix_plan.md
    echo '{"state": "CLOSED"}' > .ralph/.circuit_breaker_state

    local stderr_output
    stderr_output=$(echo '{}' | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$PROJECT_ROOT/templates/hooks/on-session-start.sh" 2>&1 >/dev/null)

    echo "$stderr_output" | grep -q "Ralph loop #6"
    echo "$stderr_output" | grep -q "1/3 complete"
    echo "$stderr_output" | grep -q "2 remaining"
    echo "$stderr_output" | grep -q "CLOSED"
    echo "$stderr_output" | grep -q "Only run tests at epic boundaries"
}

@test "HOOKS-3: on-session-start.sh short-circuits when 0 tasks remaining" {
    echo '{"loop_count": 10}' > .ralph/status.json
    printf -- '- [x] task 1\n- [x] task 2\n- [x] task 3\n' > .ralph/fix_plan.md
    echo '{"state": "CLOSED"}' > .ralph/.circuit_breaker_state

    local stderr_output
    stderr_output=$(echo '{}' | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$PROJECT_ROOT/templates/hooks/on-session-start.sh" 2>&1 >/dev/null)

    echo "$stderr_output" | grep -q "ALL TASKS COMPLETE"
    echo "$stderr_output" | grep -q "Do NOT run tests"
    echo "$stderr_output" | grep -q "EXIT_SIGNAL: true"
    # Should NOT contain the "read fix_plan" instruction
    ! echo "$stderr_output" | grep -q "FIRST unchecked item"
}

@test "HOOKS-3: on-session-start.sh clears per-loop file tracking" {
    echo "src/foo.py" > .ralph/.files_modified_this_loop
    echo '{}' | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$PROJECT_ROOT/templates/hooks/on-session-start.sh" 2>/dev/null
    [[ ! -s .ralph/.files_modified_this_loop ]]
}

@test "HOOKS-3: on-session-start.sh uses set -euo pipefail" {
    grep -q "set -euo pipefail" "$PROJECT_ROOT/templates/hooks/on-session-start.sh"
}

# =============================================================================
# HOOKS-4: on-stop.sh
# =============================================================================

@test "HOOKS-4: on-stop.sh exists" {
    [[ -f "$PROJECT_ROOT/templates/hooks/on-stop.sh" ]]
}

@test "HOOKS-4: on-stop.sh exits 0 without .ralph dir" {
    echo '{}' | CLAUDE_PROJECT_DIR="/nonexistent" run bash "$PROJECT_ROOT/templates/hooks/on-stop.sh"
    assert_success
}

@test "HOOKS-4: on-stop.sh parses RALPH_STATUS and writes status.json" {
    echo '{"loop_count": 0}' > .ralph/status.json
    echo '{"state": "CLOSED", "consecutive_no_progress": 0}' > .ralph/.circuit_breaker_state

    printf '{"result": "Done.\\n---RALPH_STATUS---\\nSTATUS: IN_PROGRESS\\nTASKS_COMPLETED_THIS_LOOP: 1\\nFILES_MODIFIED: 3\\nWORK_TYPE: IMPLEMENTATION\\nEXIT_SIGNAL: false\\nRECOMMENDATION: Implemented auth\\n---END_RALPH_STATUS---"}' \
      | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$PROJECT_ROOT/templates/hooks/on-stop.sh"

    [[ "$(jq -r '.status' .ralph/status.json)" == "IN_PROGRESS" ]]
    [[ "$(jq -r '.loop_count' .ralph/status.json)" == "1" ]]
}

@test "HOOKS-4: on-stop.sh logs to live.log" {
    echo '{"loop_count": 0}' > .ralph/status.json
    echo '{"state": "CLOSED", "consecutive_no_progress": 0}' > .ralph/.circuit_breaker_state

    printf '{"result": "---RALPH_STATUS---\\nSTATUS: IN_PROGRESS\\nEXIT_SIGNAL: false\\n---END_RALPH_STATUS---"}' \
      | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$PROJECT_ROOT/templates/hooks/on-stop.sh"

    [[ -f .ralph/live.log ]]
    grep -q "Loop 1" .ralph/live.log
}

@test "HOOKS-4: on-stop.sh uses set -euo pipefail" {
    grep -q "set -euo pipefail" "$PROJECT_ROOT/templates/hooks/on-stop.sh"
}

# =============================================================================
# HOOKS-5: PreToolUse hooks
# =============================================================================

@test "HOOKS-5: validate-command.sh exists" {
    [[ -f "$PROJECT_ROOT/templates/hooks/validate-command.sh" ]]
}

@test "HOOKS-5: validate-command.sh blocks git clean" {
    run bash -c 'echo "{\"tool_input\": {\"command\": \"git clean -fd\"}}" | CLAUDE_PROJECT_DIR="'"$TEST_DIR"'" bash "'"$PROJECT_ROOT"'/templates/hooks/validate-command.sh"'
    [[ "$status" -eq 2 ]]
}

@test "HOOKS-5: validate-command.sh blocks rm -rf" {
    run bash -c 'echo "{\"tool_input\": {\"command\": \"rm -rf src/\"}}" | CLAUDE_PROJECT_DIR="'"$TEST_DIR"'" bash "'"$PROJECT_ROOT"'/templates/hooks/validate-command.sh"'
    [[ "$status" -eq 2 ]]
}

@test "HOOKS-5: validate-command.sh blocks git push --force" {
    run bash -c 'echo "{\"tool_input\": {\"command\": \"git push --force origin main\"}}" | CLAUDE_PROJECT_DIR="'"$TEST_DIR"'" bash "'"$PROJECT_ROOT"'/templates/hooks/validate-command.sh"'
    [[ "$status" -eq 2 ]]
}

@test "HOOKS-5: validate-command.sh allows git add" {
    run bash -c 'echo "{\"tool_input\": {\"command\": \"git add src/main.py\"}}" | CLAUDE_PROJECT_DIR="'"$TEST_DIR"'" bash "'"$PROJECT_ROOT"'/templates/hooks/validate-command.sh"'
    assert_success
}

@test "HOOKS-5: validate-command.sh allows normal commands" {
    run bash -c 'echo "{\"tool_input\": {\"command\": \"npm test\"}}" | CLAUDE_PROJECT_DIR="'"$TEST_DIR"'" bash "'"$PROJECT_ROOT"'/templates/hooks/validate-command.sh"'
    assert_success
}

@test "HOOKS-5: validate-command.sh exits 0 without .ralph dir" {
    run bash -c 'echo "{\"tool_input\": {\"command\": \"rm -rf /\"}}" | CLAUDE_PROJECT_DIR="/nonexistent" bash "'"$PROJECT_ROOT"'/templates/hooks/validate-command.sh"'
    assert_success
}

@test "HOOKS-5: validate-command.sh blocks git commit --no-verify" {
    run bash -c 'echo "{\"tool_input\": {\"command\": \"git commit --no-verify -m \\\"test\\\"\"}}" | CLAUDE_PROJECT_DIR="'"$TEST_DIR"'" bash "'"$PROJECT_ROOT"'/templates/hooks/validate-command.sh"'
    [[ "$status" -eq 2 ]]
}

@test "HOOKS-5: validate-command.sh blocks git push --no-verify" {
    run bash -c 'echo "{\"tool_input\": {\"command\": \"git push --no-verify origin main\"}}" | CLAUDE_PROJECT_DIR="'"$TEST_DIR"'" bash "'"$PROJECT_ROOT"'/templates/hooks/validate-command.sh"'
    [[ "$status" -eq 2 ]]
}

@test "HOOKS-5: validate-command.sh blocks git commit -n (short form)" {
    run bash -c 'echo "{\"tool_input\": {\"command\": \"git commit -n -m \\\"test\\\"\"}}" | CLAUDE_PROJECT_DIR="'"$TEST_DIR"'" bash "'"$PROJECT_ROOT"'/templates/hooks/validate-command.sh"'
    [[ "$status" -eq 2 ]]
}

@test "HOOKS-5: validate-command.sh blocks --no-gpg-sign" {
    run bash -c 'echo "{\"tool_input\": {\"command\": \"git commit --no-gpg-sign -m \\\"test\\\"\"}}" | CLAUDE_PROJECT_DIR="'"$TEST_DIR"'" bash "'"$PROJECT_ROOT"'/templates/hooks/validate-command.sh"'
    [[ "$status" -eq 2 ]]
}

@test "HOOKS-5: protect-ralph-files.sh exists" {
    [[ -f "$PROJECT_ROOT/templates/hooks/protect-ralph-files.sh" ]]
}

@test "HOOKS-5: protect-ralph-files.sh allows fix_plan.md edits" {
    run bash -c 'echo "{\"tool_input\": {\"file_path\": \".ralph/fix_plan.md\"}}" | CLAUDE_PROJECT_DIR="'"$TEST_DIR"'" bash "'"$PROJECT_ROOT"'/templates/hooks/protect-ralph-files.sh"'
    assert_success
}

@test "HOOKS-5: protect-ralph-files.sh blocks PROMPT.md edits" {
    run bash -c 'echo "{\"tool_input\": {\"file_path\": \".ralph/PROMPT.md\"}}" | CLAUDE_PROJECT_DIR="'"$TEST_DIR"'" bash "'"$PROJECT_ROOT"'/templates/hooks/protect-ralph-files.sh"'
    [[ "$status" -eq 2 ]]
}

@test "HOOKS-5: protect-ralph-files.sh blocks .ralphrc edits" {
    run bash -c 'echo "{\"tool_input\": {\"file_path\": \".ralphrc\"}}" | CLAUDE_PROJECT_DIR="'"$TEST_DIR"'" bash "'"$PROJECT_ROOT"'/templates/hooks/protect-ralph-files.sh"'
    [[ "$status" -eq 2 ]]
}

@test "HOOKS-5: protect-ralph-files.sh allows normal file edits" {
    run bash -c 'echo "{\"tool_input\": {\"file_path\": \"src/main.py\"}}" | CLAUDE_PROJECT_DIR="'"$TEST_DIR"'" bash "'"$PROJECT_ROOT"'/templates/hooks/protect-ralph-files.sh"'
    assert_success
}

@test "HOOKS-5: protect-ralph-files.sh allows status.json updates" {
    run bash -c 'echo "{\"tool_input\": {\"file_path\": \".ralph/status.json\"}}" | CLAUDE_PROJECT_DIR="'"$TEST_DIR"'" bash "'"$PROJECT_ROOT"'/templates/hooks/protect-ralph-files.sh"'
    assert_success
}

# =============================================================================
# HOOKS-6: --agent ralph in build_claude_command()
# =============================================================================

@test "HOOKS-6: check_agent_support function exists" {
    grep -q "check_agent_support()" "$RALPH_LOOP"
}

@test "HOOKS-6: build_claude_command supports --agent flag" {
    grep -q '"--agent"' "$RALPH_LOOP"
}

@test "HOOKS-6: RALPH_USE_AGENT in ralphrc template" {
    grep -q "RALPH_USE_AGENT" "$PROJECT_ROOT/templates/ralphrc.template"
}

@test "HOOKS-6: RALPH_AGENT_NAME in ralphrc template" {
    grep -q "RALPH_AGENT_NAME" "$PROJECT_ROOT/templates/ralphrc.template"
}

@test "HOOKS-6: legacy fallback when agent mode unavailable" {
    grep -q "Falling back to legacy mode" "$RALPH_LOOP"
}

# =============================================================================
# All hook scripts exist in templates
# =============================================================================

@test "all hook scripts exist in templates/hooks/" {
    [[ -f "$PROJECT_ROOT/templates/hooks/on-session-start.sh" ]]
    [[ -f "$PROJECT_ROOT/templates/hooks/on-stop.sh" ]]
    [[ -f "$PROJECT_ROOT/templates/hooks/validate-command.sh" ]]
    [[ -f "$PROJECT_ROOT/templates/hooks/protect-ralph-files.sh" ]]
    [[ -f "$PROJECT_ROOT/templates/hooks/on-file-change.sh" ]]
    [[ -f "$PROJECT_ROOT/templates/hooks/on-bash-command.sh" ]]
    [[ -f "$PROJECT_ROOT/templates/hooks/on-subagent-done.sh" ]]
    [[ -f "$PROJECT_ROOT/templates/hooks/on-stop-failure.sh" ]]
    [[ -f "$PROJECT_ROOT/templates/hooks/on-teammate-idle.sh" ]]
    [[ -f "$PROJECT_ROOT/templates/hooks/on-task-completed.sh" ]]
}

@test "all hook scripts use set -euo pipefail" {
    for script in "$PROJECT_ROOT"/templates/hooks/*.sh; do
        grep -q "set -euo pipefail" "$script"
    done
}
