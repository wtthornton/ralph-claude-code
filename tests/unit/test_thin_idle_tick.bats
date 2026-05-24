#!/usr/bin/env bats
# TAP-2496: thin idle tick — skip Claude on confirmed-empty backlog.
#
# Goal: when Linear backlog is freshly empty AND coordinator confidence is
# high, the harness emits a synthetic RALPH_STATUS through the same on-stop
# hook path and skips the full Claude invocation. Three thin ticks combine
# with the TAP-2495 quorum to halt cleanly at < $0.10 — vs. AgentForge's
# $1.66 / idle-loop baseline.

bats_require_minimum_version 1.5.0
load '../helpers/test_helper'

REPO_ROOT="${BATS_TEST_DIRNAME}/../.."

setup() {
    export TEST_TEMP_DIR="$(mktemp -d)"
    cd "$TEST_TEMP_DIR"
    export RALPH_DIR="$TEST_TEMP_DIR/.ralph"
    export CLAUDE_PROJECT_DIR="$TEST_TEMP_DIR"
    mkdir -p "$RALPH_DIR/hooks"
    # Copy hook template into the temp ralph dir so _emit_synthetic_idle_status can call it
    cp "$REPO_ROOT/templates/hooks/on-stop.sh" "$RALPH_DIR/hooks/on-stop.sh"
    # Stub date_utils + minimal harness env
    source "$REPO_ROOT/lib/date_utils.sh"
    # ralph_loop.sh expects these globals
    export STATUS_FILE="$RALPH_DIR/status.json"
    export EXIT_SIGNALS_FILE="$RALPH_DIR/.exit_signals"
    export PROJECT_DIR="$TEST_TEMP_DIR"
    # Pre-seed .exit_signals and .ralph_run_id so on-stop hook runs cleanly
    echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": []}' > "$EXIT_SIGNALS_FILE"
    echo "test-run-$$" > "$RALPH_DIR/.ralph_run_id"
    # Session guard
    export RALPH_LOOP_ACTIVE=1
    # Pre-seed brief.json with high coordinator_confidence
    cat > "$RALPH_DIR/brief.json" <<'EOF'
{"schema_version":1,"task_id":"none","task_source":"linear","task_summary":"idle","risk_level":"LOW","affected_modules":[],"acceptance_criteria":["nothing to do"],"prior_learnings":[],"qa_required":false,"qa_scope":"","delegate_to":"ralph","coordinator_confidence":0.95,"created_at":"2026-05-23T00:00:00Z"}
EOF
    # Mock linear_get_open_count → returns 0
    mkdir -p "$TEST_TEMP_DIR/bin"
    cat > "$TEST_TEMP_DIR/bin/linear_get_open_count_mock.sh" <<'EOF'
linear_get_open_count() {
    echo "${MOCK_OPEN_COUNT:-0}"
    return ${MOCK_OPEN_COUNT_EXIT:-0}
}
EOF
    # We'll source the helpers from ralph_loop.sh — extract just the thin idle tick fns
    # by sourcing the whole file is too heavy; we instead test the eligibility logic
    # via a focused harness that re-declares the function shape.
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR"
}

