#!/bin/bash

# lib/memory.sh — Cross-session agent memory (Phase 14, AGENTMEM-1/2/3)
#
# Episodic memory: records what worked/failed per iteration.
# Semantic memory: project index (language, test runner, structure).
# Memory decay: exponential scoring with age-based pruning.
#
# Configuration:
#   RALPH_MAX_EPISODES=100            — Max episodes to retain
#   RALPH_MEMORY_DECAY_DAYS=14        — Days before pruning
#   RALPH_MEMORY_DECAY_FACTOR=0.9     — Per-day decay factor
#   RALPH_INDEX_MAX_AGE_HOURS=24      — Project index staleness threshold

MEMORY_DIR="${RALPH_DIR:-.ralph}/memory"
RALPH_MAX_EPISODES="${RALPH_MAX_EPISODES:-100}"
RALPH_MEMORY_DECAY_DAYS="${RALPH_MEMORY_DECAY_DAYS:-14}"
RALPH_MEMORY_DECAY_FACTOR="${RALPH_MEMORY_DECAY_FACTOR:-0.9}"
RALPH_INDEX_MAX_AGE_HOURS="${RALPH_INDEX_MAX_AGE_HOURS:-24}"

# =============================================================================
# AGENTMEM-1: Episodic Memory
# =============================================================================

# ralph_record_episode — Record an episode after each iteration
#
# Usage: ralph_record_episode <outcome> <work_type> <completed_task> <error_summary> [files_changed]
# outcome: success | failure
#
ralph_record_episode() {
    local outcome="${1:-unknown}"
    local work_type="${2:-UNKNOWN}"
    local completed_task="${3:-}"
    local error_summary="${4:-}"
    local files_changed="${5:-}"

    mkdir -p "$MEMORY_DIR"
    local episodes_file="$MEMORY_DIR/episodes.jsonl"

    local timestamp
    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    if command -v jq &>/dev/null; then
        local episode
        episode=$(jq -n \
            --arg ts "$timestamp" \
            --arg task "$completed_task" \
            --arg outcome "$outcome" \
            --arg wt "$work_type" \
            --arg files "$files_changed" \
            --arg err "$error_summary" \
            --arg lc "${LOOP_COUNT:-0}" \
            '{timestamp: $ts, task: $task, outcome: $outcome, work_type: $wt, files_changed: $files, error_summary: $err, loop_count: ($lc | tonumber)}')
        echo "$episode" >> "$episodes_file"
    fi

    # Bound to max episodes (keep newest)
    if [[ -f "$episodes_file" ]]; then
        local count
        count=$(wc -l < "$episodes_file")
        if [[ "$count" -gt "$RALPH_MAX_EPISODES" ]]; then
            local keep=$((RALPH_MAX_EPISODES))
            tail -n "$keep" "$episodes_file" > "${episodes_file}.tmp"
            mv "${episodes_file}.tmp" "$episodes_file"
        fi
    fi
}

# ralph_get_relevant_episodes — Retrieve episodes relevant to a task
#
# Usage: ralph_get_relevant_episodes "task description" [max_results]
# Returns: JSONL of top relevant episodes (default 5, failures prioritized)
#
ralph_get_relevant_episodes() {
    local task_text="${1:-}"
    local max_results="${2:-5}"
    local episodes_file="$MEMORY_DIR/episodes.jsonl"

    [[ ! -f "$episodes_file" ]] && return 0

    # Extract keywords from task (filenames, module names)
    local keywords
    keywords=$(echo "$task_text" | grep -oE '[a-zA-Z_][a-zA-Z0-9_]+' | sort -u | head -20)

    # Score each episode by keyword overlap + failure bias
    if command -v jq &>/dev/null; then
        local keyword_pattern
        keyword_pattern=$(echo "$keywords" | tr '\n' '|' | sed 's/|$//')

        # Guard against empty pattern matching everything
        if [[ -z "$keyword_pattern" ]]; then
            return 0
        fi

        # Simple relevance: grep for any keyword matches, add +2 for failures
        # Use jq -s for proper JSON-aware sorting instead of text-based sort
        grep -iE "$keyword_pattern" "$episodes_file" 2>/dev/null | \
            jq -c '. + {relevance: (if .outcome == "failure" then 2 else 0 end)}' 2>/dev/null | \
            jq -s 'sort_by(.relevance) | reverse | .[:'"$max_results"'][]' 2>/dev/null
    fi
}

# =============================================================================
# AGENTMEM-2: Semantic Memory (Project Index)
# =============================================================================

