# Story RALPH-SDK-STATE-4: Wire state_backend into RalphAgent.__init__()

**Epic:** [Pluggable State Backend](epic-sdk-state-backend.md)
**Priority:** Critical
**Status:** Pending
**Effort:** Small
**Component:** `sdk/ralph_sdk/agent.py`

---

## Problem

`RalphAgent.__init__()` currently creates its own `ralph_dir` Path and passes it to
various internal methods that perform file I/O directly. There is no way to inject an
alternative state backend.

Before Story 5 can remove direct file I/O from `agent.py`, the `state_backend` parameter
must be wired in and available on `self`.

## Solution

Add an optional `state_backend` parameter to `RalphAgent.__init__()`. When not provided,
default to `FileStateBackend(ralph_dir)` to preserve backward compatibility. Store it as
`self.state_backend` for use by all state operations.

This story only wires the parameter -- it does not yet change any method implementations.
Story 5 handles the actual replacement of file I/O calls.

## Implementation

Modify `sdk/ralph_sdk/agent.py`:

1. Add import at top of file:
   ```python
   from ralph_sdk.state import FileStateBackend, RalphStateBackend
   ```

2. Update `RalphAgent.__init__()` signature:
   ```python
   def __init__(
       self,
       config: RalphConfig | None = None,
       project_dir: str | Path = ".",
       state_backend: RalphStateBackend | None = None,
   ) -> None:
       self.config = config or RalphConfig.load(project_dir)
       self.project_dir = Path(project_dir).resolve()
       self.ralph_dir = self.project_dir / self.config.ralph_dir
       self.loop_count = 0
       self.start_time = 0.0
       self.session_id = ""
       self._completion_indicators = 0
       self._running = False

       # State backend — default to file-based for backward compatibility
       self.state_backend: RalphStateBackend = (
           state_backend
           if state_backend is not None
           else FileStateBackend(self.ralph_dir)
       )

       # Ensure .ralph directory exists (FileStateBackend also does this,
       # but keep it for non-file backends that don't create directories)
       self.ralph_dir.mkdir(parents=True, exist_ok=True)
       (self.ralph_dir / "logs").mkdir(exist_ok=True)
   ```

3. No changes to any method bodies in this story -- they still use direct file I/O.
   Story 5 replaces them with `self.state_backend.*` calls.

## Acceptance Criteria

- [ ] `RalphAgent.__init__()` accepts optional `state_backend` parameter
- [ ] Parameter type is `RalphStateBackend | None`, defaulting to `None`
- [ ] When `None`, defaults to `FileStateBackend(self.ralph_dir)`
- [ ] `self.state_backend` is set and accessible
- [ ] `RalphAgent()` with no arguments still works (backward compatible)
- [ ] `RalphAgent(state_backend=NullStateBackend())` accepts the null backend
- [ ] Existing tests continue to pass without modification
- [ ] Import of `FileStateBackend` and `RalphStateBackend` added to agent.py

## Test Plan

- **Default backend**: `agent = RalphAgent(project_dir=tmp)`. Verify `agent.state_backend` is an instance of `FileStateBackend`.
- **Custom backend**: `agent = RalphAgent(project_dir=tmp, state_backend=NullStateBackend())`. Verify `agent.state_backend` is an instance of `NullStateBackend`.
- **Backward compatibility**: Run the existing full test suite with no changes. All tests must pass since the default behavior is unchanged.
- **Type check**: `mypy sdk/ralph_sdk/agent.py` passes cleanly with the new parameter.
