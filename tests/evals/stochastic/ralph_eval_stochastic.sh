#!/usr/bin/env bash
# tests/evals/stochastic/ralph_eval_stochastic.sh
# EVALS-3: Stochastic eval runner.
#
# Runs a golden file evaluation N times and determines PASS/FAIL/INCONCLUSIVE
# based on success rate against a configurable threshold.
#
# Usage: source this file and call ralph_eval_stochastic <golden_file>
#   or run directly: ./ralph_eval_stochastic.sh <golden_file> [project_dir]
#
# Environment variables:
#   RALPH_EVAL_RUNS            - number of runs (default: 3)
#   RALPH_EVAL_PASS_THRESHOLD  - pass rate threshold (default: 0.8 = 80%)
#   RALPH_EVAL_FAIL_THRESHOLD  - fail rate threshold (default: 0.2 = 20%)
#   RALPH_EVAL_RESULTS_DIR     - directory for JSONL results (default: tests/evals/results)
#   RALPH_EVAL_PROJECT_DIR     - project directory to run Ralph in (required for actual runs)
#   RALPH_EVAL_DRY_RUN         - if "true", simulates runs without calling Ralph (for testing)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVALS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPARE_SCRIPT="$EVALS_DIR/compare_golden.sh"

# Defaults
RALPH_EVAL_RUNS="${RALPH_EVAL_RUNS:-3}"
RALPH_EVAL_PASS_THRESHOLD="${RALPH_EVAL_PASS_THRESHOLD:-0.8}"
RALPH_EVAL_FAIL_THRESHOLD="${RALPH_EVAL_FAIL_THRESHOLD:-0.2}"
RALPH_EVAL_RESULTS_DIR="${RALPH_EVAL_RESULTS_DIR:-$EVALS_DIR/results}"
RALPH_EVAL_DRY_RUN="${RALPH_EVAL_DRY_RUN:-false}"

# Source compare_golden for comparison functions
source "$COMPARE_SCRIPT"

# Calculate Wilson score confidence interval at 95% confidence level.
# Uses the Wilson score interval formula for binomial proportions.
#
# Args:
#   $1 - passes: number of successful runs
#   $2 - total: total number of runs
#
# Output: prints "lower upper" bounds of 95% CI (space-separated, 4 decimal places)
#
# The Wilson score interval is preferred over the normal approximation
# because it performs well even with small sample sizes (n < 30).
ralph_eval_confidence_interval() {
    local passes="${1:?passes required}"
    local total="${2:?total required}"

    if [[ "$total" -eq 0 ]]; then
        echo "0.0000 0.0000"
        return
    fi

    # Wilson score interval at 95% confidence (z = 1.96)
    # Formula:
    #   center = (p + z^2/(2n)) / (1 + z^2/n)
    #   margin = z * sqrt(p*(1-p)/n + z^2/(4*n^2)) / (1 + z^2/n)
    #   CI = [center - margin, center + margin]
    #
    # We use awk for floating-point arithmetic since bash only does integers.
    awk -v p="$passes" -v n="$total" 'BEGIN {
        z = 1.96
        z2 = z * z
        phat = p / n

        denom = 1 + z2 / n
        center = (phat + z2 / (2 * n)) / denom
        margin = z * sqrt((phat * (1 - phat) / n) + (z2 / (4 * n * n))) / denom

        lower = center - margin
        upper = center + margin

        # Clamp to [0, 1]
        if (lower < 0) lower = 0
        if (upper > 1) upper = 1

        printf "%.4f %.4f\n", lower, upper
    }'
}

