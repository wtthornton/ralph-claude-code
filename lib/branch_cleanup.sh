#!/usr/bin/env bash

# lib/branch_cleanup.sh — Epic-boundary janitor for squash-merged Ralph
# working branches (TAP-1880, parent epic TAP-1878).
#
# Why this exists: Ralph's prompt-side fix (TAP-1879) tells Claude to delete
# the source branch after each squash-merge, but it leaks whenever Claude
# crashes mid-loop, the network errors on `git push origin --delete`, or
# the LLM truncates the deletion sentence. This module is the harness-side
# safety net — it scans for squash-merged `tap-*` branches and deletes
# them at the same low cadence as other epic-boundary work.
#
# Detection: `git cherry main <branch>` — the only reliable squash-merge
# signal. `git branch --merged main` does NOT work because squash-merge
# creates a new commit on main rather than fast-forwarding (2026 git-cleanup
# canon: whitep4nth3r, Adam Johnson, not-an-aardvark/git-delete-squashed).
#
# Safety envelope:
#   - protected list never deleted (default: main, master, develop, release/*)
#   - prefix filter (default tap-) — non-Ralph branches ignored
#   - min-age threshold (default 24h) — avoids deleting in-flight branches
#   - currently-checked-out branch + RALPH_CURRENT_BRANCH never deleted
#   - failures (network, permission) are WARN-only — never trip the CB
#
# Config:
#   RALPH_BRANCH_CLEANUP_ENABLED       (default true)
#   RALPH_BRANCH_PREFIX                (default tap-)
#   RALPH_BRANCH_CLEANUP_MIN_AGE_HOURS (default 24)
#   RALPH_BRANCH_CLEANUP_PROTECTED     (default "main:master:develop:release/*")

RALPH_BRANCH_CLEANUP_ENABLED="${RALPH_BRANCH_CLEANUP_ENABLED:-true}"
RALPH_BRANCH_PREFIX="${RALPH_BRANCH_PREFIX:-tap-}"
RALPH_BRANCH_CLEANUP_MIN_AGE_HOURS="${RALPH_BRANCH_CLEANUP_MIN_AGE_HOURS:-24}"
RALPH_BRANCH_CLEANUP_PROTECTED="${RALPH_BRANCH_CLEANUP_PROTECTED:-main:master:develop:release/*}"

# branch_cleanup_log — internal logger. Uses log_status() if available
# (when sourced from ralph_loop.sh), otherwise stderr.
branch_cleanup_log() {
    local level="$1"; shift
    local msg="$*"
    if declare -F log_status >/dev/null 2>&1; then
        log_status "$level" "branch_cleanup: $msg"
    else
        printf '[%s] branch_cleanup: %s\n' "$level" "$msg" >&2
    fi
}

# branch_cleanup_is_protected — true (0) if $branch matches any pattern in
# RALPH_BRANCH_CLEANUP_PROTECTED (colon-separated; bash-glob each entry).
branch_cleanup_is_protected() {
    local branch="$1"
    local protected="${RALPH_BRANCH_CLEANUP_PROTECTED:-main:master:develop:release/*}"
    local IFS=":"
    local pattern
    # shellcheck disable=SC2086
    for pattern in $protected; do
        [[ -z "$pattern" ]] && continue
        # Bash glob match — works for both literals ("main") and globs ("release/*")
        # shellcheck disable=SC2053
        if [[ "$branch" == $pattern ]]; then
            return 0
        fi
    done
    return 1
}

# branch_cleanup_is_squashed — true (0) if every commit on $branch is
# already present on main (via git cherry).
#
# Implementation: `git cherry main <branch>` prints one line per commit;
# lines starting with `+` are NOT on main, lines starting with `-` ARE.
# An empty output means $branch has no commits beyond the fork point with
# main (already-merged in the fast-forward sense). All-`-` output means
# every commit's patch is present on main (squash-merged). Any `+` means
# unmerged work remains.
branch_cleanup_is_squashed() {
    local branch="$1"
    local main_ref="${2:-main}"
    local out rc
    out=$(git cherry "$main_ref" "$branch" 2>/dev/null)
    rc=$?
    if [[ "$rc" -ne 0 ]]; then
        # git cherry failed — treat as ambiguous, do NOT delete
        return 2
    fi
    # No output: nothing to merge — not "squashed" in the sense this
    # module cares about (could be a branch identical to main).
    if [[ -z "$out" ]]; then
        return 2
    fi
    # Any line starting with '+' means at least one commit is unmerged.
    if grep -q '^+' <<< "$out"; then
        return 1
    fi
    # All lines start with '-' → every commit's patch is on main → squashed.
    return 0
}

# branch_cleanup_age_hours — age of $branch's tip commit in hours.
# Empty string if branch is missing or git fails.
branch_cleanup_age_hours() {
    local branch="$1"
    local ts now
    ts=$(git log -1 --format=%ct "$branch" -- 2>/dev/null) || return 1
    [[ -z "$ts" ]] && return 1
    now=$(date +%s)
    echo $(( (now - ts) / 3600 ))
}

