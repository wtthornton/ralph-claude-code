# Story RALPH-SDK-ASYNC-1: Add aiofiles Dependency

**Epic:** [Async SDK](epic-sdk-async.md)
**Priority:** Critical
**Status:** Pending
**Effort:** Trivial
**Component:** `sdk/pyproject.toml`

---

## Problem

The Ralph SDK needs async file I/O for TheStudio integration. The `aiofiles` library
provides drop-in async wrappers around Python's built-in `open()`, `read()`, and `write()`
functions. Without this dependency declared, subsequent stories (ASYNC-2 through ASYNC-8)
cannot use async file operations.

## Solution

Add `aiofiles>=24.0` to the `[project.dependencies]` section of `pyproject.toml`. This is
the only change -- no code modifications.

## Implementation

**File:** `sdk/pyproject.toml`

BEFORE:
```toml
[project.optional-dependencies]
dev = [
    "pytest>=8.0",
    "pytest-cov>=4.0",
]
```

AFTER:
```toml
dependencies = [
    "aiofiles>=24.0",
]

[project.optional-dependencies]
dev = [
    "pytest>=8.0",
    "pytest-cov>=4.0",
    "pytest-asyncio>=0.24",
]
```

Note: `pytest-asyncio` is added to dev dependencies to support async test functions in
subsequent stories.

## Acceptance Criteria

- [ ] `aiofiles>=24.0` listed in `[project.dependencies]` in `pyproject.toml`
- [ ] `pytest-asyncio>=0.24` listed in `[project.optional-dependencies].dev`
- [ ] `pip install -e ".[dev]"` succeeds and installs both packages
- [ ] `python -c "import aiofiles; print(aiofiles.__version__)"` succeeds
- [ ] `python -c "import pytest_asyncio"` succeeds
- [ ] No code changes outside `pyproject.toml`

## Test Plan

- **Install test**: Run `pip install -e ".[dev]"` in a fresh venv and confirm aiofiles and
  pytest-asyncio are both installed.
- **Import test**: `python -c "import aiofiles"` exits with code 0.
- **Version check**: `python -c "import aiofiles; assert tuple(int(x) for x in aiofiles.__version__.split('.')[:1]) >= (24,)"` passes.
- **Existing tests**: `pytest sdk/tests/` still passes (no regressions).