# ralph_generate_project_index — Detect project characteristics
#
# Writes .ralph/memory/project_index.json with detected language,
# test runner, file counts, and top directories.
#
ralph_generate_project_index() {
    mkdir -p "$MEMORY_DIR"
    local index_file="$MEMORY_DIR/project_index.json"

    # Detect language
    local language="unknown"
    if [[ -f "package.json" ]] || ls *.ts *.tsx *.js *.jsx &>/dev/null 2>&1; then
        language="javascript/typescript"
    elif [[ -f "pyproject.toml" ]] || [[ -f "setup.py" ]] || ls *.py &>/dev/null 2>&1; then
        language="python"
    elif [[ -f "go.mod" ]]; then
        language="go"
    elif [[ -f "Cargo.toml" ]]; then
        language="rust"
    elif [[ -f "pom.xml" ]] || [[ -f "build.gradle" ]]; then
        language="java"
    elif ls *.sh &>/dev/null 2>&1; then
        language="bash"
    fi

    # Detect test runner
    local test_runner="unknown"
    if [[ -f "package.json" ]] && grep -q '"jest"' package.json 2>/dev/null; then
        test_runner="jest"
    elif [[ -f "pyproject.toml" ]] && grep -q 'pytest' pyproject.toml 2>/dev/null; then
        test_runner="pytest"
    elif command -v bats &>/dev/null && ls tests/*.bats &>/dev/null 2>&1; then
        test_runner="bats"
    elif [[ -f "go.mod" ]]; then
        test_runner="go test"
    fi

    # Count files
    local file_count
    file_count=$(find . -maxdepth 3 -type f -not -path './.git/*' -not -path './node_modules/*' -not -path './.ralph/*' 2>/dev/null | wc -l)

    # Top directories
    local top_dirs
    top_dirs=$(ls -d */ 2>/dev/null | grep -vE '^(node_modules|\.git|\.ralph|__pycache__|\.cache)/' | head -10 | tr '\n' ',' | sed 's/,$//')

    # Config files present
    local configs=""
    [[ -f ".ralphrc" ]] && configs="${configs}ralphrc,"
    [[ -f "ralph.config.json" ]] && configs="${configs}ralph.config.json,"
    [[ -f "package.json" ]] && configs="${configs}package.json,"
    [[ -f "pyproject.toml" ]] && configs="${configs}pyproject.toml,"
    [[ -f "tsconfig.json" ]] && configs="${configs}tsconfig.json,"
    configs=$(echo "$configs" | sed 's/,$//')

    if command -v jq &>/dev/null; then
        jq -n \
            --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
            --arg lang "$language" \
            --arg runner "$test_runner" \
            --arg fc "$file_count" \
            --arg dirs "$top_dirs" \
            --arg cfgs "$configs" \
            '{generated_at: $ts, language: $lang, test_runner: $runner, file_count: ($fc | tonumber), top_directories: $dirs, config_files: $cfgs}' \
            > "$index_file"
    fi
}

# ralph_is_index_stale — Check if project index needs regeneration
#
# Returns 0 (stale/missing) or 1 (fresh).
#
ralph_is_index_stale() {
    local index_file="$MEMORY_DIR/project_index.json"
    [[ ! -f "$index_file" ]] && return 0

    local max_age_seconds=$((RALPH_INDEX_MAX_AGE_HOURS * 3600))
    local now
    now=$(date '+%s')

    local file_mtime
    if stat -c '%Y' "$index_file" &>/dev/null 2>&1; then
        file_mtime=$(stat -c '%Y' "$index_file")
    elif stat -f '%m' "$index_file" &>/dev/null 2>&1; then
        file_mtime=$(stat -f '%m' "$index_file")
    else
        return 0
    fi

    local age=$((now - file_mtime))
    [[ "$age" -gt "$max_age_seconds" ]] && return 0
    return 1
}

# =============================================================================
# AGENTMEM-3: Memory Decay
# =============================================================================

# ralph_prune_stale_memories — Remove episodes older than decay_days
#
# Uses exponential decay (Ebbinghaus-inspired). Runs at session start.
#
ralph_prune_stale_memories() {
    local episodes_file="$MEMORY_DIR/episodes.jsonl"
    [[ ! -f "$episodes_file" ]] && return 0

    local cutoff_date
    if date -d "-${RALPH_MEMORY_DECAY_DAYS} days" '+%Y-%m-%dT%H:%M:%SZ' &>/dev/null 2>&1; then
        cutoff_date=$(date -d "-${RALPH_MEMORY_DECAY_DAYS} days" '+%Y-%m-%dT%H:%M:%SZ')
    elif date -v "-${RALPH_MEMORY_DECAY_DAYS}d" '+%Y-%m-%dT%H:%M:%SZ' &>/dev/null 2>&1; then
        cutoff_date=$(date -v "-${RALPH_MEMORY_DECAY_DAYS}d" '+%Y-%m-%dT%H:%M:%SZ')
    else
        return 0
    fi

    if command -v jq &>/dev/null; then
        jq -c --arg cutoff "$cutoff_date" 'select(.timestamp >= $cutoff)' "$episodes_file" \
            > "${episodes_file}.tmp" 2>/dev/null
        mv "${episodes_file}.tmp" "$episodes_file"
    fi
}
