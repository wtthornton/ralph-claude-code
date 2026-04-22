#!/bin/bash
# ralph-cost-report — per-loop cost/time/ticket/agent analysis.
#
# Reads the .ralph/logs/claude_output_*.log files (the last line of each
# contains the JSON result from Claude) plus on-stop.sh-written status
# snapshots, aggregates per-loop metrics without requiring an intrusive
# hook change, and prints:
#   - a per-loop table: time · dur · cost · work_type · tickets · agents · tools
#   - a summary block: cost/loop avg, cost/ticket avg, worst-value loop,
#     cost-by-work-type, cost trend (first-half vs second-half)
#
# Usage:
#   ralph-cost-report                # human table (default)
#   ralph-cost-report --json         # JSONL, one line per loop
#   ralph-cost-report --summary      # only the aggregate block
#   ralph-cost-report --since 16:30  # filter by HH:MM lower bound
#   RALPH_DIR=/path/to/.ralph ralph-cost-report   # override project dir
#
# Exit codes:
#   0 — success
#   2 — no claude_output logs found in RALPH_DIR/logs

set -euo pipefail

RALPH_DIR="${RALPH_DIR:-.ralph}"
LOG_DIR="$RALPH_DIR/logs"
MODE="human"
SINCE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --json)    MODE="jsonl"; shift ;;
        --summary) MODE="summary"; shift ;;
        --since)   SINCE="$2"; shift 2 ;;
        -h|--help)
            sed -n '3,20p' "$0"
            exit 0
            ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

if [[ ! -d "$LOG_DIR" ]]; then
    echo "error: $LOG_DIR not found (run from project root or set RALPH_DIR)" >&2
    exit 2
fi

# Find all claude_output logs except the stream variants; oldest first.
mapfile -t LOG_FILES < <(ls -1 "$LOG_DIR"/claude_output_*.log 2>/dev/null | grep -v '_stream\.log$' | sort)

