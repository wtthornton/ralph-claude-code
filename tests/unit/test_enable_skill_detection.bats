#!/usr/bin/env bats
# TAP-576 (SKILLS-INJECT-3): verify project-skill detection, the --skip-skills
# and --skills flags, ralph_enable_ci JSON emission, and idempotent re-install.

load '../helpers/test_helper'

PROJECT_ROOT="${BATS_TEST_DIRNAME}/../.."
ENABLE_LIB="${PROJECT_ROOT}/lib/enable_core.sh"
SKILLS_LIB="${PROJECT_ROOT}/lib/skills_install.sh"

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"
    # Isolate from the user's real ~/.claude/skills
    export HOME="$TEST_DIR/home"
    mkdir -p "$HOME/.claude/skills"
    # Populate stub source skills so skills_install_one has something to copy
    for s in python-patterns claude-api backend-patterns linear eval-harness; do
        mkdir -p "$HOME/.claude/skills/$s"
        cat > "$HOME/.claude/skills/$s/SKILL.md" << EOF
---
name: $s
description: Stub skill for $s test
---
EOF
    done
    enable_log() { :; }
    export -f enable_log
    # Required by enable_core
    RALPH_VERSION="test"
    export RALPH_VERSION
    # shellcheck disable=SC1090
    source "$ENABLE_LIB"
}

teardown() {
    if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
        cd /
        rm -rf "$TEST_DIR"
    fi
}

# =============================================================================
# detect_tier_a_skills — signal matrix
# =============================================================================

@test "detect_tier_a_skills returns nothing for an empty project" {
    run detect_tier_a_skills
    assert_success
    [ -z "$(printf '%s' "$output" | tr -d '[:space:]')" ]
}

@test "detect_tier_a_skills picks python-patterns on pyproject.toml" {
    touch pyproject.toml
    run detect_tier_a_skills
    [[ "$output" == *"python-patterns"* ]]
}

@test "detect_tier_a_skills picks claude-api on anthropic dependency" {
    cat > requirements.txt << 'EOF'
anthropic>=0.30
EOF
    run detect_tier_a_skills
    [[ "$output" == *"claude-api"* ]]
}

@test "detect_tier_a_skills picks backend-patterns on express project" {
    cat > package.json << 'EOF'
{"dependencies": {"express": "^4"}}
EOF
    run detect_tier_a_skills
    [[ "$output" == *"backend-patterns"* ]]
}

@test "detect_tier_a_skills picks linear when .ralphrc opts in" {
    echo 'RALPH_TASK_SOURCE=linear' > .ralphrc
    run detect_tier_a_skills
    [[ "$output" == *"linear"* ]]
}

@test "detect_tier_a_skills picks eval-harness when tests/evals/ exists" {
    mkdir -p tests/evals
    run detect_tier_a_skills
    [[ "$output" == *"eval-harness"* ]]
}

@test "detect_tier_a_skills stacks multiple signals" {
    touch pyproject.toml
    echo 'RALPH_TASK_SOURCE=linear' > .ralphrc
    mkdir -p tests/evals
    run detect_tier_a_skills
    [[ "$output" == *"python-patterns"* ]]
    [[ "$output" == *"linear"* ]]
    [[ "$output" == *"eval-harness"* ]]
}

# =============================================================================
# install_project_tier_a_skills — --skip-skills / --skills override
# =============================================================================

@test "install_project_tier_a_skills honors ENABLE_SKIP_SKILLS=true" {
    touch pyproject.toml
    ENABLE_SKIP_SKILLS=true install_project_tier_a_skills
    [ ! -d ".claude/skills/python-patterns" ]
    [ -z "$INSTALLED_TIER_A_SKILLS" ]
}

@test "install_project_tier_a_skills honors ENABLE_SKILLS_OVERRIDE list" {
    # Detection would pick nothing (empty dir), but override forces install
    ENABLE_SKILLS_OVERRIDE="python-patterns,linear" install_project_tier_a_skills
    [ -d ".claude/skills/python-patterns" ]
    [ -d ".claude/skills/linear" ]
    [[ "$INSTALLED_TIER_A_SKILLS" == *"python-patterns"* ]]
    [[ "$INSTALLED_TIER_A_SKILLS" == *"linear"* ]]
}

@test "install_project_tier_a_skills trims whitespace in override list" {
    ENABLE_SKILLS_OVERRIDE=" python-patterns , linear " install_project_tier_a_skills
    [ -d ".claude/skills/python-patterns" ]
    [ -d ".claude/skills/linear" ]
}

@test "install_project_tier_a_skills skips missing source dirs without failing" {
    ENABLE_SKILLS_OVERRIDE="definitely-not-a-real-skill,python-patterns" install_project_tier_a_skills
    [ -d ".claude/skills/python-patterns" ]
    [ ! -d ".claude/skills/definitely-not-a-real-skill" ]
}

@test "install_project_tier_a_skills populates INSTALLED_TIER_A_SKILLS" {
    touch pyproject.toml
    install_project_tier_a_skills
    [ -n "$INSTALLED_TIER_A_SKILLS" ]
    [[ "$INSTALLED_TIER_A_SKILLS" == *"python-patterns"* ]]
}

# =============================================================================
# Idempotency — re-running must not corrupt existing installs
# =============================================================================

@test "install_project_tier_a_skills is idempotent on re-run" {
    touch pyproject.toml
    install_project_tier_a_skills
    local first_pass="$INSTALLED_TIER_A_SKILLS"
    [ -d ".claude/skills/python-patterns" ]
    # Second pass: should not fail and should not remove the skill
    install_project_tier_a_skills
    [ -d ".claude/skills/python-patterns" ]
    [ "$INSTALLED_TIER_A_SKILLS" = "$first_pass" ]
}

@test "install_project_tier_a_skills preserves user-authored skill dirs" {
    # Create a user-authored skill with no .ralph-managed sidecar
    mkdir -p .claude/skills/python-patterns
    echo "USER CONTENT" > .claude/skills/python-patterns/user-file.md
    touch pyproject.toml
    install_project_tier_a_skills
    # User content must survive
    [ -f .claude/skills/python-patterns/user-file.md ]
    grep -q "USER CONTENT" .claude/skills/python-patterns/user-file.md
}

# =============================================================================
# CLI-level flag plumbing in ralph_enable.sh and ralph_enable_ci.sh
# =============================================================================

@test "ralph_enable.sh help mentions --skip-skills and --skills" {
    run bash "$PROJECT_ROOT/ralph_enable.sh" --help
    assert_success
    [[ "$output" == *"--skip-skills"* ]]
    [[ "$output" == *"--skills"* ]]
}

@test "ralph_enable_ci.sh help mentions --skip-skills and --skills" {
    run bash "$PROJECT_ROOT/ralph_enable_ci.sh" --help
    assert_success
    [[ "$output" == *"--skip-skills"* ]]
    [[ "$output" == *"--skills"* ]]
}

@test "ralph_enable_ci.sh JSON output schema mentions skills_installed" {
    run bash "$PROJECT_ROOT/ralph_enable_ci.sh" --help
    assert_success
    [[ "$output" == *"skills_installed"* ]]
}

@test "ralph_enable_ci.sh rejects bare --skills without argument" {
    run bash "$PROJECT_ROOT/ralph_enable_ci.sh" --skills
    assert_failure
    [[ "$output" == *"--skills"* ]]
    [[ "$output" == *"comma-separated"* ]] || [[ "$output" == *"requires"* ]]
}