# branch_cleanup_local — delete a local branch via `git branch -D`.
# Returns 0 on success, non-zero on failure (already logged).
branch_cleanup_local() {
    local branch="$1"
    if git branch -D "$branch" >/dev/null 2>&1; then
        branch_cleanup_log "INFO" "deleted local branch: $branch"
        return 0
    fi
    branch_cleanup_log "WARN" "failed to delete local branch: $branch"
    return 1
}

# branch_cleanup_origin — delete a remote branch via
# `git push origin --delete`. Best-effort: any failure (no remote,
# permission denied, network error, branch already gone) is logged WARN
# and returns 0 so the orchestrator never propagates a failing rc.
branch_cleanup_origin() {
    local branch="$1"
    # Skip if no `origin` remote configured
    if ! git remote get-url origin >/dev/null 2>&1; then
        return 0
    fi
    # Skip if origin doesn't have this branch (cheap pre-check avoids
    # noisy WARN for branches that were never pushed)
    if ! git ls-remote --heads origin "$branch" 2>/dev/null | grep -q .; then
        return 0
    fi
    if git push origin --delete "$branch" >/dev/null 2>&1; then
        branch_cleanup_log "INFO" "deleted origin branch: $branch"
    else
        branch_cleanup_log "WARN" "best-effort: failed to delete origin branch (network/permission?): $branch"
    fi
    return 0
}

# ralph_cleanup_merged_branches — orchestrator. Scans all local branches,
# filters by prefix + age + protected-list + squash-merge evidence, and
# deletes survivors (local + origin). Always returns 0 so callers don't
# need failure handling — the safety envelope is the point of this module.
#
# Optional arg: $1 = main_ref (default: main).
#
# Globals respected: RALPH_BRANCH_CLEANUP_ENABLED, RALPH_BRANCH_PREFIX,
# RALPH_BRANCH_CLEANUP_MIN_AGE_HOURS, RALPH_BRANCH_CLEANUP_PROTECTED,
# RALPH_CURRENT_BRANCH.
ralph_cleanup_merged_branches() {
    local main_ref="${1:-main}"

    if [[ "${RALPH_BRANCH_CLEANUP_ENABLED:-true}" != "true" ]]; then
        return 0
    fi

    # Not in a git repo → no-op (e.g., bare ralph project)
    if ! git rev-parse --git-dir >/dev/null 2>&1; then
        return 0
    fi

    # main_ref must exist locally
    if ! git rev-parse --verify "$main_ref" >/dev/null 2>&1; then
        branch_cleanup_log "INFO" "main ref '$main_ref' not found — skipping cleanup"
        return 0
    fi

    local current_branch
    current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || current_branch=""

    local deleted=0 skipped=0 candidates=0
    local branch age

    # Walk every local branch
    while IFS= read -r branch; do
        [[ -z "$branch" ]] && continue
        # Strip the leading marker `*` or ` ` from `git branch` output
        branch="${branch## }"
        branch="${branch#\* }"

        # Prefix filter (cheap)
        if [[ "$branch" != "$RALPH_BRANCH_PREFIX"* ]]; then
            continue
        fi
        candidates=$((candidates + 1))

        # Protected list — main/master/develop/release/*
        if branch_cleanup_is_protected "$branch"; then
            skipped=$((skipped + 1))
            continue
        fi

        # Never delete the currently-checked-out branch
        if [[ -n "$current_branch" && "$branch" == "$current_branch" ]]; then
            skipped=$((skipped + 1))
            continue
        fi

        # Never delete RALPH_CURRENT_BRANCH (caller can pin a branch)
        if [[ -n "${RALPH_CURRENT_BRANCH:-}" && "$branch" == "${RALPH_CURRENT_BRANCH}" ]]; then
            skipped=$((skipped + 1))
            continue
        fi

        # Min-age threshold — skip in-flight branches
        age=$(branch_cleanup_age_hours "$branch") || age=""
        if [[ -n "$age" && "$age" -lt "${RALPH_BRANCH_CLEANUP_MIN_AGE_HOURS:-24}" ]]; then
            skipped=$((skipped + 1))
            continue
        fi

        # Squash-merge evidence (git cherry) — the only authorization
        if ! branch_cleanup_is_squashed "$branch" "$main_ref"; then
            skipped=$((skipped + 1))
            continue
        fi

        branch_cleanup_local "$branch" || { skipped=$((skipped + 1)); continue; }
        branch_cleanup_origin "$branch"
        deleted=$((deleted + 1))
    done < <(git branch --list 2>/dev/null | sed 's/^[* ] //')

    if [[ "$candidates" -gt 0 ]]; then
        branch_cleanup_log "INFO" "scanned $candidates ${RALPH_BRANCH_PREFIX}* branches: deleted=$deleted skipped=$skipped"
    fi

    return 0
}
