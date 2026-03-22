# Story RALPH-SDK-PYDANTIC-3: Convert CircuitBreakerState to Pydantic BaseModel

**Epic:** [Pydantic v2 Models](epic-sdk-pydantic-models.md)
**Priority:** Critical
**Status:** Done
**Effort:** Small
**Component:** `sdk/ralph_sdk/status.py`

---

## Problem

`CircuitBreakerState` is a plain `@dataclass` with no validation. The `state` field
accepts any string, so `CircuitBreakerState(state="MAYBE_OPEN")` silently succeeds.
The mutation methods (`trip()`, `half_open()`, `close()`, `reset()`) set string literals
that could drift from the accepted values without any enforcement.

The `.circuit_breaker_state` JSON file format must not change — the bash loop's
`circuit_breaker.sh` reads and writes this file.

## Solution

1. Introduce `CircuitBreakerStateEnum` as a `StrEnum` with values `CLOSED`, `HALF_OPEN`, `OPEN`.
2. Convert `CircuitBreakerState` from `@dataclass` to Pydantic `BaseModel`.
3. Preserve `trip()`, `half_open()`, `close()`, `reset()`, `load()`, and `save()` method signatures.
4. The JSON output of `save()` must remain byte-identical for the same input data.

## Implementation

### BEFORE (`sdk/ralph_sdk/status.py`, lines 91-172)

```python
@dataclass
class CircuitBreakerState:
    """Circuit breaker state compatible with .circuit_breaker_state JSON."""

    state: str = "CLOSED"  # CLOSED, HALF_OPEN, OPEN
    no_progress_count: int = 0
    same_error_count: int = 0
    last_error: str = ""
    opened_at: str = ""
    last_transition: str = ""

    @classmethod
    def load(cls, ralph_dir: str | Path = ".ralph") -> CircuitBreakerState:
        """Load from .ralph/.circuit_breaker_state."""
        cb_file = Path(ralph_dir) / ".circuit_breaker_state"
        if not cb_file.exists():
            return cls()
        try:
            data = json.loads(cb_file.read_text(encoding="utf-8"))
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

    def save(self, ralph_dir: str | Path = ".ralph") -> None:
        """Write circuit breaker state atomically."""
        ralph_dir = Path(ralph_dir)
        ralph_dir.mkdir(parents=True, exist_ok=True)
        cb_file = ralph_dir / ".circuit_breaker_state"
        tmp_file = cb_file.with_suffix(f".{os.getpid()}.tmp")
        try:
            tmp_file.write_text(
                json.dumps({
                    "state": self.state,
                    "no_progress_count": self.no_progress_count,
                    "same_error_count": self.same_error_count,
                    "last_error": self.last_error,
                    "opened_at": self.opened_at,
                    "last_transition": self.last_transition,
                }, indent=2) + "\n",
                encoding="utf-8",
            )
            tmp_file.replace(cb_file)
        finally:
            tmp_file.unlink(missing_ok=True)

    def trip(self, reason: str = "") -> None:
        """Transition to OPEN state."""
        self.state = "OPEN"
        self.opened_at = time.strftime("%Y-%m-%dT%H:%M:%S%z")
        self.last_error = reason
        self.last_transition = f"OPEN: {reason}"

    def half_open(self) -> None:
        """Transition to HALF_OPEN (cooldown expired)."""
        self.state = "HALF_OPEN"
        self.last_transition = "HALF_OPEN: cooldown expired"

    def close(self) -> None:
        """Transition to CLOSED (recovery successful)."""
        self.state = "CLOSED"
        self.no_progress_count = 0
        self.same_error_count = 0
        self.last_error = ""
        self.opened_at = ""
        self.last_transition = "CLOSED: recovery successful"

    def reset(self, reason: str = "manual") -> None:
        """Reset to initial state."""
        self.state = "CLOSED"
        self.no_progress_count = 0
        self.same_error_count = 0
        self.last_error = ""
        self.opened_at = ""
        self.last_transition = f"RESET: {reason}"
```

### AFTER (`sdk/ralph_sdk/status.py`, circuit breaker section)

