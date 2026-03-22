# Story OTEL-2: Trace ID Propagation Across Sub-Agents and Hooks

**Epic:** [OpenTelemetry & Observability v2](epic-otel-observability.md)
**Priority:** High
**Status:** Open
**Effort:** Small
**Component:** `.claude/hooks/`, `.claude/agents/ralph.md`, `ralph_loop.sh`

---

## Problem

Sub-agents (ralph-explorer, ralph-tester, ralph-reviewer, ralph-architect) and hooks (on-stop.sh, on-session-start.sh, protect-ralph-files.sh) execute as independent processes with no shared correlation ID. When a sub-agent fails or a hook misbehaves, tracing the failure back to the originating loop iteration requires manual timestamp correlation.

## Solution

Propagate `RALPH_TRACE_ID` and `RALPH_PARENT_SPAN_ID` as environment variables to all sub-processes. Each sub-agent and hook creates a child span linked to the parent trace.

## Implementation

### Step 1: Export trace context in ralph_loop.sh

```bash
# After ralph_trace_start(), export for child processes
export RALPH_TRACE_ID
export RALPH_PARENT_SPAN_ID="$RALPH_SPAN_ID"
```

### Step 2: Update hook scripts to emit child spans

```bash
# In on-stop.sh, on-session-start.sh, etc.:
if [[ -n "${RALPH_TRACE_ID:-}" ]]; then
    source "$(dirname "$0")/../../lib/tracing.sh" 2>/dev/null || true
    local hook_span_id
    hook_span_id=$(ralph_generate_span_id)
    # Record hook execution as child span
    ralph_trace_child_span \
        "$RALPH_TRACE_ID" \
        "$RALPH_PARENT_SPAN_ID" \
        "$hook_span_id" \
        "hook:$(basename "$0" .sh)" \
        "$hook_status"
fi
```

### Step 3: Add child span function to lib/tracing.sh

```bash
ralph_trace_child_span() {
    [[ "$RALPH_OTEL_ENABLED" != "true" ]] && return 0

    local trace_id="$1" parent_span_id="$2" span_id="$3"
    local name="$4" status="$5"
    local start_time="${6:-$(date +%s%N 2>/dev/null || echo "$(date +%s)000000000")}"
    local end_time
    end_time=$(date +%s%N 2>/dev/null || echo "$(date +%s)000000000")

    jq -n -c \
        --arg trace_id "$trace_id" \
        --arg parent_span_id "$parent_span_id" \
        --arg span_id "$span_id" \
        --arg name "$name" \
        --arg status "$status" \
        --arg start_time "$start_time" \
        --arg end_time "$end_time" \
        '{
            resourceSpans: [{
                scopeSpans: [{
                    spans: [{
                        traceId: $trace_id,
                        parentSpanId: $parent_span_id,
                        spanId: $span_id,
                        name: $name,
                        startTimeUnixNano: $start_time,
                        endTimeUnixNano: $end_time,
                        status: {code: (if $status == "OK" then 1 else 2 end)}
                    }]
                }]
            }]
        }' >> "$RALPH_TRACE_FILE"
}
```

### Step 4: Include trace_id in status.json

```bash
# In on-stop.sh, add trace_id to status.json output:
if [[ -n "${RALPH_TRACE_ID:-}" ]]; then
    jq --arg tid "$RALPH_TRACE_ID" '. + {trace_id: $tid}' "$STATUS_FILE" > "${STATUS_FILE}.tmp"
    mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
fi
```

## Design Notes

- **Environment variable propagation**: Simplest cross-process trace context transport. No need for HTTP headers or file-based passing since all sub-processes are local.
- **Graceful degradation**: If `RALPH_TRACE_ID` is unset (e.g., running outside the loop), hooks skip span emission silently.
- **Parent-child linking**: OTel `parentSpanId` field creates a proper trace tree: loop iteration → Claude invocation → hook executions / sub-agent spans.
- **status.json inclusion**: Allows the main loop to correlate status reads with the trace that generated them.

## Acceptance Criteria

- [ ] `RALPH_TRACE_ID` and `RALPH_PARENT_SPAN_ID` are exported before Claude CLI invocation
- [ ] Hook scripts emit child spans linked to the parent trace
- [ ] Sub-agent spawns inherit trace context via environment
- [ ] `status.json` includes `trace_id` field when tracing is enabled
- [ ] Missing trace context does not cause hook failures (graceful degradation)

## Test Plan

```bash
@test "trace context is exported as environment variables" {
    source "$RALPH_DIR/lib/tracing.sh"
    ralph_trace_start "1" "TEST-1"

    assert [ -n "$RALPH_TRACE_ID" ]
    assert [ -n "$RALPH_SPAN_ID" ]
}

@test "ralph_trace_child_span links to parent" {
    source "$RALPH_DIR/lib/tracing.sh"
    RALPH_TRACE_DIR="$TEST_DIR/traces"
    RALPH_TRACE_FILE="$RALPH_TRACE_DIR/traces-test.jsonl"
    RALPH_OTEL_ENABLED="true"
    mkdir -p "$RALPH_TRACE_DIR"

    local parent_span="abc123"
    ralph_trace_child_span "trace-1" "$parent_span" "child-1" "hook:on-stop" "OK"

    local record
    record=$(cat "$RALPH_TRACE_FILE")
    echo "$record" | jq -e '.resourceSpans[0].scopeSpans[0].spans[0].parentSpanId == "abc123"'
}
```

## References

- [W3C Trace Context — Propagation](https://www.w3.org/TR/trace-context/)
- [OTel Context Propagation](https://opentelemetry.io/docs/concepts/context-propagation/)
