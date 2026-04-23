#!/bin/bash

# lib/linear_backend.sh — Linear API task backend for Ralph
#
# Provides open/done issue counts and next-task retrieval via the
# Linear GraphQL API. Used when RALPH_TASK_SOURCE=linear.
#
# Required config (.ralphrc or environment):
#   LINEAR_API_KEY          Personal Linear API key
#   RALPH_LINEAR_PROJECT    Project name (e.g. "Ralph Continuous Coding")
#
# Failure semantics (TAP-536):
#   * On API/parse error, public functions print NOTHING to stdout and exit 1.
#     Callers MUST distinguish "exit non-zero" (unknown) from "exit 0 + value".
#   * Old behavior (return "0"/""  + exit 0 on errors) caused premature loop
#     exits when network/auth/schema errors made a populated backlog look empty.
#   * `_linear_log_error` emits one structured line on stderr with no secrets:
#         linear_api_error: op=<name> reason=<timeout|network|http_NNN|parse|...>
#
# Push-mode (TAP-741):
#   * When LINEAR_API_KEY is unset (OAuth-via-MCP deployments), the count
#     functions fall back to reading `linear_open_count` / `linear_done_count`
#     from `$RALPH_DIR/status.json`, written by the on-stop hook from Claude's
#     RALPH_STATUS block. Entries older than RALPH_LINEAR_COUNTS_MAX_AGE_SECONDS
#     (default 900) are treated as stale and trigger the same abstain path.
#   * Iteration 1 has no prior hook write, so it abstains — same safe default as
#     an API outage. Iteration 2+ sees fresh counts and proceeds normally.

LINEAR_GRAPHQL_URL="https://api.linear.app/graphql"
RALPH_LINEAR_COUNTS_MAX_AGE_SECONDS_DEFAULT=900

# TAP-664: Session-cached project ID resolved from RALPH_LINEAR_PROJECT name.
# Populated by `linear_init` at session start. Queries prefer the cached ID
# over the raw name because Linear's `name.eq` filter is case- and whitespace-
# sensitive — any drift (trailing space, case difference, smart-quote vs ascii
# dash) silently returns an empty page, which TAP-536's fail-loud guard cannot
# distinguish from "zero open issues" and routes to a fake plan_complete exit.
_LINEAR_PROJECT_ID=""

# =============================================================================
# Internal helpers
# =============================================================================

# _linear_log_error — Emit a single structured error line on stderr.
# Never includes the API key, project name, or any other secret.
_linear_log_error() {
    local op="$1"
    local reason="$2"
    echo "linear_api_error: op=${op} reason=${reason}" >&2
}

# _linear_api — Execute a GraphQL query against Linear.
#
# Args:
#   $1 query
#   $2 variables_json (default '{}')
#
# Stdout: raw JSON response on success (HTTP 2xx).
# Exit:   0 on success, non-zero on any failure.
# Stderr: single `linear_api_error: ...` line on failure (via _linear_log_error).
_linear_api() {
    local query="$1"
    local variables="${2:-}"
    [[ -z "$variables" ]] && variables='{}'

    if [[ -z "${LINEAR_API_KEY:-}" ]]; then
        _linear_log_error "_linear_api" "no_api_key"
        return 1
    fi

    # Build payload via jq so query/variables can contain any character safely
    local payload
    payload=$(jq -n \
        --arg q "$query" \
        --argjson v "$variables" \
        '{query: $q, variables: $v}') || {
        _linear_log_error "_linear_api" "payload_build"
        return 1
    }

    # Capture body + HTTP code in one curl invocation. `-w '\n%{http_code}'`
    # appends the status code on its own line so we can split it off.
    local raw rc
    raw=$(curl -s --max-time 10 \
        -w '\n%{http_code}' \
        -H "Authorization: ${LINEAR_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "$LINEAR_GRAPHQL_URL" 2>/dev/null)
    rc=$?

    if [[ $rc -ne 0 ]]; then
        case $rc in
            28)  _linear_log_error "_linear_api" "timeout" ;;
            6|7) _linear_log_error "_linear_api" "network" ;;
            *)   _linear_log_error "_linear_api" "curl_${rc}" ;;
        esac
        return 1
    fi

    # Split: last line is the HTTP code, everything before is the body
    local http_code body
    http_code="${raw##*$'\n'}"
    body="${raw%$'\n'*}"

    if ! [[ "$http_code" =~ ^[0-9]+$ ]]; then
        _linear_log_error "_linear_api" "no_http_code"
        return 1
    fi

    if (( http_code < 200 || http_code >= 400 )); then
        _linear_log_error "_linear_api" "http_${http_code}"
        return 1
    fi

    # Surface GraphQL-level errors that come back with HTTP 200
    if echo "$body" | jq -e '.errors | length > 0' >/dev/null 2>&1; then
        _linear_log_error "_linear_api" "graphql_errors"
        return 1
    fi

    printf '%s' "$body"
    return 0
}

