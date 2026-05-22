#!/usr/bin/env bats
# T5 / 2.16.0: lib/pending_merges.sh — async PR-merge queue.

bats_require_minimum_version 1.5.0

REPO_ROOT_FIXED="${BATS_TEST_DIRNAME}/../.."

setup() {
    export TEST_TEMP_DIR="$(mktemp -d "${BATS_TEST_TMPDIR:-/tmp}/pm.XXXXXX")"
    cd "$TEST_TEMP_DIR"
    mkdir -p .ralph
    export RALPH_DIR="$TEST_TEMP_DIR/.ralph"
    export PENDING_MERGES_FILE="$RALPH_DIR/pending-merges.json"
    # shellcheck disable=SC1090
    source "$REPO_ROOT_FIXED/lib/pending_merges.sh"
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR" 2>/dev/null || true
}

@test "T5: pending_merges_enabled honors RALPH_ASYNC_MERGE flag" {
    unset RALPH_ASYNC_MERGE
    run pending_merges_enabled
    [[ "$status" -eq 1 ]] || fail "expected disabled default, got $status"
    RALPH_ASYNC_MERGE=true run pending_merges_enabled
    [[ "$status" -eq 0 ]] || fail "expected enabled with flag=true, got $status"
}

@test "T5: pending_merges_init creates empty queue file" {
    run pending_merges_init
    [[ "$status" -eq 0 ]]
    [[ -s "$PENDING_MERGES_FILE" ]] || fail "queue file not created"
    local v
    v=$(jq -r '.version' "$PENDING_MERGES_FILE")
    [[ "$v" == "1" ]] || fail "wrong version: $v"
}

@test "T5: pending_merges_add appends an entry" {
    pending_merges_add 123 "TAP-1234" "feature/foo"
    local entry_count
    entry_count=$(jq '.entries | length' "$PENDING_MERGES_FILE")
    [[ "$entry_count" -eq 1 ]] || fail "expected 1 entry, got $entry_count"
    local pr
    pr=$(jq -r '.entries[0].pr_number' "$PENDING_MERGES_FILE")
    [[ "$pr" -eq 123 ]] || fail "wrong pr_number: $pr"
    local status_val
    status_val=$(jq -r '.entries[0].merge_status' "$PENDING_MERGES_FILE")
    [[ "$status_val" == "open" ]] || fail "wrong initial merge_status: $status_val"
}

@test "T5: pending_merges_add rejects invalid pr_number" {
    run pending_merges_add "notanumber" "TAP-1" "feature/foo"
    [[ "$status" -eq 1 ]] || fail "expected rc=1 for invalid pr_number, got $status"
}

@test "T5: pending_merges_count tracks open entries only" {
    pending_merges_add 1 "TAP-1" "feature/a"
    pending_merges_add 2 "TAP-2" "feature/b"
    pending_merges_add 3 "TAP-3" "feature/c"
    local n
    n=$(pending_merges_count)
    [[ "$n" -eq 3 ]] || fail "expected 3, got $n"
    # Mark one merged via direct jq surgery to simulate post-poll state
    local upd
    upd=$(jq '(.entries[] | select(.pr_number == 2) | .merge_status) = "merged"' "$PENDING_MERGES_FILE")
    echo "$upd" > "$PENDING_MERGES_FILE"
    n=$(pending_merges_count)
    [[ "$n" -eq 2 ]] || fail "expected 2 after marking one merged, got $n"
}

@test "T5: pending_merges_add returns 2 when queue is at cap" {
    RALPH_ASYNC_MERGE_MAX_PENDING=2 pending_merges_add 1 "TAP-1" "feature/a"
    RALPH_ASYNC_MERGE_MAX_PENDING=2 pending_merges_add 2 "TAP-2" "feature/b"
    RALPH_ASYNC_MERGE_MAX_PENDING=2 run pending_merges_add 3 "TAP-3" "feature/c"
    [[ "$status" -eq 2 ]] || fail "expected rc=2 at cap, got $status"
    local n
    n=$(pending_merges_count)
    [[ "$n" -eq 2 ]] || fail "queue should not have grown past cap, got $n"
}

@test "T5: pending_merges_surface_failed reports failed entries" {
    pending_merges_add 5 "TAP-5" "feature/e"
    # Mutate the entry to look failed
    local upd
    upd=$(jq '(.entries[] | select(.pr_number == 5) | .merge_status) = "failed"
              | (.entries[] | select(.pr_number == 5) | .failure_reason) = "ci_failed"' "$PENDING_MERGES_FILE")
    echo "$upd" > "$PENDING_MERGES_FILE"
    run pending_merges_surface_failed
    [[ "$status" -eq 0 ]]
    [[ "$output" == *"PENDING-MERGE FAILURES"* ]] || fail "no failure summary: $output"
    [[ "$output" == *"#5"* && "$output" == *"TAP-5"* && "$output" == *"ci_failed"* ]] \
        || fail "summary missing pieces: $output"
}

@test "T5: pending_merges_surface_failed prints nothing when none failed" {
    pending_merges_add 7 "TAP-7" "feature/g"
    run pending_merges_surface_failed
    [[ "$status" -eq 0 ]]
    [[ -z "$output" ]] || fail "expected no output, got: $output"
}

@test "T5: pending_merges_get_merged lists merged tickets" {
    pending_merges_add 10 "TAP-10" "feature/x"
    pending_merges_add 11 "TAP-11" "feature/y"
    local upd
    upd=$(jq '(.entries[] | select(.pr_number == 10) | .merge_status) = "merged"' "$PENDING_MERGES_FILE")
    echo "$upd" > "$PENDING_MERGES_FILE"
    run pending_merges_get_merged
    [[ "$status" -eq 0 ]]
    [[ "$output" == "TAP-10" ]] || fail "expected only TAP-10, got: $output"
}

@test "T5: pending_merges_drop removes an entry" {
    pending_merges_add 20 "TAP-20" "feature/p"
    pending_merges_add 21 "TAP-21" "feature/q"
    pending_merges_drop 20
    local remaining
    remaining=$(jq -r '[.entries[].pr_number] | join(",")' "$PENDING_MERGES_FILE")
    [[ "$remaining" == "21" ]] || fail "drop didn't remove: $remaining"
}

@test "T5: pending_merges_poll no-ops when async-merge disabled" {
    unset RALPH_ASYNC_MERGE
    pending_merges_add 30 "TAP-30" "feature/m"
    run pending_merges_poll
    [[ "$status" -eq 0 ]]
    # Entry should remain unchanged
    local ms
    ms=$(jq -r '.entries[0].merge_status' "$PENDING_MERGES_FILE")
    [[ "$ms" == "open" ]] || fail "poll changed state with flag off: $ms"
}

@test "T5: pending_merges_poll no-ops when queue is empty" {
    RALPH_ASYNC_MERGE=true run pending_merges_poll
    [[ "$status" -eq 0 ]]
}
