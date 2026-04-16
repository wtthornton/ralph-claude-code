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

LINEAR_GRAPHQL_URL="https://api.linear.app/graphql"

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

# =============================================================================
# Public functions
# =============================================================================

# linear_get_open_count — Count open (backlog/unstarted/started) issues.
# Stdout: integer count on success.
# Exit:   0 on success, 1 on API/parse error (no stdout output).
linear_get_open_count() {
    local query='query($project:String!){
      issues(filter:{
        project:{name:{eq:$project}},
        state:{type:{in:["backlog","unstarted","started"]}}
      },first:250){nodes{id}}
    }'
    local result
    result=$(_linear_api "$query" "{\"project\":\"${RALPH_LINEAR_PROJECT:-}\"}") || return 1

    local count
    count=$(printf '%s' "$result" | jq -r '.data.issues.nodes // [] | length' 2>/dev/null)
    if ! [[ "$count" =~ ^[0-9]+$ ]]; then
        _linear_log_error "open_count" "parse"
        return 1
    fi

    printf '%s\n' "$count"
    return 0
}

# linear_get_done_count — Count completed issues in project.
# Stdout: integer count on success.
# Exit:   0 on success, 1 on API/parse error (no stdout output).
linear_get_done_count() {
    local query='query($project:String!){
      issues(filter:{
        project:{name:{eq:$project}},
        state:{type:{eq:"completed"}}
      },first:250){nodes{id}}
    }'
    local result
    result=$(_linear_api "$query" "{\"project\":\"${RALPH_LINEAR_PROJECT:-}\"}") || return 1

    local count
    count=$(printf '%s' "$result" | jq -r '.data.issues.nodes // [] | length' 2>/dev/null)
    if ! [[ "$count" =~ ^[0-9]+$ ]]; then
        _linear_log_error "done_count" "parse"
        return 1
    fi

    printf '%s\n' "$count"
    return 0
}

# linear_get_next_task — Get highest-priority open issue.
# Priority: 1=Urgent 2=High 3=Normal 4=Low 0=None (treated as lowest).
# Stdout: "IDENTIFIER: title" on success; empty when backlog has no open issues.
# Exit:   0 on success (including empty backlog), 1 on API/parse error.
linear_get_next_task() {
    local query='query($project:String!){
      issues(filter:{
        project:{name:{eq:$project}},
        state:{type:{in:["backlog","unstarted"]}}
      },first:50){nodes{id identifier title priority}}
    }'
    local result
    result=$(_linear_api "$query" "{\"project\":\"${RALPH_LINEAR_PROJECT:-}\"}") || return 1

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

# linear_check_configured — Returns 0 iff Linear backend is usable (env only).
# Does not make an API call — see linear_get_open_count for liveness.
linear_check_configured() {
    [[ -z "${LINEAR_API_KEY:-}" ]] && return 1
    [[ -z "${RALPH_LINEAR_PROJECT:-}" ]] && return 1
    return 0
}
