#!/usr/bin/env bats
# TAP-649: CI workflows must not regress on two known-bad patterns.
#
#   1. `|| true` that masks a real test failure
#   2. `grep -c … || echo "0"` double-zero pitfall (grep -c exits 1 with
#      stdout "0" when there's no match, so `|| echo "0"` emits "0\n0" —
#      two lines — and crashes subsequent arithmetic)

load '../helpers/test_helper'

PROJECT_ROOT="${BATS_TEST_DIRNAME}/../.."

@test "TAP-649: no workflow masks npm test failure with || true" {
    run grep -rn 'npm test .*|| true' "$PROJECT_ROOT/.github/workflows/"
    [[ "$status" -ne 0 ]]
}

@test "TAP-649: no workflow uses 'grep -c ... || echo \"0\"' pitfall" {
    run grep -rnE 'grep -c[^|]*\|\| echo *"0"' "$PROJECT_ROOT/.github/workflows/"
    [[ "$status" -ne 0 ]]
}

@test "TAP-649: update-badges.yml fails when npm test fails (guard present)" {
    run grep -q 'Test suite failed' "$PROJECT_ROOT/.github/workflows/update-badges.yml"
    assert_success
}

@test "TAP-649: update-badges.yml sanitizes grep -c output via tr -cd '0-9'" {
    run grep -q "tr -cd '0-9'" "$PROJECT_ROOT/.github/workflows/update-badges.yml"
    assert_success
}
