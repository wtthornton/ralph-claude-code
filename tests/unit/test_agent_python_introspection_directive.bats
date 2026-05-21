#!/usr/bin/env bats
# TAP-2256: every Ralph agent system prompt that has Bash access — plus
# the consumer-project PROMPT.md template — must surface the
# python-introspection workaround so the agent doesn't burn tool calls
# on `python3 -c '...'` against projects that block it via PreToolUse
# hooks. Field-observed 2026-05-20 on AgentForge (3 hits / 25 min run).
#
# Scope rationale: ralph-explorer.md and ralph-reviewer.md don't have
# Bash in their `tools:` list, so they physically can't trigger this
# friction and don't need the directive.

bats_require_minimum_version 1.5.0
load '../helpers/test_helper'

REPO_ROOT="${BATS_TEST_DIRNAME}/../.."

# Files that ship with `Bash` tool access OR drive consumer-project
# agents — all four MUST carry the /tmp/snippet.py directive.
AGENT_FILES=(
    "$REPO_ROOT/.claude/agents/ralph.md"
    "$REPO_ROOT/.claude/agents/ralph-tester.md"
    "$REPO_ROOT/.claude/agents/ralph-architect.md"
    "$REPO_ROOT/templates/PROMPT.md"
)

@test "TAP-2256: every Bash-capable agent prompt names /tmp/snippet.py" {
    for f in "${AGENT_FILES[@]}"; do
        [[ -f "$f" ]] || fail "missing: $f"
        grep -qF '/tmp/snippet.py' "$f" \
            || fail "$(basename "$f"): missing /tmp/snippet.py workaround pointer"
    done
}

@test "TAP-2256: every Bash-capable agent prompt cross-references python-introspection skill" {
    for f in "${AGENT_FILES[@]}"; do
        grep -qE 'python-introspection' "$f" \
            || fail "$(basename "$f"): missing python-introspection skill reference"
    done
}

@test "TAP-2256: every Bash-capable agent prompt warns about validate-command / PreToolUse hooks" {
    # The reason the workaround matters — agents need to know WHY they
    # should avoid `python3 -c`, not just that they should.
    for f in "${AGENT_FILES[@]}"; do
        grep -qE 'PreToolUse|validate-command' "$f" \
            || fail "$(basename "$f"): missing PreToolUse / validate-command hook context"
    done
}

@test "TAP-2256: ralph-explorer.md is intentionally NOT in scope (no Bash tool)" {
    # If someone adds Bash to ralph-explorer's tools, this test will
    # remind them to add the directive there too. We grep the agent
    # file's frontmatter; the absence of Bash is what justifies the
    # absence of the directive.
    local explorer="$REPO_ROOT/.claude/agents/ralph-explorer.md"
    [[ -f "$explorer" ]] || skip "ralph-explorer.md not present"
    if grep -qE '^\s*-\s*Bash\s*$' "$explorer"; then
        fail "ralph-explorer.md gained Bash access — add /tmp/snippet.py directive to it too"
    fi
}

@test "TAP-2256: ralph-reviewer.md is intentionally NOT in scope (no Bash tool)" {
    local reviewer="$REPO_ROOT/.claude/agents/ralph-reviewer.md"
    [[ -f "$reviewer" ]] || skip "ralph-reviewer.md not present"
    if grep -qE '^\s*-\s*Bash\s*$' "$reviewer"; then
        fail "ralph-reviewer.md gained Bash access — add /tmp/snippet.py directive to it too"
    fi
}
