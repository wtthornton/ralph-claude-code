#!/usr/bin/env bats
# Unit Tests for FAILURE.md Protocol (FAILSPEC-1)
# Validates structure, frontmatter, and completeness of failure mode documentation.

load '../helpers/test_helper'

# FAILURE.md lives in the project root, not in .ralph/
PROJECT_ROOT="${BATS_TEST_DIRNAME}/../.."
FAILURE_FILE="${PROJECT_ROOT}/FAILURE.md"

@test "FAILURE.md exists in project root" {
    [[ -f "$FAILURE_FILE" ]] || fail "FAILURE.md not found at $FAILURE_FILE"
}

@test "FAILURE.md has valid YAML frontmatter delimiters" {
    head -1 "$FAILURE_FILE" | grep -q "^---$"
    local closing_line
    closing_line=$(awk 'NR>1 && /^---$/{print NR; exit}' "$FAILURE_FILE")
    [[ -n "$closing_line" ]] || fail "No closing frontmatter delimiter found"
}

@test "FAILURE.md frontmatter contains schema version" {
    grep -q "schema: failure-protocol/v1" "$FAILURE_FILE"
}

@test "FAILURE.md frontmatter contains agent name" {
    grep -q "agent: ralph" "$FAILURE_FILE"
}

@test "FAILURE.md frontmatter contains version" {
    grep -q "version:" "$FAILURE_FILE"
}

@test "FAILURE.md frontmatter contains last_reviewed date" {
    grep -q "last_reviewed:" "$FAILURE_FILE"
}

@test "FAILURE.md documents FM-001 API Rate Limit" {
    grep -q "FM-001" "$FAILURE_FILE"
    grep -q "API Rate Limit" "$FAILURE_FILE"
}

@test "FAILURE.md documents FM-002 Circuit Breaker Trip" {
    grep -q "FM-002" "$FAILURE_FILE"
    grep -q "Circuit Breaker Trip" "$FAILURE_FILE"
}

@test "FAILURE.md documents FM-003 Consecutive Timeout" {
    grep -q "FM-003" "$FAILURE_FILE"
    grep -q "Consecutive Timeout" "$FAILURE_FILE"
}

@test "FAILURE.md documents FM-007 File System Full" {
    grep -q "FM-007" "$FAILURE_FILE"
    grep -q "File System Full" "$FAILURE_FILE"
}

@test "FAILURE.md documents FM-008 Claude CLI Missing" {
    grep -q "FM-008" "$FAILURE_FILE"
    grep -q "Claude CLI" "$FAILURE_FILE"
}

@test "FAILURE.md documents all 12 failure modes" {
    for fm in FM-001 FM-002 FM-003 FM-004 FM-005 FM-006 FM-007 FM-008 FM-009 FM-010 FM-011 FM-012; do
        grep -q "$fm" "$FAILURE_FILE" || fail "Missing failure mode: $fm"
    done
}

@test "Each failure mode has Severity field" {
    local count
    count=$(grep -c "\*\*Severity:\*\*" "$FAILURE_FILE")
    [[ "$count" -ge 12 ]] || fail "Expected at least 12 Severity fields, found $count"
}

@test "Each failure mode has Detection field" {
    local count
    count=$(grep -c "\*\*Detection:\*\*" "$FAILURE_FILE")
    [[ "$count" -ge 12 ]] || fail "Expected at least 12 Detection fields, found $count"
}

@test "Each failure mode has Response field" {
    local count
    count=$(grep -c "\*\*Response:\*\*" "$FAILURE_FILE")
    [[ "$count" -ge 12 ]] || fail "Expected at least 12 Response fields, found $count"
}

@test "Each failure mode has Fallback field" {
    local count
    count=$(grep -c "\*\*Fallback:\*\*" "$FAILURE_FILE")
    [[ "$count" -ge 12 ]] || fail "Expected at least 12 Fallback fields, found $count"
}

@test "Each failure mode has Notification field" {
    local count
    count=$(grep -c "\*\*Notification:\*\*" "$FAILURE_FILE")
    [[ "$count" -ge 12 ]] || fail "Expected at least 12 Notification fields, found $count"
}

@test "Each failure mode has Recovery field" {
    local count
    count=$(grep -c "\*\*Recovery:\*\*" "$FAILURE_FILE")
    [[ "$count" -ge 12 ]] || fail "Expected at least 12 Recovery fields, found $count"
}

@test "FAILURE.md contains failure mode matrix" {
    grep -q "Failure Mode Matrix" "$FAILURE_FILE"
}

@test "FAILURE.md contains escalation chain" {
    grep -q "Escalation Chain" "$FAILURE_FILE"
}

# ============================================================================
# FAILSAFE.md Tests (FAILSPEC-2)
# ============================================================================

FAILSAFE_FILE="${PROJECT_ROOT}/FAILSAFE.md"

@test "FAILSAFE.md exists in project root" {
    [[ -f "$FAILSAFE_FILE" ]] || fail "FAILSAFE.md not found at $FAILSAFE_FILE"
}

