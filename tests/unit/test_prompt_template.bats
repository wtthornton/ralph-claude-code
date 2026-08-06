#!/usr/bin/env bats
# Unit tests for templates/PROMPT.md and templates/skills-local/ralph-workflow/SKILL.md
#
# Tests cover: TAP-593 optimizer hint step 0 presence in ralph-workflow skill,
# and that templates/PROMPT.md defers to the skill for task-selection contract.

load '../helpers/test_helper'

_TEMPLATE_SKILL_FILE="${BATS_TEST_DIRNAME}/../../templates/skills-local/ralph-workflow/SKILL.md"
_TEMPLATE_PROMPT_FILE="${BATS_TEST_DIRNAME}/../../templates/PROMPT.md"

# =============================================================================
# TEST 1: ralph-workflow skill contains optimizer hint step 0
# =============================================================================

@test "TAP-593: ralph-workflow SKILL.md contains optimizer hint step 0" {
    [[ -f "$_TEMPLATE_SKILL_FILE" ]]
    # Step 0 must instruct Claude to honor the LOCALITY HINT and delete the file
    grep -q 'LOCALITY HINT' "$_TEMPLATE_SKILL_FILE"
    grep -q 'linear_next_issue' "$_TEMPLATE_SKILL_FILE"
    grep -q 'rm -f .ralph/.linear_next_issue' "$_TEMPLATE_SKILL_FILE"
}

# =============================================================================
# TEST 2: templates/PROMPT.md references the ralph-workflow skill
# =============================================================================

@test "TAP-593: templates/PROMPT.md defers task-selection contract to ralph-workflow skill" {
    [[ -f "$_TEMPLATE_PROMPT_FILE" ]]
    # Must reference the skill that now owns the task-selection contract
    grep -q 'ralph-workflow' "$_TEMPLATE_PROMPT_FILE"
}

# =============================================================================
# TEST 3: TAP-2333 — the three upstreamed PROMPT.md hardening rules are present
# (TAP-2332 friction patterns promoted to the template so every Ralph-managed
# project inherits them via ralph-upgrade-project). A future template edit must
# not silently drop them.
# =============================================================================

@test "TAP-2333: Pattern 1 — python3 -c → /tmp/snippet.py / python-introspection" {
    [[ -f "$_TEMPLATE_PROMPT_FILE" ]]
    grep -q '/tmp/snippet.py' "$_TEMPLATE_PROMPT_FILE"
    grep -q 'python-introspection' "$_TEMPLATE_PROMPT_FILE"
}

@test "TAP-2333: Pattern 2 — Read before first Edit reminder" {
    grep -qi 'Read before Edit' "$_TEMPLATE_PROMPT_FILE"
    grep -q 'File has not been read yet' "$_TEMPLATE_PROMPT_FILE"
}

@test "TAP-2333: Pattern 3 — git status busy-dir guard with STATUS: BLOCKED pivot" {
    grep -q 'STATUS: BLOCKED' "$_TEMPLATE_PROMPT_FILE"
    grep -q 'RALPH_BUSY_DIRS' "$_TEMPLATE_PROMPT_FILE"
}

# =============================================================================
# TEST 4: TAP-2716 — audit-campaign label selection rules.
# audit-fix is a single fix story (selectable); not-implementable / audit-digest
# are finding bundles that must NEVER be auto-selected. The behavior lives in
# skill + PROMPT prose only (OAuth-via-MCP selection has no bash seam), so these
# content assertions are the deterministic guard against a future edit dropping
# the rule. Extends the audit-readonly precedent.
# =============================================================================

@test "TAP-2716: ralph-workflow SKILL.md marks not-implementable / audit-digest non-selectable" {
    [[ -f "$_TEMPLATE_SKILL_FILE" ]]
    grep -q 'not-implementable' "$_TEMPLATE_SKILL_FILE"
    grep -q 'audit-digest' "$_TEMPLATE_SKILL_FILE"
    # The "never auto-select" rule must be present, not just the label name.
    grep -qi 'Never auto-select' "$_TEMPLATE_SKILL_FILE"
    # audit-fix must remain selectable.
    grep -q 'audit-fix' "$_TEMPLATE_SKILL_FILE"
}

@test "TAP-2716: templates/PROMPT.md carries the audit-label selection note" {
    [[ -f "$_TEMPLATE_PROMPT_FILE" ]]
    grep -q 'audit-fix' "$_TEMPLATE_PROMPT_FILE"
    grep -qi 'NEVER auto-select' "$_TEMPLATE_PROMPT_FILE"
    grep -q 'not-implementable' "$_TEMPLATE_PROMPT_FILE"
    grep -q 'audit-digest' "$_TEMPLATE_PROMPT_FILE"
}

@test "TAP-2716: ralph-workflow skill stays byte-identical across all three install copies" {
    # The harness keeps templates/skills-local (source), .claude/skills, and
    # .cursor/skills byte-identical; an audit-label edit to one must hit all.
    local src="${BATS_TEST_DIRNAME}/../.."
    local a="$src/templates/skills-local/ralph-workflow/SKILL.md"
    local b="$src/.claude/skills/ralph-workflow/SKILL.md"
    local c="$src/.cursor/skills/ralph-workflow/SKILL.md"
    diff -q "$a" "$b" || fail "templates/skills-local and .claude/skills diverged"
    diff -q "$a" "$c" || fail "templates/skills-local and .cursor/skills diverged"
}
