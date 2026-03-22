# Story TEST-2: Implement Monitor Dashboard Tests

**Epic:** [RALPH-TEST](epic-validation-testing.md)
**Priority:** Medium
**Status:** Open
**Effort:** Medium
**Component:** `tests/integration/test_monitor.bats`

---

## Problem

The monitor dashboard displays loop count, API usage, recent logs, and circuit breaker state. These displays read from `.ralph/status.json` and log files, but accuracy of the rendering is not validated.

## Solution

Create tests that verify the monitor dashboard correctly reads and displays state from Ralph's data files. Tests mock the data files and verify rendered output.

## Implementation

```bash
@test "monitor displays current loop count" {
  echo '{"loop_count": 5}' > "$TEST_PROJECT/.ralph/status.json"
  run render_monitor_status "$TEST_PROJECT"
  [[ "$output" == *"Loop: 5"* ]]
}

@test "monitor displays API call count" {
  echo "42" > "$TEST_PROJECT/.ralph/.call_count"
  echo '{"max_calls_per_hour": 100}' > "$TEST_PROJECT/.ralph/status.json"
  run render_monitor_status "$TEST_PROJECT"
  [[ "$output" == *"42/100"* ]]
}

@test "monitor displays circuit breaker state" {
  echo '{"state": "HALF_OPEN"}' > "$TEST_PROJECT/.ralph/.circuit_breaker_state"
  run render_monitor_status "$TEST_PROJECT"
  [[ "$output" == *"HALF_OPEN"* ]]
}

@test "monitor handles missing status.json" {
  rm -f "$TEST_PROJECT/.ralph/status.json"
  run render_monitor_status "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No status"* ]]
}

@test "monitor shows recent log entries" {
  echo "2026-03-21 10:00 Starting loop 3" > "$TEST_PROJECT/.ralph/logs/ralph.log"
  run render_monitor_logs "$TEST_PROJECT"
  [[ "$output" == *"Starting loop 3"* ]]
}
```

## Acceptance Criteria

- [ ] Loop count display accuracy verified
- [ ] API call count and limit display verified
- [ ] Circuit breaker state display verified
- [ ] Graceful handling of missing/empty data files
- [ ] Recent log entries rendered correctly
- [ ] Refresh interval behavior tested
