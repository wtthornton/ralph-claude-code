#!/bin/bash
# lib/skill_retro.sh — SKILLS-INJECT-5/6: Skill friction detection and retro apply.
#
# SKILLS-INJECT-5: Reads .ralph/status.json and stream logs after each loop,
# identifies friction signals, emits a JSON friction report.
#
# SKILLS-INJECT-6: Advisory or auto-tune mode — adds/removes one skill per loop
# based on the friction report. Checksum-guard prevents overwriting user-modified skills.
#
# Configuration:
#   RALPH_SKILL_AUTO_TUNE=false   — When true, applies skill changes automatically
#   RALPH_SKILL_RETRO_WINDOW=5    — Number of recent loops to examine for patterns

[[ -n "${SKILL_RETRO_SOURCED:-}" ]] && return 0
SKILL_RETRO_SOURCED=1

RALPH_SKILL_AUTO_TUNE="${RALPH_SKILL_AUTO_TUNE:-false}"
RALPH_SKILL_RETRO_WINDOW="${RALPH_SKILL_RETRO_WINDOW:-5}"
RALPH_SKILL_REDETECT_INTERVAL="${RALPH_SKILL_REDETECT_INTERVAL:-10}"

# ---------------------------------------------------------------------------
# Friction signal detection (SKILLS-INJECT-5)
# ---------------------------------------------------------------------------

