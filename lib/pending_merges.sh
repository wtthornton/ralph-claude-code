#!/bin/bash
# lib/pending_merges.sh — async PR-merge queue (T5 / 2.16.0)
#
# Decouples the agent's "ticket done" decision from the GitHub merge actually
# landing. Today's flow waits ~2–4 min per PR for CI green. With this queue,
# the agent opens the PR, records the pending merge, and immediately picks the
# next ticket. The harness polls pending PRs at loop boundaries and merges
# any that are green.
#
# Operator opt-in: RALPH_ASYNC_MERGE=true (default false). All functions are
# safe no-ops when the queue file is missing or the flag is off. CI failures
# surface to the next loop's context so the agent can fix; the harness never
# silently drops a PR.
#
# Bounded by RALPH_ASYNC_MERGE_MAX_PENDING (default 5). Above the cap, callers
# should force-drain synchronously rather than queue more.
#
# State file: .ralph/pending-merges.json (atomic writes via mv).
# Schema version 1:
#   {
#     "version": 1,
#     "entries": [
#       {
#         "pr_number": 123,
#         "ticket_id": "TAP-1234",
#         "branch": "feature/foo",
#         "created_at": "2026-05-22T16:00:00Z",
#         "last_check_at": "2026-05-22T16:05:00Z",
#         "ci_status": "pending" | "green" | "red",
#         "merge_status": "open" | "merged" | "failed",
#         "merge_sha": null | "<sha>",
#         "failure_reason": null | "<short string>"
#       }
#     ]
#   }
#
# Pure-bash. Sourceable from any caller. Requires jq + gh CLI.

# shellcheck shell=bash

PENDING_MERGES_FILE="${PENDING_MERGES_FILE:-${RALPH_DIR:-.ralph}/pending-merges.json}"

# Reuse atomic_write from ralph_loop.sh when present; otherwise define minimal copy.
if ! declare -F atomic_write >/dev/null 2>&1; then
    atomic_write() {
        local target="$1"
        local value="$2"
        local tmp
        tmp="${target}.tmp.$$.${RANDOM}"
        printf '%s' "$value" > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
        mv -f "$tmp" "$target" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
        return 0
    }
fi

_pending_merges_log() {
    local lvl="${1:-INFO}"
    shift || true
    if declare -F log_status >/dev/null 2>&1; then
        log_status "$lvl" "pending-merges: $*"
    else
        printf '[%s] [PENDING-MERGES] %s\n' "$lvl" "$*" >&2
    fi
}

# pending_merges_enabled — returns 0 if async-merge mode is on.
pending_merges_enabled() {
    [[ "${RALPH_ASYNC_MERGE:-false}" == "true" ]]
}

# pending_merges_init — create the queue file if missing.
pending_merges_init() {
    [[ -s "$PENDING_MERGES_FILE" ]] && return 0
    local dir
    dir=$(dirname -- "$PENDING_MERGES_FILE")
    [[ -d "$dir" ]] || mkdir -p -- "$dir" 2>/dev/null || return 1
    atomic_write "$PENDING_MERGES_FILE" '{"version":1,"entries":[]}'
}

# pending_merges_count — print the count of open (not merged, not failed) entries.
pending_merges_count() {
    [[ -s "$PENDING_MERGES_FILE" ]] || { echo 0; return 0; }
    jq -r '[.entries[]? | select((.merge_status // "open") == "open")] | length' \
        "$PENDING_MERGES_FILE" 2>/dev/null || echo 0
}

