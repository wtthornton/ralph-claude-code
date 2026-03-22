# Story TEST-7: Implement E2E Full Loop Tests

**Epic:** [RALPH-TEST](epic-validation-testing.md)
**Priority:** Medium
**Status:** Open
**Effort:** Large
**Component:** `tests/e2e/test_full_loop.bats`

---

## Problem

Ralph's unit and integration tests validate individual components, but no test verifies the complete loop: read fix_plan.md → invoke Claude → parse response → update status → check exit → repeat until done. Without E2E tests, the full workflow can regress even when individual components pass.

## Solution

Create E2E tests using mock Claude responses (recorded fixtures) that exercise the complete loop lifecycle. Tests validate that Ralph can start, process tasks, detect completion, and exit cleanly.

## Implementation

### Test Infrastructure
1. Create `tests/e2e/` directory
2. Create `tests/e2e/fixtures/` with recorded Claude response sequences
3. Create `tests/e2e/mock_claude.sh` — Mock Claude Code CLI that replays fixture responses

### Mock Claude
```bash
#!/usr/bin/env bash
# mock_claude.sh — Replays fixture responses in sequence
FIXTURE_DIR="${MOCK_FIXTURE_DIR:-tests/e2e/fixtures/simple-task}"
RESPONSE_INDEX="${MOCK_RESPONSE_FILE:-.ralph/.mock_response_index}"

index=$(cat "$RESPONSE_INDEX" 2>/dev/null || echo 0)
response_file="$FIXTURE_DIR/response-$index.json"

if [ -f "$response_file" ]; then
  cat "$response_file"
  echo $((index + 1)) > "$RESPONSE_INDEX"
else
  # Final response with EXIT_SIGNAL
  cat "$FIXTURE_DIR/response-final.json"
fi
```

### E2E Tests
```bash
@test "E2E: simple 2-task project completes" {
  setup_e2e_project "simple-task"
  export CLAUDE_CMD="$PWD/tests/e2e/mock_claude.sh"
  run ralph --project "$E2E_PROJECT" --calls 10
  [ "$status" -eq 0 ]
  # All tasks should be checked
  grep -c "\[x\]" "$E2E_PROJECT/.ralph/fix_plan.md"
}

@test "E2E: circuit breaker trips on no-progress loop" {
  setup_e2e_project "no-progress"
  export CLAUDE_CMD="$PWD/tests/e2e/mock_claude.sh"
  run ralph --project "$E2E_PROJECT" --calls 10
  cb_state=$(jq -r '.state' "$E2E_PROJECT/.ralph/.circuit_breaker_state")
  [ "$cb_state" = "OPEN" ]
}

@test "E2E: rate limit detection pauses loop" {
  setup_e2e_project "rate-limited"
  export CLAUDE_CMD="$PWD/tests/e2e/mock_claude.sh"
  run ralph --project "$E2E_PROJECT" --calls 3
  [[ "$output" == *"rate limit"* ]] || [[ "$output" == *"Rate limit"* ]]
}

@test "E2E: session continuity across restarts" {
  setup_e2e_project "multi-session"
  export CLAUDE_CMD="$PWD/tests/e2e/mock_claude.sh"
  # First run
  ralph --project "$E2E_PROJECT" --calls 2
  session1=$(cat "$E2E_PROJECT/.ralph/.claude_session_id")
  # Second run (should reuse session)
  ralph --project "$E2E_PROJECT" --calls 2
  session2=$(cat "$E2E_PROJECT/.ralph/.claude_session_id")
  [ "$session1" = "$session2" ]
}

@test "E2E: loop exits on EXIT_SIGNAL" {
  setup_e2e_project "clean-exit"
  export CLAUDE_CMD="$PWD/tests/e2e/mock_claude.sh"
  run ralph --project "$E2E_PROJECT" --calls 10
  [ "$status" -eq 0 ]
  exit_signal=$(jq -r '.EXIT_SIGNAL' "$E2E_PROJECT/.ralph/status.json")
  [ "$exit_signal" = "true" ]
}
```

### Fixture Projects
- `simple-task/` — 2 tasks, completes in 3 responses
- `no-progress/` — Repeated responses with no task completion (triggers CB)
- `rate-limited/` — Response includes rate_limit_event
- `multi-session/` — 2 tasks across 2 sessions
- `clean-exit/` — Single task with clean EXIT_SIGNAL

## Acceptance Criteria

- [ ] Mock Claude CLI replays fixture responses deterministically
- [ ] Simple task completion E2E passes (start → work → exit)
- [ ] Circuit breaker trip E2E passes (no-progress detection)
- [ ] Rate limit detection E2E passes
- [ ] Session continuity E2E passes (ID reuse across restarts)
- [ ] EXIT_SIGNAL detection E2E passes
- [ ] All fixture projects are self-contained and reproducible
- [ ] E2E tests run in CI without real API calls
