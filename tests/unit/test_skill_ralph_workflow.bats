#!/usr/bin/env bats
# Contract tests for the Ralph-local skill `ralph-workflow`.
#
# This skill ships under templates/skills-local/ (NOT the tier-S global
# library). It is installed per-project into each Ralph-managed project's
# .claude/skills/ralph-workflow/ — so the rules it enforces (RALPH_STATUS
# block schema, epic-boundary QA deferral, EXIT_SIGNAL gate) only apply
# when Claude runs in a Ralph project, not globally.
#
# The harness reads RALPH_STATUS fields from Claude's response and gates
# the circuit breaker + exit logic on them. If this skill ever drifts away
# from the field names / values the loop expects, the harness will silently
# miscount progress. These tests pin the schema.

bats_require_minimum_version 1.5.0
load '../helpers/test_helper'

SKILL_FILE="${BATS_TEST_DIRNAME}/../../templates/skills-local/ralph-workflow/SKILL.md"

extract_frontmatter() {
    local file="$1"
    awk '
        BEGIN { in_fm = 0; started = 0 }
        /^---[[:space:]]*$/ {
            if (!started) { started = 1; in_fm = 1; next }
            else if (in_fm) { exit }
        }
        in_fm { print }
    ' "$file"
}

@test "ralph-workflow skill file exists" {
    [[ -f "$SKILL_FILE" ]] || fail "missing $SKILL_FILE"
}

@test "ralph-workflow has YAML frontmatter" {
    local fm
    fm=$(extract_frontmatter "$SKILL_FILE")
    [[ -n "$fm" ]] || fail "no frontmatter in $SKILL_FILE"
}

@test "ralph-workflow frontmatter declares name, description, ralph_local" {
    local fm
    fm=$(extract_frontmatter "$SKILL_FILE")
    echo "$fm" | grep -qE '^name:[[:space:]]*ralph-workflow[[:space:]]*$' || fail "name: must be 'ralph-workflow'"
    echo "$fm" | grep -qE '^description:' || fail "description: missing"
    echo "$fm" | grep -qE '^ralph_local:[[:space:]]*true[[:space:]]*$' || fail "ralph_local: true missing (distinguishes from tier-S global skills)"
}

@test "ralph-workflow frontmatter declares allowed-tools including Task" {
    # Task is needed because the skill tells Claude to delegate to
    # ralph-explorer / ralph-tester sub-agents.
    local fm
    fm=$(extract_frontmatter "$SKILL_FILE")
    echo "$fm" | grep -qE '^[[:space:]]*-[[:space:]]*Task[[:space:]]*$' || fail "allowed-tools must include Task"
}

@test "ralph-workflow body pins the RALPH_STATUS block schema" {
    # These are the exact field names the harness (on-stop.sh + loop) reads.
    # If the skill drops or renames any of them, status reporting breaks.
    local required_fields=(
        "STATUS:"
        "TASKS_COMPLETED_THIS_LOOP:"
        "FILES_MODIFIED:"
        "TESTS_STATUS:"
        "WORK_TYPE:"
        "EXIT_SIGNAL:"
        "RECOMMENDATION:"
    )
    for field in "${required_fields[@]}"; do
        grep -qF "$field" "$SKILL_FILE" || fail "skill body missing RALPH_STATUS field: $field"
    done
    grep -qF -- "---RALPH_STATUS---" "$SKILL_FILE" || fail "skill body missing block start delimiter"
    grep -qF -- "---END_RALPH_STATUS---" "$SKILL_FILE" || fail "skill body missing block end delimiter"
}

@test "ralph-workflow forbids EXIT_SIGNAL:true paired with TESTS_STATUS:DEFERRED" {
    # The dual-condition exit gate depends on this — a deferred-tests exit is
    # the specific failure mode that motivated the gate. The skill must state
    # the rule explicitly so Claude never emits that combination.
    grep -qiE 'Never.*EXIT_SIGNAL.*DEFERRED|EXIT_SIGNAL.*true.*DEFERRED' "$SKILL_FILE" \
        || fail "skill must explicitly forbid EXIT_SIGNAL:true with TESTS_STATUS:DEFERRED"
}

@test "ralph-workflow documents epic-boundary QA deferral" {
    # Mid-epic loops must set TESTS_STATUS: DEFERRED; full QA runs at the
    # last `- [ ]` under a `##` section. If this guidance disappears the
    # batched-task speed optimization falls apart.
    grep -qE 'epic.?boundary' "$SKILL_FILE" || fail "skill must mention epic boundary concept"
    grep -qF "DEFERRED" "$SKILL_FILE" || fail "skill must describe DEFERRED test status"
}

@test "ralph-workflow documents STOP-after-status discipline" {
    # Claude must end the response right after the status block — otherwise
    # it starts the next task mid-response and the harness can't cleanly
    # re-invoke.
    grep -qE '\bSTOP\b' "$SKILL_FILE" || fail "skill must tell Claude to STOP after the status block"
}

# -----------------------------------------------------------------------------
# Install wiring
# -----------------------------------------------------------------------------
# The skill has to actually reach each project's .claude/skills/ or the rules
# above are aspirational. These tests verify the plumbing that gets it there.

@test "setup.sh installs ralph-workflow into new projects' .claude/skills/" {
    run grep -F 'skills-local' "${BATS_TEST_DIRNAME}/../../setup.sh"
    assert_success
    grep -qF '.claude/skills' "${BATS_TEST_DIRNAME}/../../setup.sh" \
        || fail "setup.sh must write into .claude/skills/"
    grep -qF '.cursor/skills' "${BATS_TEST_DIRNAME}/../../setup.sh" \
        || fail "setup.sh must mirror skills into .cursor/skills/"
}

@test "upgrade_skills_local mirrors skills-local into .cursor/skills/" {
    grep -qF '.cursor/skills' "${BATS_TEST_DIRNAME}/../../ralph_upgrade_project.sh" \
        || fail "ralph_upgrade_project.sh must mirror skills into .cursor/skills/"
}

@test "ralph_upgrade_project.sh has upgrade_skills_local()" {
    run grep -F 'upgrade_skills_local()' "${BATS_TEST_DIRNAME}/../../ralph_upgrade_project.sh"
    assert_success
}

@test "ralph_upgrade_project.sh calls upgrade_skills_local during upgrade" {
    # Specifically, the call must live in the function that drives per-project
    # upgrade (after upgrade_agents). Otherwise the function is dead code.
    local script="${BATS_TEST_DIRNAME}/../../ralph_upgrade_project.sh"
    local call_line def_line
    call_line=$(grep -n '^[[:space:]]*upgrade_skills_local[[:space:]]*"' "$script" | head -1 | cut -d: -f1)
    def_line=$(grep -n '^upgrade_skills_local()' "$script" | head -1 | cut -d: -f1)
    [[ -n "$call_line" ]] || fail "upgrade_skills_local is never called"
    [[ -n "$def_line" ]] || fail "upgrade_skills_local is never defined"
    [[ "$call_line" != "$def_line" ]] || fail "call and definition are the same line?"
}

@test "RALPH_SKILLS_LOCAL_SOURCE points under \$RALPH_TEMPLATES/skills-local" {
    run grep -E '^RALPH_SKILLS_LOCAL_SOURCE=' "${BATS_TEST_DIRNAME}/../../ralph_upgrade_project.sh"
    assert_success
    [[ "$output" == *'skills-local'* ]] || fail "expected skills-local in path, got: $output"
}
