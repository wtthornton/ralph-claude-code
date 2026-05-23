#!/usr/bin/env bats
# AgentForge feedback #1 — RALPH_PUSH_EVERY_LOOP / ralph_push_pending_commits.
#
# After each successful loop iteration, the harness pushes pending commits
# to origin so the autonomous work is upstream-visible. Closes the
# multi-epic state-drift pattern where local main accumulated 12+ unpushed
# commits while Linear ticked tickets Done.
#
# Behavior under test:
#   - Disabled via RALPH_PUSH_EVERY_LOOP=false → no push
#   - DRY_RUN=true                              → no push
#   - Not in a git repo                         → silent skip (no log noise)
#   - No upstream branch                        → silent skip
#   - Zero unpushed commits                     → silent skip
#   - Happy path (1+ unpushed commit)           → push fires, origin gets it
#   - Push failure                              → WARN + .push-failure.err written

bats_require_minimum_version 1.5.0
load '../helpers/test_helper'

REPO_ROOT="${BATS_TEST_DIRNAME}/../.."

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"

    # Bare origin
    ORIGIN_DIR="$TEST_DIR/origin.git"
    git init --bare --initial-branch=main "$ORIGIN_DIR" >/dev/null 2>&1

    # Working repo
    WORK_DIR="$TEST_DIR/work"
    git init --initial-branch=main "$WORK_DIR" >/dev/null 2>&1
    cd "$WORK_DIR"
    git config user.email "t@example.com"
    git config user.name "t"
    git config commit.gpgsign false
    git remote add origin "$ORIGIN_DIR"
    echo "seed" > README.md
    git add README.md && git commit -m "seed" >/dev/null 2>&1
    git push -u origin main >/dev/null 2>&1

    export RALPH_DIR="$WORK_DIR/.ralph"
    mkdir -p "$RALPH_DIR"
    export RALPH_PROJECT_ROOT="$WORK_DIR"

    # Capture log_status emissions so we can assert on them
    LOG_LINES=()
    log_status() { LOG_LINES+=("$1|$2"); }
    export -f log_status

    # Extract just the helper body from ralph_loop.sh and eval it. TAP-2473
    # adds the _ralph_push_log_failure sibling helper — pick that up too so
    # the rebase-failure branch has its failure-log writer.
    eval "$(awk '/^ralph_push_pending_commits\(\) \{$/,/^\}$/' "$REPO_ROOT/ralph_loop.sh")"
    eval "$(awk '/^_ralph_push_log_failure\(\) \{$/,/^\}$/' "$REPO_ROOT/ralph_loop.sh")"
}

teardown() {
    cd /
    rm -rf "$TEST_DIR"
    unset RALPH_DIR RALPH_PROJECT_ROOT
    unset RALPH_PUSH_EVERY_LOOP DRY_RUN
}

# Helper to check if any captured log line matches a substring
_has_log() {
    local needle="$1"
    for line in "${LOG_LINES[@]}"; do
        [[ "$line" == *"$needle"* ]] && return 0
    done
    return 1
}

@test "push: disabled via RALPH_PUSH_EVERY_LOOP=false → silent skip" {
    export RALPH_PUSH_EVERY_LOOP=false
    echo "more" >> README.md
    git add README.md && git commit -m "unpushed" >/dev/null 2>&1

    ralph_push_pending_commits

    # Should not have pushed; origin still at seed
    local origin_head work_seed
    origin_head=$(git -C "$ORIGIN_DIR" rev-parse main)
    work_seed=$(git -C "$WORK_DIR" rev-parse 'HEAD~1')
    [[ "$origin_head" == "$work_seed" ]] \
        || fail "RALPH_PUSH_EVERY_LOOP=false should have prevented the push"
    ! _has_log "push:" \
        || fail "disabled path should be silent — no 'push:' log lines"
}

@test "push: DRY_RUN=true → silent skip" {
    export DRY_RUN=true
    echo "more" >> README.md
    git add README.md && git commit -m "unpushed" >/dev/null 2>&1

    ralph_push_pending_commits

    ! _has_log "push:" || fail "DRY_RUN should suppress the push entirely"
}

@test "push: not in a git repo → silent skip" {
    export RALPH_PROJECT_ROOT="$TEST_DIR/not-a-repo"
    mkdir -p "$RALPH_PROJECT_ROOT"

    ralph_push_pending_commits

    ! _has_log "push:" || fail "non-git directory should be silent"
}

@test "push: zero unpushed commits → silent skip" {
    # work_dir is already in sync with origin/main after setup
    ralph_push_pending_commits

    ! _has_log "push:" || fail "zero-ahead should be silent"
}

