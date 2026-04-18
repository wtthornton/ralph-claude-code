#!/usr/bin/env bats
# TAP-538: Tests for templates/hooks/on-stop.sh resilience and parity.
#
# Focus:
#   * Corrupt .circuit_breaker_state must be auto-repaired with a WARN, not a
#     hook crash that blocks the loop.
#   * .ralph/hooks/on-stop.sh must stay byte-identical to the template (drift
#     means a stale, less-hardened hook ships with the project).

bats_require_minimum_version 1.5.0
load '../helpers/test_helper'

REPO_ROOT="${BATS_TEST_DIRNAME}/../.."
TEMPLATE_HOOK="${REPO_ROOT}/templates/hooks/on-stop.sh"
RUNTIME_HOOK="${REPO_ROOT}/.ralph/hooks/on-stop.sh"

setup() {
    export TEST_TEMP_DIR="$(mktemp -d)"
    cd "$TEST_TEMP_DIR"
    # Hook keys off CLAUDE_PROJECT_DIR for the .ralph location.
    export CLAUDE_PROJECT_DIR="$TEST_TEMP_DIR"
    mkdir -p "$TEST_TEMP_DIR/.ralph"
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR"
}

# Minimal valid CLI response payload the hook can parse.
_valid_input() {
    cat <<'JSON'
{"result":"Did some work.\n\n```json\n{\"RALPH_STATUS\":{\"EXIT_SIGNAL\":false,\"FILES_MODIFIED\":0,\"TASKS_COMPLETED\":0,\"WORK_TYPE\":\"IMPLEMENTATION\"}}\n```"}
JSON
}

# =============================================================================
# Drift parity — TAP-538 root cause was the runtime hook losing template fixes
# =============================================================================

@test "TAP-538: .ralph/hooks/on-stop.sh is byte-identical to templates/hooks/on-stop.sh" {
    [[ -f "$TEMPLATE_HOOK" ]] || skip "template hook missing: $TEMPLATE_HOOK"
    [[ -f "$RUNTIME_HOOK" ]] || skip "runtime hook missing: $RUNTIME_HOOK"
    run diff -q "$RUNTIME_HOOK" "$TEMPLATE_HOOK"
    assert_success
}

@test "TAP-538: .ralph/hooks/on-session-start.sh is byte-identical to template" {
    local tpl="${REPO_ROOT}/templates/hooks/on-session-start.sh"
    local rt="${REPO_ROOT}/.ralph/hooks/on-session-start.sh"
    [[ -f "$tpl" && -f "$rt" ]] || skip "on-session-start.sh missing in tpl or runtime"
    run diff -q "$rt" "$tpl"
    assert_success
}

# =============================================================================
# CB state recovery — corrupt input must NOT crash the hook
# =============================================================================

@test "TAP-538: corrupt .circuit_breaker_state is auto-repaired, hook exits 0" {
    # Seed a deliberately corrupt file (not valid JSON).
    printf 'this is not json {{{ broken' > "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state"

    # Run the hook with a valid payload; the corrupt CB state must be repaired
    # rather than crash the hook.
    run --separate-stderr bash "$TEMPLATE_HOOK" <<<"$(_valid_input)"
    assert_success

    # WARN must be logged on stderr.
    [[ "$stderr" == *"corrupt"* && "$stderr" == *"reinitializing"* ]] || \
        fail "expected reinit WARN on stderr, got: $stderr"

    # File must now be valid JSON.
    run jq -e 'type == "object"' "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state"
    assert_success

    # Re-init must produce a CB-state object with the expected shape. The
    # hook's normal logic runs immediately after repair, so the no-progress
    # counter may have been incremented to 1 by this same invocation — that's
    # fine; what we assert is that the schema is restored.
    run jq -e '
        (.state | type == "string") and
        (.consecutive_no_progress | type == "number") and
        (.consecutive_permission_denials | type == "number") and
        (.total_opens | type == "number")
    ' "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state"
    assert_success
}

@test "TAP-538: empty .circuit_breaker_state is treated as corrupt and repaired" {
    : > "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state"
    run --separate-stderr bash "$TEMPLATE_HOOK" <<<"$(_valid_input)"
    assert_success
    run jq -e 'type == "object"' "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state"
    assert_success
}

@test "TAP-538: valid .circuit_breaker_state is preserved (no spurious reinit)" {
    # Seed a valid CB state with non-default counters.
    printf '%s\n' \
        '{"state":"CLOSED","consecutive_no_progress":2,"consecutive_permission_denials":1,"total_opens":3}' \
        > "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state"

    run --separate-stderr bash "$TEMPLATE_HOOK" <<<"$(_valid_input)"
    assert_success

    # No reinit WARN should fire on a healthy state.
    [[ "$stderr" != *"corrupt"* ]] || \
        fail "valid state should not be reported as corrupt: $stderr"

    # The hook IS allowed to mutate counters per its progress rules; we only
    # assert the file is still valid JSON of the right shape after the run.
    run jq -e '(.state | type == "string") and (.consecutive_no_progress | type == "number")' \
        "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state"
    assert_success
}