```python
class CircuitBreakerStateEnum(StrEnum):
    """Valid circuit breaker states."""
    CLOSED = "CLOSED"
    HALF_OPEN = "HALF_OPEN"
    OPEN = "OPEN"


class CircuitBreakerState(BaseModel):
    """Circuit breaker state compatible with .circuit_breaker_state JSON."""

    state: CircuitBreakerStateEnum = CircuitBreakerStateEnum.CLOSED
    no_progress_count: int = 0
    same_error_count: int = 0
    last_error: str = ""
    opened_at: str = ""
    last_transition: str = ""

    @classmethod
    def load(cls, ralph_dir: str | Path = ".ralph") -> CircuitBreakerState:
        """Load from .ralph/.circuit_breaker_state."""
        cb_file = Path(ralph_dir) / ".circuit_breaker_state"
        if not cb_file.exists():
            return cls()
        try:
            data = json.loads(cb_file.read_text(encoding="utf-8"))
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

    def save(self, ralph_dir: str | Path = ".ralph") -> None:
        """Write circuit breaker state atomically."""
        ralph_dir = Path(ralph_dir)
        ralph_dir.mkdir(parents=True, exist_ok=True)
        cb_file = ralph_dir / ".circuit_breaker_state"
        tmp_file = cb_file.with_suffix(f".{os.getpid()}.tmp")
        try:
            tmp_file.write_text(
                json.dumps({
                    "state": self.state,
                    "no_progress_count": self.no_progress_count,
                    "same_error_count": self.same_error_count,
                    "last_error": self.last_error,
                    "opened_at": self.opened_at,
                    "last_transition": self.last_transition,
                }, indent=2) + "\n",
                encoding="utf-8",
            )
            tmp_file.replace(cb_file)
        finally:
            tmp_file.unlink(missing_ok=True)

    def trip(self, reason: str = "") -> None:
        """Transition to OPEN state."""
        self.state = CircuitBreakerStateEnum.OPEN
        self.opened_at = time.strftime("%Y-%m-%dT%H:%M:%S%z")
        self.last_error = reason
        self.last_transition = f"OPEN: {reason}"

    def half_open(self) -> None:
        """Transition to HALF_OPEN (cooldown expired)."""
        self.state = CircuitBreakerStateEnum.HALF_OPEN
        self.last_transition = "HALF_OPEN: cooldown expired"

    def close(self) -> None:
        """Transition to CLOSED (recovery successful)."""
        self.state = CircuitBreakerStateEnum.CLOSED
        self.no_progress_count = 0
        self.same_error_count = 0
        self.last_error = ""
        self.opened_at = ""
        self.last_transition = "CLOSED: recovery successful"

    def reset(self, reason: str = "manual") -> None:
        """Reset to initial state."""
        self.state = CircuitBreakerStateEnum.CLOSED
        self.no_progress_count = 0
        self.same_error_count = 0
        self.last_error = ""
        self.opened_at = ""
        self.last_transition = f"RESET: {reason}"
```

### Key Changes

- `state` field typed as `CircuitBreakerStateEnum` instead of `str`.
- Mutation methods (`trip()`, `half_open()`, `close()`, `reset()`) use enum members instead of string literals.
- `StrEnum` values serialize to plain strings in JSON — bash `circuit_breaker.sh` sees identical output.
- `load()` accepts plain strings from existing `.circuit_breaker_state` files — Pydantic coerces to enum.
- Also update `RalphStatus.circuit_breaker_state` field from `str` to `CircuitBreakerStateEnum` (cross-reference with Story 2).

### Cross-Model Update

In the `RalphStatus` model (from Story 2), update the `circuit_breaker_state` field:

```python
# BEFORE (Story 2 left this as str)
circuit_breaker_state: str = "CLOSED"

# AFTER (Story 3 types it)
circuit_breaker_state: CircuitBreakerStateEnum = CircuitBreakerStateEnum.CLOSED
```

## Acceptance Criteria

