#!/bin/bash

# lib/tracing.sh — OpenTelemetry-compatible trace generation (Phase 14, OTEL-1)
#
# Generates per-iteration traces in JSONL format matching OTLP JSON encoding.
# Includes GenAI Semantic Convention attributes for LLM observability.
#
# Configuration:
#   RALPH_OTEL_ENABLED=true    — Enable trace generation (default: false)
#   RALPH_TRACE_DIR            — Directory for trace files (default: .ralph/traces/)
#   RALPH_TRACE_RETENTION_MONTHS — Months to retain old trace files (default: 6)

TRACE_DIR="${RALPH_TRACE_DIR:-${RALPH_DIR:-.ralph}/traces}"
RALPH_OTEL_ENABLED="${RALPH_OTEL_ENABLED:-false}"
RALPH_TRACE_RETENTION_MONTHS="${RALPH_TRACE_RETENTION_MONTHS:-6}"

# Current trace context (exported for sub-agents and hooks)
export RALPH_TRACE_ID=""
export RALPH_PARENT_SPAN_ID=""

# ralph_trace_generate_id — Generate a UUID v4 trace ID
#
# Uses /proc/sys/kernel/random/uuid (Linux), uuidgen (macOS/WSL), or
# random hex fallback. Returns lowercase hex without dashes (32 chars).
#
ralph_trace_generate_id() {
    local uuid=""
    if [[ -f /proc/sys/kernel/random/uuid ]]; then
        uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null)
    elif command -v uuidgen &>/dev/null; then
        uuid=$(uuidgen 2>/dev/null)
    fi

    if [[ -z "$uuid" ]]; then
        # Fallback: random hex from /dev/urandom
        uuid=$(od -An -tx1 -N16 /dev/urandom 2>/dev/null | tr -d ' \n' | head -c32)
    fi

    # Normalize: lowercase, no dashes
    echo "${uuid//-/}" | tr '[:upper:]' '[:lower:]' | head -c32
}

# ralph_trace_generate_span_id — Generate a span ID (16 hex chars)
#
ralph_trace_generate_span_id() {
    if [[ -f /dev/urandom ]]; then
        od -An -tx1 -N8 /dev/urandom 2>/dev/null | tr -d ' \n' | head -c16
    else
        printf '%016x' $((RANDOM * RANDOM))
    fi
}

# ralph_trace_timestamp_ns — Get current timestamp in nanoseconds
#
# Falls back to seconds * 1e9 if nanosecond precision unavailable.
#
ralph_trace_timestamp_ns() {
    if date '+%s%N' &>/dev/null 2>&1; then
        local ns
        ns=$(date '+%s%N' 2>/dev/null)
        # On macOS, %N may output literal 'N'
        if [[ "$ns" == *N* ]]; then
            echo "$(date '+%s')000000000"
        else
            echo "$ns"
        fi
    else
        echo "$(date '+%s')000000000"
    fi
}

# ralph_trace_start — Begin a new trace for this loop iteration
#
# Sets RALPH_TRACE_ID and RALPH_PARENT_SPAN_ID for context propagation.
# Creates the trace directory if needed.
#
# Usage: ralph_trace_start
#
ralph_trace_start() {
    [[ "$RALPH_OTEL_ENABLED" != "true" ]] && return 0

    RALPH_TRACE_ID=$(ralph_trace_generate_id)
    RALPH_PARENT_SPAN_ID=$(ralph_trace_generate_span_id)
    export RALPH_TRACE_ID RALPH_PARENT_SPAN_ID

    mkdir -p "$TRACE_DIR"
}

