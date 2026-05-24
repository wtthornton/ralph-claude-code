#!/usr/bin/env bats
# TAP-2501: idle-tick cache hygiene — thin idle ticks must not mutate
# prompt-cache-relevant files (.last_completed_files, .linear_next_issue,
# .brief_cache/*.json) so the prefix stays stable across thin ticks.
#
# AgentForge accumulated 2.05B cache_read_tokens over 111 loops largely
# because every idle tick subtly perturbed the next loop's prompt prefix
# → cache miss cascade. Each loop wrote .last_completed_files (empty),
# which busted the cache for the next loop.

bats_require_minimum_version 1.5.0
load '../helpers/test_helper'

REPO_ROOT="${BATS_TEST_DIRNAME}/../.."
HOOK="${REPO_ROOT}/templates/hooks/on-stop.sh"

setup() {
    export TEST_TEMP_DIR="$(mktemp -d)"
    cd "$TEST_TEMP_DIR"
    export CLAUDE_PROJECT_DIR="$TEST_TEMP_DIR"
    export RALPH_LOOP_ACTIVE=1
    mkdir -p "$TEST_TEMP_DIR/.ralph"
    echo "test-run-$$" > "$TEST_TEMP_DIR/.ralph/.ralph_run_id"
    printf '%s\n' '{"state":"CLOSED","consecutive_no_progress":0,"consecutive_permission_denials":0,"total_opens":0}' \
        > "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state"
    # Pre-seed .last_completed_files with a known authoritative state
    cat > "$TEST_TEMP_DIR/.ralph/.last_completed_files" <<'EOF'
src/auth.py
src/router.py
tests/test_auth.py
EOF
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR"
}

# Helper: synthesize an IDLE_TICK response and feed to on-stop.sh
_emit_idle_tick_response() {
    local _body="Harness-synthesized idle tick — backlog empty.

---RALPH_STATUS---
STATUS: COMPLETE
TASKS_COMPLETED_THIS_LOOP: 0
FILES_MODIFIED: 0
WORK_TYPE: IDLE_TICK
EXIT_SIGNAL: true
RECOMMENDATION: harness-emitted idle tick (loop 1)
---END_RALPH_STATUS---"
    local _input
    _input=$(jq -Rs '{result: .}' <<<"$_body")
    printf '%s' "$_input" | bash "$HOOK"
}

# =============================================================================
# 1. IDLE_TICK does NOT rewrite .last_completed_files
# =============================================================================
@test "TAP-2501: IDLE_TICK preserves .last_completed_files contents" {
    local _orig_md5
    _orig_md5=$(md5sum "$TEST_TEMP_DIR/.ralph/.last_completed_files" | awk '{print $1}')
    _emit_idle_tick_response
    local _new_md5
    _new_md5=$(md5sum "$TEST_TEMP_DIR/.ralph/.last_completed_files" | awk '{print $1}')
    [[ "$_orig_md5" == "$_new_md5" ]] || { echo "expected same md5; before=$_orig_md5 after=$_new_md5"; return 1; }
}

# =============================================================================
# 2. IDLE_TICK does NOT touch .linear_next_issue
# =============================================================================
@test "TAP-2501: IDLE_TICK preserves .linear_next_issue when present" {
    echo "TAP-9999" > "$TEST_TEMP_DIR/.ralph/.linear_next_issue"
    _emit_idle_tick_response
    [[ -f "$TEST_TEMP_DIR/.ralph/.linear_next_issue" ]] || { echo ".linear_next_issue deleted"; return 1; }
    local _v
    _v=$(cat "$TEST_TEMP_DIR/.ralph/.linear_next_issue")
    [[ "$_v" == "TAP-9999" ]] || { echo "expected TAP-9999, got $_v"; return 1; }
}

# =============================================================================
# 3. Non-IDLE_TICK loop with no transcript still updates .last_completed_files
#    (writes empty file — the existing behavior on no-transcript loops)
# =============================================================================
@test "TAP-2501: non-IDLE_TICK loop still mutates .last_completed_files (no regression)" {
    local _body="Made a real change.

---RALPH_STATUS---
STATUS: IN_PROGRESS
TASKS_COMPLETED_THIS_LOOP: 0
FILES_MODIFIED: 1
WORK_TYPE: IMPLEMENTATION
EXIT_SIGNAL: false
RECOMMENDATION: shipped a fix
---END_RALPH_STATUS---"
    local _input
    _input=$(jq -Rs '{result: .}' <<<"$_body")
    local _orig_md5
    _orig_md5=$(md5sum "$TEST_TEMP_DIR/.ralph/.last_completed_files" | awk '{print $1}')
    printf '%s' "$_input" | bash "$HOOK"
    local _new_md5
    _new_md5=$(md5sum "$TEST_TEMP_DIR/.ralph/.last_completed_files" | awk '{print $1}')
    # Without transcript, the hook writes an empty file → md5 changes
    [[ "$_orig_md5" != "$_new_md5" ]] || { echo "expected md5 change on real loop; before=$_orig_md5 after=$_new_md5"; return 1; }
}
