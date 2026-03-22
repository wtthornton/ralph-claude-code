# Story OTEL-1: OTel Trace Generation with GenAI Semantic Conventions

**Epic:** [OpenTelemetry & Observability v2](epic-otel-observability.md)
**Priority:** High
**Status:** Open
**Effort:** Medium
**Component:** `ralph_loop.sh`, new `lib/tracing.sh`

---

## Problem

Ralph's metrics (Phase 8, `lib/metrics.sh`) record aggregate session-level data in local JSONL files. There is no per-invocation trace record with standardized attributes. Debugging requires correlating timestamps across multiple log files manually.

The 2026 industry standard is OpenTelemetry with GenAI Semantic Conventions — standardized attributes that any observability platform can consume.

## Solution

Create a new `lib/tracing.sh` module that generates OTel-compatible trace records in JSONL format. Each loop iteration produces a trace with spans for the Claude CLI invocation, including GenAI attributes extracted from the response.

## Implementation

### Step 1: Create `lib/tracing.sh`

```bash
# lib/tracing.sh — OTel-compatible trace generation

RALPH_OTEL_ENABLED=${RALPH_OTEL_ENABLED:-true}
RALPH_TRACE_DIR="${RALPH_DIR}/.traces"
RALPH_TRACE_FILE="${RALPH_TRACE_DIR}/traces-$(date +%Y-%m).jsonl"

# Generate a UUID v4 trace ID
ralph_generate_trace_id() {
    cat /proc/sys/kernel/random/uuid 2>/dev/null || \
        python3 -c "import uuid; print(uuid.uuid4())" 2>/dev/null || \
        od -x /dev/urandom | head -1 | awk '{OFS="-"; print $2$3,$4,$5,$6,$7$8$9}'
}

# Generate a 16-char span ID
ralph_generate_span_id() {
    head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n'
}

# Start a trace for this loop iteration
ralph_trace_start() {
    local loop_count="$1" task_id="$2"

    export RALPH_TRACE_ID=$(ralph_generate_trace_id)
    export RALPH_SPAN_ID=$(ralph_generate_span_id)
    export RALPH_TRACE_START=$(date +%s%N 2>/dev/null || echo "$(date +%s)000000000")

    mkdir -p "$RALPH_TRACE_DIR"
}

# Record a completed trace span
ralph_trace_record() {
    [[ "$RALPH_OTEL_ENABLED" != "true" ]] && return 0

    local span_name="$1"
    local status="$2"  # OK, ERROR, TIMEOUT
    local model="${3:-unknown}"
    local input_tokens="${4:-0}"
    local output_tokens="${5:-0}"
    local duration_ms="${6:-0}"

    local end_time
    end_time=$(date +%s%N 2>/dev/null || echo "$(date +%s)000000000")

    # Sanitize: strip any env vars or secrets from span data
    local sanitized_name
    sanitized_name=$(echo "$span_name" | sed 's/ANTHROPIC_API_KEY=[^ ]*/ANTHROPIC_API_KEY=****/g')

    # Write OTel-compatible JSONL record
    jq -n -c \
        --arg trace_id "$RALPH_TRACE_ID" \
        --arg span_id "$RALPH_SPAN_ID" \
        --arg name "$sanitized_name" \
        --arg status "$status" \
        --arg model "$model" \
        --argjson input_tokens "$input_tokens" \
        --argjson output_tokens "$output_tokens" \
        --argjson duration_ms "$duration_ms" \
        --arg start_time "$RALPH_TRACE_START" \
        --arg end_time "$end_time" \
        --arg ralph_version "$RALPH_VERSION" \
        '{
            resourceSpans: [{
                resource: {
                    attributes: [
                        {key: "service.name", value: {stringValue: "ralph"}},
                        {key: "service.version", value: {stringValue: $ralph_version}}
                    ]
                },
                scopeSpans: [{
                    spans: [{
                        traceId: $trace_id,
                        spanId: $span_id,
                        name: $name,
                        startTimeUnixNano: $start_time,
                        endTimeUnixNano: $end_time,
                        status: {code: (if $status == "OK" then 1 elif $status == "ERROR" then 2 else 0 end)},
                        attributes: [
                            {key: "gen_ai.system", value: {stringValue: "anthropic"}},
                            {key: "gen_ai.request.model", value: {stringValue: $model}},
                            {key: "gen_ai.usage.input_tokens", value: {intValue: $input_tokens}},
                            {key: "gen_ai.usage.output_tokens", value: {intValue: $output_tokens}},
                            {key: "gen_ai.response.finish_reason", value: {stringValue: $status}},
                            {key: "ralph.duration_ms", value: {intValue: $duration_ms}},
                            {key: "ralph.loop_iteration", value: {stringValue: $name}}
                        ]
                    }]
                }]
            }]
        }' >> "$RALPH_TRACE_FILE"
}
```

### Step 2: Integrate with main loop

```bash
# Before Claude CLI invocation:
ralph_trace_start "$LOOP_COUNT" "$CURRENT_TASK"

# After invocation completes:
local model input_tokens output_tokens
model=$(jq -r '.model // "unknown"' "$STATUS_FILE" 2>/dev/null)
input_tokens=$(jq -r '.input_tokens // 0' "$STATUS_FILE" 2>/dev/null)
output_tokens=$(jq -r '.output_tokens // 0' "$STATUS_FILE" 2>/dev/null)

ralph_trace_record \
    "loop_iteration_${LOOP_COUNT}" \
    "$([[ $EXIT_CODE -eq 0 ]] && echo "OK" || echo "ERROR")" \
    "$model" \
    "$input_tokens" \
    "$output_tokens" \
    "$duration_ms"
```

