# Story RALPH-SDK-PYDANTIC-6: Convert RalphConfig to Pydantic BaseModel

**Epic:** [Pydantic v2 Models](epic-sdk-pydantic-models.md)
**Priority:** High
**Status:** Done
**Effort:** Medium
**Component:** `sdk/ralph_sdk/config.py`

---

## Problem

`RalphConfig` is a plain `@dataclass` with 30+ fields and no runtime validation. Critical
settings like `max_calls_per_hour`, `timeout_minutes`, and `max_turns` accept any integer,
including invalid values like `0`, `-1`, or `99999`. A misconfigured `.ralphrc` or
`ralph.config.json` silently produces a config that causes failures deep in the loop.

The three-layer precedence chain (`.ralphrc` -> `ralph.config.json` -> env vars) uses
`setattr()` to apply overrides, which bypasses any validation.

## Solution

1. Convert `RalphConfig` from `@dataclass` to Pydantic `BaseModel`.
2. Add validation ranges: `max_calls_per_hour` (1-1000), `timeout_minutes` (1-120), `max_turns` (1-200).
3. Keep the `load()` class method with the full precedence chain.
4. Keep custom `_load_ralphrc()`, `_load_json_config()`, `_load_env()` methods — use `model_validate()` at the end to apply validation.
5. Preserve `to_dict()` and `to_json()` methods.

### Design Decision: Custom Load vs Pydantic BaseSettings

Pydantic v2 provides `pydantic-settings` with `BaseSettings` that supports env var loading.
However, Ralph's precedence chain is more complex:
- `.ralphrc` is a bash file parsed with regex (not a `.env` file)
- `ralph.config.json` uses camelCase keys (not snake_case)
- Env vars use `RALPH_` and `CLAUDE_` prefixes with non-standard mapping

Keeping the custom `load()` method is simpler and avoids adding a `pydantic-settings`
dependency. The `load()` method builds a raw dict from all three layers, then passes it
to `model_validate()` for final construction with validation.

## Implementation

### BEFORE (`sdk/ralph_sdk/config.py`, class definition, lines 14-92)

```python
@dataclass
class RalphConfig:
    """Configuration for Ralph SDK agent.

    Precedence (highest to lowest):
    1. Environment variables
    2. ralph.config.json
    3. .ralphrc (bash config)
    4. Defaults
    """

    # Project
    project_name: str = "my-project"
    project_type: str = "unknown"

    # Loop settings
    max_calls_per_hour: int = 100
    timeout_minutes: int = 15
    output_format: str = "json"

    # Tool permissions
    allowed_tools: list[str] = field(default_factory=lambda: [
        "Write", "Read", "Edit", "Bash(git add *)", "Bash(git commit *)",
        ...
    ])

    # Session management
    session_continuity: bool = True
    session_expiry_hours: int = 24

    # Circuit breaker
    cb_no_progress_threshold: int = 3
    cb_same_error_threshold: int = 5
    cb_output_decline_threshold: int = 70
    cb_cooldown_minutes: int = 30
    cb_auto_reset: bool = False

    # Log rotation
    log_max_size_mb: int = 10
    log_max_files: int = 5
    log_max_output_files: int = 20

    # Dry run
    dry_run: bool = False

    # Advanced
    claude_code_cmd: str = "claude"
    claude_auto_update: bool = True
    claude_min_version: str = "2.0.76"
    verbose: bool = False

    # Agent settings
    agent_name: str = "ralph"
    use_agent: bool = True

    # Teams (experimental)
    enable_teams: bool = False
    max_teammates: int = 3
    bg_testing: bool = False
    teammate_mode: str = "tmux"

    # Paths (derived)
    ralph_dir: str = ".ralph"

    # SDK-specific
    model: str = "claude-sonnet-4-20250514"
    max_turns: int = 50
```

### AFTER (`sdk/ralph_sdk/config.py`, class definition)

