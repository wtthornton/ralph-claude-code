#!/usr/bin/env bats
# TAP-2343: coordinator session recovery — error_during_execution streams
# must NOT have their session_id persisted, and a dead-session --resume
# failure must retry cold-start in the same call rather than returning
# failure for the harness to discover next loop.
#
# Background: AgentForge 2026-05-22 ran `coordinator: debrief failed (exit 1)`
# every loop after #1. The captured .coordinator-debrief.err showed the
# response was an `error_during_execution` whose own session_id was being
# captured and resumed-against on the next loop, causing the same failure
# to repeat. TAP-1900 cleared the dead id but did not retry.

bats_require_minimum_version 1.5.0

REPO_ROOT_FIXED="${BATS_TEST_DIRNAME}/../.."

setup() {
    export TEST_TEMP_DIR="$(mktemp -d "${BATS_TEST_TMPDIR:-/tmp}/coord_recovery.XXXXXX")"
    cd "$TEST_TEMP_DIR"
    mkdir -p .ralph .ralph/logs bin
    export RALPH_DIR="$TEST_TEMP_DIR/.ralph"
    export LOG_DIR="$RALPH_DIR/logs"
    export DRY_RUN=false
    unset RALPH_COORDINATOR_DISABLED || true
    unset COORDINATOR_SESSION_MAX_AGE_SECONDS || true
    export RALPH_COORDINATOR_TIMEOUT_SECONDS=0
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR" 2>/dev/null || true
}

# Source the session helpers so we can exercise the detector directly.
_source_session_lib() {
    # shellcheck disable=SC1091
    source "$REPO_ROOT_FIXED/lib/coordinator_session.sh"
}

# Build a fake `claude` binary that records its argv to .last_argv_<N>
# and emits a configurable JSONL response. Resume-then-fail behavior is
# determined by whether the argv contains `--resume`.
_install_fake_claude_two_phase() {
    local dead_sid="$1"
    cat > "$TEST_TEMP_DIR/bin/claude" <<EOF
#!/usr/bin/env bash
# Count invocations across the same test.
n_file="\$BATS_TEST_TMPDIR/coord_invoke_count"
[[ -f "\$n_file" ]] || echo 0 > "\$n_file"
n=\$(cat "\$n_file")
n=\$(( n + 1 ))
echo "\$n" > "\$n_file"

printf '%s\n' "\$@" > "$TEST_TEMP_DIR/.last_argv_\${n}"

# If --resume <dead_sid> is in argv, emit an error_during_execution
# response whose own session_id is a NEW UUID. The harness must NOT
# capture it — that's the bug TAP-2343 fixes.
if printf '%s\n' "\$@" | grep -q '^--resume\$' && \
   printf '%s\n' "\$@" | grep -q '^$dead_sid\$'; then
    cat <<'JSON'
{"type":"system","subtype":"init","session_id":"$dead_sid"}
{"type":"result","subtype":"error_during_execution","is_error":true,"session_id":"error-response-sid-9999","errors":["No conversation found with session ID: $dead_sid"]}
JSON
    exit 1
fi

# Otherwise (cold start / different resume id) emit a clean success
# with a brand-new session id.
echo '{"type":"system","subtype":"init","session_id":"recovered-sid-7777"}'
echo '{"type":"result","session_id":"recovered-sid-7777","success":true}'
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/claude"
    export CLAUDE_CODE_CMD="$TEST_TEMP_DIR/bin/claude"
}

# -- error_stream detector -------------------------------------------------

@test "TAP-2343: stream_is_error_response detects error_during_execution subtype" {
    _source_session_lib
    local s="$TEST_TEMP_DIR/err.jsonl"
    cat > "$s" <<'EOF'
{"type":"system","subtype":"init","session_id":"abc"}
{"type":"result","subtype":"error_during_execution","is_error":true,"session_id":"xyz","errors":["No conversation found with session ID: abc"]}
EOF
    coordinator_session_stream_is_error_response "$s" \
        || fail "expected error response to be detected"
}

@test "TAP-2343: stream_is_error_response detects bare is_error:true on result" {
    _source_session_lib
    local s="$TEST_TEMP_DIR/err2.jsonl"
    echo '{"type":"result","is_error":true,"session_id":"foo"}' > "$s"
    coordinator_session_stream_is_error_response "$s" \
        || fail "expected is_error result to be detected"
}

@test "TAP-2343: stream_is_error_response returns 1 on clean success stream" {
    _source_session_lib
    local s="$TEST_TEMP_DIR/ok.jsonl"
    cat > "$s" <<'EOF'
{"type":"system","subtype":"init","session_id":"abc"}
{"type":"result","session_id":"abc","success":true}
EOF
    run coordinator_session_stream_is_error_response "$s"
    [[ "$status" -eq 1 ]] || fail "expected non-error to be reported, got status=$status"
}

