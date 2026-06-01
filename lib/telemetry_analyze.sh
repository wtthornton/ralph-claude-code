#!/bin/bash
# =============================================================================
# lib/telemetry_analyze.sh — Closed-loop telemetry analyzer ("ralph --analyze")
#
# Story TELEMETRY-HARVESTER (docs/specs/story-telemetry-harvester.md).
#
# Reads the harness's CONTROL-PATH telemetry — the JSONL/state files that are
# each consumed by exactly one internal decision and never surfaced to a human —
# and prints prioritized [OK]/[WARN]/[SKIP] findings, with an optional --json.
#
# Read-only: never writes under .ralph/. Always exits 0 (advisory, never gates).
#
# Deliberately does NOT duplicate `ralph --stats` (run counts, work-type, brain,
# skills) — that reads .ralph/metrics/*.jsonl; the harvester reads the six
# control-path artifacts below:
#   .coordinator_timings.jsonl, .coordinator_phase_timings.jsonl,
#   .model_routing.jsonl, .invocation_latencies, status.json cache fields,
#   .qa_failures.json
#
# The p95 rules reuse the PR #54/#58 right-censor (exit_code 124 → ×1.5) +
# ceiling-index method so the harvester's percentile agrees with the value the
# harness actually enforces.
# =============================================================================

# Findings accumulator. Each element is a complete JSON object string.
_TA_FINDINGS=()

# _ta_add SEVERITY RULE VALUE THRESHOLD DETAIL HINT
# Build one finding object (jq handles all string escaping) and stash it.
_ta_add() {
    local severity="$1" rule="$2" value="$3" threshold="$4" detail="$5" hint="$6"
    local obj
    obj=$(jq -nc \
        --arg sev "$severity" --arg rule "$rule" --arg val "$value" \
        --arg thr "$threshold" --arg det "$detail" --arg hint "$hint" \
        '{rule:$rule, severity:$sev, value:$val, threshold:$thr, detail:$det, hint:$hint}' \
        2>/dev/null) || return 0
    _TA_FINDINGS+=("$obj")
}

