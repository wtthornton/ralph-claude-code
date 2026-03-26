#!/usr/bin/env bash
# Mock Claude CLI for E2E testing (Issue #225)
# Simulates realistic Claude Code CLI scenarios deterministically.
#
# Usage:
#   MOCK_SCENARIO=normal ./tests/mock_claude.sh [args...]
#
# Scenarios (controlled via MOCK_SCENARIO env var):
#   normal         - Outputs progress then EXIT_SIGNAL: true after MOCK_LOOPS loops (default 3)
#   stuck          - Never outputs progress (simulates infinite no-output loop)
#   permission     - Outputs repeated permission denial responses
#   rate_limit     - Outputs rate limit / API quota exceeded response
#   high_tokens    - Outputs response with very high token usage
#   error          - Outputs a generic error response
#   empty          - Outputs empty result
#
# Environment:
#   MOCK_SCENARIO       - Scenario to simulate (default: "normal")
#   MOCK_LOOP_COUNT     - Current loop number (auto-incremented via state file)
#   MOCK_LOOPS          - Total loops before EXIT_SIGNAL in "normal" scenario (default: 3)
#   MOCK_STATE_DIR      - Directory for state tracking (default: /tmp/ralph_mock_state)

set -euo pipefail

MOCK_SCENARIO="${MOCK_SCENARIO:-normal}"
MOCK_LOOPS="${MOCK_LOOPS:-3}"
MOCK_STATE_DIR="${MOCK_STATE_DIR:-/tmp/ralph_mock_state}"

# Track loop count via state file (persists across invocations)
mkdir -p "$MOCK_STATE_DIR"
MOCK_COUNT_FILE="$MOCK_STATE_DIR/loop_count"
if [[ -f "$MOCK_COUNT_FILE" ]]; then
    MOCK_LOOP_COUNT=$(cat "$MOCK_COUNT_FILE")
else
    MOCK_LOOP_COUNT=0
fi
MOCK_LOOP_COUNT=$((MOCK_LOOP_COUNT + 1))
echo "$MOCK_LOOP_COUNT" > "$MOCK_COUNT_FILE"

# Helper: generate a valid Claude JSON output envelope
emit_json_result() {
    local result_text="$1"
    local session_id="${MOCK_SESSION_ID:-mock-session-$(date +%s)}"
    # System init line
    echo "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"${session_id}\",\"tools\":[\"Read\",\"Write\",\"Edit\",\"Bash\"]}"
    # Assistant message
    echo "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":$(printf '%s' "$result_text" | jq -Rs .)}]}}"
    # Result line
    echo "{\"type\":\"result\",\"subtype\":\"success\",\"result\":$(printf '%s' "$result_text" | jq -Rs .),\"is_error\":false,\"session_id\":\"${session_id}\",\"num_turns\":1,\"cost_usd\":0.005,\"duration_ms\":1200,\"duration_api_ms\":1000}"
}

# Helper: generate rate_limit_event JSON
emit_rate_limit() {
    local session_id="${MOCK_SESSION_ID:-mock-session-$(date +%s)}"
    echo "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"${session_id}\",\"tools\":[\"Read\",\"Write\",\"Edit\",\"Bash\"]}"
    echo "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"Rate limit reached.\"}]}}"
    echo "{\"type\":\"result\",\"subtype\":\"rate_limit_event\",\"rate_limit_event\":{\"type\":\"rate_limit\",\"status\":\"rejected\",\"message\":\"You have exceeded your 5-hour usage limit. Please try again later.\"}}"
}

# Helper: generate error result JSON
emit_error_result() {
    local error_text="$1"
    local session_id="${MOCK_SESSION_ID:-mock-session-$(date +%s)}"
    echo "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"${session_id}\",\"tools\":[\"Read\",\"Write\",\"Edit\",\"Bash\"]}"
    echo "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":$(printf '%s' "$error_text" | jq -Rs .)}]}}"
    echo "{\"type\":\"result\",\"subtype\":\"error\",\"result\":$(printf '%s' "$error_text" | jq -Rs .),\"is_error\":true,\"session_id\":\"${session_id}\",\"num_turns\":1,\"cost_usd\":0.001,\"duration_ms\":500,\"duration_api_ms\":400}"
}