@test "TAP-2343: stream_is_error_response returns 1 on missing stream" {
    _source_session_lib
    run coordinator_session_stream_is_error_response "/nonexistent/path"
    [[ "$status" -eq 1 ]] || fail "expected non-error for missing stream, got status=$status"
}

# -- end-to-end recovery path ----------------------------------------------

@test "TAP-2343: cold-start debrief succeeds (no prior session file)" {
    set --
    # shellcheck disable=SC1090
    source "$REPO_ROOT_FIXED/ralph_loop.sh"
    coordinator_session_clear

    # Simple fake claude that always returns success.
    cat > "$TEST_TEMP_DIR/bin/claude" <<EOF
#!/usr/bin/env bash
echo '{"type":"system","subtype":"init","session_id":"fresh-sid-0001"}'
echo '{"type":"result","session_id":"fresh-sid-0001","success":true}'
exit 0
EOF
    chmod +x "$TEST_TEMP_DIR/bin/claude"
    export CLAUDE_CODE_CMD="$TEST_TEMP_DIR/bin/claude"

    run ralph_coordinator_invoke debrief "OUTCOME=success"
    [[ "$status" -eq 0 ]] || fail "expected zero exit on cold-start debrief, got $status — output: $output"
    local sid
    sid=$(coordinator_session_read)
    [[ "$sid" == "fresh-sid-0001" ]] \
        || fail "expected captured session_id from cold-start, got: '$sid'"
}

@test "TAP-2343: dead session id triggers cold-start retry in same call (debrief succeeds)" {
    set --
    # shellcheck disable=SC1090
    source "$REPO_ROOT_FIXED/ralph_loop.sh"

    # Seed a stored session id that the fake claude will treat as dead.
    coordinator_session_write "dead-sid-1234"
    _install_fake_claude_two_phase "dead-sid-1234"

    run ralph_coordinator_invoke debrief "OUTCOME=success"
    [[ "$status" -eq 0 ]] \
        || fail "expected zero exit after cold-start retry, got $status — output: $output"

    # The fake records each invocation. Two argv files must exist.
    [[ -f "$TEST_TEMP_DIR/.last_argv_1" ]] || fail "first invocation was not recorded"
    [[ -f "$TEST_TEMP_DIR/.last_argv_2" ]] || fail "retry was not invoked — only one call recorded"

    grep -q '^--resume$' "$TEST_TEMP_DIR/.last_argv_1" \
        || fail "first call should have carried --resume — argv:\n$(cat "$TEST_TEMP_DIR/.last_argv_1")"
    if grep -q '^--resume$' "$TEST_TEMP_DIR/.last_argv_2"; then
        fail "retry must NOT carry --resume (cold-start) — argv:\n$(cat "$TEST_TEMP_DIR/.last_argv_2")"
    fi

    local sid
    sid=$(coordinator_session_read)
    [[ "$sid" == "recovered-sid-7777" ]] \
        || fail "expected recovered-sid-7777 after cold-start retry, got: '$sid'"
}

@test "TAP-2343: error_during_execution session_id is NOT persisted (single call)" {
    set --
    # shellcheck disable=SC1090
    source "$REPO_ROOT_FIXED/ralph_loop.sh"
    coordinator_session_clear

    # Fake claude that returns an error_during_execution response carrying
    # its own (fresh) session_id — but no "No conversation found" so the
    # cold-start-retry branch does NOT fire.
    cat > "$TEST_TEMP_DIR/bin/claude" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
{"type":"system","subtype":"init","session_id":"abc-1234"}
{"type":"result","subtype":"error_during_execution","is_error":true,"session_id":"poisoned-sid-2222","errors":["Some other error"]}
JSON
exit 1
EOF
    chmod +x "$TEST_TEMP_DIR/bin/claude"
    export CLAUDE_CODE_CMD="$TEST_TEMP_DIR/bin/claude"

    ralph_coordinator_invoke debrief "OUTCOME=failure" || true

    local sid
    sid=$(coordinator_session_read)
    [[ -z "$sid" ]] \
        || fail "error_during_execution session_id must NOT be persisted, got: '$sid'"
}

@test "TAP-2343: successful response after retry persists the NEW session id (not the dead one)" {
    set --
    # shellcheck disable=SC1090
    source "$REPO_ROOT_FIXED/ralph_loop.sh"

    coordinator_session_write "dead-sid-1234"
    _install_fake_claude_two_phase "dead-sid-1234"

    ralph_coordinator_invoke brief "MODE=brief
content" || true

    local sid
    sid=$(coordinator_session_read)
    [[ "$sid" == "recovered-sid-7777" ]] \
        || fail "expected recovered session id, got: '$sid'"
    # Confirm the dead id was NOT re-captured from the error response.
    [[ "$sid" != "error-response-sid-9999" ]] \
        || fail "error response session_id was leaked into the session file"
}