# Helper: source just the thin idle tick functions from ralph_loop.sh
_load_thin_idle_tick_fns() {
    # Extract _thin_idle_tick_eligible + _emit_synthetic_idle_status from ralph_loop.sh
    # into a temp file we can source. Function definitions span until the closing brace
    # at column 0.
    awk '
      /^_thin_idle_tick_eligible\(\) \{/ || /^_emit_synthetic_idle_status\(\) \{/ { in_fn=1 }
      in_fn { print }
      in_fn && /^\}/ { in_fn=0 }
    ' "$REPO_ROOT/ralph_loop.sh" > "$TEST_TEMP_DIR/thin_fns.sh"
    source "$TEST_TEMP_DIR/bin/linear_get_open_count_mock.sh"
    source "$TEST_TEMP_DIR/thin_fns.sh"
}

# =============================================================================
# 1. Eligibility: empty backlog + high confidence + linear mode → eligible
# =============================================================================
@test "TAP-2496: empty backlog + high confidence brief → thin tick eligible" {
    _load_thin_idle_tick_fns
    export RALPH_TASK_SOURCE=linear
    export MOCK_OPEN_COUNT=0
    export MOCK_OPEN_COUNT_EXIT=0
    run _thin_idle_tick_eligible
    assert_success
}

# =============================================================================
# 2. Ineligibility: non-empty backlog → declines
# =============================================================================
@test "TAP-2496: non-empty backlog → thin tick declines (real Claude call)" {
    _load_thin_idle_tick_fns
    export RALPH_TASK_SOURCE=linear
    export MOCK_OPEN_COUNT=5
    export MOCK_OPEN_COUNT_EXIT=0
    run _thin_idle_tick_eligible
    assert_failure
}

# =============================================================================
# 3. Ineligibility: linear_get_open_count abstains (stale counts) → declines
# =============================================================================
@test "TAP-2496: linear_get_open_count abstains (exit 1) → thin tick declines" {
    _load_thin_idle_tick_fns
    export RALPH_TASK_SOURCE=linear
    export MOCK_OPEN_COUNT_EXIT=1
    run _thin_idle_tick_eligible
    assert_failure
}

# =============================================================================
# 4. Ineligibility: low coordinator confidence → declines
# =============================================================================
@test "TAP-2496: coordinator_confidence < threshold → thin tick declines" {
    _load_thin_idle_tick_fns
    # Rewrite brief with low confidence
    jq '.coordinator_confidence = 0.5' "$RALPH_DIR/brief.json" > "$RALPH_DIR/brief.tmp" && mv "$RALPH_DIR/brief.tmp" "$RALPH_DIR/brief.json"
    export RALPH_TASK_SOURCE=linear
    export MOCK_OPEN_COUNT=0
    export MOCK_OPEN_COUNT_EXIT=0
    run _thin_idle_tick_eligible
    assert_failure
}

# =============================================================================
# 5. Ineligibility: file mode (RALPH_TASK_SOURCE=file) → declines
# =============================================================================
@test "TAP-2496: file mode → thin tick declines (linear only)" {
    _load_thin_idle_tick_fns
    export RALPH_TASK_SOURCE=file
    export MOCK_OPEN_COUNT=0
    run _thin_idle_tick_eligible
    assert_failure
}

# =============================================================================
# 6. Operator opt-out: RALPH_THIN_IDLE_TICK=false → declines
# =============================================================================
@test "TAP-2496: RALPH_THIN_IDLE_TICK=false → thin tick disabled" {
    _load_thin_idle_tick_fns
    export RALPH_TASK_SOURCE=linear
    export MOCK_OPEN_COUNT=0
    export RALPH_THIN_IDLE_TICK=false
    run _thin_idle_tick_eligible
    assert_failure
}

# =============================================================================
# 7. Synthetic emission: _emit_synthetic_idle_status writes status.json correctly
# =============================================================================
@test "TAP-2496: synthetic emission writes EXIT_SIGNAL=true + WORK_TYPE=IDLE_TICK to status.json" {
    _load_thin_idle_tick_fns
    _emit_synthetic_idle_status 42 >/dev/null 2>&1
    [[ -f "$STATUS_FILE" ]] || { echo "status.json not written"; return 1; }
    local _es _wt
    _es=$(jq -r '.exit_signal' "$STATUS_FILE")
    _wt=$(jq -r '.work_type' "$STATUS_FILE")
    [[ "$_es" == "true" ]] || { echo "expected exit_signal=true, got $_es"; return 1; }
    [[ "$_wt" == "IDLE_TICK" ]] || { echo "expected work_type=IDLE_TICK, got $_wt"; return 1; }
}

# =============================================================================
# 8. Threshold override: RALPH_THIN_TICK_CONFIDENCE_FLOOR=0.5 accepts 0.6
# =============================================================================
@test "TAP-2496: RALPH_THIN_TICK_CONFIDENCE_FLOOR=0.5 accepts confidence=0.6" {
    _load_thin_idle_tick_fns
    jq '.coordinator_confidence = 0.6' "$RALPH_DIR/brief.json" > "$RALPH_DIR/brief.tmp" && mv "$RALPH_DIR/brief.tmp" "$RALPH_DIR/brief.json"
    export RALPH_TASK_SOURCE=linear
    export MOCK_OPEN_COUNT=0
    export RALPH_THIN_TICK_CONFIDENCE_FLOOR=0.5
    run _thin_idle_tick_eligible
    assert_success
}