# _ta_percentile <jsonl_file>
# Censored p95 (seconds) of a latency JSONL file whose lines carry
# .duration_seconds and .exit_code. Mirrors ralph_compute_adaptive_timeout /
# ralph_compute_coordinator_timeout exactly: censored (exit_code 124) samples
# inflated ×1.5, ceiling p95 index. Echoes the integer, or nothing if no usable
# samples.
_ta_percentile() {
    local file="$1"
    [[ -f "$file" && -s "$file" ]] || return 0
    # Collect the usable values FIRST, then index into them. Deriving the index
    # from `wc -l` (every line) instead of the count of values that survive the
    # `grep -E '^[0-9]+$'` filter overflows the index whenever any line lacks
    # .duration_seconds (jq emits nothing for `empty`), so `sed` prints nothing
    # and the whole rule silently degrades to SKIP despite ample timing data.
    local vals
    vals=$(jq -r '(if (.exit_code // 0) == 124
            then ((.duration_seconds // 0) * 3 / 2 | floor)
            else (.duration_seconds // empty) end)' "$file" 2>/dev/null \
        | grep -E '^[0-9]+$' \
        | sort -n)
    [[ -n "$vals" ]] || return 0
    local count
    count=$(printf '%s\n' "$vals" | wc -l | tr -d '[:space:]')
    [[ "${count:-0}" -ge 1 ]] || return 0
    local idx=$(( (count * 95 + 99) / 100 ))
    [[ "$idx" -lt 1 ]] && idx=1
    [[ "$idx" -gt "$count" ]] && idx=$count
    printf '%s\n' "$vals" | sed -n "${idx}p"
}

# Resolve the enforced budget by delegating to the harness functions when this
# lib is sourced inside ralph_loop.sh. In isolation (BATS) the functions are
# absent and these echo nothing, so the timeout rules degrade to an INFO that
# reports the p95 without a ratio. Tests stub the functions to exercise OK/WARN.
_ta_budget_coordinator_seconds() {
    declare -F ralph_compute_coordinator_timeout >/dev/null 2>&1 || return 0
    local v; v=$(ralph_compute_coordinator_timeout 2>/dev/null)
    [[ "$v" =~ ^[0-9]+$ ]] && echo "$v"
}
_ta_budget_mainloop_seconds() {
    declare -F ralph_compute_adaptive_timeout >/dev/null 2>&1 || return 0
    local m; m=$(ralph_compute_adaptive_timeout 2>/dev/null)
    [[ "$m" =~ ^[0-9]+$ ]] && echo $(( m * 60 ))
}

# --- Rule 1: coordinator timeout health -------------------------------------
_ta_rule_coordinator_timeout() {
    local dir="$1" file="$1/.coordinator_timings.jsonl"
    if [[ ! -s "$file" ]]; then
        _ta_add SKIP coordinator_timeout "" "" "no coordinator timing samples yet" ""
        return 0
    fi
    local p95; p95=$(_ta_percentile "$file")
    if [[ -z "$p95" ]]; then
        _ta_add SKIP coordinator_timeout "" "" "no usable coordinator timing samples" ""
        return 0
    fi
    local budget; budget=$(_ta_budget_coordinator_seconds)
    if [[ -z "$budget" ]]; then
        _ta_add INFO coordinator_timeout "$p95" "" \
            "coordinator censored-p95=${p95}s; enforced adaptive budget unavailable in this context" \
            "run inside the harness to compare against the live budget"
        return 0
    fi
    # WARN when p95 has reached 90% of the budget — timeouts are imminent.
    if [[ "$p95" -ge $(( budget * 9 / 10 )) ]]; then
        _ta_add WARN coordinator_timeout "$p95" "$budget" \
            "coordinator censored-p95=${p95}s ≥ 90% of adaptive budget ${budget}s — timeouts imminent" \
            "raise RALPH_COORDINATOR_TIMEOUT_MIN_SECONDS, or investigate slow brief synthesis (see coordinator_phase finding)"
    else
        _ta_add OK coordinator_timeout "$p95" "$budget" \
            "coordinator censored-p95=${p95}s vs adaptive budget ${budget}s (headroom $(( budget - p95 ))s)" ""
    fi
}

# --- Rule 2: main-loop timeout health ---------------------------------------
_ta_rule_mainloop_timeout() {
    local dir="$1" file="$1/.invocation_latencies"
    if [[ ! -s "$file" ]]; then
        _ta_add SKIP mainloop_timeout "" "" "no main-loop latency samples yet" ""
        return 0
    fi
    local p95; p95=$(_ta_percentile "$file")
    if [[ -z "$p95" ]]; then
        _ta_add SKIP mainloop_timeout "" "" "no usable main-loop latency samples" ""
        return 0
    fi
    local budget; budget=$(_ta_budget_mainloop_seconds)
    if [[ -z "$budget" ]]; then
        _ta_add INFO mainloop_timeout "$p95" "" \
            "main-loop censored-p95=${p95}s; enforced adaptive budget unavailable in this context" \
            "run inside the harness to compare against the live budget"
        return 0
    fi
    if [[ "$p95" -ge $(( budget * 9 / 10 )) ]]; then
        _ta_add WARN mainloop_timeout "$p95" "$budget" \
            "main-loop censored-p95=${p95}s ≥ 90% of adaptive budget ${budget}s — timeouts imminent" \
            "raise ADAPTIVE_TIMEOUT_MIN_MINUTES / CLAUDE_TIMEOUT_MINUTES, or split large tasks"
    else
        _ta_add OK mainloop_timeout "$p95" "$budget" \
            "main-loop censored-p95=${p95}s vs adaptive budget ${budget}s (headroom $(( budget - p95 ))s)" ""
    fi
}

# --- Rule 3: prompt-cache hit-rate ------------------------------------------
# Matches ralph_monitor.sh:480 exactly:
#   hit = session_cache_read / (session_cache_read + session_cache_create + session_input)
_ta_rule_cache_hit_rate() {
    local dir="$1" file="$1/status.json"
    if [[ ! -s "$file" ]]; then
        _ta_add SKIP cache_hit_rate "" "" "no status.json yet" ""
        return 0
    fi
    local r c i
    r=$(jq -r '.session_cache_read_tokens // 0' "$file" 2>/dev/null | tr -cd '0-9'); r=${r:-0}
    c=$(jq -r '.session_cache_create_tokens // 0' "$file" 2>/dev/null | tr -cd '0-9'); c=${c:-0}
    i=$(jq -r '.session_input_tokens // 0' "$file" 2>/dev/null | tr -cd '0-9'); i=${i:-0}
    local d=$(( r + c + i ))
    if [[ "$d" -eq 0 ]]; then
        _ta_add SKIP cache_hit_rate "" "" "no cache token data in status.json yet" ""
        return 0
    fi
    local pct; pct=$(awk -v r="$r" -v d="$d" 'BEGIN{printf "%.0f", r/d*100}')
    local thr="${RALPH_CACHE_HIT_RATE_WARN:-30}"
    if [[ "$pct" -lt "$thr" ]]; then
        _ta_add WARN cache_hit_rate "$pct" "$thr" \
            "session cache hit-rate ${pct}% < threshold ${thr}% (read=${r}, create=${c}, in=${i})" \
            "suspect prompt-prefix churn: mid-session CLAUDE.md/agent/skill edits, --resume failures, or per-loop content injected high in the prompt"
    else
        _ta_add OK cache_hit_rate "$pct" "$thr" \
            "session cache hit-rate ${pct}% ≥ threshold ${thr}% (read=${r}, create=${c}, in=${i})" ""
    fi
}

# --- Rule 4: Opus QA-failure escalation cluster -----------------------------
_ta_rule_opus_escalation() {
    local dir="$1" file="$1/.model_routing.jsonl"
    local window="${RALPH_ANALYZE_ROUTING_WINDOW:-200}"
    if [[ ! -s "$file" ]]; then
        _ta_add SKIP opus_escalation "" "" "no model-routing decisions yet" ""
        return 0
    fi
    local esc
    esc=$(tail -n "$window" "$file" 2>/dev/null \
        | jq -r 'select(.reason == "qa_failure_escalation") | 1' 2>/dev/null \
        | grep -c '1' | tr -cd '0-9'); esc=${esc:-0}
    if [[ "$esc" -eq 0 ]]; then
        _ta_add OK opus_escalation "0" "" \
            "no Opus QA-failure escalations in last ${window} routing decisions" ""
        return 0
    fi
    # Name the stuck issues (failure count >= 3 is the escalation trigger).
    local qa="$dir/.qa_failures.json" stuck=""
    if [[ -s "$qa" ]]; then
        stuck=$(jq -r 'to_entries | map(select(.value >= 3) | .key) | join(", ")' "$qa" 2>/dev/null)
    fi
    [[ -z "$stuck" ]] && stuck="(none currently at >=3)"
    _ta_add INFO opus_escalation "$esc" "3" \
        "Opus escalated ${esc}× in last ${window} routing decisions; stuck issues: ${stuck}" \
        "review the failure cluster for: ${stuck}"
}

# --- Rule 5: coordinator phase attribution (gates OPERATOR-NOTES #2) ---------
_ta_rule_coordinator_phase() {
    local dir="$1" file="$1/.coordinator_phase_timings.jsonl"
    if [[ ! -s "$file" ]]; then
        _ta_add SKIP coordinator_phase "" "" "no coordinator phase samples yet" ""
        return 0
    fi
    local total synth recall
    total=$(wc -l < "$file" 2>/dev/null | tr -cd '0-9'); total=${total:-0}
    synth=$(jq -r 'select(.dominant_phase == "synthesis") | 1' "$file" 2>/dev/null | grep -c '1' | tr -cd '0-9'); synth=${synth:-0}
    recall=$(jq -r 'select(.brain_recall_invoked == true) | 1' "$file" 2>/dev/null | grep -c '1' | tr -cd '0-9'); recall=${recall:-0}
    if [[ "$total" -eq 0 ]]; then
        _ta_add SKIP coordinator_phase "" "" "no usable coordinator phase samples" ""
        return 0
    fi
    local hint=""
    # If synthesis dominates and brain recall is rare, the coordinator→Haiku
    # trial (OPERATOR-NOTES #2) is supported: the cost is synthesis, not recall.
    if [[ "$synth" -ge $(( total / 2 )) ]]; then
        hint="synthesis is the dominant cost — supports the coordinator→Haiku trial (OPERATOR-NOTES #2); compare wall-clock + brief accuracy before/after"
    fi
    _ta_add INFO coordinator_phase "${synth}/${total}" "" \
        "coordinator phases: ${synth}/${total} synthesis-dominated, brain_recall invoked in ${recall}/${total}" \
        "$hint"
}

# --- Renderers --------------------------------------------------------------
_ta_render_human() {
    local sev rule detail hint
    echo "Ralph Telemetry Analysis"
    echo "========================"
    echo ""
    local f
    for f in "${_TA_FINDINGS[@]}"; do
        sev=$(jq -r '.severity' <<<"$f")
        rule=$(jq -r '.rule' <<<"$f")
        detail=$(jq -r '.detail' <<<"$f")
        hint=$(jq -r '.hint' <<<"$f")
        echo "  [${sev}] ${rule}: ${detail}"
        [[ -n "$hint" && "$hint" != "null" ]] && echo "         ↳ ${hint}"
    done
    echo ""
}

_ta_render_json() {
    local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    if [[ "${#_TA_FINDINGS[@]}" -eq 0 ]]; then
        jq -nc --arg ts "$ts" '{generated_at:$ts, findings:[]}'
        return 0
    fi
    printf '%s\n' "${_TA_FINDINGS[@]}" \
        | jq -s --arg ts "$ts" '{generated_at:$ts, findings:.}'
}

# ralph_telemetry_analyze [--json]
# Public entry point wired to `ralph --analyze`. Always returns 0.
ralph_telemetry_analyze() {
    local as_json="false"
    [[ "${1:-}" == "--json" ]] && as_json="true"

    local dir="${RALPH_DIR:-.ralph}"
    _TA_FINDINGS=()

    if [[ ! -d "$dir" ]]; then
        if [[ "$as_json" == "true" ]]; then
            jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                '{generated_at:$ts, findings:[{rule:"setup", severity:"SKIP", value:"", threshold:"", detail:"no .ralph/ directory in current path", hint:"run from a Ralph-managed project root"}]}'
        else
            echo "Ralph Telemetry Analysis"
            echo "========================"
            echo ""
            echo "  [SKIP] setup: no .ralph/ directory in $(pwd) — run from a Ralph-managed project root"
            echo ""
        fi
        return 0
    fi

    _ta_rule_coordinator_timeout "$dir"
    _ta_rule_mainloop_timeout "$dir"
    _ta_rule_cache_hit_rate "$dir"
    _ta_rule_opus_escalation "$dir"
    _ta_rule_coordinator_phase "$dir"

    if [[ "$as_json" == "true" ]]; then
        _ta_render_json
    else
        _ta_render_human
    fi
    return 0
}
