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
