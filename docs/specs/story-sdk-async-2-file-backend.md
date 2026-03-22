# Story RALPH-SDK-ASYNC-2: Make FileStateBackend Methods Async with aiofiles

**Epic:** [Async SDK](epic-sdk-async.md)
**Priority:** Critical
**Status:** Pending
**Effort:** Medium
**Component:** `sdk/ralph_sdk/status.py`

---

## Problem

`RalphStatus.load()`, `RalphStatus.save()`, `CircuitBreakerState.load()`, and
`CircuitBreakerState.save()` all use synchronous `Path.read_text()` and `Path.write_text()`.
When called from an async context (TheStudio's FastAPI routes, Temporal activities), these
block the event loop. Every file I/O operation in the state layer must become async to
satisfy the Epic's requirement of zero synchronous file access in the async path.

## Solution

Replace all `Path.read_text()` / `Path.write_text()` calls in `status.py` with
`aiofiles.open()`. Preserve the atomic write pattern (write to temp file, then rename).
Add async class methods `aload()` and `asave()` alongside the existing sync methods to
maintain backward compatibility during the migration.

## Implementation

**File:** `sdk/ralph_sdk/status.py`

### RalphStatus.aload()

BEFORE (sync `load`):
```python
@classmethod
def load(cls, ralph_dir: str | Path = ".ralph") -> RalphStatus:
    """Load status from .ralph/status.json."""
    status_file = Path(ralph_dir) / "status.json"
    if not status_file.exists():
        return cls()
    try:
        data = json.loads(status_file.read_text(encoding="utf-8"))
        return cls.from_dict(data)
    except (json.JSONDecodeError, OSError):
        return cls()
```

AFTER (add async variant):
```python
@classmethod
async def aload(cls, ralph_dir: str | Path = ".ralph") -> RalphStatus:
    """Load status from .ralph/status.json (async)."""
    import aiofiles
    status_file = Path(ralph_dir) / "status.json"
    if not status_file.exists():
        return cls()
    try:
        async with aiofiles.open(status_file, encoding="utf-8") as f:
            content = await f.read()
        data = json.loads(content)
        return cls.from_dict(data)
    except (json.JSONDecodeError, OSError):
        return cls()
```

### RalphStatus.asave()

BEFORE (sync `save`):
```python
def save(self, ralph_dir: str | Path = ".ralph") -> None:
    """Write status atomically to .ralph/status.json."""
    ralph_dir = Path(ralph_dir)
    ralph_dir.mkdir(parents=True, exist_ok=True)
    status_file = ralph_dir / "status.json"
    tmp_file = status_file.with_suffix(f".{os.getpid()}.tmp")
    try:
        tmp_file.write_text(
            json.dumps(self.to_dict(), indent=2) + "\n",
            encoding="utf-8",
        )
        tmp_file.replace(status_file)
    finally:
        tmp_file.unlink(missing_ok=True)
```

AFTER (add async variant):
```python
async def asave(self, ralph_dir: str | Path = ".ralph") -> None:
    """Write status atomically to .ralph/status.json (async)."""
    import aiofiles
    ralph_dir = Path(ralph_dir)
    ralph_dir.mkdir(parents=True, exist_ok=True)
    status_file = ralph_dir / "status.json"
    tmp_file = status_file.with_suffix(f".{os.getpid()}.tmp")
    try:
        async with aiofiles.open(tmp_file, "w", encoding="utf-8") as f:
            await f.write(json.dumps(self.to_dict(), indent=2) + "\n")
        tmp_file.replace(status_file)
    finally:
        tmp_file.unlink(missing_ok=True)
```

### CircuitBreakerState.aload()

BEFORE (sync `load`):
```python
@classmethod
def load(cls, ralph_dir: str | Path = ".ralph") -> CircuitBreakerState:
    cb_file = Path(ralph_dir) / ".circuit_breaker_state"
    if not cb_file.exists():
        return cls()
    try:
        data = json.loads(cb_file.read_text(encoding="utf-8"))
        return cls(
            state=data.get("state", "CLOSED"),
            ...
        )
    except (json.JSONDecodeError, OSError):
        return cls()
```

AFTER (add async variant):
```python
@classmethod
async def aload(cls, ralph_dir: str | Path = ".ralph") -> CircuitBreakerState:
    """Load from .ralph/.circuit_breaker_state (async)."""
    import aiofiles
    cb_file = Path(ralph_dir) / ".circuit_breaker_state"
    if not cb_file.exists():
        return cls()
    try:
        async with aiofiles.open(cb_file, encoding="utf-8") as f:
            content = await f.read()
        data = json.loads(content)
        return cls(
            state=data.get("state", "CLOSED"),
            no_progress_count=data.get("no_progress_count", 0),
            same_error_count=data.get("same_error_count", 0),
            last_error=data.get("last_error", ""),
            opened_at=data.get("opened_at", ""),
            last_transition=data.get("last_transition", ""),
        )
    except (json.JSONDecodeError, OSError):
        return cls()
```

### CircuitBreakerState.asave()

AFTER (add async variant):
```python
async def asave(self, ralph_dir: str | Path = ".ralph") -> None:
    """Write circuit breaker state atomically (async)."""
    import aiofiles
    ralph_dir = Path(ralph_dir)
    ralph_dir.mkdir(parents=True, exist_ok=True)
    cb_file = ralph_dir / ".circuit_breaker_state"
    tmp_file = cb_file.with_suffix(f".{os.getpid()}.tmp")
    try:
        async with aiofiles.open(tmp_file, "w", encoding="utf-8") as f:
            await f.write(json.dumps({
                "state": self.state,
                "no_progress_count": self.no_progress_count,
                "same_error_count": self.same_error_count,
                "last_error": self.last_error,
                "opened_at": self.opened_at,
                "last_transition": self.last_transition,
            }, indent=2) + "\n")
        tmp_file.replace(cb_file)
    finally:
        tmp_file.unlink(missing_ok=True)
```

## Acceptance Criteria

- [ ] `RalphStatus.aload()` reads status.json using aiofiles
- [ ] `RalphStatus.asave()` writes status.json using aiofiles with atomic temp+rename
- [ ] `CircuitBreakerState.aload()` reads .circuit_breaker_state using aiofiles
- [ ] `CircuitBreakerState.asave()` writes .circuit_breaker_state using aiofiles with atomic temp+rename
- [ ] Original sync `load()` and `save()` methods are preserved (backward compat)
- [ ] Temp file cleanup in `finally` block preserved for WSL/NTFS compatibility
- [ ] No `Path.read_text()` or `Path.write_text()` in any async method

## Test Plan

- **Round-trip test**: `await status.asave(tmp_dir)` then `loaded = await RalphStatus.aload(tmp_dir)` and verify all fields match.
- **Atomic write test**: During `asave()`, confirm temp file is created then replaced (mock `Path.replace` to inspect intermediate state).
- **Missing file test**: `await RalphStatus.aload("/nonexistent")` returns default `RalphStatus()` without raising.
- **Corrupt file test**: Write invalid JSON to status.json, call `await RalphStatus.aload()`, verify default object returned.
- **CircuitBreakerState round-trip**: Same pattern -- `asave()` then `aload()`, verify `state`, `no_progress_count`, `last_error` fields.
- **Sync compat test**: Existing sync `load()` / `save()` still work unchanged.
