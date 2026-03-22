# Story CTXMGMT-1: Progressive Context Loading Strategy

**Epic:** [Context Window Management](epic-context-management.md)
**Priority:** High
**Status:** Open
**Effort:** Medium
**Component:** `.claude/agents/ralph.md`, `.claude/hooks/on-session-start.sh`, `ralph_loop.sh`

---

## Problem

Ralph loads all available context into the prompt without prioritization. As sessions progress, the context fills with exploration results, tool outputs, and conversation history. Quality degrades as the model attends to increasingly diluted context.

## Solution

Structure context loading in priority layers. Higher-priority information goes first (stable prefix), lower-priority information fills remaining space. The agent definition documents the loading order so Claude organizes its attention appropriately.

## Implementation

### Context Loading Order

```
Layer 1 — Identity (always, ~2K tokens)
├── Agent definition (ralph.md)
├── Tool restrictions (disallowedTools)
└── Safety rules (file protection, command validation)

Layer 2 — Project Facts (always, ~500 tokens)
├── Project index (from AGENTMEM-2)
├── AGENT.md (build/run instructions)
└── Key conventions

Layer 3 — Task Context (always, ~1-3K tokens)
├── Current fix_plan.md section (unchecked tasks only)
├── PROMPT.md (development instructions)
└── Current task description

Layer 4 — Memory (if enabled, ~500 tokens)
├── Relevant episodic memories (from AGENTMEM-1)
└── Recent error context

Layer 5 — Conversation History (managed by Claude Code)
├── Last 4 turns preserved verbatim
├── Earlier turns auto-compressed
└── First 3 turns preserved (original instructions)
```

### Implementation in on-session-start.sh

```bash
ralph_build_context() {
    local context=""

    # Layer 2: Project facts (Layer 1 is agent definition, auto-loaded)
    if [[ -f "${RALPH_MEMORY_DIR}/project_index.json" ]]; then
        context+="## Project\n$(jq -r '...' "${RALPH_MEMORY_DIR}/project_index.json")\n\n"
    fi

    # Layer 3: Current task context
    context+="## Current Work\n"
    context+="$(ralph_get_current_section)\n\n"

    # Layer 4: Relevant memories
    if [[ "${RALPH_MEMORY_ENABLED:-true}" == "true" ]]; then
        local memories
        memories=$(ralph_get_relevant_episodes "$(ralph_get_current_task)" 5)
        if [[ -n "$memories" ]]; then
            context+="## Prior Session Notes\n$memories\n\n"
        fi
    fi

    # Layer 5: Dynamic context (loop state)
    context+="## Iteration\nLoop: $LOOP_COUNT\n"
    context+="$(ralph_get_rate_limit_status)\n"

    echo -e "$context"
}
```

## Design Notes

- **Claude Code handles Layer 5**: The CLI's built-in context compression manages conversation history. Ralph doesn't need to implement this.
- **Layers are additive**: If memory is disabled, Layers 1-3+5 still provide full functionality.
- **Budget**: Total injected context (Layers 2-4) is ~1-4K tokens — well within budget.
- **SparkCo recommendation**: "Preserve first 3 and last 4 turns" — this is Claude Code's default compression behavior.

## Acceptance Criteria

- [ ] Context loaded in documented priority order
- [ ] Each layer's token budget is bounded
- [ ] Missing layers (e.g., memory disabled) don't break context loading
- [ ] Agent definition documents the loading strategy for Claude's awareness

## References

- [SparkCo — Agent Context Windows in 2026](https://sparkco.ai/blog/agent-context-windows-in-2026-how-to-stop-your-ai-from-forgetting-everything)
- [Factory.ai — The Context Window Problem](https://factory.ai/news/context-window-problem)
