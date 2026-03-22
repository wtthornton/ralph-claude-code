# Story RALPH-WSL-2: Add Child Process Cleanup to Trap Handler

**Epic:** [WSL Reliability Polish](epic-wsl-reliability-polish.md)
**Priority:** Low
**Status:** Done
**Effort:** Small
**Component:** `ralph_loop.sh` (`cleanup` function)

---

## Problem

When Ralph receives SIGINT (Ctrl+C, WSL session termination), the `cleanup()` trap handler
runs but doesn't explicitly terminate pipeline children. The tee, awk stream filter, and any
jq processes receive their own SIGINT independently and log their own exit code 130 errors:

```
[WARN] Failed to write stream output to log file (exit code 130)
[WARN] jq filter had issues parsing some stream events (exit code 130)
```

These are not real errors — they're expected consequences of the parent being killed. But they
make the crash log noisy and harder to diagnose actual issues.

## Solution

### Change 1: Track pipeline PIDs

After launching the Claude execution pipeline, capture the background PIDs:

```bash
# Store pipeline PID for cleanup
RALPH_PIPELINE_PID=$!
```

### Change 2: Kill children in cleanup()

In the `cleanup()` function, kill the pipeline process group before logging:

```bash
cleanup() {
    local trap_exit_code=$?
    if [[ "$_CLEANUP_DONE" == "true" ]]; then return; fi
    _CLEANUP_DONE=true

    # Kill pipeline children to prevent spurious error logs
    if [[ -n "${RALPH_PIPELINE_PID:-}" ]]; then
        kill -- -"$RALPH_PIPELINE_PID" 2>/dev/null || true
        wait "$RALPH_PIPELINE_PID" 2>/dev/null || true
    fi

    # ... existing cleanup logic ...
}
```

### Change 3: Suppress expected 130 warnings on SIGINT

When the exit code is 130 (SIGINT), suppress pipeline warnings:

```bash
if [[ $trap_exit_code -eq 130 ]]; then
    # SIGINT — pipeline warnings are expected, don't log them
    return
fi
```

## Acceptance Criteria

- [ ] SIGINT crash produces one clean log entry, not multiple child process warnings
- [ ] Normal loop completion is unaffected
- [ ] Pipeline processes are terminated before cleanup logging
