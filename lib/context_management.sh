#!/bin/bash

# lib/context_management.sh — Context management utilities for Ralph
#
# CTXMGMT-1: Progressive context loading
# CTXMGMT-2: Task decomposition signals
#
# CTXMGMT-1 reduces context size per iteration by loading only relevant sections
# of fix_plan.md based on current progress.
# CTXMGMT-2 detects when a task is too large for a single iteration and signals
# Claude to decompose it into smaller sub-tasks.
#
# Research: Success rate drops after 35 min; doubling duration quadruples failure rate.
# Strategy: Start lean, expand context only when needed.
#
# Configuration:
#   RALPH_PROGRESSIVE_CONTEXT=true   — Enable progressive loading (default: false)
#   RALPH_MAX_PLAN_ITEMS=10          — Max unchecked items to include (default: 10)
#   RALPH_CONTEXT_BUDGET_TOKENS=4000 — Soft token budget for injected context (default: 4000)

RALPH_PROGRESSIVE_CONTEXT="${RALPH_PROGRESSIVE_CONTEXT:-false}"
RALPH_MAX_PLAN_ITEMS="${RALPH_MAX_PLAN_ITEMS:-10}"
RALPH_CONTEXT_BUDGET_TOKENS="${RALPH_CONTEXT_BUDGET_TOKENS:-4000}"

# =============================================================================
# CTXMGMT-1: Progressive context loading
# =============================================================================

