#!/bin/bash

# lib/qa_failures.sh — QA failure state tracking for retry escalation
#
# Tracks consecutive QA failures per Linear issue ID. When a task fails QA,
# the count increments; when QA passes, the count is cleared (per-issue).
# If a task hits 3+ consecutive failures, the next attempt escalates to Opus.
#
# State stored in .ralph/.qa_failures.json (JSON object keyed by issue_id).
# Format: { "TAP-123": 2, "TAP-456": 1, ... }

# qa_failures_path — Return path to the QA failures state file
#
qa_failures_path() {
    local ralph_dir="${RALPH_DIR:-.ralph}"
    echo "$ralph_dir/.qa_failures.json"
}

# qa_failures_init — Initialize QA failures state if missing
#
qa_failures_init() {
    local state_file
    state_file=$(qa_failures_path)

    if [[ ! -f "$state_file" ]]; then
        echo "{}" > "$state_file"
    fi
}

# qa_failures_increment — Increment QA failure count for an issue
#
# Usage: qa_failures_increment "TAP-123"
# Returns: new count (or 1 on first failure)
#
qa_failures_increment() {
    local issue_id="${1:-}"
    [[ -z "$issue_id" ]] && return 1

    qa_failures_init
    local state_file
    state_file=$(qa_failures_path)

    local current_count
    current_count=$(jq -r ".\"$issue_id\" // 0" "$state_file" 2>/dev/null) || current_count=0

    local new_count=$((current_count + 1))

    # Atomically update using a temp file
    local tmp_file="${state_file}.tmp.$$"
    if jq --arg id "$issue_id" --arg count "$new_count" \
        '.[$id] = ($count | tonumber)' "$state_file" > "$tmp_file" 2>/dev/null; then
        mv -f "$tmp_file" "$state_file"
    else
        rm -f "$tmp_file"
        return 1
    fi

    echo "$new_count"
}

# qa_failures_get — Get current QA failure count for an issue
#
# Usage: count=$(qa_failures_get "TAP-123")
# Returns: count (0 if not tracked or issue not found)
#
qa_failures_get() {
    local issue_id="${1:-}"
    [[ -z "$issue_id" ]] && return 1

    qa_failures_init
    local state_file
    state_file=$(qa_failures_path)

    jq -r ".\"$issue_id\" // 0" "$state_file" 2>/dev/null || echo "0"
}

# qa_failures_reset — Clear QA failure count for an issue (on PASSING)
#
# Usage: qa_failures_reset "TAP-123"
# Returns: 0 on success
#
qa_failures_reset() {
    local issue_id="${1:-}"
    [[ -z "$issue_id" ]] && return 1

    qa_failures_init
    local state_file
    state_file=$(qa_failures_path)

    # Delete the key if it exists
    local tmp_file="${state_file}.tmp.$$"
    if jq --arg id "$issue_id" 'del(.[$id])' "$state_file" > "$tmp_file" 2>/dev/null; then
        mv -f "$tmp_file" "$state_file"
        return 0
    else
        rm -f "$tmp_file"
        return 1
    fi
}

# qa_failures_clear_all — Wipe all QA failure state
#
# Usage: qa_failures_clear_all
#
qa_failures_clear_all() {
    local state_file
    state_file=$(qa_failures_path)

    if [[ -f "$state_file" ]]; then
        echo "{}" > "$state_file"
    fi
}

# qa_failures_dump — Print full state (debug/observability)
#
# Usage: qa_failures_dump
#
qa_failures_dump() {
    local state_file
    state_file=$(qa_failures_path)

    if [[ -f "$state_file" ]]; then
        cat "$state_file"
    else
        echo "{}"
    fi
}
