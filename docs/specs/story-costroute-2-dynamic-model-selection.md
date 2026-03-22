# Story COSTROUTE-2: Dynamic Model Selection Based on Complexity

**Epic:** [Cost-Aware Model Routing](epic-cost-aware-routing.md)
**Priority:** High
**Status:** Open
**Effort:** Medium
**Component:** `ralph_loop.sh`, `lib/complexity.sh`, `.claude/agents/ralph.md`

---

## Problem

After COSTROUTE-1 classifies task complexity, Ralph needs to select the appropriate model. Currently, model selection is hardcoded in agent definitions and `build_claude_command()`.

## Solution

Map complexity levels to model tiers and dynamically override the model via `--model` CLI flag or agent configuration.

## Implementation

### Step 1: Model routing table

```bash
# In lib/complexity.sh:
RALPH_MODEL_ROUTING_ENABLED=${RALPH_MODEL_ROUTING_ENABLED:-false}

ralph_select_model() {
    local complexity="$1"

    if [[ "$RALPH_MODEL_ROUTING_ENABLED" != "true" ]]; then
        echo "${RALPH_DEFAULT_MODEL:-sonnet}"
        return
    fi

    case "$complexity" in
        1|2) echo "${RALPH_MODEL_TRIVIAL:-haiku}" ;;    # TRIVIAL, SIMPLE
        3)   echo "${RALPH_MODEL_ROUTINE:-sonnet}" ;;    # ROUTINE
        4)   echo "${RALPH_MODEL_COMPLEX:-sonnet}" ;;    # COMPLEX
        5)   echo "${RALPH_MODEL_ARCH:-opus}" ;;         # ARCHITECTURAL
        *)   echo "${RALPH_DEFAULT_MODEL:-sonnet}" ;;
    esac
}
```

### Step 2: Integrate with build_claude_command()

```bash
# In ralph_loop.sh, before invoking Claude:
local task_text complexity model_tier
task_text=$(ralph_get_current_task)
ralph_classify_task_complexity "$task_text"
complexity=$?
complexity=$(ralph_adjust_complexity_for_retries "$complexity" "$RETRY_COUNT")
model_tier=$(ralph_select_model "$complexity")

log "INFO" "Task complexity: $(ralph_complexity_to_string $complexity) → Model: $model_tier"

# Add --model flag to Claude command
CLAUDE_CMD="$CLAUDE_CMD --model $model_tier"
```

### Step 3: Configuration

```bash
# In .ralphrc template:
# RALPH_MODEL_ROUTING_ENABLED=false   # Enable dynamic model routing
# RALPH_MODEL_TRIVIAL=haiku           # Model for TRIVIAL/SIMPLE tasks
# RALPH_MODEL_ROUTINE=sonnet          # Model for ROUTINE tasks
# RALPH_MODEL_COMPLEX=sonnet          # Model for COMPLEX tasks
# RALPH_MODEL_ARCH=opus               # Model for ARCHITECTURAL tasks
# RALPH_DEFAULT_MODEL=sonnet          # Fallback model
```

### Step 4: Log routing decisions for analysis

```bash
ralph_log_routing_decision() {
    local task="$1" complexity="$2" model="$3" retry_count="$4"
    local routing_log="${RALPH_DIR}/.model_routing.jsonl"

    jq -n -c \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg task "$task" \
        --arg complexity "$(ralph_complexity_to_string $complexity)" \
        --arg model "$model" \
        --argjson retries "$retry_count" \
        '{timestamp: $ts, task: $task, complexity: $complexity, model: $model, retries: $retries}' \
        >> "$routing_log"
}
```

## Design Notes

- **Disabled by default**: `RALPH_MODEL_ROUTING_ENABLED=false` preserves existing static behavior. Users opt-in when ready.
- **Per-tier model overrides**: Users can customize which model handles each tier. A team might use Opus for COMPLEX tasks if they value quality over cost.
- **Routing log**: JSONL log enables post-hoc analysis of routing decisions vs. outcomes. Useful for tuning the classifier.
- **--model flag**: Claude Code CLI accepts `--model` to override the agent definition's model. This is the least-invasive integration point.

## Acceptance Criteria

- [ ] Model dynamically selected based on task complexity
- [ ] Per-tier model mapping configurable via `.ralphrc`
- [ ] Routing decisions logged to `.model_routing.jsonl`
- [ ] `RALPH_MODEL_ROUTING_ENABLED=false` reverts to static model
- [ ] `--model` override in `.ralphrc` still works (takes precedence)

## Test Plan

```bash
@test "ralph_select_model returns haiku for trivial" {
    source "$RALPH_DIR/lib/complexity.sh"
    RALPH_MODEL_ROUTING_ENABLED="true"
    local model
    model=$(ralph_select_model 1)
    assert_equal "$model" "haiku"
}

@test "ralph_select_model returns sonnet when routing disabled" {
    source "$RALPH_DIR/lib/complexity.sh"
    RALPH_MODEL_ROUTING_ENABLED="false"
    local model
    model=$(ralph_select_model 1)
    assert_equal "$model" "sonnet"
}

@test "ralph_select_model returns opus for architectural" {
    source "$RALPH_DIR/lib/complexity.sh"
    RALPH_MODEL_ROUTING_ENABLED="true"
    local model
    model=$(ralph_select_model 5)
    assert_equal "$model" "opus"
}
```

## References

- [Amazon Bedrock — Intelligent Prompt Routing](https://aws.amazon.com/bedrock/intelligent-prompt-routing/)
- [Fast.io — AI Agent Token Cost Optimization](https://fast.io/resources/ai-agent-token-cost-optimization/)