# ralph_trace_record — Record a trace span for this iteration
#
# Usage: ralph_trace_record <span_name> <start_ns> <end_ns> \
#          <model> <input_tokens> <output_tokens> <finish_reason> [extra_json]
#
# Writes an OTLP-compatible JSONL record to the monthly trace file.
# Sanitizes any API keys/secrets before writing.
#
ralph_trace_record() {
    [[ "$RALPH_OTEL_ENABLED" != "true" ]] && return 0

    local span_name="${1:-ralph_iteration}"
    local start_ns="${2:-0}"
    local end_ns="${3:-0}"
    local model="${4:-unknown}"
    local input_tokens="${5:-0}"
    local output_tokens="${6:-0}"
    local finish_reason="${7:-unknown}"
    local extra_json="${8:-}"

    local span_id
    span_id=$(ralph_trace_generate_span_id)

    local trace_file="$TRACE_DIR/$(date '+%Y-%m').jsonl"

    # Build the trace record
    local record
    record=$(cat <<TRACE_EOF
{"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"ralph"}},{"key":"service.version","value":{"stringValue":"${RALPH_VERSION:-unknown}"}}]},"scopeSpans":[{"scope":{"name":"ralph.loop"},"spans":[{"traceId":"${RALPH_TRACE_ID}","spanId":"${span_id}","parentSpanId":"${RALPH_PARENT_SPAN_ID}","name":"${span_name}","startTimeUnixNano":"${start_ns}","endTimeUnixNano":"${end_ns}","attributes":[{"key":"gen_ai.system","value":{"stringValue":"anthropic"}},{"key":"gen_ai.request.model","value":{"stringValue":"${model}"}},{"key":"gen_ai.usage.input_tokens","value":{"intValue":"${input_tokens}"}},{"key":"gen_ai.usage.output_tokens","value":{"intValue":"${output_tokens}"}},{"key":"gen_ai.response.finish_reason","value":{"stringValue":"${finish_reason}"}},{"key":"ralph.loop_count","value":{"intValue":"${LOOP_COUNT:-0}"}},{"key":"ralph.correlation_id","value":{"stringValue":"${RALPH_TRACE_ID}"}}]}]}]}]}
TRACE_EOF
    )

    # Sanitize: remove any API key patterns
    record=$(echo "$record" | sed -E \
        -e 's/sk-ant-[a-zA-Z0-9_-]+/[REDACTED]/g' \
        -e 's/sk-[a-zA-Z0-9]{20,}/[REDACTED]/g' \
        -e 's/ANTHROPIC_API_KEY=[^ "]+/ANTHROPIC_API_KEY=[REDACTED]/g')

    echo "$record" >> "$trace_file"
}

# ralph_trace_child_span — Create a child span (for hooks/sub-agents)
#
# Usage: ralph_trace_child_span <span_name> <start_ns> <end_ns> [extra_attrs_json]
#
ralph_trace_child_span() {
    [[ "$RALPH_OTEL_ENABLED" != "true" ]] && return 0
    [[ -z "$RALPH_TRACE_ID" ]] && return 0

    local span_name="${1:-child}"
    local start_ns="${2:-0}"
    local end_ns="${3:-0}"

    local child_span_id
    child_span_id=$(ralph_trace_generate_span_id)

    local trace_file="$TRACE_DIR/$(date '+%Y-%m').jsonl"

    local record
    record=$(cat <<CHILD_EOF
{"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"ralph"}}]},"scopeSpans":[{"scope":{"name":"ralph.hooks"},"spans":[{"traceId":"${RALPH_TRACE_ID}","spanId":"${child_span_id}","parentSpanId":"${RALPH_PARENT_SPAN_ID}","name":"${span_name}","startTimeUnixNano":"${start_ns}","endTimeUnixNano":"${end_ns}","attributes":[]}]}]}]}
CHILD_EOF
    )

    echo "$record" >> "$trace_file"
}

# ralph_trace_rotate — Prune trace files older than retention period
#
# Usage: ralph_trace_rotate
#
ralph_trace_rotate() {
    [[ ! -d "$TRACE_DIR" ]] && return 0

    local retention_months="${RALPH_TRACE_RETENTION_MONTHS}"
    local cutoff_date

    if date -d "-${retention_months} months" '+%Y-%m' &>/dev/null 2>&1; then
        cutoff_date=$(date -d "-${retention_months} months" '+%Y-%m')
    elif date -v "-${retention_months}m" '+%Y-%m' &>/dev/null 2>&1; then
        cutoff_date=$(date -v "-${retention_months}m" '+%Y-%m')
    else
        return 0
    fi

    for trace_file in "$TRACE_DIR"/*.jsonl; do
        [[ ! -f "$trace_file" ]] && continue
        local file_month
        file_month=$(basename "$trace_file" .jsonl)
        if [[ "$file_month" < "$cutoff_date" ]]; then
            rm -f "$trace_file"
        fi
    done
}
