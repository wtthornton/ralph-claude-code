# Story RALPH-SDK-V2-7: Full CLI Regression Test

**Epic:** [Release, Integration Testing & v2.0.0](epic-sdk-v2-release.md)
**Priority:** Critical
**Status:** Done
**Effort:** Medium
**Component:** `tests/`, `sdk/tests/`

---

## Problem

v2.0.0 introduces significant SDK changes: async API, state backend, Pydantic models,
new modules, and new public API surface. These changes must not break any existing
functionality for standalone Ralph users. The bash loop, SDK CLI mode, dry-run mode,
and live mode must all work exactly as before.

A full regression test is the final gate before the v2.0.0 release. If any existing
test fails, the release is blocked.

## Solution

Run the complete test suite:

1. All 736+ existing BATS tests (bash loop, CLI parsing, hooks, integration).
2. All existing SDK pytest tests.
3. All new SDK tests from Epics 1-8.
4. Manual verification of key CLI modes.

## Implementation

### Step 1: Run all BATS tests

```bash
# From project root
npm test
```

Expected: All 736+ tests pass with 0 failures.

### Step 2: Run all SDK tests

```bash
# From sdk directory
cd sdk && pytest -v --tb=short
```

Expected: All tests pass, including new tests from Epics 1-8.

### Step 3: Verify CLI modes

```bash
# Verify ralph (bash loop) works
ralph --version  # Should output 2.0.0
ralph --help     # Should display help text

# Verify ralph --sdk works
ralph --sdk --dry-run  # Should complete without error

# Verify ralph --live works (quick check)
ralph --live --dry-run  # Should complete without error
```

### Step 4: Verify no import errors

```bash
# All SDK imports should work
python -c "from ralph_sdk import RalphAgent, TaskInput, TaskResult; print('OK')"
python -c "from ralph_sdk import RalphConfig, RalphStatus; print('OK')"
python -c "from ralph_sdk import TaskPacketInput, IntentSpecInput; print('OK')"
python -c "from ralph_sdk import EvidenceBundle; print('OK')"
python -c "from ralph_sdk import RalphStateBackend, FileStateBackend, NullStateBackend; print('OK')"
```

### Key Notes

- This story produces no code changes — it is purely a verification gate.
- If any test fails, the failure must be investigated and fixed before release.
- BATS tests cover the bash loop exhaustively — they are the primary safety net for standalone users.
- SDK tests cover the Python SDK — they verify the v2.0.0 changes work correctly.
- CLI mode checks verify end-to-end operation from the user's perspective.

## Acceptance Criteria

- [ ] All 736+ existing BATS tests pass (`npm test`)
- [ ] All existing SDK pytest tests pass (`cd sdk && pytest`)
- [ ] All new Epic 1-8 SDK tests pass
- [ ] `ralph --version` outputs `2.0.0`
- [ ] `ralph --help` displays help text without errors
- [ ] `ralph --sdk --dry-run` completes without error
- [ ] `ralph --live --dry-run` completes without error
- [ ] All SDK imports succeed without errors
- [ ] No regressions in any existing functionality
- [ ] Zero test failures across the entire suite

## Test Plan

```bash
# Full regression run (this IS the test plan)
echo "=== BATS Tests ==="
npm test 2>&1 | tail -5

echo "=== SDK Tests ==="
cd sdk && pytest -v --tb=short 2>&1 | tail -10

echo "=== CLI Verification ==="
ralph --version
ralph --sdk --dry-run && echo "SDK dry-run: OK" || echo "SDK dry-run: FAIL"

echo "=== Import Verification ==="
python -c "
from ralph_sdk import (
    RalphAgent, TaskInput, TaskResult, RalphConfig, RalphStatus,
    TaskPacketInput, IntentSpecInput, EvidenceBundle,
    RalphStateBackend, FileStateBackend, NullStateBackend,
)
print('All imports: OK')
"
```