if [[ ${#LOG_FILES[@]} -eq 0 ]]; then
    echo "error: no claude_output_*.log files in $LOG_DIR" >&2
    exit 2
fi

# emit_jsonl_line <log_file>
# Extracts the last `type:"result"` line from the log + the matching stream
# log (for tool/agent counts), plus the RALPH_STATUS fields, and emits one
# JSONL record to stdout.
emit_jsonl_line() {
    local log="$1"
    local fname
    fname=$(basename "$log" .log)
    # fname format: claude_output_YYYY-MM-DD_HH-MM-SS
    local time_hhmmss
    time_hhmmss=$(echo "$fname" | awk -F_ '{print $3"_"$4}' | tr '_-' ': ')

    # Extract the single result line. Some logs have multiple JSON objects
    # per line; the last line IS the result for ralph's use of -p mode.
    local result_line
    result_line=$(tail -c 40000 "$log" | awk '/"type":"result"/' | tail -1)
    [[ -z "$result_line" ]] && return 0

    local cost dur turns is_error model
    cost=$(echo "$result_line"  | jq -r '.total_cost_usd // 0' 2>/dev/null)
    dur=$(echo "$result_line"   | jq -r '.duration_ms // 0'    2>/dev/null)
    turns=$(echo "$result_line" | jq -r '.num_turns // 0'      2>/dev/null)
    is_error=$(echo "$result_line" | jq -r '.is_error // false' 2>/dev/null)
    model=$(echo "$result_line" | jq -r '.modelUsage | keys | first // "unknown"' 2>/dev/null)

    # Pull RALPH_STATUS fields out of .result (a free-form string).
    local result_text
    result_text=$(echo "$result_line" | jq -r '.result // ""' 2>/dev/null)
    local tasks files work tests exit_sig tickets
    # grep -oE returns 1 on no match, which `set -e` would fatally honor; the
    # `|| true` keeps the pipeline tolerant for responses that lack RALPH_STATUS
    # (e.g. rate-limit bail-outs).
    tasks=$(echo     "$result_text" | { grep -oE 'TASKS_COMPLETED_THIS_LOOP: [0-9]+' || true; } | head -1 | awk '{print $2}')
    files=$(echo     "$result_text" | { grep -oE 'FILES_MODIFIED: [0-9]+'            || true; } | head -1 | awk '{print $2}')
    work=$(echo      "$result_text" | { grep -oE 'WORK_TYPE: [A-Z_]+'                || true; } | head -1 | awk '{print $2}')
    tests=$(echo     "$result_text" | { grep -oE 'TESTS_STATUS: [A-Z_]+'             || true; } | head -1 | awk '{print $2}')
    exit_sig=$(echo  "$result_text" | { grep -oE 'EXIT_SIGNAL: (true|false)'         || true; } | head -1 | awk '{print $2}')
    tickets=$(echo   "$result_text" | { grep -oE 'TAP-[0-9]+'                        || true; } | sort -u | paste -sd, -)

    # Stream log: count tool uses + sub-agent invocations.
    # Safe integer grep-count: strip non-digits, default to 0 on any failure.
    _gc() {
        local pat="$1" file="$2"
        local n
        n=$(grep -c "$pat" "$file" 2>/dev/null | tr -cd '0-9')
        echo "${n:-0}"
    }

    local stream="${log%.log}_stream.log"
    local tool_bash=0 tool_edit=0 tool_read=0 tool_grep=0 tool_glob=0 tool_write=0 tool_task=0
    local agent_explorer=0 agent_tester=0 agent_reviewer=0 agent_architect=0
    local mcp_tapps=0 mcp_brain=0 mcp_docs=0 mcp_linear=0 mcp_context7=0
    if [[ -f "$stream" ]]; then
        tool_bash=$(_gc '"name":"Bash"'  "$stream")
        tool_edit=$(_gc '"name":"Edit"'  "$stream")
        tool_read=$(_gc '"name":"Read"'  "$stream")
        tool_grep=$(_gc '"name":"Grep"'  "$stream")
        tool_glob=$(_gc '"name":"Glob"'  "$stream")
        tool_write=$(_gc '"name":"Write"' "$stream")
        tool_task=$(_gc '"name":"Task"'  "$stream")

        # ralph_loop.sh counts "agents" as task_started events. We also break
        # out by subagent_type so the named-vs-general-purpose split is visible.
        agent_explorer=$(_gc  '"subagent_type":"ralph-explorer"'  "$stream")
        agent_tester=$(_gc    '"subagent_type":"ralph-tester"'    "$stream")
        agent_reviewer=$(_gc  '"subagent_type":"ralph-reviewer"'  "$stream")
        agent_architect=$(_gc '"subagent_type":"ralph-architect"' "$stream")
        local agent_generic
        agent_generic=$(_gc   '"subagent_type":"general-purpose"' "$stream")
        local tasks_started
        tasks_started=$(_gc   '"subtype":"task_started"' "$stream")

        mcp_tapps=$(_gc    '"name":"mcp__tapps-mcp__'             "$stream")
        mcp_brain=$(_gc    '"name":"mcp__tapps-brain__'           "$stream")
        mcp_docs=$(_gc     '"name":"mcp__docs-mcp__'              "$stream")
        mcp_linear=$(_gc   '"name":"mcp__plugin_linear_linear__'  "$stream")
        mcp_context7=$(_gc '"name":"mcp__context7__'              "$stream")
    fi

    # is_error might be the literal string "false"/"true" or JSON bool; coerce.
    [[ "$is_error" != "true" && "$is_error" != "false" ]] && is_error="false"
    [[ "$exit_sig" != "true" && "$exit_sig" != "false" ]] && exit_sig="false"
    # Numeric fields may be empty if missing.
    [[ "$tasks" =~ ^[0-9]+$ ]] || tasks=0
    [[ "$files" =~ ^[0-9]+$ ]] || files=0
    [[ "$turns" =~ ^[0-9]+$ ]] || turns=0

    jq -cn \
        --arg    time     "$time_hhmmss" \
        --arg    log      "$fname" \
        --arg    model    "$model" \
        --arg    work     "${work:-UNKNOWN}" \
        --arg    tests    "${tests:-UNKNOWN}" \
        --arg    tickets  "${tickets:-}" \
        --argjson cost    "${cost:-0}" \
        --argjson dur_ms  "${dur:-0}" \
        --argjson turns   "${turns:-0}" \
        --argjson tasks   "${tasks:-0}" \
        --argjson files   "${files:-0}" \
        --argjson err     "${is_error:-false}" \
        --argjson exit_sig "${exit_sig:-false}" \
        --argjson tool_bash "${tool_bash:-0}" \
        --argjson tool_edit "${tool_edit:-0}" \
        --argjson tool_read "${tool_read:-0}" \
        --argjson tool_grep "${tool_grep:-0}" \
        --argjson tool_glob "${tool_glob:-0}" \
        --argjson tool_write "${tool_write:-0}" \
        --argjson tool_task "${tool_task:-0}" \
        --argjson agent_explorer  "${agent_explorer:-0}" \
        --argjson agent_tester    "${agent_tester:-0}" \
        --argjson agent_reviewer  "${agent_reviewer:-0}" \
        --argjson agent_architect "${agent_architect:-0}" \
        --argjson agent_generic   "${agent_generic:-0}" \
        --argjson tasks_started   "${tasks_started:-0}" \
        --argjson mcp_tapps    "${mcp_tapps:-0}" \
        --argjson mcp_brain    "${mcp_brain:-0}" \
        --argjson mcp_docs     "${mcp_docs:-0}" \
        --argjson mcp_linear   "${mcp_linear:-0}" \
        --argjson mcp_context7 "${mcp_context7:-0}" \
        '{time:$time, log:$log, model:$model, is_error:$err,
          cost_usd:$cost, duration_s:($dur_ms/1000|floor), turns:$turns,
          tasks:$tasks, files:$files, work:$work, tests:$tests,
          exit_signal:$exit_sig, tickets:$tickets,
          tools:{bash:$tool_bash, edit:$tool_edit, read:$tool_read,
                 grep:$tool_grep, glob:$tool_glob, write:$tool_write,
                 task:$tool_task},
          agents:{explorer:$agent_explorer, tester:$agent_tester,
                  reviewer:$agent_reviewer, architect:$agent_architect,
                  generic:$agent_generic, tasks_started:$tasks_started},
          mcp:{tapps:$mcp_tapps, brain:$mcp_brain, docs:$mcp_docs,
               linear:$mcp_linear, context7:$mcp_context7}}'
}

# Emit all JSONL lines
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
for log in "${LOG_FILES[@]}"; do
    emit_jsonl_line "$log" >> "$TMP"
done

# Filter by --since HH:MM if provided.
if [[ -n "$SINCE" ]]; then
    jq -c --arg s "$SINCE" 'select(.time >= $s)' "$TMP" > "$TMP.f"
    mv "$TMP.f" "$TMP"
fi

if [[ "$MODE" == "jsonl" ]]; then
    cat "$TMP"
    exit 0
fi

if [[ "$MODE" == "human" ]]; then
    printf '%-8s  %5s  %6s  %5s  %-4s  %-14s  %-18s  %-5s  %-25s\n' \
        "time" "dur_s" "cost_usd" "turns" "tsks" "work" "e/t/r/a" "mcp_b" "tickets"
    printf '%-8s  %5s  %6s  %5s  %-4s  %-14s  %-18s  %-5s  %-25s\n' \
        "--------" "-----" "--------" "-----" "----" "--------------" "---------------" "-----" "-------------------------"
    jq -r '[.time, (.duration_s|tostring), (.cost_usd|tostring),
            (.turns|tostring), (.tasks|tostring), .work,
            "\(.agents.explorer)/\(.agents.tester)/\(.agents.reviewer)/\(.agents.architect)",
            (.mcp.brain|tostring),
            (if .tickets=="" then "-" else .tickets end)] | @tsv' "$TMP" |
        awk -F'\t' '{printf "%-8s  %5s  %6.2f  %5s  %-4s  %-14s  %-18s  %-5s  %-25s\n", $1, $2, $3, $4, $5, $6, $7, $8, $9}'
    echo ""
fi

# Summary block (always, unless --json)
TOTAL_COST=$(jq -s 'map(.cost_usd) | add // 0' "$TMP")
N=$(jq -s 'length' "$TMP")
[[ "$N" -eq 0 ]] && exit 0
AVG_COST=$(jq -s 'map(.cost_usd) | add / length' "$TMP")
TOTAL_TASKS=$(jq -s 'map(.tasks) | add // 0' "$TMP")
TOTAL_TICKETS=$(jq -s '[.[].tickets | split(",") | .[] | select(length > 0)] | unique | length' "$TMP")
TOTAL_SEC=$(jq -s 'map(.duration_s) | add // 0' "$TMP")

echo "=== Summary ($N loops, ${TOTAL_SEC}s total active time) ==="
printf "  Total cost:        \$%s\n" "$TOTAL_COST"
printf "  Avg cost/loop:     \$%s\n" "$AVG_COST"
if [[ "$TOTAL_TICKETS" -gt 0 ]]; then
    CPT=$(jq -nr --argjson c "$TOTAL_COST" --argjson t "$TOTAL_TICKETS" '$c / $t')
    printf "  Avg cost/ticket:   \$%s  (%s unique TAPs referenced)\n" "$CPT" "$TOTAL_TICKETS"
fi

echo ""
echo "  Cost by work_type:"
jq -s 'group_by(.work)[] | {work: .[0].work, n: length, total: (map(.cost_usd)|add), avg: (map(.cost_usd)|add/length)}' "$TMP" |
    jq -r '"    \(.work | ascii_downcase | .[:14]) \(" "*(15-(.work|length))) n=\(.n) total=$\(.total | .*100|round|./100) avg=$\(.avg | .*100|round|./100)"'

echo ""
echo "  Sub-agent invocations (across all loops):"
jq -s '{named_ralph_explorer: (map(.agents.explorer)|add),
        named_ralph_tester: (map(.agents.tester)|add),
        named_ralph_reviewer: (map(.agents.reviewer)|add),
        named_ralph_architect: (map(.agents.architect)|add),
        general_purpose: (map(.agents.generic)|add),
        total_tasks_started: (map(.agents.tasks_started)|add)}' "$TMP" |
    jq -r 'to_entries | map("    \(.key): \(.value)") | .[]'

