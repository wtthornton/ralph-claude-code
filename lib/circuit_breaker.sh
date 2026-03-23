#!/bin/bash
# Circuit Breaker Component for Ralph (Simplified)
# Prevents runaway token consumption by detecting stagnation.
# Based on Michael Nygard's "Release It!" pattern.
#
# Progress detection and state updates are handled by the on-stop.sh hook.
# This module provides: state reading, cooldown/auto-recovery, display, and reset.

# Source date utilities for cross-platform compatibility
source "$(dirname "${BASH_SOURCE[0]}")/date_utils.sh"

# Circuit Breaker States
CB_STATE_CLOSED="CLOSED"        # Normal operation, progress detected
CB_STATE_HALF_OPEN="HALF_OPEN"  # Monitoring mode, checking for recovery
CB_STATE_OPEN="OPEN"            # Failure detected, execution halted

# Configuration
RALPH_DIR="${RALPH_DIR:-.ralph}"
CB_STATE_FILE="$RALPH_DIR/.circuit_breaker_state"
CB_HISTORY_FILE="$RALPH_DIR/.circuit_breaker_history"
CB_COOLDOWN_MINUTES=${CB_COOLDOWN_MINUTES:-30}
CB_AUTO_RESET=${CB_AUTO_RESET:-false}

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Initialize circuit breaker state file and handle startup recovery
init_circuit_breaker() {
    # Validate existing state file
    if [[ -f "$CB_STATE_FILE" ]]; then
        if ! jq '.' "$CB_STATE_FILE" > /dev/null 2>&1; then
            rm -f "$CB_STATE_FILE"
        fi
    fi

    # Create default state if missing
    if [[ ! -f "$CB_STATE_FILE" ]]; then
        cat > "$CB_STATE_FILE" << EOF
{
    "state": "$CB_STATE_CLOSED",
    "last_change": "$(get_iso_timestamp)",
    "consecutive_no_progress": 0,
    "total_opens": 0,
    "reason": ""
}
EOF
    fi

    # Ensure history file exists
    if [[ -f "$CB_HISTORY_FILE" ]]; then
        if ! jq '.' "$CB_HISTORY_FILE" > /dev/null 2>&1; then
            rm -f "$CB_HISTORY_FILE"
        fi
    fi
    [[ -f "$CB_HISTORY_FILE" ]] || echo '[]' > "$CB_HISTORY_FILE"

    # LOGFIX-8: Fix state inconsistency — if OPEN but total_opens=0, correct it
    local _current_state _total_opens
    _current_state=$(jq -r '.state' "$CB_STATE_FILE" 2>/dev/null || echo "$CB_STATE_CLOSED")
    _total_opens=$(jq -r '.total_opens // 0' "$CB_STATE_FILE" 2>/dev/null || echo "0")
    if [[ "$_current_state" == "$CB_STATE_OPEN" && "$_total_opens" -eq 0 ]]; then
        local tmp
        tmp=$(mktemp "${CB_STATE_FILE}.XXXXXX")
        jq '.total_opens = 1' "$CB_STATE_FILE" > "$tmp" && mv "$tmp" "$CB_STATE_FILE"
        rm -f "$tmp" 2>/dev/null
    fi

    # Startup recovery: handle OPEN state
    local current_state
    current_state=$(jq -r '.state' "$CB_STATE_FILE" 2>/dev/null || echo "$CB_STATE_CLOSED")

    if [[ "$current_state" == "$CB_STATE_OPEN" ]]; then
        if [[ "$CB_AUTO_RESET" == "true" ]]; then
            # Auto-reset: bypass cooldown, go straight to CLOSED
            local total_opens
            total_opens=$(jq -r '.total_opens // 0' "$CB_STATE_FILE" 2>/dev/null || echo "0")
            _cb_log_transition "$CB_STATE_OPEN" "$CB_STATE_CLOSED" "Auto-reset on startup (CB_AUTO_RESET=true)"

            cat > "$CB_STATE_FILE" << EOF
{
    "state": "$CB_STATE_CLOSED",
    "last_change": "$(get_iso_timestamp)",
    "consecutive_no_progress": 0,
    "total_opens": $total_opens,
    "reason": "Auto-reset on startup"
}
EOF
        else
            # Cooldown: check if enough time has elapsed to transition to HALF_OPEN
            _cb_check_cooldown
        fi
    fi
}

