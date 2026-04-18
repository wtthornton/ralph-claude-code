#!/usr/bin/env bats
# Unit Tests for Exit Detection Logic

load '../helpers/test_helper'

setup() {
    # Source helper functions
    source "$(dirname "$BATS_TEST_FILENAME")/../helpers/test_helper.bash"

    # Set up environment with .ralph/ subfolder structure
    export RALPH_DIR=".ralph"
    export EXIT_SIGNALS_FILE="$RALPH_DIR/.exit_signals"
    export RESPONSE_ANALYSIS_FILE="$RALPH_DIR/.response_analysis"
    export MAX_CONSECUTIVE_TEST_LOOPS=3
    export MAX_CONSECUTIVE_DONE_SIGNALS=2

    # Create temp test directory
    export TEST_TEMP_DIR="$(mktemp -d)"
    cd "$TEST_TEMP_DIR"
    mkdir -p "$RALPH_DIR"

    # Initialize exit signals file
    echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": []}' > "$EXIT_SIGNALS_FILE"
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR"
}

# Helper function: should_exit_gracefully (extracted from ralph_loop.sh)
# Updated to respect EXIT_SIGNAL from .response_analysis for completion indicators
should_exit_gracefully() {
    if [[ ! -f "$EXIT_SIGNALS_FILE" ]]; then
        echo ""  # Return empty string instead of using return code
        return 1  # Don't exit, file doesn't exist
    fi

    local signals=$(cat "$EXIT_SIGNALS_FILE")

    # Count recent signals (last 5 loops) - with error handling
    local recent_test_loops
    local recent_done_signals
    local recent_completion_indicators

    recent_test_loops=$(echo "$signals" | jq '.test_only_loops | length' 2>/dev/null || echo "0")
    recent_done_signals=$(echo "$signals" | jq '.done_signals | length' 2>/dev/null || echo "0")
    recent_completion_indicators=$(echo "$signals" | jq '.completion_indicators | length' 2>/dev/null || echo "0")

    # Check for exit conditions

    # 1. Too many consecutive test-only loops
    if [[ $recent_test_loops -ge $MAX_CONSECUTIVE_TEST_LOOPS ]]; then
        echo "test_saturation"
        return 0
    fi

    # 2. Multiple "done" signals
    if [[ $recent_done_signals -ge $MAX_CONSECUTIVE_DONE_SIGNALS ]]; then
        echo "completion_signals"
        return 0
    fi

    # 3. Strong completion indicators (only if Claude's EXIT_SIGNAL is true)
    # This prevents premature exits when heuristics detect completion patterns
    # but Claude explicitly indicates work is still in progress
    local claude_exit_signal="false"
    if [[ -f "$RESPONSE_ANALYSIS_FILE" ]]; then
        claude_exit_signal=$(jq -r '.analysis.exit_signal // false' "$RESPONSE_ANALYSIS_FILE" 2>/dev/null || echo "false")
    fi

    if [[ $recent_completion_indicators -ge 2 ]] && [[ "$claude_exit_signal" == "true" ]]; then
        echo "project_complete"
        return 0
    fi

    # 4. Check fix_plan.md for completion
    # Fix #144: Only match valid markdown checkboxes, not date entries like [2026-01-29]
    # PREFLIGHT-EMPTY-PLAN: zero unchecked items = exit cleanly, even if total_items=0
    # (file has only headers / no tasks defined yet). Mirrors the live function.
    if [[ -f "$RALPH_DIR/fix_plan.md" ]]; then
        local uncompleted_items
        local completed_items
        uncompleted_items=$(grep -cE "^[[:space:]]*- \[ \]" "$RALPH_DIR/fix_plan.md" 2>/dev/null) || uncompleted_items=0
        uncompleted_items=$(echo "$uncompleted_items" | tr -cd '0-9'); uncompleted_items=${uncompleted_items:-0}
        completed_items=$(grep -cE "^[[:space:]]*- \[[xX]\]" "$RALPH_DIR/fix_plan.md" 2>/dev/null) || completed_items=0
        completed_items=$(echo "$completed_items" | tr -cd '0-9'); completed_items=${completed_items:-0}

        if [[ $uncompleted_items -eq 0 ]]; then
            echo "plan_complete"
            return 0
        fi
    fi

    echo ""  # Return empty string instead of using return code
    return 1  # Don't exit
}

# Test 1: No exit when signals are empty
@test "should_exit_gracefully returns empty with no signals" {
    echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": []}' > "$EXIT_SIGNALS_FILE"

    result=$(should_exit_gracefully || true)
    assert_equal "$result" ""
}

# Test 2: Exit on test saturation (3 test loops)
@test "should_exit_gracefully exits on test saturation (3 loops)" {
    echo '{"test_only_loops": [1,2,3], "done_signals": [], "completion_indicators": []}' > "$EXIT_SIGNALS_FILE"

    result=$(should_exit_gracefully)
    assert_equal "$result" "test_saturation"
}

# Test 4: No exit with only 2 test loops
@test "should_exit_gracefully continues with 2 test loops" {
    echo '{"test_only_loops": [1,2], "done_signals": [], "completion_indicators": []}' > "$EXIT_SIGNALS_FILE"

    result=$(should_exit_gracefully || true)
    assert_equal "$result" ""
}

# Test 5: Exit on done signals (2 signals)
@test "should_exit_gracefully exits on 2 done signals" {
    echo '{"test_only_loops": [], "done_signals": [1,2], "completion_indicators": []}' > "$EXIT_SIGNALS_FILE"

    result=$(should_exit_gracefully || true)
    assert_equal "$result" "completion_signals"
}

# Test 7: No exit with only 1 done signal
@test "should_exit_gracefully continues with 1 done signal" {
    echo '{"test_only_loops": [], "done_signals": [1], "completion_indicators": []}' > "$EXIT_SIGNALS_FILE"

    result=$(should_exit_gracefully || true)
    assert_equal "$result" ""
}

# Test 8: Exit on completion indicators (2 indicators) with EXIT_SIGNAL=true
@test "should_exit_gracefully exits on 2 completion indicators" {
    echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": [1,2]}' > "$EXIT_SIGNALS_FILE"

    # Must also have exit_signal=true in .response_analysis (after fix)
    cat > "$RESPONSE_ANALYSIS_FILE" << 'EOF'
{
    "loop_number": 2,
    "analysis": {
        "exit_signal": true,
        "confidence_score": 80
    }
}
EOF

    result=$(should_exit_gracefully || true)
    assert_equal "$result" "project_complete"
}

# Test 9: No exit with only 1 completion indicator
@test "should_exit_gracefully continues with 1 completion indicator" {
    echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": [1]}' > "$EXIT_SIGNALS_FILE"

    result=$(should_exit_gracefully || true)
    assert_equal "$result" ""
}

# Test 10: Exit when fix_plan.md all items complete
@test "should_exit_gracefully exits when all fix_plan items complete" {
    cat > "$RALPH_DIR/fix_plan.md" << 'EOF'
# Fix Plan
- [x] Task 1
- [x] Task 2
- [x] Task 3
EOF

    result=$(should_exit_gracefully)
    assert_equal "$result" "plan_complete"
}

# Test 11: No exit when fix_plan.md partially complete
@test "should_exit_gracefully continues when fix_plan partially complete" {
    cat > "$RALPH_DIR/fix_plan.md" << 'EOF'
# Fix Plan
- [x] Task 1
- [ ] Task 2
- [ ] Task 3
EOF

    result=$(should_exit_gracefully || true)
    assert_equal "$result" ""
}

# Test 12: No exit when fix_plan.md missing
@test "should_exit_gracefully continues when fix_plan missing" {
    # Don't create fix_plan.md

    result=$(should_exit_gracefully || true)
    assert_equal "$result" ""
}

# Test 13: No exit when exit signals file missing
@test "should_exit_gracefully continues when exit signals file missing" {
    rm -f "$EXIT_SIGNALS_FILE"

    result=$(should_exit_gracefully || true)
    assert_equal "$result" ""
}

