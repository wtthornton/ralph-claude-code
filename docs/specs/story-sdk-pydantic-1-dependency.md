# Story RALPH-SDK-PYDANTIC-1: Add Pydantic v2 Dependency

**Epic:** [Pydantic v2 Models](epic-sdk-pydantic-models.md)
**Priority:** Critical
**Status:** Pending
**Effort:** Trivial
**Component:** `sdk/pyproject.toml`

---

## Problem

The Ralph SDK uses plain `@dataclass` for all data models. Before converting any
model to Pydantic `BaseModel`, the dependency must be declared in `pyproject.toml`.
Currently the SDK has zero runtime dependencies — only `pytest` and `pytest-cov` in
dev extras.

## Solution

Add `pydantic>=2.0,<3.0` to the `[project.dependencies]` array in `sdk/pyproject.toml`.
This is a zero-risk change that unblocks all subsequent stories.

## Implementation

### BEFORE (`sdk/pyproject.toml`)

```toml
[project]
name = "ralph-sdk"
version = "1.3.0"
description = "Ralph Agent SDK — autonomous AI development loop for Claude Code"
readme = "README.md"
license = {text = "MIT"}
requires-python = ">=3.12"
authors = [
    {name = "Ralph Contributors"},
]
keywords = ["claude", "ai", "agent", "sdk", "autonomous", "development"]
classifiers = [
    "Development Status :: 4 - Beta",
    "Intended Audience :: Developers",
    "License :: OSI Approved :: MIT License",
    "Programming Language :: Python :: 3.12",
    "Programming Language :: Python :: 3.13",
    "Topic :: Software Development :: Libraries",
]

[project.optional-dependencies]
dev = [
    "pytest>=8.0",
    "pytest-cov>=4.0",
]
```

### AFTER (`sdk/pyproject.toml`)

```toml
[project]
name = "ralph-sdk"
version = "1.3.0"
description = "Ralph Agent SDK — autonomous AI development loop for Claude Code"
readme = "README.md"
license = {text = "MIT"}
requires-python = ">=3.12"
authors = [
    {name = "Ralph Contributors"},
]
keywords = ["claude", "ai", "agent", "sdk", "autonomous", "development"]
classifiers = [
    "Development Status :: 4 - Beta",
    "Intended Audience :: Developers",
    "License :: OSI Approved :: MIT License",
    "Programming Language :: Python :: 3.12",
    "Programming Language :: Python :: 3.13",
    "Topic :: Software Development :: Libraries",
]
dependencies = [
    "pydantic>=2.0,<3.0",
]

[project.optional-dependencies]
dev = [
    "pytest>=8.0",
    "pytest-cov>=4.0",
]
```

### Key Notes

- The `dependencies` key goes directly under `[project]`, before `[project.optional-dependencies]`.
- Version constraint `>=2.0,<3.0` ensures Pydantic v2 features (`model_dump()`, `model_validate()`, `ConfigDict`) are available while avoiding a hypothetical v3 breaking change.
- No changes to `[build-system]` or `[tool.*]` sections.

## Acceptance Criteria

- [ ] `pyproject.toml` declares `pydantic>=2.0,<3.0` in `[project] dependencies`
- [ ] `pip install -e sdk/` succeeds and installs pydantic 2.x
- [ ] `python -c "import pydantic; print(pydantic.VERSION)"` prints a 2.x version
- [ ] Existing SDK tests still pass (`cd sdk && pytest`)
- [ ] No changes to any Python source files in this story

## Test Plan

```bash
# Verify pydantic installs correctly
cd sdk && pip install -e .
python -c "import pydantic; assert pydantic.VERSION.startswith('2.'), f'Expected 2.x, got {pydantic.VERSION}'"

# Verify existing tests still pass
cd sdk && pytest

# Verify no runtime import errors
python -c "from ralph_sdk.agent import RalphAgent; print('OK')"
python -c "from ralph_sdk.status import RalphStatus; print('OK')"
python -c "from ralph_sdk.config import RalphConfig; print('OK')"
```
