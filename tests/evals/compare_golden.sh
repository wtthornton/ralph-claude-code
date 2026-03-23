#!/usr/bin/env bash
# tests/evals/compare_golden.sh
# Compares actual Ralph run results against golden file expectations.
# Usage: source this file and call ralph_compare_golden <golden_file> <actual_status_json>
#   or run directly: ./compare_golden.sh <golden_file> <actual_status_json>

set -euo pipefail

# Compare result codes
RALPH_EVAL_PASS=0
RALPH_EVAL_FAIL=1
RALPH_EVAL_INCONCLUSIVE=2

# Compare a golden file against actual status.json output.
#
# Args:
#   $1 - golden_file: path to the golden file JSON
#   $2 - actual_status: path to the actual .ralph/status.json from a run
#
# Returns:
#   0 (PASS)          - all expected fields match
#   1 (FAIL)          - critical fields do not match (exit_signal, work_type)
#   2 (INCONCLUSIVE)  - non-critical differences (files_modified count differs but acceptable)
#
# Output: prints comparison report to stdout, result summary to stderr
ralph_compare_golden() {
    local golden_file="${1:?golden_file path required}"
    local actual_status="${2:?actual_status path required}"

    # Validate inputs
    if [[ ! -f "$golden_file" ]]; then
        echo "ERROR: Golden file not found: $golden_file" >&2
        return "$RALPH_EVAL_FAIL"
    fi
    if [[ ! -f "$actual_status" ]]; then
        echo "ERROR: Actual status file not found: $actual_status" >&2
        return "$RALPH_EVAL_FAIL"
    fi

    # Validate JSON
    if ! jq empty "$golden_file" 2>/dev/null; then
        echo "ERROR: Golden file is not valid JSON: $golden_file" >&2
        return "$RALPH_EVAL_FAIL"
    fi
    if ! jq empty "$actual_status" 2>/dev/null; then
        echo "ERROR: Actual status is not valid JSON: $actual_status" >&2
        return "$RALPH_EVAL_FAIL"
    fi

    local eval_id
    eval_id=$(jq -r '.id // "unknown"' "$golden_file")

    # Extract expected values
    local expected_exit_signal expected_work_type expected_files_modified
    local expected_max_iterations expected_max_tokens
    expected_exit_signal=$(jq -r '.expected.exit_signal // "false"' "$golden_file")
    expected_work_type=$(jq -r '.expected.work_type // "UNKNOWN"' "$golden_file")
    expected_files_modified=$(jq -r '.expected.files_modified // 0' "$golden_file")
    expected_max_iterations=$(jq -r '.expected.max_iterations // 0' "$golden_file")
    expected_max_tokens=$(jq -r '.expected.max_tokens // 0' "$golden_file")

    # Extract actual values
    local actual_exit_signal actual_work_type actual_files_modified actual_loop_count
    actual_exit_signal=$(jq -r '.exit_signal // "false"' "$actual_status")
    actual_work_type=$(jq -r '.work_type // "UNKNOWN"' "$actual_status")
    actual_files_modified=$(jq -r '.files_modified // 0' "$actual_status")
    actual_loop_count=$(jq -r '.loop_count // 0' "$actual_status")

    local result="$RALPH_EVAL_PASS"
    local checks_passed=0
    local checks_total=0
    local report=""

    # --- Check 1: exit_signal (CRITICAL) ---
    checks_total=$((checks_total + 1))
    if [[ "$actual_exit_signal" == "$expected_exit_signal" ]]; then
        checks_passed=$((checks_passed + 1))
        report+="  [PASS] exit_signal: expected=$expected_exit_signal actual=$actual_exit_signal\n"
    else
        result="$RALPH_EVAL_FAIL"
        report+="  [FAIL] exit_signal: expected=$expected_exit_signal actual=$actual_exit_signal\n"
    fi

    # --- Check 2: work_type (CRITICAL if expected is not UNKNOWN) ---
    checks_total=$((checks_total + 1))
    if [[ "$expected_work_type" == "UNKNOWN" ]] || [[ "$actual_work_type" == "$expected_work_type" ]]; then
        checks_passed=$((checks_passed + 1))
        report+="  [PASS] work_type: expected=$expected_work_type actual=$actual_work_type\n"
    else
        result="$RALPH_EVAL_FAIL"
        report+="  [FAIL] work_type: expected=$expected_work_type actual=$actual_work_type\n"
    fi

    # --- Check 3: files_modified (INCONCLUSIVE if different) ---
    checks_total=$((checks_total + 1))
    if [[ "$actual_files_modified" -eq "$expected_files_modified" ]]; then
        checks_passed=$((checks_passed + 1))
        report+="  [PASS] files_modified: expected=$expected_files_modified actual=$actual_files_modified\n"
    else
        # Different file count is INCONCLUSIVE, not a hard failure
        if [[ "$result" == "$RALPH_EVAL_PASS" ]]; then
            result="$RALPH_EVAL_INCONCLUSIVE"
        fi
        report+="  [WARN] files_modified: expected=$expected_files_modified actual=$actual_files_modified (INCONCLUSIVE)\n"
    fi

    # --- Check 4: max_iterations (FAIL if exceeded, skip if 0) ---
    if [[ "$expected_max_iterations" -gt 0 ]]; then
        checks_total=$((checks_total + 1))
        if [[ "$actual_loop_count" -le "$expected_max_iterations" ]]; then
            checks_passed=$((checks_passed + 1))
            report+="  [PASS] iterations: max=$expected_max_iterations actual=$actual_loop_count\n"
        else
            if [[ "$result" != "$RALPH_EVAL_FAIL" ]]; then
                result="$RALPH_EVAL_INCONCLUSIVE"
            fi
            report+="  [WARN] iterations: max=$expected_max_iterations actual=$actual_loop_count (exceeded)\n"
        fi
    fi

    # --- Check 5: tool_sequence_contains (FAIL if missing required tools) ---
    local tool_contains_count
    tool_contains_count=$(jq '.expected.tool_sequence_contains | length' "$golden_file" 2>/dev/null || echo "0")
    if [[ "$tool_contains_count" -gt 0 ]]; then
        # Tool sequence checking requires a tool log; skip if not available
        local tool_log=""
        local ralph_dir
        ralph_dir=$(dirname "$actual_status")
        if [[ -f "$ralph_dir/live.log" ]]; then
            tool_log="$ralph_dir/live.log"
        fi

        if [[ -n "$tool_log" ]]; then
            local i
            for ((i=0; i<tool_contains_count; i++)); do
                local required_tool
                required_tool=$(jq -r ".expected.tool_sequence_contains[$i]" "$golden_file")
                checks_total=$((checks_total + 1))
                if grep -q "$required_tool" "$tool_log" 2>/dev/null; then
                    checks_passed=$((checks_passed + 1))
                    report+="  [PASS] tool_contains: $required_tool found\n"
                else
                    result="$RALPH_EVAL_FAIL"
                    report+="  [FAIL] tool_contains: $required_tool NOT found in tool log\n"
                fi
            done
        else
            report+="  [SKIP] tool_sequence_contains: no tool log available\n"
        fi
    fi

    # --- Check 6: tool_sequence_excludes (FAIL if forbidden tools present) ---
    local tool_excludes_count
    tool_excludes_count=$(jq '.expected.tool_sequence_excludes | length' "$golden_file" 2>/dev/null || echo "0")
    if [[ "$tool_excludes_count" -gt 0 ]]; then
        local tool_log=""
        local ralph_dir
        ralph_dir=$(dirname "$actual_status")
        if [[ -f "$ralph_dir/live.log" ]]; then
            tool_log="$ralph_dir/live.log"
        fi

        if [[ -n "$tool_log" ]]; then
            local i
            for ((i=0; i<tool_excludes_count; i++)); do
                local forbidden_tool
                forbidden_tool=$(jq -r ".expected.tool_sequence_excludes[$i]" "$golden_file")
                checks_total=$((checks_total + 1))
                if grep -q "$forbidden_tool" "$tool_log" 2>/dev/null; then
                    result="$RALPH_EVAL_FAIL"
                    report+="  [FAIL] tool_excludes: $forbidden_tool FOUND in tool log (should be absent)\n"
                else
                    checks_passed=$((checks_passed + 1))
                    report+="  [PASS] tool_excludes: $forbidden_tool correctly absent\n"
                fi
            done
        else
            report+="  [SKIP] tool_sequence_excludes: no tool log available\n"
        fi
    fi

    # --- Summary ---
    local result_label
    case "$result" in
        "$RALPH_EVAL_PASS")        result_label="PASS" ;;
        "$RALPH_EVAL_FAIL")        result_label="FAIL" ;;
        "$RALPH_EVAL_INCONCLUSIVE") result_label="INCONCLUSIVE" ;;
        *)                          result_label="UNKNOWN" ;;
    esac

    echo "=== Golden Comparison: $eval_id ==="
    echo -e "$report"
    echo "--- Result: $result_label ($checks_passed/$checks_total checks passed) ---"

    echo "EVAL_RESULT=$result_label" >&2

    return "$result"
}

# If run directly (not sourced), execute with CLI args
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ $# -lt 2 ]]; then
        echo "Usage: $0 <golden_file.json> <actual_status.json>"
        echo ""
        echo "Compares actual Ralph run results against golden file expectations."
        echo ""
        echo "Exit codes:"
        echo "  0 = PASS          - all checks passed"
        echo "  1 = FAIL          - critical checks failed"
        echo "  2 = INCONCLUSIVE  - non-critical differences"
        exit 1
    fi

    ralph_compare_golden "$@"
fi