# Test 14: Handle corrupted JSON gracefully
@test "should_exit_gracefully handles corrupted JSON" {
    echo 'invalid json{' > "$EXIT_SIGNALS_FILE"

    # Should not crash, should treat as 0 signals
    result=$(should_exit_gracefully || true)
    assert_equal "$result" ""
}

# Test 15: Multiple exit conditions simultaneously (test takes priority)
@test "should_exit_gracefully returns first matching condition" {
    echo '{"test_only_loops": [1,2,3,4], "done_signals": [1,2], "completion_indicators": [1,2]}' > "$EXIT_SIGNALS_FILE"

    result=$(should_exit_gracefully)
    # Should return test_saturation (checked first)
    assert_equal "$result" "test_saturation"
}

# Test 16: PREFLIGHT-EMPTY-PLAN — fix_plan with NO checkboxes exits cleanly.
# Was previously expected to return "" (continue), but spinning on an empty plan
# wastes 3 Claude calls before the no-progress CB trips. With the pre-flight fix,
# zero-unchecked-items always exits with plan_complete (file backend).
@test "should_exit_gracefully exits clean on fix_plan with no checkboxes (PREFLIGHT-EMPTY-PLAN)" {
    cat > "$RALPH_DIR/fix_plan.md" << 'EOF'
# Fix Plan
This is just text, no tasks yet.
EOF

    result=$(should_exit_gracefully || true)
    assert_equal "$result" "plan_complete"
}

# PREFLIGHT-EMPTY-PLAN regression: fix_plan with only headers (real tapps-brain case)
@test "should_exit_gracefully exits clean on fix_plan with only headers (no tasks defined)" {
    cat > "$RALPH_DIR/fix_plan.md" << 'EOF'
# Ralph Fix Plan — EPIC-070

## EPIC-070: Remote-First Brain as a Shared Service

(all stories archived)
EOF

    result=$(should_exit_gracefully || true)
    assert_equal "$result" "plan_complete"
}

# PREFLIGHT-EMPTY-PLAN guard: file with at least one unchecked task must NOT exit.
@test "should_exit_gracefully continues with even one unchecked item" {
    cat > "$RALPH_DIR/fix_plan.md" << 'EOF'
# Plan
- [x] done
- [ ] still TODO
EOF

    result=$(should_exit_gracefully || true)
    assert_equal "$result" ""
}

# Test 17: fix_plan.md with mixed checkbox formats
@test "should_exit_gracefully handles mixed checkbox formats" {
    cat > "$RALPH_DIR/fix_plan.md" << 'EOF'
# Fix Plan
- [x] Task 1 completed
- [ ] Task 2 pending
- [X] Task 3 completed (uppercase)
- [] Task 4 (invalid format, should not count)
EOF

    result=$(should_exit_gracefully || true)
    # 2 completed out of 3 valid tasks
    assert_equal "$result" ""
}

# =============================================================================
# EXIT_SIGNAL RESPECT TESTS (Issue: Premature exit when EXIT_SIGNAL=false)
# =============================================================================
# These tests verify that completion indicators only trigger exit when
# Claude's explicit EXIT_SIGNAL is true, preventing premature exits during
# productive iterations.

# Test 21: Completion indicators with EXIT_SIGNAL=false should continue
@test "should_exit_gracefully continues when completion indicators high but EXIT_SIGNAL=false" {
    # Setup: High completion indicators (would normally exit)
    echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": [1,2,3]}' > "$EXIT_SIGNALS_FILE"

    # Setup: Claude's explicit exit signal is false (still working)
    mkdir -p "$(dirname "$RESPONSE_ANALYSIS_FILE")"
    cat > "$RESPONSE_ANALYSIS_FILE" << 'EOF'
{
    "loop_number": 3,
    "timestamp": "2026-01-12T10:00:00Z",
    "output_format": "text",
    "analysis": {
        "has_completion_signal": true,
        "is_test_only": false,
        "is_stuck": false,
        "has_progress": true,
        "files_modified": 5,
        "confidence_score": 70,
        "exit_signal": false,
        "work_summary": "Implementing feature, still in progress"
    }
}
EOF

    result=$(should_exit_gracefully || true)
    # Should NOT exit because EXIT_SIGNAL is false
    assert_equal "$result" ""
}

# Test 22: Completion indicators with EXIT_SIGNAL=true should exit
@test "should_exit_gracefully exits when completion indicators high AND EXIT_SIGNAL=true" {
    # Setup: High completion indicators
    echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": [1,2]}' > "$EXIT_SIGNALS_FILE"

    # Setup: Claude's explicit exit signal is true (project complete)
    mkdir -p "$(dirname "$RESPONSE_ANALYSIS_FILE")"
    cat > "$RESPONSE_ANALYSIS_FILE" << 'EOF'
{
    "loop_number": 2,
    "timestamp": "2026-01-12T10:00:00Z",
    "output_format": "text",
    "analysis": {
        "has_completion_signal": true,
        "is_test_only": false,
        "is_stuck": false,
        "has_progress": false,
        "files_modified": 0,
        "confidence_score": 100,
        "exit_signal": true,
        "work_summary": "All tasks complete, project ready for review"
    }
}
EOF

    result=$(should_exit_gracefully)
    # Should exit because BOTH conditions are met
    assert_equal "$result" "project_complete"
}

# Test 23: Completion indicators without .response_analysis file should continue
@test "should_exit_gracefully continues when .response_analysis file missing" {
    # Setup: High completion indicators
    echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": [1,2,3]}' > "$EXIT_SIGNALS_FILE"

    # Don't create .response_analysis - defaults to exit_signal=false
    rm -f "$RESPONSE_ANALYSIS_FILE"

    result=$(should_exit_gracefully || true)
    # Should NOT exit because exit_signal defaults to false
    assert_equal "$result" ""
}

# Test 24: Completion indicators with malformed .response_analysis should continue
@test "should_exit_gracefully continues when .response_analysis has invalid JSON" {
    # Setup: High completion indicators
    echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": [1,2]}' > "$EXIT_SIGNALS_FILE"

    # Setup: Corrupted/invalid JSON in .response_analysis
    echo 'invalid json{broken' > "$RESPONSE_ANALYSIS_FILE"

    result=$(should_exit_gracefully || true)
    # Should NOT exit because jq parsing fails, defaults to false
    assert_equal "$result" ""
}

# Test 25: EXIT_SIGNAL=true but completion indicators below threshold should continue
@test "should_exit_gracefully continues when EXIT_SIGNAL=true but indicators below threshold" {
    # Setup: Only 1 completion indicator (below threshold of 2)
    echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": [1]}' > "$EXIT_SIGNALS_FILE"

    # Setup: Claude says exit is true
    cat > "$RESPONSE_ANALYSIS_FILE" << 'EOF'
{
    "loop_number": 1,
    "analysis": {
        "exit_signal": true,
        "confidence_score": 100
    }
}
EOF

    result=$(should_exit_gracefully || true)
    # Should NOT exit because indicators below threshold
    assert_equal "$result" ""
}

# Test 26: EXIT_SIGNAL=false with explicit false value in JSON
@test "should_exit_gracefully handles explicit false exit_signal" {
    echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": [1,2,3,4,5]}' > "$EXIT_SIGNALS_FILE"

    # Explicit false value
    cat > "$RESPONSE_ANALYSIS_FILE" << 'EOF'
{
    "analysis": {
        "exit_signal": false
    }
}
EOF

    result=$(should_exit_gracefully || true)
    assert_equal "$result" ""
}

