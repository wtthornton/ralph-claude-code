#!/usr/bin/env bats
# TAP-914: .ralph/brief.json schema + lib/brief.sh helpers.
# Verifies brief_path, brief_exists, brief_read_field, brief_validate,
# brief_write (atomic), and brief_clear against the schema documented in
# docs/specs/brief-schema.md.

bats_require_minimum_version 1.5.0
load '../helpers/test_helper'

REPO_ROOT="${BATS_TEST_DIRNAME}/../.."
BRIEF_LIB="${REPO_ROOT}/lib/brief.sh"

# Override RALPH_DIR to point at this test's tmpdir so brief_path() resolves
# locally and we never touch the real .ralph/.
setup() {
    export TEST_TEMP_DIR="$(mktemp -d "${BATS_TEST_TMPDIR:-/tmp}/brief.XXXXXX")"
    cd "$TEST_TEMP_DIR"
    export RALPH_DIR="$TEST_TEMP_DIR/.ralph"
    mkdir -p "$RALPH_DIR"
    # shellcheck disable=SC1090
    source "$BRIEF_LIB"
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR" 2>/dev/null || true
}

# A canonical, valid brief used as the base for negative tests.
valid_brief_json() {
    cat <<'EOF'
{
  "schema_version": 1,
  "task_id": "TAP-914",
  "task_source": "linear",
  "task_summary": "Define brief.json schema and bash helpers.",
  "risk_level": "MEDIUM",
  "affected_modules": ["lib/brief.sh"],
  "acceptance_criteria": ["sourceable", "validates"],
  "prior_learnings": [],
  "qa_required": true,
  "qa_scope": "tests/unit/test_brief_schema.bats",
  "delegate_to": "ralph",
  "coordinator_confidence": 0.85,
  "created_at": "2026-04-29T22:30:00Z"
}
EOF
}

@test "TAP-914: lib/brief.sh is sourceable and exports helpers" {
    type brief_path
    type brief_exists
    type brief_read_field
    type brief_validate
    type brief_write
    type brief_clear
}

@test "TAP-914: brief_path honors RALPH_DIR override" {
    run brief_path
    assert_success
    assert_output "$RALPH_DIR/brief.json"
}

@test "TAP-914: brief_exists is false for missing file" {
    run brief_exists
    assert_failure
}

@test "TAP-914: brief_validate accepts the canonical valid brief" {
    local p="$RALPH_DIR/brief.json"
    valid_brief_json > "$p"
    run brief_validate "$p"
    assert_success
}

@test "TAP-914: brief_validate rejects missing schema_version" {
    local p="$RALPH_DIR/brief.json"
    valid_brief_json | jq 'del(.schema_version)' > "$p"
    run brief_validate "$p"
    assert_failure
    [[ "$output" == *"schema_version"* ]] || fail "stderr should mention schema_version, got: $output"
}

@test "TAP-914: brief_validate rejects wrong schema_version" {
    local p="$RALPH_DIR/brief.json"
    valid_brief_json | jq '.schema_version = 2' > "$p"
    run brief_validate "$p"
    assert_failure
    [[ "$output" == *"schema_version must be 1"* ]] || fail "got: $output"
}

@test "TAP-914: brief_validate rejects invalid risk_level" {
    local p="$RALPH_DIR/brief.json"
    valid_brief_json | jq '.risk_level = "CRITICAL"' > "$p"
    run brief_validate "$p"
    assert_failure
    [[ "$output" == *"risk_level"* ]] || fail "got: $output"
}

@test "TAP-914: brief_validate rejects invalid task_source" {
    local p="$RALPH_DIR/brief.json"
    valid_brief_json | jq '.task_source = "github"' > "$p"
    run brief_validate "$p"
    assert_failure
    [[ "$output" == *"task_source"* ]] || fail "got: $output"
}

@test "TAP-914: brief_validate rejects invalid delegate_to" {
    local p="$RALPH_DIR/brief.json"
    valid_brief_json | jq '.delegate_to = "ralph-explorer"' > "$p"
    run brief_validate "$p"
    assert_failure
    [[ "$output" == *"delegate_to"* ]] || fail "got: $output"
}

@test "TAP-914: brief_validate rejects coordinator_confidence < 0" {
    local p="$RALPH_DIR/brief.json"
    valid_brief_json | jq '.coordinator_confidence = -0.1' > "$p"
    run brief_validate "$p"
    assert_failure
    [[ "$output" == *"coordinator_confidence"* ]] || fail "got: $output"
}

