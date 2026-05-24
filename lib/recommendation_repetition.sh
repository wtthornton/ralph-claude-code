#!/bin/bash
# TAP-2499: Recommendation-repetition halt — orchestrator-level defense-in-depth.
#
# If the parser fix (TAP-2494) ever regresses or Claude finds another way to
# emit the same RECOMMENDATION across many loops without making progress,
# this module trips an explicit halt. Matches OpenHands `user_response` and
# SWE-agent talked-to-user counters — N identical normalized recommendations
# within a window → exit_reason=recommendation_repetition.
#
# Normalization strips loop numbers and numeric counts so cosmetic variations
# (e.g. "Loop 40 of empty-backlog runaway" vs "Loop 41 of empty-backlog
# runaway") collapse to the same hash.

RALPH_DIR="${RALPH_DIR:-.ralph}"
RECENT_RECS_FILE="${RALPH_DIR}/.recent_recommendations"
RALPH_RECOMMENDATION_REPETITION_THRESHOLD=${RALPH_RECOMMENDATION_REPETITION_THRESHOLD:-5}
RALPH_RECOMMENDATION_REPETITION_WINDOW_MIN=${RALPH_RECOMMENDATION_REPETITION_WINDOW_MIN:-30}
RALPH_RECOMMENDATION_RING_SIZE=${RALPH_RECOMMENDATION_RING_SIZE:-10}

# Normalize a recommendation string before hashing. Lowercases, strips
# whitespace, strips loop-number prefixes ("Loop N", "Loop #N", "Loop N —"),
# and collapses numeric counts in parens like "(4 live probes)" → "(X live
# probes)" so cosmetic loop-to-loop variation hashes identically.
recommendation_normalize() {
    local _text="$1"
    # Lowercase
    _text=$(printf '%s' "$_text" | tr '[:upper:]' '[:lower:]')
    # Strip "loop N", "loop #N", optionally followed by " — " / " - " / " of "
    _text=$(printf '%s' "$_text" | sed -E '
        s/loop[[:space:]]*#?[0-9]+([[:space:]]*[—-][[:space:]]*|[[:space:]]+of[[:space:]]+)/loop /g
        s/loop[[:space:]]*#?[0-9]+/loop/g
    ')
    # Collapse numeric counts in parentheses: "(4 live probes)" → "(X live probes)"
    _text=$(printf '%s' "$_text" | sed -E 's/\(([0-9]+)([[:space:]])/(X\2/g')
    # Strip all whitespace runs to single space
    _text=$(printf '%s' "$_text" | tr -s '[:space:]' ' ')
    # Trim
    _text=$(printf '%s' "$_text" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
    printf '%s' "$_text"
}

# Hash a normalized recommendation. Uses sha256sum prefix for collision-safety
# without keeping the full hash on every line.
recommendation_hash() {
    local _norm
    _norm=$(recommendation_normalize "$1")
    printf '%s' "$_norm" | sha256sum 2>/dev/null | cut -c1-16
}

# Append a recommendation observation to the ring buffer.
# Each line: <epoch_seconds> <hash16>
# Caller passes the raw RECOMMENDATION text; we hash it.
recommendation_record() {
    local _text="$1"
    [[ -z "$_text" ]] && return 0
    [[ -d "$RALPH_DIR" ]] || return 0
    local _now _hash
    _now=$(date +%s)
    _hash=$(recommendation_hash "$_text")
    [[ -z "$_hash" ]] && return 0
    printf '%s %s\n' "$_now" "$_hash" >> "$RECENT_RECS_FILE"
    # Trim ring buffer
    if [[ -f "$RECENT_RECS_FILE" ]]; then
        local _lines
        _lines=$(wc -l < "$RECENT_RECS_FILE" 2>/dev/null | tr -cd '0-9')
        _lines=${_lines:-0}
        if (( _lines > RALPH_RECOMMENDATION_RING_SIZE )); then
            tail -n "$RALPH_RECOMMENDATION_RING_SIZE" "$RECENT_RECS_FILE" > "${RECENT_RECS_FILE}.tmp" \
                && mv "${RECENT_RECS_FILE}.tmp" "$RECENT_RECS_FILE"
        fi
    fi
}

# Check whether the ring buffer shows >= threshold entries with the same hash
# within the last WINDOW_MIN minutes. Echoes the offending hash on a hit,
# nothing on a miss. Exit 0 = repetition detected; exit 1 = not detected.
recommendation_repetition_check() {
    [[ -f "$RECENT_RECS_FILE" ]] || return 1
    local _now _cutoff
    _now=$(date +%s)
    _cutoff=$((_now - RALPH_RECOMMENDATION_REPETITION_WINDOW_MIN * 60))
    # Read lines within window, group by hash, find any with >= threshold
    local _hits
    _hits=$(awk -v cutoff="$_cutoff" -v threshold="$RALPH_RECOMMENDATION_REPETITION_THRESHOLD" '
        $1 >= cutoff {
            counts[$2]++
            if (counts[$2] >= threshold) {
                print $2; exit
            }
        }
    ' "$RECENT_RECS_FILE")
    if [[ -n "$_hits" ]]; then
        printf '%s' "$_hits"
        return 0
    fi
    return 1
}

# Helper for diversity stat (used by ralph-monitor).
recommendation_diversity_stat() {
    [[ -f "$RECENT_RECS_FILE" ]] || { echo "0 0"; return 0; }
    local _total _unique
    _total=$(wc -l < "$RECENT_RECS_FILE" 2>/dev/null | tr -cd '0-9')
    _total=${_total:-0}
    _unique=$(awk '{print $2}' "$RECENT_RECS_FILE" 2>/dev/null | sort -u | wc -l | tr -cd '0-9')
    _unique=${_unique:-0}
    echo "$_unique $_total"
}