```python
from pydantic import BaseModel, Field


class RalphConfig(BaseModel):
    """Configuration for Ralph SDK agent.

    Precedence (highest to lowest):
    1. Environment variables
    2. ralph.config.json
    3. .ralphrc (bash config)
    4. Defaults
    """

    # Project
    project_name: str = "my-project"
    project_type: str = "unknown"

    # Loop settings
    max_calls_per_hour: int = Field(default=100, ge=1, le=1000)
    timeout_minutes: int = Field(default=15, ge=1, le=120)
    output_format: str = "json"

    # Tool permissions
    allowed_tools: list[str] = Field(default_factory=lambda: [
        "Write", "Read", "Edit", "Bash(git add *)", "Bash(git commit *)",
        "Bash(git diff *)", "Bash(git log *)", "Bash(git status)",
        "Bash(git status *)", "Bash(git push *)", "Bash(git pull *)",
        "Bash(git fetch *)", "Bash(git checkout *)", "Bash(git branch *)",
        "Bash(git stash *)", "Bash(git merge *)", "Bash(git tag *)",
        "Bash(git -C *)", "Bash(grep *)", "Bash(find *)", "Bash(npm *)",
        "Bash(pytest)", "Bash(xargs *)", "Bash(sort *)", "Bash(tee *)",
        "Bash(rm *)", "Bash(touch *)", "Bash(sed *)", "Bash(awk *)",
        "Bash(tr *)", "Bash(cut *)", "Bash(dirname *)", "Bash(basename *)",
        "Bash(realpath *)", "Bash(test *)", "Bash(true)", "Bash(false)",
        "Bash(sleep *)", "Bash(ls *)", "Bash(cat *)", "Bash(wc *)",
        "Bash(head *)", "Bash(tail *)", "Bash(mkdir *)", "Bash(cp *)",
        "Bash(mv *)",
    ])

    # Session management
    session_continuity: bool = True
    session_expiry_hours: int = Field(default=24, ge=1)

    # Circuit breaker
    cb_no_progress_threshold: int = Field(default=3, ge=1)
    cb_same_error_threshold: int = Field(default=5, ge=1)
    cb_output_decline_threshold: int = Field(default=70, ge=1, le=100)
    cb_cooldown_minutes: int = Field(default=30, ge=1)
    cb_auto_reset: bool = False

    # Log rotation
    log_max_size_mb: int = Field(default=10, ge=1)
    log_max_files: int = Field(default=5, ge=1)
    log_max_output_files: int = Field(default=20, ge=1)

    # Dry run
    dry_run: bool = False

    # Advanced
    claude_code_cmd: str = "claude"
    claude_auto_update: bool = True
    claude_min_version: str = "2.0.76"
    verbose: bool = False

    # Agent settings
    agent_name: str = "ralph"
    use_agent: bool = True

    # Teams (experimental)
    enable_teams: bool = False
    max_teammates: int = Field(default=3, ge=1, le=10)
    bg_testing: bool = False
    teammate_mode: str = "tmux"

    # Paths (derived)
    ralph_dir: str = ".ralph"

    # SDK-specific
    model: str = "claude-sonnet-4-20250514"
    max_turns: int = Field(default=50, ge=1, le=200)
```

### BEFORE (`load()` method, lines 93-112)

```python
    @classmethod
    def load(cls, project_dir: str | Path = ".") -> RalphConfig:
        """Load configuration with full precedence chain."""
        project_dir = Path(project_dir)
        config = cls()

        # Layer 1: .ralphrc (bash config)
        ralphrc_path = project_dir / ".ralphrc"
        if ralphrc_path.exists():
            config._load_ralphrc(ralphrc_path)

        # Layer 2: ralph.config.json
        json_config_path = project_dir / "ralph.config.json"
        if json_config_path.exists():
            config._load_json_config(json_config_path)

        # Layer 3: Environment variables (highest precedence)
        config._load_env()

        return config
```

### AFTER (`load()` method — two-pass approach)

