#!/usr/bin/env bats
# SKILLS-INJECT-5/6: Tests for lib/skill_retro.sh friction detection and retro apply.

bats_require_minimum_version 1.5.0
load '../helpers/test_helper'

SKILL_RETRO="$BATS_TEST_DIRNAME/../../lib/skill_retro.sh"

setup() {
    export RALPH_DIR="$BATS_TEST_TMPDIR/.ralph"
    mkdir -p "$RALPH_DIR/logs"
    export RALPH_VERSION="test"
    export RALPH_SKILL_AUTO_TUNE="false"
    export RALPH_SKILL_RETRO_WINDOW="5"
    # shellcheck disable=SC1090
    source "$SKILL_RETRO"
}

teardown() {
    rm -rf "$BATS_TEST_TMPDIR/.ralph"
}

_write_status() {
    # Args: tasks_completed files_modified work_type has_permission_denials permission_denial_count loop_count
    jq -n \
        --argjson tc "${1:-0}" \
        --argjson fm "${2:-0}" \
        --arg wt "${3:-UNKNOWN}" \
        --argjson hpd "${4:-false}" \
        --argjson pdc "${5:-0}" \
        --argjson lc "${6:-1}" \
        '{tasks_completed:$tc, files_modified:$fm, work_type:$wt,
          has_permission_denials:$hpd, permission_denial_count:$pdc, loop_count:$lc}' \
        > "$RALPH_DIR/status.json"
}

# ---------------------------------------------------------------------------
# skill_retro_detect_friction
# ---------------------------------------------------------------------------

@test "SKILLS-INJECT-5: no status.json → valid JSON, no friction" {
    run skill_retro_detect_friction
    [[ "$status" -eq 0 ]]
    echo "$output" | jq -e '.has_friction == false' >/dev/null
    echo "$output" | jq -e '.friction_signals | length == 0' >/dev/null
}

@test "SKILLS-INJECT-5: permission denials → friction signal + agentic-engineering" {
    _write_status 0 0 "UNKNOWN" true 3 5
    run skill_retro_detect_friction
    [[ "$status" -eq 0 ]]
    echo "$output" | jq -e '.has_friction == true' >/dev/null
    echo "$output" | jq -e '[.friction_signals[].type] | contains(["permission_denials"])' >/dev/null
    echo "$output" | jq -e '.recommended_skills | contains(["agentic-engineering"])' >/dev/null
}

@test "SKILLS-INJECT-5: no progress → no_progress signal" {
    _write_status 0 0 "IMPLEMENTATION" false 0 10
    run skill_retro_detect_friction
    [[ "$status" -eq 0 ]]
    echo "$output" | jq -e '[.friction_signals[].type] | contains(["no_progress"])' >/dev/null
}

@test "SKILLS-INJECT-5: tasks completed → no no_progress signal" {
    _write_status 1 3 "IMPLEMENTATION" false 0 5
    run skill_retro_detect_friction
    [[ "$status" -eq 0 ]]
    ! echo "$output" | jq -e '[.friction_signals[].type] | contains(["no_progress"])' >/dev/null
}

@test "SKILLS-INJECT-5: repeated stalls in log → repeated_stall signal + search-first" {
    # Write several RALPH_STATUS blocks with TASKS_COMPLETED_THIS_LOOP: 0
    for i in 1 2 3 4; do
        echo "---RALPH_STATUS---" >> "$RALPH_DIR/logs/ralph.log"
        echo "STATUS: IN_PROGRESS" >> "$RALPH_DIR/logs/ralph.log"
        echo "TASKS_COMPLETED_THIS_LOOP: 0" >> "$RALPH_DIR/logs/ralph.log"
        echo "---END_RALPH_STATUS---" >> "$RALPH_DIR/logs/ralph.log"
    done
    _write_status 0 0 "IMPLEMENTATION" false 0 10
    run skill_retro_detect_friction
    [[ "$status" -eq 0 ]]
    echo "$output" | jq -e '[.friction_signals[].type] | contains(["repeated_stall"])' >/dev/null
    echo "$output" | jq -e '.recommended_skills | contains(["search-first"])' >/dev/null
}

