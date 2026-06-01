#!/usr/bin/env bats
# TAP-2497: MCP health injection into the prompt + on-stop recognition of
# mcp_unreachable so the agent doesn't improvise EXIT_SIGNAL when the
# transport is degraded.
#
# Three behavior contracts:
#   1. on-stop.sh recognizes STATUS: BLOCKED + RECOMMENDATION mentioning
#      "mcp_unreachable" → increments .mcp_blocked_count, does NOT count
#      as no-progress.
#   2. After RALPH_MCP_BLOCKED_QUORUM (default 3) consecutive
#      mcp_unreachable, the hook writes .harness_halt_reason=
#      mcp_unreachable_quorum.
#   3. A productive (non-mcp_unreachable) loop CLEARS the counter so
#      transient outages don't accumulate across recovered loops.

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
    # Pre-seed a healthy CB state
    printf '%s\n' '{"state":"CLOSED","consecutive_no_progress":0,"consecutive_permission_denials":0,"total_opens":0}' \
        > "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state"
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR"
}

# Helper: synthesize a mcp_unreachable response and feed to on-stop.sh
_emit_mcp_unreachable_response() {
    local _body="Linear MCP disconnected — cannot pick task.

---RALPH_STATUS---
STATUS: BLOCKED
TASKS_COMPLETED_THIS_LOOP: 0
FILES_MODIFIED: 0
WORK_TYPE: IMPLEMENTATION
EXIT_SIGNAL: false
RECOMMENDATION: mcp_unreachable — Linear plugin disconnected, will retry next loop
---END_RALPH_STATUS---"
    local _input
    _input=$(jq -Rs '{result: .}' <<<"$_body")
    printf '%s' "$_input" | bash "$HOOK"
}

# Helper: synthesize a productive (files_modified > 0) response
_emit_productive_response() {
    local _body="Made changes.

---RALPH_STATUS---
STATUS: COMPLETE
TASKS_COMPLETED_THIS_LOOP: 1
FILES_MODIFIED: 1
WORK_TYPE: IMPLEMENTATION
EXIT_SIGNAL: false
RECOMMENDATION: shipped TAP-XXXX
---END_RALPH_STATUS---"
    local _input
    _input=$(jq -Rs '{result: .}' <<<"$_body")
    printf '%s' "$_input" | bash "$HOOK"
}

# =============================================================================
# 1. mcp_unreachable response increments .mcp_blocked_count
# =============================================================================
@test "TAP-2497: mcp_unreachable response increments .mcp_blocked_count to 1" {
    _emit_mcp_unreachable_response
    [[ -f "$TEST_TEMP_DIR/.ralph/.mcp_blocked_count" ]] || { echo "counter file missing"; return 1; }
    local _count
    read -r _count < "$TEST_TEMP_DIR/.ralph/.mcp_blocked_count"
    [[ "$_count" == "1" ]] || { echo "expected 1, got $_count"; return 1; }
}

# =============================================================================
# 2. mcp_unreachable does NOT increment consecutive_no_progress
# =============================================================================
@test "TAP-2497: mcp_unreachable does NOT increment consecutive_no_progress" {
    _emit_mcp_unreachable_response
    local _np
    _np=$(jq -r '.consecutive_no_progress' "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state")
    [[ "$_np" == "0" ]] || { echo "expected 0, got $_np"; return 1; }
}

# =============================================================================
# 3. Three consecutive mcp_unreachable → quorum sentinel written
# =============================================================================
@test "TAP-2497: 3 consecutive mcp_unreachable → mcp_unreachable_quorum halt sentinel" {
    _emit_mcp_unreachable_response
    _emit_mcp_unreachable_response
    _emit_mcp_unreachable_response
    [[ -f "$TEST_TEMP_DIR/.ralph/.harness_halt_reason" ]] || { echo "halt sentinel missing"; return 1; }
    local _reason
    _reason=$(cat "$TEST_TEMP_DIR/.ralph/.harness_halt_reason")
    [[ "$_reason" == "mcp_unreachable_quorum" ]] || { echo "expected mcp_unreachable_quorum, got $_reason"; return 1; }
}

# =============================================================================
# 4. Productive loop after mcp_unreachable resets the counter
# =============================================================================
@test "TAP-2497: productive loop after 2 mcp_unreachable resets counter" {
    _emit_mcp_unreachable_response
    _emit_mcp_unreachable_response
    local _count
    read -r _count < "$TEST_TEMP_DIR/.ralph/.mcp_blocked_count"
    [[ "$_count" == "2" ]]
    _emit_productive_response
    [[ ! -f "$TEST_TEMP_DIR/.ralph/.mcp_blocked_count" ]] || { echo "counter file should be removed after productive loop"; return 1; }
}

