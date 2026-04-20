#!/usr/bin/env bats
# TAP-538: Tests for templates/hooks/on-stop.sh resilience and parity.
#
# Focus:
#   * Corrupt .circuit_breaker_state must be auto-repaired with a WARN, not a
#     hook crash that blocks the loop.
#   * .ralph/hooks/on-stop.sh must stay byte-identical to the template (drift
#     means a stale, less-hardened hook ships with the project).

bats_require_minimum_version 1.5.0
load '../helpers/test_helper'

REPO_ROOT="${BATS_TEST_DIRNAME}/../.."
TEMPLATE_HOOK="${REPO_ROOT}/templates/hooks/on-stop.sh"
RUNTIME_HOOK="${REPO_ROOT}/.ralph/hooks/on-stop.sh"

setup() {
    export TEST_TEMP_DIR="$(mktemp -d)"
    cd "$TEST_TEMP_DIR"
    # Hook keys off CLAUDE_PROJECT_DIR for the .ralph location.
    export CLAUDE_PROJECT_DIR="$TEST_TEMP_DIR"
    mkdir -p "$TEST_TEMP_DIR/.ralph"
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR"
}

# Minimal valid CLI response payload the hook can parse.
_valid_input() {
    cat <<'JSON'
{"result":"Did some work.\n\n```json\n{\"RALPH_STATUS\":{\"EXIT_SIGNAL\":false,\"FILES_MODIFIED\":0,\"TASKS_COMPLETED\":0,\"WORK_TYPE\":\"IMPLEMENTATION\"}}\n```"}
JSON
}

# =============================================================================
# Drift parity — TAP-538 root cause was the runtime hook losing template fixes
# =============================================================================

@test "TAP-538: .ralph/hooks/on-stop.sh is byte-identical to templates/hooks/on-stop.sh" {
    [[ -f "$TEMPLATE_HOOK" ]] || skip "template hook missing: $TEMPLATE_HOOK"
    [[ -f "$RUNTIME_HOOK" ]] || skip "runtime hook missing: $RUNTIME_HOOK"
    run diff -q "$RUNTIME_HOOK" "$TEMPLATE_HOOK"
    assert_success
}

@test "TAP-538: .ralph/hooks/on-session-start.sh is byte-identical to template" {
    local tpl="${REPO_ROOT}/templates/hooks/on-session-start.sh"
    local rt="${REPO_ROOT}/.ralph/hooks/on-session-start.sh"
    [[ -f "$tpl" && -f "$rt" ]] || skip "on-session-start.sh missing in tpl or runtime"
    run diff -q "$rt" "$tpl"
    assert_success
}

# =============================================================================
# CB state recovery — corrupt input must NOT crash the hook
# =============================================================================

@test "TAP-538: corrupt .circuit_breaker_state is auto-repaired, hook exits 0" {
    # Seed a deliberately corrupt file (not valid JSON).
    printf 'this is not json {{{ broken' > "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state"

    # Run the hook with a valid payload; the corrupt CB state must be repaired
    # rather than crash the hook.
    run --separate-stderr bash "$TEMPLATE_HOOK" <<<"$(_valid_input)"
    assert_success

    # WARN must be logged on stderr.
    [[ "$stderr" == *"corrupt"* && "$stderr" == *"reinitializing"* ]] || \
        fail "expected reinit WARN on stderr, got: $stderr"

    # File must now be valid JSON.
    run jq -e 'type == "object"' "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state"
    assert_success

    # Re-init must produce a CB-state object with the expected shape. The
    # hook's normal logic runs immediately after repair, so the no-progress
    # counter may have been incremented to 1 by this same invocation — that's
    # fine; what we assert is that the schema is restored.
    run jq -e '
        (.state | type == "string") and
        (.consecutive_no_progress | type == "number") and
        (.consecutive_permission_denials | type == "number") and
        (.total_opens | type == "number")
    ' "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state"
    assert_success
}

