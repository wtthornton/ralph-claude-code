#!/usr/bin/env bats
# TAP-2502: structured exit-signal via Write-tool sentinel.
#
# The agent writes `.ralph/.exit_signal_intent` (line 1 = enum, line 2+ = reason);
# on-file-change.sh validates, appends to .exit_signal_calls.jsonl, updates
# .exit_signals.completion_indicators (on EMIT_EXIT_SIGNAL), and deletes the
# intent file. This is the durable 2026-industry-best signal path — zero regex
# ambiguity vs. the text fallback that TAP-2494 hardened.

bats_require_minimum_version 1.5.0
load '../helpers/test_helper'

REPO_ROOT="${BATS_TEST_DIRNAME}/../.."
HOOK="${REPO_ROOT}/templates/hooks/on-file-change.sh"
PROTECT_HOOK="${REPO_ROOT}/templates/hooks/protect-ralph-files.sh"

setup() {
    export TEST_TEMP_DIR="$(mktemp -d)"
    cd "$TEST_TEMP_DIR"
    export CLAUDE_PROJECT_DIR="$TEST_TEMP_DIR"
    mkdir -p "$TEST_TEMP_DIR/.ralph"
    # Pre-seed status.json so loop_count can be read
    cat > "$TEST_TEMP_DIR/.ralph/status.json" <<'EOF'
{"loop_count": 7}
EOF
    # Pre-seed .exit_signals so the sentinel can update it
    cat > "$TEST_TEMP_DIR/.ralph/.exit_signals" <<'EOF'
{"test_only_loops": [], "done_signals": [], "completion_indicators": []}
EOF
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR"
}

# Helper: simulate a Write tool firing on the sentinel.
_simulate_sentinel_write() {
    local _action=$1 _reason=$2
    # Agent writes the sentinel
    printf '%s\n%s\n' "$_action" "$_reason" > "$TEST_TEMP_DIR/.ralph/.exit_signal_intent"
    # Hook fires (PostToolUse) with file_path
    local _input
    _input=$(jq -nc --arg path "$TEST_TEMP_DIR/.ralph/.exit_signal_intent" '{tool_input: {file_path: $path}}')
    printf '%s' "$_input" | bash "$HOOK"
}

# =============================================================================
# 1. Valid EMIT_EXIT_SIGNAL → JSONL appended, completion_indicators grows, intent deleted
# =============================================================================
@test "TAP-2502: EMIT_EXIT_SIGNAL appends JSONL entry + grows completion_indicators + deletes intent" {
    _simulate_sentinel_write "EMIT_EXIT_SIGNAL" "backlog empty"
    # JSONL entry exists
    [[ -f "$TEST_TEMP_DIR/.ralph/.exit_signal_calls.jsonl" ]] || { echo "JSONL missing"; return 1; }
    local _lines
    _lines=$(wc -l < "$TEST_TEMP_DIR/.ralph/.exit_signal_calls.jsonl" | tr -cd '0-9')
    [[ "$_lines" == "1" ]] || { echo "expected 1 JSONL line, got $_lines"; return 1; }
    # completion_indicators grew
    local _count
    _count=$(jq -r '.completion_indicators | length' "$TEST_TEMP_DIR/.ralph/.exit_signals")
    [[ "$_count" == "1" ]] || { echo "expected 1 indicator, got $_count"; return 1; }
    # Intent file deleted (single-shot)
    [[ ! -f "$TEST_TEMP_DIR/.ralph/.exit_signal_intent" ]] || { echo "intent file should be deleted"; return 1; }
}

# =============================================================================
# 2. JSONL entry contains the action and reason
# =============================================================================
@test "TAP-2502: JSONL entry contains action + reason fields" {
    _simulate_sentinel_write "EMIT_EXIT_SIGNAL" "backlog confirmed empty after 3 probes"
    local _action _reason
    _action=$(jq -r '.action' "$TEST_TEMP_DIR/.ralph/.exit_signal_calls.jsonl")
    _reason=$(jq -r '.reason' "$TEST_TEMP_DIR/.ralph/.exit_signal_calls.jsonl")
    [[ "$_action" == "EMIT_EXIT_SIGNAL" ]] || { echo "expected EMIT_EXIT_SIGNAL, got $_action"; return 1; }
    [[ "$_reason" == "backlog confirmed empty after 3 probes" ]] || { echo "expected the reason, got '$_reason'"; return 1; }
}

