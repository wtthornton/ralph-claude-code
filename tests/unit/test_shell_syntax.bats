#!/usr/bin/env bats
# TAP-2439 — Local regression test for shell syntax.
#
# Mirrors the CI bash -n step so a broken script gets caught in `npm test`
# instead of slipping through to a PR. Excludes node_modules and .ralph/
# (the latter is a runtime working dir, not a source tree).

bats_require_minimum_version 1.5.0
load '../helpers/test_helper'

REPO_ROOT="${BATS_TEST_DIRNAME}/../.."

@test "TAP-2439: every tracked *.sh passes bash -n" {
    local fail_list=()
    local f
    # Use git ls-files so the test mirrors what CI checks.
    while IFS= read -r f; do
        [[ -f "$REPO_ROOT/$f" ]] || continue
        if ! bash -n "$REPO_ROOT/$f" 2>/dev/null; then
            fail_list+=("$f")
        fi
    done < <(cd "$REPO_ROOT" && git ls-files '*.sh')

    if [[ ${#fail_list[@]} -gt 0 ]]; then
        printf 'bash -n failed for:\n' >&2
        printf '  %s\n' "${fail_list[@]}" >&2
        return 1
    fi
}
