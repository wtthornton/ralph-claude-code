# Story RALPH-LOOP-5: Add Loop Crash Diagnostics and Recovery

**Epic:** [Loop Stability & Analysis Resilience](epic-loop-stability.md)
**Priority:** Medium
**Status:** Done
**Effort:** Small
**Component:** `ralph_loop.sh` (trap handling, status tracking)

---

## Problem

When the ralph loop crashes during `execute_claude_code`, there is zero diagnostic
information:

1. **No crash log:** The cleanup function (line 1826) only handles SIGINT/SIGTERM,
   not EXIT. If the bash process dies from OOM, SIGPIPE, or an unhandled error,
   no cleanup runs.

2. **No status update:** `status.json` stays frozen at `"executing"/"running"` from
   BEFORE Claude executed. There's no way to distinguish "still running" from "crashed."

3. **No crash counter:** When the script is restarted (manually or by a wrapper),
   there's no record that the previous invocation crashed. The same crash repeats
   indefinitely.

4. **Loop count resets:** `loop_count` is a bash variable that resets to 0 on every
   script invocation. Combined with exit signal clearing in `main()`, the loop
   always starts fresh with no memory of previous runs.

## Solution

Add an EXIT trap, crash detection on startup, and a persistent loop counter.

## Implementation

### Change 1: Add EXIT trap

```bash
# Replace line 1844:
# BEFORE:
trap cleanup SIGINT SIGTERM

# AFTER:
trap cleanup SIGINT SIGTERM EXIT
```

Update the cleanup function to handle the EXIT case:

```bash
cleanup() {
    local trap_exit_code=$?

    if [[ "$_CLEANUP_DONE" == "true" ]]; then return; fi
    _CLEANUP_DONE=true

    if [[ $loop_count -gt 0 ]]; then
        if [[ $trap_exit_code -ne 0 ]]; then
            log_status "ERROR" "Ralph loop crashed (exit code: $trap_exit_code)"
            update_status "$loop_count" "$(cat "$CALL_COUNT_FILE" 2>/dev/null || echo "0")" "crashed" "error" "exit_code_$trap_exit_code"
            # Record crash for startup detection
            echo "$trap_exit_code" > "$RALPH_DIR/.last_crash_code"
        else
            # Normal exit (code 0) — check if status was properly updated
            local current_status
            current_status=$(jq -r '.status' "$STATUS_FILE" 2>/dev/null || echo "unknown")
            if [[ "$current_status" == "running" ]]; then
                log_status "WARN" "Ralph exited normally but status still 'running' — possible silent crash"
                update_status "$loop_count" "$(cat "$CALL_COUNT_FILE" 2>/dev/null || echo "0")" "unexpected_exit" "stopped"
            fi
        fi
    fi
}
```

### Change 2: Crash detection on startup

In `main()`, after loading .ralphrc and before the main loop, check for crash artifacts:

```bash
# Detect previous crash
if [[ -f "$RALPH_DIR/.last_crash_code" ]]; then
    local last_crash_code
    last_crash_code=$(cat "$RALPH_DIR/.last_crash_code" 2>/dev/null || echo "unknown")
    log_status "WARN" "Previous Ralph invocation crashed (exit code: $last_crash_code)"
    rm -f "$RALPH_DIR/.last_crash_code"
fi

# Detect stale "running" status from a crashed run
if [[ -f "$STATUS_FILE" ]]; then
    local stale_status
    stale_status=$(jq -r '.status' "$STATUS_FILE" 2>/dev/null || echo "unknown")
    if [[ "$stale_status" == "running" ]]; then
        log_status "WARN" "Previous run left status as 'running' — likely crashed during execution"
    fi
fi
```

### Change 3: Persistent loop counter

Track total loops across restarts using a file counter:

```bash
# In main(), before the while loop:
local persistent_loop_file="$RALPH_DIR/.total_loop_count"
local persistent_loops=0
if [[ -f "$persistent_loop_file" ]]; then
    persistent_loops=$(cat "$persistent_loop_file" 2>/dev/null || echo "0")
    persistent_loops=$((persistent_loops + 0))
fi

# Inside the while loop, after incrementing loop_count:
persistent_loops=$((persistent_loops + 1))
echo "$persistent_loops" > "$persistent_loop_file"
log_status "LOOP" "=== Starting Loop #$loop_count (total: #$persistent_loops) ==="
```

## Design Notes

- **EXIT trap vs SIGINT/SIGTERM only:** The EXIT trap fires on ANY exit — normal return,
  `exit`, signal, or crash. This is strictly more capable than SIGINT/SIGTERM only.
  The cleanup function already has a reentrancy guard (`_CLEANUP_DONE`) to handle
  the case where EXIT fires after a signal handler already ran cleanup.
- **`.last_crash_code` file:** Simple crash breadcrumb that survives process death.
  Deleted on next startup after logging. Prevents accumulation.
- **Persistent loop counter:** Distinguishes "Loop #1 (total: #47)" (47th attempt,
  suggesting repeated crashes) from "Loop #1 (total: #1)" (fresh start). This makes
  the repeated-crash pattern immediately visible in logs.

## Acceptance Criteria

- [ ] EXIT trap fires on normal exit, crash, and signal
- [ ] Crash exit code recorded in `.last_crash_code`
- [ ] Next startup detects and logs previous crash
- [ ] Stale "running" status from crashed run detected on startup
- [ ] Persistent loop counter shows total loops across restarts
- [ ] Log format: "Starting Loop #N (total: #M)" where M >= N
- [ ] Existing BATS tests still pass

## Test Plan

```bash
@test "cleanup updates status on crash exit" {
    loop_count=1
    trap_exit_code=137  # SIGKILL

    # Simulate crash cleanup
    _CLEANUP_DONE=false
    cleanup

    # Verify status updated
    run jq -r '.status' "$STATUS_FILE"
    assert_output "error"

    # Verify crash code recorded
    assert_file_exists "$RALPH_DIR/.last_crash_code"
    run cat "$RALPH_DIR/.last_crash_code"
    assert_output "137"
}

@test "startup detects previous crash" {
    echo "137" > "$RALPH_DIR/.last_crash_code"

    # Run startup detection logic
    # Should log warning and remove the file
    # ... (implementation-specific test)
}

@test "persistent loop counter increments across restarts" {
    echo "5" > "$RALPH_DIR/.total_loop_count"

    # Simulate loop start
    local persistent_loops=$(cat "$RALPH_DIR/.total_loop_count")
    persistent_loops=$((persistent_loops + 1))
    echo "$persistent_loops" > "$RALPH_DIR/.total_loop_count"

    run cat "$RALPH_DIR/.total_loop_count"
    assert_output "6"
}
```
