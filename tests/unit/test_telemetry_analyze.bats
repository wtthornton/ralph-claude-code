#!/usr/bin/env bats
# Behavior contract for lib/telemetry_analyze.sh — the `ralph --analyze`
# closed-loop telemetry analyzer (Story TELEMETRY-HARVESTER).
#
# Read-only, advisory, always exit 0. Five rules over the harness's
# control-path telemetry; each degrades to [SKIP] on a missing/empty file.
# The two timeout rules reuse the PR #54/#58 censored (exit_code 124 → ×1.5) +
# ceiling-p95 method, so the analyzer's percentile agrees with the enforced
# budget.

bats_require_minimum_version 1.5.0

LIB="${BATS_TEST_DIRNAME}/../../lib/telemetry_analyze.sh"

setup() {
    export TEST_TEMP_DIR="$(mktemp -d)"
    export RALPH_DIR="$TEST_TEMP_DIR/.ralph"
    mkdir -p "$RALPH_DIR"
    # Neutralize operator env that would otherwise leak into rule thresholds.
    unset RALPH_CACHE_HIT_RATE_WARN RALPH_ANALYZE_ROUTING_WINDOW
    source "$LIB"
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR"
}

# Stubs for the enforced-budget delegates (absent outside the harness).
_stub_budgets() {
    ralph_compute_coordinator_timeout() { echo "${1:-300}"; }
    ralph_compute_adaptive_timeout() { echo "${1:-8}"; }  # minutes
}

# --- setup / empty-state ----------------------------------------------------

@test "no .ralph directory yields a single SKIP setup finding, exit 0" {
    export RALPH_DIR="$TEST_TEMP_DIR/nonexistent"
    run ralph_telemetry_analyze
    [ "$status" -eq 0 ]
    [[ "$output" == *"[SKIP] setup"* ]]
}

@test "all-empty .ralph: every rule degrades to SKIP/OK, never errors, exit 0" {
    run ralph_telemetry_analyze
    [ "$status" -eq 0 ]
    [[ "$output" == *"[SKIP] coordinator_timeout"* ]]
    [[ "$output" == *"[SKIP] mainloop_timeout"* ]]
    [[ "$output" == *"[SKIP] cache_hit_rate"* ]]
    [[ "$output" == *"[SKIP] opus_escalation"* ]]
    [[ "$output" == *"[SKIP] coordinator_phase"* ]]
}

# --- Rule 1: coordinator timeout health -------------------------------------

@test "coordinator_timeout WARN when censored-p95 >= 90% of budget" {
    _stub_budgets
    ralph_compute_coordinator_timeout() { echo 300; }
    # sorted [120,140,160,450]; ceil-idx 4 -> 450 >= 270
    printf '{"duration_seconds":120,"exit_code":0}\n{"duration_seconds":140,"exit_code":0}\n{"duration_seconds":300,"exit_code":124}\n{"duration_seconds":160,"exit_code":0}\n' > "$RALPH_DIR/.coordinator_timings.jsonl"
    run ralph_telemetry_analyze
    [ "$status" -eq 0 ]
    [[ "$output" == *"[WARN] coordinator_timeout"* ]]
    [[ "$output" == *"450s"* ]]
}

@test "coordinator_timeout OK with healthy headroom" {
    _stub_budgets
    ralph_compute_coordinator_timeout() { echo 600; }
    printf '{"duration_seconds":120,"exit_code":0}\n{"duration_seconds":130,"exit_code":0}\n{"duration_seconds":140,"exit_code":0}\n' > "$RALPH_DIR/.coordinator_timings.jsonl"
    run ralph_telemetry_analyze
    [[ "$output" == *"[OK] coordinator_timeout"* ]]
    [[ "$output" == *"headroom"* ]]
}

@test "coordinator_timeout INFO (no ratio) when budget delegate is absent" {
    # No stubs defined -> _ta_budget_coordinator_seconds returns empty.
    printf '{"duration_seconds":120,"exit_code":0}\n{"duration_seconds":130,"exit_code":0}\n{"duration_seconds":140,"exit_code":0}\n' > "$RALPH_DIR/.coordinator_timings.jsonl"
    run ralph_telemetry_analyze
    [[ "$output" == *"[INFO] coordinator_timeout"* ]]
    [[ "$output" == *"budget unavailable"* ]]
}

# --- Rule 2: main-loop timeout health ---------------------------------------

@test "mainloop_timeout WARN when censored-p95 >= 90% of budget (minutes->seconds)" {
    _stub_budgets
    ralph_compute_adaptive_timeout() { echo 8; }  # 480s
    # sorted [300,420,900]; ceil-idx 3 -> 900 >= 432
    printf '{"duration_seconds":300,"exit_code":0}\n{"duration_seconds":420,"exit_code":0}\n{"duration_seconds":600,"exit_code":124}\n' > "$RALPH_DIR/.invocation_latencies"
    run ralph_telemetry_analyze
    [[ "$output" == *"[WARN] mainloop_timeout"* ]]
    [[ "$output" == *"900s"* ]]
}

@test "mainloop_timeout OK with healthy headroom" {
    _stub_budgets
    ralph_compute_adaptive_timeout() { echo 30; }  # 1800s
    printf '{"duration_seconds":300,"exit_code":0}\n{"duration_seconds":350,"exit_code":0}\n{"duration_seconds":400,"exit_code":0}\n' > "$RALPH_DIR/.invocation_latencies"
    run ralph_telemetry_analyze
    [[ "$output" == *"[OK] mainloop_timeout"* ]]
}

