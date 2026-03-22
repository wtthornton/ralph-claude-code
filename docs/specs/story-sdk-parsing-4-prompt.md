# Story RALPH-SDK-PARSING-4: Update Agent Prompt to Request JSON Status Output

**Epic:** [Structured Response Parsing](epic-sdk-structured-parsing.md)
**Priority:** Medium
**Status:** Pending
**Effort:** Trivial
**Component:** `sdk/ralph_sdk/agent.py` (`_build_iteration_prompt`)

---

## Problem

The current prompt built by `_build_iteration_prompt()` (agent.py:363-372) does not
instruct Claude to output its status in any structured format. Claude outputs the
`WORK_TYPE: ...` / `EXIT_SIGNAL: ...` status fields as plain text because the project's
`PROMPT.md` template tells it to — but the SDK has no control over what's in `PROMPT.md`.

When the SDK controls the prompt (standalone mode), it should explicitly request JSON
status output in a fenced code block matching the `RalphStatusBlock` schema. This makes
Strategy 1 (JSON code block) of `parse_ralph_status()` the primary path, which is more
reliable than regex extraction.

The text fallback still works for backward compatibility when the bash loop's `PROMPT.md`
is used, so this change is purely additive.

## Solution

Append a status output instruction block to the prompt built by `_build_iteration_prompt()`.
The instruction tells Claude to output its status as a JSON fenced code block with the
exact fields from `RalphStatusBlock`.

## Implementation

### Change 1: `sdk/ralph_sdk/agent.py` — Add status output instruction to prompt

```python
# BEFORE (agent.py:363-372):
def _build_iteration_prompt(self, task_input: TaskInput) -> str:
    """Build the prompt for one iteration (matching bash PROMPT+fix_plan injection)."""
    parts = []
    if task_input.prompt:
        parts.append(task_input.prompt)
    if task_input.fix_plan:
        parts.append(f"\n\n## Current Fix Plan\n\n{task_input.fix_plan}")
    if task_input.agent_instructions:
        parts.append(f"\n\n## Build/Run Instructions\n\n{task_input.agent_instructions}")
    return "\n".join(parts)

# AFTER:
RALPH_STATUS_INSTRUCTION = """

## Status Output

When you finish your work, output your status as a JSON code block with exactly these fields:

```json
{
  "version": 1,
  "status": "IN_PROGRESS or COMPLETED or ERROR or BLOCKED",
  "exit_signal": false,
  "tasks_completed": 0,
  "files_modified": 0,
  "progress_summary": "Brief description of what was done",
  "work_type": "IMPLEMENTATION or TESTING or REFACTORING or DOCUMENTATION or INVESTIGATION or PLANNING or REVIEW or UNKNOWN",
  "tests_status": "PASSING or FAILING or DEFERRED or NOT_RUN"
}
```

- Set `exit_signal` to `true` only when ALL tasks in the fix plan are complete.
- Set `tasks_completed` to the number of tasks finished in this iteration.
- Set `files_modified` to the number of files you created or changed.
- Set `tests_status` to `DEFERRED` if you did not run tests this iteration.
"""

def _build_iteration_prompt(self, task_input: TaskInput) -> str:
    """Build the prompt for one iteration (matching bash PROMPT+fix_plan injection)."""
    parts = []
    if task_input.prompt:
        parts.append(task_input.prompt)
    if task_input.fix_plan:
        parts.append(f"\n\n## Current Fix Plan\n\n{task_input.fix_plan}")
    if task_input.agent_instructions:
        parts.append(f"\n\n## Build/Run Instructions\n\n{task_input.agent_instructions}")
    parts.append(RALPH_STATUS_INSTRUCTION)
    return "\n".join(parts)
```

## Acceptance Criteria

- [ ] `_build_iteration_prompt()` appends status output instruction to every prompt
- [ ] Instruction includes the exact JSON schema with all `RalphStatusBlock` fields
- [ ] Instruction specifies valid enum values for `status`, `work_type`, and `tests_status`
- [ ] Instruction explains when to set `exit_signal: true`
- [ ] Instruction is added after all other prompt parts (prompt, fix_plan, agent_instructions)
- [ ] Existing prompts still work — the instruction is appended, not replacing anything
- [ ] The `RALPH_STATUS_INSTRUCTION` constant is defined at module level for testability

## Test Plan

```python
from ralph_sdk.agent import RalphAgent, TaskInput, RALPH_STATUS_INSTRUCTION

def test_prompt_includes_status_instruction():
    """Status instruction appended to built prompt."""
    agent = RalphAgent.__new__(RalphAgent)  # Skip __init__ for unit test
    agent.config = type("C", (), {"use_agent": False})()
    task = TaskInput(prompt="Do the work", fix_plan="- [ ] Task 1")
    # Call the method directly
    prompt = agent._build_iteration_prompt(task)
    assert "## Status Output" in prompt
    assert '"version": 1' in prompt
    assert "exit_signal" in prompt
    assert "IMPLEMENTATION" in prompt

def test_prompt_instruction_after_fix_plan():
    """Status instruction comes after fix plan and agent instructions."""
    agent = RalphAgent.__new__(RalphAgent)
    agent.config = type("C", (), {"use_agent": False})()
    task = TaskInput(
        prompt="Do the work",
        fix_plan="- [ ] Task 1",
        agent_instructions="Run npm test",
    )
    prompt = agent._build_iteration_prompt(task)
    fix_plan_pos = prompt.index("## Current Fix Plan")
    agent_instr_pos = prompt.index("## Build/Run Instructions")
    status_pos = prompt.index("## Status Output")
    assert fix_plan_pos < agent_instr_pos < status_pos

def test_prompt_without_fix_plan_still_has_instruction():
    """Status instruction present even with minimal prompt."""
    agent = RalphAgent.__new__(RalphAgent)
    agent.config = type("C", (), {"use_agent": False})()
    task = TaskInput(prompt="Do the work")
    prompt = agent._build_iteration_prompt(task)
    assert "## Status Output" in prompt

def test_status_instruction_constant_exists():
    """RALPH_STATUS_INSTRUCTION is a module-level constant."""
    assert isinstance(RALPH_STATUS_INSTRUCTION, str)
    assert len(RALPH_STATUS_INSTRUCTION) > 100
    assert "```json" in RALPH_STATUS_INSTRUCTION
```