# skill_retro_detect_friction — Analyze recent loop state and emit a JSON report.
#
# Reads:
#   $RALPH_DIR/status.json         — current loop status
#   $RALPH_DIR/logs/ralph.log      — loop history (RALPH_STATUS blocks)
#   $RALPH_DIR/logs/claude_output_*.log — stream logs (tool errors)
#
# Emits JSON to stdout:
#   {
#     "timestamp":  "...",
#     "loop_count": N,
#     "has_friction": true|false,
#     "friction_signals": [
#       { "type": "...", "severity": "high|medium|low", ... }
#     ],
#     "recommended_skills": ["skill-name", ...]
#   }
#
skill_retro_detect_friction() {
    local ralph_dir="${RALPH_DIR:-.ralph}"
    local status_file="$ralph_dir/status.json"
    local log_file="$ralph_dir/logs/ralph.log"

    local timestamp loop_count=0
    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    local -a signals=()
    local -a recommended=()

    # --- Read current status.json ---
    local has_permission_denials="false"
    local permission_denial_count=0
    local tasks_completed=0
    local files_modified=0
    local work_type="UNKNOWN"
    local tests_status=""

    if [[ -f "$status_file" ]] && command -v jq &>/dev/null; then
        has_permission_denials=$(jq -r '.has_permission_denials // false' "$status_file" 2>/dev/null || echo "false")
        permission_denial_count=$(jq -r '.permission_denial_count // 0' "$status_file" 2>/dev/null | tr -cd '0-9' || echo "0")
        tasks_completed=$(jq -r '.tasks_completed // 0' "$status_file" 2>/dev/null | tr -cd '0-9' || echo "0")
        files_modified=$(jq -r '.files_modified // 0' "$status_file" 2>/dev/null | tr -cd '0-9' || echo "0")
        work_type=$(jq -r '.work_type // "UNKNOWN"' "$status_file" 2>/dev/null || echo "UNKNOWN")
        loop_count=$(jq -r '.loop_count // 0' "$status_file" 2>/dev/null | tr -cd '0-9' || echo "0")
    fi

    # --- Signal: permission denials ---
    if [[ "$has_permission_denials" == "true" ]] || [[ "$permission_denial_count" -gt 0 ]]; then
        signals+=("{\"type\":\"permission_denials\",\"severity\":\"high\",\"count\":${permission_denial_count}}")
        recommended+=("agentic-engineering")
    fi

    # --- Signal: no progress this loop ---
    if [[ "$tasks_completed" -eq 0 && "$files_modified" -eq 0 && "$loop_count" -gt 0 ]]; then
        signals+=("{\"type\":\"no_progress\",\"severity\":\"medium\",\"tasks_completed\":0,\"files_modified\":0}")
    fi

    # --- Signal: repeated no-progress across recent loops (stall) ---
    local stall_count=0
    if [[ -f "$log_file" ]]; then
        stall_count=$(grep -c 'TASKS_COMPLETED_THIS_LOOP: 0' "$log_file" 2>/dev/null \
            | tr -cd '0-9') || stall_count=0
        # Only count the last N loops worth of the log
        local recent_stalls
        recent_stalls=$(tail -n $((RALPH_SKILL_RETRO_WINDOW * 50)) "$log_file" 2>/dev/null \
            | grep -c 'TASKS_COMPLETED_THIS_LOOP: 0' 2>/dev/null | tr -cd '0-9') || recent_stalls=0
        if [[ "${recent_stalls:-0}" -ge 3 ]]; then
            signals+=("{\"type\":\"repeated_stall\",\"severity\":\"high\",\"loops_stalled\":${recent_stalls}}")
            recommended+=("search-first")
        fi
    fi

    # --- Signal: repeated test failures ---
    if [[ -f "$log_file" ]]; then
        local test_failures
        test_failures=$(tail -n $((RALPH_SKILL_RETRO_WINDOW * 50)) "$log_file" 2>/dev/null \
            | grep -c 'TESTS_STATUS: FAILING' 2>/dev/null | tr -cd '0-9') || test_failures=0
        if [[ "${test_failures:-0}" -ge 2 ]]; then
            signals+=("{\"type\":\"repeated_test_failures\",\"severity\":\"medium\",\"count\":${test_failures}}")
            recommended+=("tdd-workflow")
        fi
    fi

    # --- Signal: tool errors in stream logs ---
    local tool_error_count=0
    local latest_output_log
    latest_output_log=$(ls -t "$ralph_dir/logs/claude_output_"*.log 2>/dev/null | head -1)
    if [[ -n "$latest_output_log" && -f "$latest_output_log" ]]; then
        tool_error_count=$(grep -c '"is_error":true' "$latest_output_log" 2>/dev/null \
            | tr -cd '0-9') || tool_error_count=0
        if [[ "${tool_error_count:-0}" -ge 3 ]]; then
            signals+=("{\"type\":\"repeated_tool_errors\",\"severity\":\"medium\",\"count\":${tool_error_count}}")
        fi
    fi

    # --- Signal: UNKNOWN work type with no progress (confused loop, only meaningful after first loop) ---
    if [[ "$work_type" == "UNKNOWN" && "$tasks_completed" -eq 0 && "$files_modified" -eq 0 && "$loop_count" -gt 0 ]]; then
        signals+=("{\"type\":\"confused_work_type\",\"severity\":\"low\"}")
        recommended+=("agentic-engineering")
    fi

    # --- Deduplicate recommended skills ---
    local -a unique_recommended=()
    local r
    for r in "${recommended[@]}"; do
        local found=false
        local existing
        for existing in "${unique_recommended[@]:-}"; do
            [[ "$existing" == "$r" ]] && found=true && break
        done
        [[ "$found" == "false" ]] && unique_recommended+=("$r")
    done

    # --- Build JSON output ---
    local has_friction="false"
    [[ ${#signals[@]} -gt 0 ]] && has_friction="true"

    local signals_json="[]"
    if [[ ${#signals[@]} -gt 0 ]]; then
        signals_json="[$(IFS=,; echo "${signals[*]}")]"
    fi

    local recommended_json="[]"
    if [[ ${#unique_recommended[@]} -gt 0 ]]; then
        recommended_json=$(printf '"%s",' "${unique_recommended[@]}")
        recommended_json="[${recommended_json%,}]"
    fi

    jq -n \
        --arg ts "$timestamp" \
        --argjson lc "${loop_count:-0}" \
        --argjson hf "$has_friction" \
        --argjson sigs "$signals_json" \
        --argjson rec "$recommended_json" \
        '{timestamp:$ts, loop_count:$lc, has_friction:$hf, friction_signals:$sigs, recommended_skills:$rec}'
}

# ---------------------------------------------------------------------------
# Retro apply — advisory or auto-tune (SKILLS-INJECT-6)
# ---------------------------------------------------------------------------

# skill_retro_apply — Apply skill changes based on a friction report.
#
# Parameters:
#   $1 (friction_json)   — JSON string from skill_retro_detect_friction
#   $2 (target_dir)      — target project's .claude/skills dir (default: .claude/skills)
#   $3 (global_dir)      — global skills source (default: ~/.claude/skills)
#   $4 (ralph_version)   — version string for sidecar (default: $RALPH_VERSION)
#
# Behavior:
#   - Advisory mode (RALPH_SKILL_AUTO_TUNE=false): logs recommendations, no writes
#   - Auto-tune mode (RALPH_SKILL_AUTO_TUNE=true): adds ≤1 skill per call
#
# Returns: 0 always (non-fatal)
#
skill_retro_apply() {
    local friction_json="${1:-{}}"
    local target_dir="${2:-.claude/skills}"
    local global_dir="${3:-$HOME/.claude/skills}"
    local ralph_version="${4:-${RALPH_VERSION:-unknown}}"

    if ! command -v jq &>/dev/null; then
        echo "WARN: jq not available — skill_retro_apply skipped" >&2
        return 0
    fi

    local has_friction
    has_friction=$(echo "$friction_json" | jq -r '.has_friction // false')
    [[ "$has_friction" != "true" ]] && return 0

    local recommended
    recommended=$(echo "$friction_json" | jq -r '.recommended_skills[]?' 2>/dev/null)

    if [[ -z "$recommended" ]]; then
        return 0
    fi

    if [[ "$RALPH_SKILL_AUTO_TUNE" != "true" ]]; then
        echo "INFO: skill-retro advisory — recommended skills: $(echo "$recommended" | tr '\n' ' ')" >&2
        return 0
    fi

    # Auto-tune: install at most one skill per call (the first uninstalled recommended skill)
    local _lib_dir
    _lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local skills_install_lib="$_lib_dir/skills_install.sh"
    if [[ ! -f "$skills_install_lib" ]]; then
        echo "WARN: skills_install.sh not found — auto-tune skipped" >&2
        return 0
    fi
    # shellcheck disable=SC1090
    source "$skills_install_lib"

    mkdir -p "$target_dir"

    local skill
    while IFS= read -r skill; do
        [[ -z "$skill" ]] && continue
        local src="$global_dir/$skill"
        local dest="$target_dir/$skill"

        # Only install if not already present with sidecar
        if [[ -d "$dest" ]]; then
            continue
        fi

        if [[ -d "$src" ]]; then
            if skills_install_one "$src" "$dest" "$ralph_version"; then
                echo "INFO: skill-retro auto-installed: $skill" >&2
            fi
            # One skill per call
            return 0
        fi
    done <<< "$recommended"

    return 0
}

# ---------------------------------------------------------------------------
# Periodic re-detection — SKILLS-INJECT-7
# ---------------------------------------------------------------------------

# skill_retro_periodic_reconcile — Re-detect Tier A skills every N loops.
#
# Called from the main ralph loop. Only runs when loop_count is a multiple of
# RALPH_SKILL_REDETECT_INTERVAL (default 10). Detects project signals, installs
# any newly-applicable skills that aren't already present.
#
# Parameters:
#   $1 (loop_count)   — current loop count (integer)
#   $2 (project_dir)  — project root (default: $PWD)
#   $3 (global_dir)   — global skills source (default: ~/.claude/skills)
#
skill_retro_periodic_reconcile() {
    local loop_count="${1:-0}"
    local project_dir="${2:-$PWD}"
    local global_dir="${3:-$HOME/.claude/skills}"

    # Gate: only run at multiples of the interval (and never at loop 0)
    [[ "$loop_count" -gt 0 ]] || return 0
    (( loop_count % RALPH_SKILL_REDETECT_INTERVAL == 0 )) || return 0

    local _lib_dir
    _lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    # Lazily load skills_install.sh — needed for install_one
    if [[ -z "${SKILLS_INSTALL_SOURCED:-}" ]] && [[ -f "$_lib_dir/skills_install.sh" ]]; then
        # shellcheck disable=SC1090
        source "$_lib_dir/skills_install.sh"
    fi

    # Lazily load enable_core.sh — needed for detect_tier_a_skills
    if ! declare -f detect_tier_a_skills &>/dev/null; then
        if [[ -f "$_lib_dir/enable_core.sh" ]]; then
            # shellcheck disable=SC1090
            source "$_lib_dir/enable_core.sh"
        else
            return 0
        fi
    fi

    local target_dir="$project_dir/.claude/skills"
    local ralph_version="${RALPH_VERSION:-unknown}"
    local -a installed=()

    local line skill src dest
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        skill="$line"
        src="$global_dir/$skill"
        dest="$target_dir/$skill"

        # Skip if already installed (sidecar present) or user-authored (dest exists, no sidecar)
        [[ -d "$dest" ]] && continue
        [[ -d "$src" ]] || continue

        mkdir -p "$target_dir"
        if declare -f skills_install_one &>/dev/null; then
            if skills_install_one "$src" "$dest" "$ralph_version"; then
                installed+=("$skill")
            fi
        fi
    done < <(cd "$project_dir" && detect_tier_a_skills 2>/dev/null)

    if [[ ${#installed[@]} -gt 0 ]]; then
        if declare -f log_status &>/dev/null; then
            log_status "INFO" "skill-retro reconcile (loop $loop_count): installed ${installed[*]}"
        else
            echo "INFO: skill-retro reconcile (loop $loop_count): installed ${installed[*]}" >&2
        fi
        # SKILLS-INJECT-8: emit skill_added metric for each reconcile-installed skill
        local s
        for s in "${installed[@]}"; do
            declare -f record_skill_metric &>/dev/null && \
                record_skill_metric "skill_added" "$s" "$project_dir" 2>/dev/null || true
        done
    fi

    return 0
}
