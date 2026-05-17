#!/usr/bin/env bats
# TAP-1880 — lib/branch_cleanup.sh — squash-merged branch janitor.
#
# Covers: happy-path local + origin delete, git-cherry ambiguous-result
# skip, protected-branch skip, prefix-mismatch skip, min-age skip,
# current-branch skip, origin-missing graceful, push-permission-denied
# WARN. Each test stands up a tmpdir git repo (with a fake remote in
# another tmpdir) so detection is real, not stubbed.

bats_require_minimum_version 1.5.0

REPO_ROOT="${BATS_TEST_DIRNAME}/../.."
BRANCH_CLEANUP_LIB="${REPO_ROOT}/lib/branch_cleanup.sh"

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"

    # Origin lives in its own bare repo
    ORIGIN_DIR="$TEST_DIR/origin.git"
    git init --bare --initial-branch=main "$ORIGIN_DIR" >/dev/null 2>&1

    # Working repo, with origin wired up
    WORK_DIR="$TEST_DIR/work"
    git init --initial-branch=main "$WORK_DIR" >/dev/null 2>&1
    cd "$WORK_DIR"
    git config user.email "test@example.com"
    git config user.name "test"
    git config commit.gpgsign false
    git remote add origin "$ORIGIN_DIR"

    # main with an initial commit
    echo "initial" > README.md
    git add README.md && git commit -m "initial" >/dev/null 2>&1
    git push origin main >/dev/null 2>&1

    set +e
    source "$BRANCH_CLEANUP_LIB"
    set -e

    # Default config — each test can override
    export RALPH_BRANCH_CLEANUP_ENABLED=true
    export RALPH_BRANCH_PREFIX=tap-
    export RALPH_BRANCH_CLEANUP_MIN_AGE_HOURS=0  # disable age guard by default
    export RALPH_BRANCH_CLEANUP_PROTECTED="main:master:develop:release/*"
    unset RALPH_CURRENT_BRANCH
}

teardown() {
    cd /
    rm -rf "$TEST_DIR"
}

# Helper: create a branch with a commit, then squash-merge it to main and
# push the squash to origin. Leaves the source branch behind locally + on
# origin (so the test can verify cleanup deletes it).
_make_squashed_branch() {
    local branch="$1"
    # Filename component must not contain '/' or git treats it as a path
    local file="file-${branch//\//_}.txt"
    git checkout -b "$branch" main >/dev/null 2>&1
    echo "work-on-$branch" > "$file"
    git add "$file" && git commit -m "work on $branch" >/dev/null 2>&1
    git push origin "$branch" >/dev/null 2>&1
    git checkout main >/dev/null 2>&1
    git merge --squash "$branch" >/dev/null 2>&1
    git commit -m "squash-merge $branch" >/dev/null 2>&1
    git push origin main >/dev/null 2>&1
}

_make_unmerged_branch() {
    local branch="$1"
    local file="file-${branch//\//_}.txt"
    git checkout -b "$branch" main >/dev/null 2>&1
    echo "wip-on-$branch" > "$file"
    git add "$file" && git commit -m "wip on $branch" >/dev/null 2>&1
    git checkout main >/dev/null 2>&1
}

# -----------------------------------------------------------------------------
# is_protected
# -----------------------------------------------------------------------------

@test "TAP-1880: branch_cleanup_is_protected matches main / master / develop" {
    branch_cleanup_is_protected "main"
    branch_cleanup_is_protected "master"
    branch_cleanup_is_protected "develop"
}

@test "TAP-1880: branch_cleanup_is_protected matches release/* glob" {
    branch_cleanup_is_protected "release/2026.05"
    branch_cleanup_is_protected "release/v1.0"
}

@test "TAP-1880: branch_cleanup_is_protected rejects normal tap-* branches" {
    ! branch_cleanup_is_protected "tap-1234-some-work"
    ! branch_cleanup_is_protected "tap-9999"
}

# -----------------------------------------------------------------------------
# is_squashed
# -----------------------------------------------------------------------------

@test "TAP-1880: branch_cleanup_is_squashed returns 0 for squash-merged branch" {
    _make_squashed_branch "tap-1001-squashed"
    branch_cleanup_is_squashed "tap-1001-squashed" "main"
}

@test "TAP-1880: branch_cleanup_is_squashed returns 1 for unmerged branch" {
    _make_unmerged_branch "tap-1002-unmerged"
    run branch_cleanup_is_squashed "tap-1002-unmerged" "main"
    [ "$status" -eq 1 ]
}

@test "TAP-1880: branch_cleanup_is_squashed returns 2 (ambiguous) for branch identical to main" {
    git checkout -b "tap-1003-identical" main >/dev/null 2>&1
    git checkout main >/dev/null 2>&1
    run branch_cleanup_is_squashed "tap-1003-identical" "main"
    [ "$status" -eq 2 ]
}

# -----------------------------------------------------------------------------
# ralph_cleanup_merged_branches — happy path
# -----------------------------------------------------------------------------

@test "TAP-1880: happy path — squash-merged tap-* branch is deleted locally AND on origin" {
    _make_squashed_branch "tap-2001-happy"

    # Sanity: branch exists both places before cleanup
    git rev-parse --verify "tap-2001-happy" >/dev/null 2>&1
    git ls-remote --heads origin "tap-2001-happy" 2>/dev/null | grep -q .

    ralph_cleanup_merged_branches main

    # Branch is gone both places
    ! git rev-parse --verify "tap-2001-happy" >/dev/null 2>&1
    ! git ls-remote --heads origin "tap-2001-happy" 2>/dev/null | grep -q .
}

