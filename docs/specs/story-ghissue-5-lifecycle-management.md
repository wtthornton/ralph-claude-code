# Story GHISSUE-5: Issue Lifecycle Management

**Epic:** [RALPH-GHISSUE](epic-github-issue-integration.md)
**Priority:** Medium
**Status:** Open
**Effort:** Small
**Component:** `lib/github_issues.sh`, `.ralph/hooks/on-stop.sh`

---

## Problem

When Ralph completes work on a GitHub issue, the issue remains open. Users must manually close it, link the commit, and update labels. For standalone Ralph users, automating these lifecycle steps saves time and keeps GitHub state consistent.

## Solution

After Ralph's loop exits with EXIT_SIGNAL, automatically:
1. Comment on the issue with a summary of completed work
2. Optionally close the issue (with user confirmation or flag)
3. Link the most recent commit SHA to the issue

## Implementation

1. Add `complete_github_issue()` to `lib/github_issues.sh`:
   ```bash
   complete_github_issue() {
     local issue_number=$(cat .ralph/.github_issue_number 2>/dev/null)
     [ -z "$issue_number" ] && return 0  # No issue context, skip

     local status_json=$(cat .ralph/status.json)
     local progress=$(echo "$status_json" | jq -r '.PROGRESS_SUMMARY')
     local commit_sha=$(git rev-parse HEAD 2>/dev/null)

     # Comment with completion summary
     local comment="## Ralph Completion Report

**Status:** Completed
**Commit:** ${commit_sha:0:7}
**Summary:** $progress

---
_Automated by [Ralph](https://github.com/ralphclaude/ralph-claude-code)_"

     gh issue comment "$issue_number" --body "$comment"

     # Close issue if configured
     if [ "$RALPH_AUTO_CLOSE_ISSUES" = "true" ]; then
       gh issue close "$issue_number" --comment "Closed by Ralph — work completed in $commit_sha"
     fi

     # Add label
     gh issue edit "$issue_number" --add-label "agent:completed" 2>/dev/null || true
   }
   ```

2. Integrate into loop exit path (after EXIT_SIGNAL detected, before final cleanup)

3. Configuration:
   ```bash
   RALPH_AUTO_CLOSE_ISSUES="false"      # Close issues on completion (default: false)
   RALPH_ISSUE_COMMENT="true"           # Comment completion summary (default: true)
   RALPH_ISSUE_LABEL="agent:completed"  # Label to add on completion
   ```

4. Add failure lifecycle:
   ```bash
   fail_github_issue() {
     local issue_number=$(cat .ralph/.github_issue_number 2>/dev/null)
     [ -z "$issue_number" ] && return 0

     gh issue comment "$issue_number" --body "## Ralph Failed
**Reason:** Circuit breaker tripped / rate limit / error
**Last status:** $(jq -r '.PROGRESS_SUMMARY' .ralph/status.json)

_Needs manual intervention._"

     gh issue edit "$issue_number" --add-label "agent:failed" 2>/dev/null || true
   }
   ```

### Key Design Decisions

1. **Auto-close default off:** Closing issues is a significant action. Users must opt in via `RALPH_AUTO_CLOSE_ISSUES=true`.
2. **Comment always:** Completion comments are low-risk and high-value. Default on.
3. **Failure tracking:** Failed issues get labeled so users can filter and retry.
4. **No issue assignment changes:** Ralph doesn't reassign issues. That's a team workflow concern (TheStudio territory).

## Testing

```bash
@test "completion comment posted on EXIT_SIGNAL" {
  echo "42" > .ralph/.github_issue_number
  mock_exit_signal
  run complete_github_issue
  [ "$status" -eq 0 ]
  # Verify gh issue comment was called
  assert_gh_called "issue comment 42"
}

@test "issue closed when RALPH_AUTO_CLOSE_ISSUES=true" {
  export RALPH_AUTO_CLOSE_ISSUES="true"
  echo "42" > .ralph/.github_issue_number
  run complete_github_issue
  assert_gh_called "issue close 42"
}

@test "issue NOT closed when RALPH_AUTO_CLOSE_ISSUES=false" {
  export RALPH_AUTO_CLOSE_ISSUES="false"
  echo "42" > .ralph/.github_issue_number
  run complete_github_issue
  refute_gh_called "issue close"
}

@test "failure comment posted on circuit breaker trip" {
  echo "42" > .ralph/.github_issue_number
  run fail_github_issue
  assert_gh_called "issue comment 42"
  assert_gh_called "issue edit 42 --add-label agent:failed"
}

@test "no GitHub calls when no issue context" {
  rm -f .ralph/.github_issue_number
  run complete_github_issue
  [ "$status" -eq 0 ]
  refute_gh_called "issue"
}
```

## Acceptance Criteria

- [ ] Completion comment posted to GitHub issue on EXIT_SIGNAL
- [ ] Comment includes progress summary and commit SHA
- [ ] Issue closed only when `RALPH_AUTO_CLOSE_ISSUES=true`
- [ ] `agent:completed` label added on success
- [ ] `agent:failed` label added on failure with failure reason
- [ ] No GitHub API calls when no issue context (`.github_issue_number` missing)
- [ ] Configuration via `.ralphrc` and `ralph.config.json`