@test "TAP-914: brief_validate rejects coordinator_confidence > 1" {
    local p="$RALPH_DIR/brief.json"
    valid_brief_json | jq '.coordinator_confidence = 1.5' > "$p"
    run brief_validate "$p"
    assert_failure
    [[ "$output" == *"coordinator_confidence"* ]] || fail "got: $output"
}

@test "TAP-914: brief_validate rejects non-array affected_modules" {
    local p="$RALPH_DIR/brief.json"
    valid_brief_json | jq '.affected_modules = "lib/brief.sh"' > "$p"
    run brief_validate "$p"
    assert_failure
    [[ "$output" == *"affected_modules"* ]] || fail "got: $output"
}

@test "TAP-914: brief_validate rejects empty file" {
    local p="$RALPH_DIR/brief.json"
    : > "$p"
    run brief_validate "$p"
    assert_failure
    [[ "$output" == *"missing or empty"* ]] || fail "got: $output"
}

@test "TAP-914: brief_validate rejects malformed JSON" {
    local p="$RALPH_DIR/brief.json"
    echo '{not json' > "$p"
    run brief_validate "$p"
    assert_failure
}

@test "TAP-914: brief_write rejects invalid JSON without touching target" {
    local p="$RALPH_DIR/brief.json"
    valid_brief_json > "$p"
    local before_md5
    before_md5=$(md5sum "$p" | cut -d' ' -f1)

    run brief_write '{not json'
    assert_failure
    [[ "$output" == *"invalid JSON"* ]] || fail "got: $output"

    local after_md5
    after_md5=$(md5sum "$p" | cut -d' ' -f1)
    [[ "$before_md5" == "$after_md5" ]] || fail "previous brief was corrupted by failed write"
}

@test "TAP-914: brief_write writes valid JSON atomically (no tmp leftovers)" {
    run brief_write "$(valid_brief_json)"
    assert_success
    [[ -s "$RALPH_DIR/brief.json" ]] || fail "brief not written"
    # No stray .tmp files in the dir.
    local leftovers
    leftovers=$(find "$RALPH_DIR" -name 'brief.json.tmp.*' -print 2>/dev/null | wc -l | tr -cd '0-9')
    [[ "${leftovers:-0}" == "0" ]] || fail "found tmp leftovers"
    # Round-trip parses.
    jq -e . "$RALPH_DIR/brief.json" >/dev/null
}

@test "TAP-914: concurrent brief_write calls never produce partial JSON" {
    # Fire 8 concurrent writes; verify the final file always parses.
    local i
    for i in 1 2 3 4 5 6 7 8; do
        ( brief_write "$(valid_brief_json | jq --argjson n "$i" '.coordinator_confidence = ($n / 10)')" ) &
    done
    wait
    [[ -s "$RALPH_DIR/brief.json" ]] || fail "no brief written"
    jq -e . "$RALPH_DIR/brief.json" >/dev/null || fail "final brief is partial JSON"
    # No stray tmp files.
    local leftovers
    leftovers=$(find "$RALPH_DIR" -name 'brief.json.tmp.*' -print 2>/dev/null | wc -l | tr -cd '0-9')
    [[ "${leftovers:-0}" == "0" ]] || fail "tmp leftovers after concurrent writes: $leftovers"
}

@test "TAP-914: brief_read_field reads top-level scalar" {
    valid_brief_json > "$RALPH_DIR/brief.json"
    run brief_read_field "task_id"
    assert_success
    assert_output "TAP-914"
}

@test "TAP-914: brief_read_field returns non-zero on missing field" {
    valid_brief_json > "$RALPH_DIR/brief.json"
    run brief_read_field "no_such_field"
    assert_failure
}

@test "TAP-914: brief_read_field returns non-zero on missing file" {
    run brief_read_field "task_id"
    assert_failure
}

@test "TAP-914: brief_clear removes the brief file" {
    valid_brief_json > "$RALPH_DIR/brief.json"
    run brief_clear
    assert_success
    [[ ! -e "$RALPH_DIR/brief.json" ]] || fail "brief still present after clear"
}

@test "TAP-914: brief_exists is true after a successful brief_write" {
    brief_write "$(valid_brief_json)"
    run brief_exists
    assert_success
}
