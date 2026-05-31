#!/usr/bin/env bats
# TAP-2599 (Issue 2): a squash-merge must delete the remote feature branch so
# origin doesn't accumulate merged branches (observed: PR #406 merged but
# origin/tap-2599-... remained). Every `gh pr merge --squash` path Ralph
# drives — the async merge helper AND the resume-guidance prompt — must carry
# `--delete-branch`.

bats_require_minimum_version 1.5.0

REPO_ROOT="${BATS_TEST_DIRNAME}/../.."

@test "TAP-2599: pending_merges.sh squash-merge uses --delete-branch" {
    grep -q 'gh pr merge "\$pr_number" --squash --delete-branch' \
        "$REPO_ROOT/lib/pending_merges.sh" \
        || fail "pending_merges_poll must merge with --delete-branch"
}

@test "TAP-2599: ralph_loop.sh resume prompt never suggests bare 'gh pr merge --squash --auto'" {
    # Any --auto merge guidance handed to the agent must include --delete-branch
    # on the same invocation so GitHub deletes the branch when auto-merge fires.
    run grep -oE 'gh pr merge --squash --auto[^`]*' "$REPO_ROOT/ralph_loop.sh"
    [[ "$status" -eq 0 ]] || fail "expected at least one --auto merge directive in the prompt"
    while IFS= read -r line; do
        [[ "$line" == *"--delete-branch"* ]] \
            || fail "bare auto-merge without --delete-branch: $line"
    done <<< "$output"
}