case "$MOCK_SCENARIO" in
    normal)
        if [[ "$MOCK_LOOP_COUNT" -ge "$MOCK_LOOPS" ]]; then
            # Final loop: emit completion with EXIT_SIGNAL
            result_text="All tasks have been completed successfully.

---RALPH_STATUS---
STATUS: COMPLETE
TASKS_COMPLETED_THIS_LOOP: 1
FILES_MODIFIED: 2
TESTS_STATUS: PASSING
WORK_TYPE: IMPLEMENTATION
EXIT_SIGNAL: true
RECOMMENDATION: All work is done. Project is ready for review.
---END_RALPH_STATUS---"
            emit_json_result "$result_text"
        else
            # Progress loop: emit productive work without EXIT_SIGNAL
            result_text="Working on task ${MOCK_LOOP_COUNT} of ${MOCK_LOOPS}. Implemented feature and updated files.

---RALPH_STATUS---
STATUS: IN_PROGRESS
TASKS_COMPLETED_THIS_LOOP: 1
FILES_MODIFIED: 3
TESTS_STATUS: PASSING
WORK_TYPE: IMPLEMENTATION
EXIT_SIGNAL: false
RECOMMENDATION: Continue with next task.
---END_RALPH_STATUS---"
            emit_json_result "$result_text"
        fi
        ;;

    stuck)
        # No progress: outputs thinking without any file changes or tasks completed
        result_text="Analyzing the code structure... Thinking about the problem...

---RALPH_STATUS---
STATUS: IN_PROGRESS
TASKS_COMPLETED_THIS_LOOP: 0
FILES_MODIFIED: 0
TESTS_STATUS: UNKNOWN
WORK_TYPE: UNKNOWN
EXIT_SIGNAL: false
RECOMMENDATION: Still analyzing.
---END_RALPH_STATUS---"
        emit_json_result "$result_text"
        ;;

    permission)
        # Permission denial response
        result_text="I need permission to execute this command but it was denied.

User denied tool use: Bash(rm -rf /important)
The user denied the tool execution request.

---RALPH_STATUS---
STATUS: BLOCKED
TASKS_COMPLETED_THIS_LOOP: 0
FILES_MODIFIED: 0
TESTS_STATUS: UNKNOWN
WORK_TYPE: UNKNOWN
EXIT_SIGNAL: false
RECOMMENDATION: Permission denied for required operation.
---END_RALPH_STATUS---"
        emit_json_result "$result_text"
        ;;

    rate_limit)
        # Rate limit / API quota exceeded
        emit_rate_limit
        ;;

    high_tokens)
        # High token usage response (large output simulating expensive call)
        result_text="Completed extensive analysis and refactoring across multiple files.

---RALPH_STATUS---
STATUS: IN_PROGRESS
TASKS_COMPLETED_THIS_LOOP: 1
FILES_MODIFIED: 15
TESTS_STATUS: PASSING
WORK_TYPE: IMPLEMENTATION
EXIT_SIGNAL: false
RECOMMENDATION: Significant progress but more work needed.
---END_RALPH_STATUS---"
        ht_session_id="${MOCK_SESSION_ID:-mock-session-$(date +%s)}"
        echo "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"${ht_session_id}\",\"tools\":[\"Read\",\"Write\",\"Edit\",\"Bash\"]}"
        echo "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":$(printf '%s' "$result_text" | jq -Rs .)}]}}"
        # Result with very high token usage
        echo "{\"type\":\"result\",\"subtype\":\"success\",\"result\":$(printf '%s' "$result_text" | jq -Rs .),\"is_error\":false,\"session_id\":\"${ht_session_id}\",\"num_turns\":25,\"cost_usd\":2.50,\"duration_ms\":180000,\"duration_api_ms\":175000,\"usage\":{\"input_tokens\":180000,\"output_tokens\":95000,\"cache_read_tokens\":50000,\"cache_write_tokens\":20000}}"
        ;;

    error)
        # Generic error response
        emit_error_result "Error: Cannot find module 'missing-dependency'. Failed to compile."
        ;;

    empty)
        # Empty / minimal result
        emit_json_result ""
        ;;

    *)
        echo "Unknown MOCK_SCENARIO: $MOCK_SCENARIO" >&2
        exit 1
        ;;
esac

exit 0