@test "SKILLS-INJECT-5: repeated test failures → tdd-workflow recommendation" {
    for i in 1 2 3; do
        echo "TESTS_STATUS: FAILING" >> "$RALPH_DIR/logs/ralph.log"
    done
    _write_status 1 2 "IMPLEMENTATION" false 0 5
    run skill_retro_detect_friction
    [[ "$status" -eq 0 ]]
    echo "$output" | jq -e '.recommended_skills | contains(["tdd-workflow"])' >/dev/null
}

@test "SKILLS-INJECT-5: unknown work type + no progress → confused_work_type signal" {
    _write_status 0 0 "UNKNOWN" false 0 5
    run skill_retro_detect_friction
    [[ "$status" -eq 0 ]]
    echo "$output" | jq -e '[.friction_signals[].type] | contains(["confused_work_type"])' >/dev/null
}

@test "SKILLS-INJECT-5: output has required top-level keys" {
    run skill_retro_detect_friction
    [[ "$status" -eq 0 ]]
    echo "$output" | jq -e '.timestamp' >/dev/null
    echo "$output" | jq -e '.loop_count' >/dev/null
    echo "$output" | jq -e 'has("has_friction")' >/dev/null
    echo "$output" | jq -e '.friction_signals | type == "array"' >/dev/null
    echo "$output" | jq -e '.recommended_skills | type == "array"' >/dev/null
}

@test "SKILLS-INJECT-5: recommended skills deduplicated across multiple signals" {
    # Permission denials AND confused_work_type both recommend agentic-engineering.
    _write_status 0 0 "UNKNOWN" true 2 5
    run skill_retro_detect_friction
    [[ "$status" -eq 0 ]]
    local count
    count=$(echo "$output" | jq '[.recommended_skills[] | select(. == "agentic-engineering")] | length')
    [[ "$count" -eq 1 ]]
}

# ---------------------------------------------------------------------------
# skill_retro_apply (SKILLS-INJECT-6)
# ---------------------------------------------------------------------------

@test "SKILLS-INJECT-6: advisory mode logs recommendation, no files written" {
    local friction
    friction=$(jq -n '{has_friction:true, recommended_skills:["tdd-workflow"], friction_signals:[]}')
    local target="$BATS_TEST_TMPDIR/target_skills"

    run skill_retro_apply "$friction" "$target" "$BATS_TEST_TMPDIR/global_skills"
    [[ "$status" -eq 0 ]]
    [[ ! -d "$target" ]] || [[ -z "$(ls -A "$target" 2>/dev/null)" ]]
}

@test "SKILLS-INJECT-6: no friction → apply is no-op" {
    local friction
    friction=$(jq -n '{has_friction:false, recommended_skills:[], friction_signals:[]}')
    local target="$BATS_TEST_TMPDIR/noop_skills"

    run skill_retro_apply "$friction" "$target"
    [[ "$status" -eq 0 ]]
    [[ ! -d "$target" ]] || [[ -z "$(ls -A "$target" 2>/dev/null)" ]]
}

@test "SKILLS-INJECT-6: auto-tune installs one skill from global dir" {
    export RALPH_SKILL_AUTO_TUNE="true"

    local global="$BATS_TEST_TMPDIR/global_skills"
    mkdir -p "$global/tdd-workflow"
    echo "# tdd" > "$global/tdd-workflow/SKILL.md"

    local target="$BATS_TEST_TMPDIR/target_skills"
    local friction
    friction=$(jq -n '{has_friction:true, recommended_skills:["tdd-workflow"], friction_signals:[]}')

    run skill_retro_apply "$friction" "$target" "$global"
    [[ "$status" -eq 0 ]]
    [[ -f "$target/tdd-workflow/SKILL.md" ]]
    [[ -f "$target/tdd-workflow/.ralph-managed" ]]

    export RALPH_SKILL_AUTO_TUNE="false"
}