# ralph_build_progressive_context — Build a focused context payload for this iteration
#
# Reads fix_plan.md, extracts only the CURRENT epic (next unchecked section),
# and trims completed items. Returns a focused subset of the plan.
#
# Usage: focused_plan=$(ralph_build_progressive_context)
#
ralph_build_progressive_context() {
    [[ "$RALPH_PROGRESSIVE_CONTEXT" != "true" ]] && {
        # Passthrough: return full plan if progressive loading disabled
        cat "${RALPH_DIR:-.ralph}/fix_plan.md" 2>/dev/null
        return 0
    }

    local plan_file="${RALPH_DIR:-.ralph}/fix_plan.md"
    [[ ! -f "$plan_file" ]] && return 0

    local plan_content
    plan_content=$(<"$plan_file")

    # Count total items and progress
    local total_items unchecked_items
    total_items=$(echo "$plan_content" | grep -cE '^\s*- \[[xX ]\]' 2>/dev/null) || total_items=0
    unchecked_items=$(echo "$plan_content" | grep -cE '^\s*- \[ \]' 2>/dev/null) || unchecked_items=0

    if [[ $total_items -eq 0 ]]; then
        echo "$plan_content"
        return 0
    fi

    local progress_pct=0
    if [[ $total_items -gt 0 ]]; then
        progress_pct=$(( (total_items - unchecked_items) * 100 / total_items ))
    fi

    # Strategy: Include header + current epic section + next N unchecked items
    # 1. Always include lines before first checkbox (headers, notes)
    # 2. Find the current "active" section (first section containing unchecked items)
    # 3. Trim completed items from previous sections (show only as count)

    local output=""
    local in_active_section=false
    local items_included=0
    local current_section_header=""
    local section_has_unchecked=false
    local pre_checkbox=true
    local completed_sections=0
    local completed_items_in_prior=0

    while IFS= read -r line; do
        # Detect section headers (## lines)
        if [[ "$line" =~ ^##\  ]]; then
            # If we were in an active section and hit a new header, check if we should stop
            if [[ "$in_active_section" == "true" && $items_included -ge $RALPH_MAX_PLAN_ITEMS ]]; then
                output+="
... ($unchecked_items remaining items in later sections)
"
                break
            fi

            # Start tracking new section
            current_section_header="$line"
            section_has_unchecked=false
            pre_checkbox=false

            # Check if this section has unchecked items (lookahead would be complex, just include header)
            output+="$line
"
            continue
        fi

        # Pre-checkbox content (title, notes) — always include
        if [[ "$pre_checkbox" == "true" ]]; then
            output+="$line
"
            continue
        fi

        # Completed items in non-active sections — summarize
        if [[ "$line" =~ ^[[:space:]]*-\ \[[xX]\] ]] && [[ "$in_active_section" != "true" ]]; then
            completed_items_in_prior=$((completed_items_in_prior + 1))
            continue
        fi

        # Unchecked item — this section is active
        if [[ "$line" =~ ^[[:space:]]*-\ \[\ \] ]]; then
            if [[ "$in_active_section" != "true" && $completed_items_in_prior -gt 0 ]]; then
                output+="($completed_items_in_prior completed items above)
"
                completed_items_in_prior=0
            fi
            in_active_section=true
            items_included=$((items_included + 1))

            if [[ $items_included -le $RALPH_MAX_PLAN_ITEMS ]]; then
                output+="$line
"
            fi
            continue
        fi

        # Other lines in active section — include
        if [[ "$in_active_section" == "true" ]]; then
            output+="$line
"
        fi
    done <<< "$plan_content"

    # If there were trailing completed items
    if [[ $completed_items_in_prior -gt 0 && "$in_active_section" != "true" ]]; then
        output+="($completed_items_in_prior completed items)
"
    fi

    echo "$output"
}

# ralph_estimate_context_tokens — Rough token estimate for a text string
#
# Uses 4 chars ≈ 1 token heuristic (good enough for budget enforcement).
#
ralph_estimate_context_tokens() {
    local text="${1:-}"
    local char_count=${#text}
    echo $(( char_count / 4 ))
}

# ralph_get_iteration_context_summary — Return a JSON summary of context state
#
# Used by on-session-start.sh hook to inject minimal context.
#
ralph_get_iteration_context_summary() {
    local plan_file="${RALPH_DIR:-.ralph}/fix_plan.md"

    local total=0 done=0 remaining=0
    if [[ -f "$plan_file" ]]; then
        total=$(grep -cE '^\s*- \[[xX ]\]' "$plan_file" 2>/dev/null) || total=0
        done=$(grep -cE '^\s*- \[[xX]\]' "$plan_file" 2>/dev/null) || done=0
        remaining=$((total - done))
    fi

    local current_section=""
    if [[ -f "$plan_file" ]]; then
        # Find the section containing the first unchecked item
        current_section=$(awk '/^## /{section=$0} /^[[:space:]]*- \[ \]/{print section; exit}' "$plan_file" 2>/dev/null | sed 's/^## //')
    fi

    printf '{"total_tasks":%d,"completed":%d,"remaining":%d,"current_section":"%s","progressive_loading":%s}' \
        "$total" "$done" "$remaining" \
        "$(echo "$current_section" | sed 's/"/\\"/g')" \
        "$RALPH_PROGRESSIVE_CONTEXT"
}

# =============================================================================
# CTXMGMT-2: Task decomposition signals
# =============================================================================

# ralph_detect_decomposition_needed — Check if current task needs decomposition
#
# Heuristics:
# 1. Task text mentions 5+ files
# 2. Previous iteration timed out on this task
# 3. Task has complexity >= COMPLEX (4) from complexity classifier
# 4. Consecutive loops without progress on same task
#
# Returns: 0 if decomposition recommended, 1 otherwise
# Outputs: JSON with reason and recommendation
#
ralph_detect_decomposition_needed() {
    local task_text="${1:-}"
    local loop_count="${2:-0}"

    local reasons=()
    local should_decompose=false

    # 1. File count heuristic
    local file_count
    file_count=$(echo "$task_text" | grep -oiE '[a-zA-Z0-9_/.-]+\.(py|js|ts|sh|go|rs|java|rb|c|cpp|h)' | sort -u | wc -l)
    file_count=$(echo "$file_count" | tr -d '[:space:]')
    if [[ "$file_count" -ge 5 ]]; then
        reasons+=("mentions $file_count files")
        should_decompose=true
    fi

    # 2. Check for timeout on previous iteration
    local status_file="${RALPH_DIR:-.ralph}/status.json"
    if [[ -f "$status_file" ]]; then
        local prev_exit_code
        prev_exit_code=$(jq -r '.exit_code // 0' "$status_file" 2>/dev/null || echo "0")
        if [[ "$prev_exit_code" == "124" ]]; then
            reasons+=("previous iteration timed out")
            should_decompose=true
        fi
    fi

    # 3. Complexity check (if complexity.sh is loaded)
    # Note: ralph_classify_task_complexity uses 'return $score' so exit code = score (non-zero).
    # We must capture stdout before the || fallback overwrites it.
    if declare -f ralph_classify_task_complexity &>/dev/null; then
        local complexity=3
        complexity=$(ralph_classify_task_complexity "$task_text" 2>/dev/null) || true
        if [[ "$complexity" -ge 4 ]]; then
            reasons+=("complexity=$(ralph_complexity_name "$complexity" 2>/dev/null || echo "HIGH")")
            should_decompose=true
        fi
    fi

    # 4. No progress detection (3+ loops without files_modified > 0 on same section)
    if [[ -f "$status_file" ]]; then
        local consecutive_no_progress
        consecutive_no_progress=$(jq -r '.consecutive_no_progress // 0' "$status_file" 2>/dev/null || echo "0")
        if [[ "$consecutive_no_progress" -ge 3 ]]; then
            reasons+=("$consecutive_no_progress loops without progress")
            should_decompose=true
        fi
    fi

    if [[ "$should_decompose" == "true" ]]; then
        local reason_str
        reason_str=$(printf '%s, ' "${reasons[@]}")
        reason_str="${reason_str%, }"
        printf '{"decompose":true,"reasons":"%s","recommendation":"Break this task into smaller sub-tasks of 1-3 files each"}' "$reason_str"
        return 0
    else
        printf '{"decompose":false,"reasons":"","recommendation":""}'
        return 1
    fi
}

# ralph_inject_decomposition_hint — Add decomposition guidance to prompt context
#
# Called by on-session-start hook when decomposition is detected.
# Returns text to append to the session context.
#
ralph_inject_decomposition_hint() {
    local detection_json="${1:-}"

    if [[ -z "$detection_json" ]]; then
        return 0
    fi

    local should_decompose
    should_decompose=$(echo "$detection_json" | jq -r '.decompose // false' 2>/dev/null)

    if [[ "$should_decompose" != "true" ]]; then
        return 0
    fi

    local reasons
    reasons=$(echo "$detection_json" | jq -r '.reasons // ""' 2>/dev/null)

    cat <<EOF

TASK DECOMPOSITION RECOMMENDED
The current task appears too large for a single iteration.
Reasons: $reasons

Instead of attempting the full task:
1. Break it into 2-4 sub-tasks, each touching 1-3 files
2. Update fix_plan.md with the sub-tasks (as indented checkboxes under the parent)
3. Complete only the FIRST sub-task this iteration
4. Set EXIT_SIGNAL: false (more work remains)

This improves success rate and keeps context manageable.
EOF
}