@test "TAP-538: empty .circuit_breaker_state is treated as corrupt and repaired" {
    : > "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state"
    run --separate-stderr bash "$TEMPLATE_HOOK" <<<"$(_valid_input)"
    assert_success
    run jq -e 'type == "object"' "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state"
    assert_success
}

@test "TAP-538: valid .circuit_breaker_state is preserved (no spurious reinit)" {
    # Seed a valid CB state with non-default counters.
    printf '%s\n' \
        '{"state":"CLOSED","consecutive_no_progress":2,"consecutive_permission_denials":1,"total_opens":3}' \
        > "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state"

    run --separate-stderr bash "$TEMPLATE_HOOK" <<<"$(_valid_input)"
    assert_success

    # No reinit WARN should fire on a healthy state.
    [[ "$stderr" != *"corrupt"* ]] || \
        fail "valid state should not be reported as corrupt: $stderr"

    # The hook IS allowed to mutate counters per its progress rules; we only
    # assert the file is still valid JSON of the right shape after the run.
    run jq -e '(.state | type == "string") and (.consecutive_no_progress | type == "number")' \
        "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state"
    assert_success
}

# =============================================================================
# EXIT-CLEAN: Claude's `EXIT_SIGNAL: true + STATUS: COMPLETE` with 0/0 changes
# is a legitimate clean-exit signal, not stagnation. The hook must not increment
# consecutive_no_progress in that case (otherwise empty-plan launches burn 3
# Claude calls before the no-progress CB trips).
# =============================================================================

# Helper: build a Claude response payload with a RALPH_STATUS block.
_status_block_input() {
    local exit_signal="$1" status="$2" tasks="$3" files="$4"
    local body="Result.

---RALPH_STATUS---
STATUS: ${status}
TASKS_COMPLETED_THIS_LOOP: ${tasks}
FILES_MODIFIED: ${files}
TESTS_STATUS: NOT_RUN
WORK_TYPE: IMPLEMENTATION
EXIT_SIGNAL: ${exit_signal}
RECOMMENDATION: Test payload.
---END_RALPH_STATUS---"
    jq -Rs '{result: .}' <<<"$body"
}

@test "EXIT-CLEAN: EXIT_SIGNAL=true + STATUS=COMPLETE + 0/0 RESETS no-progress (does NOT increment)" {
    # Pre-seed: no-progress already at 2 (one more 'no progress' would trip on threshold=3).
    printf '%s\n' \
        '{"state":"CLOSED","consecutive_no_progress":2,"consecutive_permission_denials":0,"total_opens":0}' \
        > "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state"

    run --separate-stderr bash "$TEMPLATE_HOOK" <<<"$(_status_block_input true COMPLETE 0 0)"
    assert_success

    # Counter must be reset to 0, state must remain CLOSED — exit_signal is a
    # request for clean shutdown, not a stagnation indicator.
    run jq -r '.consecutive_no_progress' "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state"
    assert_output "0"
    run jq -r '.state' "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state"
    assert_output "CLOSED"
}

@test "EXIT-CLEAN guard: EXIT_SIGNAL=false + 0/0 STILL increments no-progress (regression guard)" {
    # Same seed; this time EXIT_SIGNAL=false (no clean-exit request).
    # Hook must STILL count this as no-progress and trip the CB at threshold=3.
    printf '%s\n' \
        '{"state":"CLOSED","consecutive_no_progress":2,"consecutive_permission_denials":0,"total_opens":0}' \
        > "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state"

    run --separate-stderr bash "$TEMPLATE_HOOK" <<<"$(_status_block_input false IN_PROGRESS 0 0)"
    assert_success

    run jq -r '.consecutive_no_progress' "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state"
    assert_output "3"
    run jq -r '.state' "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state"
    assert_output "OPEN"
}

