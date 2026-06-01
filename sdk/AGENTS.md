# Ralph SDK — agent guidance

The SDK is a Python 3.12+ package that provides the async agent loop, state backend, and supporting modules used by both the Ralph CLI and embedding hosts.

For the canonical TappsMCP / agent contract, see [`../AGENTS.md`](../AGENTS.md). This file is a thin pointer so per-file scoring tools detect the surface here.

## Quick reference

- **Entry point:** `python -m ralph_sdk` (see `__main__.py`)
- **Public surface:** `ralph_sdk.agent.RalphAgent`, `ralph_sdk.config.RalphConfig`, `ralph_sdk.state.RalphStateBackend`
- **Pluggable interfaces:** state backend (`state.py`), metrics collector (`metrics.py`), memory backend (`memory.py`), import graph cache (`import_graph.py`)
- **Tests:** `tests/` (pytest + pytest-asyncio). Run via `uv run --frozen pytest`.

## Quality scoring prerequisites (TAP-2775)

`tapps_score_file` / `tapps_quick_check` resolve `ruff` and `mypy` as **bare
subprocesses via `PATH`** — unlike `tapps_session_start`, the scorer does *not*
fall back to the tapps-mcp tool-env `bin/`. If the binaries are only inside the
SDK's `.venv`, the scorer reports `ruff: not_found` / `mypy: not_found`, runs
`degraded`, and silently skips lint + type findings (the quality gate then
reflects complexity/maintainability only — a false-confidence blind spot).

Install both on `PATH` (the same place tapps-mcp itself lives):

```bash
uv tool install ruff    # -> ~/.local/bin/ruff   (match tapps: ruff 0.15.15)
uv tool install mypy    # -> ~/.local/bin/mypy   (match tapps: mypy 2.1.0)
```

Verify with `tapps_score_file` on any SDK module — `tool_errors` must not
contain `ruff` or `mypy`. (`perflint` is an optional `tapps-mcp[perf]` extra and
is out of scope here.)

## Conventions

- All models are Pydantic v2 `BaseModel`s.
- The agent loop is fully async; `run_sync()` wraps it for CLI use.
- State I/O goes through `RalphStateBackend` (file or null).
- New helpers added during refactors land in module-private functions (`_name`); public API stays additive.

See [`../CLAUDE.md`](../CLAUDE.md) for project-wide patterns and the loop-design invariants this SDK mirrors.
