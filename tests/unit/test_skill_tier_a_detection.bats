#!/usr/bin/env bats
# SKILLS-INJECT-3: Unit tests for Tier A skill detection and project-local install.

bats_require_minimum_version 1.5.0
load '../helpers/test_helper'

ENABLE_CORE="$BATS_TEST_DIRNAME/../../lib/enable_core.sh"

setup() {
    # Work in a clean temp dir so detection reads only what we plant.
    export TEST_PROJECT="$BATS_TEST_TMPDIR/project"
    mkdir -p "$TEST_PROJECT"
    export OLDPWD="$PWD"
    cd "$TEST_PROJECT"

    # Silence enable_log noise in tests.
    export ENABLE_USE_COLORS="false"
    export RALPH_VERSION="test"

    # shellcheck disable=SC1090
    source "$ENABLE_CORE"
}

teardown() {
    cd "$OLDPWD"
    rm -rf "$TEST_PROJECT"
}

# ---------------------------------------------------------------------------
# detect_tier_a_skills
# ---------------------------------------------------------------------------

@test "detect_tier_a_skills: empty project returns no skills" {
    local result
    result=$(detect_tier_a_skills)
    [[ -z "$result" ]]
}

@test "detect_tier_a_skills: pyproject.toml → python-patterns" {
    touch pyproject.toml
    local result
    result=$(detect_tier_a_skills)
    echo "$result" | grep -q "python-patterns"
}

@test "detect_tier_a_skills: setup.py → python-patterns" {
    touch setup.py
    local result
    result=$(detect_tier_a_skills)
    echo "$result" | grep -q "python-patterns"
}

@test "detect_tier_a_skills: setup.cfg → python-patterns" {
    touch setup.cfg
    local result
    result=$(detect_tier_a_skills)
    echo "$result" | grep -q "python-patterns"
}

@test "detect_tier_a_skills: anthropic import in .py → claude-api" {
    mkdir -p src
    echo "import anthropic" > src/main.py
    local result
    result=$(detect_tier_a_skills)
    echo "$result" | grep -q "claude-api"
}

@test "detect_tier_a_skills: @anthropic-ai in package.json → claude-api" {
    echo '{"dependencies":{"@anthropic-ai/sdk":"^1.0.0"}}' > package.json
    local result
    result=$(detect_tier_a_skills)
    echo "$result" | grep -q "claude-api"
}

@test "detect_tier_a_skills: package.json + express → backend-patterns" {
    echo '{"dependencies":{"express":"^4.0.0"}}' > package.json
    local result
    result=$(detect_tier_a_skills)
    echo "$result" | grep -q "backend-patterns"
}

@test "detect_tier_a_skills: package.json without express → no backend-patterns" {
    echo '{"dependencies":{"react":"^18.0.0"}}' > package.json
    local result
    result=$(detect_tier_a_skills)
    ! echo "$result" | grep -q "backend-patterns"
}

@test "detect_tier_a_skills: RALPH_TASK_SOURCE=linear env var → linear" {
    export RALPH_TASK_SOURCE="linear"
    local result
    result=$(detect_tier_a_skills)
    echo "$result" | grep -q "linear"
    unset RALPH_TASK_SOURCE
}

@test "detect_tier_a_skills: .ralphrc with RALPH_TASK_SOURCE=linear → linear" {
    echo 'RALPH_TASK_SOURCE=linear' > .ralphrc
    local result
    result=$(detect_tier_a_skills)
    echo "$result" | grep -q "linear"
}

@test "detect_tier_a_skills: tests/evals/ → eval-harness" {
    mkdir -p tests/evals
    local result
    result=$(detect_tier_a_skills)
    echo "$result" | grep -q "eval-harness"
}

@test "detect_tier_a_skills: multiple signals → multiple skills" {
    touch pyproject.toml
    mkdir -p tests/evals
    local result
    result=$(detect_tier_a_skills)
    echo "$result" | grep -q "python-patterns"
    echo "$result" | grep -q "eval-harness"
}

# ---------------------------------------------------------------------------
# install_project_tier_a_skills
# ---------------------------------------------------------------------------

@test "install_project_tier_a_skills: no skills detected → returns 0, no .claude/skills" {
    run install_project_tier_a_skills
    [[ "$status" -eq 0 ]]
    [[ ! -d ".claude/skills" ]] || [[ -z "$(ls -A .claude/skills 2>/dev/null)" ]]
}

