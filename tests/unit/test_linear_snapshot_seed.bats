#!/usr/bin/env bats
# TAP-2442 — Snapshot-cache pre-seed for Linear open/done counts.
#
# Verifies:
#   * _linear_count_from_snapshot_cache returns issue count from cache hit
#   * Cache miss / expired / malformed → exit 1 (TAP-536 fail-loud preserved)
#   * linear_seed_counts_from_snapshot_cache writes counts + linear_counts_at
#     into status.json, but is a no-op when no fresh cache exists
#   * After seeding, _linear_read_hook_count finds the values and succeeds

bats_require_minimum_version 1.5.0
load '../helpers/test_helper'

LINEAR_BACKEND="${BATS_TEST_DIRNAME}/../../lib/linear_backend.sh"

setup() {
    TEST_TEMP_DIR="$(mktemp -d)"
    cd "$TEST_TEMP_DIR"
    mkdir -p "$TEST_TEMP_DIR/.ralph"
    mkdir -p "$TEST_TEMP_DIR/.tapps-mcp-cache/linear-snapshots"
    export RALPH_DIR="$TEST_TEMP_DIR/.ralph"
    export RALPH_LINEAR_TEAM="TappsCodingAgents"
    export RALPH_LINEAR_PROJECT="Ralph Continuous Coding"
    export RALPH_LINEAR_SNAPSHOT_CACHE_DIR="$TEST_TEMP_DIR/.tapps-mcp-cache/linear-snapshots"
    unset LINEAR_API_KEY
    source "$LINEAR_BACKEND"
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR"
    unset RALPH_DIR RALPH_LINEAR_TEAM RALPH_LINEAR_PROJECT RALPH_LINEAR_SNAPSHOT_CACHE_DIR
}

_write_snapshot() {
    local state="$1" issue_count="$2" expires_at="$3"
    local file="$RALPH_LINEAR_SNAPSHOT_CACHE_DIR/${RALPH_LINEAR_TEAM}__${RALPH_LINEAR_PROJECT}__${state}__abc123.json"
    local issues="["
    for i in $(seq 1 "$issue_count"); do
        [[ $i -gt 1 ]] && issues+=","
        issues+="{\"id\":\"TAP-$i\"}"
    done
    issues+="]"
    cat > "$file" <<EOF
{
  "cached_at": $(($(date -u +%s) - 60)),
  "expires_at": ${expires_at},
  "state": "${state}",
  "team": "${RALPH_LINEAR_TEAM}",
  "project": "${RALPH_LINEAR_PROJECT}",
  "issues": ${issues}
}
EOF
}

@test "TAP-2442: _linear_count_from_snapshot_cache returns count on cache hit" {
    _write_snapshot "open" 7 $(($(date -u +%s) + 300))
    run _linear_count_from_snapshot_cache "open"
    assert_success
    [[ "$output" == "7" ]]
}

@test "TAP-2442: empty cache dir → exit 1 (TAP-536 abstain)" {
    # bats `run` captures stderr too; assert the stdout is NOT an integer
    # (the function emits a `linear_api_error: ...` stderr line on miss).
    run _linear_count_from_snapshot_cache "open"
    assert_failure
    [[ ! "$output" =~ ^[0-9]+$ ]]
}

@test "TAP-2442: expired snapshot → exit 1" {
    _write_snapshot "open" 7 $(($(date -u +%s) - 60))  # expired 60s ago
    run _linear_count_from_snapshot_cache "open"
    assert_failure
}

@test "TAP-2442: missing team/project → exit 1" {
    unset RALPH_LINEAR_TEAM
    run _linear_count_from_snapshot_cache "open"
    assert_failure
}

@test "TAP-2442: missing cache dir → exit 1" {
    rm -rf "$RALPH_LINEAR_SNAPSHOT_CACHE_DIR"
    run _linear_count_from_snapshot_cache "open"
    assert_failure
}

@test "TAP-2442: linear_seed_counts_from_snapshot_cache writes status.json on cache hit" {
    _write_snapshot "open" 12 $(($(date -u +%s) + 300))
    _write_snapshot "completed" 5 $(($(date -u +%s) + 300))
    [[ ! -f "$RALPH_DIR/status.json" ]]
    run linear_seed_counts_from_snapshot_cache
    assert_success
    [[ -f "$RALPH_DIR/status.json" ]]
    local _open _done _ts
    _open=$(jq -r '.linear_open_count' "$RALPH_DIR/status.json")
    _done=$(jq -r '.linear_done_count' "$RALPH_DIR/status.json")
    _ts=$(jq -r '.linear_counts_at' "$RALPH_DIR/status.json")
    [[ "$_open" == "12" ]]
    [[ "$_done" == "5" ]]
    [[ -n "$_ts" && "$_ts" != "null" ]]
}

@test "TAP-2442: linear_seed_counts_from_snapshot_cache is a no-op on cache miss" {
    # No snapshot files at all.
    run linear_seed_counts_from_snapshot_cache
    assert_success
    [[ ! -f "$RALPH_DIR/status.json" ]]
}

@test "TAP-2442: seed merges into existing status.json (does not clobber)" {
    _write_snapshot "open" 3 $(($(date -u +%s) + 300))
    printf '%s\n' '{"status":"running","loop_count":42,"recommendation":"keep going"}' \
        > "$RALPH_DIR/status.json"
    run linear_seed_counts_from_snapshot_cache
    assert_success
    [[ "$(jq -r '.status' "$RALPH_DIR/status.json")" == "running" ]]
    [[ "$(jq -r '.loop_count' "$RALPH_DIR/status.json")" == "42" ]]
    [[ "$(jq -r '.linear_open_count' "$RALPH_DIR/status.json")" == "3" ]]
}

@test "TAP-2442: after seeding, linear_get_open_count returns the seeded value" {
    _write_snapshot "open" 9 $(($(date -u +%s) + 300))
    linear_seed_counts_from_snapshot_cache
    run linear_get_open_count
    assert_success
    [[ "$output" == "9" ]]
}

@test "TAP-2442: most recent snapshot wins when multiple slices exist" {
    _write_snapshot "open" 4 $(($(date -u +%s) + 300))
    # Older file — touch it back in time
    touch -d "1 hour ago" "$RALPH_LINEAR_SNAPSHOT_CACHE_DIR"/*open*.json
    # Now write a newer one with different count
    sleep 0.1
    local file2="$RALPH_LINEAR_SNAPSHOT_CACHE_DIR/${RALPH_LINEAR_TEAM}__${RALPH_LINEAR_PROJECT}__open__xyz999.json"
    cat > "$file2" <<EOF
{"expires_at": $(($(date -u +%s) + 300)), "issues":[{"id":"TAP-9"},{"id":"TAP-8"}]}
EOF
    run _linear_count_from_snapshot_cache "open"
    assert_success
    [[ "$output" == "2" ]]
}