- [ ] `CircuitBreakerState` is a Pydantic `BaseModel` (not `@dataclass`)
- [ ] `CircuitBreakerStateEnum` StrEnum with values: `CLOSED`, `HALF_OPEN`, `OPEN`
- [ ] `CircuitBreakerState(state="INVALID")` raises `ValidationError`
- [ ] `CircuitBreakerState(state="HALF_OPEN")` succeeds (string coercion to enum)
- [ ] `trip()`, `half_open()`, `close()`, `reset()` methods work correctly
- [ ] `save()` output is identical to the dataclass version for the same input data
- [ ] `load()` reads existing `.circuit_breaker_state` files from bash loop
- [ ] `RalphStatus.circuit_breaker_state` field updated to use `CircuitBreakerStateEnum`
- [ ] `model_json_schema()` returns valid JSON Schema

## Test Plan

```python
import json
import pytest
from pydantic import ValidationError
from ralph_sdk.status import CircuitBreakerState, CircuitBreakerStateEnum


def test_default_construction():
    """Default CircuitBreakerState matches previous dataclass defaults."""
    cb = CircuitBreakerState()
    assert cb.state == CircuitBreakerStateEnum.CLOSED
    assert cb.no_progress_count == 0
    assert cb.same_error_count == 0
    assert cb.last_error == ""


def test_string_coercion():
    """Plain strings from bash loop coerce to enum values."""
    cb = CircuitBreakerState(state="HALF_OPEN")
    assert cb.state == CircuitBreakerStateEnum.HALF_OPEN


def test_invalid_state_raises():
    """Invalid state raises ValidationError."""
    with pytest.raises(ValidationError):
        CircuitBreakerState(state="MAYBE_OPEN")


def test_trip():
    """trip() transitions to OPEN."""
    cb = CircuitBreakerState()
    cb.trip("too many errors")
    assert cb.state == CircuitBreakerStateEnum.OPEN
    assert cb.last_error == "too many errors"
    assert cb.opened_at != ""


def test_half_open():
    """half_open() transitions to HALF_OPEN."""
    cb = CircuitBreakerState(state="OPEN")
    cb.half_open()
    assert cb.state == CircuitBreakerStateEnum.HALF_OPEN


def test_close():
    """close() resets to CLOSED with counters zeroed."""
    cb = CircuitBreakerState(state="HALF_OPEN", no_progress_count=3)
    cb.close()
    assert cb.state == CircuitBreakerStateEnum.CLOSED
    assert cb.no_progress_count == 0
    assert cb.same_error_count == 0


def test_reset():
    """reset() clears all state."""
    cb = CircuitBreakerState(state="OPEN", no_progress_count=5, last_error="fail")
    cb.reset("manual")
    assert cb.state == CircuitBreakerStateEnum.CLOSED
    assert cb.no_progress_count == 0
    assert cb.last_transition == "RESET: manual"


def test_save_load_round_trip(tmp_path):
    """save() then load() preserves all data."""
    ralph_dir = tmp_path / ".ralph"
    cb = CircuitBreakerState(state="OPEN", no_progress_count=2, last_error="timeout")
    cb.save(ralph_dir)
    restored = CircuitBreakerState.load(ralph_dir)
    assert restored.state == cb.state
    assert restored.no_progress_count == cb.no_progress_count
    assert restored.last_error == cb.last_error


def test_load_from_bash_circuit_breaker(tmp_path):
    """Load a .circuit_breaker_state file written by bash circuit_breaker.sh."""
    ralph_dir = tmp_path / ".ralph"
    ralph_dir.mkdir()
    cb_json = {
        "state": "HALF_OPEN",
        "no_progress_count": 3,
        "same_error_count": 1,
        "last_error": "no output",
        "opened_at": "2026-03-22T10:00:00+0000",
        "last_transition": "HALF_OPEN: cooldown expired",
    }
    (ralph_dir / ".circuit_breaker_state").write_text(json.dumps(cb_json, indent=2))
    cb = CircuitBreakerState.load(ralph_dir)
    assert cb.state == CircuitBreakerStateEnum.HALF_OPEN
    assert cb.no_progress_count == 3


def test_json_schema():
    """model_json_schema() returns valid schema."""
    schema = CircuitBreakerState.model_json_schema()
    assert "properties" in schema
    assert "state" in schema["properties"]
```
