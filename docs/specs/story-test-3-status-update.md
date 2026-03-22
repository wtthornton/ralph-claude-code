# Story TEST-3: Implement Status Update Tests

**Epic:** [RALPH-TEST](epic-validation-testing.md)
**Priority:** Medium
**Status:** Open
**Effort:** Small
**Component:** `tests/unit/test_status_updates.bats`

---

## Problem

`status.json` is the primary data contract between Ralph's hook system and its monitoring/metrics infrastructure. Schema violations or stale data could cascade to incorrect dashboard displays, broken metrics, and false circuit breaker triggers.

## Solution

Create unit tests that validate status.json writes against a defined schema, test staleness detection, and verify atomic write behavior on WSL/NTFS.

## Implementation

```bash
@test "status.json contains all required fields" {
  source .ralph/hooks/on-stop.sh
  # Trigger status write with mock data
  write_status '{"WORK_TYPE":"IMPLEMENTATION","COMPLETED_TASK":"task 1","NEXT_TASK":"task 2","PROGRESS_SUMMARY":"progress","EXIT_SIGNAL":"false"}'
  # Validate required fields
  jq -e '.WORK_TYPE' .ralph/status.json
  jq -e '.COMPLETED_TASK' .ralph/status.json
  jq -e '.NEXT_TASK' .ralph/status.json
  jq -e '.PROGRESS_SUMMARY' .ralph/status.json
  jq -e '.EXIT_SIGNAL' .ralph/status.json
  jq -e '.timestamp' .ralph/status.json
}

@test "status.json is valid JSON" {
  write_status '{"WORK_TYPE":"IMPLEMENTATION","EXIT_SIGNAL":"false"}'
  run jq '.' .ralph/status.json
  [ "$status" -eq 0 ]
}

@test "stale status detection triggers warning" {
  # Write status with old timestamp
  echo '{"timestamp":"2026-03-20T00:00:00Z"}' > .ralph/status.json
  run check_status_staleness .ralph/status.json 300
  [[ "$output" == *"stale"* ]]
}

@test "atomic write prevents partial status.json" {
  # Verify temp file + mv pattern
  write_status '{"WORK_TYPE":"TEST"}'
  # No .tmp files should remain
  [ ! -f ".ralph/status.json.tmp" ]
}

@test "status.json handles special characters in task names" {
  write_status '{"COMPLETED_TASK":"Fix \"quoted\" task & <html>","EXIT_SIGNAL":"false"}'
  jq -e '.COMPLETED_TASK' .ralph/status.json
}
```

## Acceptance Criteria

- [ ] All required fields validated (WORK_TYPE, COMPLETED_TASK, NEXT_TASK, PROGRESS_SUMMARY, EXIT_SIGNAL, timestamp)
- [ ] Output is always valid JSON
- [ ] Staleness detection works with configurable threshold
- [ ] Atomic write pattern verified (no partial writes)
- [ ] Special characters in task names handled correctly
- [ ] Schema matches what monitor dashboard and metrics expect
