# Story OTEL-3: Per-Trace Cost Attribution and Budget Alerts

**Epic:** [OpenTelemetry & Observability v2](epic-otel-observability.md)
**Priority:** Medium
**Status:** Open
**Effort:** Small
**Component:** `lib/tracing.sh`, `lib/metrics.sh`, `ralph_loop.sh`

---

## Problem

Ralph tracks aggregate token usage per session but cannot attribute costs to individual tasks, sub-agents, or iterations. Users running multi-hour loops have no visibility into which tasks consumed the most tokens or cost.

The 2026 best practice is per-trace cost attribution as the highest-impact cost optimization — you can't reduce what you can't measure.

## Solution

Calculate and record per-iteration cost based on model pricing, accumulate per-task costs, and alert when a configurable budget threshold is exceeded.

## Implementation

### Step 1: Model pricing table

```bash
# In lib/tracing.sh:
# Pricing per 1M tokens (USD) — updated for 2026 models
ralph_get_model_cost() {
    local model="$1" direction="$2"  # direction: input or output
    case "$model" in
        *opus*)   [[ "$direction" == "input" ]] && echo "15.00" || echo "75.00" ;;
        *sonnet*) [[ "$direction" == "input" ]] && echo "3.00"  || echo "15.00" ;;
        *haiku*)  [[ "$direction" == "input" ]] && echo "0.80"  || echo "4.00"  ;;
        *)        [[ "$direction" == "input" ]] && echo "3.00"  || echo "15.00" ;;  # default to Sonnet
    esac
}

ralph_calculate_cost() {
    local model="$1" input_tokens="$2" output_tokens="$3"
    local input_rate output_rate cost
    input_rate=$(ralph_get_model_cost "$model" "input")
    output_rate=$(ralph_get_model_cost "$model" "output")
    # cost = (input_tokens / 1M * input_rate) + (output_tokens / 1M * output_rate)
    cost=$(awk "BEGIN {printf \"%.6f\", ($input_tokens / 1000000 * $input_rate) + ($output_tokens / 1000000 * $output_rate)}")
    echo "$cost"
}
```

### Step 2: Record cost in trace and accumulate

```bash
RALPH_SESSION_COST_FILE="${RALPH_DIR}/.session_cost"

ralph_trace_record_with_cost() {
    # ... existing ralph_trace_record logic ...
    local cost
    cost=$(ralph_calculate_cost "$model" "$input_tokens" "$output_tokens")

    # Accumulate session cost
    local prev_cost
    prev_cost=$(cat "$RALPH_SESSION_COST_FILE" 2>/dev/null || echo "0")
    awk "BEGIN {printf \"%.6f\", $prev_cost + $cost}" > "$RALPH_SESSION_COST_FILE"

    # Check budget
    ralph_check_budget "$cost"
}

ralph_check_budget() {
    local iteration_cost="$1"
    local budget="${RALPH_COST_BUDGET_USD:-0}"  # 0 = no budget
    [[ "$budget" == "0" ]] && return 0

    local total_cost
    total_cost=$(cat "$RALPH_SESSION_COST_FILE" 2>/dev/null || echo "0")

    if awk "BEGIN {exit !($total_cost > $budget)}"; then
        log "WARN" "Cost budget exceeded: \$${total_cost} > \$${budget} budget"
        # Send notification if configured
        [[ -n "${RALPH_NOTIFY_WEBHOOK:-}" ]] && \
            ralph_notify "budget_exceeded" "Session cost \$${total_cost} exceeds budget \$${budget}"
    fi
}
```

### Step 3: Add cost to --stats output

```bash
# In --stats handler:
local session_cost
session_cost=$(cat "$RALPH_SESSION_COST_FILE" 2>/dev/null || echo "0")
echo "Session Cost: \$${session_cost}"
echo "Budget: \$${RALPH_COST_BUDGET_USD:-unlimited}"
```

## Design Notes

- **Pricing table maintained in code**: Simpler than API lookups. Updated per model release. Users can override via `RALPH_MODEL_PRICING_FILE` for custom/self-hosted models.
- **awk for floating point**: bash doesn't support float arithmetic natively. awk is ubiquitous and sufficient.
- **Budget is advisory**: Exceeding budget triggers a warning/notification but doesn't halt the loop. Users can set `RALPH_COST_BUDGET_HARD=true` to halt on budget breach.
- **Session cost file reset**: Cleared on `ralph --reset` or new session start. Persists across loop iterations.

## Acceptance Criteria

- [ ] Per-iteration cost calculated from model pricing and token counts
- [ ] Cumulative session cost tracked in `.session_cost`
- [ ] `ralph --stats` shows session cost and budget
- [ ] Warning logged when cost exceeds `RALPH_COST_BUDGET_USD`
- [ ] Webhook notification sent on budget breach (if configured)
- [ ] Cost included as attribute in OTel trace records

## Test Plan

```bash
@test "ralph_calculate_cost computes correct Sonnet cost" {
    source "$RALPH_DIR/lib/tracing.sh"
    local cost
    cost=$(ralph_calculate_cost "claude-sonnet-4-6" 100000 50000)
    # (100000/1M * 3.00) + (50000/1M * 15.00) = 0.30 + 0.75 = 1.05
    assert_equal "$cost" "1.050000"
}

@test "ralph_check_budget warns on exceeded budget" {
    source "$RALPH_DIR/lib/tracing.sh"
    RALPH_DIR="$TEST_DIR"
    RALPH_SESSION_COST_FILE="$TEST_DIR/.session_cost"
    RALPH_COST_BUDGET_USD="1.00"
    echo "1.50" > "$RALPH_SESSION_COST_FILE"

    run ralph_check_budget "0.10"
    assert_output --partial "budget exceeded"
}
```

## References

- [Anthropic Pricing](https://www.anthropic.com/pricing)
- [Moltbook-AI — AI Agent Cost Optimization 2026](https://moltbook-ai.com/posts/ai-agent-cost-optimization-2026)
- [Portkey — LLM Observability](https://portkey.ai/blog/the-complete-guide-to-llm-observability/)