@test "FAILSAFE.md has valid YAML frontmatter" {
    head -1 "$FAILSAFE_FILE" | grep -q "^---$"
    grep -q "schema: failsafe-protocol/v1" "$FAILSAFE_FILE"
    grep -q "agent: ralph" "$FAILSAFE_FILE"
}

@test "FAILSAFE.md documents degradation hierarchy with 7 levels" {
    grep -q "Degradation Hierarchy" "$FAILSAFE_FILE"
    grep -q "Full operation" "$FAILSAFE_FILE"
    grep -q "No sub-agents" "$FAILSAFE_FILE"
    grep -q "No hooks" "$FAILSAFE_FILE"
    grep -q "No session continuity" "$FAILSAFE_FILE"
    grep -q "No metrics/tracing" "$FAILSAFE_FILE"
    grep -q "No file protection" "$FAILSAFE_FILE"
    grep -q "HALT" "$FAILSAFE_FILE"
}

@test "FAILSAFE.md documents safe defaults table" {
    grep -q "Safe Defaults" "$FAILSAFE_FILE"
    grep -q "Missing.*status.json" "$FAILSAFE_FILE"
    grep -q "Missing.*ralphrc" "$FAILSAFE_FILE"
    grep -q "Circuit breaker state corrupt" "$FAILSAFE_FILE"
}

@test "FAILSAFE.md documents minimum viable operation" {
    grep -q "Minimum Viable Operation" "$FAILSAFE_FILE"
    grep -q "ralph_loop.sh" "$FAILSAFE_FILE"
    grep -q "circuit_breaker.sh" "$FAILSAFE_FILE"
    grep -q "Claude CLI" "$FAILSAFE_FILE"
    grep -q "fix_plan.md" "$FAILSAFE_FILE"
}

# ============================================================================
# KILLSWITCH.md Tests (FAILSPEC-3)
# ============================================================================

KILLSWITCH_FILE="${PROJECT_ROOT}/KILLSWITCH.md"
RALPH_LOOP_FILE="${PROJECT_ROOT}/ralph_loop.sh"

@test "KILLSWITCH.md exists in project root" {
    [[ -f "$KILLSWITCH_FILE" ]] || fail "KILLSWITCH.md not found at $KILLSWITCH_FILE"
}

@test "KILLSWITCH.md has valid YAML frontmatter" {
    head -1 "$KILLSWITCH_FILE" | grep -q "^---$"
    grep -q "schema: killswitch-protocol/v1" "$KILLSWITCH_FILE"
    grep -q "agent: ralph" "$KILLSWITCH_FILE"
}

@test "KILLSWITCH.md documents all stop triggers" {
    grep -q "SIGINT" "$KILLSWITCH_FILE"
    grep -q "SIGTERM" "$KILLSWITCH_FILE"
    grep -q "SIGKILL" "$KILLSWITCH_FILE"
    grep -q "ralph --stop" "$KILLSWITCH_FILE"
    grep -q ".killswitch" "$KILLSWITCH_FILE"
    grep -q "Circuit breaker" "$KILLSWITCH_FILE"
}

@test "KILLSWITCH.md documents cleanup guarantees" {
    grep -q "Cleanup Guarantees" "$KILLSWITCH_FILE"
    grep -q "Terminate Claude CLI" "$KILLSWITCH_FILE"
    grep -q "status.json" "$KILLSWITCH_FILE"
    grep -q "Release lock" "$KILLSWITCH_FILE"
}

@test "KILLSWITCH.md documents post-mortem data" {
    grep -q "Post-Mortem Data" "$KILLSWITCH_FILE"
    grep -q "ralph.log" "$KILLSWITCH_FILE"
    grep -q "circuit_breaker_state" "$KILLSWITCH_FILE"
}

@test "ralph_loop.sh contains ralph_check_killswitch function" {
    grep -q "ralph_check_killswitch()" "$RALPH_LOOP_FILE"
}

@test "ralph_loop.sh checks killswitch in main loop" {
    grep -q "ralph_check_killswitch" "$RALPH_LOOP_FILE"
    grep -q "killswitch_activated" "$RALPH_LOOP_FILE"
}

@test "ralph_check_killswitch reads reason from file" {
    # Source just enough to test the function
    export RALPH_DIR="$(mktemp -d)"
    mkdir -p "$RALPH_DIR"

    # Stub log_status to capture output
    log_status() { echo "$1: $2"; }
    export -f log_status

    # Source the function definition from ralph_loop.sh
    eval "$(grep -A 10 'ralph_check_killswitch()' "$RALPH_LOOP_FILE")"

    # No killswitch file — should return 0
    run ralph_check_killswitch
    [[ "$status" -eq 0 ]] || fail "Expected success when no killswitch file"

    # Create killswitch with reason
    echo "test stop reason" > "$RALPH_DIR/.killswitch"
    run ralph_check_killswitch
    [[ "$status" -eq 1 ]] || fail "Expected failure when killswitch file exists"
    [[ "$output" == *"test stop reason"* ]] || fail "Expected reason in output, got: $output"

    # File should be removed after check
    [[ ! -f "$RALPH_DIR/.killswitch" ]] || fail "Killswitch file should be removed after reading"

    rm -rf "$RALPH_DIR"
}

