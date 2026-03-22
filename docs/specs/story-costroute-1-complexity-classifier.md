# Story COSTROUTE-1: Task Complexity Classifier

**Epic:** [Cost-Aware Model Routing](epic-cost-aware-routing.md)
**Priority:** High
**Status:** Open
**Effort:** Medium
**Component:** `ralph_loop.sh`, new `lib/complexity.sh`

---

## Problem

Ralph selects models statically: Sonnet for all main-agent work, regardless of whether the task is "fix a typo in README" or "refactor the authentication module across 12 files." This one-size-fits-all approach wastes money on trivial tasks and may produce suboptimal results on complex ones.

## Solution

Create a task complexity classifier that analyzes fix_plan.md task text and contextual signals to produce a complexity score (TRIVIAL, SIMPLE, ROUTINE, COMPLEX, ARCHITECTURAL) without requiring an LLM call.

## Implementation

### Step 1: Create `lib/complexity.sh`

```bash
# lib/complexity.sh — Task complexity classification

# Complexity levels (maps to model tiers)
COMPLEXITY_TRIVIAL=1    # Haiku
COMPLEXITY_SIMPLE=2     # Haiku
COMPLEXITY_ROUTINE=3    # Sonnet
COMPLEXITY_COMPLEX=4    # Sonnet (high effort)
COMPLEXITY_ARCHITECTURAL=5  # Opus

ralph_classify_task_complexity() {
    local task_text="$1"
    local score=0

    # Signal 1: Task size annotation (highest priority)
    case "$task_text" in
        *"[TRIVIAL]"*|*"Trivial"*) return $COMPLEXITY_TRIVIAL ;;
        *"[SMALL]"*) score=$((score + 1)) ;;
        *"[MEDIUM]"*) score=$((score + 2)) ;;
        *"[LARGE]"*) score=$((score + 4)) ;;
    esac

    # Signal 2: Complexity keywords
    local low_keywords="rename|typo|version|bump|comment|delete|remove unused|update import|fix lint"
    local high_keywords="refactor|architect|design|migrate|rewrite|security|performance|integrate|implement.*system"

    if echo "$task_text" | grep -qiE "$low_keywords"; then
        score=$((score - 1))
    fi
    if echo "$task_text" | grep -qiE "$high_keywords"; then
        score=$((score + 2))
    fi

    # Signal 3: File count heuristic (count paths mentioned in task text)
    local file_count
    file_count=$(echo "$task_text" | grep -oE '[a-zA-Z0-9_/]+\.[a-z]{1,4}' | sort -u | wc -l)
    if [[ "$file_count" -ge 5 ]]; then
        score=$((score + 2))
    elif [[ "$file_count" -ge 3 ]]; then
        score=$((score + 1))
    fi

    # Signal 4: Multi-step indicators
    if echo "$task_text" | grep -qiE "and|then|also|across|all|every|each"; then
        score=$((score + 1))
    fi

    # Map score to complexity level
    if [[ "$score" -le 0 ]]; then
        return $COMPLEXITY_TRIVIAL
    elif [[ "$score" -le 1 ]]; then
        return $COMPLEXITY_SIMPLE
    elif [[ "$score" -le 3 ]]; then
        return $COMPLEXITY_ROUTINE
    elif [[ "$score" -le 5 ]]; then
        return $COMPLEXITY_COMPLEX
    else
        return $COMPLEXITY_ARCHITECTURAL
    fi
}

ralph_complexity_to_string() {
    case "$1" in
        1) echo "TRIVIAL" ;;
        2) echo "SIMPLE" ;;
        3) echo "ROUTINE" ;;
        4) echo "COMPLEX" ;;
        5) echo "ARCHITECTURAL" ;;
        *) echo "ROUTINE" ;;
    esac
}
```

### Step 2: Add retry-based complexity escalation

```bash
# If a task has been retried, escalate complexity
ralph_adjust_complexity_for_retries() {
    local base_complexity="$1"
    local retry_count="$2"

    if [[ "$retry_count" -ge 3 ]]; then
        # 3+ retries → escalate by 2 levels
        echo $(( base_complexity + 2 > 5 ? 5 : base_complexity + 2 ))
    elif [[ "$retry_count" -ge 1 ]]; then
        # 1-2 retries → escalate by 1 level
        echo $(( base_complexity + 1 > 5 ? 5 : base_complexity + 1 ))
    else
        echo "$base_complexity"
    fi
}
```

## Design Notes

- **No LLM call for classification**: Classification uses regex/heuristics only. An LLM call for classification would cost more than the routing saves on most tasks.
- **Return code as complexity**: Bash functions return exit codes 1-5 for complexity levels. Clean, efficient, no stdout parsing needed.
- **Task size annotations are authoritative**: If the user wrote `[LARGE]`, respect that regardless of keyword analysis.
- **Retry escalation**: A task that keeps failing at Sonnet should be escalated to Opus. This prevents stuck loops where the model isn't capable enough.
- **Conservative defaults**: Unknown tasks default to ROUTINE (Sonnet). We only downgrade to Haiku when confident, and only upgrade to Opus when strong signals are present.

## Acceptance Criteria

- [ ] Task text classified into 5 complexity levels without LLM call
- [ ] Size annotations (`[TRIVIAL]`, `[SMALL]`, `[MEDIUM]`, `[LARGE]`) are respected
- [ ] Complexity keywords influence classification
- [ ] File count heuristic contributes to score
- [ ] Retry count escalates complexity
- [ ] Classification logged for debugging

## Test Plan

```bash
@test "classify trivial task" {
    source "$RALPH_DIR/lib/complexity.sh"
    ralph_classify_task_complexity "Fix typo in README.md"
    assert_equal "$?" "$COMPLEXITY_TRIVIAL"
}

@test "classify complex task" {
    source "$RALPH_DIR/lib/complexity.sh"
    ralph_classify_task_complexity "[LARGE] Refactor authentication module across auth.py, middleware.py, views.py, models.py, and tests/"
    assert_equal "$?" "$COMPLEXITY_ARCHITECTURAL"
}

@test "classify routine task" {
    source "$RALPH_DIR/lib/complexity.sh"
    ralph_classify_task_complexity "[MEDIUM] Add error handling to API endpoint"
    assert_equal "$?" "$COMPLEXITY_ROUTINE"
}

@test "size annotation overrides keywords" {
    source "$RALPH_DIR/lib/complexity.sh"
    ralph_classify_task_complexity "[TRIVIAL] Rename variable in auth module"
    assert_equal "$?" "$COMPLEXITY_TRIVIAL"
}

@test "retry escalation works" {
    source "$RALPH_DIR/lib/complexity.sh"
    local result
    result=$(ralph_adjust_complexity_for_retries "$COMPLEXITY_ROUTINE" 3)
    assert_equal "$result" "$COMPLEXITY_ARCHITECTURAL"
}
```

## References

- [Amazon Bedrock — Intelligent Prompt Routing](https://aws.amazon.com/bedrock/intelligent-prompt-routing/)
- [oFox — How to Reduce AI API Costs](https://ofox.ai/blog/how-to-reduce-ai-api-costs-2026/)
