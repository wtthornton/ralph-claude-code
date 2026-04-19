#!/usr/bin/env bats
# TAP-575: Content contract for Ralph's global skill library.
# Every SKILL.md must have "When to invoke" and "Exit criteria" sections
# so that Ralph's main loop (and any future skill-retro logic in
# TAP-578/579) can rely on a predictable shape when reading these files.

bats_require_minimum_version 1.5.0
load '../helpers/test_helper'

SKILLS_ROOT="${BATS_TEST_DIRNAME}/../../templates/skills/global"

TIER_S_SKILLS=(search-first tdd-workflow simplify context-audit agentic-engineering)

setup() {
    [[ -d "$SKILLS_ROOT" ]] || skip "templates/skills/global not present"
}

@test "TAP-575: every SKILL.md has a 'When to invoke' section" {
    for s in "${TIER_S_SKILLS[@]}"; do
        local file="$SKILLS_ROOT/$s/SKILL.md"
        grep -qE '^##[[:space:]]+When to invoke' "$file" \
            || fail "$s: missing '## When to invoke' section"
    done
}

@test "TAP-575: every SKILL.md has an 'Exit criteria' section" {
    for s in "${TIER_S_SKILLS[@]}"; do
        local file="$SKILLS_ROOT/$s/SKILL.md"
        grep -qE '^##[[:space:]]+Exit criteria' "$file" \
            || fail "$s: missing '## Exit criteria' section"
    done
}

@test "TAP-575: every SKILL.md references Ralph-specific context" {
    # The point of a Ralph-hardened skill is that it names concrete loop
    # signals (fix_plan.md, EXIT_SIGNAL, ralph-explorer, etc.). A skill
    # that reads like generic advice with no Ralph nouns in it is a
    # regression we want to catch early.
    local ralph_terms='ralph|fix_plan|EXIT_SIGNAL|ralph-explorer|ralph-tester|ralph-reviewer|ralph-architect|RALPH_STATUS|epic boundary'

    for s in "${TIER_S_SKILLS[@]}"; do
        local file="$SKILLS_ROOT/$s/SKILL.md"
        grep -qEi "$ralph_terms" "$file" \
            || fail "$s: no Ralph-specific anchor found (expected one of: $ralph_terms)"
    done
}

@test "TAP-575: every skill has at least one example file" {
    for s in "${TIER_S_SKILLS[@]}"; do
        local examples_dir="$SKILLS_ROOT/$s/examples"
        [[ -d "$examples_dir" ]] || fail "$s: examples/ directory missing"
        local count
        count=$(find "$examples_dir" -maxdepth 1 -type f -name '*.md' | wc -l)
        (( count >= 1 )) || fail "$s: no .md files under examples/"
    done
}

@test "TAP-575: every SKILL.md mentions at least one sub-agent integration" {
    # Sub-agent integration is a required section per the spec; the
    # simplest structural check is that the file names at least one
    # of the four Ralph sub-agents.
    for s in "${TIER_S_SKILLS[@]}"; do
        local file="$SKILLS_ROOT/$s/SKILL.md"
        grep -qE 'ralph-(explorer|tester|reviewer|architect)' "$file" \
            || fail "$s: SKILL.md does not reference any ralph-* sub-agent"
    done
}
