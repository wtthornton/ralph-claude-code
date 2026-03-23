#!/usr/bin/env bats

# Tests for lib/context_management.sh — Progressive context loading (CTXMGMT-1)
# and Task decomposition signals (CTXMGMT-2)

setup() {
    export RALPH_DIR="$BATS_TEST_TMPDIR/.ralph"
    export RALPH_VERBOSE="false"
    mkdir -p "$RALPH_DIR"
    source "$BATS_TEST_DIRNAME/../../lib/context_management.sh"
}

teardown() {
    rm -rf "$BATS_TEST_TMPDIR/.ralph"
}

# =============================================================================
# CTXMGMT-1: Progressive context loading
# =============================================================================

@test "CTXMGMT-1: progressive context returns full plan when disabled" {
    RALPH_PROGRESSIVE_CONTEXT="false"
    echo "- [ ] Task 1" > "$RALPH_DIR/fix_plan.md"
    result=$(ralph_build_progressive_context)
    [[ "$result" == *"Task 1"* ]]
}

@test "CTXMGMT-1: progressive context limits items to MAX_PLAN_ITEMS" {
    RALPH_PROGRESSIVE_CONTEXT="true"
    RALPH_MAX_PLAN_ITEMS="3"
    cat > "$RALPH_DIR/fix_plan.md" << 'EOF'
# Plan
## Section 1
- [ ] Task 1
- [ ] Task 2
- [ ] Task 3
- [ ] Task 4
- [ ] Task 5
EOF
    result=$(ralph_build_progressive_context)
    # Should include only first 3 (MAX_PLAN_ITEMS=3)
    [[ "$result" == *"Task 1"* ]]
    [[ "$result" == *"Task 3"* ]]
}

@test "CTXMGMT-1: context summary returns JSON" {
    cat > "$RALPH_DIR/fix_plan.md" << 'EOF'
## Epic 1
- [x] Done task
- [ ] Open task
EOF
    result=$(ralph_get_iteration_context_summary)
    echo "$result" | jq . >/dev/null 2>&1  # Valid JSON
    [[ "$(echo "$result" | jq -r '.remaining')" == "1" ]]
}

@test "CTXMGMT-1: token estimation works" {
    result=$(ralph_estimate_context_tokens "1234567890123456")  # 16 chars = ~4 tokens
    [[ "$result" -eq 4 ]]
}

# =============================================================================
# CTXMGMT-2: Decomposition detection
# =============================================================================

@test "CTXMGMT-2: decomposition detects large file count" {
    local task="Fix auth in src/auth.py, src/login.py, src/register.py, src/session.py, src/middleware.py, src/utils.py"
    local result
    result=$(ralph_detect_decomposition_needed "$task" 1)
    echo "$result" | jq -r '.decompose' | grep -q "true"
}

@test "CTXMGMT-2: decomposition not triggered for small tasks" {
    local task="Fix typo in README.md"
    local result
    result=$(ralph_detect_decomposition_needed "$task" 1 || true)
    echo "$result" | jq -r '.decompose' | grep -q "false"
}

@test "CTXMGMT-2: decomposition detects timeout" {
    echo '{"exit_code": 124}' > "$RALPH_DIR/status.json"
    local result
    result=$(ralph_detect_decomposition_needed "Some task" 5)
    echo "$result" | jq -r '.decompose' | grep -q "true"
    echo "$result" | jq -r '.reasons' | grep -q "timed out"
}

@test "CTXMGMT-2: decomposition detects no progress" {
    echo '{"consecutive_no_progress": 4}' > "$RALPH_DIR/status.json"
    local result
    result=$(ralph_detect_decomposition_needed "Some task" 5)
    echo "$result" | jq -r '.decompose' | grep -q "true"
    echo "$result" | jq -r '.reasons' | grep -q "loops without progress"
}

@test "CTXMGMT-2: decomposition returns valid JSON on no-decompose" {
    local result
    result=$(ralph_detect_decomposition_needed "Fix typo" 0 || true)
    # Should be parseable JSON
    echo "$result" | jq empty
    [[ "$(echo "$result" | jq -r '.decompose')" == "false" ]]
}

