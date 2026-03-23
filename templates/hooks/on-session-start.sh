#!/bin/bash
# .ralph/hooks/on-session-start.sh
# Replaces: build_loop_context() in ralph_loop.sh
#
# SessionStart hook. Reads loop state and emits context for Claude's system prompt.
# Exit 0 = allow session. stderr = inject into context.

set -euo pipefail

RALPH_DIR="${CLAUDE_PROJECT_DIR:-.}/.ralph"

# Guard: only run if this is a Ralph-managed project
if [[ ! -d "$RALPH_DIR" ]]; then
  exit 0
fi

# Read current loop count
loop_count=0
if [[ -f "$RALPH_DIR/status.json" ]]; then
  loop_count=$(jq -r '.loop_count // 0' "$RALPH_DIR/status.json" 2>/dev/null || echo "0")
fi

# Read fix_plan completion status
total_tasks=0
done_tasks=0
if [[ -f "$RALPH_DIR/fix_plan.md" ]]; then
  total_tasks=$(grep -c '^\- \[' "$RALPH_DIR/fix_plan.md" 2>/dev/null) || total_tasks=0
  done_tasks=$(grep -c '^\- \[x\]' "$RALPH_DIR/fix_plan.md" 2>/dev/null) || done_tasks=0
fi
remaining=$((total_tasks - done_tasks))

# Read circuit breaker state
cb_state="CLOSED"
if [[ -f "$RALPH_DIR/.circuit_breaker_state" ]]; then
  cb_state=$(jq -r '.state // "CLOSED"' "$RALPH_DIR/.circuit_breaker_state" 2>/dev/null || echo "CLOSED")
fi

# Read last loop outcome (if available)
last_status=""
if [[ -f "$RALPH_DIR/status.json" ]]; then
  last_status=$(jq -r '.status // ""' "$RALPH_DIR/status.json" 2>/dev/null || echo "")
fi

# Clear per-loop file tracking
: > "$RALPH_DIR/.files_modified_this_loop" 2>/dev/null || true

# Emit context to stderr (injected into Claude's system prompt)
if [[ $total_tasks -gt 0 && $remaining -eq 0 ]]; then
  cat >&2 <<EOF
Ralph loop #$((loop_count + 1)). Tasks: $done_tasks/$total_tasks complete, 0 remaining.
Circuit breaker: $cb_state.$([ -n "$last_status" ] && echo " Last loop: $last_status.")
ALL TASKS COMPLETE. Do NOT run tests, lint, or any verification. Emit your RALPH_STATUS block with STATUS: COMPLETE, TASKS_COMPLETED_THIS_LOOP: 0, TESTS_STATUS: PASSING, EXIT_SIGNAL: true, and STOP immediately.
EOF
else
  cat >&2 <<EOF
Ralph loop #$((loop_count + 1)). Tasks: $done_tasks/$total_tasks complete, $remaining remaining.
Circuit breaker: $cb_state.$([ -n "$last_status" ] && echo " Last loop: $last_status.")
Read .ralph/fix_plan.md and do the FIRST unchecked item. IMPORTANT: Only run tests at epic boundaries (last task in a ## section). Otherwise set TESTS_STATUS: DEFERRED — do NOT run any test commands.
EOF

  # CTXMGMT-2: Check if current task needs decomposition
  if [[ "${RALPH_PROGRESSIVE_CONTEXT:-false}" == "true" ]]; then
    # Source context_management.sh from Ralph's lib directory
    _ctx_lib_loaded=false
    for _lib_path in "$HOME/.ralph/lib/context_management.sh" \
                     "${RALPH_INSTALL_DIR:-/nonexistent}/lib/context_management.sh"; do
      if [[ -f "$_lib_path" ]]; then
        source "$_lib_path"
        _ctx_lib_loaded=true
        break
      fi
    done

    if [[ "$_ctx_lib_loaded" == "true" ]] && declare -f ralph_detect_decomposition_needed &>/dev/null; then
      current_task=$(grep -m1 -E '^\s*- \[ \]' "$RALPH_DIR/fix_plan.md" 2>/dev/null || echo "")
      if [[ -n "$current_task" ]]; then
        decomp_result=$(ralph_detect_decomposition_needed "$current_task" "${loop_count:-0}" 2>/dev/null || echo '{"decompose":false}')
        if echo "$decomp_result" | jq -r '.decompose' 2>/dev/null | grep -q "true"; then
          reasons=$(echo "$decomp_result" | jq -r '.reasons // ""' 2>/dev/null)
          echo "" >&2
          echo "DECOMPOSITION SIGNAL: Current task may be too large ($reasons). Consider breaking into sub-tasks." >&2
        fi
      fi
    fi
  fi
fi

exit 0
