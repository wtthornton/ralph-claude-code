#!/usr/bin/env bats

# Tests for COSTROUTE-4 (cost dashboard).
# COSTROUTE-3 (prompt cache optimization) was reverted — the function shipped
# without a runtime caller in linear mode. See PR removing it for rationale.

setup() {
    export RALPH_DIR="$BATS_TEST_TMPDIR/.ralph"
    export RALPH_VERBOSE="false"
    mkdir -p "$RALPH_DIR"
}

teardown() {
    rm -rf "$BATS_TEST_TMPDIR/.ralph"
}

# =============================================================================
# COSTROUTE-4: Cost Dashboard
# =============================================================================

@test "COSTROUTE-4: cost dashboard outputs valid JSON" {
    source "$BATS_TEST_DIRNAME/../../lib/tracing.sh" 2>/dev/null || true
    source "$BATS_TEST_DIRNAME/../../lib/metrics.sh"
    export TRACE_DIR="$RALPH_DIR/traces"
    mkdir -p "$RALPH_DIR/traces" "$RALPH_DIR/metrics"

    # Create sample cost data
    echo '{"timestamp":"2026-03-23","model":"sonnet","input_tokens":5000,"output_tokens":2000,"cost_usd":0.045,"trace_id":"abc","loop_count":1}' > "$RALPH_DIR/traces/costs.jsonl"

    result=$(ralph_show_cost_dashboard --json)
    echo "$result" | jq . >/dev/null 2>&1
    [[ "$(echo "$result" | jq -r '.total_iterations')" -ge 0 ]]
}

@test "COSTROUTE-4: cost dashboard JSON includes all required fields" {
    source "$BATS_TEST_DIRNAME/../../lib/tracing.sh" 2>/dev/null || true
    source "$BATS_TEST_DIRNAME/../../lib/metrics.sh"
    mkdir -p "$RALPH_DIR/traces" "$RALPH_DIR/metrics"

    echo '{"timestamp":"2026-03-23","model":"sonnet","input_tokens":5000,"output_tokens":2000,"cost_usd":0.045,"trace_id":"abc","loop_count":1}' > "$RALPH_DIR/traces/costs.jsonl"

    result=$(ralph_show_cost_dashboard --json)
    [[ "$(echo "$result" | jq 'has("total_cost_usd")')" == "true" ]]
    [[ "$(echo "$result" | jq 'has("total_input_tokens")')" == "true" ]]
    [[ "$(echo "$result" | jq 'has("total_output_tokens")')" == "true" ]]
    [[ "$(echo "$result" | jq 'has("total_iterations")')" == "true" ]]
    [[ "$(echo "$result" | jq 'has("cost_per_iteration")')" == "true" ]]
    [[ "$(echo "$result" | jq 'has("budget_usd")')" == "true" ]]
    [[ "$(echo "$result" | jq 'has("budget_used_pct")')" == "true" ]]
    [[ "$(echo "$result" | jq 'has("by_model")')" == "true" ]]
}

@test "COSTROUTE-4: cost dashboard computes correct totals" {
    source "$BATS_TEST_DIRNAME/../../lib/tracing.sh" 2>/dev/null || true
    source "$BATS_TEST_DIRNAME/../../lib/metrics.sh"
    mkdir -p "$RALPH_DIR/traces" "$RALPH_DIR/metrics"

    cat > "$RALPH_DIR/traces/costs.jsonl" <<'EOF'
{"timestamp":"2026-03-23","model":"sonnet","input_tokens":5000,"output_tokens":2000,"cost_usd":0.045,"trace_id":"abc","loop_count":1}
{"timestamp":"2026-03-23","model":"sonnet","input_tokens":3000,"output_tokens":1000,"cost_usd":0.025,"trace_id":"def","loop_count":2}
EOF

    result=$(ralph_show_cost_dashboard --json)
    total_cost=$(echo "$result" | jq -r '.total_cost_usd')
    total_input=$(echo "$result" | jq -r '.total_input_tokens')
    total_output=$(echo "$result" | jq -r '.total_output_tokens')

    # 0.045 + 0.025 = 0.07
    [[ "$total_cost" == "0.07" ]]
    [[ "$total_input" == "8000" ]]
    [[ "$total_output" == "3000" ]]
}

