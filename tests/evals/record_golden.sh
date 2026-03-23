#!/usr/bin/env bash
# tests/evals/record_golden.sh
# Records golden files from successful Ralph runs.
# Usage: source this file and call ralph_record_golden <eval_id> <description>
#   or run directly: ./record_golden.sh <eval_id> <description> [status_json_path]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GOLDEN_DIR="$SCRIPT_DIR/golden"

# Get Ralph version from package.json or ralph_loop.sh
_ralph_get_version() {
    local project_root
    project_root="$(cd "$SCRIPT_DIR/../.." && pwd)"

    # Try package.json first
    if [[ -f "$project_root/package.json" ]]; then
        local ver
        ver=$(jq -r '.version // "unknown"' "$project_root/package.json" 2>/dev/null || echo "unknown")
        if [[ "$ver" != "unknown" && -n "$ver" ]]; then
            echo "$ver"
            return
        fi
    fi

    # Fallback to ralph_loop.sh
    if [[ -f "$project_root/ralph_loop.sh" ]]; then
        grep -m1 'RALPH_VERSION=' "$project_root/ralph_loop.sh" 2>/dev/null \
            | sed 's/.*RALPH_VERSION="\{0,1\}\([^"]*\)"\{0,1\}/\1/' \
            | tr -d '\r\n[:space:]' || echo "unknown"
        return
    fi

    echo "unknown"
}