@test "CTXMGMT-2: decomposition returns valid JSON on decompose" {
    local task="Fix auth.py, login.py, register.py, session.py, middleware.py, utils.py"
    local result
    result=$(ralph_detect_decomposition_needed "$task" 1)
    echo "$result" | jq empty
    [[ "$(echo "$result" | jq -r '.decompose')" == "true" ]]
    [[ -n "$(echo "$result" | jq -r '.recommendation')" ]]
}

@test "CTXMGMT-2: decomposition returns recommendation text" {
    local task="Fix auth.py, login.py, register.py, session.py, middleware.py, utils.py"
    local result
    result=$(ralph_detect_decomposition_needed "$task" 1)
    echo "$result" | jq -r '.recommendation' | grep -q "sub-tasks"
}

@test "CTXMGMT-2: decomposition reasons include file count" {
    local task="Fix auth.py, login.py, register.py, session.py, middleware.py, utils.py"
    local result
    result=$(ralph_detect_decomposition_needed "$task" 1)
    echo "$result" | jq -r '.reasons' | grep -q "files"
}

@test "CTXMGMT-2: decomposition handles empty task text" {
    local result
    result=$(ralph_detect_decomposition_needed "" 0 || true)
    echo "$result" | jq -r '.decompose' | grep -q "false"
}

@test "CTXMGMT-2: decomposition handles missing status file" {
    rm -f "$RALPH_DIR/status.json"
    local result
    result=$(ralph_detect_decomposition_needed "Fix typo" 0 || true)
    echo "$result" | jq empty
}

@test "CTXMGMT-2: decomposition with complexity integration" {
    # Source complexity.sh to enable heuristic #3
    source "$BATS_TEST_DIRNAME/../../lib/complexity.sh"
    local task="[LARGE] Refactor the entire authentication and session management system"
    local result
    result=$(ralph_detect_decomposition_needed "$task" 1)
    echo "$result" | jq -r '.decompose' | grep -q "true"
    echo "$result" | jq -r '.reasons' | grep -q "complexity"
}

# =============================================================================
# CTXMGMT-2: Decomposition hint injection
# =============================================================================

@test "CTXMGMT-2: inject_hint returns empty for non-decompose" {
    local result
    result=$(ralph_inject_decomposition_hint '{"decompose":false}')
    [[ -z "$result" ]]
}

@test "CTXMGMT-2: inject_hint returns guidance for decompose" {
    local result
    result=$(ralph_inject_decomposition_hint '{"decompose":true,"reasons":"mentions 6 files"}')
    echo "$result" | grep -q "DECOMPOSITION RECOMMENDED"
    echo "$result" | grep -q "mentions 6 files"
    echo "$result" | grep -q "sub-tasks"
}

@test "CTXMGMT-2: inject_hint handles empty input" {
    local result
    result=$(ralph_inject_decomposition_hint "")
    [[ -z "$result" ]]
}

@test "CTXMGMT-2: inject_hint includes actionable steps" {
    local result
    result=$(ralph_inject_decomposition_hint '{"decompose":true,"reasons":"test"}')
    echo "$result" | grep -q "Break it into 2-4 sub-tasks"
    echo "$result" | grep -q "fix_plan.md"
    echo "$result" | grep -q "EXIT_SIGNAL: false"
}

# =============================================================================
# CTXMGMT-2: Multiple heuristics combined
# =============================================================================

@test "CTXMGMT-2: multiple reasons combined" {
    echo '{"exit_code": 124, "consecutive_no_progress": 3}' > "$RALPH_DIR/status.json"
    local task="Fix auth.py, login.py, register.py, session.py, middleware.py, utils.py"
    local result
    result=$(ralph_detect_decomposition_needed "$task" 5)
    echo "$result" | jq -r '.decompose' | grep -q "true"
    # Should mention both file count and timeout
    local reasons
    reasons=$(echo "$result" | jq -r '.reasons')
    echo "$reasons" | grep -q "files"
    echo "$reasons" | grep -q "timed out"
}
