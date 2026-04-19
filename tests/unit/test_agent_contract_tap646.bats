#!/usr/bin/env bats
# TAP-646: guard against agent contract drift.
#
# A. ralph-tester must match the doc claim (Sonnet, worktree-isolated).
# B. No agent file may declare `Agent(...)` as a tool — that's not a valid
#    entry in the Claude Code schema; sub-agent delegation uses `Task`.

load '../helpers/test_helper'

PROJECT_ROOT="${BATS_TEST_DIRNAME}/../.."

@test "TAP-646 A: ralph-tester uses model: sonnet (matches CLAUDE.md)" {
    run grep -E "^model: sonnet$" "$PROJECT_ROOT/.claude/agents/ralph-tester.md"
    assert_success
}

@test "TAP-646 B: no agent file uses invalid Agent(...) tool entry" {
    run grep -nE "^  - Agent\(" "$PROJECT_ROOT/.claude/agents/"*.md
    [[ "$status" -ne 0 ]]
}

@test "TAP-646 B: ralph.md declares Task in its tool list" {
    run grep -E "^  - Task$" "$PROJECT_ROOT/.claude/agents/ralph.md"
    assert_success
}

@test "TAP-646 B: ralph-architect.md declares Task in its tool list" {
    run grep -E "^  - Task$" "$PROJECT_ROOT/.claude/agents/ralph-architect.md"
    assert_success
}

@test "TAP-646: every tool entry resolves to a known Claude Code tool name" {
    # The canonical tool set as of the CLAUDE.md contract.
    local allowed='^(Read|Write|Edit|Glob|Grep|Bash|Task|TodoWrite|WebFetch|WebSearch|NotebookEdit|ExitPlanMode|mcp__docs-mcp__\*|Bash\([^)]*\))$'
    local unknown=0
    for f in "$PROJECT_ROOT/.claude/agents/"*.md; do
        # Parse tools: block — lines "  - <name>" between "^tools:$" and next unindented key
        local names
        names=$(awk '/^tools:$/{in_t=1; next} in_t && /^  - /{print $2; next} in_t && /^[a-zA-Z]/{in_t=0}' "$f")
        while IFS= read -r name; do
            [[ -z "$name" ]] && continue
            if ! grep -qE "$allowed" <<< "$name"; then
                echo "UNKNOWN tool in $f: $name" >&2
                unknown=1
            fi
        done <<< "$names"
    done
    [[ "$unknown" -eq 0 ]]
}
