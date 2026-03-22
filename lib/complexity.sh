#!/bin/bash

# lib/complexity.sh — Task complexity classifier + cost-aware model routing (Phase 14)
#
# Classifies tasks into 5 levels without LLM calls (regex/heuristics only).
# Used by COSTROUTE-1 (classifier) and COSTROUTE-2 (dynamic model selection).
#
# Return values: 1=TRIVIAL, 2=SIMPLE, 3=ROUTINE, 4=COMPLEX, 5=ARCHITECTURAL
#
# Configuration:
#   RALPH_MODEL_ROUTING_ENABLED=false  — Enable dynamic model selection (default: false)
#   RALPH_MODEL_TRIVIAL=haiku          — Model for trivial/simple tasks
#   RALPH_MODEL_ROUTINE=sonnet         — Model for routine tasks (default)
#   RALPH_MODEL_COMPLEX=sonnet         — Model for complex tasks
#   RALPH_MODEL_ARCH=opus              — Model for architectural tasks
#   RALPH_DEFAULT_MODEL=sonnet         — Fallback model

RALPH_MODEL_ROUTING_ENABLED="${RALPH_MODEL_ROUTING_ENABLED:-false}"
RALPH_MODEL_TRIVIAL="${RALPH_MODEL_TRIVIAL:-haiku}"
RALPH_MODEL_ROUTINE="${RALPH_MODEL_ROUTINE:-sonnet}"
RALPH_MODEL_COMPLEX="${RALPH_MODEL_COMPLEX:-sonnet}"
RALPH_MODEL_ARCH="${RALPH_MODEL_ARCH:-opus}"
RALPH_DEFAULT_MODEL="${RALPH_DEFAULT_MODEL:-sonnet}"

# ralph_classify_task_complexity — Classify a task into 5 complexity levels
#
# Usage: ralph_classify_task_complexity "task description"
# Returns: 1 (TRIVIAL), 2 (SIMPLE), 3 (ROUTINE), 4 (COMPLEX), 5 (ARCHITECTURAL)
#
# Priority order:
# 1. Explicit size annotations [TRIVIAL], [SMALL], [MEDIUM], [LARGE], [ARCH]
# 2. Retry escalation (3+ retries → +2, 1-2 retries → +1)
# 3. Keyword analysis (architectural terms score higher)
# 4. File count heuristic (5+ files → COMPLEX)
# 5. Default: ROUTINE (3)
#
ralph_classify_task_complexity() {
    local task_text="${1:-}"
    local retry_count="${2:-0}"
    local score=3  # Default: ROUTINE

    # 1. Explicit size annotations (highest priority)
    if echo "$task_text" | grep -qiE '\[TRIVIAL\]'; then
        score=1
        _complexity_debug "Annotation: TRIVIAL"
        echo "$score"
        return "$score"
    elif echo "$task_text" | grep -qiE '\[SMALL\]'; then
        score=2
        _complexity_debug "Annotation: SMALL"
        echo "$score"
        return "$score"
    elif echo "$task_text" | grep -qiE '\[MEDIUM\]'; then
        score=3
        _complexity_debug "Annotation: MEDIUM"
        echo "$score"
        return "$score"
    elif echo "$task_text" | grep -qiE '\[LARGE\]'; then
        score=4
        _complexity_debug "Annotation: LARGE"
        echo "$score"
        return "$score"
    elif echo "$task_text" | grep -qiE '\[ARCH\]|\[ARCHITECTURAL\]'; then
        score=5
        _complexity_debug "Annotation: ARCHITECTURAL"
        echo "$score"
        return "$score"
    fi

    # 2. Keyword analysis
    local keyword_score=0

    # High-complexity keywords (+2)
    if echo "$task_text" | grep -qiE 'architect|redesign|migrate|rewrite|overhaul|platform'; then
        keyword_score=$((keyword_score + 2))
        _complexity_debug "High-complexity keyword detected"
    fi

    # Medium-complexity keywords (+1)
    if echo "$task_text" | grep -qiE 'refactor|integrate|implement|convert|restructure'; then
        keyword_score=$((keyword_score + 1))
        _complexity_debug "Medium-complexity keyword detected"
    fi

    # Low-complexity keywords (-1)
    if echo "$task_text" | grep -qiE 'typo|comment|rename|bump|version|trivial|simple fix'; then
        keyword_score=$((keyword_score - 1))
        _complexity_debug "Low-complexity keyword detected"
    fi

    score=$((score + keyword_score))

    # 3. File count heuristic
    local file_count
    file_count=$(echo "$task_text" | grep -oiE '[a-zA-Z0-9_/.-]+\.(py|js|ts|sh|go|rs|java|rb|c|cpp|h)' | sort -u | wc -l)
    if [[ "$file_count" -ge 10 ]]; then
        score=$((score + 2))
        _complexity_debug "File count: $file_count (10+ files → +2)"
    elif [[ "$file_count" -ge 5 ]]; then
        score=$((score + 1))
        _complexity_debug "File count: $file_count (5+ files → +1)"
    fi

    # 4. Multi-step indicators
    local step_count
    step_count=$(echo "$task_text" | grep -ciE '^\s*[-*]\s*\[.\]|step [0-9]|phase [0-9]|then |after that')
    if [[ "$step_count" -ge 5 ]]; then
        score=$((score + 1))
        _complexity_debug "Multi-step: $step_count steps detected"
    fi

    # 5. Retry escalation
    if [[ "$retry_count" -ge 3 ]]; then
        score=$((score + 2))
        _complexity_debug "Retry escalation: $retry_count retries → +2"
    elif [[ "$retry_count" -ge 1 ]]; then
        score=$((score + 1))
        _complexity_debug "Retry escalation: $retry_count retries → +1"
    fi

    # Clamp to 1-5 range
    [[ "$score" -lt 1 ]] && score=1
    [[ "$score" -gt 5 ]] && score=5

    _complexity_debug "Final score: $score"
    echo "$score"
    return "$score"
}

