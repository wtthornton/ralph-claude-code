#!/usr/bin/env bats
# TAP-2485: _coordinator_record_outcome — write the .coordinator-${mode}.err
# marker on failure, clear it on success. Same colocation principle as
# _ralph_push_{log_failure,clear_failure_marker}: the agent can't rm under
# .ralph/ (validate-command.sh blanket-blocks it, intentional per TAP-2344)
# and the protect-hook allowlist stays narrow, so the writer is the only
# place a stale marker can be cleared.
#
# Pre-TAP-2485 the failure write was the ONLY thing the function did —
# stranded markers from old failures survived every subsequent success,
# making the working tree look like the coordinator was perpetually broken.

bats_require_minimum_version 1.5.0

REPO_ROOT="${BATS_TEST_DIRNAME}/../.."

setup() {
    export TEST_DIR="$(mktemp -d "${BATS_TEST_TMPDIR:-/tmp}/coord_outcome.XXXXXX")"
    cd "$TEST_DIR"
    mkdir -p .ralph
    export RALPH_DIR="$TEST_DIR/.ralph"

    # Extract just the helper body — no need to source the whole loop script.
    eval "$(awk '/^_coordinator_record_outcome\(\) \{$/,/^\}$/' "$REPO_ROOT/ralph_loop.sh")"
}

teardown() {
    cd /
    rm -rf "$TEST_DIR" 2>/dev/null || true
    unset RALPH_DIR
}

# Make a synthetic stream-file with some payload so failure-write has content.
_make_stream() {
    local _path="$1"
    printf 'first line\nsecond line\nERROR: synthetic failure\n' > "$_path"
}

# ---- failure path — writes marker -----------------------------------------

@test "TAP-2485: failure rc=1 with non-empty stream → marker written" {
    local _stream="$TEST_DIR/stream.txt"
    _make_stream "$_stream"

    _coordinator_record_outcome 1 "brief" "$_stream" 120 130

    local _err="$RALPH_DIR/.coordinator-brief.err"
    [[ -s "$_err" ]] || fail "expected marker to be written on failure"
    grep -q "coordinator brief failed (exit 1)" "$_err" \
        || fail "missing failure header in marker"
    grep -q "ERROR: synthetic failure" "$_err" \
        || fail "stream tail not captured in marker"
}

@test "TAP-2485: failure rc=124 (timeout) → marker carries duration" {
    local _stream="$TEST_DIR/stream.txt"
    _make_stream "$_stream"

    _coordinator_record_outcome 124 "brief" "$_stream" 126 127

    local _err="$RALPH_DIR/.coordinator-brief.err"
    grep -q "timeout=126s duration=127s" "$_err" \
        || fail "marker should record timeout + duration"
}

@test "TAP-2485: failure with empty/missing stream → no marker (existing behavior preserved)" {
    # If the stream file is empty or missing, there's nothing useful to log
    # and we don't synthesize a header — same as pre-TAP-2485 behavior.
    _coordinator_record_outcome 1 "brief" "$TEST_DIR/nonexistent" 120 5

    [[ ! -e "$RALPH_DIR/.coordinator-brief.err" ]] \
        || fail "must not write marker when stream is empty/missing"
}

# ---- success path — TAP-2485 clear --------------------------------------

@test "TAP-2485: success rc=0 with stale marker present → marker cleared" {
    # Seed a stranded marker (the bug scenario this story fixes)
    printf '[2026-05-22T23:52:25Z] coordinator brief failed (exit 124)\nstale tail\n' \
        > "$RALPH_DIR/.coordinator-brief.err"
    [[ -s "$RALPH_DIR/.coordinator-brief.err" ]] || fail "test setup: marker should exist"

    # Successful invocation should clear it
    _coordinator_record_outcome 0 "brief" "$TEST_DIR/anything" 120 8

    [[ ! -e "$RALPH_DIR/.coordinator-brief.err" ]] \
        || fail "stale marker must be cleared on success (got: $(cat "$RALPH_DIR/.coordinator-brief.err" 2>/dev/null))"
}

@test "TAP-2485: success with no prior marker → no-op (idempotent)" {
    _coordinator_record_outcome 0 "brief" "" 120 5

    [[ ! -e "$RALPH_DIR/.coordinator-brief.err" ]] \
        || fail "success with no prior marker must remain absent"
    # Function should return 0 even with empty stream arg
}

@test "TAP-2485: success clears the mode-specific marker only" {
    # Seed two stale markers — brief and debrief
    printf 'stale brief\n' > "$RALPH_DIR/.coordinator-brief.err"
    printf 'stale debrief\n' > "$RALPH_DIR/.coordinator-debrief.err"

    # Successful brief invocation should clear ONLY the brief marker
    _coordinator_record_outcome 0 "brief" "" 120 5

    [[ ! -e "$RALPH_DIR/.coordinator-brief.err" ]] \
        || fail "brief marker should be cleared"
    [[ -s "$RALPH_DIR/.coordinator-debrief.err" ]] \
        || fail "debrief marker must NOT be touched by a brief success"
}

# ---- all three modes get the right marker name ----------------------------

@test "TAP-2485: debrief mode writes .coordinator-debrief.err" {
    local _stream="$TEST_DIR/stream.txt"
    _make_stream "$_stream"
    _coordinator_record_outcome 1 "debrief" "$_stream" 120 8
    [[ -s "$RALPH_DIR/.coordinator-debrief.err" ]] || fail "debrief marker missing"
    grep -q "coordinator debrief failed" "$RALPH_DIR/.coordinator-debrief.err" \
        || fail "header should name the mode"
}

@test "TAP-2485: consult mode writes .coordinator-consult.err" {
    local _stream="$TEST_DIR/stream.txt"
    _make_stream "$_stream"
    _coordinator_record_outcome 1 "consult" "$_stream" 60 5
    [[ -s "$RALPH_DIR/.coordinator-consult.err" ]] || fail "consult marker missing"
    grep -q "coordinator consult failed" "$RALPH_DIR/.coordinator-consult.err" \
        || fail "header should name the mode"
}

# ---- regression guards ----------------------------------------------------

@test "TAP-2485: no allowlist widening — hook still blocks .coordinator-*.err writes" {
    # The whole point of the loop-side clear is to keep the agent edit
    # surface narrow. If a future change adds .coordinator-*.err to the
    # protect-hook allowlist, this test fires.
    local hook="$REPO_ROOT/templates/hooks/protect-ralph-files.sh"
    # Allow the existing comment that REFERENCES tapps-mcp/.ralph/.coordinator-brief.err
    # as evidence — but no actual allowlist case-pattern for these markers.
    ! grep -qE '"\$RALPH_DIR"/\.coordinator-.*\.err|\.ralph/\.coordinator-.*\.err\)' "$hook" \
        || fail "protect-ralph-files.sh must NOT carve out coordinator-*.err markers (TAP-2485: clear is loop-side)"

    local vhook="$REPO_ROOT/templates/hooks/validate-command.sh"
    ! grep -qE 'coordinator-.*\.err' "$vhook" \
        || fail "validate-command.sh must NOT carve out coordinator-*.err markers (TAP-2485: clear is loop-side)"
}
