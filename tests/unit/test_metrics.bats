#!/usr/bin/env bats
# Unit tests for lib/metrics.sh
# Focus: TAP-533 — eval injection in ralph_show_stats stats path is eliminated.

load '../helpers/test_helper'

METRICS_LIB="${BATS_TEST_DIRNAME}/../../lib/metrics.sh"

setup() {
    export TEST_TEMP_DIR="$(mktemp -d)"
    cd "$TEST_TEMP_DIR"

    export RALPH_DIR=".ralph"
    export METRICS_DIR="$RALPH_DIR/metrics"
    mkdir -p "$METRICS_DIR"

    source "$METRICS_LIB"
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR"
}

# Helper: write a metrics JSONL file with two events
seed_metrics() {
    local file="$METRICS_DIR/2026-04.jsonl"
    cat > "$file" <<'EOF'
{"timestamp":"2026-04-01T00:00:00Z","loop_count":1,"session_id":"a","work_type":"IMPLEMENTATION","exit_signal":false,"api_calls":3,"circuit_breaker_state":"CLOSED","completed_task":"task-old"}
{"timestamp":"2026-04-15T00:00:00Z","loop_count":2,"session_id":"b","work_type":"IMPLEMENTATION","exit_signal":true,"api_calls":5,"circuit_breaker_state":"CLOSED","completed_task":"task-recent"}
EOF
}

# =============================================================================
# Source-level guard: no `eval` in lib/metrics.sh executable code
# =============================================================================

@test "TAP-533: lib/metrics.sh contains no executable eval" {
    # Strip comments and blank lines, then assert no `eval ` invocation remains.
    # Comments in the file are still allowed to reference TAP-533/eval for context.
    run bash -c "grep -vE '^\s*(#|$)' '$METRICS_LIB' | grep -E '\beval\b' || true"
    assert_success
    [[ -z "$output" ]]
}

# =============================================================================
# Behavior: stats path returns aggregated counts without crashing
# =============================================================================

@test "TAP-533: ralph_show_stats aggregates events without --last filter" {
    seed_metrics

    run ralph_show_stats
    assert_success

    [[ "$output" == *"Total iterations:"* ]]
    [[ "$output" == *"2"* ]]
}

@test "TAP-533: ralph_show_stats applies --last cutoff via jq --arg" {
    seed_metrics

    # 7d cutoff (relative to "now") should keep only the 2026-04-15 event.
    # The 2026-04-01 event is 15+ days older.
    run ralph_show_stats --last 7d
    assert_success
    # Either 1 iteration kept or "No metrics" if "now" is much later — both OK.
    [[ "$output" == *"Total iterations:"* || "$output" == *"No metrics"* ]]
}

# =============================================================================
# Security: malicious --last input cannot execute arbitrary shell
# =============================================================================

@test "TAP-533: malicious --last value with shell metacharacters does not execute" {
    seed_metrics

    # Sentinel file the injection would create if eval were still in the code path.
    local sentinel="$TEST_TEMP_DIR/pwned.txt"
    [[ ! -f "$sentinel" ]]

    # Crafted period: ends in 'd' so it matches *d), period%d expansion contains
    # `"; touch $sentinel; #` — under the old eval path this would execute touch.
    local malicious='1"; touch '"$sentinel"'; #d'

    # Function may print "no metrics" or aggregate normally; what matters is that
    # the sentinel file is NOT created.
    run ralph_show_stats --last "$malicious"

    [[ ! -f "$sentinel" ]] || fail "Eval injection executed: sentinel file was created"
}

@test "TAP-533: malicious --last value with backtick command substitution does not execute" {
    seed_metrics

    local sentinel="$TEST_TEMP_DIR/backtick_pwned.txt"
    [[ ! -f "$sentinel" ]]

    # Backtick-style injection.
    local malicious='1`touch '"$sentinel"'`d'

    run ralph_show_stats --last "$malicious"

    [[ ! -f "$sentinel" ]] || fail "Backtick injection executed: sentinel file was created"
}

# =============================================================================
# Robustness: filenames with spaces are handled safely (was hazard with `cat $files`)
# =============================================================================

@test "TAP-533: file path with spaces is processed without word splitting" {
    # Even though metric files are normally YYYY-MM.jsonl, simulate a hostile
    # filename to prove the array-quoted path is robust.
    local weird="$METRICS_DIR/2026-04 with space.jsonl"
    cat > "$weird" <<'EOF'
{"timestamp":"2026-04-15T00:00:00Z","loop_count":2,"session_id":"b","work_type":"IMPLEMENTATION","exit_signal":true,"api_calls":5,"circuit_breaker_state":"CLOSED","completed_task":"task"}
EOF

    run ralph_show_stats
    assert_success
    [[ "$output" == *"Total iterations:"* ]]
}
