#!/usr/bin/env bats
# TAP-2498: brief schema additive change — new acceptance_action enum
# alongside the existing free-text acceptance_criteria array. Closed enum
# prevents the wording drift observed across AgentForge loops 106-109 where
# the coordinator emitted "Emit EXIT_SIGNAL: true" → "loop continues cleanly"
# → "harness will halt" for identical empty-backlog input, and the agent
# followed each variant differently.

bats_require_minimum_version 1.5.0
load '../helpers/test_helper'

REPO_ROOT="${BATS_TEST_DIRNAME}/../.."

setup() {
    export TEST_TEMP_DIR="$(mktemp -d)"
    cd "$TEST_TEMP_DIR"
    source "$REPO_ROOT/lib/brief.sh"
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR"
}

# Helper: write a brief.json with optional extra fields
_write_brief() {
    local extra="$1"
    cat > "$TEST_TEMP_DIR/brief.json" <<EOF
{
  "schema_version": 1,
  "task_id": "TAP-1234",
  "task_source": "linear",
  "task_summary": "Test brief",
  "risk_level": "LOW",
  "affected_modules": ["lib/x.sh"],
  "acceptance_criteria": ["criterion 1"],
  "prior_learnings": [],
  "qa_required": true,
  "qa_scope": "tests/x.bats",
  "delegate_to": "ralph",
  "coordinator_confidence": 0.8,
  "created_at": "2026-05-23T00:00:00Z"
  $extra
}
EOF
}

# =============================================================================
# 1. Legacy brief (no acceptance_action) → accept (backward compat)
# =============================================================================
@test "TAP-2498: brief without acceptance_action validates (legacy backward compat)" {
    _write_brief ""
    run brief_validate "$TEST_TEMP_DIR/brief.json"
    assert_success
}

# =============================================================================
# 2. Valid acceptance_action enum → accept
# =============================================================================
@test "TAP-2498: acceptance_action=EMIT_EXIT_SIGNAL validates" {
    _write_brief ',"acceptance_action":"EMIT_EXIT_SIGNAL"'
    run brief_validate "$TEST_TEMP_DIR/brief.json"
    assert_success
}

@test "TAP-2498: acceptance_action=IMPLEMENT validates" {
    _write_brief ',"acceptance_action":"IMPLEMENT"'
    run brief_validate "$TEST_TEMP_DIR/brief.json"
    assert_success
}

@test "TAP-2498: acceptance_action=BLOCK validates" {
    _write_brief ',"acceptance_action":"BLOCK"'
    run brief_validate "$TEST_TEMP_DIR/brief.json"
    assert_success
}

@test "TAP-2498: acceptance_action=CONTINUE_AND_RETRY validates" {
    _write_brief ',"acceptance_action":"CONTINUE_AND_RETRY"'
    run brief_validate "$TEST_TEMP_DIR/brief.json"
    assert_success
}

# =============================================================================
# 3. Invalid acceptance_action value → reject
# =============================================================================
@test "TAP-2498: acceptance_action with free-text value is rejected" {
    _write_brief ',"acceptance_action":"make it work"'
    run brief_validate "$TEST_TEMP_DIR/brief.json"
    assert_failure
    [[ "$output" == *"acceptance_action must be one of"* ]] || { echo "expected enum error in output: $output"; return 1; }
}

# =============================================================================
# 4. acceptance_action with wrong type (number) → reject
# =============================================================================
@test "TAP-2498: acceptance_action with non-string value is rejected" {
    _write_brief ',"acceptance_action":42'
    run brief_validate "$TEST_TEMP_DIR/brief.json"
    assert_failure
}

# =============================================================================
# 5. acceptance_action_rationale (informative field) — accepts any string
# =============================================================================
@test "TAP-2498: acceptance_action_rationale free-text validates" {
    _write_brief ',"acceptance_action":"EMIT_EXIT_SIGNAL","acceptance_action_rationale":"empty backlog confirmed, halt"'
    run brief_validate "$TEST_TEMP_DIR/brief.json"
    assert_success
}

# =============================================================================
# 6. Lowercase enum value is rejected (case-sensitive)
# =============================================================================
@test "TAP-2498: acceptance_action=emit_exit_signal (lowercase) is rejected" {
    _write_brief ',"acceptance_action":"emit_exit_signal"'
    run brief_validate "$TEST_TEMP_DIR/brief.json"
    assert_failure
}
