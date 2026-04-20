#!/bin/bash

# Ralph Status Monitor - Live terminal dashboard for the Ralph loop
# Note: set -e intentionally removed — the monitor is a display-only loop
# that must be resilient to transient write errors on broken tmux ptys (Issue #188)

STATUS_FILE=".ralph/status.json"
LOG_FILE=".ralph/logs/ralph.log"
REFRESH_INTERVAL=2

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

# Clear screen and hide cursor
clear_screen() {
    clear
    printf '\033[?25l'  # Hide cursor
}

# Show cursor on exit
show_cursor() {
    printf '\033[?25h'  # Show cursor
}

# Cleanup function
cleanup() {
    show_cursor
    echo
    echo "Monitor stopped."
    exit 0
}

# Set up signal handlers
trap cleanup SIGINT SIGTERM EXIT

# Main display function
display_status() {
    clear_screen
    
    # Header
    echo -e "${WHITE}╔════════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${WHITE}║                           🤖 RALPH MONITOR                              ║${NC}"
    echo -e "${WHITE}║                        Live Status Dashboard                           ║${NC}"
    echo -e "${WHITE}╚════════════════════════════════════════════════════════════════════════╝${NC}"
    echo
    
    # Status section
    if [[ -f "$STATUS_FILE" ]]; then
        # Parse JSON status
        local status_data=$(cat "$STATUS_FILE")
        local loop_count=$(echo "$status_data" | jq -r '.loop_count // "0"' 2>/dev/null || echo "0")
        local calls_made=$(echo "$status_data" | jq -r '.calls_made_this_hour // "0"' 2>/dev/null || echo "0")
        local max_calls=$(echo "$status_data" | jq -r '.max_calls_per_hour // "100"' 2>/dev/null || echo "100")
        local status=$(echo "$status_data" | jq -r '.status // "unknown"' 2>/dev/null || echo "unknown")
        local work_type=$(echo "$status_data" | jq -r '.work_type // ""' 2>/dev/null || echo "")

        # LINEAR-DASH fields (may be null)
        local linear_issue=$(echo "$status_data" | jq -r '.linear_issue // ""' 2>/dev/null || echo "")
        local linear_url=$(echo "$status_data" | jq -r '.linear_url // ""' 2>/dev/null || echo "")
        local linear_epic=$(echo "$status_data" | jq -r '.linear_epic // ""' 2>/dev/null || echo "")
        local linear_epic_done=$(echo "$status_data" | jq -r '.linear_epic_done // ""' 2>/dev/null || echo "")
        local linear_epic_total=$(echo "$status_data" | jq -r '.linear_epic_total // ""' 2>/dev/null || echo "")
        local last_linear_issue=$(echo "$status_data" | jq -r '.last_linear_issue // ""' 2>/dev/null || echo "")
        local session_cost=$(echo "$status_data" | jq -r '.session_cost_usd // 0' 2>/dev/null || echo "0")
        local session_in=$(echo "$status_data" | jq -r '.session_input_tokens // 0' 2>/dev/null || echo "0")
        local session_out=$(echo "$status_data" | jq -r '.session_output_tokens // 0' 2>/dev/null || echo "0")
        local loop_cost=$(echo "$status_data" | jq -r '.loop_cost_usd // 0' 2>/dev/null || echo "0")
        local loop_in=$(echo "$status_data" | jq -r '.loop_input_tokens // 0' 2>/dev/null || echo "0")
        local loop_out=$(echo "$status_data" | jq -r '.loop_output_tokens // 0' 2>/dev/null || echo "0")

        # Current Issue block — show current issue, or last known with (executing...) while loop runs
        local _display_issue="$linear_issue"
        local _issue_suffix=""
        if [[ ( -z "$linear_issue" || "$linear_issue" == "null" ) && -n "$last_linear_issue" && "$last_linear_issue" != "null" && "$status" == "running" ]]; then
            _display_issue="$last_linear_issue"
            _issue_suffix="   ${YELLOW}(executing...)${NC}"
        fi
        if [[ -n "$_display_issue" && "$_display_issue" != "null" ]]; then
            echo -e "${PURPLE}┌─ Current Issue ─────────────────────────────────────────────────────────┐${NC}"
            echo -e "${PURPLE}│${NC} Issue:          ${WHITE}${_display_issue}${NC}${_issue_suffix}${work_type:+   ${BLUE}[${work_type}]${NC}}"
            if [[ -n "$linear_url" && "$linear_url" != "null" ]]; then
                echo -e "${PURPLE}│${NC} Link:           ${BLUE}${linear_url}${NC}"
            fi
            echo -e "${PURPLE}└─────────────────────────────────────────────────────────────────────────┘${NC}"
            echo
        fi

        # Epic progress block — only when epic + counts known
        if [[ -n "$linear_epic" && "$linear_epic" != "null" && -n "$linear_epic_done" && -n "$linear_epic_total" && "$linear_epic_total" != "0" ]]; then
            local pct=$(awk -v d="$linear_epic_done" -v t="$linear_epic_total" 'BEGIN{if(t>0) printf "%.0f", d/t*100; else print 0}')
            local bar_filled=$(awk -v d="$linear_epic_done" -v t="$linear_epic_total" 'BEGIN{if(t>0) printf "%d", d/t*20; else print 0}')
            local bar=""
            local i=0
            while [[ $i -lt $bar_filled ]]; do bar+="▓"; i=$((i+1)); done
            while [[ $i -lt 20 ]]; do bar+="░"; i=$((i+1)); done
            echo -e "${PURPLE}┌─ Epic Progress ─────────────────────────────────────────────────────────┐${NC}"
            echo -e "${PURPLE}│${NC} Epic:           ${WHITE}${linear_epic}${NC}"
            echo -e "${PURPLE}│${NC} Progress:       ${GREEN}${linear_epic_done}${NC}/${linear_epic_total}  (${pct}%)  ${bar}"
            echo -e "${PURPLE}│${NC} QA triggers at: ${linear_epic_total}/${linear_epic_total} (all stories In Review or Done)"
            echo -e "${PURPLE}└─────────────────────────────────────────────────────────────────────────┘${NC}"
            echo
        fi

        # PHASE1: model + cache + sub-agent fields
        local loop_model=$(echo "$status_data" | jq -r '.loop_model // ""' 2>/dev/null || echo "")
        local cache_read=$(echo "$status_data" | jq -r '.session_cache_read_tokens // 0' 2>/dev/null || echo "0")
        local cache_create=$(echo "$status_data" | jq -r '.session_cache_create_tokens // 0' 2>/dev/null || echo "0")
        local loop_subagents=$(echo "$status_data" | jq -r '.loop_subagents // {} | to_entries | map("\(.key)×\(.value)") | join(", ")' 2>/dev/null || echo "")
        local session_subagents=$(echo "$status_data" | jq -r '.session_subagents // {} | to_entries | map("\(.key) \(.value)") | join(", ")' 2>/dev/null || echo "")

        echo -e "${CYAN}┌─ Current Status ────────────────────────────────────────────────────────┐${NC}"
        echo -e "${CYAN}│${NC} Loop Count:     ${WHITE}#$loop_count${NC}"
        echo -e "${CYAN}│${NC} Status:         ${GREEN}$status${NC}"
        if [[ -n "$loop_model" && "$loop_model" != "null" ]]; then
            echo -e "${CYAN}│${NC} Model:          ${GREEN}${loop_model}${NC}"
        fi
        echo -e "${CYAN}│${NC} API Calls:      $calls_made/$max_calls (this hour)"
        # Token + cost — only if data is present (emitted by Linear-driven mode or agent-mode JSON)
        if [[ "$session_cost" != "0" && "$session_cost" != "0.000000" ]] || [[ "$session_in" != "0" ]] || [[ "$cache_read" != "0" || "$cache_create" != "0" ]]; then
            local sess_in_fmt=$(printf "%'d" "$session_in" 2>/dev/null || echo "$session_in")
            local sess_out_fmt=$(printf "%'d" "$session_out" 2>/dev/null || echo "$session_out")
            local sess_cost_fmt=$(awk -v c="$session_cost" 'BEGIN{printf "%.4f", c}')
            local loop_cost_fmt=$(awk -v c="$loop_cost" 'BEGIN{printf "%.4f", c}')
            echo -e "${CYAN}│${NC} Tokens (loop):  in ${loop_in}, out ${loop_out}"
            echo -e "${CYAN}│${NC} Tokens (sess):  in ${sess_in_fmt}, out ${sess_out_fmt}"
            echo -e "${CYAN}│${NC} Cost:           loop \$${loop_cost_fmt}  ·  session \$${sess_cost_fmt}"
            # Cache hit ratio across the session — read / (read + create + out-of-cache in)
            if [[ "$cache_read" != "0" || "$cache_create" != "0" ]]; then
                local cache_hit_pct=$(awk -v r="$cache_read" -v c="$cache_create" -v i="$session_in" 'BEGIN{d=r+c+i; if(d>0) printf "%.0f", r/d*100; else print 0}')
                local cache_read_fmt=$(printf "%'d" "$cache_read" 2>/dev/null || echo "$cache_read")
                echo -e "${CYAN}│${NC} Cache:          ${GREEN}${cache_hit_pct}%${NC} hit · ${cache_read_fmt} tokens read"
            fi
        fi
        if [[ -n "$loop_subagents" ]]; then
            echo -e "${CYAN}│${NC} Sub-agents (loop):    ${loop_subagents}"
        fi
        if [[ -n "$session_subagents" ]]; then
            echo -e "${CYAN}│${NC} Sub-agents (session): ${session_subagents}"
        fi
        # MCP activity — top 3 tools this loop by call count
        local loop_mcp_top=$(echo "$status_data" | jq -r '.loop_mcp_calls.by_tool // {} | to_entries | sort_by(-.value) | .[0:3] | map("\(.key | split("__") | last)×\(.value)") | join("  ")' 2>/dev/null || echo "")
        if [[ -n "$loop_mcp_top" ]]; then
            echo -e "${CYAN}│${NC} MCP (loop):     ${loop_mcp_top}"
        fi
        # Teams configuration (read once from .ralphrc — teams state isn't persisted to a consumable file)
        local teams_enabled=$(grep -E "^RALPH_ENABLE_TEAMS=" .ralphrc 2>/dev/null | tail -1 | sed 's/.*=//; s/["'"'"']//g' | tr -d '[:space:]')
        if [[ "$teams_enabled" == "true" ]]; then
            local teams_max=$(grep -E "^RALPH_MAX_TEAMMATES=" .ralphrc 2>/dev/null | tail -1 | sed 's/.*=//; s/["'"'"']//g' | tr -d '[:space:]')
            local teams_mode=$(grep -E "^RALPH_TEAMMATE_MODE=" .ralphrc 2>/dev/null | tail -1 | sed 's/.*=//; s/["'"'"']//g' | tr -d '[:space:]')
            echo -e "${CYAN}│${NC} Teams:          ${GREEN}enabled${NC} · max ${teams_max:-3} teammates · mode ${teams_mode:-tmux}"
        fi
        echo -e "${CYAN}└─────────────────────────────────────────────────────────────────────────┘${NC}"
        echo

    else
        echo -e "${RED}┌─ Status ────────────────────────────────────────────────────────────────┐${NC}"
        echo -e "${RED}│${NC} Status file not found. Ralph may not be running."
        echo -e "${RED}└─────────────────────────────────────────────────────────────────────────┘${NC}"
        echo
    fi
    
    # Claude Code Progress section
    if [[ -f ".ralph/progress.json" ]]; then
        local progress_data=$(cat ".ralph/progress.json" 2>/dev/null)
        local progress_status=$(echo "$progress_data" | jq -r '.status // "idle"' 2>/dev/null || echo "idle")
        
        if [[ "$progress_status" == "executing" ]]; then
            local indicator=$(echo "$progress_data" | jq -r '.indicator // "⠋"' 2>/dev/null || echo "⠋")
            local elapsed=$(echo "$progress_data" | jq -r '.elapsed_seconds // "0"' 2>/dev/null || echo "0")
            local last_output=$(echo "$progress_data" | jq -r '.last_output // ""' 2>/dev/null || echo "")
            
            echo -e "${YELLOW}┌─ Claude Code Progress ──────────────────────────────────────────────────┐${NC}"
            echo -e "${YELLOW}│${NC} Status:         ${indicator} Working (${elapsed}s elapsed)"
            if [[ -n "$last_output" && "$last_output" != "" ]]; then
                # Truncate long output for display
                local display_output=$(echo "$last_output" | head -c 60)
                echo -e "${YELLOW}│${NC} Output:         ${display_output}..."
            fi
            echo -e "${YELLOW}└─────────────────────────────────────────────────────────────────────────┘${NC}"
            echo
        fi
    fi
    
    # Recent logs
    echo -e "${BLUE}┌─ Recent Activity ───────────────────────────────────────────────────────┐${NC}"
    if [[ -f "$LOG_FILE" ]]; then
        tail -n 8 "$LOG_FILE" | while IFS= read -r line; do
            echo -e "${BLUE}│${NC} $line"
        done
    else
        echo -e "${BLUE}│${NC} No log file found"
    fi
    echo -e "${BLUE}└─────────────────────────────────────────────────────────────────────────┘${NC}"
    
    # Footer
    echo
    echo -e "${YELLOW}Controls: Ctrl+C to exit | Refreshes every ${REFRESH_INTERVAL}s | $(date '+%H:%M:%S')${NC}"
}

# Main monitor loop
main() {
    echo "Starting Ralph Monitor..."
    sleep 2
    
    while true; do
        display_status
        sleep "$REFRESH_INTERVAL"
    done
}

main