@test "COSTROUTE-4: cost dashboard human output contains header" {
    source "$BATS_TEST_DIRNAME/../../lib/tracing.sh" 2>/dev/null || true
    source "$BATS_TEST_DIRNAME/../../lib/metrics.sh"
    mkdir -p "$RALPH_DIR/traces" "$RALPH_DIR/metrics"

    result=$(ralph_show_cost_dashboard)
    [[ "$result" == *"Ralph Cost Dashboard"* ]]
    [[ "$result" == *"===================="* ]]
}

@test "COSTROUTE-4: cost dashboard shows budget info when set" {
    export RALPH_COST_BUDGET_USD="10"
    source "$BATS_TEST_DIRNAME/../../lib/tracing.sh" 2>/dev/null || true
    source "$BATS_TEST_DIRNAME/../../lib/metrics.sh"
    mkdir -p "$RALPH_DIR/traces" "$RALPH_DIR/metrics"

    echo '{"timestamp":"2026-03-23","model":"sonnet","input_tokens":5000,"output_tokens":2000,"cost_usd":1.00,"trace_id":"abc","loop_count":1}' > "$RALPH_DIR/traces/costs.jsonl"

    result=$(ralph_show_cost_dashboard)
    [[ "$result" == *"Budget:"* ]]
    [[ "$result" == *"10"* ]]
}

@test "COSTROUTE-4: cost dashboard JSON includes budget percentage" {
    export RALPH_COST_BUDGET_USD="10"
    source "$BATS_TEST_DIRNAME/../../lib/tracing.sh" 2>/dev/null || true
    source "$BATS_TEST_DIRNAME/../../lib/metrics.sh"
    mkdir -p "$RALPH_DIR/traces" "$RALPH_DIR/metrics"

    echo '{"timestamp":"2026-03-23","model":"sonnet","input_tokens":5000,"output_tokens":2000,"cost_usd":5.00,"trace_id":"abc","loop_count":1}' > "$RALPH_DIR/traces/costs.jsonl"

    result=$(ralph_show_cost_dashboard --json)
    pct=$(echo "$result" | jq -r '.budget_used_pct')
    [[ "$pct" == "50" ]]
}

@test "COSTROUTE-4: cost dashboard handles no data gracefully" {
    source "$BATS_TEST_DIRNAME/../../lib/tracing.sh" 2>/dev/null || true
    source "$BATS_TEST_DIRNAME/../../lib/metrics.sh"
    mkdir -p "$RALPH_DIR/traces" "$RALPH_DIR/metrics"

    result=$(ralph_show_cost_dashboard --json)
    echo "$result" | jq . >/dev/null 2>&1
    [[ "$(echo "$result" | jq -r '.total_cost_usd')" == "0" ]]
    [[ "$(echo "$result" | jq -r '.total_iterations')" == "0" ]]
}

@test "COSTROUTE-4: cost dashboard model breakdown groups by model" {
    source "$BATS_TEST_DIRNAME/../../lib/tracing.sh" 2>/dev/null || true
    source "$BATS_TEST_DIRNAME/../../lib/metrics.sh"
    mkdir -p "$RALPH_DIR/traces" "$RALPH_DIR/metrics"

    cat > "$RALPH_DIR/traces/costs.jsonl" <<'EOF'
{"timestamp":"2026-03-23","model":"sonnet","input_tokens":5000,"output_tokens":2000,"cost_usd":0.045,"trace_id":"abc","loop_count":1}
{"timestamp":"2026-03-23","model":"haiku","input_tokens":1000,"output_tokens":500,"cost_usd":0.005,"trace_id":"def","loop_count":2}
{"timestamp":"2026-03-23","model":"sonnet","input_tokens":3000,"output_tokens":1000,"cost_usd":0.025,"trace_id":"ghi","loop_count":3}
EOF

    result=$(ralph_show_cost_dashboard --json)
    model_count=$(echo "$result" | jq '.by_model | length')
    [[ "$model_count" -eq 2 ]]

    # sonnet should have 2 entries
    sonnet_iters=$(echo "$result" | jq '[.by_model[] | select(.model == "sonnet")] | .[0].iterations')
    [[ "$sonnet_iters" == "2" ]]
}