# Read current circuit breaker state
get_circuit_state() {
    if [[ ! -f "$CB_STATE_FILE" ]]; then
        echo "$CB_STATE_CLOSED"
        return
    fi
    jq -r '.state' "$CB_STATE_FILE" 2>/dev/null || echo "$CB_STATE_CLOSED"
}

# Check if circuit breaker allows execution
can_execute() {
    local state
    state=$(get_circuit_state)
    [[ "$state" != "$CB_STATE_OPEN" ]]
}

# Check if the loop should halt (used in main loop)
should_halt_execution() {
    local state
    state=$(get_circuit_state)

    if [[ "$state" == "$CB_STATE_OPEN" ]]; then
        show_circuit_status
        echo ""
        echo -e "${RED}╔════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}║  EXECUTION HALTED: Circuit Breaker Opened                 ║${NC}"
        echo -e "${RED}╚════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "${YELLOW}Ralph has detected that no progress is being made.${NC}"
        echo ""
        echo -e "${YELLOW}Possible reasons:${NC}"
        echo "  • Project may be complete (check .ralph/fix_plan.md)"
        echo "  • Claude may be stuck on an error"
        echo "  • .ralph/PROMPT.md may need clarification"
        echo "  • Manual intervention may be required"
        echo ""
        echo -e "${YELLOW}To continue:${NC}"
        echo "  1. Review recent logs: tail -20 .ralph/logs/ralph.log"
        echo "  2. Check Claude output: ls -lt .ralph/logs/claude_output_*.log | head -1"
        echo "  3. Update .ralph/fix_plan.md if needed"
        echo "  4. Reset circuit breaker: ralph --reset-circuit"
        echo ""
        return 0  # Signal to halt
    else
        return 1  # Can continue
    fi
}

# Check if circuit breaker just transitioned to OPEN (after hook update)
# Returns 0 if OPEN, 1 otherwise. Used by ralph_loop.sh after execute_claude_code.
cb_is_open() {
    local state
    state=$(get_circuit_state)
    [[ "$state" == "$CB_STATE_OPEN" ]]
}

# Display circuit breaker status
show_circuit_status() {
    init_circuit_breaker

    local state_data state reason no_progress total_opens
    state_data=$(cat "$CB_STATE_FILE")
    state=$(echo "$state_data" | jq -r '.state')
    reason=$(echo "$state_data" | jq -r '.reason')
    no_progress=$(echo "$state_data" | jq -r '.consecutive_no_progress')
    total_opens=$(echo "$state_data" | jq -r '.total_opens')

    local color="" status_icon=""
    case $state in
        "$CB_STATE_CLOSED")   color=$GREEN;  status_icon="✅" ;;
        "$CB_STATE_HALF_OPEN") color=$YELLOW; status_icon="⚠️ " ;;
        "$CB_STATE_OPEN")     color=$RED;    status_icon="🚨" ;;
    esac

    echo -e "${color}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${color}║           Circuit Breaker Status                          ║${NC}"
    echo -e "${color}╚════════════════════════════════════════════════════════════╝${NC}"
    echo -e "${color}State:${NC}                 $status_icon $state"
    echo -e "${color}Reason:${NC}                $reason"
    echo -e "${color}Loops since progress:${NC} $no_progress"
    echo -e "${color}Total opens:${NC}          $total_opens"

    # CBDECAY-1: Show sliding window stats
    local window_stats window_total window_failures
    window_stats=$(cb_get_window_stats)
    window_total=$(echo "$window_stats" | cut -d' ' -f1)
    window_failures=$(echo "$window_stats" | cut -d' ' -f2)
    echo -e "${color}Failure window:${NC}       $window_failures failures / $window_total calls in last ${CB_FAILURE_DECAY_MINUTES}m"
    echo ""
}

