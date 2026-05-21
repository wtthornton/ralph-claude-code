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

    # Extract just the helper body from ralph_loop.sh and eval it
    eval "$(awk '/^ralph_push_pending_commits\(\) \{$/,/^\}$/' "$REPO_ROOT/ralph_loop.sh")"
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