@test "EXIT-CLEAN guard: EXIT_SIGNAL=true but STATUS!=COMPLETE does NOT bypass no-progress" {
    # Defensive: only honor exit-clean when BOTH signals agree. EXIT_SIGNAL=true
    # without STATUS=COMPLETE is ambiguous — fall through to normal classification.
    printf '%s\n' \
        '{"state":"CLOSED","consecutive_no_progress":2,"consecutive_permission_denials":0,"total_opens":0}' \
        > "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state"

    run --separate-stderr bash "$TEMPLATE_HOOK" <<<"$(_status_block_input true PARTIAL 0 0)"
    assert_success

    # Should be treated as no-progress and trip.
    run jq -r '.consecutive_no_progress' "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state"
    assert_output "3"
}

@test "EXIT-CLEAN: status.json after EXIT_SIGNAL=true is valid JSON (Bug 1 regression guard)" {
    # The grep -c || echo 0 pattern previously injected a stray '0\n' into status.json,
    # which broke ralph_loop.sh's downstream jq reads. Template was fixed via tr -cd '0-9'.
    # This test asserts status.json stays valid JSON across the EXIT_SIGNAL=true path.
    printf '%s\n' \
        '{"state":"CLOSED","consecutive_no_progress":0,"consecutive_permission_denials":0,"total_opens":0}' \
        > "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state"
    printf '{"loop_count": 5}' > "$TEST_TEMP_DIR/.ralph/status.json"

    run --separate-stderr bash "$TEMPLATE_HOOK" <<<"$(_status_block_input true COMPLETE 0 0)"
    assert_success

    # status.json must be valid JSON with exit_signal field intact.
    run jq -e 'type == "object" and .exit_signal == "true"' "$TEST_TEMP_DIR/.ralph/status.json"
    assert_success
}

# =============================================================================
# COST-EXTRACT: total_cost_usd and token usage live in the live stream-json file
# under .ralph/logs/, NOT in the official ~/.claude/projects/<proj>/<sess>.jsonl
# transcript. The hook must fall through to the stream file so loop_cost_usd and
# loop_input_tokens / loop_output_tokens are non-zero on real loops.
# Regression: tapps-brain status.json showed loop_cost_usd=0 across all loops
# despite cache token counts being populated correctly (3.1M read / 180K create
# per loop), because both INPUT and transcript_path lacked a "type":"result" line.
# =============================================================================

@test "COST-EXTRACT: hook reads total_cost_usd from .ralph/logs/ stream when transcript lacks result line" {
    # Set up a minimal stream-json log mirroring what `claude --output-format stream-json`
    # writes during a real loop. Only the result line carries cost.
    mkdir -p "$TEST_TEMP_DIR/.ralph/logs"
    cat > "$TEST_TEMP_DIR/.ralph/logs/claude_output_2099-01-01_00-00-00.log" <<'STREAM'
{"type":"system","subtype":"init","session_id":"abc123"}
{"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":1000,"cache_creation_input_tokens":500}}}
{"type":"result","subtype":"success","is_error":false,"total_cost_usd":1.234567,"usage":{"input_tokens":42,"output_tokens":99,"cache_read_input_tokens":3136400,"cache_creation_input_tokens":180230}}
STREAM

    # Provide INPUT with a transcript_path that has NO result line — matches what
    # ~/.claude/projects/<proj>/<sess>.jsonl actually looks like in agent mode.
    local transcript="$TEST_TEMP_DIR/.ralph/transcript.jsonl"
    cat > "$transcript" <<'JSONL'
{"type":"user","message":{"content":"go"}}
{"type":"assistant","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":42,"output_tokens":99,"cache_read_input_tokens":3136400,"cache_creation_input_tokens":180230}}}
JSONL

    printf '%s\n' \
        '{"state":"CLOSED","consecutive_no_progress":0,"consecutive_permission_denials":0,"total_opens":0}' \
        > "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state"

    local input
    input=$(jq -n --arg tp "$transcript" \
        '{transcript_path: $tp, result: "Did work.\n\n---RALPH_STATUS---\nSTATUS: IN_PROGRESS\nTASKS_COMPLETED_THIS_LOOP: 1\nFILES_MODIFIED: 3\nTESTS_STATUS: NOT_RUN\nWORK_TYPE: IMPLEMENTATION\nEXIT_SIGNAL: false\nRECOMMENDATION: keep going\n---END_RALPH_STATUS---"}')

    run --separate-stderr bash "$TEMPLATE_HOOK" <<<"$input"
    assert_success

    # Cost and token counts must reflect the stream's result line, not zero.
    run jq -r '.loop_cost_usd' "$TEST_TEMP_DIR/.ralph/status.json"
    assert_output "1.234567"
    run jq -r '.loop_input_tokens' "$TEST_TEMP_DIR/.ralph/status.json"
    assert_output "42"
    run jq -r '.loop_output_tokens' "$TEST_TEMP_DIR/.ralph/status.json"
    assert_output "99"
}

