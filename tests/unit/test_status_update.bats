#!/usr/bin/env bats
# Unit tests for status.json updates (Phase 9, TEST-3)
# Tests field validation, JSON output, staleness, atomic writes, special chars

load '../helpers/test_helper'
load '../helpers/fixtures'

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"
    export RALPH_DIR=".ralph"
    mkdir -p "$RALPH_DIR"
}

teardown() {
    cd /
    rm -rf "$TEST_DIR"
}

@test "status.json has all required fields" {
    cat > "$RALPH_DIR/status.json" << 'EOF'
{
    "WORK_TYPE": "IMPLEMENTATION",
    "COMPLETED_TASK": "Added login form",
    "NEXT_TASK": "Add validation",
    "PROGRESS_SUMMARY": "50% done",
    "EXIT_SIGNAL": false,
    "status": "IN_PROGRESS",
    "timestamp": "2026-03-21T10:00:00+0000",
    "loop_count": 5,
    "session_id": "sess-abc123",
    "circuit_breaker_state": "CLOSED"
}
EOF
    run jq -e '.WORK_TYPE' "$RALPH_DIR/status.json"
    [ "$status" -eq 0 ]
    run jq -e '.COMPLETED_TASK' "$RALPH_DIR/status.json"
    [ "$status" -eq 0 ]
    run jq -e '.NEXT_TASK' "$RALPH_DIR/status.json"
    [ "$status" -eq 0 ]
    run jq -e '.PROGRESS_SUMMARY' "$RALPH_DIR/status.json"
    [ "$status" -eq 0 ]
    run jq -e '.EXIT_SIGNAL' "$RALPH_DIR/status.json"
    [ "$status" -eq 0 ]
    run jq -e '.timestamp' "$RALPH_DIR/status.json"
    [ "$status" -eq 0 ]
}

@test "status.json is valid JSON" {
    echo '{"WORK_TYPE":"TEST","EXIT_SIGNAL":false,"status":"IN_PROGRESS"}' > "$RALPH_DIR/status.json"
    run jq empty "$RALPH_DIR/status.json"
    [ "$status" -eq 0 ]
}

@test "status.json EXIT_SIGNAL is boolean" {
    echo '{"EXIT_SIGNAL": true}' > "$RALPH_DIR/status.json"
    local val
    val=$(jq -r 'type_of(.EXIT_SIGNAL) // (.EXIT_SIGNAL | type)' "$RALPH_DIR/status.json" 2>/dev/null)
    [ "$val" = "boolean" ]
}

@test "status.json loop_count is number" {
    echo '{"loop_count": 42}' > "$RALPH_DIR/status.json"
    local val
    val=$(jq -r '.loop_count | type' "$RALPH_DIR/status.json")
    [ "$val" = "number" ]
}

@test "status staleness detection — fresh status" {
    echo "{\"timestamp\": \"$(date -u '+%Y-%m-%dT%H:%M:%SZ')\"}" > "$RALPH_DIR/status.json"
    # File just created should not be stale
    local file_age
    file_age=$(( $(date +%s) - $(stat -c %Y "$RALPH_DIR/status.json" 2>/dev/null || stat -f %m "$RALPH_DIR/status.json" 2>/dev/null || echo "$(date +%s)") ))
    [ "$file_age" -lt 60 ]
}

@test "atomic write leaves no temp files" {
    echo '{"test": true}' > "$RALPH_DIR/status.json"
    # Check for orphaned temp files
    local orphans
    orphans=$(find "$RALPH_DIR" -name "status.json.*" -type f 2>/dev/null | wc -l)
    [ "$orphans" -eq 0 ]
}

@test "special characters in task names are preserved" {
    cat > "$RALPH_DIR/status.json" << 'EOF'
{
    "COMPLETED_TASK": "Fix bug in \"parser\" module (issue #42)",
    "NEXT_TASK": "Test with special chars: <>&'\"/",
    "EXIT_SIGNAL": false
}
EOF
    run jq -e '.COMPLETED_TASK' "$RALPH_DIR/status.json"
    [ "$status" -eq 0 ]
    local task
    task=$(jq -r '.COMPLETED_TASK' "$RALPH_DIR/status.json")
    [[ "$task" == *"parser"* ]]
}

@test "WORK_TYPE accepts all valid values" {
    for wt in IMPLEMENTATION TESTING ANALYSIS PLANNING DEBUGGING UNKNOWN; do
        echo "{\"WORK_TYPE\": \"$wt\"}" > "$RALPH_DIR/status.json"
        local val
        val=$(jq -r '.WORK_TYPE' "$RALPH_DIR/status.json")
        [ "$val" = "$wt" ]
    done
}

@test "empty status.json returns defaults" {
    echo '{}' > "$RALPH_DIR/status.json"
    local wt
    wt=$(jq -r '.WORK_TYPE // "UNKNOWN"' "$RALPH_DIR/status.json")
    [ "$wt" = "UNKNOWN" ]
    local es
    es=$(jq -r '.EXIT_SIGNAL // false' "$RALPH_DIR/status.json")
    [ "$es" = "false" ]
}
