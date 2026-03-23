#!/usr/bin/env bash
# tests/evals/stochastic/run_stochastic_suite.sh
# EVALS-3: Wrapper to run all golden files through the stochastic eval suite.
#
# Usage: ./run_stochastic_suite.sh [golden_dir] [project_dir]
#
# Iterates over all *.json files in the golden directory and runs
# ralph_eval_stochastic on each one. Prints a summary table at the end.
#
# Environment variables (passed through to ralph_eval_stochastic.sh):
#   RALPH_EVAL_RUNS            - number of runs per golden file (default: 3)
#   RALPH_EVAL_PASS_THRESHOLD  - pass rate threshold (default: 0.8)
#   RALPH_EVAL_FAIL_THRESHOLD  - fail rate threshold (default: 0.2)
#   RALPH_EVAL_RESULTS_DIR     - JSONL results directory
#   RALPH_EVAL_PROJECT_DIR     - project directory for Ralph runs
#   RALPH_EVAL_DRY_RUN         - 'true' to simulate without Ralph calls

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVALS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
STOCHASTIC_SCRIPT="$SCRIPT_DIR/ralph_eval_stochastic.sh"

# Defaults
GOLDEN_DIR="${1:-$EVALS_DIR/golden}"
RALPH_EVAL_PROJECT_DIR="${2:-${RALPH_EVAL_PROJECT_DIR:-.}}"
export RALPH_EVAL_PROJECT_DIR

# Validate
if [[ ! -d "$GOLDEN_DIR" ]]; then
    echo "ERROR: Golden directory not found: $GOLDEN_DIR" >&2
    exit 1
fi

if [[ ! -f "$STOCHASTIC_SCRIPT" ]]; then
    echo "ERROR: Stochastic eval script not found: $STOCHASTIC_SCRIPT" >&2
    exit 1
fi

# Find all golden files
golden_files=()
while IFS= read -r -d '' file; do
    golden_files+=("$file")
done < <(find "$GOLDEN_DIR" -name '*.json' -type f -print0 | sort -z)

if [[ ${#golden_files[@]} -eq 0 ]]; then
    echo "No golden files found in $GOLDEN_DIR"
    exit 0
fi

echo "=============================================="
echo "  RALPH Stochastic Eval Suite"
echo "=============================================="
echo "Golden files: ${#golden_files[@]}"
echo "Runs per eval: ${RALPH_EVAL_RUNS:-3}"
echo "Pass threshold: ${RALPH_EVAL_PASS_THRESHOLD:-0.8}"
echo "Dry run: ${RALPH_EVAL_DRY_RUN:-false}"
echo "=============================================="
echo ""

# Track results for summary
declare -a eval_ids=()
declare -a eval_results=()
total_pass=0
total_fail=0
total_inconclusive=0
total_evals=0

for golden_file in "${golden_files[@]}"; do
    total_evals=$((total_evals + 1))
    eval_id=$(jq -r '.id // "unknown"' "$golden_file")
    eval_ids+=("$eval_id")

    echo ""
    echo "----------------------------------------------"

    set +e
    bash "$STOCHASTIC_SCRIPT" "$golden_file"
    result=$?
    set -e

    case $result in
        0)
            eval_results+=("PASS")
            total_pass=$((total_pass + 1))
            ;;
        1)
            eval_results+=("FAIL")
            total_fail=$((total_fail + 1))
            ;;
        2)
            eval_results+=("INCONCLUSIVE")
            total_inconclusive=$((total_inconclusive + 1))
            ;;
        *)
            eval_results+=("ERROR")
            total_fail=$((total_fail + 1))
            ;;
    esac
done

# Print summary table
echo ""
echo ""
echo "=============================================="
echo "  SUMMARY"
echo "=============================================="
printf "  %-25s %s\n" "EVAL ID" "RESULT"
printf "  %-25s %s\n" "-------------------------" "--------"

for ((i=0; i<${#eval_ids[@]}; i++)); do
    printf "  %-25s %s\n" "${eval_ids[$i]}" "${eval_results[$i]}"
done

echo "  -------------------------  --------"
echo "  Total: $total_evals"
echo "  Pass: $total_pass"
echo "  Fail: $total_fail"
echo "  Inconclusive: $total_inconclusive"
echo "=============================================="

# Overall exit code
if [[ "$total_fail" -gt 0 ]]; then
    echo ""
    echo "SUITE RESULT: FAIL ($total_fail failures)"
    exit 1
elif [[ "$total_inconclusive" -gt 0 ]]; then
    echo ""
    echo "SUITE RESULT: INCONCLUSIVE ($total_inconclusive inconclusive)"
    exit 2
else
    echo ""
    echo "SUITE RESULT: PASS (all $total_pass evaluations passed)"
    exit 0
fi