# -----------------------------------------------------------------------------
# Safety: ambiguous git-cherry result is NEVER deleted
# -----------------------------------------------------------------------------

@test "TAP-1880: ambiguous git-cherry result skips deletion" {
    _make_unmerged_branch "tap-2002-unmerged"

    ralph_cleanup_merged_branches main

    # Unmerged branch must survive
    git rev-parse --verify "tap-2002-unmerged" >/dev/null 2>&1
}

# -----------------------------------------------------------------------------
# Safety: protected branches never deleted (even when they look squashed)
# -----------------------------------------------------------------------------

@test "TAP-1880: protected branch (release/*) is never deleted" {
    _make_squashed_branch "release/2026.05"
    # Prefix would normally exclude it, so override
    export RALPH_BRANCH_PREFIX="release"

    ralph_cleanup_merged_branches main

    git rev-parse --verify "release/2026.05" >/dev/null 2>&1
}

# -----------------------------------------------------------------------------
# Safety: prefix mismatch — non-Ralph branches ignored
# -----------------------------------------------------------------------------

@test "TAP-1880: prefix mismatch — feature/* squash-merged branch is left alone" {
    _make_squashed_branch "feature/some-work"

    ralph_cleanup_merged_branches main

    git rev-parse --verify "feature/some-work" >/dev/null 2>&1
}

# -----------------------------------------------------------------------------
# Safety: min-age — branches younger than threshold are skipped
# -----------------------------------------------------------------------------

@test "TAP-1880: min-age threshold skips branches younger than the cutoff" {
    _make_squashed_branch "tap-2003-young"
    export RALPH_BRANCH_CLEANUP_MIN_AGE_HOURS=24

    ralph_cleanup_merged_branches main

    # Just-created branch is < 24h old → survives
    git rev-parse --verify "tap-2003-young" >/dev/null 2>&1
}

# -----------------------------------------------------------------------------
# Safety: currently-checked-out branch is never deleted
# -----------------------------------------------------------------------------

@test "TAP-1880: currently-checked-out branch is never deleted even if squash-merged" {
    _make_squashed_branch "tap-2004-current"
    # _make_squashed_branch left us on main; switch back to the candidate
    git checkout "tap-2004-current" >/dev/null 2>&1

    ralph_cleanup_merged_branches main

    git rev-parse --verify "tap-2004-current" >/dev/null 2>&1
}

@test "TAP-1880: RALPH_CURRENT_BRANCH pin is never deleted" {
    _make_squashed_branch "tap-2005-pinned"
    export RALPH_CURRENT_BRANCH="tap-2005-pinned"

    ralph_cleanup_merged_branches main

    git rev-parse --verify "tap-2005-pinned" >/dev/null 2>&1
}

# -----------------------------------------------------------------------------
# Graceful: missing origin remote — local-only cleanup still works
# -----------------------------------------------------------------------------

@test "TAP-1880: origin-missing — local cleanup still happens, returns 0" {
    _make_squashed_branch "tap-2006-no-origin"
    git remote remove origin

    run ralph_cleanup_merged_branches main
    [ "$status" -eq 0 ]

    ! git rev-parse --verify "tap-2006-no-origin" >/dev/null 2>&1
}

# -----------------------------------------------------------------------------
# Graceful: push --delete failure is WARN-only — no rc bubble-up
# -----------------------------------------------------------------------------

@test "TAP-1880: push --delete failure (broken remote URL) does not fail the orchestrator" {
    _make_squashed_branch "tap-2007-bad-origin"
    # Break origin so the push fails. Local delete still succeeds.
    git remote set-url origin "/no/such/path"

    run ralph_cleanup_merged_branches main
    [ "$status" -eq 0 ]

    ! git rev-parse --verify "tap-2007-bad-origin" >/dev/null 2>&1
}

# -----------------------------------------------------------------------------
# Toggle: RALPH_BRANCH_CLEANUP_ENABLED=false → no-op
# -----------------------------------------------------------------------------

@test "TAP-1880: RALPH_BRANCH_CLEANUP_ENABLED=false skips the entire scan" {
    _make_squashed_branch "tap-2008-disabled"
    export RALPH_BRANCH_CLEANUP_ENABLED=false

    ralph_cleanup_merged_branches main

    git rev-parse --verify "tap-2008-disabled" >/dev/null 2>&1
}

# -----------------------------------------------------------------------------
# Sanity: not-in-git-repo → graceful no-op
# -----------------------------------------------------------------------------

@test "TAP-1880: non-git directory → no-op return 0" {
    cd "$TEST_DIR"
    rm -rf bare && mkdir bare && cd bare

    run ralph_cleanup_merged_branches main
    [ "$status" -eq 0 ]
}

# -----------------------------------------------------------------------------
# Sanity: missing main_ref → graceful no-op
# -----------------------------------------------------------------------------

@test "TAP-1880: missing main ref → no-op return 0" {
    _make_squashed_branch "tap-2009-no-main-ref"

    run ralph_cleanup_merged_branches "no-such-ref"
    [ "$status" -eq 0 ]
    # Branch survives — we couldn't compute cherry without the ref
    git rev-parse --verify "tap-2009-no-main-ref" >/dev/null 2>&1
}