echo ""
echo "  MCP calls total (across all loops):"
jq -s '{tapps_mcp: (map(.mcp.tapps)|add), tapps_brain: (map(.mcp.brain)|add),
        docs_mcp: (map(.mcp.docs)|add), linear: (map(.mcp.linear)|add),
        context7: (map(.mcp.context7)|add)}' "$TMP" |
    jq -r 'to_entries | map("    \(.key): \(.value)") | .[]'

echo ""
# Cost trend: first half vs second half (signals context-growth blowup)
FIRST_AVG=$(jq -s 'sort_by(.time) | .[0:(length/2|floor)] | if length==0 then 0 else (map(.cost_usd)|add/length) end' "$TMP")
SECOND_AVG=$(jq -s 'sort_by(.time) | .[(length/2|floor):] | if length==0 then 0 else (map(.cost_usd)|add/length) end' "$TMP")
printf "  Cost trend:        first half avg=\$%.2f  ·  second half avg=\$%.2f\n" "$FIRST_AVG" "$SECOND_AVG"

# Worst-value: single-ticket loops with cost > 2x the average.
echo ""
echo "  Worst-value loops (> 2x avg cost, ≤ 1 ticket shipped):"
jq -s --argjson avg "$AVG_COST" \
    '.[] | select(.cost_usd > 2*$avg and .tasks <= 1) | "    \(.time)  $\(.cost_usd|.*100|round|./100)  \(.work)  tickets=\(.tickets // "-")"' "$TMP" 2>/dev/null |
    sed 's/^"//; s/"$//'
