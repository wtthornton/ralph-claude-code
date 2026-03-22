#!/bin/bash

# lib/metrics.sh — Lightweight metrics and analytics (Phase 8, OBSERVE-1)
#
# Appends metrics to .ralph/metrics/YYYY-MM.jsonl (monthly JSONL files).
# Collected in on-stop.sh hook after each iteration.
# Human-readable summary via ralph --stats.

METRICS_DIR="${RALPH_DIR:-.ralph}/metrics"

# record_metric — Append a metric event to the monthly JSONL file
#
# Usage: record_metric
# Reads from environment: RALPH_DIR, loop_count, session_id, etc.
# Reads from .ralph/status.json for iteration details.
#
record_metric() {
    local metrics_dir="${METRICS_DIR}"
    mkdir -p "$metrics_dir"

    local month_file="$metrics_dir/$(date '+%Y-%m').jsonl"
    local timestamp
    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    local status_file="${RALPH_DIR:-.ralph}/status.json"
    local work_type="UNKNOWN"
    local exit_signal="false"
    local cb_state="CLOSED"
    local completed_task=""

    if [[ -f "$status_file" ]] && command -v jq &>/dev/null; then
        work_type=$(jq -r '.WORK_TYPE // "UNKNOWN"' "$status_file" 2>/dev/null)
        exit_signal=$(jq -r '.EXIT_SIGNAL // false' "$status_file" 2>/dev/null)
        cb_state=$(jq -r '.circuit_breaker_state // "CLOSED"' "$status_file" 2>/dev/null)
        completed_task=$(jq -r '.COMPLETED_TASK // ""' "$status_file" 2>/dev/null)
    fi

    local call_count=0
    local call_count_file="${RALPH_DIR:-.ralph}/.call_count"
    if [[ -f "$call_count_file" ]]; then
        call_count=$(cat "$call_count_file" 2>/dev/null || echo "0")
    fi

    local loop_count="${LOOP_COUNT:-0}"
    local session_id=""
    local session_file="${RALPH_DIR:-.ralph}/.claude_session_id"
    if [[ -f "$session_file" ]]; then
        session_id=$(cat "$session_file" 2>/dev/null | head -1)
    fi

    # Build JSON line (no jq dependency — manual construction)
    local metric_line
    metric_line=$(printf '{"timestamp":"%s","loop_count":%s,"session_id":"%s","work_type":"%s","exit_signal":%s,"api_calls":%s,"circuit_breaker_state":"%s","completed_task":"%s"}' \
        "$timestamp" \
        "$loop_count" \
        "$session_id" \
        "$work_type" \
        "$exit_signal" \
        "$call_count" \
        "$cb_state" \
        "$(echo "$completed_task" | sed 's/"/\\"/g' | head -c 200)")

    echo "$metric_line" >> "$month_file"
}

# ralph_show_stats — Display human-readable metrics summary
#
# Usage: ralph_show_stats [--json] [--last PERIOD]
#
ralph_show_stats() {
    local format="human"
    local period=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json) format="json"; shift ;;
            --last) period="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    local metrics_dir="${METRICS_DIR}"

    if [[ ! -d "$metrics_dir" ]]; then
        if [[ "$format" == "json" ]]; then
            echo '{"error": "No metrics data found"}'
        else
            echo "No metrics data found. Run Ralph to generate metrics."
        fi
        return 0
    fi

    # Collect all JSONL files
    local files
    files=$(find "$metrics_dir" -name '*.jsonl' -type f | sort)

    if [[ -z "$files" ]]; then
        if [[ "$format" == "json" ]]; then
            echo '{"error": "No metrics data found"}'
        else
            echo "No metrics data found."
        fi
        return 0
    fi

    if ! command -v jq &>/dev/null; then
        echo "Error: jq required for metrics display"
        return 1
    fi

    # Apply time filter
    local filter_cmd="cat"
    if [[ -n "$period" ]]; then
        local cutoff
        case "$period" in
            *d) cutoff=$(date -u -d "-${period%d} days" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -v-"${period%d}d" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) ;;
            *h) cutoff=$(date -u -d "-${period%h} hours" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -v-"${period%h}H" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) ;;
            *) cutoff="" ;;
        esac
        if [[ -n "$cutoff" ]]; then
            filter_cmd="jq -c 'select(.timestamp >= \"$cutoff\")'"
        fi
    fi

    # Aggregate metrics
    local all_metrics
    all_metrics=$(cat $files | eval "$filter_cmd" 2>/dev/null)

    if [[ -z "$all_metrics" ]]; then
        echo "No metrics found for the specified period."
        return 0
    fi

    local total_runs avg_loops success_rate cb_trips total_calls

    total_runs=$(echo "$all_metrics" | wc -l | tr -d ' ')
    total_calls=$(echo "$all_metrics" | jq -s '[.[].api_calls] | add // 0' 2>/dev/null)
    success_rate=$(echo "$all_metrics" | jq -s '[.[].exit_signal] | map(select(. == true)) | length as $s | ($s / (length | if . == 0 then 1 else . end) * 100) | floor' 2>/dev/null)
    cb_trips=$(echo "$all_metrics" | jq -s '[.[].circuit_breaker_state] | map(select(. == "OPEN")) | length' 2>/dev/null)
    avg_loops=$(echo "$all_metrics" | jq -s '[.[].loop_count] | (add / (length | if . == 0 then 1 else . end)) | floor' 2>/dev/null)

    # Work type breakdown
    local work_breakdown
    work_breakdown=$(echo "$all_metrics" | jq -s 'group_by(.work_type) | map({type: .[0].work_type, count: length}) | sort_by(-.count)' 2>/dev/null)

    if [[ "$format" == "json" ]]; then
        jq -n \
            --argjson total "$total_runs" \
            --argjson avg_loops "${avg_loops:-0}" \
            --argjson success "${success_rate:-0}" \
            --argjson cb "${cb_trips:-0}" \
            --argjson calls "${total_calls:-0}" \
            --argjson breakdown "$work_breakdown" \
            '{
                totalRuns: $total,
                avgLoopsPerRun: $avg_loops,
                successRate: $success,
                circuitBreakerTrips: $cb,
                totalApiCalls: $calls,
                workTypeBreakdown: $breakdown
            }'
    else
        echo "Ralph Metrics Summary"
        echo "====================="
        [[ -n "$period" ]] && echo "Period: last $period"
        echo ""
        echo "  Total iterations:    $total_runs"
        echo "  Avg loops/run:       ${avg_loops:-0}"
        echo "  Success rate:        ${success_rate:-0}%"
        echo "  CB trips:            ${cb_trips:-0}"
        echo "  Total API calls:     ${total_calls:-0}"
        echo ""
        echo "Work type breakdown:"
        echo "$work_breakdown" | jq -r '.[] | "  \(.type): \(.count)"' 2>/dev/null
    fi
}