```python
    @classmethod
    def load(cls, project_dir: str | Path = ".") -> RalphConfig:
        """Load configuration with full precedence chain.

        Uses a two-pass approach:
        1. Collect raw overrides from all layers into a dict (no validation).
        2. Pass the merged dict to model_validate() for validated construction.
        """
        project_dir = Path(project_dir)
        overrides: dict[str, Any] = {}

        # Layer 1: .ralphrc (bash config) — lowest precedence
        ralphrc_path = project_dir / ".ralphrc"
        if ralphrc_path.exists():
            overrides.update(cls._parse_ralphrc(ralphrc_path))

        # Layer 2: ralph.config.json
        json_config_path = project_dir / "ralph.config.json"
        if json_config_path.exists():
            overrides.update(cls._parse_json_config(json_config_path))

        # Layer 3: Environment variables — highest precedence
        overrides.update(cls._parse_env())

        return cls.model_validate(overrides)

    @staticmethod
    def _parse_ralphrc(path: Path) -> dict[str, Any]:
        """Parse .ralphrc bash config file into a dict of overrides."""
        # (Same regex parsing logic, returns dict instead of calling setattr)
        ...

    @staticmethod
    def _parse_json_config(path: Path) -> dict[str, Any]:
        """Parse ralph.config.json into a dict of overrides."""
        # (Same camelCase -> snake_case mapping, returns dict)
        ...

    @staticmethod
    def _parse_env() -> dict[str, Any]:
        """Parse environment variables into a dict of overrides."""
        # (Same RALPH_/CLAUDE_ prefix mapping, returns dict)
        ...
```

### Key Changes

- `@dataclass` replaced with `BaseModel`.
- `field(default_factory=...)` replaced with `Field(default_factory=...)`.
- Validation constraints on critical fields: `max_calls_per_hour` (1-1000), `timeout_minutes` (1-120), `max_turns` (1-200).
- `load()` refactored to a two-pass approach: collect raw overrides, then `model_validate()`.
- Private `_load_*` methods (which used `setattr()`) replaced with static `_parse_*` methods that return dicts.
- `to_dict()` and `to_json()` methods unchanged in behavior.
- Existing `_set_from_key()` helper removed — key mapping logic moved into `_parse_ralphrc()`.

### Migration Notes

- The `setattr()` pattern in `_load_*` methods is incompatible with Pydantic's validation.
  Assigning `config.max_calls_per_hour = -1` would bypass validation. The two-pass approach
  collects all overrides as a raw dict, then validates everything at construction time.
- If an override value is invalid (e.g., `MAX_CALLS_PER_HOUR=0` in env), `model_validate()`
  raises `ValidationError` instead of silently accepting it. This is a **behavior change**
  that improves reliability but may need error handling in `load()` callers.

## Acceptance Criteria

- [ ] `RalphConfig` is a Pydantic `BaseModel` (not `@dataclass`)
- [ ] `RalphConfig(max_calls_per_hour=0)` raises `ValidationError`
- [ ] `RalphConfig(max_calls_per_hour=1001)` raises `ValidationError`
- [ ] `RalphConfig(timeout_minutes=0)` raises `ValidationError`
- [ ] `RalphConfig(timeout_minutes=121)` raises `ValidationError`
- [ ] `RalphConfig(max_turns=0)` raises `ValidationError`
- [ ] `RalphConfig(max_turns=201)` raises `ValidationError`
- [ ] `RalphConfig()` succeeds with all defaults
- [ ] `load()` applies full precedence chain: `.ralphrc` < `ralph.config.json` < env vars
- [ ] `load()` with a valid `.ralphrc` and `ralph.config.json` produces correct merged config
- [ ] `to_dict()` output format is unchanged (camelCase keys)
- [ ] `to_json()` output is valid JSON matching `to_dict()`
- [ ] `model_json_schema()` returns valid JSON Schema with constraint metadata
- [ ] Invalid env var values raise clear `ValidationError` (not silent skip)

## Test Plan