# Test 27: EXIT_SIGNAL missing from analysis object should default to false
@test "should_exit_gracefully defaults to false when exit_signal field missing" {
    echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": [1,2]}' > "$EXIT_SIGNALS_FILE"

    # analysis object exists but no exit_signal field
    cat > "$RESPONSE_ANALYSIS_FILE" << 'EOF'
{
    "loop_number": 5,
    "analysis": {
        "confidence_score": 80,
        "has_completion_signal": true,
        "is_test_only": false
    }
}
EOF

    result=$(should_exit_gracefully || true)
    # Missing exit_signal should default to false, so continue
    assert_equal "$result" ""
}

# Test 28: Test priority - test_saturation still takes priority over completion indicators
@test "should_exit_gracefully test_saturation takes priority even with EXIT_SIGNAL=false" {
    # Test loops should still trigger exit regardless of EXIT_SIGNAL
    echo '{"test_only_loops": [1,2,3,4], "done_signals": [], "completion_indicators": [1]}' > "$EXIT_SIGNALS_FILE"

    cat > "$RESPONSE_ANALYSIS_FILE" << 'EOF'
{
    "analysis": {
        "exit_signal": false
    }
}
EOF

    result=$(should_exit_gracefully)
    # test_saturation is checked before completion_indicators
    assert_equal "$result" "test_saturation"
}

# Test 29: done_signals still takes priority over completion indicators
@test "should_exit_gracefully done_signals takes priority even with EXIT_SIGNAL=false" {
    echo '{"test_only_loops": [], "done_signals": [1,2,3], "completion_indicators": [1]}' > "$EXIT_SIGNALS_FILE"

    cat > "$RESPONSE_ANALYSIS_FILE" << 'EOF'
{
    "analysis": {
        "exit_signal": false
    }
}
EOF

    result=$(should_exit_gracefully)
    # done_signals is checked before completion_indicators
    assert_equal "$result" "completion_signals"
}

# Test 30: Empty analysis object in .response_analysis should default to false
@test "should_exit_gracefully handles empty analysis object" {
    echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": [1,2]}' > "$EXIT_SIGNALS_FILE"

    cat > "$RESPONSE_ANALYSIS_FILE" << 'EOF'
{
    "loop_number": 3,
    "analysis": {}
}
EOF

    result=$(should_exit_gracefully || true)
    assert_equal "$result" ""
}

# Test 31: STATUS=COMPLETE but EXIT_SIGNAL=false conflict - EXIT_SIGNAL takes precedence
@test "should_exit_gracefully respects EXIT_SIGNAL=false even when STATUS=COMPLETE" {
    # Setup: High completion indicators
    echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": [1,2,3]}' > "$EXIT_SIGNALS_FILE"

    # Setup: Conflicting signals - STATUS says COMPLETE but EXIT_SIGNAL explicitly false
    # This can happen when Claude marks a phase complete but has more work to do
    cat > "$RESPONSE_ANALYSIS_FILE" << 'EOF'
{
    "loop_number": 3,
    "timestamp": "2026-01-12T10:00:00Z",
    "output_format": "text",
    "analysis": {
        "has_completion_signal": true,
        "is_test_only": false,
        "is_stuck": false,
        "has_progress": true,
        "files_modified": 3,
        "confidence_score": 100,
        "exit_signal": false,
        "work_summary": "Phase complete, but more phases remain"
    }
}
EOF

    result=$(should_exit_gracefully || true)
    # EXIT_SIGNAL=false should take precedence, continue working
    assert_equal "$result" ""
}

# =============================================================================
# UPDATE_EXIT_SIGNALS TESTS (Issue: Confidence-based completion indicators)
# =============================================================================
# These tests verify that update_exit_signals() only adds to completion_indicators
# when EXIT_SIGNAL is true, not based on confidence score alone.
# This is critical for JSON mode where confidence is always >= 70.

# Source the response_analyzer library for direct testing
# Note: These tests source the library to test update_exit_signals() directly

# Test 32: update_exit_signals should NOT add to completion_indicators when exit_signal=false
@test "update_exit_signals does NOT add to completion_indicators when exit_signal=false" {
    # Source the response analyzer library
    [[ -f "${BATS_TEST_DIRNAME}/../../lib/response_analyzer.sh" ]] || skip "response_analyzer.sh removed (SKILLS-3)"
    source "${BATS_TEST_DIRNAME}/../../lib/response_analyzer.sh"

    # Initialize exit signals file
    echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": []}' > "$EXIT_SIGNALS_FILE"

    # Create analysis file with HIGH confidence (70) but exit_signal=false
    # This simulates JSON mode where confidence is always >= 70
    cat > "$RESPONSE_ANALYSIS_FILE" << 'EOF'
{
    "loop_number": 1,
    "timestamp": "2026-01-12T10:00:00Z",
    "output_format": "json",
    "analysis": {
        "has_completion_signal": false,
        "is_test_only": false,
        "is_stuck": false,
        "has_progress": true,
        "files_modified": 5,
        "confidence_score": 70,
        "exit_signal": false,
        "work_summary": "Implementing feature, still in progress"
    }
}
EOF

    # Call update_exit_signals
    update_exit_signals "$RESPONSE_ANALYSIS_FILE" "$EXIT_SIGNALS_FILE"

    # Verify completion_indicators was NOT incremented
    local indicator_count=$(jq '.completion_indicators | length' "$EXIT_SIGNALS_FILE")
    assert_equal "$indicator_count" "0"
}

# Test 33: update_exit_signals SHOULD add to completion_indicators when exit_signal=true
@test "update_exit_signals adds to completion_indicators when exit_signal=true" {
    # Source the response analyzer library
    [[ -f "${BATS_TEST_DIRNAME}/../../lib/response_analyzer.sh" ]] || skip "response_analyzer.sh removed (SKILLS-3)"
    source "${BATS_TEST_DIRNAME}/../../lib/response_analyzer.sh"

    # Initialize exit signals file
    echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": []}' > "$EXIT_SIGNALS_FILE"

    # Create analysis file with exit_signal=true
    cat > "$RESPONSE_ANALYSIS_FILE" << 'EOF'
{
    "loop_number": 1,
    "timestamp": "2026-01-12T10:00:00Z",
    "output_format": "json",
    "analysis": {
        "has_completion_signal": true,
        "is_test_only": false,
        "is_stuck": false,
        "has_progress": false,
        "files_modified": 0,
        "confidence_score": 100,
        "exit_signal": true,
        "work_summary": "All tasks complete"
    }
}
EOF

    # Call update_exit_signals
    update_exit_signals "$RESPONSE_ANALYSIS_FILE" "$EXIT_SIGNALS_FILE"

    # Verify completion_indicators WAS incremented
    local indicator_count=$(jq '.completion_indicators | length' "$EXIT_SIGNALS_FILE")
    assert_equal "$indicator_count" "1"

    # Verify the loop number was recorded
    local loop_recorded=$(jq '.completion_indicators[0]' "$EXIT_SIGNALS_FILE")
    assert_equal "$loop_recorded" "1"
}

