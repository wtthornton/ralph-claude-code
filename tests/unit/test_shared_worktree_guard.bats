#!/usr/bin/env bats
# TAP-2797: Shared-worktree foreign-WIP guard.
# The instance lock (LOCK-1) stops a second ralph_loop.sh but not a manual /
# interactive writer sharing the same git working tree. ralph_guard_shared_worktree
# detects uncommitted TRACKED changes Ralph did not author and WARNs (default)
# or refuses (RALPH_REQUIRE_CLEAN_TREE=true). `.ralph/` state is Ralph-owned and
# must not count as foreign WIP.

REPO_ROOT_FIXED="${BATS_TEST_DIRNAME}/../.."

setup() {
    export TEST_TEMP_DIR="$(mktemp -d "${BATS_TEST_TMPDIR:-/tmp}/sw_guard.XXXXXX")"
    cd "$TEST_TEMP_DIR"
    mkdir -p .ralph .ralph/logs
    export RALPH_DIR="$TEST_TEMP_DIR/.ralph"
    export LOG_DIR="$RALPH_DIR/logs"
    export DRY_RUN=false

    # Real git repo with one committed file so the tree starts clean.
    git init -q .
    git config user.email test@example.com
    git config user.name "Test"
    echo "v1" > tracked.txt
    git add tracked.txt .gitignore 2>/dev/null || git add tracked.txt
    git commit -qm "init"

    # Source ralph_loop.sh so ralph_guard_shared_worktree is defined.
    set --
    # shellcheck disable=SC1090
    source "$REPO_ROOT_FIXED/ralph_loop.sh"
}

teardown() {
    cd /
    [[ -n "$TEST_TEMP_DIR" && -d "$TEST_TEMP_DIR" ]] && rm -rf "$TEST_TEMP_DIR"
}

@test "clean tree: guard returns 0 silently" {
    run ralph_guard_shared_worktree
    [ "$status" -eq 0 ]
    [[ "$output" != *"TAP-2797"* ]]
}

@test "foreign WIP (tracked edit): guard WARNs but returns 0 by default" {
    echo "manual edit" >> tracked.txt
    run ralph_guard_shared_worktree
    [ "$status" -eq 0 ]
    [[ "$output" == *"TAP-2797"* ]]
    [[ "$output" == *"dedicated git worktree"* ]]
}

@test "foreign WIP + RALPH_REQUIRE_CLEAN_TREE=true: guard refuses (exit 1)" {
    echo "manual edit" >> tracked.txt
    export RALPH_REQUIRE_CLEAN_TREE=true
    run ralph_guard_shared_worktree
    [ "$status" -eq 1 ]
    [[ "$output" == *"refusing to start"* ]]
}

@test "foreign WIP + RALPH_ALLOW_SHARED_TREE=true: guard proceeds silently" {
    echo "manual edit" >> tracked.txt
    export RALPH_ALLOW_SHARED_TREE=true
    run ralph_guard_shared_worktree
    [ "$status" -eq 0 ]
    [[ "$output" != *"TAP-2797"* ]]
}

@test ".ralph/ changes alone are Ralph-owned, not foreign WIP" {
    # Track a .ralph file (PROMPT.md is committed in real projects) then dirty it.
    mkdir -p .ralph
    echo "task" > .ralph/PROMPT.md
    git add -f .ralph/PROMPT.md
    git commit -qm "add prompt"
    echo "edited by ralph" >> .ralph/PROMPT.md
    run ralph_guard_shared_worktree
    [ "$status" -eq 0 ]
    [[ "$output" != *"TAP-2797"* ]]
}

@test "staged (cached) foreign change is detected" {
    echo "staged edit" >> tracked.txt
    git add tracked.txt
    run ralph_guard_shared_worktree
    [ "$status" -eq 0 ]
    [[ "$output" == *"TAP-2797"* ]]
}

@test "outside a git repo: guard is a no-op" {
    local nongit
    nongit="$(mktemp -d "${BATS_TEST_TMPDIR:-/tmp}/nongit.XXXXXX")"
    cd "$nongit"
    run ralph_guard_shared_worktree
    [ "$status" -eq 0 ]
    [[ "$output" != *"TAP-2797"* ]]
    rm -rf "$nongit"
}

@test "ralph_guard_shared_worktree is called after acquire_instance_lock in main()" {
    # Source-level ordering assertion: the guard must run after the lock so a
    # second ralph_loop.sh is rejected first, then foreign WIP is checked.
    local lock_line guard_line
    lock_line=$(grep -n 'acquire_instance_lock$' "$REPO_ROOT_FIXED/ralph_loop.sh" | tail -1 | cut -d: -f1)
    guard_line=$(grep -n 'ralph_guard_shared_worktree$' "$REPO_ROOT_FIXED/ralph_loop.sh" | tail -1 | cut -d: -f1)
    [ -n "$lock_line" ]
    [ -n "$guard_line" ]
    [ "$guard_line" -gt "$lock_line" ]
}