# Run a single Ralph evaluation against a golden file.
#
# Args:
#   $1 - golden_file: path to golden file JSON
#   $2 - run_index: which run number this is (for logging)
#
# Returns: 0=PASS, 1=FAIL, 2=INCONCLUSIVE
_ralph_single_eval_run() {
    local golden_file="$1"
    local run_index="$2"
    local project_dir="${RALPH_EVAL_PROJECT_DIR:-.}"

    if [[ "$RALPH_EVAL_DRY_RUN" == "true" ]]; then
        # Dry-run mode: simulate a Ralph run by creating a mock status.json
        local mock_status
        mock_status=$(mktemp)

        # Copy expected values from golden file as the "actual" result
        # Add slight randomization for stochastic testing
        local expected_exit expected_work expected_files
        expected_exit=$(jq -r '.expected.exit_signal // "true"' "$golden_file")
        expected_work=$(jq -r '.expected.work_type // "IMPLEMENTATION"' "$golden_file")
        expected_files=$(jq -r '.expected.files_modified // 0' "$golden_file")

        cat > "$mock_status" <<EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S')",
  "loop_count": 2,
  "status": "COMPLETE",
  "exit_signal": "$expected_exit",
  "tasks_completed": 1,
  "files_modified": $expected_files,
  "work_type": "$expected_work",
  "recommendation": "dry-run simulation"
}
EOF
        ralph_compare_golden "$golden_file" "$mock_status" > /dev/null 2>&1
        local result=$?
        rm -f "$mock_status"
        return $result
    fi

    # Real run: invoke Ralph in the project directory
    local ralph_cmd="${RALPH_CMD:-ralph}"
    local status_json="$project_dir/.ralph/status.json"

    # Run Ralph with --dry-run or real execution
    if ! (cd "$project_dir" && "$ralph_cmd" --max-loops 1 2>/dev/null); then
        echo "WARN: Ralph run $run_index failed to execute" >&2
        return 1
    fi

    if [[ ! -f "$status_json" ]]; then
        echo "WARN: No status.json produced by run $run_index" >&2
        return 1
    fi

    ralph_compare_golden "$golden_file" "$status_json" > /dev/null 2>&1
    return $?
}

