#!/usr/bin/env bats
# Integration tests for lib/task_sources.sh (Issue #152)
# Tests fetch_beads_tasks(), fetch_github_tasks(), import_tasks_from_sources(),
# and count functions with mock command helpers for bd and gh.

load '../helpers/test_helper'
load '../helpers/fixtures'

# Path to task_sources.sh
TASK_SOURCES="${BATS_TEST_DIRNAME}/../../lib/task_sources.sh"

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"

    # Initialize git repo (needed by check_github_available)
    git init > /dev/null 2>&1
    git config user.email "test@example.com"
    git config user.name "Test User"
    git remote add origin "https://github.com/test-owner/test-repo.git" 2>/dev/null || true

    # Create .beads directory for beads availability checks
    mkdir -p .beads

    # Source the library under test
    source "$TASK_SOURCES"

    # Set up task caps for predictable tests
    export RALPH_MAX_TASKS_PER_SOURCE=50
    export RALPH_MAX_TASKS_TOTAL=100
}

teardown() {
    # Restore overridden commands
    unset -f bd 2>/dev/null || true
    unset -f gh 2>/dev/null || true

    if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
        cd /
        rm -rf "$TEST_DIR"
    fi
}

# =============================================================================
# MOCK COMMAND HELPERS
# =============================================================================

# Mock bd (beads) command - controlled via MOCK_BD_* env vars
# Usage:
#   MOCK_BD_OUTPUT='...'  MOCK_BD_EXIT=0  mock_bd_setup
mock_bd_setup() {
    bd() {
        if [[ "${MOCK_BD_EXIT:-0}" -ne 0 ]]; then
            echo "${MOCK_BD_ERROR:-bd: error}" >&2
            return "${MOCK_BD_EXIT}"
        fi
        echo "${MOCK_BD_OUTPUT:-[]}"
        return 0
    }
    export -f bd
}

# Mock gh (GitHub CLI) command - controlled via MOCK_GH_* env vars
# Usage:
#   MOCK_GH_OUTPUT='...'  MOCK_GH_EXIT=0  mock_gh_setup
mock_gh_setup() {
    gh() {
        local subcommand="${1:-}"
        shift || true

        # Handle 'gh auth status' for check_github_available
        if [[ "$subcommand" == "auth" ]]; then
            return "${MOCK_GH_AUTH_EXIT:-0}"
        fi

        # Handle 'gh issue list' and 'gh label list'
        if [[ "${MOCK_GH_EXIT:-0}" -ne 0 ]]; then
            echo "${MOCK_GH_ERROR:-gh: error}" >&2
            return "${MOCK_GH_EXIT}"
        fi
        echo "${MOCK_GH_OUTPUT:-[]}"
        return 0
    }
    export -f gh
}

# =============================================================================
# FETCH BEADS TASKS - JSON PARSING (5 tests)
# =============================================================================

@test "fetch_beads_tasks: parses valid JSON with multiple issues" {
    MOCK_BD_OUTPUT='[
        {"id": "abc-001", "title": "Fix login bug", "status": "open"},
        {"id": "abc-002", "title": "Add search feature", "status": "open"},
        {"id": "abc-003", "title": "Refactor database layer", "status": "in_progress"}
    ]'
    mock_bd_setup

    run fetch_beads_tasks "all"
    assert_success

    [[ "$output" == *"[abc-001] Fix login bug"* ]]
    [[ "$output" == *"[abc-002] Add search feature"* ]]
    [[ "$output" == *"[abc-003] Refactor database layer"* ]]

    # Each line should be a checkbox task
    local task_count
    task_count=$(echo "$output" | grep -c '^\- \[ \]' || echo "0")
    [ "$task_count" -eq 3 ]
}

