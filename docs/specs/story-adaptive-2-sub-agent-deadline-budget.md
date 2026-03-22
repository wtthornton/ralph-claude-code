# Story ADAPTIVE-2: Sub-Agent Deadline Budget

**Epic:** [Adaptive Timeout Strategy](epic-adaptive-timeout.md)
**Priority:** High
**Status:** Pending
**Effort:** Medium
**Component:** `.claude/agents/ralph-tester.md`, `.claude/agents/ralph.md`, `ralph_loop.sh`

---

## Problem

When Ralph spawns QA sub-agents (ralph-tester, ralph-reviewer), they have no awareness of the remaining time budget. They start heavy operations (full pytest runs taking 20+ minutes, repeated ruff checks, mypy with 90-second timeouts) without knowing that the main loop will kill them in 5 minutes.

This causes:
1. **Exit 143 cascade**: Main loop SIGTERM kills all sub-agents and their child processes
2. **Wasted computation**: Sub-agents start operations they can't finish
3. **No results**: Killed sub-agents produce no usable QA output
4. **Retry spiral**: QA agent tries progressively smaller test subsets, each getting killed

### Evidence (from TheStudio, 2026-03-22)

- Agent #2 (pytest): Full test suite → killed (143), unit tests only → killed (143), then tried progressively smaller slices
- Agent #3 (ruff): Ran `ruff check` 10+ times with different args, all within the same timeout window
- Agent #4 (mypy): Started `timeout 90 mypy src/` at 28m50s — guaranteed to be killed at 30m00s
- Individual tool calls ran 27-29 minutes into the 30-minute budget before being killed

## Solution

Pass a **deadline timestamp** to sub-agents so they can:
1. Know how much time remains
2. Skip heavy operations when time is insufficient
3. Use shorter tool timeouts as deadline approaches
4. Return partial results rather than getting killed

This follows the **gRPC deadline propagation** pattern: the parent sets an absolute deadline, each child computes remaining time and adapts.

## Implementation

### Step 1: Pass deadline to sub-agents via environment or prompt

```bash
# In ralph_loop.sh, when spawning QA sub-agents:
LOOP_START_EPOCH=$(date +%s)
LOOP_TIMEOUT_SECONDS=$((CLAUDE_TIMEOUT_MINUTES * 60))
LOOP_DEADLINE=$((LOOP_START_EPOCH + LOOP_TIMEOUT_SECONDS))

# Pass deadline in the sub-agent spawn prompt:
TESTER_PROMPT="Run QA. DEADLINE_EPOCH=$LOOP_DEADLINE ($(date -d @$LOOP_DEADLINE +%H:%M:%S)). You have approximately $((LOOP_DEADLINE - $(date +%s)))s remaining. Do NOT start operations that will exceed this deadline."
```

### Step 2: Update ralph-tester agent prompt with deadline awareness

Add to ralph-tester.md:

```markdown
## Deadline Awareness

You may receive a DEADLINE_EPOCH in your prompt. If present:

1. **Check remaining time** before each major operation:
   - If < 5 minutes remain: Skip full test suites. Run only `pytest --collect-only` to verify imports.
   - If < 10 minutes remain: Run unit tests only with `--timeout=30` per test.
   - If < 15 minutes remain: Run unit tests with standard timeout.
   - If >= 15 minutes remain: Run full test suite including integration.

2. **Use proportional tool timeouts**:
   ```bash
   # Remaining seconds / 2 = max tool timeout (leave margin for reporting)
   REMAINING=$((DEADLINE_EPOCH - $(date +%s)))
   TOOL_TIMEOUT=$((REMAINING / 2))
   timeout $TOOL_TIMEOUT pytest ...
   ```

3. **Never start** a full pytest or mypy run with < 5 minutes remaining.

4. **Report partial results** if you run out of time:
   ```
   ## Test Results (PARTIAL — deadline approaching)
   - Completed: ruff check, unit tests (src/workflow/)
   - Skipped: integration tests, mypy (insufficient time)
   - Recommendation: Increase CLAUDE_TIMEOUT_MINUTES or run tests separately
   ```
```

### Step 3: Update ralph.md main agent prompt

Add deadline propagation instructions:

```markdown
## Sub-Agent Time Budgets

When spawning sub-agents for QA at epic boundaries:

1. **Calculate remaining time**: Check how long the current invocation has been running
2. **Allocate time budgets**:
   - ralph-tester: 60% of remaining time
   - ralph-reviewer: 30% of remaining time
   - Leave 10% margin for your own reporting
3. **Pass deadline** in the agent prompt: "DEADLINE_EPOCH=<epoch>. You have ~Ns remaining."
4. **If < 10 minutes remain**: Skip full QA. Set `TESTS_STATUS: DEFERRED` with reason "insufficient time budget"
```

