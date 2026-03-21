#!/usr/bin/env bats
# Unit tests for Agent Teams + Parallelism (Phase 4)
# Tests TEAMS-1 through TEAMS-5 acceptance criteria

load '../helpers/test_helper'

RALPH_LOOP="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"
PROJECT_ROOT="${BATS_TEST_DIRNAME}/../.."

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"
}

teardown() {
    if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
        cd /
        rm -rf "$TEST_DIR"
    fi
}

# =============================================================================
# TEAMS-5: .gitignore exclusions
# =============================================================================

@test "TEAMS-5: .gitignore excludes Claude Code worktrees" {
    grep -q '\.claude/worktrees/' "$PROJECT_ROOT/.gitignore"
}

@test "TEAMS-5: .gitignore excludes local settings" {
    grep -q 'settings.local.json' "$PROJECT_ROOT/.gitignore"
}

@test "TEAMS-5: .gitignore excludes agent memory" {
    grep -q 'agent-memory' "$PROJECT_ROOT/.gitignore"
}

@test "TEAMS-5: template .gitignore excludes Claude Code worktrees" {
    grep -q '\.claude/worktrees/' "$PROJECT_ROOT/templates/.gitignore"
}

@test "TEAMS-5: template .gitignore excludes local settings" {
    grep -q 'settings.local.json' "$PROJECT_ROOT/templates/.gitignore"
}

@test "TEAMS-5: template .gitignore excludes agent memory" {
    grep -q 'agent-memory' "$PROJECT_ROOT/templates/.gitignore"
}

# =============================================================================
# TEAMS-1: .ralphrc template configuration
# =============================================================================

@test "TEAMS-1: ralphrc template contains RALPH_ENABLE_TEAMS" {
    grep -q 'RALPH_ENABLE_TEAMS=false' "$PROJECT_ROOT/templates/ralphrc.template"
}

@test "TEAMS-1: ralphrc template contains RALPH_MAX_TEAMMATES" {
    grep -q 'RALPH_MAX_TEAMMATES=3' "$PROJECT_ROOT/templates/ralphrc.template"
}

@test "TEAMS-1: ralphrc template contains RALPH_BG_TESTING" {
    grep -q 'RALPH_BG_TESTING=false' "$PROJECT_ROOT/templates/ralphrc.template"
}

@test "TEAMS-1: ralphrc template contains RALPH_TEAMMATE_MODE" {
    grep -q 'RALPH_TEAMMATE_MODE="tmux"' "$PROJECT_ROOT/templates/ralphrc.template"
}

@test "TEAMS-1: ralphrc template documents known limitations" {
    grep -q 'VS Code terminal' "$PROJECT_ROOT/templates/ralphrc.template"
    grep -q 'Windows Terminal' "$PROJECT_ROOT/templates/ralphrc.template"
    grep -q 'session resumption' "$PROJECT_ROOT/templates/ralphrc.template"
}

# =============================================================================
# TEAMS-1: setup_teams() function
# =============================================================================

@test "TEAMS-1: setup_teams function exists in ralph_loop.sh" {
    grep -q 'setup_teams()' "$PROJECT_ROOT/ralph_loop.sh"
}

@test "TEAMS-1: check_teams_support function exists in ralph_loop.sh" {
    grep -q 'check_teams_support()' "$PROJECT_ROOT/ralph_loop.sh"
}

@test "TEAMS-1: setup_teams is called from main" {
    grep -q 'setup_teams' "$PROJECT_ROOT/ralph_loop.sh"
}

# =============================================================================
# TEAMS-3: ralph-bg-tester.md background agent
# =============================================================================

@test "TEAMS-3: ralph-bg-tester.md exists" {
    [[ -f "$PROJECT_ROOT/.claude/agents/ralph-bg-tester.md" ]]
}

@test "TEAMS-3: ralph-bg-tester.md has valid name" {
    grep -q "name: ralph-bg-tester" "$PROJECT_ROOT/.claude/agents/ralph-bg-tester.md"
}

@test "TEAMS-3: ralph-bg-tester.md has background: true" {
    grep -q "background: true" "$PROJECT_ROOT/.claude/agents/ralph-bg-tester.md"
}

@test "TEAMS-3: ralph-bg-tester.md uses model: sonnet" {
    grep -q "model: sonnet" "$PROJECT_ROOT/.claude/agents/ralph-bg-tester.md"
}

@test "TEAMS-3: ralph-bg-tester.md has Bash tool" {
    grep -q "Bash" "$PROJECT_ROOT/.claude/agents/ralph-bg-tester.md"
}

@test "TEAMS-3: ralph-bg-tester.md has maxTurns: 10" {
    grep -q "maxTurns: 10" "$PROJECT_ROOT/.claude/agents/ralph-bg-tester.md"
}

