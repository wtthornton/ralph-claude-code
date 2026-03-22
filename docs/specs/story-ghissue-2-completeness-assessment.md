# Story GHISSUE-2: Issue Completeness Assessment

**Epic:** [RALPH-GHISSUE](epic-github-issue-integration.md)
**Priority:** Medium
**Status:** Open
**Effort:** Medium
**Component:** `lib/github_issues.sh`

---

## Problem

Many GitHub issues are vaguely written — "fix the login page" or "improve performance." When GHISSUE-1 encounters these, it uses Claude to generate a task list, but it does so blindly without assessing whether the issue has enough information to be actionable.

## Solution

Before generating a fix_plan.md, assess the issue's completeness and either:
1. Generate a high-quality plan if sufficient information exists
2. Flag missing information and generate a partial plan with assumptions noted
3. Optionally comment on the issue requesting clarification (with user confirmation)

## Implementation

1. Add `assess_issue_completeness()` to `lib/github_issues.sh`:
   ```bash
   assess_issue_completeness() {
     local title="$1"
     local body="$2"

     local assessment=$(claude --print "Assess this GitHub issue for completeness. Rate 1-5:
     - Does it describe the problem clearly? (1-5)
     - Are reproduction steps provided? (1-5)
     - Is the expected behavior stated? (1-5)
     - Is the scope bounded? (1-5)

     Issue: $title
     $body

     Output JSON: {score: N, missing: [...], assumptions: [...]}")

     echo "$assessment"
   }
   ```

2. Integrate into GHISSUE-1's import flow:
   - Score >= 3: Generate plan directly
   - Score 2: Generate plan with assumptions section at top
   - Score 1: Warn user, offer to request clarification on the issue

3. Add `--assess-only` flag:
   ```bash
   ralph --issue 42 --assess-only  # Just assess, don't import
   ```

4. Optional: comment on issue with questions (requires user confirmation):
   ```bash
   if [ "$COMPLETENESS_SCORE" -le 2 ] && confirm "Comment on issue requesting clarification?"; then
     gh issue comment "$issue_number" --body "$clarification_questions"
   fi
   ```

### Key Design Decisions

1. **Assessment is advisory, not blocking:** A low score warns but doesn't prevent import. Users know their issues better than heuristics.
2. **Assumptions are explicit:** When Ralph generates a plan from an incomplete issue, assumptions are listed at the top of fix_plan.md so Claude knows what was inferred.
3. **No auto-commenting:** Ralph never writes to GitHub without user confirmation. This respects the "TheStudio owns GitHub writes" principle even in standalone mode.

## Testing

```bash
@test "complete issue gets high score" {
  local assessment=$(assess_issue_completeness "Login fails with 500" "Steps: 1. Go to /login 2. Enter valid credentials 3. Click submit. Expected: redirect to dashboard. Actual: 500 error.")
  score=$(echo "$assessment" | jq -r '.score')
  [ "$score" -ge 3 ]
}

@test "vague issue gets low score" {
  local assessment=$(assess_issue_completeness "Fix login" "The login is broken")
  score=$(echo "$assessment" | jq -r '.score')
  [ "$score" -le 2 ]
}

@test "low-score issue includes assumptions in fix_plan" {
  mock_gh_issue 44 "Fix login" "Login is broken"
  ralph --issue 44 --project "$TEST_PROJECT" --dry-run
  grep -qi "assumption" "$TEST_PROJECT/.ralph/fix_plan.md"
}

@test "--assess-only shows assessment without importing" {
  run ralph --issue 42 --assess-only --project "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [ ! -f "$TEST_PROJECT/.ralph/fix_plan.md" ]
  [[ "$output" == *"score"* ]]
}
```

## Acceptance Criteria

- [ ] Issues assessed on 4 dimensions (problem clarity, repro steps, expected behavior, scope)
- [ ] Score >= 3: plan generated directly
- [ ] Score <= 2: plan generated with assumptions section
- [ ] `--assess-only` flag shows assessment without importing
- [ ] Optional issue commenting requires user confirmation
- [ ] Assessment results stored in `.ralph/.github_issue_assessment.json`