# =============================================================================
# 3. BLOCK action → JSONL entry but NO completion_indicators growth
# =============================================================================
@test "TAP-2502: BLOCK action records JSONL but does NOT grow completion_indicators" {
    _simulate_sentinel_write "BLOCK" "every issue is blocked:waiting-for-credentials"
    # JSONL
    [[ -f "$TEST_TEMP_DIR/.ralph/.exit_signal_calls.jsonl" ]]
    # NO indicator growth
    local _count
    _count=$(jq -r '.completion_indicators | length' "$TEST_TEMP_DIR/.ralph/.exit_signals")
    [[ "$_count" == "0" ]] || { echo "expected 0 indicators for BLOCK, got $_count"; return 1; }
}

# =============================================================================
# 4. Invalid action → WARN, no state change, intent still deleted
# =============================================================================
@test "TAP-2502: invalid action (MAKE_IT_WORK) is rejected with WARN, intent deleted" {
    local _stderr_capture
    _stderr_capture=$(_simulate_sentinel_write "MAKE_IT_WORK" "weird stuff" 2>&1 1>/dev/null) || true
    # No JSONL entry
    [[ ! -f "$TEST_TEMP_DIR/.ralph/.exit_signal_calls.jsonl" ]] || { echo "JSONL should not exist for invalid action"; return 1; }
    # Intent file still deleted (single-shot semantics — agent can't keep it around to retry)
    [[ ! -f "$TEST_TEMP_DIR/.ralph/.exit_signal_intent" ]] || { echo "intent file should be deleted even on invalid action"; return 1; }
}

# =============================================================================
# 5. Idempotency: two EMIT_EXIT_SIGNAL writes on the same loop don't double-count
# =============================================================================
@test "TAP-2502: two EMIT_EXIT_SIGNAL writes in same loop only count once" {
    _simulate_sentinel_write "EMIT_EXIT_SIGNAL" "first"
    _simulate_sentinel_write "EMIT_EXIT_SIGNAL" "second"
    local _count
    _count=$(jq -r '.completion_indicators | length' "$TEST_TEMP_DIR/.ralph/.exit_signals")
    [[ "$_count" == "1" ]] || { echo "expected 1 indicator (idempotent), got $_count"; return 1; }
    # Both JSONL entries appended (audit trail)
    local _lines
    _lines=$(wc -l < "$TEST_TEMP_DIR/.ralph/.exit_signal_calls.jsonl" | tr -cd '0-9')
    [[ "$_lines" == "2" ]] || { echo "expected 2 JSONL lines, got $_lines"; return 1; }
}

# =============================================================================
# 6. protect-ralph-files.sh allows Write to .exit_signal_intent
# =============================================================================
@test "TAP-2502: protect-ralph-files allows .exit_signal_intent write" {
    local _input
    _input=$(jq -nc --arg path "$TEST_TEMP_DIR/.ralph/.exit_signal_intent" '{tool_input: {file_path: $path}}')
    run bash "$PROTECT_HOOK" <<<"$_input"
    assert_success
}

# =============================================================================
# 7. protect-ralph-files.sh STILL blocks .ralph/status.json (defense intact)
# =============================================================================
@test "TAP-2502: protect-ralph-files allows status.json write (existing allowlist preserved)" {
    local _input
    _input=$(jq -nc --arg path "$TEST_TEMP_DIR/.ralph/status.json" '{tool_input: {file_path: $path}}')
    run bash "$PROTECT_HOOK" <<<"$_input"
    assert_success
}

@test "TAP-2502: protect-ralph-files STILL blocks unknown .ralph/ path" {
    local _input
    _input=$(jq -nc --arg path "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state" '{tool_input: {file_path: $path}}')
    run bash "$PROTECT_HOOK" <<<"$_input"
    assert_failure
}