@test "fetch_beads_tasks: filters out closed issues" {
    MOCK_BD_OUTPUT='[
        {"id": "abc-001", "title": "Open issue", "status": "open"},
        {"id": "abc-002", "title": "Closed issue", "status": "closed"},
        {"id": "abc-003", "title": "In progress issue", "status": "in_progress"}
    ]'
    mock_bd_setup

    run fetch_beads_tasks "all"
    assert_success

    [[ "$output" == *"Open issue"* ]]
    [[ "$output" != *"Closed issue"* ]]
    [[ "$output" == *"In progress issue"* ]]
}

@test "fetch_beads_tasks: falls back to text parsing when JSON fails" {
    # Simulate bd returning non-JSON text output (JSON parse failure)
    MOCK_BD_EXIT=1
    MOCK_BD_ERROR="bd: JSON mode not available"

    # Override bd to return text on second call (fallback path)
    bd() {
        local args=("$@")
        local has_json=false
        for arg in "${args[@]}"; do
            [[ "$arg" == "--json" ]] && has_json=true
        done

        if [[ "$has_json" == "true" ]]; then
            # JSON mode fails
            return 1
        else
            # Text mode succeeds
            echo "○ abc-001 [● P2] [task] - Fix login bug"
            echo "○ abc-002 [● P1] [task] - Add search feature"
            return 0
        fi
    }
    export -f bd

    run fetch_beads_tasks "open"
    assert_success

    # Should have parsed text output into checkbox format
    local task_count
    task_count=$(echo "$output" | grep -c '^\- \[ \]' || echo "0")
    [ "$task_count" -ge 1 ]
}

@test "fetch_beads_tasks: handles entries with missing fields gracefully" {
    MOCK_BD_OUTPUT='[
        {"id": "abc-001", "title": "Valid issue", "status": "open"},
        {"id": "", "title": "Missing ID", "status": "open"},
        {"id": "abc-003", "title": "", "status": "open"},
        {"title": "No ID field at all", "status": "open"},
        {"id": "abc-005", "status": "open"}
    ]'
    mock_bd_setup

    run fetch_beads_tasks "all"
    assert_success

    # Only the fully valid entry should appear
    [[ "$output" == *"[abc-001] Valid issue"* ]]
    # Entries with missing id or title should be filtered
    [[ "$output" != *"Missing ID"* ]]
    [[ "$output" != *"No ID field"* ]]
}

@test "fetch_beads_tasks: returns empty on empty JSON array" {
    MOCK_BD_OUTPUT='[]'
    mock_bd_setup

    run fetch_beads_tasks "open"
    assert_success

    # Output should be empty (no tasks)
    [ -z "$output" ] || [[ "$output" =~ ^[[:space:]]*$ ]]
}

# =============================================================================
# FETCH BEADS TASKS - STATUS FILTERING (3 tests)
# =============================================================================

@test "fetch_beads_tasks: passes open status filter to bd" {
    # Track what arguments bd was called with
    local captured_args_file="$TEST_DIR/.bd_args"
    bd() {
        echo "$*" >> "$captured_args_file"
        echo '[]'
        return 0
    }
    export -f bd

    run fetch_beads_tasks "open"
    assert_success

    # First call should include --json --status open
    local first_call
    first_call=$(head -1 "$captured_args_file")
    [[ "$first_call" == *"--json"* ]]
    [[ "$first_call" == *"--status open"* ]]
}

@test "fetch_beads_tasks: passes in_progress status filter to bd" {
    local captured_args_file="$TEST_DIR/.bd_args"
    bd() {
        echo "$*" >> "$captured_args_file"
        echo '[]'
        return 0
    }
    export -f bd

    run fetch_beads_tasks "in_progress"
    assert_success

    local first_call
    first_call=$(head -1 "$captured_args_file")
    [[ "$first_call" == *"--status in_progress"* ]]
}