@test "push: no upstream branch (orphan) → silent skip" {
    git checkout -b orphan-branch >/dev/null 2>&1
    echo "orphan work" > orphan.txt
    git add orphan.txt && git commit -m "orphan commit" >/dev/null 2>&1

    ralph_push_pending_commits

    ! _has_log "push:" || fail "no-upstream branch should be silent"
}

@test "push: happy path — one unpushed commit lands on origin" {
    echo "new work" > new.txt
    git add new.txt && git commit -m "new work" >/dev/null 2>&1
    local local_head
    local_head=$(git rev-parse HEAD)

    ralph_push_pending_commits

    local origin_head
    origin_head=$(git -C "$ORIGIN_DIR" rev-parse main)
    [[ "$origin_head" == "$local_head" ]] \
        || fail "expected origin to advance to local HEAD ($local_head), got $origin_head"
    _has_log "succeeded" || fail "expected INFO 'push: succeeded' log"
}

@test "push: failure writes .push-failure.err and does not propagate" {
    # Stage an unpushed commit
    echo "more" >> README.md
    git add README.md && git commit -m "needs push" >/dev/null 2>&1
    # Break the remote URL so push fails — local commit still ahead
    git remote set-url origin "$TEST_DIR/nonexistent-bare.git"

    # Helper must return 0 even on push failure (CB must not trip). We use
    # `run` because we care about the exit code; LOG_LINES from inside the
    # subshell doesn't carry back, so we assert on the diagnostic file
    # instead — a stronger observable than the WARN log anyway.
    run ralph_push_pending_commits
    [[ "$status" -eq 0 ]] || fail "helper must return 0 on push failure (got $status)"

    [[ -s "$RALPH_DIR/.push-failure.err" ]] \
        || fail "expected .push-failure.err with diagnostic content"
    grep -q "git push failed" "$RALPH_DIR/.push-failure.err" \
        || fail "expected diagnostic header in .push-failure.err"
}

@test "push: wired into execute_claude_code success path" {
    grep -qE 'ralph_push_pending_commits[[:space:]]*$' "$REPO_ROOT/ralph_loop.sh" \
        || fail "ralph_loop.sh should call ralph_push_pending_commits in the success branch"
}

# =============================================================================
# TAP-2473: fetch+rebase recovery on rejected push.
#
# Cross-project audit 2026-05-22/23 found stranded commits in
# .push-failure.err across all 3 sibling projects from "fetch first" /
# "cannot lock ref" rejections (remote moved between agent's commit and
# harness push). Pre-TAP-2473 the helper logged the rejection and moved
# on; commits sat local while Linear ticked Done.
#
# New contract: rejected push → fetch origin → if upstream moved, rebase
# --autostash → retry push once. Conflict / second-push-failure → abort
# + log as today. Hard rule: no --force, no --force-with-lease (R0).
# =============================================================================

# Helper: create a "remote-moved" scenario. Pushes a side-branch commit
# directly to ORIGIN_DIR/main from a fresh clone, simulating another
# repo / human / sibling Ralph having advanced the upstream while WORK_DIR
# kept its own local commit.
_advance_origin() {
    local _content="$1"  # file content for the remote commit
    local _side_clone="$TEST_DIR/side"
    rm -rf "$_side_clone"
    git clone "$ORIGIN_DIR" "$_side_clone" >/dev/null 2>&1
    (
        cd "$_side_clone"
        git config user.email "side@example.com"
        git config user.name "side"
        git config commit.gpgsign false
        printf '%s\n' "$_content" > origin-side-work.txt
        git add origin-side-work.txt
        git commit -m "origin side commit" >/dev/null 2>&1
        git push origin main >/dev/null 2>&1
    )
}

