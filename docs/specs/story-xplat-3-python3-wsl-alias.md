# Story XPLAT-3: Python3 Alias in WSL Agent Environments

**Epic:** [Cross-Platform Compatibility](epic-cross-platform-compatibility.md)
**Priority:** Low
**Status:** Pending
**Effort:** Trivial
**Component:** `.claude/agents/ralph.md`, `.claude/agents/ralph-tester.md`

---

## Problem

Agent tool calls use `python` which fails in WSL with:
```
Exit code 127
/bin/bash: line 1: python: command not found
```

Modern Ubuntu/Debian (the standard WSL distros) only ship `python3`. The `python` command requires the `python-is-python3` package to be explicitly installed.

**Root cause confirmed by:** TheStudio logs 2026-03-22, agent execution failure.

## Solution

Update agent prompts to specify `python3` for Python execution. Add a note in the agent definition about WSL Python requirements.

## Implementation

### Step 1: Update agent prompts

In `.claude/agents/ralph.md` and other agents that may run Python:

```markdown
## Environment Notes

- **Python**: Use `python3` (not `python`) — WSL/Ubuntu only provides `python3` by default
- **pip**: Use `pip3` or `python3 -m pip`
```

### Step 2: Add validate-command.sh check (optional enhancement)

In the existing `validate-command.sh` PreToolUse hook, add a warning for bare `python`:

```bash
# In validate-command.sh:
# Warn about bare 'python' usage
if [[ "$command" =~ ^python[[:space:]] ]] && [[ ! "$command" =~ ^python3 ]]; then
    if ! command -v python &>/dev/null && command -v python3 &>/dev/null; then
        echo "WARN: 'python' not found. Use 'python3' instead." >&2
        # Don't block — Claude may self-correct
    fi
fi
```

### Step 3: Add to PROMPT.md template

In the PROMPT.md template that drives each loop:

```markdown
## Environment
- Use `python3` (not `python`) for Python commands
```

## Design Notes

- **Agent prompt vs hook**: Adding to the agent prompt is the most reliable approach — Claude reads it at the start of every invocation. The hook approach is a secondary safety net.
- **Not blocking**: The validate-command hook should warn, not block, because Claude may be running a command that has its own `python` binary (e.g., conda environments, virtualenvs).
- **PROMPT.md**: Including the note in PROMPT.md ensures it's seen even when agents are not used (legacy mode).

## Acceptance Criteria

- [ ] Agent definitions reference `python3` in environment notes
- [ ] PROMPT.md template includes `python3` guidance
- [ ] Claude uses `python3` instead of `python` in generated commands

## Test Plan

```bash
@test "ralph agent mentions python3" {
    run grep -c "python3" "$RALPH_DIR/.claude/agents/ralph.md"
    assert [ "$output" -ge 1 ]
}

@test "PROMPT template mentions python3" {
    run grep -c "python3" "$RALPH_DIR/templates/PROMPT.md.template"
    assert [ "$output" -ge 1 ]
}
```

## References

- [Ubuntu — python-is-python3 Package](https://packages.ubuntu.com/jammy/python-is-python3)
- [PEP 394 — The "python" Command on Unix-Like Systems](https://peps.python.org/pep-0394/)
- [Microsoft — WSL Development Environment](https://learn.microsoft.com/en-us/windows/wsl/setup/environment)
