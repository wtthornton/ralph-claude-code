# Story RALPH-MULTI-1: Strengthen PROMPT.md Stop Instruction

**Epic:** [Multi-Task Loop Violation and Cascading Failures](epic-multi-task-cascading-failures.md)
**Priority:** Critical
**Status:** Done
**Effort:** Trivial
**Component:** `templates/PROMPT.md`

---

## Problem

Claude completed 2 tasks in a single loop invocation, violating the "ONE task per
loop" contract in PROMPT.md. Two contributing factors:

1. **No explicit STOP instruction** after the RALPH_STATUS block. The template says
   "ONE task per loop" (line 15) but never says "stop after emitting the status block."

2. **"Ralph's Action" lines are misread as self-instructions.** Line 252 says:
   > Ralph's Action: Continues loop, circuit breaker stays CLOSED (normal operation)

   Claude interpreted "Continues loop" as an instruction to keep working, rather than
   a description of what the external harness does.

**Research finding (2026):** Claude Code has documented issues (#27743, #15443, #7777)
where Claude ignores explicit CLAUDE.md stop instructions. PROMPT.md text alone is not
a guaranteed stop mechanism. However, strengthening the language significantly reduces
violations and is the correct first step. A Stop hook (ralph-wiggum pattern) is the
reliable enforcement mechanism for future hardening.

## Solution

Two changes to `templates/PROMPT.md`:

### Change 1: Add explicit STOP instruction to the execution contract

After the "Output your RALPH_STATUS block" step, add a hard stop instruction:

```markdown
## Execution Contract (Per Loop)
...
9. Commit implementation + fix_plan update together.
10. Output your RALPH_STATUS block.
11. **STOP. End your response immediately after the status block.**
    Do NOT start another task. Do NOT say "moving to the next task."
    The Ralph harness will re-invoke you for the next item.
    Your response MUST end within 2 lines of the closing `---END_RALPH_STATUS---`.
```

### Change 2: Reword "Ralph's Action" lines in exit scenarios

Replace all "Ralph's Action:" lines with "Harness behavior:" and add explicit
"Your action: STOP" lines. Example for Scenario 5:

**Before:**
```markdown
### Scenario 5: Making Progress
**Given**: Current task is done, unchecked items remain in fix_plan.md
**Then**: Set `STATUS: IN_PROGRESS`, `EXIT_SIGNAL: false`, `TASKS_COMPLETED_THIS_LOOP: 1`
**Ralph's Action**: Continues loop, circuit breaker stays CLOSED (normal operation)
```

**After:**
```markdown
### Scenario 5: Making Progress (MOST COMMON)
**Given**: Current task is done, unchecked items remain in fix_plan.md
**Then**: Set `STATUS: IN_PROGRESS`, `EXIT_SIGNAL: false`, `TASKS_COMPLETED_THIS_LOOP: 1`
**Your action**: STOP immediately. Do not continue to the next task.
*(The harness will re-invoke you for the next item automatically.)*
```

Apply the same pattern to all 6 scenarios (lines 139-277).

### Change 3: Fix Scenario 5 example showing TASKS_COMPLETED: 3

The template's Scenario 5 example shows `TASKS_COMPLETED_THIS_LOOP: 3`, which
contradicts the "ONE task per loop" rule. Change to `1`.

## Design Notes

- **Why not just use a Stop hook?** A Stop hook (ralph-wiggum pattern) is the
  reliable enforcement mechanism but requires code changes to `ralph_loop.sh`. This
  PROMPT.md change is a zero-code fix that reduces violations immediately. A Stop
  hook story can be added as a future hardening measure.
- **"MUST end within 2 lines"** gives Claude minimal room for a brief closing remark
  without allowing it to start a new task.
- **Italic harness description** visually distinguishes it from instructions to Claude,
  reducing misinterpretation.

## Acceptance Criteria

- [ ] PROMPT.md template includes explicit STOP instruction after status block
- [ ] All "Ralph's Action:" lines replaced with "Your action: STOP" + italic harness note
- [ ] Scenario 5 example shows `TASKS_COMPLETED_THIS_LOOP: 1`
- [ ] No scenario implies Claude should continue to another task
- [ ] Changes propagated to any existing PROMPT.md files (via ralph-migrate or docs)

## Test Plan

```bash
@test "PROMPT.md template contains explicit stop instruction" {
    run grep -c "STOP.*End your response immediately" templates/PROMPT.md
    assert_output "1"
}

@test "PROMPT.md template has no Ralph's Action lines" {
    run grep -c "Ralph's Action" templates/PROMPT.md
    assert_output "0"
}

@test "PROMPT.md Scenario 5 shows TASKS_COMPLETED 1" {
    run grep -A5 "Scenario 5" templates/PROMPT.md
    assert_output --partial "TASKS_COMPLETED_THIS_LOOP: 1"
}
```

## References

- Claude ignores stop instructions: Issues [#27743](https://github.com/anthropics/claude-code/issues/27743), [#15443](https://github.com/anthropics/claude-code/issues/15443), [#7777](https://github.com/anthropics/claude-code/issues/7777)
- Ralph-wiggum plugin (Stop hook pattern): [github.com/anthropics/claude-code/tree/main/plugins/ralph-wiggum](https://github.com/anthropics/claude-code/tree/main/plugins/ralph-wiggum)
- Claude Code hooks reference: [code.claude.com/docs/en/hooks](https://code.claude.com/docs/en/hooks)
