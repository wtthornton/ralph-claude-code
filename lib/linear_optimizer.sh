#!/bin/bash

# lib/linear_optimizer.sh — Linear task cache-locality optimizer (LINOPT-2 / TAP-591)
#
# Scores open Linear issues by module overlap with the last-completed file set
# and writes the highest-scoring issue ID to .ralph/.linear_next_issue.
#
# Entry point: linear_optimizer_run
# Called at session start by ralph_loop.sh when RALPH_TASK_SOURCE=linear.
#
# Guards (no-op + return 0):
#   RALPH_TASK_SOURCE != "linear"
#   RALPH_NO_LINEAR_OPTIMIZE == "true"
#   RALPH_LINEAR_PROJECT unset
#   LINEAR_API_KEY unset (push-mode — Claude picks tasks via Linear MCP)
#
# Output:
#   .ralph/.linear_next_issue  — first line: issue identifier (e.g. "TAP-591")
#                                optional comment: "# scored: 0.6543"
#
# Configuration:
#   RALPH_NO_LINEAR_OPTIMIZE=true     — disable entirely (no API calls, no write)
#   RALPH_OPTIMIZER_FETCH_LIMIT=20    — max issues to fetch and score
#   RALPH_OPTIMIZER_EXPLORER_MAX=3    — max explorer fallback calls per session
#   RALPH_NO_DEP_DEMOTE=true          — skip TAP-592 import-graph demotion phase

RALPH_DIR="${RALPH_DIR:-.ralph}"
RALPH_OPTIMIZER_FETCH_LIMIT="${RALPH_OPTIMIZER_FETCH_LIMIT:-20}"
RALPH_OPTIMIZER_EXPLORER_MAX="${RALPH_OPTIMIZER_EXPLORER_MAX:-3}"

_OPTIMIZER_EXPLORER_CALLS=0
_OPTIMIZER_CACHE_FILE="${RALPH_DIR}/.linear_optimizer_cache.json"

# =============================================================================
# Internal helpers
# =============================================================================

# _optimizer_extract_paths_from_body — Extract likely file paths from issue body.
# Conservative: extension required, node_modules/.git noise filtered.
# Stdout: one path per line, deduplicated and sorted.
_optimizer_extract_paths_from_body() {
    local body="$1"
    printf '%s\n' "$body" \
        | grep -oE '([a-zA-Z0-9_./-]+/)?[a-zA-Z0-9_-]+\.(py|js|ts|tsx|jsx|sh|md|json|yaml|yml|toml|sql|bats)' \
        | grep -v '^node_modules/' \
        | grep -v '^\.git/' \
        | sort -u
}

# _optimizer_score_jaccard — Jaccard(A, B) + shared-parent-dir bonus.
# Args:
#   $1 file containing set A (one path per line)
#   $2 file containing set B (one path per line)
# Stdout: score as "N.NNNN" (range 0.0 .. 1.3)
_optimizer_score_jaccard() {
    local file_a="$1"
    local file_b="$2"

    [[ ! -s "$file_a" || ! -s "$file_b" ]] && { printf '0.0000\n'; return 0; }

    awk '
    NR == FNR { A[$0] = 1; next }
    {
        B[$0] = 1
        if (A[$0]) inter++
    }
    END {
        union_sz = length(A) + length(B) - inter
        if (union_sz == 0) { print "0.0000"; exit }
        jaccard = inter / union_sz
        n_max = (length(A) > length(B)) ? length(A) : length(B)
        bonus = (n_max > 0) ? 0.3 * (inter / n_max) : 0
        printf "%.4f\n", jaccard + bonus
    }
    ' "$file_a" "$file_b"
}

# _optimizer_invoke_explorer — Wrapper for the ralph-explorer (Haiku) call.
# Isolated so tests can override it without a real Claude CLI.
# Args:
#   $1 prompt text
# Stdout: one path per line (may be empty on failure).
_optimizer_invoke_explorer() {
    local prompt="$1"
    local model="${RALPH_OPTIMIZER_EXPLORER_MODEL:-claude-haiku-4-5-20251001}"
    claude --model "$model" --max-turns 1 -p "$prompt" 2>/dev/null \
        | grep -E '[a-zA-Z0-9_/-]+\.[a-zA-Z]+' \
        | head -20 \
        || true
}