# _linear_read_hook_count — Read a Claude-reported count from status.json.
#
# TAP-741: Source of truth for push-mode (OAuth-via-MCP) deployments. The
# on-stop hook extracts LINEAR_OPEN_COUNT / LINEAR_DONE_COUNT from Claude's
# RALPH_STATUS block and writes them to $RALPH_DIR/status.json with a
# linear_counts_at timestamp. This function returns the stored value only if
# it's a valid non-negative integer AND within the staleness window.
#
# Args:
#   $1 field name ("linear_open_count" or "linear_done_count")
#   $2 op label for error logging ("open_count" | "done_count")
#
# Stdout: integer on success.
# Exit:   0 on success, 1 if the field is missing, malformed, or stale.
_linear_read_hook_count() {
    local field="$1"
    local op="$2"
    local ralph_dir="${RALPH_DIR:-.ralph}"
    local status_file="$ralph_dir/status.json"
    local max_age="${RALPH_LINEAR_COUNTS_MAX_AGE_SECONDS:-$RALPH_LINEAR_COUNTS_MAX_AGE_SECONDS_DEFAULT}"

    if [[ ! -f "$status_file" ]]; then
        _linear_log_error "$op" "no_status_file"
        return 1
    fi
    if ! jq -e 'type == "object"' "$status_file" >/dev/null 2>&1; then
        _linear_log_error "$op" "status_json_malformed"
        return 1
    fi

    local value counts_at
    value=$(jq -r ".${field} // empty" "$status_file" 2>/dev/null || echo "")
    counts_at=$(jq -r '.linear_counts_at // empty' "$status_file" 2>/dev/null || echo "")

    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
        _linear_log_error "$op" "no_hook_count"
        return 1
    fi

    # Staleness check. If counts_at is missing we err on the safe side and
    # abstain — a value without a timestamp could be a hand-edited relic.
    if [[ -z "$counts_at" ]]; then
        _linear_log_error "$op" "no_counts_timestamp"
        return 1
    fi
    local counts_epoch now_epoch age
    counts_epoch=$(date -d "$counts_at" +%s 2>/dev/null || echo "")
    if [[ -z "$counts_epoch" ]] && command -v gdate >/dev/null 2>&1; then
        counts_epoch=$(gdate -d "$counts_at" +%s 2>/dev/null || echo "")
    fi
    if ! [[ "$counts_epoch" =~ ^[0-9]+$ ]]; then
        _linear_log_error "$op" "counts_timestamp_unparseable"
        return 1
    fi
    now_epoch=$(date -u +%s)
    age=$((now_epoch - counts_epoch))
    if (( age > max_age )); then
        _linear_log_error "$op" "counts_stale"
        return 1
    fi

    printf '%s\n' "$value"
    return 0
}

# =============================================================================
# Public functions
# =============================================================================

# linear_get_open_count — Count open (backlog/unstarted/started) issues.
#
# Precedence:
#   1. LINEAR_API_KEY set → GraphQL (unchanged behavior, TAP-536 semantics).
#   2. Else → push-mode read from status.json (TAP-741).
#   3. Neither → exit 1 (abstain).
#
# Stdout: integer count on success.
# Exit:   0 on success, 1 on any failure (no stdout output).
linear_get_open_count() {
    if [[ -n "${LINEAR_API_KEY:-}" ]]; then
        local result
        result=$(_linear_run_issues_query \
            'state:{type:{in:["backlog","unstarted","started"]}}' \
            'id') || return 1

        local count
        count=$(printf '%s' "$result" | jq -r '.data.issues.nodes // [] | length' 2>/dev/null)
        if ! [[ "$count" =~ ^[0-9]+$ ]]; then
            _linear_log_error "open_count" "parse"
            return 1
        fi

        printf '%s\n' "$count"
        return 0
    fi

    _linear_read_hook_count "linear_open_count" "open_count"
}

# linear_get_done_count — Count completed issues in project.
# Precedence identical to linear_get_open_count.
linear_get_done_count() {
    if [[ -n "${LINEAR_API_KEY:-}" ]]; then
        local result
        result=$(_linear_run_issues_query \
            'state:{type:{eq:"completed"}}' \
            'id') || return 1

        local count
        count=$(printf '%s' "$result" | jq -r '.data.issues.nodes // [] | length' 2>/dev/null)
        if ! [[ "$count" =~ ^[0-9]+$ ]]; then
            _linear_log_error "done_count" "parse"
            return 1
        fi

        printf '%s\n' "$count"
        return 0
    fi

    _linear_read_hook_count "linear_done_count" "done_count"
}

