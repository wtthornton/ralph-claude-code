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
# All functions fail-open (return "0" or "") so the loop degrades
# gracefully if the API is unreachable rather than crashing.

LINEAR_GRAPHQL_URL="https://api.linear.app/graphql"

# =============================================================================
# Internal helper
# =============================================================================

# _linear_api — Execute a GraphQL query against Linear
# Usage: _linear_api QUERY VARIABLES_JSON
# Returns: raw JSON response on stdout; exit 1 on error
_linear_api() {
    local query="$1"
    local variables="${2:-}"
    [[ -z "$variables" ]] && variables='{}'

    if [[ -z "${LINEAR_API_KEY:-}" ]]; then
        echo '{"error":"LINEAR_API_KEY not set"}' >&2
        return 1
    fi

    # Build payload: embed query as a JSON string value
    local payload
    payload=$(jq -n \
        --arg q "$query" \
        --argjson v "$variables" \
        '{query: $q, variables: $v}') || return 1

    curl -sf \
        --max-time 10 \
        -H "Authorization: ${LINEAR_API_KEY}" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "$LINEAR_GRAPHQL_URL"
}

# =============================================================================
# Public functions
# =============================================================================

# linear_get_open_count — Count open (backlog/unstarted/started) issues
# Returns: integer on stdout (0 on error)
linear_get_open_count() {
    local query='query($project:String!){
      issues(filter:{
        project:{name:{eq:$project}},
        state:{type:{in:["backlog","unstarted","started"]}}
      },first:250){nodes{id}}
    }'
    local result
    result=$(_linear_api "$query" "{\"project\":\"${RALPH_LINEAR_PROJECT:-}\"}" 2>/dev/null) || { echo "0"; return 0; }
    echo "$result" | jq '.data.issues.nodes | length' 2>/dev/null || echo "0"
}

# linear_get_done_count — Count completed issues in project
# Returns: integer on stdout (0 on error)
linear_get_done_count() {
    local query='query($project:String!){
      issues(filter:{
        project:{name:{eq:$project}},
        state:{type:{eq:"completed"}}
      },first:250){nodes{id}}
    }'
    local result
    result=$(_linear_api "$query" "{\"project\":\"${RALPH_LINEAR_PROJECT:-}\"}" 2>/dev/null) || { echo "0"; return 0; }
    echo "$result" | jq '.data.issues.nodes | length' 2>/dev/null || echo "0"
}

# linear_get_next_task — Get highest priority open issue
# Priority values: 1=Urgent 2=High 3=Normal 4=Low 0=None (treated as lowest)
# Returns: "IDENTIFIER: title" on stdout, or empty string if none
linear_get_next_task() {
    local query='query($project:String!){
      issues(filter:{
        project:{name:{eq:$project}},
        state:{type:{in:["backlog","unstarted"]}}
      },first:50){nodes{id identifier title priority}}
    }'
    local result
    result=$(_linear_api "$query" "{\"project\":\"${RALPH_LINEAR_PROJECT:-}\"}" 2>/dev/null) || { echo ""; return 0; }

    echo "$result" | jq -r '
        (.data.issues.nodes // [])
        | map(. + {sortPriority: (if .priority == 0 then 99 else .priority end)})
        | sort_by(.sortPriority)
        | first
        | if . then "\(.identifier): \(.title)" else "" end
    ' 2>/dev/null || echo ""
}

# linear_check_configured — Returns 0 if Linear backend is usable
linear_check_configured() {
    [[ -z "${LINEAR_API_KEY:-}" ]] && return 1
    [[ -z "${RALPH_LINEAR_PROJECT:-}" ]] && return 1
    return 0
}
