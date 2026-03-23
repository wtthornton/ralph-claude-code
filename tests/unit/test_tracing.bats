#!/usr/bin/env bats

# Tests for lib/tracing.sh — OTel trace generation (OTEL-1)

setup() {
    export RALPH_DIR="$BATS_TEST_TMPDIR/.ralph"
    export RALPH_OTEL_ENABLED="true"
    export RALPH_TRACE_DIR="$RALPH_DIR/traces"
    export RALPH_VERSION="2.0.0"
    export LOOP_COUNT=1
    mkdir -p "$RALPH_DIR"
    source "$BATS_TEST_DIRNAME/../../lib/tracing.sh"
}

teardown() {
    rm -rf "$BATS_TEST_TMPDIR/.ralph"
}

@test "ralph_trace_generate_id produces 32 hex chars" {
    local id
    id=$(ralph_trace_generate_id)
    [[ ${#id} -eq 32 ]]
    [[ "$id" =~ ^[0-9a-f]+$ ]]
}

@test "ralph_trace_generate_id produces unique IDs" {
    local id1 id2
    id1=$(ralph_trace_generate_id)
    id2=$(ralph_trace_generate_id)
    [[ "$id1" != "$id2" ]]
}

@test "ralph_trace_generate_span_id produces 16 hex chars" {
    local span_id
    span_id=$(ralph_trace_generate_span_id)
    [[ ${#span_id} -eq 16 ]]
}

@test "ralph_trace_start sets RALPH_TRACE_ID" {
    ralph_trace_start
    [[ -n "$RALPH_TRACE_ID" ]]
    [[ ${#RALPH_TRACE_ID} -eq 32 ]]
}

@test "ralph_trace_start creates trace directory" {
    ralph_trace_start
    [[ -d "$RALPH_TRACE_DIR" ]]
}

@test "ralph_trace_record writes JSONL to monthly file" {
    ralph_trace_start
    ralph_trace_record "test_span" "1000" "2000" "sonnet" "100" "50" "stop"
    local month_file="$RALPH_TRACE_DIR/$(date '+%Y-%m').jsonl"
    [[ -f "$month_file" ]]
    local line_count
    line_count=$(wc -l < "$month_file")
    [[ "$line_count" -eq 1 ]]
}

@test "ralph_trace_record includes GenAI attributes" {
    ralph_trace_start
    ralph_trace_record "test_span" "1000" "2000" "claude-sonnet" "500" "200" "end_turn"
    local month_file="$RALPH_TRACE_DIR/$(date '+%Y-%m').jsonl"
    grep -q 'gen_ai.system' "$month_file"
    grep -q 'gen_ai.request.model' "$month_file"
    grep -q 'claude-sonnet' "$month_file"
    grep -q 'gen_ai.usage.input_tokens' "$month_file"
    grep -q 'gen_ai.usage.output_tokens' "$month_file"
}

@test "ralph_trace_record sanitizes API keys" {
    ralph_trace_start
    # Inject a fake API key in the span name to test sanitization
    ralph_trace_record "task with sk-ant-api03-fake-key-here" "1000" "2000" "sonnet" "0" "0" "stop"
    local month_file="$RALPH_TRACE_DIR/$(date '+%Y-%m').jsonl"
    ! grep -q 'sk-ant-api03' "$month_file"
    grep -q 'REDACTED' "$month_file"
}

@test "tracing disabled when RALPH_OTEL_ENABLED=false" {
    export RALPH_OTEL_ENABLED="false"
    ralph_trace_start
    [[ -z "$RALPH_TRACE_ID" ]]
    ralph_trace_record "test" "0" "0" "sonnet" "0" "0" "stop"
    [[ ! -d "$RALPH_TRACE_DIR" ]] || [[ -z "$(ls -A "$RALPH_TRACE_DIR" 2>/dev/null)" ]]
}

@test "ralph_trace_timestamp_ns returns numeric value" {
    local ts
    ts=$(ralph_trace_timestamp_ns)
    [[ "$ts" =~ ^[0-9]+$ ]]
    [[ ${#ts} -ge 10 ]]
}

# =============================================================================
# OTEL-3: Cost Attribution and Budget Alerts
# =============================================================================

@test "OTEL-3: cost calculation for sonnet" {
    # 1M input tokens at $3/1M + 1M output at $15/1M = $18.00
    result=$(ralph_trace_calculate_cost "sonnet" 1000000 1000000)
    [[ "$result" == "18.000000" ]]
}

@test "OTEL-3: cost calculation for haiku" {
    # 1M input at $0.25/1M + 1M output at $1.25/1M = $1.50
    result=$(ralph_trace_calculate_cost "haiku" 1000000 1000000)
    [[ "$result" == "1.500000" ]]
}

@test "OTEL-3: cost calculation for opus" {
    # 1M input at $15/1M + 1M output at $75/1M = $90.00
    result=$(ralph_trace_calculate_cost "opus" 1000000 1000000)
    [[ "$result" == "90.000000" ]]
}

@test "OTEL-3: cost calculation with zero tokens" {
    result=$(ralph_trace_calculate_cost "sonnet" 0 0)
    [[ "$result" == "0.000000" ]]
}

@test "OTEL-3: cost record written to costs.jsonl" {
    TRACE_DIR="$BATS_TEST_TMPDIR/.ralph/traces"
    RALPH_DIR="$BATS_TEST_TMPDIR/.ralph"
    mkdir -p "$TRACE_DIR"
    ralph_trace_record_cost "sonnet" 5000 2000
    [[ -f "$TRACE_DIR/costs.jsonl" ]]
    # Validate it's valid JSON
    local line
    line=$(head -1 "$TRACE_DIR/costs.jsonl")
    echo "$line" | jq . >/dev/null 2>&1
}

@test "OTEL-3: cost record contains expected fields" {
    TRACE_DIR="$BATS_TEST_TMPDIR/.ralph/traces"
    RALPH_DIR="$BATS_TEST_TMPDIR/.ralph"
    mkdir -p "$TRACE_DIR"
    ralph_trace_record_cost "sonnet" 5000 2000
    local line
    line=$(head -1 "$TRACE_DIR/costs.jsonl")
    echo "$line" | jq -e '.model' >/dev/null
    echo "$line" | jq -e '.input_tokens' >/dev/null
    echo "$line" | jq -e '.output_tokens' >/dev/null
    echo "$line" | jq -e '.cost_usd' >/dev/null
    echo "$line" | jq -e '.timestamp' >/dev/null
}

@test "OTEL-3: budget alert triggered at threshold" {
    TRACE_DIR="$BATS_TEST_TMPDIR/.ralph/traces"
    RALPH_DIR="$BATS_TEST_TMPDIR/.ralph"
    export RALPH_COST_BUDGET_USD="0.01"
    export RALPH_COST_ALERT_THRESHOLD="50"
    mkdir -p "$TRACE_DIR"
    # Record cost that exceeds 50% of $0.01 budget
    ralph_trace_record_cost "sonnet" 100000 100000
    [[ -f "$RALPH_DIR/.cost_alert" ]]
}

@test "OTEL-3: no budget alert when budget is 0 (disabled)" {
    TRACE_DIR="$BATS_TEST_TMPDIR/.ralph/traces"
    RALPH_DIR="$BATS_TEST_TMPDIR/.ralph"
    export RALPH_COST_BUDGET_USD="0"
    mkdir -p "$TRACE_DIR"
    ralph_trace_record_cost "sonnet" 1000000 1000000
    [[ ! -f "$RALPH_DIR/.cost_alert" ]]
}

@test "OTEL-3: cost record skipped when OTEL disabled" {
    export RALPH_OTEL_ENABLED="false"
    TRACE_DIR="$BATS_TEST_TMPDIR/.ralph/traces"
    mkdir -p "$TRACE_DIR"
    ralph_trace_record_cost "sonnet" 5000 2000
    [[ ! -f "$TRACE_DIR/costs.jsonl" ]]
}

# =============================================================================
# OTEL-4: OTLP Exporter
# =============================================================================

@test "OTEL-4: export skipped when disabled" {
    export RALPH_OTLP_EXPORT_ENABLED="false"
    ralph_otlp_export  # Should return 0 silently
}

@test "OTEL-4: export skipped without endpoint" {
    export RALPH_OTLP_EXPORT_ENABLED="true"
    export RALPH_OTLP_ENDPOINT=""
    ralph_otlp_export  # Should return 0 silently
}

@test "OTEL-4: batch export skipped when disabled" {
    export RALPH_OTLP_EXPORT_ENABLED="false"
    ralph_otlp_export_batch  # Should return 0 silently
}

@test "OTEL-4: batch export skipped without endpoint" {
    export RALPH_OTLP_EXPORT_ENABLED="true"
    export RALPH_OTLP_ENDPOINT=""
    ralph_otlp_export_batch  # Should return 0 silently
}

@test "OTEL-4: export handles missing trace file gracefully" {
    export RALPH_OTLP_EXPORT_ENABLED="true"
    export RALPH_OTLP_ENDPOINT="http://localhost:4318/v1/traces"
    TRACE_DIR="$BATS_TEST_TMPDIR/.ralph/traces"
    mkdir -p "$TRACE_DIR"
    # No trace file exists — should return 0
    ralph_otlp_export
}