# Test 34: update_exit_signals accumulates completion_indicators only on exit_signal=true
@test "update_exit_signals accumulates completion_indicators only when exit_signal=true" {
    # Source the response analyzer library
    [[ -f "${BATS_TEST_DIRNAME}/../../lib/response_analyzer.sh" ]] || skip "response_analyzer.sh removed (SKILLS-3)"
    source "${BATS_TEST_DIRNAME}/../../lib/response_analyzer.sh"

    # Initialize exit signals file
    echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": []}' > "$EXIT_SIGNALS_FILE"

    # Loop 1: exit_signal=false (should NOT add)
    cat > "$RESPONSE_ANALYSIS_FILE" << 'EOF'
{
    "loop_number": 1,
    "analysis": {
        "has_completion_signal": false,
        "is_test_only": false,
        "has_progress": true,
        "confidence_score": 80,
        "exit_signal": false
    }
}
EOF
    update_exit_signals "$RESPONSE_ANALYSIS_FILE" "$EXIT_SIGNALS_FILE"

    # Loop 2: exit_signal=false (should NOT add)
    cat > "$RESPONSE_ANALYSIS_FILE" << 'EOF'
{
    "loop_number": 2,
    "analysis": {
        "has_completion_signal": true,
        "is_test_only": false,
        "has_progress": true,
        "confidence_score": 90,
        "exit_signal": false
    }
}
EOF
    update_exit_signals "$RESPONSE_ANALYSIS_FILE" "$EXIT_SIGNALS_FILE"

    # Loop 3: exit_signal=true (SHOULD add)
    cat > "$RESPONSE_ANALYSIS_FILE" << 'EOF'
{
    "loop_number": 3,
    "analysis": {
        "has_completion_signal": true,
        "is_test_only": false,
        "has_progress": false,
        "confidence_score": 100,
        "exit_signal": true
    }
}
EOF
    update_exit_signals "$RESPONSE_ANALYSIS_FILE" "$EXIT_SIGNALS_FILE"

    # Verify only 1 completion indicator (from loop 3)
    local indicator_count=$(jq '.completion_indicators | length' "$EXIT_SIGNALS_FILE")
    assert_equal "$indicator_count" "1"

    local loop_recorded=$(jq '.completion_indicators[0]' "$EXIT_SIGNALS_FILE")
    assert_equal "$loop_recorded" "3"
}

# Test 35: JSON mode simulation - 5 loops with exit_signal=false should NOT trigger safety breaker
@test "update_exit_signals JSON mode - 5 loops with exit_signal=false does not fill completion_indicators" {
    # Source the response analyzer library
    [[ -f "${BATS_TEST_DIRNAME}/../../lib/response_analyzer.sh" ]] || skip "response_analyzer.sh removed (SKILLS-3)"
    source "${BATS_TEST_DIRNAME}/../../lib/response_analyzer.sh"

    # Initialize exit signals file
    echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": []}' > "$EXIT_SIGNALS_FILE"

    # Simulate 5 JSON mode loops with high confidence but exit_signal=false
    # This is the exact scenario that caused the bug
    for i in 1 2 3 4 5; do
        cat > "$RESPONSE_ANALYSIS_FILE" << EOF
{
    "loop_number": $i,
    "output_format": "json",
    "analysis": {
        "has_completion_signal": false,
        "is_test_only": false,
        "has_progress": true,
        "files_modified": 3,
        "confidence_score": 70,
        "exit_signal": false,
        "work_summary": "Working on feature $i"
    }
}
EOF
        update_exit_signals "$RESPONSE_ANALYSIS_FILE" "$EXIT_SIGNALS_FILE"
    done

    # Verify completion_indicators is EMPTY (not filled with 5 indicators)
    local indicator_count=$(jq '.completion_indicators | length' "$EXIT_SIGNALS_FILE")
    assert_equal "$indicator_count" "0"
}

# =============================================================================
# PERMISSION DENIAL EXIT TESTS (Issue #101)
# =============================================================================
# When Claude Code is denied permission to run commands, Ralph should detect
# this from the permission_denials field and halt the loop to allow user intervention.

# Helper function with permission denial support
should_exit_gracefully_with_denials() {
    if [[ ! -f "$EXIT_SIGNALS_FILE" ]]; then
        echo ""
        return 1
    fi

    local signals=$(cat "$EXIT_SIGNALS_FILE")

    local recent_test_loops
    local recent_done_signals
    local recent_completion_indicators

    recent_test_loops=$(echo "$signals" | jq '.test_only_loops | length' 2>/dev/null || echo "0")
    recent_done_signals=$(echo "$signals" | jq '.done_signals | length' 2>/dev/null || echo "0")
    recent_completion_indicators=$(echo "$signals" | jq '.completion_indicators | length' 2>/dev/null || echo "0")

    # Check for permission denials first (highest priority - Issue #101)
    if [[ -f "$RESPONSE_ANALYSIS_FILE" ]]; then
        local has_permission_denials=$(jq -r '.analysis.has_permission_denials // false' "$RESPONSE_ANALYSIS_FILE" 2>/dev/null || echo "false")
        if [[ "$has_permission_denials" == "true" ]]; then
            echo "permission_denied"
            return 0
        fi
    fi

    # 1. Too many consecutive test-only loops
    if [[ $recent_test_loops -ge $MAX_CONSECUTIVE_TEST_LOOPS ]]; then
        echo "test_saturation"
        return 0
    fi

    # 2. Multiple "done" signals
    if [[ $recent_done_signals -ge $MAX_CONSECUTIVE_DONE_SIGNALS ]]; then
        echo "completion_signals"
        return 0
    fi

    # 3. Strong completion indicators (only if Claude's EXIT_SIGNAL is true)
    local claude_exit_signal="false"
    if [[ -f "$RESPONSE_ANALYSIS_FILE" ]]; then
        claude_exit_signal=$(jq -r '.analysis.exit_signal // false' "$RESPONSE_ANALYSIS_FILE" 2>/dev/null || echo "false")
    fi

    if [[ $recent_completion_indicators -ge 2 ]] && [[ "$claude_exit_signal" == "true" ]]; then
        echo "project_complete"
        return 0
    fi

    echo ""
    return 1
}

# Test 36: Exit on permission denial detected
@test "should_exit_gracefully exits on permission_denied" {
    echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": []}' > "$EXIT_SIGNALS_FILE"

    # Create response analysis with permission denials
    cat > "$RESPONSE_ANALYSIS_FILE" << 'EOF'
{
    "loop_number": 1,
    "output_format": "json",
    "analysis": {
        "has_completion_signal": false,
        "is_test_only": false,
        "is_stuck": false,
        "has_progress": false,
        "files_modified": 0,
        "confidence_score": 70,
        "exit_signal": false,
        "work_summary": "Tried to run npm install but permission denied",
        "has_permission_denials": true,
        "permission_denial_count": 1,
        "denied_commands": ["npm install"]
    }
}
EOF

    result=$(should_exit_gracefully_with_denials)
    assert_equal "$result" "permission_denied"
}

# Test 37: No exit when no permission denials
@test "should_exit_gracefully continues when no permission denials" {
    echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": []}' > "$EXIT_SIGNALS_FILE"

    # Create response analysis without permission denials
    cat > "$RESPONSE_ANALYSIS_FILE" << 'EOF'
{
    "loop_number": 1,
    "output_format": "json",
    "analysis": {
        "has_completion_signal": false,
        "is_test_only": false,
        "is_stuck": false,
        "has_progress": true,
        "files_modified": 3,
        "confidence_score": 70,
        "exit_signal": false,
        "work_summary": "Implementing feature",
        "has_permission_denials": false,
        "permission_denial_count": 0,
        "denied_commands": []
    }
}
EOF

    result=$(should_exit_gracefully_with_denials || true)
    assert_equal "$result" ""
}

# Test 38: Permission denial takes priority over other signals
@test "permission_denied takes priority over test_saturation" {
    # Set up test saturation condition
    echo '{"test_only_loops": [1,2,3], "done_signals": [], "completion_indicators": []}' > "$EXIT_SIGNALS_FILE"

    # Create response analysis with permission denials
    cat > "$RESPONSE_ANALYSIS_FILE" << 'EOF'
{
    "loop_number": 3,
    "analysis": {
        "is_test_only": true,
        "has_permission_denials": true,
        "permission_denial_count": 1,
        "denied_commands": ["npm install"]
    }
}
EOF

    # Permission denied should take priority
    result=$(should_exit_gracefully_with_denials)
    assert_equal "$result" "permission_denied"
}

# Test 39: Multiple permission denials detected
@test "should_exit_gracefully detects multiple permission denials" {
    echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": []}' > "$EXIT_SIGNALS_FILE"

    cat > "$RESPONSE_ANALYSIS_FILE" << 'EOF'
{
    "loop_number": 1,
    "analysis": {
        "has_permission_denials": true,
        "permission_denial_count": 3,
        "denied_commands": ["npm install", "pnpm install", "yarn add lodash"]
    }
}
EOF

    result=$(should_exit_gracefully_with_denials)
    assert_equal "$result" "permission_denied"
}