# _optimizer_explorer_resolve — Ask ralph-explorer for likely file paths.
# Respects the session cap RALPH_OPTIMIZER_EXPLORER_MAX.
# Caches results in .ralph/.linear_optimizer_cache.json (key: id:updatedAt).
# Stdout: one path per line (may be empty).
_optimizer_explorer_resolve() {
    local issue_id="$1"
    local updated_at="$2"
    local title="$3"
    local body="$4"

    local cache_key="${issue_id}:${updated_at}"

    # Check persistent cache first
    if [[ -f "$_OPTIMIZER_CACHE_FILE" ]]; then
        local cached
        cached=$(jq -r --arg k "$cache_key" '.[$k] // empty' \
            "$_OPTIMIZER_CACHE_FILE" 2>/dev/null || true)
        if [[ -n "$cached" ]]; then
            printf '%s\n' "$cached"
            return 0
        fi
    fi

    # Session cap
    if (( _OPTIMIZER_EXPLORER_CALLS >= RALPH_OPTIMIZER_EXPLORER_MAX )); then
        return 0
    fi
    _OPTIMIZER_EXPLORER_CALLS=$(( _OPTIMIZER_EXPLORER_CALLS + 1 ))

    local prompt="Given this Linear issue title and body, list the likely file paths it would touch. Output one path per line, no commentary. Only output paths with file extensions. Title: ${title} Body: ${body:0:500}"

    local result
    result=$(_optimizer_invoke_explorer "$prompt" 2>/dev/null || true)

    # Persist to cache
    if [[ -n "$result" ]]; then
        local existing='{}'
        [[ -f "$_OPTIMIZER_CACHE_FILE" ]] && \
            existing=$(cat "$_OPTIMIZER_CACHE_FILE" 2>/dev/null || echo '{}')
        local cache_tmp="${_OPTIMIZER_CACHE_FILE}.tmp.$$"
        if jq --arg k "$cache_key" --arg v "$result" '. + {($k): $v}' \
                <<< "$existing" > "$cache_tmp" 2>/dev/null; then
            mv -f "$cache_tmp" "$_OPTIMIZER_CACHE_FILE" 2>/dev/null || \
                rm -f "$cache_tmp" 2>/dev/null
        else
            rm -f "$cache_tmp" 2>/dev/null
        fi
    fi

    printf '%s\n' "$result"
    return 0
}

