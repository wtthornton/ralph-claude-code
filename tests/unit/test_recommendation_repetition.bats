#!/usr/bin/env bats
# TAP-2499: orchestrator-level recommendation-repetition halt.
# Defense-in-depth against future regressions of the parser fix (TAP-2494).

bats_require_minimum_version 1.5.0
load '../helpers/test_helper'

REPO_ROOT="${BATS_TEST_DIRNAME}/../.."

setup() {
    export TEST_TEMP_DIR="$(mktemp -d)"
    cd "$TEST_TEMP_DIR"
    export RALPH_DIR="$TEST_TEMP_DIR/.ralph"
    mkdir -p "$RALPH_DIR"
    source "$REPO_ROOT/lib/recommendation_repetition.sh"
    # Reset envs to defaults for each test
    export RALPH_RECOMMENDATION_REPETITION_THRESHOLD=5
    export RALPH_RECOMMENDATION_REPETITION_WINDOW_MIN=30
    export RALPH_RECOMMENDATION_RING_SIZE=10
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR"
}

# =============================================================================
# 1. Normalization collapses loop-number variations to one hash
# =============================================================================
@test "TAP-2499: normalize collapses 'Loop 40' and 'Loop 41' to same hash" {
    local _h1 _h2
    _h1=$(recommendation_hash "Loop 40 of empty-backlog runaway")
    _h2=$(recommendation_hash "Loop 41 of empty-backlog runaway")
    [[ "$_h1" == "$_h2" ]] || { echo "expected same hash, got $_h1 vs $_h2"; return 1; }
}

# =============================================================================
# 2. Normalization collapses parenthesized counts: (4 live probes) ≈ (7 live probes)
# =============================================================================
@test "TAP-2499: normalize collapses '(4 live probes)' and '(7 live probes)' to same hash" {
    local _h1 _h2
    _h1=$(recommendation_hash "Backlog confirmed empty (4 live probes)")
    _h2=$(recommendation_hash "Backlog confirmed empty (7 live probes)")
    [[ "$_h1" == "$_h2" ]] || { echo "expected same hash, got $_h1 vs $_h2"; return 1; }
}

# =============================================================================
# 3. Different recommendations produce different hashes
# =============================================================================
@test "TAP-2499: distinct recommendations produce distinct hashes" {
    local _h1 _h2
    _h1=$(recommendation_hash "Backlog empty, halting")
    _h2=$(recommendation_hash "Shipped TAP-1234, ready for next")
    [[ "$_h1" != "$_h2" ]] || { echo "expected different hashes"; return 1; }
}

# =============================================================================
# 4. Threshold detection: 5 identical → repetition detected
# =============================================================================
@test "TAP-2499: 5 identical recommendations within window → repetition detected" {
    for i in 1 2 3 4 5; do
        recommendation_record "Loop $i of empty-backlog runaway"
    done
    run recommendation_repetition_check
    assert_success
}

# =============================================================================
# 5. Below threshold: 4 identical → no detection
# =============================================================================
@test "TAP-2499: 4 identical recommendations → repetition NOT detected" {
    for i in 1 2 3 4; do
        recommendation_record "Loop $i of empty-backlog runaway"
    done
    run recommendation_repetition_check
    assert_failure
}

# =============================================================================
# 6. Diverse recommendations: 5 distinct → no detection
# =============================================================================
@test "TAP-2499: 5 distinct recommendations → repetition NOT detected" {
    recommendation_record "Shipped TAP-1001"
    recommendation_record "Shipped TAP-1002"
    recommendation_record "Shipped TAP-1003"
    recommendation_record "Shipped TAP-1004"
    recommendation_record "Shipped TAP-1005"
    run recommendation_repetition_check
    assert_failure
}

# =============================================================================
# 7. Out-of-window entries are excluded
# =============================================================================
@test "TAP-2499: entries older than window are excluded from count" {
    # Manually write entries with old timestamps
    local _old=$(($(date +%s) - 60 * 60))  # 1 hour ago, beyond 30min default
    local _hash
    _hash=$(recommendation_hash "Loop X of empty-backlog runaway")
    for i in 1 2 3 4 5; do
        printf '%s %s\n' "$_old" "$_hash" >> "$RALPH_DIR/.recent_recommendations"
    done
    run recommendation_repetition_check
    assert_failure
}

# =============================================================================
# 8. Ring buffer caps at RALPH_RECOMMENDATION_RING_SIZE entries
# =============================================================================
@test "TAP-2499: ring buffer caps at RALPH_RECOMMENDATION_RING_SIZE entries" {
    export RALPH_RECOMMENDATION_RING_SIZE=5
    for i in 1 2 3 4 5 6 7 8 9 10; do
        recommendation_record "Distinct entry $i with unique content"
    done
    local _lines
    _lines=$(wc -l < "$RALPH_DIR/.recent_recommendations" | tr -cd '0-9')
    [[ "$_lines" == "5" ]] || { echo "expected 5 lines (ring cap), got $_lines"; return 1; }
}

# =============================================================================
# 9. Configurable threshold via RALPH_RECOMMENDATION_REPETITION_THRESHOLD
# =============================================================================
@test "TAP-2499: RALPH_RECOMMENDATION_REPETITION_THRESHOLD=3 → 3 identical triggers" {
    export RALPH_RECOMMENDATION_REPETITION_THRESHOLD=3
    for i in 1 2 3; do
        recommendation_record "Loop $i of identical pattern"
    done
    run recommendation_repetition_check
    assert_success
}

# =============================================================================
# 10. Diversity stat helper
# =============================================================================
@test "TAP-2499: recommendation_diversity_stat reports unique/total" {
    recommendation_record "A"
    recommendation_record "A"
    recommendation_record "B"
    run recommendation_diversity_stat
    assert_success
    # Output format: "unique total"
    [[ "$output" == "2 3" ]] || { echo "expected '2 3', got '$output'"; return 1; }
}
