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

# =============================================================================
# OTEL-3: Cost Attribution and Budget Alerts
# =============================================================================

# Configuration
RALPH_COST_BUDGET_USD="${RALPH_COST_BUDGET_USD:-0}"  # 0 = no budget (disabled)
RALPH_COST_ALERT_THRESHOLD="${RALPH_COST_ALERT_THRESHOLD:-80}"  # Alert at 80% of budget

# Cost rates per 1M tokens (March 2026 Anthropic pricing)
# These are defaults and can be overridden via environment
RALPH_COST_HAIKU_INPUT="${RALPH_COST_HAIKU_INPUT:-0.25}"
RALPH_COST_HAIKU_OUTPUT="${RALPH_COST_HAIKU_OUTPUT:-1.25}"
RALPH_COST_SONNET_INPUT="${RALPH_COST_SONNET_INPUT:-3.00}"
RALPH_COST_SONNET_OUTPUT="${RALPH_COST_SONNET_OUTPUT:-15.00}"
RALPH_COST_OPUS_INPUT="${RALPH_COST_OPUS_INPUT:-15.00}"
RALPH_COST_OPUS_OUTPUT="${RALPH_COST_OPUS_OUTPUT:-75.00}"

# ralph_trace_calculate_cost — Calculate USD cost for a given model and token counts
#
# Usage: cost=$(ralph_trace_calculate_cost "sonnet" 1000 500)
# Returns: cost in USD as decimal string (e.g., "0.0105")
#
ralph_trace_calculate_cost() {
    local model="${1:-sonnet}"
    local input_tokens="${2:-0}"
    local output_tokens="${3:-0}"

    local input_rate output_rate
    case "$model" in
        *haiku*)
            input_rate="$RALPH_COST_HAIKU_INPUT"
            output_rate="$RALPH_COST_HAIKU_OUTPUT"
            ;;
        *opus*)
            input_rate="$RALPH_COST_OPUS_INPUT"
            output_rate="$RALPH_COST_OPUS_OUTPUT"
            ;;
        *)  # Default: sonnet pricing
            input_rate="$RALPH_COST_SONNET_INPUT"
            output_rate="$RALPH_COST_SONNET_OUTPUT"
            ;;
    esac

    # Cost = (input_tokens / 1M * input_rate) + (output_tokens / 1M * output_rate)
    # Use awk for floating point math (no bc dependency)
    awk -v it="$input_tokens" -v ot="$output_tokens" \
        -v ir="$input_rate" -v or_rate="$output_rate" \
        'BEGIN { printf "%.6f", (it / 1000000 * ir) + (ot / 1000000 * or_rate) }'
}

# ralph_trace_record_cost — Record cost for this iteration and check budget
#
# Usage: ralph_trace_record_cost "sonnet" 5000 2000
#
# Side effects:
#   - Appends cost to .ralph/traces/costs.jsonl
#   - Writes budget alert to .ralph/.cost_alert if threshold exceeded
#
ralph_trace_record_cost() {
    [[ "$RALPH_OTEL_ENABLED" != "true" ]] && return 0

    local model="${1:-sonnet}"
    local input_tokens="${2:-0}"
    local output_tokens="${3:-0}"

    local cost
    cost=$(ralph_trace_calculate_cost "$model" "$input_tokens" "$output_tokens")

    local cost_file="$TRACE_DIR/costs.jsonl"
    mkdir -p "$TRACE_DIR"

    local timestamp
    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    # Append cost record
    printf '{"timestamp":"%s","model":"%s","input_tokens":%s,"output_tokens":%s,"cost_usd":%s,"trace_id":"%s","loop_count":%s}\n' \
        "$timestamp" "$model" "$input_tokens" "$output_tokens" "$cost" \
        "${RALPH_TRACE_ID:-}" "${LOOP_COUNT:-0}" >> "$cost_file"

    # Check budget if set
    if [[ "$RALPH_COST_BUDGET_USD" != "0" ]] && [[ -f "$cost_file" ]]; then
        local total_cost
        total_cost=$(awk -F'"cost_usd":' '{split($2,a,",|}"); sum+=a[1]} END{printf "%.6f", sum}' "$cost_file" 2>/dev/null || echo "0")

        local budget_pct
        budget_pct=$(awk -v total="$total_cost" -v budget="$RALPH_COST_BUDGET_USD" \
            'BEGIN { if (budget > 0) printf "%.0f", (total / budget * 100); else print "0" }')

        if [[ "$budget_pct" -ge "$RALPH_COST_ALERT_THRESHOLD" ]]; then
            local alert_msg="Cost alert: \$${total_cost} of \$${RALPH_COST_BUDGET_USD} budget used (${budget_pct}%)"
            echo "$alert_msg" > "${RALPH_DIR:-.ralph}/.cost_alert"

            # Log alert
            if declare -f log_status &>/dev/null; then
                log_status "WARN" "$alert_msg"
            else
                echo "[WARN] $alert_msg" >&2
            fi
        fi
    fi
}