# Test 40: Missing has_permission_denials field defaults to false (backward compat)
@test "should_exit_gracefully handles missing permission denial fields" {
    echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": []}' > "$EXIT_SIGNALS_FILE"

    # Old format response analysis without permission denial fields
    cat > "$RESPONSE_ANALYSIS_FILE" << 'EOF'
{
    "loop_number": 1,
    "analysis": {
        "has_completion_signal": false,
        "is_test_only": false,
        "exit_signal": false
    }
}
EOF

    result=$(should_exit_gracefully_with_denials || true)
    assert_equal "$result" ""
}

# =============================================================================
# CHECKBOX REGEX FIX TESTS (Issue #144)
# =============================================================================
# These tests verify that date entries like [2026-01-29] are NOT counted as
# checkboxes, preventing false "plan_complete" exits when fix_plan.md contains
# dated entries that match the old [*] pattern.

# Test 41: Date entries should NOT be counted as checkboxes
@test "fix_plan.md date entries are not counted as checkboxes" {
    cat > "$RALPH_DIR/fix_plan.md" << 'EOF'
# Fix Plan

## Changelog
- [2026-01-29] Initial version
- [2026-01-30] Added feature X
- [2026-01-31] Bug fixes

## Tasks
- [ ] Task 1 pending
- [ ] Task 2 pending
EOF

    result=$(should_exit_gracefully || true)
    # Should NOT exit - there are 2 uncompleted tasks
    assert_equal "$result" ""
}

# Test 42: Date entries mixed with completed tasks should not cause false exit
@test "fix_plan.md with dates and completed tasks counts correctly" {
    cat > "$RALPH_DIR/fix_plan.md" << 'EOF'
# Fix Plan

## Changelog
- [2026-01-29] Initial version

## Tasks
- [x] Task 1 complete
- [ ] Task 2 pending
EOF

    result=$(should_exit_gracefully || true)
    # 1 completed, 1 pending - should NOT exit
    assert_equal "$result" ""
}

# Test 43: Non-checkbox bracket patterns (NOTE, TODO, FIXME) should be excluded
@test "fix_plan.md bracket patterns like [NOTE] are not checkboxes" {
    cat > "$RALPH_DIR/fix_plan.md" << 'EOF'
# Fix Plan

## Notes
- [NOTE] Remember to update docs
- [TODO] Consider refactoring later
- [FIXME] Known issue with edge case
- [WIP] Work in progress

## Tasks
- [ ] Task 1 pending
EOF

    result=$(should_exit_gracefully || true)
    # Only 1 real task (pending) - should NOT exit
    assert_equal "$result" ""
}

# Test 44: Case-insensitive completed checkboxes ([x] and [X])
@test "fix_plan.md counts both [x] and [X] as completed" {
    cat > "$RALPH_DIR/fix_plan.md" << 'EOF'
# Fix Plan
- [x] Task 1 with lowercase x
- [X] Task 2 with uppercase X
- [x] Task 3 with lowercase x
EOF

    result=$(should_exit_gracefully)
    # All 3 tasks completed - should exit with plan_complete
    assert_equal "$result" "plan_complete"
}

# Test 45: Indented date entries should not be counted
@test "fix_plan.md indented date entries are not checkboxes" {
    cat > "$RALPH_DIR/fix_plan.md" << 'EOF'
# Fix Plan

## Releases
  - [2026-01-29] v1.0.0 released
    - [2026-01-30] v1.0.1 patch

## Tasks
- [x] All done
EOF

    result=$(should_exit_gracefully)
    # Only 1 real task (completed) - should exit
    assert_equal "$result" "plan_complete"
}

# Test 46: Empty checkbox [ ] with spaces should be counted as uncompleted
@test "fix_plan.md empty checkboxes with extra spaces" {
    cat > "$RALPH_DIR/fix_plan.md" << 'EOF'
# Fix Plan
- [ ] Task with single space (valid)
- [  ] Task with double space (invalid format, not counted)
- [x] Completed task
EOF

    result=$(should_exit_gracefully || true)
    # 1 uncompleted, 1 completed - should NOT exit
    assert_equal "$result" ""
}

# Test 47: Version numbers in brackets should not be counted
@test "fix_plan.md version numbers like [v1.0] are not checkboxes" {
    cat > "$RALPH_DIR/fix_plan.md" << 'EOF'
# Fix Plan

## Version History
- [v1.0] Initial release
- [v1.1] Added features
- [v2.0] Major update

## Tasks
- [x] Task complete
EOF

    result=$(should_exit_gracefully)
    # Only 1 real task (completed) - should exit
    assert_equal "$result" "plan_complete"
}

