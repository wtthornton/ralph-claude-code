# Story EVALS-2: Deterministic Agent Eval Suite

**Epic:** [Agent Evaluation Framework](epic-agent-evals.md)
**Priority:** Medium
**Status:** Open
**Effort:** Medium
**Component:** new `tests/evals/deterministic/`

---

## Problem

Agent behavior changes can break exit detection, task completion, and safety mechanisms. These aspects are deterministically verifiable but currently untested at the agent level.

## Solution

Create a deterministic eval suite that verifies:
1. Exit gate conditions (completion indicators + exit signal)
2. Circuit breaker trigger conditions
3. Tool restriction enforcement
4. Hook execution order
5. Task completion marking

## Implementation

### Eval categories

```bash
# tests/evals/deterministic/test_exit_gate.bats
@test "exit requires both completion_indicators>=2 AND exit_signal=true" {
    # Setup: status.json with completion_indicators=1, exit_signal=true
    # Expected: loop continues (not both conditions met)
}

@test "exit does not trigger on 'done' in mid-phase context" {
    # Setup: Claude says "done with this file" but more tasks remain
    # Expected: exit_signal remains false
}

# tests/evals/deterministic/test_circuit_breaker.bats
@test "CB trips after threshold failures in sliding window" {
    # Setup: inject N failure events within decay window
    # Expected: CB state transitions to OPEN
}

# tests/evals/deterministic/test_tool_restrictions.bats
@test "destructive git commands blocked by PreToolUse hook" {
    # Setup: simulate git reset --hard via hook
    # Expected: hook returns non-zero, command blocked
}
```

### CI integration

```yaml
# In CI pipeline:
eval-deterministic:
    runs-on: ubuntu-latest
    steps:
        - uses: actions/checkout@v4
        - run: npm install
        - run: npm run test:evals:deterministic
    timeout-minutes: 5
```

## Acceptance Criteria

- [ ] Deterministic eval suite covers: exit gate, circuit breaker, tool restrictions, hooks
- [ ] All evals are BATS-based (consistent with existing test framework)
- [ ] Suite runs in <5 minutes (suitable for pre-merge CI)
- [ ] No LLM calls required (fully deterministic)
- [ ] `npm run test:evals:deterministic` runs the suite

## References

- [Anthropic — Demystifying Evals](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents)
- [Google Cloud — Methodical Agent Evaluation](https://cloud.google.com/blog/topics/developers-practitioners/a-methodical-approach-to-agent-evaluation)
