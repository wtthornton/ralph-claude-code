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