# Run stochastic evaluation of a golden file.
#
# Runs the eval N times and determines overall result based on pass rate:
#   - PASS: pass_rate >= RALPH_EVAL_PASS_THRESHOLD (default 80%)
#   - FAIL: pass_rate < RALPH_EVAL_FAIL_THRESHOLD (default 20%)
#   - INCONCLUSIVE: pass_rate between thresholds
#
# Args:
#   $1 - golden_file: path to the golden file JSON
#
# Output: prints detailed results to stdout, appends JSONL to results file
#
# Returns: 0=PASS, 1=FAIL, 2=INCONCLUSIVE
ralph_eval_stochastic() {
    local golden_file="${1:?golden_file path required}"

    if [[ ! -f "$golden_file" ]]; then
        echo "ERROR: Golden file not found: $golden_file" >&2
        return 1
    fi

    local eval_id
    eval_id=$(jq -r '.id // "unknown"' "$golden_file")
    local eval_desc
    eval_desc=$(jq -r '.description // ""' "$golden_file")

    echo "=== Stochastic Eval: $eval_id ==="
    echo "Description: $eval_desc"
    echo "Runs: $RALPH_EVAL_RUNS | Pass threshold: $RALPH_EVAL_PASS_THRESHOLD | Fail threshold: $RALPH_EVAL_FAIL_THRESHOLD"
    echo ""

    local passes=0
    local fails=0
    local inconclusives=0
    local run_results=()

    for ((i=1; i<=RALPH_EVAL_RUNS; i++)); do
        echo -n "  Run $i/$RALPH_EVAL_RUNS: "

        local run_result
        set +e
        _ralph_single_eval_run "$golden_file" "$i"
        run_result=$?
        set -e

        case $run_result in
            0)
                echo "PASS"
                passes=$((passes + 1))
                run_results+=("PASS")
                ;;
            1)
                echo "FAIL"
                fails=$((fails + 1))
                run_results+=("FAIL")
                ;;
            2)
                echo "INCONCLUSIVE"
                inconclusives=$((inconclusives + 1))
                run_results+=("INCONCLUSIVE")
                ;;
        esac
    done

    # Calculate pass rate (passes + inconclusives count as half-pass for rate)
    local total="$RALPH_EVAL_RUNS"
    local pass_rate
    pass_rate=$(awk -v p="$passes" -v n="$total" 'BEGIN { printf "%.4f", (n > 0) ? p/n : 0 }')

    # Calculate Wilson score confidence interval
    local ci
    ci=$(ralph_eval_confidence_interval "$passes" "$total")
    local ci_lower ci_upper
    ci_lower=$(echo "$ci" | awk '{print $1}')
    ci_upper=$(echo "$ci" | awk '{print $2}')

    # Determine overall result
    local overall_result
    local overall_code
    if awk -v rate="$pass_rate" -v threshold="$RALPH_EVAL_PASS_THRESHOLD" 'BEGIN { exit !(rate >= threshold) }'; then
        overall_result="PASS"
        overall_code=0
    elif awk -v rate="$pass_rate" -v threshold="$RALPH_EVAL_FAIL_THRESHOLD" 'BEGIN { exit !(rate < threshold) }'; then
        overall_result="FAIL"
        overall_code=1
    else
        overall_result="INCONCLUSIVE"
        overall_code=2
    fi

    echo ""
    echo "--- Results ---"
    echo "  Passes: $passes/$total"
    echo "  Fails: $fails/$total"
    echo "  Inconclusive: $inconclusives/$total"
    echo "  Pass rate: $pass_rate"
    echo "  95% CI: [$ci_lower, $ci_upper]"
    echo "  Overall: $overall_result"

    # Store results in JSONL for trend analysis
    mkdir -p "$RALPH_EVAL_RESULTS_DIR"
    local results_file="$RALPH_EVAL_RESULTS_DIR/stochastic_results.jsonl"
    local run_results_json
    run_results_json=$(printf '%s\n' "${run_results[@]}" | jq -R . | jq -s .)
    local timestamp
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S')

    local result_entry
    result_entry=$(jq -cn \
        --arg id "$eval_id" \
        --arg ts "$timestamp" \
        --argjson runs "$RALPH_EVAL_RUNS" \
        --argjson passes "$passes" \
        --argjson fails "$fails" \
        --argjson inconclusives "$inconclusives" \
        --arg pass_rate "$pass_rate" \
        --arg ci_lower "$ci_lower" \
        --arg ci_upper "$ci_upper" \
        --arg result "$overall_result" \
        --argjson run_results "$run_results_json" \
        '{
            eval_id: $id,
            timestamp: $ts,
            total_runs: $runs,
            passes: $passes,
            fails: $fails,
            inconclusives: $inconclusives,
            pass_rate: ($pass_rate | tonumber),
            confidence_interval: { lower: ($ci_lower | tonumber), upper: ($ci_upper | tonumber) },
            overall_result: $result,
            run_results: $run_results
        }')

    echo "$result_entry" >> "$results_file"
    echo ""
    echo "Results appended to: $results_file"

    return "$overall_code"
}

# If run directly (not sourced), execute with CLI args
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ $# -lt 1 ]]; then
        echo "Usage: $0 <golden_file.json> [project_dir]"
        echo ""
        echo "Runs stochastic evaluation of a golden file."
        echo ""
        echo "Environment variables:"
        echo "  RALPH_EVAL_RUNS            - number of runs (default: 3)"
        echo "  RALPH_EVAL_PASS_THRESHOLD  - pass rate >= this = PASS (default: 0.8)"
        echo "  RALPH_EVAL_FAIL_THRESHOLD  - pass rate < this = FAIL (default: 0.2)"
        echo "  RALPH_EVAL_RESULTS_DIR     - JSONL results directory (default: tests/evals/results)"
        echo "  RALPH_EVAL_PROJECT_DIR     - project directory for Ralph runs"
        echo "  RALPH_EVAL_DRY_RUN         - 'true' to simulate without Ralph calls"
        echo ""
        echo "Exit codes:"
        echo "  0 = PASS          - pass rate >= threshold"
        echo "  1 = FAIL          - pass rate < fail threshold"
        echo "  2 = INCONCLUSIVE  - pass rate between thresholds"
        exit 1
    fi

    if [[ -n "${2:-}" ]]; then
        export RALPH_EVAL_PROJECT_DIR="$2"
    fi

    ralph_eval_stochastic "$1"
fi
