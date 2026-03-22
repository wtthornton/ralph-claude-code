# Story COSTROUTE-4: Token Budget and Cost Dashboard

**Epic:** [Cost-Aware Model Routing](epic-cost-aware-routing.md)
**Priority:** Medium
**Status:** Open
**Effort:** Small
**Component:** `ralph_loop.sh`, `lib/metrics.sh`

---

## Problem

Ralph has no per-task or per-session token budget. A SMALL task that consumes 200K tokens (due to runaway exploration or repeated failures) goes undetected until the user reviews logs manually.

## Solution

Set expected token budgets per complexity tier. Warn when a task exceeds its budget. Add a cost breakdown view to `ralph --stats`.

## Implementation

### Step 1: Token budget per complexity tier

```bash
# Expected token budgets (input + output combined)
RALPH_BUDGET_TRIVIAL=${RALPH_BUDGET_TRIVIAL:-10000}
RALPH_BUDGET_SIMPLE=${RALPH_BUDGET_SIMPLE:-25000}
RALPH_BUDGET_ROUTINE=${RALPH_BUDGET_ROUTINE:-75000}
RALPH_BUDGET_COMPLEX=${RALPH_BUDGET_COMPLEX:-200000}
RALPH_BUDGET_ARCH=${RALPH_BUDGET_ARCH:-500000}

ralph_get_token_budget() {
    local complexity="$1"
    case "$complexity" in
        1) echo "$RALPH_BUDGET_TRIVIAL" ;;
        2) echo "$RALPH_BUDGET_SIMPLE" ;;
        3) echo "$RALPH_BUDGET_ROUTINE" ;;
        4) echo "$RALPH_BUDGET_COMPLEX" ;;
        5) echo "$RALPH_BUDGET_ARCH" ;;
        *) echo "$RALPH_BUDGET_ROUTINE" ;;
    esac
}

ralph_check_token_budget() {
    local actual="$1" budget="$2" task="$3"
    if [[ "$actual" -gt "$budget" ]]; then
        local pct
        pct=$(awk "BEGIN {printf \"%.0f\", ($actual / $budget) * 100}")
        log "WARN" "Token budget exceeded: ${actual} tokens (${pct}% of ${budget} budget) for task: $task"
    fi
}
```

### Step 2: Cost breakdown in --stats

```bash
# In --stats handler, add model-tier breakdown:
ralph_show_cost_breakdown() {
    local routing_log="${RALPH_DIR}/.model_routing.jsonl"
    [[ ! -f "$routing_log" ]] && echo "No routing data available" && return

    echo "=== Cost by Model Tier ==="
    for tier in haiku sonnet opus; do
        local count cost
        count=$(jq -r "select(.model == \"$tier\")" "$routing_log" | wc -l)
        echo "  $tier: $count invocations"
    done

    echo ""
    echo "=== Cost by Complexity ==="
    for level in TRIVIAL SIMPLE ROUTINE COMPLEX ARCHITECTURAL; do
        local count
        count=$(jq -r "select(.complexity == \"$level\")" "$routing_log" | wc -l)
        echo "  $level: $count tasks"
    done
}
```

## Design Notes

- **Budgets are advisory warnings**: Exceeding a budget logs a warning but doesn't halt execution. Users who want hard limits can set `RALPH_BUDGET_HARD_LIMIT=true`.
- **Budgets configurable per tier**: Teams with different workload profiles can tune budgets via `.ralphrc`.
- **Cost dashboard is read-only**: `ralph --stats` aggregates data from routing logs and trace records without side effects.

## Acceptance Criteria

- [ ] Token budget set per complexity tier with configurable defaults
- [ ] Warning logged when task exceeds budget
- [ ] `ralph --stats` shows cost breakdown by model tier and complexity
- [ ] Budget thresholds configurable via `.ralphrc`

## Test Plan

```bash
@test "ralph_check_token_budget warns on exceedance" {
    source "$RALPH_DIR/lib/complexity.sh"
    run ralph_check_token_budget 150000 75000 "Test task"
    assert_output --partial "budget exceeded"
    assert_output --partial "200%"
}

@test "ralph_check_token_budget is silent under budget" {
    source "$RALPH_DIR/lib/complexity.sh"
    run ralph_check_token_budget 50000 75000 "Test task"
    refute_output --partial "budget exceeded"
}
```

## References

- [Moltbook-AI — AI Agent Cost Optimization 2026](https://moltbook-ai.com/posts/ai-agent-cost-optimization-2026)
- [Fast.io — AI Agent Token Cost Optimization](https://fast.io/resources/ai-agent-token-cost-optimization/)
