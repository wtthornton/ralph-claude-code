#!/bin/bash

# lib/notifications.sh — Local notification system (Phase 8, OBSERVE-2)
#
# Fire-and-forget notifications on key events:
# - Loop completed (EXIT_SIGNAL)
# - Loop failed (error)
# - Circuit breaker tripped
# - Rate limit hit
#
# Channels: terminal, OS native, webhook, sound

# Configuration (from .ralphrc / ralph.config.json / env)
RALPH_NOTIFY_TERMINAL="${RALPH_NOTIFY_TERMINAL:-true}"
RALPH_NOTIFY_OS="${RALPH_NOTIFY_OS:-true}"
RALPH_NOTIFY_SOUND="${RALPH_NOTIFY_SOUND:-false}"
RALPH_WEBHOOK_URL="${RALPH_WEBHOOK_URL:-}"

# ralph_notify — Send a notification via all configured channels
#
# Usage: ralph_notify "event_type" "title" "message"
# event_type: completed|failed|circuit_breaker|rate_limit
#
ralph_notify() {
    local event_type="$1"
    local title="$2"
    local message="$3"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # Terminal notification (always)
    if [[ "${RALPH_NOTIFY_TERMINAL}" == "true" ]]; then
        _notify_terminal "$event_type" "$title" "$message"
    fi

    # OS native notification
    if [[ "${RALPH_NOTIFY_OS}" == "true" ]]; then
        _notify_os "$title" "$message" &
    fi

    # Webhook
    if [[ -n "${RALPH_WEBHOOK_URL}" ]]; then
        _notify_webhook "$event_type" "$title" "$message" "$timestamp" &
    fi

    # Sound
    if [[ "${RALPH_NOTIFY_SOUND}" == "true" ]]; then
        _notify_sound "$event_type"
    fi
}

# Terminal notification with color-coded output
_notify_terminal() {
    local event_type="$1"
    local title="$2"
    local message="$3"
    local color

    case "$event_type" in
        completed)      color="\033[0;32m" ;;  # green
        failed)         color="\033[0;31m" ;;  # red
        circuit_breaker) color="\033[1;33m" ;; # yellow
        rate_limit)     color="\033[0;33m" ;;  # yellow
        *)              color="\033[0;37m" ;;  # white
    esac

    echo -e "${color}[RALPH] $title: $message\033[0m"
}

# OS native notification (Linux: notify-send, macOS: osascript)
_notify_os() {
    local title="$1"
    local message="$2"

    if command -v notify-send &>/dev/null; then
        # Linux (GNOME, KDE, etc.)
        notify-send "Ralph: $title" "$message" --icon=dialog-information 2>/dev/null || true
    elif command -v osascript &>/dev/null; then
        # macOS — sanitize inputs to prevent AppleScript injection
        local safe_title safe_message
        safe_title=$(printf '%s' "$title" | sed 's/[\\\"]/\\&/g' | tr -d '\n')
        safe_message=$(printf '%s' "$message" | sed 's/[\\\"]/\\&/g' | tr -d '\n')
        osascript -e "display notification \"$safe_message\" with title \"Ralph: $safe_title\"" 2>/dev/null || true
    fi
    # Windows/WSL: no native support, terminal-only
}

# Webhook POST (fire-and-forget)
_notify_webhook() {
    local event_type="$1"
    local title="$2"
    local message="$3"
    local timestamp="$4"

    if ! command -v curl &>/dev/null; then
        return 0
    fi

    local payload
    payload=$(jq -n \
        --arg event "$event_type" \
        --arg title "$title" \
        --arg message "$message" \
        --arg ts "$timestamp" \
        --arg project "${PROJECT_NAME:-unknown}" \
        '{event: $event, title: $title, message: $message, timestamp: $ts, project: $project}')

    if ! curl -s -X POST \
        -H "Content-Type: application/json" \
        -d "$payload" \
        --max-time 5 \
        "$RALPH_WEBHOOK_URL" >/dev/null 2>&1; then
        echo "WARN: webhook POST failed for event=$event_type url=$RALPH_WEBHOOK_URL" >&2
    fi
}

# Sound notification (terminal bell)
_notify_sound() {
    local event_type="$1"
    # Single bell for success, triple for failure
    case "$event_type" in
        completed)
            printf '\a'
            ;;
        failed|circuit_breaker)
            printf '\a'; sleep 0.3; printf '\a'; sleep 0.3; printf '\a'
            ;;
        *)
            printf '\a'
            ;;
    esac
}

# Convenience functions for common events
ralph_notify_completed() {
    ralph_notify "completed" "Loop Completed" "${1:-All tasks finished successfully}"
}

ralph_notify_failed() {
    ralph_notify "failed" "Loop Failed" "${1:-Loop exited with error}"
}

ralph_notify_circuit_breaker() {
    ralph_notify "circuit_breaker" "Circuit Breaker Tripped" "${1:-No progress detected}"
}

ralph_notify_rate_limit() {
    ralph_notify "rate_limit" "Rate Limit Hit" "${1:-API calls exhausted, waiting for reset}"
}
