#!/usr/bin/env bats
# Unit tests for ralph.ps1 (PowerShell wrapper).
#
# We can't run PowerShell in CI without an interpreter, but we *can* assert
# the source never regresses to the `bash -c "$argString"` pattern that
# TAP-641 fixed — command injection via interpolated argv.

load '../helpers/test_helper'

PROJECT_ROOT="${BATS_TEST_DIRNAME}/../.."
PS1="${PROJECT_ROOT}/ralph.ps1"

@test "TAP-641: ralph.ps1 exists" {
    [[ -f "$PS1" ]]
}

@test "TAP-641: ralph.ps1 does not call bash -c with an interpolated arg string" {
    # Pre-fix, the script built `$argString` by joining RalphArgs and
    # passed it via `bash -c "$script $argString"`. That path must be gone
    # — we rely on PowerShell argv splatting (@SafeArgs) instead.
    run grep -nE 'bash -c "\$[a-zA-Z_]+ \$argString"' "$PS1"
    [[ "$status" -ne 0 ]]
}

@test "TAP-641: ralph.ps1 uses @-splatting for user args" {
    # Must pass args via PowerShell splat so each is its own argv token.
    run grep -q '@SafeArgs' "$PS1"
    assert_success
}

@test "TAP-641: ralph.ps1 defines \$SafeArgs as an array from RalphArgs" {
    run grep -q '\$SafeArgs = @()' "$PS1"
    assert_success
    run grep -q '\$SafeArgs = @(\$RalphArgs)' "$PS1"
    assert_success
}

@test "TAP-641: ralph.ps1 no longer builds a joined \$argString" {
    # The vulnerable join-with-quotes pattern must be removed.
    run grep -nE '\$argString = \(\$RalphArgs' "$PS1"
    [[ "$status" -ne 0 ]]
}
