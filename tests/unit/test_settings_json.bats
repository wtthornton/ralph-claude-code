#!/usr/bin/env bats
# TAP-656: Validate .claude/settings.json hook entries are well-formed

load '../helpers/test_helper'

PROJECT_ROOT="${BATS_TEST_DIRNAME}/../.."
SETTINGS="${PROJECT_ROOT}/.claude/settings.json"

@test "settings.json parses as valid JSON" {
    run jq . "$SETTINGS"
    assert_success
}

@test "all hook matchers are valid regex strings (no trailing backslash)" {
    # grep exits 1 when nothing matches — that's the good case (no corrupt matchers)
    run bash -c "jq -r '.. | objects | .matcher? // empty' \"$SETTINGS\" | grep -E '\\\\\$'"
    assert_failure
}

@test "all hook commands start with 'bash ' or a known binary (not a tool name like Write/Edit)" {
    bad=$(jq -r '.. | objects | .command? // empty' "$SETTINGS" \
        | grep -Ev '^(bash |npx |node |python |sh )' \
        | grep -Ev '^$' || true)
    [ -z "$bad" ] || fail "Unexpected command values: $bad"
}

@test "no statusMessage contains a pipe separator (smell for scrambled fields)" {
    # grep exits 1 when nothing matches — that's the good case (no scrambled statusMessages)
    run bash -c "jq -r '.. | objects | .statusMessage? // empty' \"$SETTINGS\" | grep '|'"
    assert_failure
}

@test "PreToolUse has exactly two entries (Bash and Edit|Write)" {
    count=$(jq '[.hooks.PreToolUse[].matcher] | length' "$SETTINGS")
    [ "$count" -eq 2 ] || fail "Expected 2 PreToolUse entries, got $count"
}

@test "StopFailure has exactly one entry (rate_limit|server_error)" {
    count=$(jq '[.hooks.StopFailure[].matcher] | length' "$SETTINGS")
    [ "$count" -eq 1 ] || fail "Expected 1 StopFailure entry, got $count"
}
