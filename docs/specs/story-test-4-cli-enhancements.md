# Story TEST-4: Implement CLI Enhancement Tests

**Epic:** [RALPH-TEST](epic-validation-testing.md)
**Priority:** Medium
**Status:** Open
**Effort:** Medium
**Component:** `tests/unit/test_cli_enhancements.bats`

---

## Problem

CLI flags added in v1.0+ (`--live`, `--dry-run`, `--output-format`, `--reset-circuit`, `--reset-session`, `--calls`, `--timeout`, `--sdk`) are not fully tested. As more flags are added (sandbox, stats, rollback), the CLI surface needs comprehensive validation.

## Solution

Create tests for all modern CLI flags, including flag parsing, mutual exclusivity, default values, and integration with the features they control.

## Implementation

```bash
@test "--dry-run prevents API calls" {
  run ralph --dry-run --project "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [ ! -f ".ralph/.call_count" ] || [ "$(cat .ralph/.call_count)" -eq 0 ]
}

@test "--calls sets max calls per hour" {
  run ralph --calls 50 --dry-run --project "$TEST_PROJECT"
  [[ "$output" == *"50 calls/hour"* ]]
}

@test "--timeout validates range 1-120" {
  run ralph --timeout 0 --project "$TEST_PROJECT"
  [ "$status" -ne 0 ]
  run ralph --timeout 121 --project "$TEST_PROJECT"
  [ "$status" -ne 0 ]
  run ralph --timeout 60 --dry-run --project "$TEST_PROJECT"
  [ "$status" -eq 0 ]
}

@test "--output-format json produces valid JSON" {
  run ralph --output-format json --dry-run --project "$TEST_PROJECT"
  echo "$output" | jq -e '.'
}

@test "--reset-circuit clears circuit breaker state" {
  echo '{"state":"OPEN"}' > "$TEST_PROJECT/.ralph/.circuit_breaker_state"
  run ralph --reset-circuit --project "$TEST_PROJECT"
  state=$(jq -r '.state' "$TEST_PROJECT/.ralph/.circuit_breaker_state")
  [ "$state" = "CLOSED" ]
}

@test "--reset-session clears session ID" {
  echo "old-session-id" > "$TEST_PROJECT/.ralph/.claude_session_id"
  run ralph --reset-session --project "$TEST_PROJECT"
  [ ! -f "$TEST_PROJECT/.ralph/.claude_session_id" ]
}

@test "--live enables streaming output" {
  run ralph --live --dry-run --project "$TEST_PROJECT"
  [ "$status" -eq 0 ]
}

@test "--sdk flag dispatches to SDK runner" {
  run ralph --sdk --dry-run --project "$TEST_PROJECT"
  # Should attempt SDK execution (may fail if SDK not installed)
  [[ "$output" == *"SDK"* ]] || [[ "$output" == *"sdk"* ]]
}
```

## Acceptance Criteria

- [ ] All modern CLI flags tested (--dry-run, --calls, --timeout, --output-format, --live, --reset-circuit, --reset-session, --sdk)
- [ ] Flag validation tested (invalid values, out-of-range)
- [ ] Default values verified for each flag
- [ ] Mutually exclusive flags detected (if any)
- [ ] Help text includes all flags
- [ ] Exit codes documented and tested
