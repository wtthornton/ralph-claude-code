#!/usr/bin/env bats
# TAP-1875: ralph_spawn_coordinator must (a) succeed when the coordinator
# writes a valid brief on the first invocation, and (b) retry once + emit a
# brain_learn_failure signal when the coordinator returns rc=0 without
# writing the brief file. This test file complements test_coordinator_spawn.bats
# with TAP-1875-specific coverage.

bats_require_minimum_version 1.5.0

REPO_ROOT_FIXED="${BATS_TEST_DIRNAME}/../.."

setup() {
    export TEST_TEMP_DIR="$(mktemp -d "${BATS_TEST_TMPDIR:-/tmp}/coord_brief.XXXXXX")"
    cd "$TEST_TEMP_DIR"
    mkdir -p .ralph .ralph/logs
    export RALPH_DIR="$TEST_TEMP_DIR/.ralph"
    export LOG_DIR="$RALPH_DIR/logs"
    export DRY_RUN=false
    unset RALPH_COORDINATOR_DISABLED || true

    set --
    # shellcheck disable=SC1090
    source "$REPO_ROOT_FIXED/ralph_loop.sh"
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR" 2>/dev/null || true
}

write_valid_brief() {
    cat > "$RALPH_DIR/brief.json" <<'EOF'
{
  "schema_version": 1,
  "task_id": "TAP-1875",
  "task_source": "file",
  "task_summary": "coordinator must write brief on success.",
  "risk_level": "LOW",
  "affected_modules": ["ralph_loop.sh"],
  "acceptance_criteria": ["brief written on first try"],
  "prior_learnings": [],
  "qa_required": true,
  "qa_scope": "tests/unit/test_coordinator_brief.bats",
  "delegate_to": "ralph",
  "coordinator_confidence": 0.8,
  "created_at": "2026-05-16T00:00:00Z"
}
EOF
}

@test "TAP-1875: success path returns 0, writes brief, logs INFO without retry" {
    local _calls_file="$TEST_TEMP_DIR/.coord_calls"
    : > "$_calls_file"
    _coordinator_invoke_claude() {
        echo "call" >> "$_calls_file"
        write_valid_brief
        return 0
    }
    export CLAUDE_CODE_CMD=bash

    run ralph_spawn_coordinator 1
    [[ "$status" -eq 0 ]] || fail "expected zero exit on success, got $status: $output"
    [[ -s "$RALPH_DIR/brief.json" ]] || fail "brief not written"
    [[ "$output" == *"brief written"* ]] \
        || fail "expected INFO log on success, got: $output"
    # Retry path MUST NOT fire on the success path — exactly one invocation.
    local _n
    _n=$(wc -l < "$_calls_file" | tr -d '[:space:]')
    [[ "$_n" == "1" ]] || fail "expected 1 coordinator call on success, got $_n"
    [[ "$output" != *"brief written on retry"* ]] \
        || fail "retry path fired on success path"
}

@test "TAP-1875: rc=0 + no file triggers exactly one retry, then WARN" {
    local _calls_file="$TEST_TEMP_DIR/.coord_calls"
    : > "$_calls_file"
    # Mock returns 0 but never writes the brief — the canonical 88%
    # regression signature.
    _coordinator_invoke_claude() {
        echo "call" >> "$_calls_file"
        return 0
    }
    export CLAUDE_CODE_CMD=bash

    run ralph_spawn_coordinator 2
    [[ "$status" -eq 0 ]] || fail "expected zero exit (best-effort), got $status: $output"
    [[ "$output" == *"missing or invalid"* ]] \
        || fail "expected WARN about missing brief, got: $output"
    [[ ! -e "$RALPH_DIR/brief.json" ]] || fail "no brief expected after WARN"
    # Retry must fire exactly once — total of 2 calls.
    local _n
    _n=$(wc -l < "$_calls_file" | tr -d '[:space:]')
    [[ "$_n" == "2" ]] \
        || fail "expected 2 coordinator calls (1 initial + 1 retry), got $_n"
}

@test "TAP-1875: rc=0 + retry writes brief — INFO logs 'brief written on retry'" {
    local _calls_file="$TEST_TEMP_DIR/.coord_calls"
    : > "$_calls_file"
    # First call writes nothing; second call writes a valid brief. This
    # exercises the retry-recovers code path the harness ships.
    _coordinator_invoke_claude() {
        local n
        echo "call" >> "$_calls_file"
        n=$(wc -l < "$_calls_file" | tr -d '[:space:]')
        if [[ "$n" -ge 2 ]]; then
            write_valid_brief
        fi
        return 0
    }
    export CLAUDE_CODE_CMD=bash

    run ralph_spawn_coordinator 3
    [[ "$status" -eq 0 ]] || fail "expected zero exit, got $status: $output"
    [[ -s "$RALPH_DIR/brief.json" ]] || fail "brief should exist after retry recovered"
    [[ "$output" == *"brief written on retry"* ]] \
        || fail "expected INFO mentioning retry recovery, got: $output"
    [[ "$output" != *"missing or invalid"* ]] \
        || fail "should not WARN when retry recovered"
}

@test "TAP-1875: rc=0 + no file after retry calls brain_client_write_failure" {
    : > "$TEST_TEMP_DIR/.brain_calls"
    _coordinator_invoke_claude() { return 0; }
    # Override the brain client wrapper so we can assert it was invoked
    # with the expected task_id and source values without making real
    # network calls.
    brain_client_write_failure() {
        printf '%s\n' "$@" >> "$TEST_TEMP_DIR/.brain_calls"
    }
    export CLAUDE_CODE_CMD=bash

    run ralph_spawn_coordinator 4
    [[ "$status" -eq 0 ]] || fail "expected zero exit, got $status: $output"
    [[ -s "$TEST_TEMP_DIR/.brain_calls" ]] \
        || fail "brain_client_write_failure not invoked on rc=0-no-file"
    grep -q 'coordinator returned without writing brief.json' \
        "$TEST_TEMP_DIR/.brain_calls" \
        || fail "brain_client_write_failure description does not match expected text"
    grep -q 'coordinator-brief' "$TEST_TEMP_DIR/.brain_calls" \
        || fail "brain_client_write_failure source tag missing"
}

@test "TAP-1875: prompt body includes a literal Write-tool instruction" {
    # Capture the prompt body passed to the coordinator so we can assert
    # the user-visible upgrade landed in the prompt itself rather than
    # only the agent file.
    _coordinator_invoke_claude() {
        printf '%s' "$1" > "$TEST_TEMP_DIR/.coord_prompt"
        write_valid_brief
        return 0
    }
    export CLAUDE_CODE_CMD=bash

    run ralph_spawn_coordinator 1
    [[ "$status" -eq 0 ]] || fail "expected zero exit, got: $output"
    grep -q 'Write tool' "$TEST_TEMP_DIR/.coord_prompt" \
        || fail "prompt body should name the Write tool literally"
    grep -q 'atomic at the tool layer' "$TEST_TEMP_DIR/.coord_prompt" \
        || fail "prompt body should explain Write-tool atomicity"
    grep -q 'schema_version' "$TEST_TEMP_DIR/.coord_prompt" \
        || fail "prompt body should spell out the JSON schema fields"
}