@test "COST-EXTRACT: hook prefers _stream.log-suffixed sibling's NON-suffixed live file" {
    # ralph_loop.sh post-processing creates *_stream.log as a backup AFTER the
    # hook fires, then overwrites the original .log with just the result line.
    # Pre-existing _stream.log files from prior loops must not shadow the current
    # loop's live stream when picking newest-by-mtime.
    mkdir -p "$TEST_TEMP_DIR/.ralph/logs"

    # Older _stream.log backup from a previous loop ($1.99 — wrong answer).
    cat > "$TEST_TEMP_DIR/.ralph/logs/claude_output_2098-01-01_00-00-00_stream.log" <<'OLD'
{"type":"result","total_cost_usd":1.99,"usage":{"input_tokens":1,"output_tokens":1}}
OLD
    # Make sure mtime is older.
    touch -t 209801010000 "$TEST_TEMP_DIR/.ralph/logs/claude_output_2098-01-01_00-00-00_stream.log"

    # Current live stream — newer mtime, lower cost — this is the correct source.
    cat > "$TEST_TEMP_DIR/.ralph/logs/claude_output_2099-01-01_00-00-00.log" <<'NEW'
{"type":"result","total_cost_usd":0.42,"usage":{"input_tokens":7,"output_tokens":13}}
NEW

    printf '%s\n' \
        '{"state":"CLOSED","consecutive_no_progress":0,"consecutive_permission_denials":0,"total_opens":0}' \
        > "$TEST_TEMP_DIR/.ralph/.circuit_breaker_state"

    run --separate-stderr bash "$TEMPLATE_HOOK" <<<"$(_status_block_input false IN_PROGRESS 1 1)"
    assert_success

    # Must read the non-suffixed .log (the live stream), not the older _stream.log backup.
    run jq -r '.loop_cost_usd' "$TEST_TEMP_DIR/.ralph/status.json"
    assert_output "0.42"
}

# =============================================================================
# TAP-741: push-mode Linear counts — hook extracts LINEAR_OPEN_COUNT /
# LINEAR_DONE_COUNT from RALPH_STATUS and writes them to status.json with a
# linear_counts_at timestamp so lib/linear_backend.sh can read them without an
# API key.
# =============================================================================

# Helper: build a Claude response with the given Linear push-mode counts.
_status_block_with_linear_counts() {
    local open="$1" done_c="$2"
    local body="Worked on TAP-741.

---RALPH_STATUS---
STATUS: IN_PROGRESS
TASKS_COMPLETED_THIS_LOOP: 0
FILES_MODIFIED: 0
TESTS_STATUS: NOT_RUN
WORK_TYPE: IMPLEMENTATION
EXIT_SIGNAL: false
RECOMMENDATION: Test push-mode counts.
LINEAR_OPEN_COUNT: ${open}
LINEAR_DONE_COUNT: ${done_c}
---END_RALPH_STATUS---"
    jq -Rs '{result: .}' <<<"$body"
}

