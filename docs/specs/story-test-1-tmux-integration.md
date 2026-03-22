# Story TEST-1: Implement tmux Integration Tests

**Epic:** [RALPH-TEST](epic-validation-testing.md)
**Priority:** Medium
**Status:** Open
**Effort:** Medium
**Component:** `tests/integration/test_tmux.bats`

---

## Problem

Ralph's tmux dashboard (`ralph-monitor`) is untested. Layout rendering, pane management, and live updates could regress silently. tmux sessions are environment-dependent (terminal size, tmux version, WSL behavior).

## Solution

Create BATS integration tests that validate tmux dashboard behavior in a controlled environment. Tests use a headless tmux session to verify pane creation, layout, and content rendering.

## Implementation

1. Create `tests/integration/test_tmux.bats`
2. Test categories:
   - Session creation and cleanup
   - 3-pane layout rendering (main, logs, status)
   - Pane content updates on loop state changes
   - Graceful handling of missing tmux binary
   - Window resize behavior

```bash
@test "ralph-monitor creates tmux session" {
  tmux kill-session -t ralph-test 2>/dev/null || true
  ralph-monitor --session ralph-test --project "$TEST_PROJECT" &
  sleep 2
  tmux has-session -t ralph-test
  tmux kill-session -t ralph-test
}

@test "ralph-monitor creates 3 panes" {
  tmux kill-session -t ralph-test 2>/dev/null || true
  ralph-monitor --session ralph-test --project "$TEST_PROJECT" &
  sleep 2
  pane_count=$(tmux list-panes -t ralph-test | wc -l)
  [ "$pane_count" -eq 3 ]
  tmux kill-session -t ralph-test
}

@test "ralph-monitor exits gracefully without tmux" {
  export PATH="/usr/bin"  # Remove tmux from PATH
  run ralph-monitor --project "$TEST_PROJECT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"tmux is required"* ]]
}
```

## Acceptance Criteria

- [ ] tmux session creation and teardown tested
- [ ] 3-pane layout verified (main, logs, status)
- [ ] Pane content reflects current loop state
- [ ] Missing tmux binary handled gracefully
- [ ] Tests skip cleanly when tmux is unavailable in CI
- [ ] Tests clean up tmux sessions on failure