# Reset circuit breaker (for manual intervention)
reset_circuit_breaker() {
    local reason=${1:-"Manual reset"}

    # Preserve total_opens count across resets
    local prev_total_opens=0
    if [[ -f "$CB_STATE_FILE" ]]; then
        prev_total_opens=$(jq -r '.total_opens // 0' "$CB_STATE_FILE" 2>/dev/null || echo "0")
        [[ "$prev_total_opens" =~ ^[0-9]+$ ]] || prev_total_opens=0
    fi

    # Escape reason for safe JSON interpolation
    local safe_reason
    safe_reason=$(printf '%s' "$reason" | sed 's/\\/\\\\/g; s/"/\\"/g')

    cat > "$CB_STATE_FILE" << EOF
{
    "state": "$CB_STATE_CLOSED",
    "last_change": "$(get_iso_timestamp)",
    "consecutive_no_progress": 0,
    "total_opens": $prev_total_opens,
    "reason": "$safe_reason"
}
EOF

    # CBDECAY-1: Clear sliding window event log on reset
    : > "$CB_FAILURE_LOG" 2>/dev/null

    echo -e "${GREEN}✅ Circuit breaker reset to CLOSED state${NC}"
}

# --- Internal helpers ---

# Check cooldown and transition OPEN → HALF_OPEN if elapsed
_cb_check_cooldown() {
    local opened_at
    opened_at=$(jq -r '.opened_at // .last_change // ""' "$CB_STATE_FILE" 2>/dev/null || echo "")

    if [[ -n "$opened_at" && "$opened_at" != "null" ]]; then
        local opened_epoch current_epoch elapsed_minutes
        opened_epoch=$(parse_iso_to_epoch "$opened_at")
        current_epoch=$(date +%s)
        elapsed_minutes=$(( (current_epoch - opened_epoch) / 60 ))

        if [[ $elapsed_minutes -ge 0 && $elapsed_minutes -ge $CB_COOLDOWN_MINUTES ]]; then
            _cb_log_transition "$CB_STATE_OPEN" "$CB_STATE_HALF_OPEN" \
                "Cooldown elapsed (${elapsed_minutes}m >= ${CB_COOLDOWN_MINUTES}m)"

            local tmp
            tmp=$(mktemp "${CB_STATE_FILE}.XXXXXX")
            jq \
                --arg state "$CB_STATE_HALF_OPEN" \
                --arg last_change "$(get_iso_timestamp)" \
                --arg reason "Cooldown recovery: ${elapsed_minutes}m elapsed" \
                '.state = $state | .last_change = $last_change | .reason = $reason' \
                "$CB_STATE_FILE" > "$tmp" && mv "$tmp" "$CB_STATE_FILE"
        fi
    fi
}

# Log a state transition to history and console
_cb_log_transition() {
    local from_state=$1 to_state=$2 reason=$3

    # Append to history file
    if [[ -f "$CB_HISTORY_FILE" ]]; then
        local transition="{\"timestamp\": \"$(get_iso_timestamp)\", \"from_state\": \"$from_state\", \"to_state\": \"$to_state\", \"reason\": \"$reason\"}"
        local history
        history=$(cat "$CB_HISTORY_FILE")
        echo "$history" | jq ". += [$transition]" > "$CB_HISTORY_FILE" 2>/dev/null || true
    fi

    # Console log with colors
    case $to_state in
        "$CB_STATE_OPEN")
            echo -e "${RED}🚨 CIRCUIT BREAKER OPENED${NC}"
            echo -e "${RED}Reason: $reason${NC}"
            ;;
        "$CB_STATE_HALF_OPEN")
            echo -e "${YELLOW}⚠️  CIRCUIT BREAKER: Monitoring Mode${NC}"
            echo -e "${YELLOW}Reason: $reason${NC}"
            ;;
        "$CB_STATE_CLOSED")
            echo -e "${GREEN}✅ CIRCUIT BREAKER: Normal Operation${NC}"
            echo -e "${GREEN}Reason: $reason${NC}"
            ;;
    esac
}

# =============================================================================
# CBDECAY-1: Time-Weighted Sliding Window (Phase 13)
# Replace cumulative failure counter with time-based sliding window.
# Only failures within CB_FAILURE_DECAY_MINUTES contribute to threshold.
# =============================================================================

CB_FAILURE_LOG="${RALPH_DIR}/.circuit_breaker_events"
CB_FAILURE_DECAY_MINUTES=${CB_FAILURE_DECAY_MINUTES:-30}
CB_FAILURE_THRESHOLD=${CB_FAILURE_THRESHOLD:-5}
CB_MIN_CALLS=${CB_MIN_CALLS:-3}  # Don't evaluate until N calls in window