@test "TAP-2473: rejected push + clean rebase + retry succeeds" {
    # 1) Local commit, no conflict path
    echo "local work" > local-only.txt
    git add local-only.txt && git commit -m "local commit" >/dev/null 2>&1
    local _local_sha
    _local_sha=$(git rev-parse HEAD)

    # 2) Advance origin with an unrelated file (no rebase conflict)
    _advance_origin "side-content"

    # 3) Push must initially be rejected, recover via fetch+rebase
    ralph_push_pending_commits

    # Assertions:
    #   - Origin now has BOTH our local commit AND the side commit
    #   - Origin HEAD must contain our local-only.txt file
    #   - INFO log mentions "retry succeeded after fetch+rebase"
    local _origin_head
    _origin_head=$(git -C "$ORIGIN_DIR" rev-parse main)
    [[ "$_origin_head" != "$_local_sha" ]] \
        || fail "origin HEAD should differ from pre-rebase local SHA after history rewrite"
    git -C "$ORIGIN_DIR" ls-tree -r main --name-only | grep -q '^local-only.txt$' \
        || fail "origin should contain rebased local-only.txt commit"
    git -C "$ORIGIN_DIR" ls-tree -r main --name-only | grep -q '^origin-side-work.txt$' \
        || fail "origin should still contain the side commit"
    _has_log "rebase succeeded" \
        || fail "expected INFO log about rebase succeeding"
    _has_log "retry succeeded" \
        || fail "expected INFO log about retry-after-rebase succeeding"
    # No .push-failure.err on successful recovery
    [[ ! -s "$RALPH_DIR/.push-failure.err" ]] \
        || fail "successful rebase-retry must not leave .push-failure.err: $(cat "$RALPH_DIR/.push-failure.err")"
}

@test "TAP-2473: rejected push + rebase conflict → abort + .push-failure.err" {
    # 1) Local commit modifies README.md
    echo "local readme edit" >> README.md
    git add README.md && git commit -m "local readme edit" >/dev/null 2>&1

    # 2) Advance origin's README.md the SAME way → conflict on rebase
    local _side_clone="$TEST_DIR/side"
    rm -rf "$_side_clone"
    git clone "$ORIGIN_DIR" "$_side_clone" >/dev/null 2>&1
    (
        cd "$_side_clone"
        git config user.email "side@example.com"
        git config user.name "side"
        git config commit.gpgsign false
        echo "origin readme edit (different content)" >> README.md
        git add README.md
        git commit -m "origin readme edit (will conflict)" >/dev/null 2>&1
        git push origin main >/dev/null 2>&1
    )

    # 3) Helper must hit rejection → fetch → rebase-conflict → abort → log
    run ralph_push_pending_commits
    [[ "$status" -eq 0 ]] || fail "helper must return 0 on rebase failure (got $status)"

    # 4) Working tree must NOT be left mid-rebase
    [[ ! -d "$WORK_DIR/.git/rebase-merge" && ! -d "$WORK_DIR/.git/rebase-apply" ]] \
        || fail "rebase state must be aborted (no .git/rebase-* dirs left behind)"

    # 5) .push-failure.err must be written with original push failure
    [[ -s "$RALPH_DIR/.push-failure.err" ]] \
        || fail "expected .push-failure.err on rebase-conflict path"
    grep -q "git push failed" "$RALPH_DIR/.push-failure.err" \
        || fail "expected diagnostic header"

    # 6) No --force / --force-with-lease must have been attempted
    ! _has_log "force" \
        || fail "TAP-2473 hard rule: no force-push under any branch"
}

@test "TAP-2473: helper extraction does not introduce force-push string" {
    # Belt-and-suspenders: scan the live ralph_push_pending_commits body
    # for any --force token. Future drift caught here before review.
    awk '/^ralph_push_pending_commits\(\) \{$/,/^\}$/' "$REPO_ROOT/ralph_loop.sh" \
        | grep -qE -- '--force\b|--force-with-lease\b' \
        && fail "ralph_push_pending_commits must not use --force / --force-with-lease (R0 hard rule)"
    return 0
}

@test "TAP-2473: DRY_RUN short-circuits even with rejection scenario set up" {
    # Set up the same rejected-push scenario as above, but expect no recovery
    # path because DRY_RUN should skip the whole function.
    echo "local work" > local-only.txt
    git add local-only.txt && git commit -m "local commit" >/dev/null 2>&1
    _advance_origin "side-content"

    export DRY_RUN=true
    ralph_push_pending_commits

    ! _has_log "push:" || fail "DRY_RUN must suppress everything (no fetch/rebase log lines)"
    [[ ! -s "$RALPH_DIR/.push-failure.err" ]] \
        || fail "DRY_RUN must not write .push-failure.err"
}

@test "TAP-2473: RALPH_PUSH_EVERY_LOOP=false short-circuits even with rejection scenario" {
    echo "local work" > local-only.txt
    git add local-only.txt && git commit -m "local commit" >/dev/null 2>&1
    _advance_origin "side-content"

    export RALPH_PUSH_EVERY_LOOP=false
    ralph_push_pending_commits

    ! _has_log "push:" || fail "disabled knob must suppress everything"
    [[ ! -s "$RALPH_DIR/.push-failure.err" ]] \
        || fail "disabled knob must not write .push-failure.err"
}