@test "install_project_tier_a_skills: skill in global dir gets installed with sidecar" {
    # Plant a fake global skill directory to test the install path.
    local fake_global="$BATS_TEST_TMPDIR/fake_global_skills"
    mkdir -p "$fake_global/python-patterns"
    echo "# python-patterns skill" > "$fake_global/python-patterns/SKILL.md"

    # Override HOME so ~/.claude/skills resolves to our fake dir.
    local orig_home="$HOME"
    export HOME="$BATS_TEST_TMPDIR/fakehome"
    mkdir -p "$HOME/.claude/skills"
    cp -r "$fake_global/python-patterns" "$HOME/.claude/skills/"

    touch pyproject.toml  # triggers python-patterns detection

    run install_project_tier_a_skills
    [[ "$status" -eq 0 ]]
    [[ -f ".claude/skills/python-patterns/SKILL.md" ]]
    [[ -f ".claude/skills/python-patterns/.ralph-managed" ]]

    export HOME="$orig_home"
}

@test "install_project_tier_a_skills: skill not in global dir is skipped gracefully" {
    touch pyproject.toml  # triggers python-patterns
    # python-patterns is NOT in HOME/.claude/skills → should skip without error
    local orig_home="$HOME"
    export HOME="$BATS_TEST_TMPDIR/emptyhome"
    mkdir -p "$HOME/.claude/skills"

    run install_project_tier_a_skills
    [[ "$status" -eq 0 ]]
    [[ ! -f ".claude/skills/python-patterns/SKILL.md" ]]

    export HOME="$orig_home"
}

# ---------------------------------------------------------------------------
# inject_skill_hints_into_prompt (SKILLS-INJECT-4)
# ---------------------------------------------------------------------------

@test "inject_skill_hints_into_prompt: no-op when PROMPT.md missing" {
    run inject_skill_hints_into_prompt ".ralph/PROMPT.md"
    [[ "$status" -eq 0 ]]
}

@test "inject_skill_hints_into_prompt: appends Available Skills section" {
    mkdir -p .ralph
    echo "# Ralph Instructions" > .ralph/PROMPT.md

    local orig_home="$HOME"
    export HOME="$BATS_TEST_TMPDIR/skills_home"
    mkdir -p "$HOME/.claude/skills/search-first"
    cat > "$HOME/.claude/skills/search-first/SKILL.md" << 'EOF'
---
name: search-first
description: Search before writing code.
version: 1.0.0
ralph: true
---
## Body
EOF
    echo '{"ralph_version":"test","files":{}}' > "$HOME/.claude/skills/search-first/.ralph-managed"

    inject_skill_hints_into_prompt ".ralph/PROMPT.md"

    grep -q "## Available Skills" .ralph/PROMPT.md
    grep -q "/search-first" .ralph/PROMPT.md

    export HOME="$orig_home"
}

@test "inject_skill_hints_into_prompt: idempotent on second call" {
    mkdir -p .ralph
    echo "# Ralph Instructions" > .ralph/PROMPT.md

    local orig_home="$HOME"
    export HOME="$BATS_TEST_TMPDIR/skills_home2"
    mkdir -p "$HOME/.claude/skills/simplify"
    cat > "$HOME/.claude/skills/simplify/SKILL.md" << 'EOF'
---
name: simplify
description: Remove dead code.
version: 1.0.0
ralph: true
---
EOF
    echo '{}' > "$HOME/.claude/skills/simplify/.ralph-managed"

    inject_skill_hints_into_prompt ".ralph/PROMPT.md"
    inject_skill_hints_into_prompt ".ralph/PROMPT.md"

    local count
    count=$(grep -c "## Available Skills" .ralph/PROMPT.md)
    [[ "$count" -eq 1 ]]

    export HOME="$orig_home"
}

@test "inject_skill_hints_into_prompt: skips user-authored skills (no sidecar)" {
    mkdir -p .ralph
    echo "# Ralph Instructions" > .ralph/PROMPT.md

    local orig_home="$HOME"
    export HOME="$BATS_TEST_TMPDIR/skills_home3"
    mkdir -p "$HOME/.claude/skills/my-custom-skill"
    echo "# custom" > "$HOME/.claude/skills/my-custom-skill/SKILL.md"
    # No .ralph-managed sidecar → user-authored, should be skipped

    inject_skill_hints_into_prompt ".ralph/PROMPT.md"

    ! grep -q "my-custom-skill" .ralph/PROMPT.md

    export HOME="$orig_home"
}

@test "inject_skill_hints_into_prompt: block scalar description extracted correctly" {
    mkdir -p .ralph
    echo "# Ralph Instructions" > .ralph/PROMPT.md

    local orig_home="$HOME"
    export HOME="$BATS_TEST_TMPDIR/skills_home4"
    mkdir -p "$HOME/.claude/skills/tdd-workflow"
    cat > "$HOME/.claude/skills/tdd-workflow/SKILL.md" << 'EOF'
---
name: tdd-workflow
description: >
  Write tests first, then implement.
version: 1.0.0
ralph: true
---
EOF
    echo '{}' > "$HOME/.claude/skills/tdd-workflow/.ralph-managed"

    inject_skill_hints_into_prompt ".ralph/PROMPT.md"

    grep -q "Write tests first" .ralph/PROMPT.md

    export HOME="$orig_home"
}