@test "TAP-741 hook: extracts LINEAR_OPEN_COUNT / LINEAR_DONE_COUNT into status.json" {
    run --separate-stderr bash "$TEMPLATE_HOOK" <<<"$(_status_block_with_linear_counts 12 5)"
    assert_success

    run jq -r '.linear_open_count' "$TEST_TEMP_DIR/.ralph/status.json"
    assert_output "12"
    run jq -r '.linear_done_count' "$TEST_TEMP_DIR/.ralph/status.json"
    assert_output "5"
}

@test "TAP-741 hook: stamps linear_counts_at with an ISO-8601 UTC timestamp" {
    run --separate-stderr bash "$TEMPLATE_HOOK" <<<"$(_status_block_with_linear_counts 3 7)"
    assert_success

    run jq -r '.linear_counts_at' "$TEST_TEMP_DIR/.ralph/status.json"
    assert_success
    # Shape: YYYY-MM-DDTHH:MM:SSZ
    [[ "$output" =~ ^20[0-9]{2}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || \
        fail "linear_counts_at not ISO-8601 UTC: $output"
}

@test "TAP-741 hook: accepts zero counts (empty-project done signal)" {
    run --separate-stderr bash "$TEMPLATE_HOOK" <<<"$(_status_block_with_linear_counts 0 0)"
    assert_success

    run jq -r '.linear_open_count' "$TEST_TEMP_DIR/.ralph/status.json"
    assert_output "0"
    run jq -r '.linear_done_count' "$TEST_TEMP_DIR/.ralph/status.json"
    assert_output "0"
}

@test "TAP-741 hook: absent LINEAR_OPEN_COUNT / _DONE_COUNT → null fields, null timestamp" {
    # file-mode projects never emit these fields; status.json must leave them null
    # instead of poisoning the backend's staleness check with stale data.
    local body="---RALPH_STATUS---
STATUS: IN_PROGRESS
TASKS_COMPLETED_THIS_LOOP: 0
FILES_MODIFIED: 0
TESTS_STATUS: NOT_RUN
WORK_TYPE: IMPLEMENTATION
EXIT_SIGNAL: false
RECOMMENDATION: No Linear fields.
---END_RALPH_STATUS---"
    local input; input=$(jq -Rs '{result: .}' <<<"$body")

    run --separate-stderr bash "$TEMPLATE_HOOK" <<<"$input"
    assert_success

    run jq -r '.linear_open_count' "$TEST_TEMP_DIR/.ralph/status.json"
    assert_output "null"
    run jq -r '.linear_done_count' "$TEST_TEMP_DIR/.ralph/status.json"
    assert_output "null"
    run jq -r '.linear_counts_at' "$TEST_TEMP_DIR/.ralph/status.json"
    assert_output "null"
}

@test "TAP-741 hook: non-numeric LINEAR_OPEN_COUNT is coerced to null" {
    local body="---RALPH_STATUS---
STATUS: IN_PROGRESS
TASKS_COMPLETED_THIS_LOOP: 0
FILES_MODIFIED: 0
TESTS_STATUS: NOT_RUN
WORK_TYPE: IMPLEMENTATION
EXIT_SIGNAL: false
RECOMMENDATION: Bad input.
LINEAR_OPEN_COUNT: many
LINEAR_DONE_COUNT: 4
---END_RALPH_STATUS---"
    local input; input=$(jq -Rs '{result: .}' <<<"$body")

    run --separate-stderr bash "$TEMPLATE_HOOK" <<<"$input"
    assert_success

    # Malformed open_count → null; valid done_count passes through.
    run jq -r '.linear_open_count' "$TEST_TEMP_DIR/.ralph/status.json"
    assert_output "null"
    run jq -r '.linear_done_count' "$TEST_TEMP_DIR/.ralph/status.json"
    assert_output "4"
}