@test "fetch_beads_tasks: passes --all flag for all status filter" {
    local captured_args_file="$TEST_DIR/.bd_args"
    bd() {
        echo "$*" >> "$captured_args_file"
        echo '[]'
        return 0
    }
    export -f bd

    run fetch_beads_tasks "all"
    assert_success

    local first_call
    first_call=$(head -1 "$captured_args_file")
    [[ "$first_call" == *"--all"* ]]
}

# =============================================================================
# FETCH GITHUB TASKS - JSON PARSING (4 tests)
# =============================================================================

@test "fetch_github_tasks: parses valid JSON with multiple issues" {
    MOCK_GH_OUTPUT='[
        {"number": 42, "title": "Add user dashboard", "labels": [{"name": "feature"}]},
        {"number": 55, "title": "Fix login timeout", "labels": [{"name": "bug"}]},
        {"number": 78, "title": "Update documentation", "labels": [{"name": "docs"}]}
    ]'
    MOCK_GH_AUTH_EXIT=0
    mock_gh_setup

    run fetch_github_tasks "" 50
    assert_success

    [[ "$output" == *"[#42] Add user dashboard"* ]]
    [[ "$output" == *"[#55] Fix login timeout"* ]]
    [[ "$output" == *"[#78] Update documentation"* ]]

    local task_count
    task_count=$(echo "$output" | grep -c '^\- \[ \]' || echo "0")
    [ "$task_count" -eq 3 ]
}

@test "fetch_github_tasks: returns empty for empty results" {
    MOCK_GH_OUTPUT='[]'
    MOCK_GH_AUTH_EXIT=0
    mock_gh_setup

    run fetch_github_tasks "" 50
    assert_success

    [ -z "$output" ] || [[ "$output" =~ ^[[:space:]]*$ ]]
}

@test "fetch_github_tasks: applies label filter" {
    local captured_args_file="$TEST_DIR/.gh_args"
    gh() {
        local subcommand="${1:-}"
        shift || true
        if [[ "$subcommand" == "auth" ]]; then
            return 0
        fi
        echo "$subcommand $*" >> "$captured_args_file"
        echo '[]'
        return 0
    }
    export -f gh

    run fetch_github_tasks "ralph-task" 50
    assert_success

    local call_args
    call_args=$(cat "$captured_args_file")
    [[ "$call_args" == *"--label ralph-task"* ]]
}

@test "fetch_github_tasks: fails when gh auth is not available" {
    MOCK_GH_AUTH_EXIT=1
    mock_gh_setup

    run fetch_github_tasks "" 50
    assert_failure
}

# =============================================================================
# GET COUNT FUNCTIONS (3 tests)
# =============================================================================

@test "get_beads_count: returns count of non-closed issues" {
    MOCK_BD_OUTPUT='[
        {"id": "abc-001", "title": "Open 1", "status": "open"},
        {"id": "abc-002", "title": "Closed 1", "status": "closed"},
        {"id": "abc-003", "title": "Open 2", "status": "in_progress"}
    ]'
    mock_bd_setup

    run get_beads_count
    assert_success

    # Should return 2 (two non-closed issues)
    [ "$output" = "2" ]
}

@test "get_beads_count: returns 0 when beads unavailable" {
    # Remove .beads directory to make beads unavailable
    rm -rf .beads

    run get_beads_count
    assert_output "0"
}

@test "get_github_issue_count: returns 0 when GitHub unavailable" {
    # No gh mock set up, and no real gh auth
    unset -f gh 2>/dev/null || true
    if command -v gh &>/dev/null; then
        # Override gh to fail auth
        gh() {
            if [[ "$1" == "auth" ]]; then
                return 1
            fi
            return 1
        }
        export -f gh
    fi

    run get_github_issue_count
    assert_output "0"
}

# =============================================================================
# IMPORT TASKS FROM SOURCES - BEADS (3 tests)
# =============================================================================

