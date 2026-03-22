# Story GHISSUE-4: Batch Processing and Issue Queue

**Epic:** [RALPH-GHISSUE](epic-github-issue-integration.md)
**Priority:** Medium
**Status:** Open
**Effort:** Medium
**Component:** `ralph_loop.sh`, `lib/github_issues.sh`

---

## Problem

Standalone Ralph processes one issue at a time. Users with multiple issues to resolve (e.g., "fix all bugs labeled `priority:high`") must manually run `ralph --issue N` for each one. A batch mode enables processing a queue of issues sequentially.

## Solution

Add `ralph --batch` to process multiple issues in sequence. Each issue goes through the full Ralph loop independently. Queue is built from `--label`, `--milestone`, or explicit issue numbers.

## Implementation

1. Add `process_issue_batch()` to `lib/github_issues.sh`:
   ```bash
   process_issue_batch() {
     local issues=("$@")
     local total=${#issues[@]}
     local completed=0
     local failed=0

     for issue_number in "${issues[@]}"; do
       echo "[RALPH BATCH] Processing issue #$issue_number ($((completed + 1))/$total)"

       # Import and run
       import_github_issue "$issue_number" "$PROJECT_DIR"
       ralph_loop

       # Check result
       if [ $? -eq 0 ]; then
         ((completed++))
         echo "[RALPH BATCH] Issue #$issue_number completed"
       else
         ((failed++))
         echo "[RALPH BATCH] Issue #$issue_number failed"

         # Stop on failure or continue based on config
         if [ "$RALPH_BATCH_STOP_ON_FAILURE" = "true" ]; then
           echo "[RALPH BATCH] Stopping — $completed completed, $failed failed, $((total - completed - failed)) remaining"
           return 1
         fi
       fi

       # Reset state for next issue
       reset_session
     done

     echo "[RALPH BATCH] Complete — $completed/$total succeeded, $failed failed"
   }
   ```

2. Add CLI flags:
   ```bash
   --batch)          BATCH_MODE=true; shift ;;
   --batch-issues)   BATCH_ISSUES="$2"; shift 2 ;;  # Comma-separated: "42,43,44"
   --stop-on-failure) RALPH_BATCH_STOP_ON_FAILURE=true; shift ;;
   ```

3. Usage examples:
   ```bash
   ralph --batch --label bug                          # All open bugs
   ralph --batch --batch-issues 42,43,44              # Specific issues
   ralph --batch --label "priority:high" --milestone v2.0  # Filtered batch
   ralph --batch --label bug --stop-on-failure        # Stop on first failure
   ```

4. Batch results written to `.ralph/batch_results.json`:
   ```json
   {
     "started": "2026-03-21T10:00:00Z",
     "completed": "2026-03-21T14:30:00Z",
     "issues": [
       {"number": 42, "status": "completed", "loops": 5},
       {"number": 43, "status": "failed", "loops": 3, "error": "circuit_breaker_trip"},
       {"number": 44, "status": "completed", "loops": 2}
     ]
   }
   ```

### Key Design Decisions

1. **Sequential, not parallel:** Batch processes issues one at a time. Parallel execution is TheStudio's domain (multiple execution planes).
2. **Independent sessions:** Each issue gets a fresh session and clean circuit breaker state. One bad issue doesn't poison the next.
3. **Stop-on-failure opt-in:** Default is to continue processing. `--stop-on-failure` for users who want early exit.
4. **Results file:** Machine-readable batch results enable CI integration and TheStudio compatibility.

## Testing

```bash
@test "ralph --batch processes multiple issues" {
  mock_gh_issue_list_with_ids 42 43
  run ralph --batch --batch-issues 42,43 --project "$TEST_PROJECT" --dry-run
  [ "$status" -eq 0 ]
  [ -f "$TEST_PROJECT/.ralph/batch_results.json" ]
}

@test "ralph --batch --stop-on-failure stops on first failure" {
  mock_gh_issue_fail 43
  run ralph --batch --batch-issues 42,43,44 --stop-on-failure --project "$TEST_PROJECT"
  completed=$(jq '[.issues[] | select(.status == "completed")] | length' "$TEST_PROJECT/.ralph/batch_results.json")
  [ "$completed" -lt 3 ]
}

@test "batch resets session between issues" {
  run ralph --batch --batch-issues 42,43 --project "$TEST_PROJECT" --dry-run
  # Session file should exist but have been reset
  [ "$status" -eq 0 ]
}
```

## Acceptance Criteria

- [ ] `ralph --batch --label bug` processes all matching issues sequentially
- [ ] `ralph --batch --batch-issues 42,43,44` processes specific issues
- [ ] Each issue gets independent session and circuit breaker state
- [ ] `--stop-on-failure` stops batch on first failed issue
- [ ] Batch results written to `.ralph/batch_results.json`
- [ ] Progress output shows `(N/total)` for each issue
- [ ] Notifications fire for batch completion (if OBSERVE-2 is implemented)
