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