# linear_get_next_task — Get highest-priority open issue.
# Priority: 1=Urgent 2=High 3=Normal 4=Low 0=None (treated as lowest).
# API-key only — no push-mode fallback (Claude picks tasks via Linear MCP in
# push-mode, so abstaining here lets the caller treat "no shell-side hint" as
# equivalent to a non-informational loop, rather than logging a false
# linear_api_error on every iteration).
# Stdout: "IDENTIFIER: title" on success; empty when backlog has no open issues.
# Exit:   0 on success (including empty backlog), 1 on API/parse error or no API key.
linear_get_next_task() {
    [[ -z "${LINEAR_API_KEY:-}" ]] && return 1

    local result
    result=$(_linear_run_issues_query \
        'state:{type:{in:["backlog","unstarted"]}}' \
        'id identifier title priority' \
        50) || return 1

    local next
    next=$(printf '%s' "$result" | jq -r '
        (.data.issues.nodes // [])
        | map(. + {sortPriority: (if .priority == 0 then 99 else .priority end)})
        | sort_by(.sortPriority)
        | first
        | if . then "\(.identifier): \(.title)" else "" end
    ' 2>/dev/null)
    if [[ $? -ne 0 ]]; then
        _linear_log_error "next_task" "parse"
        return 1
    fi

    printf '%s\n' "$next"
    return 0
}

# linear_get_in_progress_task — Get highest-priority in-progress (started) issue.
# Used by build_loop_context to surface stuck tickets for retry before Ralph
# picks new backlog work. API-key only — no push-mode fallback (Claude uses
# Linear MCP for task selection in push-mode).
#
# Stdout: "IDENTIFIER: title" on success; empty when no started issues exist.
# Exit:   0 on success (including empty), 1 on API/parse error or no API key.
linear_get_in_progress_task() {
    [[ -z "${LINEAR_API_KEY:-}" ]] && return 1

    local result
    result=$(_linear_run_issues_query \
        'state:{type:{eq:"started"}}' \
        'id identifier title priority' \
        50) || return 1

    local next
    next=$(printf '%s' "$result" | jq -r '
        (.data.issues.nodes // [])
        | map(. + {sortPriority: (if .priority == 0 then 99 else .priority end)})
        | sort_by(.sortPriority)
        | first
        | if . then "\(.identifier): \(.title)" else "" end
    ' 2>/dev/null)
    if [[ $? -ne 0 ]]; then
        _linear_log_error "in_progress_task" "parse"
        return 1
    fi

    printf '%s\n' "$next"
    return 0
}

# TAP-664: linear_resolve_project_id — Resolve RALPH_LINEAR_PROJECT (name) to
# its Linear project UUID. Fails loudly on zero matches or >1 matches so that
# whitespace/case drift in .ralphrc surfaces as a startup error instead of a
# silent empty-result cascade that masquerades as "backlog empty → exit".
#
# Caches the resolved ID in the session-scoped `_LINEAR_PROJECT_ID` var.
#
# Stdout: UUID on success.
# Exit:   0 on success (one match), 1 on any failure (API error, no match,
#         ambiguous match). Emits a structured linear_api_error line on stderr.
linear_resolve_project_id() {
    if [[ -z "${LINEAR_API_KEY:-}" ]]; then
        _linear_log_error "resolve_project_id" "no_api_key"
        return 1
    fi
    if [[ -z "${RALPH_LINEAR_PROJECT:-}" ]]; then
        _linear_log_error "resolve_project_id" "no_project_name"
        return 1
    fi

    local query='query($name:String!){
      projects(filter:{name:{eq:$name}},first:10){nodes{id name}}
    }'
    local result
    result=$(_linear_api "$query" "{\"name\":\"${RALPH_LINEAR_PROJECT}\"}") || return 1

    local count first_id
    count=$(printf '%s' "$result" | jq -r '.data.projects.nodes // [] | length' 2>/dev/null)
    if ! [[ "$count" =~ ^[0-9]+$ ]]; then
        _linear_log_error "resolve_project_id" "parse"
        return 1
    fi

    case "$count" in
        0)
            _linear_log_error "resolve_project_id" "project_not_found"
            return 1
            ;;
        1)
            first_id=$(printf '%s' "$result" | jq -r '.data.projects.nodes[0].id' 2>/dev/null)
            if [[ -z "$first_id" || "$first_id" == "null" ]]; then
                _linear_log_error "resolve_project_id" "parse"
                return 1
            fi
            _LINEAR_PROJECT_ID="$first_id"
            printf '%s\n' "$first_id"
            return 0
            ;;
        *)
            _linear_log_error "resolve_project_id" "project_ambiguous_${count}_matches"
            return 1
            ;;
    esac
}