# pending_merges_add <pr_number> <ticket_id> <branch>
#   Append an entry for a freshly-opened PR. Returns:
#     0 on success
#     1 on argument/parse failure
#     2 when queue is at RALPH_ASYNC_MERGE_MAX_PENDING (caller should force-drain)
pending_merges_add() {
    local pr_number="$1"
    local ticket_id="$2"
    local branch="$3"
    [[ "$pr_number" =~ ^[0-9]+$ ]] || { _pending_merges_log "ERROR" "invalid pr_number '$pr_number'"; return 1; }
    [[ -n "$ticket_id" && -n "$branch" ]] || { _pending_merges_log "ERROR" "missing ticket_id or branch"; return 1; }

    pending_merges_init || return 1
    local cap="${RALPH_ASYNC_MERGE_MAX_PENDING:-5}"
    local cur
    cur=$(pending_merges_count)
    if (( cur >= cap )); then
        _pending_merges_log "WARN" "queue at cap ($cur >= $cap) — caller must drain"
        return 2
    fi

    local now
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local updated
    updated=$(jq --argjson n "$pr_number" --arg t "$ticket_id" --arg b "$branch" --arg ts "$now" '
        .entries += [{
            pr_number: $n,
            ticket_id: $t,
            branch: $b,
            created_at: $ts,
            last_check_at: $ts,
            ci_status: "pending",
            merge_status: "open",
            merge_sha: null,
            failure_reason: null
        }]
    ' "$PENDING_MERGES_FILE" 2>/dev/null) || { _pending_merges_log "ERROR" "jq update failed"; return 1; }
    atomic_write "$PENDING_MERGES_FILE" "$updated" || return 1
    _pending_merges_log "INFO" "queued PR #$pr_number ($ticket_id, $branch)"
    return 0
}

# _pending_merges_update_entry <pr_number> <jq_expression> [jq-arg ...]
#   Internal: apply a jq expression to the entry with matching pr_number.
#   Any trailing args (e.g. `--arg reason "$x"`) are forwarded to jq verbatim,
#   so dynamic values MUST be passed as jq variables and referenced in the
#   expression — never interpolated into the program text. A `gh` error message
#   containing a backslash / `$` / quote would otherwise break the jq parse, the
#   entry would never be marked failed, and pending_merges_poll would re-attempt
#   the same broken merge on every loop forever.
_pending_merges_update_entry() {
    local pr_number="$1"
    local jq_expr="$2"
    shift 2
    [[ -s "$PENDING_MERGES_FILE" ]] || return 1
    local now
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local updated
    updated=$(jq --argjson n "$pr_number" --arg ts "$now" "$@" "
        .entries |= map(
            if .pr_number == \$n then
                ($jq_expr) | .last_check_at = \$ts
            else . end
        )
    " "$PENDING_MERGES_FILE" 2>/dev/null) || return 1
    atomic_write "$PENDING_MERGES_FILE" "$updated"
}

# _pending_merges_check_ci <pr_number>
#   Probe `gh pr checks` for the given PR. Echoes one of:
#     green | pending | red | unknown
_pending_merges_check_ci() {
    local pr_number="$1"
    command -v gh >/dev/null 2>&1 || { echo "unknown"; return 0; }
    # `gh pr checks --json` reports per-check state. Treat:
    #   all states ∈ {SUCCESS, NEUTRAL, SKIPPED} → green
    #   any state ∈ {FAILURE, CANCELLED, TIMED_OUT, ACTION_REQUIRED} → red
    #   else → pending
    # No checks configured → green (nothing to wait on).
    local out
    out=$(gh pr checks "$pr_number" --json state 2>/dev/null) || { echo "unknown"; return 0; }
    [[ -z "$out" || "$out" == "[]" ]] && { echo "green"; return 0; }
    local any_red
    any_red=$(jq -r '[.[] | select((.state // "PENDING") | IN("FAILURE","CANCELLED","TIMED_OUT","ACTION_REQUIRED"))] | length' <<<"$out" 2>/dev/null || echo 0)
    if [[ "$any_red" -gt 0 ]]; then echo "red"; return 0; fi
    local any_pending
    any_pending=$(jq -r '[.[] | select((.state // "PENDING") | IN("SUCCESS","NEUTRAL","SKIPPED") | not)] | length' <<<"$out" 2>/dev/null || echo 0)
    if [[ "$any_pending" -gt 0 ]]; then echo "pending"; return 0; fi
    echo "green"
}

# pending_merges_poll — iterate over open entries and try to merge each one
# whose CI is green. Marks failed entries (red CI or merge failure) for the
# next loop to surface. Skips silently when async-merge is disabled or the
# queue is empty.
pending_merges_poll() {
    pending_merges_enabled || return 0
    [[ -s "$PENDING_MERGES_FILE" ]] || return 0

    local open_pr_numbers
    open_pr_numbers=$(jq -r '[.entries[]? | select((.merge_status // "open") == "open") | .pr_number] | .[]' \
        "$PENDING_MERGES_FILE" 2>/dev/null) || return 0

    local pr_number
    while IFS= read -r pr_number; do
        [[ -n "$pr_number" ]] || continue
        local ci_status
        ci_status=$(_pending_merges_check_ci "$pr_number")
        case "$ci_status" in
            green)
                _pending_merges_log "INFO" "PR #$pr_number CI green — merging"
                # gh pr merge --squash --delete-branch returns 0 on success.
                # Capture stderr to differentiate the March 2026 422 case from
                # other failures.
                local merge_err
                if merge_err=$(gh pr merge "$pr_number" --squash --delete-branch 2>&1); then
                    local merge_sha
                    merge_sha=$(gh pr view "$pr_number" --json mergeCommit -q '.mergeCommit.oid // ""' 2>/dev/null)
                    _pending_merges_update_entry "$pr_number" \
                        '.merge_status = "merged" | .ci_status = "green" | .merge_sha = $sha' \
                        --arg sha "$merge_sha"
                    _pending_merges_log "INFO" "PR #$pr_number merged (sha=$merge_sha)"
                else
                    # 422 "auto-merge not allowed" or other failure — log + mark failed.
                    local short_err
                    short_err=$(printf '%s' "$merge_err" | head -1 | cut -c1-120)
                    _pending_merges_update_entry "$pr_number" \
                        '.merge_status = "failed" | .ci_status = "green" | .failure_reason = ("merge_call_failed: " + $reason)' \
                        --arg reason "$short_err"
                    _pending_merges_log "WARN" "PR #$pr_number merge failed: $short_err"
                fi
                ;;
            red)
                _pending_merges_update_entry "$pr_number" \
                    '.ci_status = "red" | .merge_status = "failed" | .failure_reason = "ci_failed"'
                _pending_merges_log "WARN" "PR #$pr_number CI failed — marked for next-loop surface"
                ;;
            pending)
                _pending_merges_update_entry "$pr_number" '.ci_status = "pending"'
                ;;
            unknown|*)
                # Skip — likely missing gh binary or transient API failure.
                ;;
        esac
    done <<<"$open_pr_numbers"
    return 0
}