@test "TEAMS-3: ralph-bg-tester.md is report-only (no fix)" {
    grep -q "Do NOT fix failures" "$PROJECT_ROOT/.claude/agents/ralph-bg-tester.md"
}

@test "TEAMS-3: ralph-bg-tester.md has structured output format" {
    grep -q "Background Test Results" "$PROJECT_ROOT/.claude/agents/ralph-bg-tester.md"
}

# =============================================================================
# TEAMS-4: Hook scripts
# =============================================================================

@test "TEAMS-4: on-teammate-idle.sh exists" {
    [[ -f "$PROJECT_ROOT/templates/hooks/on-teammate-idle.sh" ]]
}

@test "TEAMS-4: on-task-completed.sh exists" {
    [[ -f "$PROJECT_ROOT/templates/hooks/on-task-completed.sh" ]]
}

@test "TEAMS-4: on-teammate-idle.sh logs to live.log" {
    grep -q 'live.log' "$PROJECT_ROOT/templates/hooks/on-teammate-idle.sh"
}

@test "TEAMS-4: on-task-completed.sh logs to live.log" {
    grep -q 'live.log' "$PROJECT_ROOT/templates/hooks/on-task-completed.sh"
}

@test "TEAMS-4: on-teammate-idle.sh exits 0 in non-Ralph project" {
    mkdir -p "$TEST_DIR/nonexistent"
    CLAUDE_PROJECT_DIR="$TEST_DIR/nonexistent" run bash "$PROJECT_ROOT/templates/hooks/on-teammate-idle.sh" <<< '{}'
    assert_success
}

@test "TEAMS-4: on-task-completed.sh exits 0 in non-Ralph project" {
    mkdir -p "$TEST_DIR/nonexistent"
    CLAUDE_PROJECT_DIR="$TEST_DIR/nonexistent" run bash "$PROJECT_ROOT/templates/hooks/on-task-completed.sh" <<< '{}'
    assert_success
}

@test "TEAMS-4: on-teammate-idle.sh logs teammate name and remaining tasks" {
    mkdir -p "$TEST_DIR/.ralph"
    printf -- '- [x] task 1\n- [ ] task 2\n' > "$TEST_DIR/.ralph/fix_plan.md"

    CLAUDE_PROJECT_DIR="$TEST_DIR" run bash "$PROJECT_ROOT/templates/hooks/on-teammate-idle.sh" <<< '{"teammate_name": "backend"}'
    assert_success

    grep -q "TEAMMATE IDLE: backend" "$TEST_DIR/.ralph/live.log"
    grep -q "1 tasks remaining" "$TEST_DIR/.ralph/live.log"
}

@test "TEAMS-4: on-task-completed.sh logs task description" {
    mkdir -p "$TEST_DIR/.ralph"

    CLAUDE_PROJECT_DIR="$TEST_DIR" run bash "$PROJECT_ROOT/templates/hooks/on-task-completed.sh" <<< '{"task_description": "Fix auth middleware"}'
    assert_success

    grep -q "TASK COMPLETED: Fix auth middleware" "$TEST_DIR/.ralph/live.log"
}

@test "TEAMS-4: TeammateIdle hook declared in settings.json" {
    jq -e '.hooks.TeammateIdle' "$PROJECT_ROOT/.claude/settings.json" >/dev/null
}

@test "TEAMS-4: TaskCompleted hook declared in settings.json" {
    jq -e '.hooks.TaskCompleted' "$PROJECT_ROOT/.claude/settings.json" >/dev/null
}

# =============================================================================
# TEAMS-2: ralph.md team execution section
# =============================================================================

@test "TEAMS-2: ralph.md exists" {
    [[ -f "$PROJECT_ROOT/.claude/agents/ralph.md" ]]
}

@test "TEAMS-2: ralph.md includes team execution section" {
    grep -q "Team Execution" "$PROJECT_ROOT/.claude/agents/ralph.md"
}

@test "TEAMS-2: ralph.md includes file ownership scopes" {
    grep -q "Backend" "$PROJECT_ROOT/.claude/agents/ralph.md"
    grep -q "Frontend" "$PROJECT_ROOT/.claude/agents/ralph.md"
}

@test "TEAMS-2: ralph.md includes sequential fallback" {
    grep -q "Sequential Fallback" "$PROJECT_ROOT/.claude/agents/ralph.md"
}

@test "TEAMS-2: ralph.md references RALPH_MAX_TEAMMATES" {
    grep -q "RALPH_MAX_TEAMMATES" "$PROJECT_ROOT/.claude/agents/ralph.md"
}

@test "TEAMS-2: ralph.md includes teammate failure handling" {
    grep -q "reassign their task to yourself" "$PROJECT_ROOT/.claude/agents/ralph.md"
}