### Step 4: Add time-awareness to tool timeouts

```markdown
## Tool Timeout Guidelines

When running Bash commands for testing/linting, set explicit timeouts proportional to remaining time:

```bash
# Get remaining time
REMAINING=$((DEADLINE_EPOCH - $(date +%s)))

# Set tool timeout to half of remaining (leave room for processing results)
if [[ $REMAINING -gt 600 ]]; then
    timeout $((REMAINING / 2)) pytest ...
elif [[ $REMAINING -gt 120 ]]; then
    timeout $((REMAINING / 2)) pytest tests/unit/ --timeout=10 -x ...
else
    echo "SKIP: Not enough time for test execution"
fi
```
```

## Design Notes

- **gRPC deadline propagation**: This directly adapts the gRPC pattern where absolute deadlines are passed between services. Each hop computes `remaining = deadline - now` and sets its own timeout accordingly.
- **Environment vs prompt**: Passing deadline via the prompt text is more reliable than environment variables because sub-agents are spawned by Claude, not by bash directly. The agent reads the deadline from its instructions.
- **Proportional timeouts**: Using `remaining / 2` for tool timeouts ensures there's always time left to process results and report back. A 60-second test run started 30 seconds before deadline would get killed — using `remaining / 2` prevents this.
- **Partial results over no results**: A report saying "unit tests passed, integration tests skipped due to deadline" is infinitely more useful than exit code 143 with no output.
- **Deferred QA as fallback**: When time is genuinely insufficient (< 10 minutes), the right answer is `TESTS_STATUS: DEFERRED` rather than starting and getting killed. The next loop iteration will have a full time budget.
- **10+ ruff runs in Agent #3**: The deadline awareness also prevents the retry spiral — if ruff fails once and there's < 5 minutes left, don't retry with different args.

## Acceptance Criteria

- [ ] Main loop passes `DEADLINE_EPOCH` to sub-agents when spawning QA
- [ ] ralph-tester agent checks remaining time before major operations
- [ ] Tool timeouts are proportional to remaining time (not hardcoded)
- [ ] Sub-agents return partial results instead of getting killed (143)
- [ ] QA is deferred when < 10 minutes remain (not attempted and killed)
- [ ] ralph.md includes sub-agent time budget allocation instructions
- [ ] Exit 143 count in QA phases drops to near zero

## Test Plan

```bash
@test "deadline budget calculation is correct" {
    source "$RALPH_DIR/ralph_loop.sh"
    LOOP_START_EPOCH=$(date +%s)
    CLAUDE_TIMEOUT_MINUTES=30
    LOOP_TIMEOUT_SECONDS=$((CLAUDE_TIMEOUT_MINUTES * 60))
    LOOP_DEADLINE=$((LOOP_START_EPOCH + LOOP_TIMEOUT_SECONDS))

    local remaining=$((LOOP_DEADLINE - $(date +%s)))
    assert [ "$remaining" -le 1800 ]
    assert [ "$remaining" -ge 1790 ]  # Allow 10s for test execution
}

@test "tool timeout is proportional to remaining time" {
    local deadline=$(($(date +%s) + 600))  # 10 minutes from now
    local remaining=$((deadline - $(date +%s)))
    local tool_timeout=$((remaining / 2))

    assert [ "$tool_timeout" -ge 290 ]
    assert [ "$tool_timeout" -le 300 ]
}

@test "QA deferred when less than 10 minutes remain" {
    local deadline=$(($(date +%s) + 300))  # 5 minutes from now
    local remaining=$((deadline - $(date +%s)))

    # Should defer QA
    assert [ "$remaining" -lt 600 ]
}
```

## References

- [gRPC — Deadlines](https://grpc.io/docs/guides/deadlines/)
- [gRPC Blog — Deadlines](https://grpc.io/blog/deadlines/)
- [userver — Deadline Propagation](https://userver.tech/d6/d64/md_en_2userver_2deadline__propagation.html)
- [AWS Step Functions — TimeoutSecondsPath](https://docs.aws.amazon.com/step-functions/latest/dg/sfn-stuck-execution.html)
- [Kubernetes — progressDeadlineSeconds](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#progress-deadline-seconds)
- [AWS Builders Library — Timeouts and retries](https://aws.amazon.com/builders-library/timeouts-retries-and-backoff-with-jitter/)
