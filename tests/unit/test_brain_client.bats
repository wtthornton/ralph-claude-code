#!/usr/bin/env bats
# Tests for lib/brain_client.sh
#
# TAP-747: HTTP 5xx from /v1/remember must not trip the session kill-switch
#          (server-side bug, not our client's fault).
# TAP-750: on-stop hook must source secrets.env when TAPPS_BRAIN_AUTH_TOKEN
#          is absent (VSCode-launched sessions never run ralph_loop.sh).

bats_require_minimum_version 1.5.0
load '../helpers/test_helper'

REPO_ROOT="${BATS_TEST_DIRNAME}/../.."
BRAIN_CLIENT="${REPO_ROOT}/lib/brain_client.sh"
TEMPLATE_HOOK="${REPO_ROOT}/templates/hooks/on-stop.sh"

setup() {
    export TEST_TEMP_DIR="$(mktemp -d)"
    export RALPH_DIR="$TEST_TEMP_DIR/.ralph"
    mkdir -p "$RALPH_DIR/metrics"
    unset TAPPS_BRAIN_AUTH_TOKEN
}

teardown() {
    rm -rf "$TEST_TEMP_DIR"
}

# =============================================================================
# TAP-747: kill-switch granularity
# =============================================================================

@test "TAP-747: 5xx response does NOT trip session kill-switch" {
    source "$BRAIN_CLIENT"
    brain_client_record_metric "$RALPH_DIR" "success" "500" "50" "server_error"
    [[ ! -f "$RALPH_DIR/.brain_disabled_this_session" ]]
}

@test "TAP-747: 000 (curl failure) DOES trip session kill-switch" {
    source "$BRAIN_CLIENT"
    brain_client_record_metric "$RALPH_DIR" "success" "000" "0" "no_connection"
    [[ -f "$RALPH_DIR/.brain_disabled_this_session" ]]
}

@test "TAP-747: 4xx response DOES trip session kill-switch" {
    source "$BRAIN_CLIENT"
    brain_client_record_metric "$RALPH_DIR" "success" "400" "30" "validation_error"
    [[ -f "$RALPH_DIR/.brain_disabled_this_session" ]]
}

@test "TAP-747: 200 response does NOT trip session kill-switch" {
    source "$BRAIN_CLIENT"
    brain_client_record_metric "$RALPH_DIR" "success" "200" "45" ""
    [[ ! -f "$RALPH_DIR/.brain_disabled_this_session" ]]
}

@test "TAP-747: 5xx does not disable brain_client_enabled after first call" {
    source "$BRAIN_CLIENT"
    export TAPPS_BRAIN_AUTH_TOKEN="test-token"
    brain_client_record_metric "$RALPH_DIR" "success" "503" "50" "server_error"
    run brain_client_enabled "$RALPH_DIR"
    assert_success
}

# =============================================================================
# TAP-2678: a client-side circuit-breaker-open skip (http 200) is logged with a
# distinct op:cb_open_skip, NOT op:failure, so audits don't read a healthy brain
# as unhealthy.
# =============================================================================

@test "TAP-2678: CB-open at http 200 logs op:cb_open_skip, not failure" {
    source "$BRAIN_CLIENT"
    brain_client_record_metric "$RALPH_DIR" "failure" "200" "12" "circuit_breaker_open"
    local row
    row=$(cat "$RALPH_DIR/metrics/brain.jsonl")
    echo "$row" | grep -q '"op":"cb_open_skip"'
    echo "$row" | grep -q '"http_code":"200"'
    # And it must NOT be recorded as a failure.
    ! echo "$row" | grep -q '"op":"failure"'
}

@test "TAP-2678: a genuine failure (non-200) still logs op:failure" {
    source "$BRAIN_CLIENT"
    brain_client_record_metric "$RALPH_DIR" "failure" "500" "40" "server_error"
    grep -q '"op":"failure"' "$RALPH_DIR/metrics/brain.jsonl"
}

@test "TAP-2678: CB-open reason at non-200 is left as-is (not rewritten)" {
    source "$BRAIN_CLIENT"
    # A CB-open skip that coincided with a real error code keeps op:failure.
    brain_client_record_metric "$RALPH_DIR" "failure" "000" "0" "circuit_breaker_open"
    grep -q '"op":"failure"' "$RALPH_DIR/metrics/brain.jsonl"
}

# =============================================================================
# TAP-750: secrets.env sourcing in the template hook
# =============================================================================

@test "TAP-750: template on-stop.sh sources secrets.env when token absent" {
    grep -q 'TAPPS_BRAIN_AUTH_TOKEN.*secrets\.env\|secrets\.env.*TAPPS_BRAIN_AUTH_TOKEN' \
        "$TEMPLATE_HOOK" || \
    grep -q "source.*secrets\.env" "$TEMPLATE_HOOK"
}

@test "TAP-750: template on-stop.sh guards sourcing with token absence check" {
    grep -q '\-z.*TAPPS_BRAIN_AUTH_TOKEN' "$TEMPLATE_HOOK"
}

@test "TAP-750: secrets.env sourcing block appears before brain client source" {
    local secrets_line brain_lib_line
    secrets_line=$(grep -n "secrets\.env" "$TEMPLATE_HOOK" | head -1 | cut -d: -f1)
    brain_lib_line=$(grep -n '_brain_lib=' "$TEMPLATE_HOOK" | head -1 | cut -d: -f1)
    [[ -n "$secrets_line" && -n "$brain_lib_line" ]]
    [[ "$secrets_line" -lt "$brain_lib_line" ]]
}
