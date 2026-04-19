#!/usr/bin/env bats
# TAP-651: github_issues.sh must reject non-numeric issue IDs before they
# reach JSON construction, and build metadata JSON with jq rather than
# heredoc interpolation.

load '../helpers/test_helper'

GH_LIB="${BATS_TEST_DIRNAME}/../../lib/github_issues.sh"

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"
    mkdir -p .ralph
    export RALPH_DIR=".ralph"
    source "$GH_LIB"
}

teardown() {
    cd /
    rm -rf "$TEST_DIR"
}

@test "TAP-651: ralph_import_issue rejects non-numeric issue id" {
    run ralph_import_issue '0,"evil":"x"'
    assert_failure
    # Must not write the metadata file on rejection
    [[ ! -f .ralph/.github_issue.json ]]
}

@test "TAP-651: ralph_import_issue rejects leading-zero and signed forms" {
    run ralph_import_issue '00'
    assert_failure
    run ralph_import_issue '-5'
    assert_failure
    run ralph_import_issue '5.0'
    assert_failure
    [[ ! -f .ralph/.github_issue.json ]]
}

@test "TAP-651: ralph_import_issue accepts plain positive integers" {
    # We can't actually hit GitHub here — so just make sure the numeric
    # validation doesn't reject a well-formed id. It'll fail later at
    # _gh_detect_repo / _gh_fetch_issue, but the early return code we
    # care about is "not the validation rejection".
    run ralph_import_issue '123'
    # Any non-1 failure from repo detection is fine; we just want to
    # confirm we didn't hit the "Invalid issue number" rejection path.
    ! echo "${output:-}${stderr:-}" | grep -q 'Invalid issue number'
}

@test "TAP-651: heredoc interpolation of issue_num removed from source" {
    # Defense-in-depth: the raw `"number": $issue_num` splice must be gone;
    # the metadata JSON is now built with jq --argjson number.
    run grep -nE '"number": \$issue_num' "$GH_LIB"
    [[ "$status" -ne 0 ]]
    run grep -q -- '--argjson number' "$GH_LIB"
    assert_success
}
