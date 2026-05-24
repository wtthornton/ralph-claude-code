#!/usr/bin/env bats
# TAP-2495: EXIT_SIGNAL quorum wins over CB_AUTO_RESET.
#
# Root cause: lib/circuit_breaker.sh:init_circuit_breaker forced CB OPEN → CLOSED
# unconditionally when CB_AUTO_RESET=true, ignoring any legitimate exit-signal
# accumulation from the previous run. AgentForge 2026-05-23 burned $22 on 111
# loops in this cycle: agent emitted EXIT_SIGNAL: true → CB tripped no-progress
# → ralph-runner relaunched → auto-reset re-CLOSED → repeat.
#
# Fix: read .ralph/.exit_signals at startup. If completion_indicators length
# ≥ EXIT_SIGNAL_HALT_THRESHOLD (default 3), write .harness_halt_reason and
# leave CB OPEN. ralph_loop.sh main loop then surfaces this as graceful exit.

bats_require_minimum_version 1.5.0
load '../helpers/test_helper'

REPO_ROOT="${BATS_TEST_DIRNAME}/../.."

setup() {
    export TEST_TEMP_DIR="$(mktemp -d)"
    cd "$TEST_TEMP_DIR"
    export RALPH_DIR="$TEST_TEMP_DIR/.ralph"
    mkdir -p "$RALPH_DIR"
    # Source the CB module under test
    source "$REPO_ROOT/lib/date_utils.sh"
    source "$REPO_ROOT/lib/circuit_breaker.sh"
    # Init writes CB_STATE_FILE; override the global to our temp scope
    CB_STATE_FILE="$RALPH_DIR/.circuit_breaker_state"
    CB_HISTORY_FILE="$RALPH_DIR/.circuit_breaker_history"
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR"
}

# Helper: write a CB state file in OPEN, with a populated exit_signals
_seed_open_state_with_signals() {
    local completion_count=$1
    local indicators_json=""
    for ((i=1; i<=completion_count; i++)); do
        if [[ -n "$indicators_json" ]]; then
            indicators_json="$indicators_json,$i"
        else
            indicators_json="$i"
        fi
    done
    cat > "$CB_STATE_FILE" <<EOF
{
  "state": "OPEN",
  "last_change": "2026-05-23T20:00:00Z",
  "consecutive_no_progress": 3,
  "consecutive_permission_denials": 0,
  "total_opens": 1,
  "reason": "no progress",
  "opened_at": "2026-05-23T20:00:00Z"
}
EOF
    cat > "$RALPH_DIR/.exit_signals" <<EOF
{"test_only_loops": [], "done_signals": [], "completion_indicators": [$indicators_json]}
EOF
}

# =============================================================================
# 1. Quorum threshold met → CB stays OPEN, halt sentinel written
# =============================================================================
@test "TAP-2495: 3 completion_indicators + CB_AUTO_RESET=true → quorum wins" {
    _seed_open_state_with_signals 3
    export CB_AUTO_RESET=true
    init_circuit_breaker
    # CB must remain OPEN (auto-reset refused)
    local state
    state=$(jq -r '.state' "$CB_STATE_FILE")
    [[ "$state" == "OPEN" ]] || { echo "expected OPEN, got $state"; return 1; }
    # Halt sentinel must contain exit_signal_quorum
    [[ -f "$RALPH_DIR/.harness_halt_reason" ]] || { echo "halt sentinel missing"; return 1; }
    local reason
    reason=$(cat "$RALPH_DIR/.harness_halt_reason")
    [[ "$reason" == "exit_signal_quorum" ]] || { echo "expected exit_signal_quorum, got $reason"; return 1; }
}

# =============================================================================
# 2. Quorum threshold met → 5 indicators also fires (≥ threshold)
# =============================================================================
@test "TAP-2495: 5 completion_indicators → quorum fires (>= threshold)" {
    _seed_open_state_with_signals 5
    export CB_AUTO_RESET=true
    init_circuit_breaker
    local state
    state=$(jq -r '.state' "$CB_STATE_FILE")
    [[ "$state" == "OPEN" ]]
    [[ -f "$RALPH_DIR/.harness_halt_reason" ]]
}

# =============================================================================
# 3. Below threshold → auto-reset DOES run (existing behavior preserved)
# =============================================================================
@test "TAP-2495: 2 completion_indicators (below 3) → auto-reset runs" {
    _seed_open_state_with_signals 2
    export CB_AUTO_RESET=true
    init_circuit_breaker
    local state
    state=$(jq -r '.state' "$CB_STATE_FILE")
    [[ "$state" == "CLOSED" ]] || { echo "expected CLOSED, got $state"; return 1; }
    # No halt sentinel
    [[ ! -f "$RALPH_DIR/.harness_halt_reason" ]] || { echo "halt sentinel should be absent"; return 1; }
}

# =============================================================================
# 4. Configurable threshold — EXIT_SIGNAL_HALT_THRESHOLD=5 → 3 indicators below threshold
# =============================================================================
@test "TAP-2495: EXIT_SIGNAL_HALT_THRESHOLD=5 → 3 indicators below threshold, auto-reset runs" {
    _seed_open_state_with_signals 3
    export CB_AUTO_RESET=true
    export EXIT_SIGNAL_HALT_THRESHOLD=5
    init_circuit_breaker
    local state
    state=$(jq -r '.state' "$CB_STATE_FILE")
    [[ "$state" == "CLOSED" ]]
    [[ ! -f "$RALPH_DIR/.harness_halt_reason" ]]
}

# =============================================================================
# 5. No .exit_signals file → original CB_AUTO_RESET behavior preserved
# =============================================================================
@test "TAP-2495: no .exit_signals file → auto-reset runs (backward compat)" {
    cat > "$CB_STATE_FILE" <<EOF
{
  "state": "OPEN",
  "last_change": "2026-05-23T20:00:00Z",
  "consecutive_no_progress": 3,
  "consecutive_permission_denials": 0,
  "total_opens": 1,
  "reason": "no progress",
  "opened_at": "2026-05-23T20:00:00Z"
}
EOF
    [[ ! -f "$RALPH_DIR/.exit_signals" ]]
    export CB_AUTO_RESET=true
    init_circuit_breaker
    local state
    state=$(jq -r '.state' "$CB_STATE_FILE")
    [[ "$state" == "CLOSED" ]]
}

# =============================================================================
# 6. Empty .exit_signals.completion_indicators → auto-reset runs (no quorum)
# =============================================================================
@test "TAP-2495: empty completion_indicators array → auto-reset runs" {
    _seed_open_state_with_signals 0
    export CB_AUTO_RESET=true
    init_circuit_breaker
    local state
    state=$(jq -r '.state' "$CB_STATE_FILE")
    [[ "$state" == "CLOSED" ]]
}

# =============================================================================
# 7. Quorum met but CB_AUTO_RESET=false → quorum still wins (no double-cooldown)
# =============================================================================
@test "TAP-2495: quorum met + CB_AUTO_RESET=false → quorum wins, no cooldown branch" {
    _seed_open_state_with_signals 3
    export CB_AUTO_RESET=false
    init_circuit_breaker
    local state
    state=$(jq -r '.state' "$CB_STATE_FILE")
    [[ "$state" == "OPEN" ]]
    [[ -f "$RALPH_DIR/.harness_halt_reason" ]]
}
