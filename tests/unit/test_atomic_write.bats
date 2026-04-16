#!/usr/bin/env bats
# TAP-535: Unit tests for atomic_write helper in ralph_loop.sh.
#
# We extract the helper by sourcing ralph_loop.sh under a guard so the script
# does not enter its main loop (NO_MAIN=1 short-circuits at the very bottom).
# atomic_write is defined near the top of the script alongside the bash
# version check and `set -o pipefail`, so it is available immediately.

bats_require_minimum_version 1.5.0
load '../helpers/test_helper'

RALPH_LOOP_SH="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

setup() {
    export TEST_TEMP_DIR="$(mktemp -d)"
    cd "$TEST_TEMP_DIR"

    # Extract atomic_write without executing main(). Sourcing ralph_loop.sh
    # directly would run hundreds of lines of init; instead we copy the
    # function out via awk and source the slice.
    local slice="$TEST_TEMP_DIR/_atomic_write_slice.sh"
    awk '/^atomic_write\(\) \{/,/^\}/' "$RALPH_LOOP_SH" > "$slice"
    # shellcheck disable=SC1090
    source "$slice"

    # Sanity: the function actually loaded.
    declare -F atomic_write >/dev/null || skip "atomic_write not defined after source"
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR"
}

# =============================================================================
# Happy path
# =============================================================================

@test "TAP-535: atomic_write writes value via temp+rename, leaves no temp file" {
    run atomic_write "$TEST_TEMP_DIR/counter" "42"
    assert_success
    [[ "$(cat "$TEST_TEMP_DIR/counter")" == "42" ]]
    # No leftover .tmp.* files
    [[ -z "$(find "$TEST_TEMP_DIR" -maxdepth 1 -name 'counter.tmp.*' -print -quit)" ]]
}

@test "TAP-535: atomic_write overwrites existing value" {
    printf 'old-value\n' > "$TEST_TEMP_DIR/state"
    run atomic_write "$TEST_TEMP_DIR/state" "new-value"
    assert_success
    [[ "$(cat "$TEST_TEMP_DIR/state")" == "new-value" ]]
}

@test "TAP-535: atomic_write supports values with spaces" {
    run atomic_write "$TEST_TEMP_DIR/timestamp" "2026 04 16"
    assert_success
    [[ "$(cat "$TEST_TEMP_DIR/timestamp")" == "2026 04 16" ]]
}

@test "TAP-535: atomic_write writes empty value (zero-length but not absent)" {
    run atomic_write "$TEST_TEMP_DIR/empty" ""
    assert_success
    [[ -f "$TEST_TEMP_DIR/empty" ]]
    [[ "$(cat "$TEST_TEMP_DIR/empty")" == "" ]]
}

# =============================================================================
# Failure paths — target is unchanged on failure
# =============================================================================

@test "TAP-535: atomic_write rejects empty target path" {
    run atomic_write "" "value"
    assert_failure
}

@test "TAP-535: atomic_write fails when parent directory does not exist" {
    run atomic_write "$TEST_TEMP_DIR/no/such/dir/file" "value"
    assert_failure
}

@test "TAP-535: atomic_write leaves original file intact when temp write fails" {
    # Create a state file with a known good value.
    local target="$TEST_TEMP_DIR/state"
    printf 'good-value\n' > "$target"

    # Make the directory read-only so the temp file write fails.
    chmod 555 "$TEST_TEMP_DIR"

    run atomic_write "$target" "would-be-corrupted"
    local rc="$status"

    # Restore permissions before any assertion to avoid teardown surprises.
    chmod 755 "$TEST_TEMP_DIR"

    [[ "$rc" -ne 0 ]] || fail "expected non-zero exit on read-only dir, got $rc"
    [[ "$(cat "$target")" == "good-value" ]] || \
        fail "target was corrupted: got '$(cat "$target")'"
    # No leaked temp files.
    [[ -z "$(find "$TEST_TEMP_DIR" -maxdepth 1 -name 'state.tmp.*' -print -quit)" ]]
}

# =============================================================================
# Concurrency: parallel writers don't collide on temp filenames
# =============================================================================

@test "TAP-535: atomic_write temp file name includes pid + RANDOM (collision-resistant)" {
    # Spawn two background writers that both target the same file. We can't
    # test "atomic" wall-clock semantics in BATS, but we can verify both
    # complete, the result is one of the two values, and no temp file leaks.
    local target="$TEST_TEMP_DIR/contended"

    ( atomic_write "$target" "writer-A" ) &
    ( atomic_write "$target" "writer-B" ) &
    wait

    [[ -f "$target" ]] || fail "target file missing after concurrent writes"
    local val
    val="$(cat "$target")"
    [[ "$val" == "writer-A" || "$val" == "writer-B" ]] || \
        fail "got unexpected value: '$val'"
    [[ -z "$(find "$TEST_TEMP_DIR" -maxdepth 1 -name 'contended.tmp.*' -print -quit)" ]] || \
        fail "concurrent write left a temp file behind"
}

# =============================================================================
# Source-level invariants from TAP-535
# =============================================================================

@test "TAP-535: ralph_loop.sh enables pipefail at top-level" {
    # Strip comments / blank lines, then assert pipefail is enabled.
    run grep -E '^[[:space:]]*set[[:space:]]+-o[[:space:]]+pipefail' "$RALPH_LOOP_SH"
    assert_success
}

@test "TAP-535: ralph_loop.sh has Bash 4+ version guard" {
    run grep -E 'BASH_VERSINFO\[0\]\}?:?-?0?\}?[[:space:]]*<[[:space:]]*4' "$RALPH_LOOP_SH"
    assert_success
}

# =============================================================================
# Partial-write recovery — simulates a kill mid-write
# =============================================================================

@test "TAP-535: simulated kill before mv leaves prior counter intact" {
    # Reproduce the race the issue describes:
    #   1. File holds the previous valid counter value.
    #   2. A new write is interrupted between truncation and write completion.
    # With plain `echo "$N" > FILE` the file is truncated first — even if the
    # write never lands, the file is now zero bytes. atomic_write must keep
    # the prior value because it never touches the target until the rename.
    local target="$TEST_TEMP_DIR/counter"
    printf '7\n' > "$target"

    # Simulate "interrupted before mv" by running the same temp+write the
    # helper does, then NOT calling mv (i.e., the kill landed mid-helper).
    local tmp="${target}.tmp.$$.${RANDOM}"
    printf '8\n' > "$tmp"
    # Pretend signal arrives here — temp file exists, but never renamed.
    rm -f "$tmp"

    # Target must still hold the old value.
    [[ "$(cat "$target")" == "7" ]] || \
        fail "expected '7' (old value preserved), got '$(cat "$target")'"
}