# ralph_trace_cost_summary — Show cost summary from trace data
#
# Usage: ralph_trace_cost_summary [--json]
#
ralph_trace_cost_summary() {
    local format="human"
    [[ "$1" == "--json" ]] && format="json"

    local cost_file="$TRACE_DIR/costs.jsonl"
    if [[ ! -f "$cost_file" ]]; then
        [[ "$format" == "json" ]] && echo '{"error":"no cost data"}' || echo "No cost data found."
        return 0
    fi

    if ! command -v jq &>/dev/null; then
        echo "Error: jq required for cost summary"
        return 1
    fi

    local summary
    summary=$(jq -s '{
        total_cost: ([.[].cost_usd] | add // 0),
        total_input_tokens: ([.[].input_tokens] | add // 0),
        total_output_tokens: ([.[].output_tokens] | add // 0),
        iterations: length,
        by_model: (group_by(.model) | map({
            model: .[0].model,
            cost: ([.[].cost_usd] | add // 0),
            iterations: length
        }))
    }' "$cost_file" 2>/dev/null)

    if [[ "$format" == "json" ]]; then
        echo "$summary"
    else
        echo "Cost Summary"
        echo "============"
        echo "  Total cost:    \$$(echo "$summary" | jq -r '.total_cost | . * 100 | round / 100')"
        echo "  Iterations:    $(echo "$summary" | jq -r '.iterations')"
        echo "  Input tokens:  $(echo "$summary" | jq -r '.total_input_tokens')"
        echo "  Output tokens: $(echo "$summary" | jq -r '.total_output_tokens')"
        echo ""
        echo "By model:"
        echo "$summary" | jq -r '.by_model[] | "  \(.model): $\(.cost | . * 100 | round / 100) (\(.iterations) iterations)"'

        # Show budget if set
        if [[ "$RALPH_COST_BUDGET_USD" != "0" ]]; then
            local total
            total=$(echo "$summary" | jq -r '.total_cost')
            local pct
            pct=$(awk -v t="$total" -v b="$RALPH_COST_BUDGET_USD" 'BEGIN{printf "%.0f", t/b*100}')
            echo ""
            echo "  Budget: \$${RALPH_COST_BUDGET_USD} (${pct}% used)"
        fi
    fi
}

# =============================================================================
# OTEL-4: OTLP Exporter
# =============================================================================

# Configuration
RALPH_OTLP_ENDPOINT="${RALPH_OTLP_ENDPOINT:-}"  # e.g., http://localhost:4318/v1/traces
RALPH_OTLP_HEADERS="${RALPH_OTLP_HEADERS:-}"    # e.g., "Authorization=Bearer token"
RALPH_OTLP_EXPORT_ENABLED="${RALPH_OTLP_EXPORT_ENABLED:-false}"

# ralph_otlp_export — Export pending trace spans to an OTLP HTTP endpoint
#
# Reads the current month's trace JSONL file, sends each record as an
# OTLP/HTTP JSON request. Successfully exported spans are tracked in
# .ralph/traces/.exported_offset to avoid re-export.
#
# Usage: ralph_otlp_export
#
ralph_otlp_export() {
    [[ "$RALPH_OTLP_EXPORT_ENABLED" != "true" ]] && return 0
    [[ -z "$RALPH_OTLP_ENDPOINT" ]] && return 0
    command -v curl &>/dev/null || { echo "[WARN] curl required for OTLP export" >&2; return 1; }

    local trace_file="$TRACE_DIR/$(date '+%Y-%m').jsonl"
    [[ ! -f "$trace_file" ]] && return 0

    local offset_file="$TRACE_DIR/.exported_offset"
    local last_offset=0
    [[ -f "$offset_file" ]] && last_offset=$(cat "$offset_file" 2>/dev/null || echo "0")
    [[ "$last_offset" =~ ^[0-9]+$ ]] || last_offset=0

    local total_lines
    total_lines=$(wc -l < "$trace_file" | tr -d ' ')

    if [[ "$last_offset" -ge "$total_lines" ]]; then
        return 0  # Nothing new to export
    fi

    # Build headers
    local curl_headers=(-H "Content-Type: application/json")
    if [[ -n "$RALPH_OTLP_HEADERS" ]]; then
        # Parse "Key1=Value1,Key2=Value2" format
        IFS=',' read -ra header_pairs <<< "$RALPH_OTLP_HEADERS"
        for pair in "${header_pairs[@]}"; do
            local key="${pair%%=*}"
            local val="${pair#*=}"
            curl_headers+=(-H "$key: $val")
        done
    fi

    # Export each new span
    local exported=0
    local line_num=0
    while IFS= read -r line; do
        line_num=$((line_num + 1))
        [[ $line_num -le $last_offset ]] && continue
        [[ -z "$line" ]] && continue

        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" \
            "${curl_headers[@]}" \
            -X POST \
            --data "$line" \
            --max-time 5 \
            "$RALPH_OTLP_ENDPOINT" 2>/dev/null || echo "000")

        if [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]]; then
            exported=$((exported + 1))
        else
            # Stop on first failure (retry next time)
            echo "[WARN] OTLP export failed at line $line_num (HTTP $http_code)" >&2
            break
        fi
    done < "$trace_file"

    # Update offset
    echo "$((last_offset + exported))" > "$offset_file"

    if [[ $exported -gt 0 ]] && declare -f log_status &>/dev/null; then
        log_status "INFO" "Exported $exported trace spans to OTLP endpoint"
    fi
}

# ralph_otlp_export_batch — Batch export (sends all pending spans in one request)
#
# More efficient than per-span export for backends that support batch ingest.
#
ralph_otlp_export_batch() {
    [[ "$RALPH_OTLP_EXPORT_ENABLED" != "true" ]] && return 0
    [[ -z "$RALPH_OTLP_ENDPOINT" ]] && return 0
    command -v curl &>/dev/null || return 1

    local trace_file="$TRACE_DIR/$(date '+%Y-%m').jsonl"
    [[ ! -f "$trace_file" ]] && return 0

    local offset_file="$TRACE_DIR/.exported_offset"
    local last_offset=0
    [[ -f "$offset_file" ]] && last_offset=$(cat "$offset_file" 2>/dev/null || echo "0")
    [[ "$last_offset" =~ ^[0-9]+$ ]] || last_offset=0

    local total_lines
    total_lines=$(wc -l < "$trace_file" | tr -d ' ')
    [[ "$last_offset" -ge "$total_lines" ]] && return 0

    # Collect new spans into a batch array
    local spans
    spans=$(tail -n +$((last_offset + 1)) "$trace_file" | jq -s '.' 2>/dev/null)
    [[ -z "$spans" || "$spans" == "[]" ]] && return 0

    local curl_headers=(-H "Content-Type: application/json")
    if [[ -n "$RALPH_OTLP_HEADERS" ]]; then
        IFS=',' read -ra header_pairs <<< "$RALPH_OTLP_HEADERS"
        for pair in "${header_pairs[@]}"; do
            curl_headers+=(-H "${pair%%=*}: ${pair#*=}")
        done
    fi

    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        "${curl_headers[@]}" \
        -X POST \
        --data "$spans" \
        --max-time 10 \
        "$RALPH_OTLP_ENDPOINT" 2>/dev/null || echo "000")

    if [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]]; then
        echo "$total_lines" > "$offset_file"
        local count=$((total_lines - last_offset))
        declare -f log_status &>/dev/null && log_status "INFO" "Batch exported $count trace spans"
    else
        echo "[WARN] Batch OTLP export failed (HTTP $http_code)" >&2
    fi
}