# _optimizer_select_winner — Phase-2 dependency-aware selection (LINOPT-3 / TAP-592).
#
# Reads from caller-scoped arrays:
#   CAND_IDS[]         identifiers in input order
#   CAND_SCORES[]      Jaccard scores
#   CAND_PRIORITIES[]  sort_priority (0=Urgent→99=None)
#   CAND_FILES_TMP[]   tempfile per candidate holding its path set (one per line)
#
# Writes the picked identifier and score into two caller-named variables via
# bash nameref. Cleans up CAND_FILES_TMP[] regardless of outcome.
#
# Args: $1 = name of caller's "best_id" variable, $2 = name of "best_score" var.
_optimizer_select_winner() {
    local -n _out_id="$1"
    local -n _out_score="$2"
    _out_id=""
    _out_score="0.0000"

    local n=${#CAND_IDS[@]}
    (( n == 0 )) && return 1

    # Build sorted index list (score DESC, priority ASC). awk emits the
    # negated-score key so ascending numeric sort puts the highest score first;
    # using `sort -g` (general numeric) is essential because lexicographic
    # comparison of "%012.6f -0" produces "-0000.000000" with a leading minus
    # that sorts BEFORE positive negations like "-0001.300000".
    local sorted_idx
    sorted_idx=$(
        local i
        for (( i=0; i<n; i++ )); do
            awk -v s="${CAND_SCORES[$i]}" -v p="${CAND_PRIORITIES[$i]}" -v i="$i" \
                'BEGIN{printf "%.6f|%02d|%d\n", -s, p, i}'
        done | sort -t'|' -k1,1g -k2,2n -k3,3n | awk -F'|' '{print $3}'
    )

    # Phase-2 dependency check (only when the import graph cache exists and the
    # opt-out flag is not set). Build "files owned by any open candidate" map.
    local cache_file="${RALPH_DIR}/.import_graph.json"
    local do_dep_check=true
    [[ "${RALPH_NO_DEP_DEMOTE:-false}" == "true" ]] && do_dep_check=false
    [[ ! -f "$cache_file" ]] && {
        do_dep_check=false
        echo "linear_optimizer: import graph cache missing — skipping dep demotion" >&2
    }
    if ! declare -F import_graph_predecessors >/dev/null 2>&1; then
        do_dep_check=false
    fi

    declare -A FILES_OWNED_BY_OPEN
    if [[ "$do_dep_check" == "true" ]]; then
        local i f
        for (( i=0; i<n; i++ )); do
            local id="${CAND_IDS[$i]}"
            local files_tmp="${CAND_FILES_TMP[$i]}"
            [[ -s "$files_tmp" ]] || continue
            while IFS= read -r f; do
                [[ -z "$f" ]] && continue
                # First-write wins — multiple candidates "owning" the same file is
                # a corner case; map.length >= 1 is enough to trigger demotion.
                FILES_OWNED_BY_OPEN["$f"]="${FILES_OWNED_BY_OPEN[$f]:-$id}"
            done < "$files_tmp"
        done
    fi

    # Iterate sorted candidates. First clean (zero open-deps) wins. Track the
    # fewest-deps fallback so we always emit a hint even when nothing is clean.
    local best_idx="" fallback_idx="" fallback_dep_count=999999
    local idx
    while IFS= read -r idx; do
        [[ -z "$idx" ]] && continue
        local id="${CAND_IDS[$idx]}"
        local files_tmp="${CAND_FILES_TMP[$idx]}"

        local dep_count=0
        if [[ "$do_dep_check" == "true" && -s "$files_tmp" ]]; then
            local f pred owner
            while IFS= read -r f; do
                [[ -z "$f" ]] && continue
                while IFS= read -r pred; do
                    [[ -z "$pred" ]] && continue
                    owner="${FILES_OWNED_BY_OPEN[$pred]:-}"
                    if [[ -n "$owner" && "$owner" != "$id" ]]; then
                        dep_count=$(( dep_count + 1 ))
                    fi
                done < <(import_graph_predecessors "$f" "$cache_file" 2>/dev/null)
            done < "$files_tmp"
        fi

        if (( dep_count == 0 )); then
            best_idx="$idx"
            break
        fi

        echo "linear_optimizer: demoting ${id} (depends on ${dep_count} open-issue file(s))" >&2
        if (( dep_count < fallback_dep_count )); then
            fallback_idx="$idx"
            fallback_dep_count=$dep_count
        fi
    done <<< "$sorted_idx"

    # Cleanup per-candidate tempfiles regardless of outcome
    local cleanup_tmp
    for cleanup_tmp in "${CAND_FILES_TMP[@]}"; do
        [[ -n "$cleanup_tmp" ]] && rm -f "$cleanup_tmp" 2>/dev/null
    done

    if [[ -n "$best_idx" ]]; then
        _out_id="${CAND_IDS[$best_idx]}"
        _out_score="${CAND_SCORES[$best_idx]}"
        return 0
    fi
    if [[ -n "$fallback_idx" ]]; then
        _out_id="${CAND_IDS[$fallback_idx]}"
        _out_score="${CAND_SCORES[$fallback_idx]}"
        echo "linear_optimizer: all candidates have open deps; picking fewest-deps: ${_out_id}" >&2
        return 0
    fi
    return 1
}

# =============================================================================
# Main entry point
# =============================================================================

# linear_optimizer_run — Score open Linear issues by cache locality and write
# the best candidate identifier to .ralph/.linear_next_issue.
#
# Side effects:
#   Writes .ralph/.linear_next_issue (atomic tmp+mv).
#   May update .ralph/.linear_optimizer_cache.json.
#   Logs advisory messages on stderr; never calls log_status (avoids coupling).
#
# Exit: 0 always. Failures are advisory — harness continues without a hint.
linear_optimizer_run() {
    # Guards
    [[ "${RALPH_TASK_SOURCE:-file}" != "linear" ]] && return 0
    [[ "${RALPH_NO_LINEAR_OPTIMIZE:-false}" == "true" ]] && return 0
    [[ -z "${RALPH_LINEAR_PROJECT:-}" ]] && return 0
    [[ -z "${LINEAR_API_KEY:-}" ]] && return 0  # push-mode: Claude picks via MCP

    local lcf="${RALPH_DIR}/.last_completed_files"
    local hint_dest="${RALPH_DIR}/.linear_next_issue"
    local hint_tmp="${hint_dest}.tmp.$$"

    # Fetch top-N open issues with description for path extraction
    local issues_json
    issues_json=$(_linear_run_issues_query \
        'state:{type:{in:["backlog","unstarted","started"]}}' \
        'id identifier title priority updatedAt description' \
        "$RALPH_OPTIMIZER_FETCH_LIMIT") || {
        echo "linear_optimizer: fetch failed — no hint written" >&2
        return 0
    }

    local n_issues
    n_issues=$(printf '%s' "$issues_json" \
        | jq -r '(.data.issues.nodes // []) | length' 2>/dev/null \
        | tr -cd '0-9')
    n_issues=${n_issues:-0}

    if (( n_issues == 0 )); then
        : > "$hint_dest" 2>/dev/null || true
        return 0
    fi

    # Prepare set A: last-completed files (may be empty)
    local a_file
    a_file=$(mktemp /tmp/ralph_opt_a.XXXXXX) || return 0
    if [[ -s "$lcf" ]]; then
        sort -u "$lcf" > "$a_file"
    fi

    # Identify top-3 by priority (eligible for explorer fallback)
    local top3_ids
    top3_ids=$(printf '%s' "$issues_json" | jq -r '
        (.data.issues.nodes // [])
        | map(. + {sortPriority: (if .priority == 0 then 99 else .priority end)})
        | sort_by(.sortPriority)
        | .[0:3]
        | .[].id
    ' 2>/dev/null || true)

    # =========================================================================
    # Phase 1 (LINOPT-2): score every candidate and accumulate the file sets
    # =========================================================================
    # Parallel arrays — index i identifies one candidate.
    local -a CAND_IDS=()
    local -a CAND_SCORES=()
    local -a CAND_PRIORITIES=()
    local -a CAND_FILES_TMP=()   # one tempfile per candidate, holding its paths

    local b_file
    b_file=$(mktemp /tmp/ralph_opt_b.XXXXXX) || { rm -f "$a_file"; return 0; }

    while IFS= read -r issue_json_line; do
        [[ -z "$issue_json_line" ]] && continue

        local issue_id identifier title priority body updated_at
        issue_id=$(printf '%s' "$issue_json_line" | jq -r '.id // ""' 2>/dev/null)
        identifier=$(printf '%s' "$issue_json_line" | jq -r '.identifier // ""' 2>/dev/null)
        title=$(printf '%s' "$issue_json_line" | jq -r '.title // ""' 2>/dev/null)
        priority=$(printf '%s' "$issue_json_line" | jq -r '.priority // 0' 2>/dev/null \
            | tr -cd '0-9')
        priority=${priority:-0}
        body=$(printf '%s' "$issue_json_line" | jq -r '.description // ""' 2>/dev/null)
        updated_at=$(printf '%s' "$issue_json_line" | jq -r '.updatedAt // ""' 2>/dev/null)

        [[ -z "$issue_id" || -z "$identifier" ]] && continue

        # Build set B: file paths from issue body
        : > "$b_file"
        _optimizer_extract_paths_from_body "$body" >> "$b_file" 2>/dev/null || true

        # Explorer fallback for top-3 priority issues with no body paths
        if [[ ! -s "$b_file" ]]; then
            if printf '%s\n' "$top3_ids" | grep -qxF "$issue_id"; then
                _optimizer_explorer_resolve \
                    "$issue_id" "$updated_at" "$title" "$body" \
                    >> "$b_file" 2>/dev/null || true
            fi
        fi

        # Score: Jaccard + parent-dir bonus
        local score
        score=$(_optimizer_score_jaccard "$a_file" "$b_file")
        local sort_priority=$(( priority == 0 ? 99 : priority ))

        # Snapshot this candidate's file set for the dependency phase
        local cand_files_tmp
        cand_files_tmp=$(mktemp /tmp/ralph_opt_cand.XXXXXX) || continue
        cp "$b_file" "$cand_files_tmp" 2>/dev/null || : > "$cand_files_tmp"

        CAND_IDS+=("$identifier")
        CAND_SCORES+=("$score")
        CAND_PRIORITIES+=("$sort_priority")
        CAND_FILES_TMP+=("$cand_files_tmp")
    done < <(printf '%s' "$issues_json" \
        | jq -c '(.data.issues.nodes // [])[]' 2>/dev/null)

    rm -f "$a_file" "$b_file" 2>/dev/null || true

    if (( ${#CAND_IDS[@]} == 0 )); then
        echo "linear_optimizer: no candidate found — no hint written" >&2
        return 0
    fi

    # =========================================================================
    # Phase 2 (LINOPT-3 / TAP-592): dependency-aware selection
    # =========================================================================
    # Sort candidate indexes by score desc, then sort_priority asc. Build the
    # FILES_OWNED_BY_OPEN map from every candidate's path set, then iterate in
    # score order — the first candidate whose files don't import anything
    # owned by another candidate wins. If all candidates have ≥1 cross-issue
    # dep, fall back to the lowest-dep-count candidate (then highest score).
    #
    # If the import graph cache is missing or RALPH_NO_DEP_DEMOTE=true, we
    # skip the predecessor walk and pick by score only — preserving the
    # phase-1 behavior.
    local best_id best_score
    _optimizer_select_winner best_id best_score

    if [[ -z "$best_id" ]]; then
        # _optimizer_select_winner cleans up tempfiles even on failure
        echo "linear_optimizer: no candidate found — no hint written" >&2
        return 0
    fi

    # Atomic write
    if printf '%s\n# scored: %s\n' "$best_id" "$best_score" > "$hint_tmp" 2>/dev/null; then
        mv -f "$hint_tmp" "$hint_dest" 2>/dev/null || rm -f "$hint_tmp" 2>/dev/null
    else
        rm -f "$hint_tmp" 2>/dev/null
    fi

    echo "linear_optimizer: hint → ${best_id} (score=${best_score})" >&2
    return 0
}