# --- Rule 3: prompt-cache hit-rate ------------------------------------------

@test "cache_hit_rate WARN below threshold" {
    printf '{"session_cache_read_tokens":1000,"session_cache_create_tokens":4000,"session_input_tokens":5000}\n' > "$RALPH_DIR/status.json"
    run ralph_telemetry_analyze
    [[ "$output" == *"[WARN] cache_hit_rate"* ]]
    [[ "$output" == *"10%"* ]]
}

@test "cache_hit_rate OK at/above threshold" {
    printf '{"session_cache_read_tokens":9000,"session_cache_create_tokens":500,"session_input_tokens":500}\n' > "$RALPH_DIR/status.json"
    run ralph_telemetry_analyze
    [[ "$output" == *"[OK] cache_hit_rate"* ]]
    [[ "$output" == *"90%"* ]]
}

@test "cache_hit_rate honors RALPH_CACHE_HIT_RATE_WARN override" {
    export RALPH_CACHE_HIT_RATE_WARN=5
    printf '{"session_cache_read_tokens":1000,"session_cache_create_tokens":4000,"session_input_tokens":5000}\n' > "$RALPH_DIR/status.json"
    run ralph_telemetry_analyze
    # 10% is now >= 5% -> OK
    [[ "$output" == *"[OK] cache_hit_rate"* ]]
}

@test "cache_hit_rate SKIP when all token fields are zero" {
    printf '{"session_cache_read_tokens":0,"session_cache_create_tokens":0,"session_input_tokens":0}\n' > "$RALPH_DIR/status.json"
    run ralph_telemetry_analyze
    [[ "$output" == *"[SKIP] cache_hit_rate"* ]]
}

# --- Rule 4: Opus QA-failure escalation cluster -----------------------------

@test "opus_escalation OK when no escalations in window" {
    printf '{"reason":"type_code"}\n{"reason":"type_haiku"}\n' > "$RALPH_DIR/.model_routing.jsonl"
    run ralph_telemetry_analyze
    [[ "$output" == *"[OK] opus_escalation"* ]]
}

@test "opus_escalation INFO names stuck issues (failure count >= 3)" {
    printf '{"reason":"type_code"}\n{"reason":"qa_failure_escalation"}\n{"reason":"qa_failure_escalation"}\n' > "$RALPH_DIR/.model_routing.jsonl"
    printf '{"TAP-123":3,"TAP-9":1}\n' > "$RALPH_DIR/.qa_failures.json"
    run ralph_telemetry_analyze
    [[ "$output" == *"[INFO] opus_escalation"* ]]
    [[ "$output" == *"2×"* ]]
    [[ "$output" == *"TAP-123"* ]]
    [[ "$output" != *"TAP-9"* ]]
}

# --- Rule 5: coordinator phase attribution ----------------------------------

@test "coordinator_phase INFO reports synthesis share and recall count" {
    printf '{"dominant_phase":"synthesis","brain_recall_invoked":true}\n{"dominant_phase":"synthesis","brain_recall_invoked":false}\n{"dominant_phase":"startup","brain_recall_invoked":false}\n' > "$RALPH_DIR/.coordinator_phase_timings.jsonl"
    run ralph_telemetry_analyze
    [[ "$output" == *"[INFO] coordinator_phase"* ]]
    [[ "$output" == *"2/3 synthesis-dominated"* ]]
    [[ "$output" == *"brain_recall invoked in 1/3"* ]]
}

@test "coordinator_phase hints the Haiku trial when synthesis dominates" {
    printf '{"dominant_phase":"synthesis","brain_recall_invoked":false}\n{"dominant_phase":"synthesis","brain_recall_invoked":false}\n' > "$RALPH_DIR/.coordinator_phase_timings.jsonl"
    run ralph_telemetry_analyze
    [[ "$output" == *"OPERATOR-NOTES #2"* ]]
}

# --- JSON output ------------------------------------------------------------

@test "--json emits valid JSON with the stable finding key schema" {
    _stub_budgets
    printf '{"session_cache_read_tokens":1000,"session_cache_create_tokens":4000,"session_input_tokens":5000}\n' > "$RALPH_DIR/status.json"
    run ralph_telemetry_analyze --json
    [ "$status" -eq 0 ]
    echo "$output" | jq -e '.generated_at and (.findings | type == "array")'
    # Every finding carries the six stable keys.
    echo "$output" | jq -e '.findings | all(has("rule") and has("severity") and has("value") and has("threshold") and has("detail") and has("hint"))'
}

@test "--json and human agree on findings count and rules" {
    _stub_budgets
    printf '{"duration_seconds":120,"exit_code":0}\n{"duration_seconds":130,"exit_code":0}\n{"duration_seconds":140,"exit_code":0}\n' > "$RALPH_DIR/.coordinator_timings.jsonl"
    run ralph_telemetry_analyze --json
    [ "$status" -eq 0 ]
    # Always five rules, one per analyzer rule.
    local n
    n=$(echo "$output" | jq '.findings | length')
    [ "$n" -eq 5 ]
    echo "$output" | jq -e '[.findings[].rule] == ["coordinator_timeout","mainloop_timeout","cache_hit_rate","opus_escalation","coordinator_phase"]'
}