# ============================================================================
# Audit Logging Tests (FAILSPEC-4)
# ============================================================================

AUDIT_LIB="${PROJECT_ROOT}/lib/audit.sh"

@test "lib/audit.sh exists" {
    [[ -f "$AUDIT_LIB" ]] || fail "lib/audit.sh not found"
}

@test "ralph_audit writes structured JSONL" {
    export RALPH_DIR="$(mktemp -d)"
    export RALPH_AUDIT_LOG="$RALPH_DIR/.audit.jsonl"
    export RALPH_AUDIT_LOG_ENABLED="true"
    export RALPH_VERSION="2.0.0"
    mkdir -p "$RALPH_DIR"

    source "$AUDIT_LIB"

    ralph_audit "test_event" "test_actor" "test_decision" "test_reason" "success"

    [[ -f "$RALPH_AUDIT_LOG" ]] || fail "Audit log not created"
    jq -e '.event_type == "test_event"' "$RALPH_AUDIT_LOG" > /dev/null || fail "event_type mismatch"
    jq -e '.actor == "test_actor"' "$RALPH_AUDIT_LOG" > /dev/null || fail "actor mismatch"
    jq -e '.decision == "test_decision"' "$RALPH_AUDIT_LOG" > /dev/null || fail "decision mismatch"
    jq -e '.reason == "test_reason"' "$RALPH_AUDIT_LOG" > /dev/null || fail "reason mismatch"
    jq -e '.outcome == "success"' "$RALPH_AUDIT_LOG" > /dev/null || fail "outcome mismatch"

    rm -rf "$RALPH_DIR"
}

@test "ralph_audit includes all required fields" {
    export RALPH_DIR="$(mktemp -d)"
    export RALPH_AUDIT_LOG="$RALPH_DIR/.audit.jsonl"
    export RALPH_AUDIT_LOG_ENABLED="true"
    export RALPH_VERSION="2.0.0"
    mkdir -p "$RALPH_DIR"

    source "$AUDIT_LIB"

    ralph_audit "test" "actor" "decision" "reason" "outcome"

    # Verify all required fields exist
    for field in timestamp event_type actor decision reason outcome trace_id session_id ralph_version; do
        jq -e "has(\"$field\")" "$RALPH_AUDIT_LOG" > /dev/null || fail "Missing field: $field"
    done

    rm -rf "$RALPH_DIR"
}

@test "ralph_audit is no-op when disabled" {
    export RALPH_DIR="$(mktemp -d)"
    export RALPH_AUDIT_LOG="$RALPH_DIR/.audit.jsonl"
    export RALPH_AUDIT_LOG_ENABLED="false"
    mkdir -p "$RALPH_DIR"

    source "$AUDIT_LIB"

    ralph_audit "test" "test" "test" "test"

    [[ ! -f "$RALPH_AUDIT_LOG" ]] || fail "Audit log should not exist when disabled"

    rm -rf "$RALPH_DIR"
}

@test "ralph_audit defaults outcome to pending" {
    export RALPH_DIR="$(mktemp -d)"
    export RALPH_AUDIT_LOG="$RALPH_DIR/.audit.jsonl"
    export RALPH_AUDIT_LOG_ENABLED="true"
    export RALPH_VERSION="2.0.0"
    mkdir -p "$RALPH_DIR"

    source "$AUDIT_LIB"

    ralph_audit "test" "actor" "decision" "reason"

    jq -e '.outcome == "pending"' "$RALPH_AUDIT_LOG" > /dev/null || fail "Default outcome should be 'pending'"

    rm -rf "$RALPH_DIR"
}

@test "ralph_loop.sh sources lib/audit.sh" {
    grep -q 'lib/audit.sh' "$RALPH_LOOP_FILE" || fail "ralph_loop.sh does not source audit.sh"
}

@test "ralph_loop.sh instruments loop_start audit event" {
    grep -q 'ralph_audit "loop_start"' "$RALPH_LOOP_FILE" || fail "Missing loop_start audit event"
}

@test "ralph_loop.sh instruments circuit_breaker audit event" {
    grep -q 'ralph_audit "circuit_breaker"' "$RALPH_LOOP_FILE" || fail "Missing circuit_breaker audit event"
}

@test "ralph_loop.sh instruments killswitch audit event" {
    grep -q 'ralph_audit "killswitch"' "$RALPH_LOOP_FILE" || fail "Missing killswitch audit event"
}

@test "ralph_loop.sh instruments exit_decision audit event" {
    grep -q 'ralph_audit "exit_decision"' "$RALPH_LOOP_FILE" || fail "Missing exit_decision audit event"
}
