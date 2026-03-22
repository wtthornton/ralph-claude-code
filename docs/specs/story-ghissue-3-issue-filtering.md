# Story GHISSUE-3: GitHub Issue Filtering

**Epic:** [RALPH-GHISSUE](epic-github-issue-integration.md)
**Priority:** Medium
**Status:** Open
**Effort:** Small
**Component:** `ralph_loop.sh`, `lib/github_issues.sh`

---

## Problem

Users need to find the right issue to work on from their repository. Without filtering, they must manually browse GitHub and then pass the issue number to `ralph --issue`. A basic listing and filtering capability makes issue selection faster.

## Solution

Add `ralph --issues` to list open issues with optional filters for labels, assignees, and milestones. Display is tabular for quick scanning. Selection feeds into `ralph --issue <number>`.

## Implementation

1. Add `list_github_issues()` to `lib/github_issues.sh`:
   ```bash
   list_github_issues() {
     local label_filter="$1"
     local assignee_filter="$2"
     local milestone_filter="$3"
     local limit="${4:-20}"

     local args="--state open --limit $limit --json number,title,labels,assignees,milestone"

     [ -n "$label_filter" ] && args="$args --label $label_filter"
     [ -n "$assignee_filter" ] && args="$args --assignee $assignee_filter"
     [ -n "$milestone_filter" ] && args="$args --milestone $milestone_filter"

     gh issue list $args | jq -r '.[] | [.number, .title, (.labels | map(.name) | join(","))] | @tsv' | \
       column -t -s $'\t'
   }
   ```

2. Add CLI flags:
   ```bash
   --issues)        LIST_ISSUES=true; shift ;;
   --label)         ISSUE_LABEL="$2"; shift 2 ;;
   --assignee)      ISSUE_ASSIGNEE="$2"; shift 2 ;;
   --milestone)     ISSUE_MILESTONE="$2"; shift 2 ;;
   ```

3. Usage examples:
   ```bash
   ralph --issues                           # List all open issues
   ralph --issues --label bug               # Filter by label
   ralph --issues --assignee @me            # My assigned issues
   ralph --issues --milestone v2.0          # Milestone filter
   ralph --issues --label "priority:high"   # Priority filter
   ```

4. Add `--issues --json` for machine-readable output

### Key Design Decisions

1. **Delegating to `gh`:** All filtering is done by `gh issue list` — no client-side filtering logic needed.
2. **Default limit 20:** Prevents overwhelming output. Users can override with `--limit`.
3. **Tabular display:** Number, title, labels in columns for quick scanning.

## Testing

```bash
@test "ralph --issues lists open issues" {
  mock_gh_issue_list 5
  run ralph --issues --project "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  lines=$(echo "$output" | wc -l)
  [ "$lines" -ge 1 ]
}

@test "ralph --issues --label filters by label" {
  run ralph --issues --label bug --project "$TEST_PROJECT"
  [ "$status" -eq 0 ]
}

@test "ralph --issues --json outputs valid JSON" {
  run ralph --issues --json --project "$TEST_PROJECT"
  echo "$output" | jq -e '.'
}

@test "ralph --issues fails gracefully without gh" {
  export PATH="/usr/bin"
  run ralph --issues --project "$TEST_PROJECT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"gh CLI required"* ]]
}
```

## Acceptance Criteria

- [ ] `ralph --issues` lists open issues in tabular format
- [ ] `--label`, `--assignee`, `--milestone` filters work
- [ ] `--json` outputs machine-readable JSON
- [ ] Default limit of 20 issues
- [ ] Issue numbers displayed for easy `ralph --issue N` follow-up
- [ ] Graceful error when `gh` CLI not available