# pending_merges_surface_failed — emit a single line summarizing any failed
# entries so the next loop's context can include them. Caller decides where
# to send the output (stdout, log line, prompt append).
pending_merges_surface_failed() {
    [[ -s "$PENDING_MERGES_FILE" ]] || return 0
    jq -r '
        [.entries[]? | select(.merge_status == "failed")]
        | if length == 0 then empty
          else "PENDING-MERGE FAILURES: " +
               (map("#\(.pr_number) (\(.ticket_id)) — \(.failure_reason // "unknown")") | join("; "))
          end
    ' "$PENDING_MERGES_FILE" 2>/dev/null
}

# pending_merges_get_merged — print one TAP-ID per line for entries that have
# merged but whose Linear ticket may not yet be Done. Used by the agent contract
# to surface "Linear cleanup pending" work at the top of the next loop.
pending_merges_get_merged() {
    [[ -s "$PENDING_MERGES_FILE" ]] || return 0
    jq -r '.entries[]? | select(.merge_status == "merged") | .ticket_id' \
        "$PENDING_MERGES_FILE" 2>/dev/null
}

# pending_merges_drop <pr_number>
#   Remove an entry — used by the agent (via a small helper invocation) after
#   it has moved the Linear ticket to Done, or by the operator manually.
pending_merges_drop() {
    local pr_number="$1"
    [[ "$pr_number" =~ ^[0-9]+$ ]] || return 1
    [[ -s "$PENDING_MERGES_FILE" ]] || return 0
    local updated
    updated=$(jq --argjson n "$pr_number" '.entries |= map(select(.pr_number != $n))' \
        "$PENDING_MERGES_FILE" 2>/dev/null) || return 1
    atomic_write "$PENDING_MERGES_FILE" "$updated"
}

# pending_merges_force_drain — synchronous merge of all open entries, blocking
# until each completes. Used when the queue hits its cap. Returns 0 even on
# partial failure; failed entries are marked for surface.
pending_merges_force_drain() {
    pending_merges_enabled || return 0
    [[ -s "$PENDING_MERGES_FILE" ]] || return 0
    _pending_merges_log "WARN" "force-draining queue (was at cap)"
    # Re-poll up to RALPH_ASYNC_MERGE_DRAIN_RETRIES times with sleep between,
    # so CI has a chance to finish.
    local retries="${RALPH_ASYNC_MERGE_DRAIN_RETRIES:-6}"
    local sleep_s="${RALPH_ASYNC_MERGE_DRAIN_SLEEP_SECONDS:-30}"
    local i=0
    while (( i < retries )); do
        pending_merges_poll
        local open
        open=$(pending_merges_count)
        [[ "$open" -eq 0 ]] && return 0
        i=$((i + 1))
        [[ "$i" -lt "$retries" ]] && sleep "$sleep_s"
    done
    return 0
}
