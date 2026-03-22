# Story GHISSUE-1: Plan Import from GitHub Issue

**Epic:** [RALPH-GHISSUE](epic-github-issue-integration.md)
**Priority:** Important
**Status:** Open
**Effort:** Medium
**Component:** `ralph_loop.sh`, `lib/task_sources.sh`, new `lib/github_issues.sh`

---

## Problem

Users must manually copy GitHub issue descriptions into `.ralph/fix_plan.md`. For standalone Ralph users working on their own repos, this is friction that should be automated. The basic flow — read issue, extract tasks, write fix_plan.md — is the foundation for all other GitHub issue features.

## Solution

Add `ralph --issue <number>` to import a single GitHub issue into fix_plan.md. Uses `gh` CLI for GitHub API access. Falls back to GitHub API with `GITHUB_TOKEN` if `gh` is not installed.

## Implementation

1. Create `lib/github_issues.sh`:
   ```bash
   import_github_issue() {
     local issue_number="$1"
     local project_dir="$2"

     # Detect repo from git remote
     local repo=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null)
     if [ -z "$repo" ]; then
       repo=$(git remote get-url origin | sed 's/.*github.com[:/]\(.*\)\.git/\1/')
     fi

     # Fetch issue
     local issue_json=$(gh issue view "$issue_number" --repo "$repo" --json title,body,labels,assignees,milestone)
     local title=$(echo "$issue_json" | jq -r '.title')
     local body=$(echo "$issue_json" | jq -r '.body')

     # Extract task list from issue body
     # Supports: - [ ] task, * [ ] task, numbered lists
     local tasks=$(echo "$body" | grep -E '^\s*[-*]\s*\[[ x]\]' || true)

     if [ -n "$tasks" ]; then
       # Issue has a task list — use it directly
       echo "# $title (Issue #$issue_number)" > "$project_dir/.ralph/fix_plan.md"
       echo "" >> "$project_dir/.ralph/fix_plan.md"
       echo "$tasks" >> "$project_dir/.ralph/fix_plan.md"
     else
       # No task list — use Claude to generate one from the description
       generate_plan_from_description "$title" "$body" "$project_dir"
     fi

     # Store issue metadata for lifecycle management
     echo "$issue_json" > "$project_dir/.ralph/.github_issue.json"
     echo "$issue_number" > "$project_dir/.ralph/.github_issue_number"
   }

   generate_plan_from_description() {
     local title="$1"
     local body="$2"
     local project_dir="$3"

     # Use Claude to convert description to task list
     local prompt="Convert this GitHub issue into a fix_plan.md task list with checkbox items. Issue: $title\n\n$body"
     claude --print "$prompt" > "$project_dir/.ralph/fix_plan.md"
   }
   ```

2. Add `--issue` flag to CLI parser in `ralph_loop.sh`:
   ```bash
   --issue)
     GITHUB_ISSUE_NUMBER="$2"
     shift 2
     ;;
   ```

3. Import issue before loop starts (after config load, before first iteration)

4. Update PROMPT.md with issue context:
   ```
   You are working on GitHub Issue #N: [title]
   [issue body as context]
   ```

### Key Design Decisions

1. **`gh` CLI preferred:** Most GitHub users have `gh` installed. API token fallback covers CI environments.
2. **Existing task lists preserved:** If the issue already has checkboxes, use them directly. Only invoke Claude for unstructured descriptions.
3. **Issue metadata stored:** `.ralph/.github_issue.json` enables GHISSUE-5 lifecycle management without re-fetching.
4. **Scoped to single issue:** Batch processing is GHISSUE-4. This story handles one issue at a time.

## Testing

```bash
@test "ralph --issue imports issue with task list" {
  # Mock gh CLI
  mock_gh_issue 42 "Fix login bug" "- [ ] task 1\n- [ ] task 2"
  run ralph --issue 42 --project "$TEST_PROJECT" --dry-run
  [ -f "$TEST_PROJECT/.ralph/fix_plan.md" ]
  grep -q "task 1" "$TEST_PROJECT/.ralph/fix_plan.md"
  grep -q "task 2" "$TEST_PROJECT/.ralph/fix_plan.md"
}

@test "ralph --issue handles issue without task list" {
  mock_gh_issue 43 "Improve performance" "The app is slow on large datasets"
  run ralph --issue 43 --project "$TEST_PROJECT" --dry-run
  [ -f "$TEST_PROJECT/.ralph/fix_plan.md" ]
  # Should have generated tasks
  grep -q "\[ \]" "$TEST_PROJECT/.ralph/fix_plan.md"
}

@test "ralph --issue stores issue metadata" {
  mock_gh_issue 42 "Fix bug" "description"
  ralph --issue 42 --project "$TEST_PROJECT" --dry-run
  [ -f "$TEST_PROJECT/.ralph/.github_issue.json" ]
  [ -f "$TEST_PROJECT/.ralph/.github_issue_number" ]
}

@test "ralph --issue fails gracefully without gh" {
  export PATH="/usr/bin"
  export GITHUB_TOKEN=""
  run ralph --issue 42 --project "$TEST_PROJECT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"gh CLI or GITHUB_TOKEN required"* ]]
}
```

## Acceptance Criteria

- [ ] `ralph --issue 42` imports GitHub issue #42 into fix_plan.md
- [ ] Issues with existing checkbox tasks use them directly
- [ ] Issues without tasks get Claude-generated fix_plan.md
- [ ] Issue metadata stored in `.ralph/.github_issue.json`
- [ ] PROMPT.md updated with issue context
- [ ] Repo detected from git remote origin
- [ ] Works with `gh` CLI or `GITHUB_TOKEN` environment variable
- [ ] Fails gracefully when neither `gh` nor token is available
