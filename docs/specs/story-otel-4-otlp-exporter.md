# Story OTEL-4: OTLP Exporter for External Backends

**Epic:** [OpenTelemetry & Observability v2](epic-otel-observability.md)
**Priority:** Medium
**Status:** Open
**Effort:** Medium
**Component:** new `lib/otlp_exporter.sh`, `lib/tracing.sh`

---

## Problem

Ralph's OTel-compatible traces (OTEL-1) are written to local JSONL files. Users who want to view traces in external platforms (Langfuse, Helicone, Datadog, Grafana Tempo) must manually import the files.

## Solution

Add an optional OTLP HTTP exporter that batches and ships trace records to a configurable OTLP endpoint. The exporter runs asynchronously to avoid blocking the main loop.

## Implementation

### Step 1: Create `lib/otlp_exporter.sh`

```bash
RALPH_OTLP_ENDPOINT="${RALPH_OTLP_ENDPOINT:-}"  # Empty = disabled
RALPH_OTLP_HEADERS="${RALPH_OTLP_HEADERS:-}"    # e.g., "Authorization=Bearer xxx"
RALPH_OTLP_BATCH_SIZE=${RALPH_OTLP_BATCH_SIZE:-10}
RALPH_OTLP_FLUSH_INTERVAL=${RALPH_OTLP_FLUSH_INTERVAL:-60}  # seconds
RALPH_OTLP_BUFFER="${RALPH_DIR}/.otlp_buffer"

ralph_otlp_enqueue() {
    local trace_json="$1"
    echo "$trace_json" >> "$RALPH_OTLP_BUFFER"

    local count
    count=$(wc -l < "$RALPH_OTLP_BUFFER" 2>/dev/null || echo "0")
    if [[ "$count" -ge "$RALPH_OTLP_BATCH_SIZE" ]]; then
        ralph_otlp_flush &
    fi
}

ralph_otlp_flush() {
    [[ -z "$RALPH_OTLP_ENDPOINT" ]] && return 0
    [[ ! -f "$RALPH_OTLP_BUFFER" ]] && return 0
    [[ ! -s "$RALPH_OTLP_BUFFER" ]] && return 0

    local batch_file="${RALPH_OTLP_BUFFER}.sending.$$"
    mv "$RALPH_OTLP_BUFFER" "$batch_file" 2>/dev/null || return 0

    # Merge individual trace records into a single OTLP payload
    local payload
    payload=$(jq -s '{resourceSpans: [.[].resourceSpans[]] }' "$batch_file")

    local headers=""
    if [[ -n "$RALPH_OTLP_HEADERS" ]]; then
        headers="-H \"${RALPH_OTLP_HEADERS/=/: }\""
    fi

    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST \
        -H "Content-Type: application/json" \
        $headers \
        -d "$payload" \
        "${RALPH_OTLP_ENDPOINT}/v1/traces" \
        --max-time 10)

    if [[ "$http_code" -ge 200 && "$http_code" -lt 300 ]]; then
        rm -f "$batch_file"
        log "DEBUG" "OTLP: exported $(wc -l < "$batch_file" 2>/dev/null || echo "?") traces"
    else
        log "WARN" "OTLP export failed (HTTP $http_code) — traces saved to $batch_file for retry"
    fi
}
```

### Step 2: Integrate with trace recording

```bash
# In ralph_trace_record (lib/tracing.sh), after writing to local file:
if [[ -n "${RALPH_OTLP_ENDPOINT:-}" ]]; then
    ralph_otlp_enqueue "$trace_json"
fi
```

### Step 3: Flush on loop exit

```bash
# In cleanup/trap handler:
ralph_otlp_flush 2>/dev/null &
wait $! 2>/dev/null
```

## Design Notes

- **Async flush**: Background process prevents blocking the main loop. Failed exports are retained for retry.
- **Batch merging**: Individual JSONL records are merged into a single OTLP payload to reduce HTTP overhead.
- **Header configuration**: Supports auth tokens for Langfuse (`Authorization=Bearer pk-xxx`), Datadog (`DD-API-KEY=xxx`), etc.
- **curl timeout**: 10-second max to prevent hanging on unreachable endpoints.
- **Graceful failure**: Export failures are logged but never halt the loop. Traces are always written to local JSONL first.

## Acceptance Criteria

- [ ] Traces exported to `RALPH_OTLP_ENDPOINT` when configured
- [ ] Batching reduces HTTP calls (default: batch of 10)
- [ ] Failed exports are retained for retry
- [ ] Export is asynchronous (does not block main loop)
- [ ] Auth headers configurable via `RALPH_OTLP_HEADERS`
- [ ] Flush on loop exit ensures no trace loss
- [ ] No export when `RALPH_OTLP_ENDPOINT` is empty

## Test Plan

```bash
@test "ralph_otlp_enqueue buffers traces" {
    source "$RALPH_DIR/lib/otlp_exporter.sh"
    RALPH_DIR="$TEST_DIR"
    RALPH_OTLP_BUFFER="$TEST_DIR/.otlp_buffer"
    RALPH_OTLP_BATCH_SIZE=100  # High to prevent auto-flush

    ralph_otlp_enqueue '{"test": 1}'
    ralph_otlp_enqueue '{"test": 2}'

    assert_equal "$(wc -l < "$RALPH_OTLP_BUFFER" | tr -d ' ')" "2"
}

@test "ralph_otlp_flush is no-op without endpoint" {
    source "$RALPH_DIR/lib/otlp_exporter.sh"
    RALPH_OTLP_ENDPOINT=""

    run ralph_otlp_flush
    assert_success
}
```

## References

- [OTLP HTTP Specification](https://opentelemetry.io/docs/specs/otlp/#otlphttp)
- [Langfuse OTLP Endpoint](https://langfuse.com/docs/opentelemetry)
- [Helicone OTLP Integration](https://docs.helicone.ai/integrations/opentelemetry)
