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

# ----------------------------------------------------------------------------
# TAP-2646 — poisoned (auto_populated) empty-snapshot guard.
#
# A list_issues call with state=null ("any") returns [] as a Linear-plugin
# query-shape quirk; the TAP-1412 auto-populate hook caches that [] with
# auto_populated=true. Without a guard the TAP-2442 pre-seed reads it as a
# real 0 and writes a poisoned linear_open_count=0 into status.json, which the
# PREFLIGHT-EMPTY-PLAN gate then treats as a clean completion (NLTlabsPE
# 2026-05-27: exited with 63 issues open). The reader must abstain on the
# poisoned signature but still honor a genuine empty bucket.
# ----------------------------------------------------------------------------

# Write a snapshot with an explicit auto_populated flag (and arbitrary state
# token, so we can simulate the "__any__" cache the plugin actually writes).
_write_snapshot_flagged() {
    local state="$1" issue_count="$2" expires_at="$3" auto_populated="$4"
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
  "auto_populated": ${auto_populated},
  "team": "${RALPH_LINEAR_TEAM}",
  "project": "${RALPH_LINEAR_PROJECT}",
  "issues": ${issues}
}
EOF
}

@test "TAP-2646: auto_populated empty snapshot → abstain (return 1)" {
    # The poisoned signature: empty issues + auto_populated:true in the bucket
    # the reader globs (state=null is normalized to the active/open view).
    _write_snapshot_flagged "open" 0 $(($(date -u +%s) + 300)) "true"
    run _linear_count_from_snapshot_cache "open"
    assert_failure
    [[ ! "$output" =~ ^[0-9]+$ ]]
}

@test "TAP-2646: genuine empty snapshot (no auto_populated) → real 0 honored" {
    # Guard must not be over-broad: a real empty bucket still returns 0.
    _write_snapshot_flagged "completed" 0 $(($(date -u +%s) + 300)) "false"
    run _linear_count_from_snapshot_cache "completed"
    assert_success
    [[ "$output" == "0" ]]
}

@test "TAP-2646: auto_populated:true but non-empty → count returned (flag only matters at 0)" {
    # The flag alone is not poison — a populated auto-populated snapshot is a
    # legitimate count and must pass through.
    _write_snapshot_flagged "open" 5 $(($(date -u +%s) + 300)) "true"
    run _linear_count_from_snapshot_cache "open"
    assert_success
    [[ "$output" == "5" ]]
}

@test "TAP-2646: seed writes NO poisoned 0 when open snapshot is auto_populated empty" {
    # Full root-cause chain: poisoned open snapshot, no completed snapshot.
    # The seed must abstain on open (and write nothing), so linear_get_open_count
    # later abstains rather than returning a poisoned 0 that trips plan_complete.
    _write_snapshot_flagged "open" 0 $(($(date -u +%s) + 300)) "true"
    run linear_seed_counts_from_snapshot_cache
    assert_success
    # status.json must not carry a poisoned linear_open_count.
    if [[ -f "$RALPH_DIR/status.json" ]]; then
        local _open
        _open=$(jq -r '.linear_open_count // "absent"' "$RALPH_DIR/status.json")
        [[ "$_open" == "absent" ]] || { echo "expected no linear_open_count, got $_open"; return 1; }
    fi
    # And the downstream count read abstains (no poisoned 0 to serve).
    run linear_get_open_count
    assert_failure
}

@test "TAP-2646: poisoned __any__ cache + populated open bucket → real count, no false 0" {
    # The literal acceptance scenario: a poisoned auto_populated empty "__any__"
    # snapshot coexists with a populated state-bucket snapshot. The seed must
    # read the populated open count and never serve the poisoned empty one.
    _write_snapshot_flagged "any" 0 $(($(date -u +%s) + 300)) "true"   # poisoned
    _write_snapshot_flagged "open" 7 $(($(date -u +%s) + 300)) "false" # real
    run linear_seed_counts_from_snapshot_cache
    assert_success
    [[ -f "$RALPH_DIR/status.json" ]]
    [[ "$(jq -r '.linear_open_count' "$RALPH_DIR/status.json")" == "7" ]]
    run linear_get_open_count
    assert_success
    [[ "$output" == "7" ]]
}