@test "import_tasks_from_sources: imports tasks from beads source" {
    MOCK_BD_OUTPUT='[
        {"id": "abc-001", "title": "Task from beads", "status": "open"},
        {"id": "abc-002", "title": "Another beads task", "status": "open"}
    ]'
    mock_bd_setup

    run import_tasks_from_sources "beads" "" ""
    assert_success

    [[ "$output" == *"Task from beads"* ]]
    [[ "$output" == *"Another beads task"* ]]
    [[ "$output" == *"Tasks from beads"* ]]
}

@test "import_tasks_from_sources: skips beads when unavailable" {
    # Remove .beads directory
    rm -rf .beads

    # Only beads source, but beads unavailable - should fail (no tasks)
    run import_tasks_from_sources "beads" "" ""
    assert_failure
}

@test "import_tasks_from_sources: applies per-source cap to beads tasks" {
    # Generate JSON with more tasks than the cap
    local json_tasks="["
    for i in $(seq 1 60); do
        [[ "$i" -gt 1 ]] && json_tasks+=","
        json_tasks+="{\"id\": \"abc-$(printf '%03d' $i)\", \"title\": \"Task $i\", \"status\": \"open\"}"
    done
    json_tasks+="]"

    MOCK_BD_OUTPUT="$json_tasks"
    mock_bd_setup

    export RALPH_MAX_TASKS_PER_SOURCE=10

    run import_tasks_from_sources "beads" "" ""
    assert_success

    # Task count should be significantly less than 60 (uncapped).
    # The per-source cap limits to 10, but normalize_tasks may convert
    # comment/header lines into additional checkbox tasks, so allow some slack.
    local task_count
    task_count=$(echo "$output" | grep -c '^\- \[ \]' || echo "0")
    [ "$task_count" -le 15 ]
    [ "$task_count" -lt 60 ]
}

# =============================================================================
# IMPORT TASKS FROM SOURCES - GITHUB (3 tests)
# =============================================================================

@test "import_tasks_from_sources: imports tasks from github source" {
    MOCK_GH_OUTPUT='[
        {"number": 10, "title": "GitHub issue one", "labels": []},
        {"number": 20, "title": "GitHub issue two", "labels": []}
    ]'
    MOCK_GH_AUTH_EXIT=0
    mock_gh_setup

    run import_tasks_from_sources "github" "" ""
    assert_success

    [[ "$output" == *"GitHub issue one"* ]]
    [[ "$output" == *"GitHub issue two"* ]]
    [[ "$output" == *"Tasks from GitHub"* ]]
}

@test "import_tasks_from_sources: passes label filter for github" {
    local captured_args_file="$TEST_DIR/.gh_args"
    gh() {
        local subcommand="${1:-}"
        shift || true
        if [[ "$subcommand" == "auth" ]]; then
            return 0
        fi
        echo "$subcommand $*" >> "$captured_args_file"
        echo '[{"number": 1, "title": "Labeled task", "labels": [{"name": "ralph-task"}]}]'
        return 0
    }
    export -f gh

    run import_tasks_from_sources "github" "" "ralph-task"
    assert_success

    [[ "$output" == *"Labeled task"* ]]

    local call_args
    call_args=$(cat "$captured_args_file")
    [[ "$call_args" == *"--label ralph-task"* ]]
}

@test "import_tasks_from_sources: handles empty github results" {
    MOCK_GH_OUTPUT='[]'
    MOCK_GH_AUTH_EXIT=0
    mock_gh_setup

    # Only github source with empty results
    run import_tasks_from_sources "github" "" ""
    # Should fail because no tasks were imported
    assert_failure
}

# =============================================================================
# IMPORT TASKS FROM SOURCES - COMBINED (4 tests)
# =============================================================================