### Step 3: Add trace rotation

```bash
# Rotate trace files monthly (aligned with metrics rotation)
ralph_rotate_traces() {
    local max_files=${RALPH_TRACE_MAX_FILES:-6}  # Keep 6 months
    local count
    count=$(ls -1 "$RALPH_TRACE_DIR"/traces-*.jsonl 2>/dev/null | wc -l)
    if [[ "$count" -gt "$max_files" ]]; then
        ls -1t "$RALPH_TRACE_DIR"/traces-*.jsonl | tail -n +$((max_files + 1)) | xargs rm -f
    fi
}
```

## Design Notes

- **JSONL format matches OTLP JSON encoding**: The `resourceSpans` structure follows the OTLP JSON protocol, making OTEL-4 (exporter) a thin HTTP POST rather than a format conversion.
- **GenAI Semantic Conventions**: Using the official attribute names ensures any OTel-compatible backend can parse and display the traces correctly.
- **Sanitization**: Applied at write time, not read time, to prevent secrets from ever reaching disk in trace files.
- **UUID v4 for trace IDs**: Three fallback methods (procfs, python3, /dev/urandom) ensure cross-platform compatibility.
- **Nanosecond timestamps**: OTel spec requires nanosecond precision. Fallback to seconds × 10^9 on platforms without `date +%N`.
- **Monthly rotation**: Aligned with existing `lib/metrics.sh` rotation to keep disk usage bounded.

## Acceptance Criteria

- [ ] Every loop iteration generates a trace record with unique `trace_id`
- [ ] Trace records include GenAI Semantic Convention attributes (model, tokens, finish_reason)
- [ ] `RALPH_OTEL_ENABLED=false` disables trace generation
- [ ] Trace JSONL format matches OTLP JSON encoding
- [ ] Trace files are rotated monthly with configurable retention
- [ ] API keys and secrets are sanitized from trace data
- [ ] Cross-platform: works on Linux, macOS, and WSL

## Test Plan

```bash
@test "ralph_generate_trace_id produces valid UUID" {
    source "$RALPH_DIR/lib/tracing.sh"
    local id
    id=$(ralph_generate_trace_id)
    [[ "$id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]
}

@test "ralph_trace_record writes JSONL with GenAI attributes" {
    source "$RALPH_DIR/lib/tracing.sh"
    RALPH_TRACE_DIR="$TEST_DIR/traces"
    RALPH_TRACE_FILE="$RALPH_TRACE_DIR/traces-test.jsonl"
    RALPH_OTEL_ENABLED="true"
    RALPH_VERSION="2.1.0"

    ralph_trace_start "1" "TEST-1"
    ralph_trace_record "loop_1" "OK" "claude-sonnet-4-6" 1000 500 15000

    assert [ -f "$RALPH_TRACE_FILE" ]
    local record
    record=$(cat "$RALPH_TRACE_FILE")
    echo "$record" | jq -e '.resourceSpans[0].scopeSpans[0].spans[0].traceId' > /dev/null
    echo "$record" | jq -e '.resourceSpans[0].scopeSpans[0].spans[0].attributes[] | select(.key == "gen_ai.request.model")' > /dev/null
}

@test "ralph_trace_record is no-op when disabled" {
    source "$RALPH_DIR/lib/tracing.sh"
    RALPH_TRACE_DIR="$TEST_DIR/traces"
    RALPH_TRACE_FILE="$RALPH_TRACE_DIR/traces-test.jsonl"
    RALPH_OTEL_ENABLED="false"

    ralph_trace_start "1" "TEST-1"
    ralph_trace_record "loop_1" "OK" "claude-sonnet-4-6" 1000 500 15000

    assert [ ! -f "$RALPH_TRACE_FILE" ]
}

@test "ralph_trace_record sanitizes API keys" {
    source "$RALPH_DIR/lib/tracing.sh"
    RALPH_TRACE_DIR="$TEST_DIR/traces"
    RALPH_TRACE_FILE="$RALPH_TRACE_DIR/traces-test.jsonl"
    RALPH_OTEL_ENABLED="true"
    RALPH_VERSION="2.1.0"

    ralph_trace_start "1" "TEST-1"
    ralph_trace_record "ANTHROPIC_API_KEY=sk-abc123 loop" "OK" "claude-sonnet-4-6" 0 0 0

    local content
    content=$(cat "$RALPH_TRACE_FILE")
    refute_output_contains "sk-abc123" "$content"
}
```

## References

- [OpenTelemetry GenAI Semantic Conventions](https://opentelemetry.io/docs/specs/semconv/gen-ai/)
- [OTLP JSON Encoding](https://opentelemetry.io/docs/specs/otlp/#json-protobuf-encoding)
- [Langfuse OTel Integration](https://langfuse.com/blog/2024-10-opentelemetry-for-llm-observability)
- [LangWatch — Trace IDs in AI](https://langwatch.ai/blog/trace-ids-llm-observability-and-distributed-tracing)