# Record a failure event with timestamp
cb_record_failure() {
    local now
    now=$(date +%s)
    echo "$now fail" >> "$CB_FAILURE_LOG"
    cb_evaluate_window
}

# Record a success event
cb_record_success() {
    local now
    now=$(date +%s)
    echo "$now ok" >> "$CB_FAILURE_LOG"
    # Prune old entries beyond the window
    cb_prune_old_events
}

# Remove events outside the sliding window
cb_prune_old_events() {
    local now cutoff
    now=$(date +%s)
    cutoff=$((now - CB_FAILURE_DECAY_MINUTES * 60))

    if [[ -f "$CB_FAILURE_LOG" ]]; then
        awk -v cutoff="$cutoff" '$1 >= cutoff' "$CB_FAILURE_LOG" > "${CB_FAILURE_LOG}.tmp"
        mv "${CB_FAILURE_LOG}.tmp" "$CB_FAILURE_LOG"
        rm -f "${CB_FAILURE_LOG}.tmp" 2>/dev/null  # WSL cleanup
    fi
}

# Get windowed stats: "total failures" on stdout
cb_get_window_stats() {
    local now cutoff total failures
    now=$(date +%s)
    cutoff=$((now - CB_FAILURE_DECAY_MINUTES * 60))

    if [[ ! -f "$CB_FAILURE_LOG" ]]; then
        echo "0 0"
        return
    fi

    total=$(awk -v cutoff="$cutoff" '$1 >= cutoff' "$CB_FAILURE_LOG" | wc -l | tr -d '[:space:]')
    failures=$(awk -v cutoff="$cutoff" '$1 >= cutoff && $2 == "fail"' "$CB_FAILURE_LOG" | wc -l | tr -d '[:space:]')
    echo "$total $failures"
}

# Evaluate the sliding window and trip CB if threshold reached
cb_evaluate_window() {
    local stats total failures
    stats=$(cb_get_window_stats)
    total=$(echo "$stats" | cut -d' ' -f1)
    failures=$(echo "$stats" | cut -d' ' -f2)

    # Don't evaluate until minimum calls reached
    if [[ "$total" -lt "$CB_MIN_CALLS" ]]; then
        return 0
    fi

    if [[ "$failures" -ge "$CB_FAILURE_THRESHOLD" ]]; then
        echo -e "${YELLOW}WARN: Circuit breaker threshold reached: $failures failures in last ${CB_FAILURE_DECAY_MINUTES}m (window: $total calls)${NC}" >&2

        # Trip the breaker
        local total_opens
        total_opens=$(jq -r '.total_opens // 0' "$CB_STATE_FILE" 2>/dev/null || echo "0")
        total_opens=$((total_opens + 1))
        _cb_log_transition "$(get_circuit_state)" "$CB_STATE_OPEN" \
            "Sliding window: $failures failures in ${CB_FAILURE_DECAY_MINUTES}m"

        local tmp
        tmp=$(mktemp "${CB_STATE_FILE}.XXXXXX")
        jq -n \
            --arg state "$CB_STATE_OPEN" \
            --arg last_change "$(get_iso_timestamp)" \
            --arg opened_at "$(get_iso_timestamp)" \
            --arg reason "failure_threshold: $failures failures in ${CB_FAILURE_DECAY_MINUTES}m window" \
            --argjson no_progress "$failures" \
            --argjson total_opens "$total_opens" \
            '{state: $state, last_change: $last_change, opened_at: $opened_at, consecutive_no_progress: $no_progress, total_opens: $total_opens, reason: $reason}' \
            > "$tmp" && mv "$tmp" "$CB_STATE_FILE"
        rm -f "$tmp" 2>/dev/null
        return 1
    fi

    return 0
}

# Override reset to also clear the event log
_cb_reset_events() {
    : > "$CB_FAILURE_LOG" 2>/dev/null
}

# Export functions for use in other scripts
export -f init_circuit_breaker
export -f get_circuit_state
export -f can_execute
export -f should_halt_execution
export -f cb_is_open
export -f show_circuit_status
export -f reset_circuit_breaker
export -f cb_record_failure
export -f cb_record_success
export -f cb_prune_old_events
export -f cb_get_window_stats
export -f cb_evaluate_window