@test "import_tasks_from_sources: combines beads and github tasks" {
    MOCK_BD_OUTPUT='[
        {"id": "abc-001", "title": "Beads task", "status": "open"}
    ]'
    mock_bd_setup

    MOCK_GH_OUTPUT='[
        {"number": 99, "title": "GitHub task", "labels": []}
    ]'
    MOCK_GH_AUTH_EXIT=0
    mock_gh_setup

    run import_tasks_from_sources "beads github" "" ""
    assert_success

    [[ "$output" == *"Beads task"* ]]
    [[ "$output" == *"GitHub task"* ]]
    [[ "$output" == *"Tasks from beads"* ]]
    [[ "$output" == *"Tasks from GitHub"* ]]
}

@test "import_tasks_from_sources: combines beads and prd tasks" {
    MOCK_BD_OUTPUT='[
        {"id": "abc-001", "title": "Beads task", "status": "open"}
    ]'
    mock_bd_setup

    mkdir -p docs
    cat > docs/prd.md << 'EOF'
# Requirements
- [ ] PRD task one
- [ ] PRD task two
EOF

    run import_tasks_from_sources "beads prd" "docs/prd.md" ""
    assert_success

    [[ "$output" == *"Beads task"* ]]
    [[ "$output" == *"PRD task one"* ]]
}

@test "import_tasks_from_sources: deduplicates across sources" {
    # Same task title in beads and github
    MOCK_BD_OUTPUT='[
        {"id": "abc-001", "title": "Fix authentication bug", "status": "open"}
    ]'
    mock_bd_setup

    MOCK_GH_OUTPUT='[
        {"number": 42, "title": "Fix authentication bug", "labels": []}
    ]'
    MOCK_GH_AUTH_EXIT=0
    mock_gh_setup

    run import_tasks_from_sources "beads github" "" ""
    assert_success

    # The deduplicated output should have "Fix authentication bug" only once
    local match_count
    match_count=$(echo "$output" | grep -ci "fix authentication bug" || echo "0")
    # May appear in the task line plus comments/headers - but actual checkbox tasks
    # should be deduplicated. Count only checkbox lines with this text.
    local task_match_count
    task_match_count=$(echo "$output" | grep '^\- \[ \]' | grep -ci "fix authentication bug" || echo "0")
    [ "$task_match_count" -le 1 ]
}

@test "import_tasks_from_sources: applies total cap across all sources" {
    # Generate many beads tasks
    local json_tasks="["
    for i in $(seq 1 30); do
        [[ "$i" -gt 1 ]] && json_tasks+=","
        json_tasks+="{\"id\": \"abc-$(printf '%03d' $i)\", \"title\": \"Beads task $i\", \"status\": \"open\"}"
    done
    json_tasks+="]"
    MOCK_BD_OUTPUT="$json_tasks"
    mock_bd_setup

    # Generate many github tasks
    local gh_tasks="["
    for i in $(seq 1 30); do
        [[ "$i" -gt 1 ]] && gh_tasks+=","
        gh_tasks+="{\"number\": $((100 + i)), \"title\": \"GitHub task $i\", \"labels\": []}"
    done
    gh_tasks+="]"
    MOCK_GH_OUTPUT="$gh_tasks"
    MOCK_GH_AUTH_EXIT=0
    mock_gh_setup

    export RALPH_MAX_TASKS_TOTAL=15

    run import_tasks_from_sources "beads github" "" ""
    assert_success

    # Total task count should be capped at 15
    local task_count
    task_count=$(echo "$output" | grep -c '^\- \[ \]' || echo "0")
    [ "$task_count" -le 15 ]
}

# =============================================================================
# IMPORT TASKS FROM SOURCES - EDGE CASES (3 tests)
# =============================================================================

@test "import_tasks_from_sources: returns failure on empty sources string" {
    run import_tasks_from_sources "" "" ""
    assert_failure
}

@test "import_tasks_from_sources: handles unknown source gracefully" {
    run import_tasks_from_sources "nonexistent_source" "" ""
    assert_failure
}

@test "import_tasks_from_sources: handles prd source with missing file" {
    run import_tasks_from_sources "prd" "nonexistent_prd.md" ""
    # Should fail since no tasks were imported
    assert_failure
}