```python
import json
import os
import pytest
from pydantic import ValidationError
from ralph_sdk.config import RalphConfig


def test_default_construction():
    """Default RalphConfig has sensible defaults."""
    c = RalphConfig()
    assert c.max_calls_per_hour == 100
    assert c.timeout_minutes == 15
    assert c.max_turns == 50
    assert c.project_name == "my-project"


def test_max_calls_per_hour_range():
    """max_calls_per_hour must be 1-1000."""
    RalphConfig(max_calls_per_hour=1)     # min
    RalphConfig(max_calls_per_hour=1000)  # max
    with pytest.raises(ValidationError):
        RalphConfig(max_calls_per_hour=0)
    with pytest.raises(ValidationError):
        RalphConfig(max_calls_per_hour=1001)


def test_timeout_minutes_range():
    """timeout_minutes must be 1-120."""
    RalphConfig(timeout_minutes=1)    # min
    RalphConfig(timeout_minutes=120)  # max
    with pytest.raises(ValidationError):
        RalphConfig(timeout_minutes=0)
    with pytest.raises(ValidationError):
        RalphConfig(timeout_minutes=121)


def test_max_turns_range():
    """max_turns must be 1-200."""
    RalphConfig(max_turns=1)    # min
    RalphConfig(max_turns=200)  # max
    with pytest.raises(ValidationError):
        RalphConfig(max_turns=0)
    with pytest.raises(ValidationError):
        RalphConfig(max_turns=201)


def test_to_dict_camel_case():
    """to_dict() uses camelCase keys for JSON compatibility."""
    c = RalphConfig()
    d = c.to_dict()
    assert "maxCallsPerHour" in d
    assert "timeoutMinutes" in d
    assert "maxTurns" in d
    assert d["maxCallsPerHour"] == 100


def test_to_json():
    """to_json() returns valid JSON string."""
    c = RalphConfig()
    j = c.to_json()
    parsed = json.loads(j)
    assert parsed["maxCallsPerHour"] == 100


def test_load_ralphrc(tmp_path):
    """load() reads .ralphrc bash config."""
    (tmp_path / ".ralphrc").write_text(
        'MAX_CALLS_PER_HOUR=200\n'
        'CLAUDE_TIMEOUT_MINUTES=30\n'
        'PROJECT_NAME="test-project"\n'
    )
    c = RalphConfig.load(tmp_path)
    assert c.max_calls_per_hour == 200
    assert c.timeout_minutes == 30
    assert c.project_name == "test-project"


def test_load_json_config(tmp_path):
    """load() reads ralph.config.json with camelCase keys."""
    config = {"maxCallsPerHour": 300, "maxTurns": 100, "projectName": "json-project"}
    (tmp_path / "ralph.config.json").write_text(json.dumps(config))
    c = RalphConfig.load(tmp_path)
    assert c.max_calls_per_hour == 300
    assert c.max_turns == 100
    assert c.project_name == "json-project"


def test_load_precedence(tmp_path):
    """Environment variables override ralph.config.json which overrides .ralphrc."""
    (tmp_path / ".ralphrc").write_text('MAX_CALLS_PER_HOUR=100\n')
    (tmp_path / "ralph.config.json").write_text(json.dumps({"maxCallsPerHour": 200}))

    # Env var should win
    os.environ["MAX_CALLS_PER_HOUR"] = "300"
    try:
        c = RalphConfig.load(tmp_path)
        assert c.max_calls_per_hour == 300
    finally:
        del os.environ["MAX_CALLS_PER_HOUR"]


def test_load_invalid_value_raises(tmp_path):
    """Invalid values in config sources raise ValidationError."""
    (tmp_path / ".ralphrc").write_text('MAX_CALLS_PER_HOUR=0\n')
    with pytest.raises(ValidationError):
        RalphConfig.load(tmp_path)


def test_json_schema():
    """model_json_schema() returns valid schema with constraints."""
    schema = RalphConfig.model_json_schema()
    assert "properties" in schema
    max_calls = schema["properties"]["max_calls_per_hour"]
    assert max_calls.get("minimum") == 1 or max_calls.get("exclusiveMinimum") == 0
    assert max_calls.get("maximum") == 1000 or max_calls.get("exclusiveMaximum") == 1001
```
