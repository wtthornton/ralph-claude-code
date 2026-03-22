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