# =============================================================================
# 5. Configurable quorum threshold via RALPH_MCP_BLOCKED_QUORUM
# =============================================================================
@test "TAP-2497: RALPH_MCP_BLOCKED_QUORUM=5 → 3 unreachables below threshold" {
    export RALPH_MCP_BLOCKED_QUORUM=5
    _emit_mcp_unreachable_response
    _emit_mcp_unreachable_response
    _emit_mcp_unreachable_response
    # Counter should be 3, but no halt sentinel (3 < 5)
    local _count
    read -r _count < "$TEST_TEMP_DIR/.ralph/.mcp_blocked_count"
    [[ "$_count" == "3" ]]
    [[ ! -f "$TEST_TEMP_DIR/.ralph/.harness_halt_reason" ]] || { echo "halt sentinel should be absent"; return 1; }
}

# =============================================================================
# 6. BLOCKED without mcp_unreachable keyword does NOT trigger the branch
# =============================================================================
@test "TAP-2497: BLOCKED without mcp_unreachable in RECOMMENDATION is regular no-progress" {
    local _body="All issues blocked.

---RALPH_STATUS---
STATUS: BLOCKED
TASKS_COMPLETED_THIS_LOOP: 0
FILES_MODIFIED: 0
WORK_TYPE: IMPLEMENTATION
EXIT_SIGNAL: false
RECOMMENDATION: every issue has blocked:waiting-for-credentials, no work possible
---END_RALPH_STATUS---"
    local _input
    _input=$(jq -Rs '{result: .}' <<<"$_body")
    printf '%s' "$_input" | bash "$HOOK"
    # No mcp counter file (different branch fired)
    [[ ! -f "$TEST_TEMP_DIR/.ralph/.mcp_blocked_count" ]] || { echo "mcp counter should not exist for non-mcp BLOCKED"; return 1; }
}

# =============================================================================
# MCP-DISCONNECT (2026-06-01): free-text disconnect summary (the agent does NOT
# emit RECOMMENDATION: mcp_unreachable) must still be recognized as a disconnect.
# This is the observed bug — the disconnect-exempt path.
# =============================================================================

# Helper: synthesize an all-MCP-disconnected response WITHOUT the canonical
# mcp_unreachable recommendation keyword — the disconnect is only in free text.
_emit_mcp_disconnect_freetext() {
    local _body="All MCP servers disconnected at loop start (tapps-mcp, docs-mcp, linear, brain). Cannot session_start, cannot read Linear, cannot run the quality gate. Harness should restart the Claude Code session to allow reconnect.

---RALPH_STATUS---
STATUS: BLOCKED
TASKS_COMPLETED_THIS_LOOP: 0
FILES_MODIFIED: 0
WORK_TYPE: IMPLEMENTATION
EXIT_SIGNAL: false
RECOMMENDATION: restart session to allow MCP servers to reconnect
---END_RALPH_STATUS---"
    local _input
    _input=$(jq -Rs '{result: .}' <<<"$_body")
    printf '%s' "$_input" | bash "$HOOK"
}

@test "MCP-DISCONNECT: free-text disconnect (no mcp_unreachable keyword) sets status.json mcp_disconnect=true" {
    _emit_mcp_disconnect_freetext
    local _md
    _md=$(jq -r '.mcp_disconnect' "$TEST_TEMP_DIR/.ralph/status.json")
    [[ "$_md" == "true" ]] || { echo "expected mcp_disconnect=true, got $_md"; return 1; }
}

@test "MCP-DISCONNECT: free-text disconnect increments .mcp_blocked_count (treated as disconnect)" {
    _emit_mcp_disconnect_freetext
    [[ -f "$TEST_TEMP_DIR/.ralph/.mcp_blocked_count" ]] || { echo "counter file missing"; return 1; }
    local _count
    read -r _count < "$TEST_TEMP_DIR/.ralph/.mcp_blocked_count"
    [[ "$_count" == "1" ]] || { echo "expected 1, got $_count"; return 1; }
}

@test "MCP-DISCONNECT: free-text disconnect does NOT increment consecutive_no_progress" {
    _emit_mcp_disconnect_freetext
    local _np
    _np=$(jq -r '.consecutive_no_progress' "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state")
    [[ "$_np" == "0" ]] || { echo "expected 0, got $_np"; return 1; }
}

