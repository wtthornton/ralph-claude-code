# Story AGENTMEM-1: Episodic Memory Store

**Epic:** [Cross-Session Agent Memory](epic-agent-memory.md)
**Priority:** Medium
**Status:** Open
**Effort:** Medium
**Component:** new `.ralph/memory/episodes.jsonl`, `ralph_loop.sh`, `.claude/hooks/on-stop.sh`

---

## Problem

Ralph repeats failed approaches across sessions. If a task failed because of a specific pattern (e.g., "renaming X broke import Y"), the next session has no knowledge of this and may attempt the same approach.

## Solution

After each loop iteration, record a brief episodic memory entry: what was attempted, whether it succeeded or failed, and key context. Inject the most relevant episodes into the agent's context at session start.

## Implementation

### Step 1: Record episodes after each iteration

```bash
RALPH_MEMORY_DIR="${RALPH_DIR}/memory"
RALPH_EPISODES_FILE="${RALPH_MEMORY_DIR}/episodes.jsonl"
RALPH_MAX_EPISODES=${RALPH_MAX_EPISODES:-100}

ralph_record_episode() {
    local task="$1" outcome="$2" work_type="$3"
    local files_changed="$4" error_summary="$5"

    mkdir -p "$RALPH_MEMORY_DIR"

    jq -n -c \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg task "$task" \
        --arg outcome "$outcome" \
        --arg work_type "$work_type" \
        --arg files "$files_changed" \
        --arg error "$error_summary" \
        --arg loop "$LOOP_COUNT" \
        '{
            timestamp: $ts,
            task: $task,
            outcome: $outcome,
            work_type: $work_type,
            files_changed: $files,
            error_summary: $error,
            loop_count: ($loop | tonumber)
        }' >> "$RALPH_EPISODES_FILE"

    # Bound file size
    local count
    count=$(wc -l < "$RALPH_EPISODES_FILE" 2>/dev/null || echo "0")
    if [[ "$count" -gt "$RALPH_MAX_EPISODES" ]]; then
        tail -"$RALPH_MAX_EPISODES" "$RALPH_EPISODES_FILE" > "${RALPH_EPISODES_FILE}.tmp"
        mv "${RALPH_EPISODES_FILE}.tmp" "$RALPH_EPISODES_FILE"
    fi
}
```

### Step 2: Retrieve relevant episodes for current task

```bash
ralph_get_relevant_episodes() {
    local current_task="$1" max_results="${2:-5}"

    [[ ! -f "$RALPH_EPISODES_FILE" ]] && return 0

    # Extract key terms from current task
    local terms
    terms=$(echo "$current_task" | tr '[:upper:]' '[:lower:]' | grep -oE '[a-z_]+\.[a-z]+|[a-z]{4,}' | sort -u | head -10)

    # Score episodes by term overlap and recency
    local result=""
    while IFS= read -r line; do
        local task_lower
        task_lower=$(echo "$line" | jq -r '.task' | tr '[:upper:]' '[:lower:]')
        local score=0
        for term in $terms; do
            echo "$task_lower" | grep -q "$term" && score=$((score + 1))
        done
        # Boost failed episodes (more important to remember)
        local outcome
        outcome=$(echo "$line" | jq -r '.outcome')
        [[ "$outcome" == "failure" ]] && score=$((score + 2))

        if [[ "$score" -gt 0 ]]; then
            result="${result}${score}\t${line}\n"
        fi
    done < "$RALPH_EPISODES_FILE"

    # Return top N by score
    echo -e "$result" | sort -rn | head -"$max_results" | cut -f2-
}
```

### Step 3: Inject episodes into session context

```bash
# In on-session-start.sh:
ralph_inject_memory() {
    local current_task="$1"
    local episodes
    episodes=$(ralph_get_relevant_episodes "$current_task" 5)

    if [[ -n "$episodes" ]]; then
        echo "## Prior Session Context"
        echo "Relevant observations from previous sessions:"
        echo "$episodes" | while IFS= read -r ep; do
            local task outcome error
            task=$(echo "$ep" | jq -r '.task')
            outcome=$(echo "$ep" | jq -r '.outcome')
            error=$(echo "$ep" | jq -r '.error_summary // "none"')
            echo "- [${outcome}] ${task}"
            [[ "$error" != "none" && "$error" != "null" ]] && echo "  Note: ${error}"
        done
    fi
}
```

## Design Notes

- **JSONL append-only**: Simple, fast, no database required. Bounded to 100 entries.
- **Term-based relevance**: Lightweight keyword matching without LLM. Good enough for file-name and module-name overlap.
- **Failure bias**: Failed episodes scored higher because they're more important to avoid repeating.
- **5 episodes injected**: Minimal context cost (~500 tokens) with high information density.
- **Project-scoped**: Episodes stored in `.ralph/memory/` within each project, not globally.

## Acceptance Criteria

- [ ] Episode recorded after each loop iteration (task, outcome, files, errors)
- [ ] Relevant episodes retrieved based on current task similarity
- [ ] Top 5 episodes injected into session context
- [ ] Failed episodes prioritized over successful ones
- [ ] Episode file bounded to configurable max entries
- [ ] Episodes are project-scoped

## Test Plan

```bash
@test "ralph_record_episode writes valid JSONL" {
    source "$RALPH_DIR/lib/memory.sh"  # or wherever this lives
    RALPH_MEMORY_DIR="$TEST_DIR/memory"
    RALPH_EPISODES_FILE="$RALPH_MEMORY_DIR/episodes.jsonl"
    LOOP_COUNT=1

    ralph_record_episode "Fix auth.py" "success" "IMPLEMENTATION" "auth.py" ""

    assert [ -f "$RALPH_EPISODES_FILE" ]
    jq -e '.task == "Fix auth.py"' "$RALPH_EPISODES_FILE"
}

@test "ralph_record_episode bounds file size" {
    source "$RALPH_DIR/lib/memory.sh"
    RALPH_MEMORY_DIR="$TEST_DIR/memory"
    RALPH_EPISODES_FILE="$RALPH_MEMORY_DIR/episodes.jsonl"
    RALPH_MAX_EPISODES=5
    LOOP_COUNT=1

    for i in $(seq 1 10); do
        ralph_record_episode "Task $i" "success" "IMPL" "file$i.py" ""
    done

    local count
    count=$(wc -l < "$RALPH_EPISODES_FILE" | tr -d ' ')
    assert [ "$count" -le 5 ]
}
```

## References

- [IBM — What Is AI Agent Memory?](https://www.ibm.com/think/topics/ai-agent-memory)
- [Machine Learning Mastery — 3 Types of Long-term Memory AI Agents Need](https://machinelearningmastery.com/beyond-short-term-memory-the-3-types-of-long-term-memory-ai-agents-need/)
- [Mem0 — AI Agent Memory Framework](https://github.com/mem0ai/mem0)