# Extract golden file data from a status.json and project context.
#
# Args:
#   $1 - eval_id: unique identifier for this golden file (e.g., "simple-fix-001")
#   $2 - description: human-readable description of the eval scenario
#   $3 - status_json_path (optional): path to .ralph/status.json. Defaults to .ralph/status.json in cwd.
#   $4 - fix_plan_path (optional): path to .ralph/fix_plan.md. Defaults to .ralph/fix_plan.md in cwd.
#
# Environment variables (optional overrides):
#   RALPH_EVAL_PROJECT_TYPE - project type (default: inferred or "generic")
#   RALPH_EVAL_FILE_COUNT - number of files in project (default: counted from git)
#   RALPH_EVAL_MAX_ITERATIONS - expected max iterations (default: from status.json loop_count)
#   RALPH_EVAL_MAX_TOKENS - expected max tokens (default: 0 = not tracked)
#   RALPH_EVAL_TOOL_INCLUDES - comma-separated tool names that MUST appear in sequence
#   RALPH_EVAL_TOOL_EXCLUDES - comma-separated tool names that MUST NOT appear in sequence
#
# Output: writes golden file JSON to golden/<eval_id>.json
ralph_record_golden() {
    local eval_id="${1:?eval_id required}"
    local description="${2:?description required}"
    local status_json="${3:-.ralph/status.json}"
    local fix_plan="${4:-.ralph/fix_plan.md}"

    # Validate inputs
    if [[ ! -f "$status_json" ]]; then
        echo "ERROR: status.json not found at $status_json" >&2
        return 1
    fi

    # Extract fields from status.json
    local exit_signal work_type files_modified loop_count
    exit_signal=$(jq -r '.exit_signal // "false"' "$status_json")
    work_type=$(jq -r '.work_type // "UNKNOWN"' "$status_json")
    files_modified=$(jq -r '.files_modified // 0' "$status_json")
    loop_count=$(jq -r '.loop_count // 0' "$status_json")

    # Infer project type
    local project_type="${RALPH_EVAL_PROJECT_TYPE:-generic}"
    if [[ "$project_type" == "generic" ]]; then
        if [[ -f "package.json" ]]; then
            project_type="node"
        elif [[ -f "requirements.txt" ]] || [[ -f "pyproject.toml" ]]; then
            project_type="python"
        elif [[ -f "Cargo.toml" ]]; then
            project_type="rust"
        elif [[ -f "go.mod" ]]; then
            project_type="go"
        fi
    fi

    # Count files
    local file_count="${RALPH_EVAL_FILE_COUNT:-0}"
    if [[ "$file_count" == "0" ]]; then
        file_count=$(git ls-files 2>/dev/null | wc -l | tr -d '[:space:]' || echo "0")
    fi

    # Extract fix plan task description
    local fix_plan_task=""
    if [[ -f "$fix_plan" ]]; then
        # Get first unchecked task or first task
        fix_plan_task=$(grep -m1 '^\- \[ \]' "$fix_plan" 2>/dev/null | sed 's/^- \[ \] //' || \
                       grep -m1 '^\- \[x\]' "$fix_plan" 2>/dev/null | sed 's/^- \[x\] //' || \
                       echo "")
    fi

    # Build tool sequence arrays
    local tool_includes="${RALPH_EVAL_TOOL_INCLUDES:-}"
    local tool_excludes="${RALPH_EVAL_TOOL_EXCLUDES:-}"
    local includes_json="[]"
    local excludes_json="[]"

    if [[ -n "$tool_includes" ]]; then
        includes_json=$(echo "$tool_includes" | tr ',' '\n' | jq -R . | jq -s .)
    fi
    if [[ -n "$tool_excludes" ]]; then
        excludes_json=$(echo "$tool_excludes" | tr ',' '\n' | jq -R . | jq -s .)
    fi

    local max_iterations="${RALPH_EVAL_MAX_ITERATIONS:-$loop_count}"
    local max_tokens="${RALPH_EVAL_MAX_TOKENS:-0}"
    local ralph_version
    ralph_version=$(_ralph_get_version)
    local recorded_at
    recorded_at=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date '+%Y-%m-%dT%H:%M:%S')

    # Ensure golden directory exists
    mkdir -p "$GOLDEN_DIR"

    # Write golden file
    local golden_file="$GOLDEN_DIR/${eval_id}.json"
    cat > "$golden_file" <<GOLDEN_EOF
{
  "id": "${eval_id}",
  "description": $(echo "$description" | jq -Rs .),
  "recorded_at": "${recorded_at}",
  "ralph_version": "${ralph_version}",
  "input": {
    "fix_plan_task": $(echo "$fix_plan_task" | jq -Rs .),
    "project_type": "${project_type}",
    "file_count": ${file_count}
  },
  "expected": {
    "exit_signal": "${exit_signal}",
    "work_type": "${work_type}",
    "files_modified": ${files_modified},
    "tool_sequence_contains": ${includes_json},
    "tool_sequence_excludes": ${excludes_json},
    "max_iterations": ${max_iterations},
    "max_tokens": ${max_tokens}
  }
}
GOLDEN_EOF

    # Validate the output is valid JSON
    if ! jq empty "$golden_file" 2>/dev/null; then
        echo "ERROR: Generated golden file is not valid JSON" >&2
        rm -f "$golden_file"
        return 1
    fi

    echo "Golden file recorded: $golden_file"
    return 0
}

# If run directly (not sourced), execute with CLI args
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ $# -lt 2 ]]; then
        echo "Usage: $0 <eval_id> <description> [status_json_path] [fix_plan_path]"
        echo ""
        echo "Records a golden file from a successful Ralph run."
        echo ""
        echo "Environment variables:"
        echo "  RALPH_EVAL_PROJECT_TYPE    - project type (default: auto-detected)"
        echo "  RALPH_EVAL_FILE_COUNT      - file count (default: git ls-files)"
        echo "  RALPH_EVAL_MAX_ITERATIONS  - max iterations (default: from status.json)"
        echo "  RALPH_EVAL_MAX_TOKENS      - max tokens (default: 0)"
        echo "  RALPH_EVAL_TOOL_INCLUDES   - comma-separated required tools"
        echo "  RALPH_EVAL_TOOL_EXCLUDES   - comma-separated forbidden tools"
        exit 1
    fi

    ralph_record_golden "$@"
fi