# Test 48: Issue/PR references should not be counted
@test "fix_plan.md issue references like [#123] are not checkboxes" {
    cat > "$RALPH_DIR/fix_plan.md" << 'EOF'
# Fix Plan

## Related Issues
- [#141] Progress detection bug
- [#144] Checkbox regex false positives
- [PR#155] Setup improvements

## Tasks
- [ ] Fix issue #141
- [ ] Fix issue #144
EOF

    result=$(should_exit_gracefully || true)
    # 2 uncompleted tasks - should NOT exit
    assert_equal "$result" ""
}

# =============================================================================
# GIT COMMIT DETECTION TESTS (Issue #141)
# =============================================================================
# These tests verify that when Claude commits within a loop, the committed files
# are counted as progress even though there are no uncommitted changes.

# Helper function to detect progress including git commits
detect_progress_with_commits() {
    local loop_start_sha="$1"
    local current_sha="$2"
    local files_changed=0

    # Check for committed changes since loop start
    if [[ -n "$loop_start_sha" && -n "$current_sha" && "$loop_start_sha" != "$current_sha" ]]; then
        # Files changed in commits between loop start and current HEAD
        files_changed=$(git diff --name-only "$loop_start_sha" "$current_sha" 2>/dev/null | wc -l || echo 0)
        files_changed=$(echo "$files_changed" | tr -d ' ')
    else
        # Fall back to uncommitted changes
        files_changed=$(git diff --name-only 2>/dev/null | wc -l || echo 0)
        files_changed=$(echo "$files_changed" | tr -d ' ')
    fi

    echo "$files_changed"
}

# Test 49: Git commit detection - files changed in commit count as progress
@test "git commit detection counts committed files as progress" {
    # Skip if git is not available
    if ! command -v git &>/dev/null; then
        skip "git not available"
    fi

    # Initialize a git repo
    git init --quiet
    git config user.email "test@test.com"
    git config user.name "Test"

    # Create initial commit
    echo "initial" > file1.txt
    git add file1.txt
    git commit --quiet -m "Initial commit"

    local loop_start_sha=$(git rev-parse HEAD)

    # Simulate Claude making changes and committing within the loop
    echo "modified" > file1.txt
    echo "new file" > file2.txt
    git add file1.txt file2.txt
    git commit --quiet -m "Claude's work"

    local current_sha=$(git rev-parse HEAD)

    # Detect progress
    local files_changed=$(detect_progress_with_commits "$loop_start_sha" "$current_sha")

    # Should detect 2 files changed
    [ "$files_changed" -eq 2 ]
}

# Test 50: Git commit detection - no progress when SHA unchanged
@test "git commit detection returns 0 when no commits made" {
    # Skip if git is not available
    if ! command -v git &>/dev/null; then
        skip "git not available"
    fi

    # Initialize a git repo
    git init --quiet
    git config user.email "test@test.com"
    git config user.name "Test"

    # Create initial commit
    echo "initial" > file1.txt
    git add file1.txt
    git commit --quiet -m "Initial commit"

    local loop_start_sha=$(git rev-parse HEAD)
    local current_sha=$(git rev-parse HEAD)

    # No uncommitted changes either
    local files_changed=$(detect_progress_with_commits "$loop_start_sha" "$current_sha")

    # Should detect 0 files (no commits, no uncommitted changes)
    [ "$files_changed" -eq 0 ]
}

# Test 51: Git commit detection - falls back to uncommitted when no commit
@test "git commit detection falls back to uncommitted changes" {
    # Skip if git is not available
    if ! command -v git &>/dev/null; then
        skip "git not available"
    fi

    # Initialize a git repo
    git init --quiet
    git config user.email "test@test.com"
    git config user.name "Test"

    # Create initial commit with two tracked files
    echo "initial1" > file1.txt
    echo "initial2" > file2.txt
    git add file1.txt file2.txt
    git commit --quiet -m "Initial commit"

    local loop_start_sha=$(git rev-parse HEAD)

    # Make uncommitted changes to tracked files (no commit)
    echo "modified1" > file1.txt
    echo "modified2" > file2.txt

    local current_sha=$(git rev-parse HEAD)  # Same as loop_start_sha

    # Detect progress - should fall back to uncommitted changes
    # Note: git diff only shows modified tracked files, not untracked files
    local files_changed=$(detect_progress_with_commits "$loop_start_sha" "$current_sha")

    # Should detect 2 uncommitted modified files
    [ "$files_changed" -eq 2 ]
}

# Test 52: Git commit detection - multiple commits within loop
@test "git commit detection counts files across multiple commits" {
    # Skip if git is not available
    if ! command -v git &>/dev/null; then
        skip "git not available"
    fi

    # Initialize a git repo
    git init --quiet
    git config user.email "test@test.com"
    git config user.name "Test"

    # Create initial commit
    echo "initial" > file1.txt
    git add file1.txt
    git commit --quiet -m "Initial commit"

    local loop_start_sha=$(git rev-parse HEAD)

    # First commit within loop
    echo "change1" > file1.txt
    git add file1.txt
    git commit --quiet -m "First change"

    # Second commit within loop
    echo "new" > file2.txt
    git add file2.txt
    git commit --quiet -m "Second change"

    # Third commit within loop
    echo "another" > file3.txt
    git add file3.txt
    git commit --quiet -m "Third change"

    local current_sha=$(git rev-parse HEAD)

    # Detect progress
    local files_changed=$(detect_progress_with_commits "$loop_start_sha" "$current_sha")

    # Should detect 3 files (one per commit)
    [ "$files_changed" -eq 3 ]
}

# Test 53: Git commit detection handles empty loop_start_sha
@test "git commit detection handles missing loop_start_sha" {
    # Skip if git is not available
    if ! command -v git &>/dev/null; then
        skip "git not available"
    fi

    # Initialize a git repo
    git init --quiet
    git config user.email "test@test.com"
    git config user.name "Test"

    # Create initial commit
    echo "initial" > file1.txt
    git add file1.txt
    git commit --quiet -m "Initial commit"

    # Make uncommitted changes
    echo "modified" > file1.txt

    local current_sha=$(git rev-parse HEAD)

    # Detect progress with empty loop_start_sha
    local files_changed=$(detect_progress_with_commits "" "$current_sha")

    # Should fall back to uncommitted changes (1 file)
    [ "$files_changed" -eq 1 ]
}

# =============================================================================
# QUESTION DETECTION VIA ON-STOP.SH HOOK (USYNC-1, upstream #190)
# =============================================================================

@test "on-stop.sh sets asking_questions=true when response contains question patterns" {
    command -v jq &>/dev/null || skip "jq not available"

    mkdir -p "$RALPH_DIR/logs"

    # Create a mock circuit breaker state for the hook
    cat > "$RALPH_DIR/.circuit_breaker_state" << 'EOF'
{"state":"CLOSED","last_change":"2026-01-01T00:00:00Z","consecutive_no_progress":0,"consecutive_permission_denials":0,"total_opens":0,"reason":""}
EOF

    # Simulate response with question patterns
    local hook_script="${BATS_TEST_DIRNAME}/../../templates/hooks/on-stop.sh"
    [[ -f "$hook_script" ]] || skip "on-stop.sh hook not found"

    local response='{"result":"Should I implement approach A or B? Which option do you prefer?"}'

    CLAUDE_PROJECT_DIR="." run bash -c "echo '$response' | bash '$hook_script'"

    assert_success

    # Check status.json was written with question detection
    [[ -f "$RALPH_DIR/status.json" ]] || fail "status.json not created"
    local asking=$(jq -r '.asking_questions' "$RALPH_DIR/status.json")
    assert_equal "$asking" "true"

    local q_count=$(jq -r '.question_count' "$RALPH_DIR/status.json")
    [[ "$q_count" -gt 0 ]] || fail "question_count should be > 0, got $q_count"
}

@test "on-stop.sh sets asking_questions=false for normal implementation output" {
    command -v jq &>/dev/null || skip "jq not available"

    mkdir -p "$RALPH_DIR/logs"

    cat > "$RALPH_DIR/.circuit_breaker_state" << 'EOF'
{"state":"CLOSED","last_change":"2026-01-01T00:00:00Z","consecutive_no_progress":0,"consecutive_permission_denials":0,"total_opens":0,"reason":""}
EOF

    local hook_script="${BATS_TEST_DIRNAME}/../../templates/hooks/on-stop.sh"
    [[ -f "$hook_script" ]] || skip "on-stop.sh hook not found"

    local response='{"result":"Implementing feature X. All tests passed successfully. Files modified: 3."}'

    CLAUDE_PROJECT_DIR="." run bash -c "echo '$response' | bash '$hook_script'"

    assert_success

    [[ -f "$RALPH_DIR/status.json" ]] || fail "status.json not created"
    local asking=$(jq -r '.asking_questions' "$RALPH_DIR/status.json")
    assert_equal "$asking" "false"

    local q_count=$(jq -r '.question_count' "$RALPH_DIR/status.json")
    assert_equal "$q_count" "0"
}

@test "on-stop.sh detects permission denials in response (USYNC-4)" {
    command -v jq &>/dev/null || skip "jq not available"

    mkdir -p "$RALPH_DIR/logs"

    cat > "$RALPH_DIR/.circuit_breaker_state" << 'EOF'
{"state":"CLOSED","last_change":"2026-01-01T00:00:00Z","consecutive_no_progress":0,"consecutive_permission_denials":0,"total_opens":0,"reason":""}
EOF

    local hook_script="${BATS_TEST_DIRNAME}/../../templates/hooks/on-stop.sh"
    [[ -f "$hook_script" ]] || skip "on-stop.sh hook not found"

    local response='{"result":"Error: tool not allowed: Bash(rm -rf /). Permission denied for destructive command."}'

    CLAUDE_PROJECT_DIR="." run bash -c "echo '$response' | bash '$hook_script'"

    assert_success

    [[ -f "$RALPH_DIR/status.json" ]] || fail "status.json not created"
    local has_pd=$(jq -r '.has_permission_denials' "$RALPH_DIR/status.json")
    assert_equal "$has_pd" "true"
}

@test "on-stop.sh does not increment CB no-progress for question loops (USYNC-3)" {
    command -v jq &>/dev/null || skip "jq not available"

    mkdir -p "$RALPH_DIR/logs"

    # Start with 2 consecutive no-progress loops (one away from threshold)
    cat > "$RALPH_DIR/.circuit_breaker_state" << 'EOF'
{"state":"CLOSED","last_change":"2026-01-01T00:00:00Z","consecutive_no_progress":2,"consecutive_permission_denials":0,"total_opens":0,"reason":""}
EOF

    local hook_script="${BATS_TEST_DIRNAME}/../../templates/hooks/on-stop.sh"
    [[ -f "$hook_script" ]] || skip "on-stop.sh hook not found"

    # Response with questions — should NOT increment no-progress
    local response='{"result":"Should I use approach A or B? What do you think?"}'

    CLAUDE_PROJECT_DIR="." run bash -c "echo '$response' | bash '$hook_script'"

    assert_success

    # CB should still be CLOSED — question loops suppress no-progress
    local cb_state=$(jq -r '.state' "$RALPH_DIR/.circuit_breaker_state")
    assert_equal "$cb_state" "CLOSED"

    local no_progress=$(jq -r '.consecutive_no_progress' "$RALPH_DIR/.circuit_breaker_state")
    assert_equal "$no_progress" "2"  # Should NOT have incremented to 3
}

# =============================================================================
# STUCK-LOOP DETECTION (USYNC-5)
# =============================================================================

@test "detect_stuck_loop returns 1 when no errors in current output" {
    source "${BATS_TEST_DIRNAME}/../../ralph_loop.sh" 2>/dev/null || true
    # Source just the function we need
    eval "$(sed -n '/^detect_stuck_loop()/,/^}/p' "${BATS_TEST_DIRNAME}/../../ralph_loop.sh")"

    mkdir -p "$RALPH_DIR/logs"
    export LOG_DIR="$RALPH_DIR/logs"

    echo "Implementing feature. All tests passed." > "$RALPH_DIR/logs/claude_output_current.log"

    run detect_stuck_loop "$RALPH_DIR/logs/claude_output_current.log"

    assert_failure  # return 1 = not stuck
}

@test "detect_stuck_loop returns 0 when same errors repeat in 3+ outputs" {
    eval "$(sed -n '/^detect_stuck_loop()/,/^}/p' "${BATS_TEST_DIRNAME}/../../ralph_loop.sh")"
    eval "$(sed -n '/^log_status()/,/^}/p' "${BATS_TEST_DIRNAME}/../../ralph_loop.sh" 2>/dev/null)" || log_status() { :; }

    mkdir -p "$RALPH_DIR/logs"
    export LOG_DIR="$RALPH_DIR/logs"

    # Create 3 historical outputs with the same error
    for i in 1 2 3; do
        echo "Error: EACCES permission denied /etc/passwd" > "$RALPH_DIR/logs/claude_output_${i}.log"
        sleep 0.1  # Ensure different mtime for ls -t ordering
    done

    # Current output with same error
    echo "Error: EACCES permission denied /etc/passwd" > "$RALPH_DIR/logs/claude_output_current.log"

    # Need status.json for the jq update
    echo '{}' > "$RALPH_DIR/status.json"

    run detect_stuck_loop "$RALPH_DIR/logs/claude_output_current.log"

    assert_success  # return 0 = stuck
}

@test "detect_stuck_loop returns 1 when errors differ across outputs" {
    eval "$(sed -n '/^detect_stuck_loop()/,/^}/p' "${BATS_TEST_DIRNAME}/../../ralph_loop.sh")"

    mkdir -p "$RALPH_DIR/logs"
    export LOG_DIR="$RALPH_DIR/logs"

    echo "Error: file not found" > "$RALPH_DIR/logs/claude_output_1.log"
    sleep 0.1
    echo "Error: network timeout" > "$RALPH_DIR/logs/claude_output_2.log"
    sleep 0.1
    echo "Error: syntax error" > "$RALPH_DIR/logs/claude_output_3.log"
    sleep 0.1

    echo "Error: EACCES permission denied" > "$RALPH_DIR/logs/claude_output_current.log"

    run detect_stuck_loop "$RALPH_DIR/logs/claude_output_current.log"

    assert_failure  # return 1 = not stuck (different errors)
}

@test "detect_stuck_loop ignores JSON field false positives" {
    eval "$(sed -n '/^detect_stuck_loop()/,/^}/p' "${BATS_TEST_DIRNAME}/../../ralph_loop.sh")"

    mkdir -p "$RALPH_DIR/logs"
    export LOG_DIR="$RALPH_DIR/logs"

    # JSON with "is_error": false is not an actual error
    for i in 1 2 3; do
        echo '{"is_error": false, "result": "Success"}' > "$RALPH_DIR/logs/claude_output_${i}.log"
        sleep 0.1
    done

    echo '{"is_error": false, "result": "Success"}' > "$RALPH_DIR/logs/claude_output_current.log"

    run detect_stuck_loop "$RALPH_DIR/logs/claude_output_current.log"

    assert_failure  # return 1 = not stuck (no real errors)
}

# =============================================================================
# CORRECTIVE GUIDANCE INJECTION (USYNC-2, upstream #190)
# =============================================================================

@test "build_loop_context includes question guidance when asking_questions=true" {
    # Write status.json with asking_questions=true
    cat > "$RALPH_DIR/status.json" << 'EOF'
{"asking_questions": true, "question_count": 3, "recommendation": ""}
EOF

    # Source just build_loop_context
    log_status() { :; }  # stub
    ralph_inject_continue_state() { :; }  # stub
    export RALPH_CONTINUE_STATE_FILE="/nonexistent"

    eval "$(sed -n '/^build_loop_context()/,/^}/p' "${BATS_TEST_DIRNAME}/../../ralph_loop.sh")"

    run build_loop_context 5

    assert_success
    [[ "$output" == *"Do NOT ask questions"* ]] || fail "Expected corrective guidance, got: $output"
}

@test "build_loop_context does not include question guidance when asking_questions=false" {
    cat > "$RALPH_DIR/status.json" << 'EOF'
{"asking_questions": false, "question_count": 0, "recommendation": ""}
EOF

    log_status() { :; }
    ralph_inject_continue_state() { :; }
    export RALPH_CONTINUE_STATE_FILE="/nonexistent"

    eval "$(sed -n '/^build_loop_context()/,/^}/p' "${BATS_TEST_DIRNAME}/../../ralph_loop.sh")"

    run build_loop_context 5

    assert_success
    [[ "$output" != *"Do NOT ask questions"* ]] || fail "Should not inject guidance when asking_questions=false"
}

# --- Stale Exit Signals Tests (Issue #194) ---

@test "startup resets stale exit signals before main loop" {
    # Verify ralph_loop.sh resets EXIT_SIGNALS_FILE before the while-true loop
    # This is the primary fix for #194: stale signals from a prior run
    # must not cause immediate exit on next invocation
    local script="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

    # Find the "Starting main loop" log message (just before while true)
    local main_loop_line
    main_loop_line=$(grep -n 'Starting main loop' "$script" | head -1 | cut -d: -f1)
    [[ -n "$main_loop_line" ]]

    # Find the exit signals reset that should appear BEFORE the main loop
    local reset_line
    reset_line=$(grep -n 'Reset exit signals\|reset.*exit.*signal' "$script" | awk -F: -v limit="$main_loop_line" '$1 < limit {print $1}' | tail -1)
    [[ -n "$reset_line" ]]

    # The reset block must reference EXIT_SIGNALS_FILE
    local reset_context
    reset_context=$(sed -n "$((reset_line-3)),$((reset_line+3))p" "$script")
    echo "$reset_context" | grep -q 'EXIT_SIGNALS_FILE'
}

@test "stale exit signals do not cause premature exit" {
    # Simulate: previous run left stale completion_indicators in .exit_signals
    # A fresh should_exit_gracefully() call after reset should NOT exit
    echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": [1, 2, 3, 4, 5]}' > "$EXIT_SIGNALS_FILE"

    # Create stale .response_analysis with exit_signal=true
    cat > "$RESPONSE_ANALYSIS_FILE" << 'EOF'
{"loop_number": 5, "analysis": {"exit_signal": true, "confidence_score": 90}}
EOF

    # Before reset: should_exit_gracefully would trigger safety_circuit_breaker
    run should_exit_gracefully
    [[ "$output" != "" ]]  # Would exit

    # Simulate startup reset (what main() now does before the loop)
    echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": []}' > "$EXIT_SIGNALS_FILE"
    rm -f "$RESPONSE_ANALYSIS_FILE"

    # After reset: should_exit_gracefully should NOT trigger
    run should_exit_gracefully
    [[ "$output" == "" ]]
}

@test "should_exit_gracefully logs diagnostic signal counts" {
    # Verify that should_exit_gracefully() logs signal counts for diagnosability
    local script="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

    # Extract the function body
    local func_body
    func_body=$(sed -n '/^should_exit_gracefully()/,/^}/p' "$script")

    # Should contain diagnostic logging of signal counts
    echo "$func_body" | grep -q 'recent_test_loops\|recent_done_signals\|recent_completion_indicators'
    # Should have a log_status call that includes signal counts for debugging
    echo "$func_body" | grep -q 'log_status.*signal\|log_status.*exit.*check\|log_status.*DEBUG.*indicator'
}

@test "API limit user-exit path calls reset_session" {
    # The "user chose to exit" path for API limits must call reset_session
    # to prevent stale .exit_signals from causing premature exit on next run
    local script="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

    # Find the API limit user exit block
    local exit_block
    exit_block=$(sed -n '/user_choice.*==.*"2"/,/break/p' "$script")

    # Must call reset_session before break
    echo "$exit_block" | grep -q 'reset_session'
}

# =============================================================================
# COMPLETION INDICATOR DECAY TESTS (Issue #224)
# =============================================================================
# These tests verify that completion_indicators reset (decay) when productive
# work happens between exit signals, preventing false-positive completions
# where Claude says "done" early, does more work, then says "done" again.

# Helper: inline version of update_exit_signals_from_status (from ralph_loop.sh)
# Needed because ralph_loop.sh can't be sourced directly (has main execution).
update_exit_signals_from_status() {
    local status_file="${RALPH_DIR}/status.json"
    local exit_signals_file="${EXIT_SIGNALS_FILE}"

    if [[ ! -f "$status_file" ]]; then
        return 1
    fi

    local exit_signal status tasks_completed files_modified work_type loop_number
    local _status_tsv
    _status_tsv=$(jq -r '[
      (.exit_signal // "false"),
      (.status // "UNKNOWN"),
      (.tasks_completed // 0 | tostring),
      (.files_modified // 0 | tostring),
      (.work_type // "UNKNOWN"),
      (.loop_count // 0 | tostring)
    ] | @tsv' "$status_file" 2>/dev/null || echo "false	UNKNOWN	0	0	UNKNOWN	0")
    IFS=$'\t' read -r exit_signal status tasks_completed files_modified work_type loop_number <<< "$_status_tsv"

    local is_test_only="false"
    [[ "$work_type" == "TESTING" ]] && is_test_only="true"

    local has_completion_signal="false"
    [[ "$status" == "COMPLETE" ]] && has_completion_signal="true"

    local has_progress="false"
    [[ "$files_modified" -gt 0 || "$tasks_completed" -gt 0 ]] && has_progress="true"

    local signals
    signals=$(jq \
        --argjson loop "$loop_number" \
        --arg test_only "$is_test_only" \
        --arg complete "$has_completion_signal" \
        --arg exit_sig "$exit_signal" \
        --arg progress "$has_progress" '
      (if $test_only == "true" then .test_only_loops += [$loop]
       elif $progress == "true" then .test_only_loops = []
       else . end) |
      (if $complete == "true" then .done_signals += [$loop] else . end) |
      (if $exit_sig == "true" then .completion_indicators += [$loop]
       elif $progress == "true" then .completion_indicators = []
       else . end) |
      .test_only_loops = .test_only_loops[-5:] |
      .done_signals = .done_signals[-5:] |
      .completion_indicators = .completion_indicators[-5:]
    ' "$exit_signals_file" 2>/dev/null || echo '{"test_only_loops":[],"done_signals":[],"completion_indicators":[]}')

    echo "$signals" > "$exit_signals_file"
    return 0
}

# Test 54: Completion indicators reset on productive work
@test "completion_indicators reset when progress detected between exit signals" {
    # Setup: status.json with exit_signal=false but progress=true
    cat > "$RALPH_DIR/status.json" << 'EOF'
{
    "exit_signal": false,
    "status": "IN_PROGRESS",
    "tasks_completed": 2,
    "files_modified": 5,
    "work_type": "IMPLEMENTATION",
    "loop_count": 3
}
EOF

    # Pre-seed completion_indicators (simulating a previous EXIT_SIGNAL=true)
    echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": [1]}' > "$EXIT_SIGNALS_FILE"

    # Run update — should reset completion_indicators since there's progress and exit_signal=false
    update_exit_signals_from_status

    # Check that completion_indicators was reset
    local indicators
    indicators=$(jq '.completion_indicators | length' "$EXIT_SIGNALS_FILE")
    assert_equal "$indicators" "0"
}

# Test 55: Completion indicators still accumulate on true exit signals
@test "completion_indicators accumulate when exit_signal is true" {
    cat > "$RALPH_DIR/status.json" << 'EOF'
{
    "exit_signal": true,
    "status": "COMPLETE",
    "tasks_completed": 0,
    "files_modified": 0,
    "work_type": "TESTING",
    "loop_count": 4
}
EOF

    echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": [1]}' > "$EXIT_SIGNALS_FILE"

    update_exit_signals_from_status

    local indicators
    indicators=$(jq '.completion_indicators | length' "$EXIT_SIGNALS_FILE")
    assert_equal "$indicators" "2"
}

# Test 56: Full scenario - exit signal, productive work, exit signal should not trigger exit
@test "productive work between exit signals prevents false-positive completion" {
    # Loop 1: Claude says "done" (exit_signal=true)
    cat > "$RALPH_DIR/status.json" << 'EOF'
{
    "exit_signal": true,
    "status": "COMPLETE",
    "tasks_completed": 1,
    "files_modified": 0,
    "work_type": "IMPLEMENTATION",
    "loop_count": 1
}
EOF
    echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": []}' > "$EXIT_SIGNALS_FILE"
    update_exit_signals_from_status

    local indicators
    indicators=$(jq '.completion_indicators | length' "$EXIT_SIGNALS_FILE")
    assert_equal "$indicators" "1"

    # Loop 2: Productive work happens (exit_signal=false, files_modified > 0)
    cat > "$RALPH_DIR/status.json" << 'EOF'
{
    "exit_signal": false,
    "status": "IN_PROGRESS",
    "tasks_completed": 1,
    "files_modified": 3,
    "work_type": "IMPLEMENTATION",
    "loop_count": 2
}
EOF
    update_exit_signals_from_status

    # completion_indicators should be reset by productive work
    indicators=$(jq '.completion_indicators | length' "$EXIT_SIGNALS_FILE")
    assert_equal "$indicators" "0"

    # Loop 3: Claude says "done" again (exit_signal=true)
    cat > "$RALPH_DIR/status.json" << 'EOF'
{
    "exit_signal": true,
    "status": "COMPLETE",
    "tasks_completed": 0,
    "files_modified": 0,
    "work_type": "IMPLEMENTATION",
    "loop_count": 3
}
EOF
    update_exit_signals_from_status

    # Only 1 indicator now (not 2), so should NOT trigger exit
    indicators=$(jq '.completion_indicators | length' "$EXIT_SIGNALS_FILE")
    assert_equal "$indicators" "1"
}

# Test 57: No progress and no exit signal leaves completion_indicators unchanged
@test "completion_indicators unchanged when no progress and no exit signal" {
    cat > "$RALPH_DIR/status.json" << 'EOF'
{
    "exit_signal": false,
    "status": "UNKNOWN",
    "tasks_completed": 0,
    "files_modified": 0,
    "work_type": "UNKNOWN",
    "loop_count": 5
}
EOF

    # Pre-seed with existing indicators
    echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": [1, 2]}' > "$EXIT_SIGNALS_FILE"

    update_exit_signals_from_status

    # No progress and no exit signal — indicators should remain unchanged
    local indicators
    indicators=$(jq '.completion_indicators | length' "$EXIT_SIGNALS_FILE")
    assert_equal "$indicators" "2"
}