@test "SKILLS-INJECT-6: auto-tune skips already-installed skill" {
    export RALPH_SKILL_AUTO_TUNE="true"

    local global="$BATS_TEST_TMPDIR/global_skills2"
    mkdir -p "$global/search-first"
    echo "# search" > "$global/search-first/SKILL.md"

    local target="$BATS_TEST_TMPDIR/target_skills2"
    mkdir -p "$target/search-first"
    echo "# already here" > "$target/search-first/SKILL.md"

    local friction
    friction=$(jq -n '{has_friction:true, recommended_skills:["search-first"], friction_signals:[]}')

    run skill_retro_apply "$friction" "$target" "$global"
    [[ "$status" -eq 0 ]]

    # The existing file should be unchanged (no sidecar → user-authored, won't overwrite)
    grep -q "already here" "$target/search-first/SKILL.md"

    export RALPH_SKILL_AUTO_TUNE="false"
}

@test "SKILLS-INJECT-7: periodic reconcile skipped when loop_count not a multiple" {
    local global="$BATS_TEST_TMPDIR/global_pr"
    mkdir -p "$global/python-patterns"
    echo "# py" > "$global/python-patterns/SKILL.md"

    local proj="$BATS_TEST_TMPDIR/proj_pr"
    mkdir -p "$proj"
    touch "$proj/pyproject.toml"

    # Loop 3 with interval 10 — should NOT install
    run skill_retro_periodic_reconcile 3 "$proj" "$global"
    [[ "$status" -eq 0 ]]
    [[ ! -d "$proj/.claude/skills/python-patterns" ]]
}

@test "SKILLS-INJECT-7: periodic reconcile installs skill at interval boundary" {
    local global="$BATS_TEST_TMPDIR/global_pr2"
    mkdir -p "$global/python-patterns"
    echo "# py" > "$global/python-patterns/SKILL.md"

    local proj="$BATS_TEST_TMPDIR/proj_pr2"
    mkdir -p "$proj"
    touch "$proj/pyproject.toml"

    # Loop 10 with interval 10 — SHOULD install
    export RALPH_SKILL_REDETECT_INTERVAL=10
    run skill_retro_periodic_reconcile 10 "$proj" "$global"
    [[ "$status" -eq 0 ]]
    [[ -f "$proj/.claude/skills/python-patterns/SKILL.md" ]]
    [[ -f "$proj/.claude/skills/python-patterns/.ralph-managed" ]]
}

@test "SKILLS-INJECT-7: periodic reconcile skips already-installed skill" {
    local global="$BATS_TEST_TMPDIR/global_pr3"
    mkdir -p "$global/python-patterns"
    echo "# py" > "$global/python-patterns/SKILL.md"

    local proj="$BATS_TEST_TMPDIR/proj_pr3"
    mkdir -p "$proj"
    touch "$proj/pyproject.toml"
    mkdir -p "$proj/.claude/skills/python-patterns"
    echo "# existing" > "$proj/.claude/skills/python-patterns/SKILL.md"

    export RALPH_SKILL_REDETECT_INTERVAL=10
    run skill_retro_periodic_reconcile 10 "$proj" "$global"
    [[ "$status" -eq 0 ]]
    # Existing file should remain (no sidecar → user-authored, not overwritten)
    grep -q "existing" "$proj/.claude/skills/python-patterns/SKILL.md"
}

@test "SKILLS-INJECT-6: auto-tune gracefully handles missing global skill" {
    export RALPH_SKILL_AUTO_TUNE="true"

    local global="$BATS_TEST_TMPDIR/global_empty"
    mkdir -p "$global"

    local target="$BATS_TEST_TMPDIR/target_empty"
    local friction
    friction=$(jq -n '{has_friction:true, recommended_skills:["nonexistent-skill"], friction_signals:[]}')

    run skill_retro_apply "$friction" "$target" "$global"
    [[ "$status" -eq 0 ]]

    export RALPH_SKILL_AUTO_TUNE="false"
}