# linear_init — One-shot session bootstrap for the Linear backend. Resolves
# the project name to an ID (if an API key is set) and logs the outcome so
# mismatches surface in the first log line rather than after a fake
# plan_complete. Safe to call multiple times; re-uses the cached ID.
#
# Stdout: nothing (diagnostics go through log_status on stderr).
# Exit:   0 when the backend is ready to serve queries in whatever mode is
#         configured; 1 only when an explicit resolve was attempted and failed.
linear_init() {
    # Push-mode (no API key) — nothing to resolve.
    [[ -z "${LINEAR_API_KEY:-}" ]] && return 0
    # Already resolved — idempotent re-use.
    [[ -n "$_LINEAR_PROJECT_ID" ]] && return 0

    # Call resolve directly (not via `$(...)`) — the function sets the
    # session-global `_LINEAR_PROJECT_ID`, and a command-substitution subshell
    # would throw that assignment away.
    if linear_resolve_project_id >/dev/null; then
        if declare -F log_status >/dev/null 2>&1; then
            log_status "INFO" "Linear project resolved: '${RALPH_LINEAR_PROJECT}' -> ${_LINEAR_PROJECT_ID}"
        fi
        return 0
    else
        if declare -F log_status >/dev/null 2>&1; then
            log_status "ERROR" "Linear project '${RALPH_LINEAR_PROJECT}' failed to resolve — check spelling, case, and trailing whitespace"
        fi
        return 1
    fi
}

# _linear_project_filter — Emit the GraphQL project-filter fragment. Prefers
# the cached UUID (exact match) over the raw name (case/whitespace-sensitive).
#
# Stdout: a JSON key-value pair (without leading/trailing braces) suitable for
# interpolation inside an `issues(filter:{ ... })` clause.
_linear_project_filter() {
    if [[ -n "$_LINEAR_PROJECT_ID" ]]; then
        printf 'project:{id:{eq:$projectId}}'
    else
        printf 'project:{name:{eq:$project}}'
    fi
}

# _linear_project_vars_json — Emit the GraphQL variables-object JSON for the
# current project filter. Pairs with _linear_project_filter.
_linear_project_vars_json() {
    if [[ -n "$_LINEAR_PROJECT_ID" ]]; then
        printf '"%s"' "$_LINEAR_PROJECT_ID"
    else
        printf '"%s"' "${RALPH_LINEAR_PROJECT:-}"
    fi
}

# _linear_run_issues_query — Factored GraphQL issues-query runner used by all
# public count/get functions. Applies the current project filter (ID when
# cached via linear_init, name otherwise — see TAP-664) so callers don't need
# to duplicate the branching.
#
# Args:
#   $1 state_clause — e.g. 'state:{type:{in:["backlog","unstarted","started"]}}'
#   $2 selection    — e.g. 'id' or 'id identifier title priority'
#   $3 first        — page size (default 250)
#
# Stdout: raw JSON response on success.
# Exit:   0 on success, 1 on failure (same fail-loud contract as _linear_api).
_linear_run_issues_query() {
    local state_clause="$1"
    local selection="$2"
    local first="${3:-250}"
    local query vars
    if [[ -n "$_LINEAR_PROJECT_ID" ]]; then
        query="query(\$projectId:String!){issues(filter:{project:{id:{eq:\$projectId}},${state_clause}},first:${first}){nodes{${selection}}}}"
        vars="{\"projectId\":\"${_LINEAR_PROJECT_ID}\"}"
    else
        query="query(\$project:String!){issues(filter:{project:{name:{eq:\$project}},${state_clause}},first:${first}){nodes{${selection}}}}"
        vars="{\"project\":\"${RALPH_LINEAR_PROJECT:-}\"}"
    fi
    _linear_api "$query" "$vars"
}

# linear_check_configured — Returns 0 iff Linear backend is usable (env only).
# Does not make an API call — see linear_get_open_count for liveness.
#
# TAP-741: RALPH_LINEAR_PROJECT is required in both modes (it's what Claude is
# told to query in push-mode and what GraphQL filters on in API-key mode).
# LINEAR_API_KEY is optional — its absence selects push-mode rather than
# disabling the backend.
linear_check_configured() {
    [[ -z "${RALPH_LINEAR_PROJECT:-}" ]] && return 1
    return 0
}