# =============================================================================
# EXIT-CLEAN: Claude's `EXIT_SIGNAL: true + STATUS: COMPLETE` with 0/0 changes
# is a legitimate clean-exit signal, not stagnation. The hook must not increment
# consecutive_no_progress in that case (otherwise empty-plan launches burn 3
# Claude calls before the no-progress CB trips).
# =============================================================================

# Helper: build a Claude response payload with a RALPH_STATUS block.
_status_block_input() {
    local exit_signal="$1" status="$2" tasks="$3" files="$4"
    local body="Result.

---RALPH_STATUS---
STATUS: ${status}
TASKS_COMPLETED_THIS_LOOP: ${tasks}
FILES_MODIFIED: ${files}
TESTS_STATUS: NOT_RUN
WORK_TYPE: IMPLEMENTATION
EXIT_SIGNAL: ${exit_signal}
RECOMMENDATION: Test payload.
---END_RALPH_STATUS---"
    jq -Rs '{result: .}' <<<"$body"
}

@test "EXIT-CLEAN: EXIT_SIGNAL=true + STATUS=COMPLETE + 0/0 RESETS no-progress (does NOT increment)" {
    # Pre-seed: no-progress already at 2 (one more 'no progress' would trip on threshold=3).
    printf '%s\n' \
        '{"state":"CLOSED","consecutive_no_progress":2,"consecutive_permission_denials":0,"total_opens":0}' \
        > "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state"

    run --separate-stderr bash "$TEMPLATE_HOOK" <<<"$(_status_block_input true COMPLETE 0 0)"
    assert_success

    # Counter must be reset to 0, state must remain CLOSED — exit_signal is a
    # request for clean shutdown, not a stagnation indicator.
    run jq -r '.consecutive_no_progress' "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state"
    assert_output "0"
    run jq -r '.state' "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state"
    assert_output "CLOSED"
}

@test "EXIT-CLEAN guard: EXIT_SIGNAL=false + 0/0 STILL increments no-progress (regression guard)" {
    # Same seed; this time EXIT_SIGNAL=false (no clean-exit request).
    # Hook must STILL count this as no-progress and trip the CB at threshold=3.
    printf '%s\n' \
        '{"state":"CLOSED","consecutive_no_progress":2,"consecutive_permission_denials":0,"total_opens":0}' \
        > "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state"

    run --separate-stderr bash "$TEMPLATE_HOOK" <<<"$(_status_block_input false IN_PROGRESS 0 0)"
    assert_success

    run jq -r '.consecutive_no_progress' "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state"
    assert_output "3"
    run jq -r '.state' "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state"
    assert_output "OPEN"
}

@test "EXIT-CLEAN guard: EXIT_SIGNAL=true but STATUS!=COMPLETE does NOT bypass no-progress" {
    # Defensive: only honor exit-clean when BOTH signals agree. EXIT_SIGNAL=true
    # without STATUS=COMPLETE is ambiguous — fall through to normal classification.
    printf '%s\n' \
        '{"state":"CLOSED","consecutive_no_progress":2,"consecutive_permission_denials":0,"total_opens":0}' \
        > "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state"

    run --separate-stderr bash "$TEMPLATE_HOOK" <<<"$(_status_block_input true PARTIAL 0 0)"
    assert_success

    # Should be treated as no-progress and trip.
    run jq -r '.consecutive_no_progress' "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state"
    assert_output "3"
}

@test "EXIT-CLEAN: status.json after EXIT_SIGNAL=true is valid JSON (Bug 1 regression guard)" {
    # The grep -c || echo 0 pattern previously injected a stray '0\n' into status.json,
    # which broke ralph_loop.sh's downstream jq reads. Template was fixed via tr -cd '0-9'.
    # This test asserts status.json stays valid JSON across the EXIT_SIGNAL=true path.
    printf '%s\n' \
        '{"state":"CLOSED","consecutive_no_progress":0,"consecutive_permission_denials":0,"total_opens":0}' \
        > "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state"
    printf '{"loop_count": 5}' > "$TEST_TEMP_DIR/.ralph/status.json"

    run --separate-stderr bash "$TEMPLATE_HOOK" <<<"$(_status_block_input true COMPLETE 0 0)"
    assert_success

    # status.json must be valid JSON with exit_signal field intact.
    run jq -e 'type == "object" and .exit_signal == "true"' "$TEST_TEMP_DIR/.ralph/status.json"
    assert_success
}