# ralph_complexity_name — Convert numeric score to name
#
ralph_complexity_name() {
    case "${1:-3}" in
        1) echo "TRIVIAL" ;;
        2) echo "SIMPLE" ;;
        3) echo "ROUTINE" ;;
        4) echo "COMPLEX" ;;
        5) echo "ARCHITECTURAL" ;;
        *) echo "ROUTINE" ;;
    esac
}

# ralph_select_model — Select model based on complexity
#
# Usage: model=$(ralph_select_model "task text" retry_count)
#
# Returns model name string. If RALPH_MODEL_ROUTING_ENABLED=false,
# always returns RALPH_DEFAULT_MODEL.
#
ralph_select_model() {
    local task_text="${1:-}"
    local retry_count="${2:-0}"

    if [[ "$RALPH_MODEL_ROUTING_ENABLED" != "true" ]]; then
        echo "$RALPH_DEFAULT_MODEL"
        return 0
    fi

    local complexity
    complexity=$(ralph_classify_task_complexity "$task_text" "$retry_count")

    local model
    case "$complexity" in
        1|2) model="$RALPH_MODEL_TRIVIAL" ;;
        3)   model="$RALPH_MODEL_ROUTINE" ;;
        4)   model="$RALPH_MODEL_COMPLEX" ;;
        5)   model="$RALPH_MODEL_ARCH" ;;
        *)   model="$RALPH_DEFAULT_MODEL" ;;
    esac

    # Log routing decision
    local routing_log="${RALPH_DIR:-.ralph}/.model_routing.jsonl"
    if command -v jq &>/dev/null; then
        local routing_entry
        routing_entry=$(jq -n \
            --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
            --arg complexity "$(ralph_complexity_name "$complexity")" \
            --arg model "$model" \
            --arg retry "$retry_count" \
            '{timestamp: $ts, complexity: $complexity, model: $model, retry_count: ($retry | tonumber)}')
        echo "$routing_entry" >> "$routing_log" 2>/dev/null
    fi

    echo "$model"
}

# _complexity_debug — Internal debug logging
#
_complexity_debug() {
    if [[ "${RALPH_VERBOSE:-false}" == "true" ]] || [[ "${RALPH_DEBUG:-false}" == "true" ]]; then
        echo "[complexity] $*" >&2
    fi
}
