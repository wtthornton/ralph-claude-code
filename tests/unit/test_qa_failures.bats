#!/usr/bin/env bats

# Tests for lib/qa_failures.sh — QA failure state tracking

setup() {
    export RALPH_DIR="$BATS_TEST_TMPDIR/.ralph"
    mkdir -p "$RALPH_DIR"
    source "$BATS_TEST_DIRNAME/../../lib/qa_failures.sh"
}

teardown() {
    rm -rf "$BATS_TEST_TMPDIR/.ralph"
}

@test "qa_failures_path returns correct path" {
    local path
    path=$(qa_failures_path)
    [[ "$path" == *"/.qa_failures.json" ]]
}

@test "qa_failures_init creates empty state file if missing" {
    qa_failures_init
    local state_file
    state_file=$(qa_failures_path)
    [[ -f "$state_file" ]]
    grep -q "{}" "$state_file"
}

@test "qa_failures_init does not overwrite existing state" {
    local state_file
    state_file=$(qa_failures_path)
    echo '{"TAP-123": 2}' > "$state_file"
    qa_failures_init
    grep -q "TAP-123" "$state_file"
}

@test "qa_failures_increment creates first entry for issue" {
    local count
    count=$(qa_failures_increment "TAP-123")
    [[ "$count" -eq 1 ]]
}

@test "qa_failures_increment returns 2 on second call" {
    qa_failures_increment "TAP-123" > /dev/null
    local count
    count=$(qa_failures_increment "TAP-123")
    [[ "$count" -eq 2 ]]
}

@test "qa_failures_increment returns 3 on third call" {
    qa_failures_increment "TAP-123" > /dev/null
    qa_failures_increment "TAP-123" > /dev/null
    local count
    count=$(qa_failures_increment "TAP-123")
    [[ "$count" -eq 3 ]]
}

@test "qa_failures_increment tracks multiple issues independently" {
    qa_failures_increment "TAP-123" > /dev/null
    qa_failures_increment "TAP-456" > /dev/null
    qa_failures_increment "TAP-123" > /dev/null
    local count_123
    local count_456
    count_123=$(qa_failures_get "TAP-123")
    count_456=$(qa_failures_get "TAP-456")
    [[ "$count_123" -eq 2 ]]
    [[ "$count_456" -eq 1 ]]
}

@test "qa_failures_get returns 0 for unknown issue" {
    qa_failures_init
    local count
    count=$(qa_failures_get "TAP-999")
    [[ "$count" -eq 0 ]]
}

@test "qa_failures_get returns current count for tracked issue" {
    qa_failures_increment "TAP-123" > /dev/null
    qa_failures_increment "TAP-123" > /dev/null
    local count
    count=$(qa_failures_get "TAP-123")
    [[ "$count" -eq 2 ]]
}

@test "qa_failures_reset clears count for issue" {
    qa_failures_increment "TAP-123" > /dev/null
    qa_failures_increment "TAP-123" > /dev/null
    qa_failures_reset "TAP-123"
    local count
    count=$(qa_failures_get "TAP-123")
    [[ "$count" -eq 0 ]]
}

@test "qa_failures_reset does not affect other issues" {
    qa_failures_increment "TAP-123" > /dev/null
    qa_failures_increment "TAP-123" > /dev/null
    qa_failures_increment "TAP-456" > /dev/null
    qa_failures_reset "TAP-123"
    local count_456
    count_456=$(qa_failures_get "TAP-456")
    [[ "$count_456" -eq 1 ]]
}

@test "qa_failures_clear_all wipes all state" {
    qa_failures_increment "TAP-123" > /dev/null
    qa_failures_increment "TAP-456" > /dev/null
    qa_failures_clear_all
    local count_123
    local count_456
    count_123=$(qa_failures_get "TAP-123")
    count_456=$(qa_failures_get "TAP-456")
    [[ "$count_123" -eq 0 ]]
    [[ "$count_456" -eq 0 ]]
}

@test "qa_failures_dump prints empty state" {
    local dump
    dump=$(qa_failures_dump)
    [[ "$dump" == "{}" ]]
}

@test "qa_failures_dump prints current state as JSON" {
    qa_failures_increment "TAP-123" > /dev/null
    qa_failures_increment "TAP-456" > /dev/null
    local dump
    dump=$(qa_failures_dump)
    grep -q "TAP-123" <<< "$dump"
    grep -q "TAP-456" <<< "$dump"
}

@test "qa_failures_increment with empty issue_id returns error" {
    run qa_failures_increment ""
    [[ $status -ne 0 ]]
}

@test "qa_failures_get with empty issue_id returns error" {
    run qa_failures_get ""
    [[ $status -ne 0 ]]
}

@test "qa_failures_reset with empty issue_id returns error" {
    run qa_failures_reset ""
    [[ $status -ne 0 ]]
}

@test "qa_failures state is persisted across init calls" {
    qa_failures_increment "TAP-123" > /dev/null
    # Re-init (simulating new shell invocation)
    source "$BATS_TEST_DIRNAME/../../lib/qa_failures.sh"
    local count
    count=$(qa_failures_get "TAP-123")
    [[ "$count" -eq 1 ]]
}

@test "qa_failures works with hyphens in issue IDs" {
    qa_failures_increment "MY-PROJECT-456" > /dev/null
    local count
    count=$(qa_failures_get "MY-PROJECT-456")
    [[ "$count" -eq 1 ]]
}
