# Story RALPH-SDK-ASYNC-9: Verify CLI Mode End-to-End

**Epic:** [Async SDK](epic-sdk-async.md)
**Priority:** Critical
**Status:** Done
**Effort:** Small
**Component:** `sdk/ralph_sdk/__main__.py`, `sdk/ralph_sdk/agent.py`

---

## Problem

After converting the entire SDK to async (ASYNC-1 through ASYNC-8), the CLI entry points
must still work for users who run `ralph --sdk` or `python -m ralph_sdk` from the command
line. These users interact with a synchronous shell -- they do not have an event loop
running. If any async conversion broke the sync bridge, the CLI will fail silently or with
confusing coroutine warnings.

This story is a verification/integration gate -- no new code is written, but specific
end-to-end scenarios are tested to confirm the full async stack works through the
`run_sync()` bridge.

## Solution

Run a comprehensive set of CLI invocations covering:
1. `python -m ralph_sdk --version` -- basic import and CLI parsing
2. `python -m ralph_sdk --dry-run` -- full loop execution through `run_sync()`
3. `python -m ralph_sdk --status` -- status reading (sync path, no loop)
4. `python -m ralph_sdk --reset-circuit` -- circuit breaker reset (sync path)
5. `ralph --sdk --dry-run` (if installed) -- the bash wrapper path

Verify no `RuntimeWarning`, no `TypeError` about unawaited coroutines, and correct output
in all cases.

## Implementation

No code changes expected. This story validates the work from ASYNC-1 through ASYNC-8.

If issues are found, fix them in the relevant component:
- Import errors: fix in `pyproject.toml` (ASYNC-1)
- Coroutine warnings: fix in `__main__.py` or `run_sync()` (ASYNC-7)
- File I/O errors: fix in `status.py` or `tools.py` (ASYNC-2, ASYNC-8)
- Subprocess errors: fix in `agent.py` (ASYNC-4)

### Expected command outputs

**`python -m ralph_sdk --version`**:
```
ralph-sdk 1.3.0
```

**`python -m ralph_sdk --dry-run --project-dir /tmp/ralph_test`** (with .ralph/ set up):
```
HH:MM:SS [INFO] ralph.sdk: Ralph SDK starting (v...)
HH:MM:SS [INFO] ralph.sdk: Project: ... (...)
HH:MM:SS [INFO] ralph.sdk: Loop iteration 1
HH:MM:SS [INFO] ralph.sdk: Dry run mode — skipping API call
```
Exit code: 0

**`python -m ralph_sdk --status --project-dir /tmp/ralph_test`**:
```json
{
  "WORK_TYPE": "DRY_RUN",
  "status": "DRY_RUN",
  ...
}
```

**`python -m ralph_sdk --reset-circuit --project-dir /tmp/ralph_test`**:
```
Circuit breaker reset to CLOSED
```

## Acceptance Criteria

- [ ] `python -m ralph_sdk --version` prints version and exits 0
- [ ] `python -m ralph_sdk --dry-run` completes a dry-run loop and exits 0
- [ ] `python -m ralph_sdk --status` prints status JSON and exits 0
- [ ] `python -m ralph_sdk --reset-circuit` resets circuit breaker and exits 0
- [ ] No `RuntimeWarning: coroutine ... was never awaited` in any invocation
- [ ] No `TypeError` related to awaiting non-coroutines
- [ ] No `ImportError` for aiofiles or asyncio
- [ ] `run_sync()` correctly bridges async `run()` to synchronous CLI
- [ ] Dry-run writes `status.json` with `status: "DRY_RUN"` (verifiable via `--status`)
- [ ] All existing SDK tests pass (`pytest sdk/tests/`)

## Test Plan

### Manual CLI verification

```bash
# Setup test project
mkdir -p /tmp/ralph_test/.ralph
echo "Test prompt" > /tmp/ralph_test/.ralph/PROMPT.md

# Test 1: Version
python -m ralph_sdk --version
# Expected: ralph-sdk X.Y.Z, exit code 0

# Test 2: Dry run
python -m ralph_sdk --dry-run --project-dir /tmp/ralph_test -v 2>&1
# Expected: Logs showing loop iteration 1, dry run mode, exit code 0
# Verify: No "coroutine" warnings in output

# Test 3: Status after dry run
python -m ralph_sdk --status --project-dir /tmp/ralph_test
# Expected: JSON with "status": "DRY_RUN"

# Test 4: Reset circuit
python -m ralph_sdk --reset-circuit --project-dir /tmp/ralph_test
# Expected: "Circuit breaker reset to CLOSED"

# Cleanup
rm -rf /tmp/ralph_test
```

### Automated test (pytest)

```python
import subprocess
import sys

def test_cli_version():
    result = subprocess.run(
        [sys.executable, "-m", "ralph_sdk", "--version"],
        capture_output=True, text=True
    )
    assert result.returncode == 0
    assert "ralph-sdk" in result.stdout

def test_cli_dry_run(tmp_path):
    ralph_dir = tmp_path / ".ralph"
    ralph_dir.mkdir()
    (ralph_dir / "PROMPT.md").write_text("Test prompt")
    result = subprocess.run(
        [sys.executable, "-m", "ralph_sdk", "--dry-run",
         "--project-dir", str(tmp_path)],
        capture_output=True, text=True
    )
    assert result.returncode == 0
    assert "coroutine" not in result.stderr.lower()

def test_cli_status_after_dry_run(tmp_path):
    ralph_dir = tmp_path / ".ralph"
    ralph_dir.mkdir()
    (ralph_dir / "PROMPT.md").write_text("Test prompt")
    # Run dry-run first
    subprocess.run(
        [sys.executable, "-m", "ralph_sdk", "--dry-run",
         "--project-dir", str(tmp_path)],
        capture_output=True, text=True
    )
    # Then check status
    result = subprocess.run(
        [sys.executable, "-m", "ralph_sdk", "--status",
         "--project-dir", str(tmp_path)],
        capture_output=True, text=True
    )
    assert result.returncode == 0
    assert '"DRY_RUN"' in result.stdout

def test_cli_reset_circuit(tmp_path):
    ralph_dir = tmp_path / ".ralph"
    ralph_dir.mkdir()
    result = subprocess.run(
        [sys.executable, "-m", "ralph_sdk", "--reset-circuit",
         "--project-dir", str(tmp_path)],
        capture_output=True, text=True
    )
    assert result.returncode == 0
    assert "Circuit breaker reset" in result.stdout
```

### Regression check

Run the full existing test suite to confirm no regressions:
```bash
cd sdk && pytest tests/ -v
```