# =============================================================================
# MCP-DISCONNECT: a genuine no-progress loop (MCP healthy, no disconnect text)
# still counts. The disconnect exemption must not leak onto ordinary stalls.
# =============================================================================
@test "MCP-DISCONNECT: genuine no-progress loop DOES increment consecutive_no_progress" {
    local _body="Investigated TAP-9001 but could not find a reproduction. No code changed.

---RALPH_STATUS---
STATUS: IN_PROGRESS
TASKS_COMPLETED_THIS_LOOP: 0
FILES_MODIFIED: 0
WORK_TYPE: IMPLEMENTATION
EXIT_SIGNAL: false
RECOMMENDATION: keep digging next loop
---END_RALPH_STATUS---"
    local _input
    _input=$(jq -Rs '{result: .}' <<<"$_body")
    printf '%s' "$_input" | bash "$HOOK"
    local _np _md
    _np=$(jq -r '.consecutive_no_progress' "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state")
    _md=$(jq -r '.mcp_disconnect' "$TEST_TEMP_DIR/.ralph/status.json")
    [[ "$_np" == "1" ]] || { echo "expected consecutive_no_progress=1, got $_np"; return 1; }
    [[ "$_md" == "false" ]] || { echo "expected mcp_disconnect=false, got $_md"; return 1; }
    [[ ! -f "$TEST_TEMP_DIR/.ralph/.mcp_blocked_count" ]] || { echo "mcp counter should not exist for genuine no-progress"; return 1; }
}

# =============================================================================
# MCP-DISCONNECT: RALPH_MCP_RETRY_MAX governs the give-up threshold and takes
# precedence over the legacy RALPH_MCP_BLOCKED_QUORUM alias.
# =============================================================================
@test "MCP-DISCONNECT: RALPH_MCP_RETRY_MAX=2 → 2 disconnects write the give-up halt sentinel" {
    export RALPH_MCP_RETRY_MAX=2
    _emit_mcp_disconnect_freetext
    [[ ! -f "$TEST_TEMP_DIR/.ralph/.harness_halt_reason" ]] || { echo "halt sentinel should be absent after 1"; return 1; }
    _emit_mcp_disconnect_freetext
    [[ -f "$TEST_TEMP_DIR/.ralph/.harness_halt_reason" ]] || { echo "halt sentinel missing after 2"; return 1; }
    local _reason
    _reason=$(cat "$TEST_TEMP_DIR/.ralph/.harness_halt_reason")
    [[ "$_reason" == "mcp_unreachable_quorum" ]] || { echo "expected mcp_unreachable_quorum, got $_reason"; return 1; }
}

@test "MCP-DISCONNECT: RALPH_MCP_RETRY_MAX overrides legacy RALPH_MCP_BLOCKED_QUORUM" {
    export RALPH_MCP_RETRY_MAX=5
    export RALPH_MCP_BLOCKED_QUORUM=2
    _emit_mcp_disconnect_freetext
    _emit_mcp_disconnect_freetext
    _emit_mcp_disconnect_freetext
    # 3 disconnects, RETRY_MAX=5 wins over BLOCKED_QUORUM=2 → no halt yet
    local _count
    read -r _count < "$TEST_TEMP_DIR/.ralph/.mcp_blocked_count"
    [[ "$_count" == "3" ]] || { echo "expected 3, got $_count"; return 1; }
    [[ ! -f "$TEST_TEMP_DIR/.ralph/.harness_halt_reason" ]] || { echo "halt sentinel should be absent (3 < 5)"; return 1; }
}

# =============================================================================
# MCP-DISCONNECT: a clean exit (EXIT_SIGNAL: true) is never misread as a
# disconnect even if 0 files / 0 tasks and MCP prose is present.
# =============================================================================
@test "MCP-DISCONNECT: EXIT_SIGNAL true with 0/0 is not a disconnect" {
    local _body="Backlog confirmed empty. MCP servers all connected, nothing left to do.

---RALPH_STATUS---
STATUS: COMPLETE
TASKS_COMPLETED_THIS_LOOP: 0
FILES_MODIFIED: 0
WORK_TYPE: IMPLEMENTATION
EXIT_SIGNAL: true
RECOMMENDATION: all done
---END_RALPH_STATUS---"
    local _input
    _input=$(jq -Rs '{result: .}' <<<"$_body")
    printf '%s' "$_input" | bash "$HOOK"
    local _md
    _md=$(jq -r '.mcp_disconnect' "$TEST_TEMP_DIR/.ralph/status.json")
    [[ "$_md" == "false" ]] || { echo "expected mcp_disconnect=false for clean exit, got $_md"; return 1; }
    [[ ! -f "$TEST_TEMP_DIR/.ralph/.mcp_blocked_count" ]] || { echo "mcp counter should not exist for clean exit"; return 1; }
}
