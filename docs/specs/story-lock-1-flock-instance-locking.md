# Story LOCK-1: Flock-Based Instance Locking

**Epic:** [Concurrent Instance Prevention](epic-concurrent-instance-prevention.md)
**Priority:** Critical
**Status:** Pending
**Effort:** Small
**Component:** `ralph_loop.sh`

---

## Problem

Starting `ralph_loop.sh` while another instance is running on the same project causes both instances to fight over shared state files (`status.json`, `.call_count`, `.circuit_breaker_state`), resulting in ~40 consecutive failures and 100 wasted API calls in a single incident.

**Root cause confirmed by:** tapps-brain logs 2026-03-21, 17:01–17:48.

## Solution

Use the `flock` command (kernel-guaranteed atomic locking) to ensure only one Ralph instance runs per project directory. Two implementation options:

### Option A: Self-locking script (flock man page recommended pattern)

```bash
# At the very top of ralph_loop.sh, before any other code:
LOCKFILE="${RALPH_DIR:-.ralph}/.ralph.lock"
[ "${FLOCKER}" != "$0" ] && exec env FLOCKER="$0" flock -en "$LOCKFILE" "$0" "$@" || :
```

### Option B: File descriptor pattern (more control over error messaging)

```bash
# After RALPH_DIR is determined, before main loop:
LOCKFILE="${RALPH_DIR}/.ralph.lock"

acquire_instance_lock() {
    exec 99>"$LOCKFILE"
    if ! flock -n 99; then
        local other_pid
        other_pid=$(cat "$LOCKFILE" 2>/dev/null || echo "unknown")
        log "ERROR" "Another Ralph instance is already running on this project (PID: $other_pid)"
        log "ERROR" "Lock file: $LOCKFILE"
        log "ERROR" "If the previous instance crashed, the lock will auto-release."
        log "ERROR" "To verify: ps -p $other_pid or check if process exists"
        exit 1
    fi
    # Write our PID for informational purposes (not used for locking — flock handles that)
    echo $$ > "$LOCKFILE"
    log "INFO" "Acquired instance lock (PID: $$)"
}
```

## Implementation

### Step 1: Add lock acquisition at startup

Place after `RALPH_DIR` is resolved but before the main loop:

```bash
# --- Instance Locking ---
LOCKFILE="${RALPH_DIR}/.ralph.lock"

acquire_instance_lock() {
    # Open file descriptor 99 for the lock file
    exec 99>"$LOCKFILE"

    if ! flock -n 99; then
        local existing_pid
        existing_pid=$(cat "$LOCKFILE" 2>/dev/null | head -1)
        echo "[ERROR] Another Ralph instance is already running (PID: ${existing_pid:-unknown})" >&2
        echo "[ERROR] Project: $(pwd)" >&2
        echo "[ERROR] Lock: $LOCKFILE" >&2
        echo "" >&2
        echo "If the process is gone, the lock auto-releases. Otherwise:" >&2
        echo "  kill $existing_pid    # Stop the other instance" >&2
        echo "  ralph --status        # Check current state" >&2
        exit 1
    fi

    # Write PID for informational display only (flock manages actual locking)
    echo $$ > "$LOCKFILE"
}

acquire_instance_lock
```

### Step 2: Handle flock availability (WSL/macOS compatibility)

```bash
acquire_instance_lock() {
    if ! command -v flock &>/dev/null; then
        # Fallback for systems without flock (macOS without util-linux)
        log "WARN" "flock not available — instance locking disabled"
        log "WARN" "Install util-linux for concurrent instance prevention"
        return 0
    fi

    exec 99>"$LOCKFILE"
    if ! flock -n 99; then
        # ... error messaging ...
        exit 1
    fi
    echo $$ > "$LOCKFILE"
    log "INFO" "Acquired instance lock (PID: $$)"
}
```

### Step 3: Add .ralph.lock to .gitignore

```bash
# In setup.sh / create_files.sh, add to .ralph/.gitignore:
echo ".ralph.lock" >> "$RALPH_DIR/.gitignore"
```

### Step 4: Integrate with --status flag

```bash
# In the --status handler:
if [[ -f "$LOCKFILE" ]]; then
    local lock_pid
    lock_pid=$(cat "$LOCKFILE" 2>/dev/null | head -1)
    if kill -0 "$lock_pid" 2>/dev/null; then
        echo "Instance: RUNNING (PID: $lock_pid)"
    else
        echo "Instance: NOT RUNNING (stale lock — will auto-release)"
    fi
else
    echo "Instance: NOT RUNNING"
fi
```

## Design Notes

- **Why `flock` over PID files**: `flock` uses `flock(2)` kernel syscall — atomic, no TOCTOU race. PID files require read-check-write which has a race window between checking and creating. Additionally, PID recycling on Linux can cause false "process exists" results.
- **Why FD 99**: High-numbered file descriptors avoid conflicts with subprocesses. Convention from BashFAQ/045.
- **Auto-release guarantee**: `flock` releases when the file descriptor closes, which happens on: normal exit, `exit` call, SIGTERM, SIGKILL, crash, or any abnormal termination. No cleanup code needed.
- **Informational PID**: Writing `$$` to the lock file is optional — it's only for human-readable error messages. The actual locking is handled entirely by `flock`.
- **Lock file location**: Inside `.ralph/` directory (project-scoped). Each project has independent locking.
- **WSL compatibility**: `flock` is available in WSL (it ships with util-linux). On native macOS, it requires `brew install util-linux`. The fallback gracefully degrades with a warning.
- **No cleanup trap needed**: Unlike PID files, `flock` locks don't need `trap 'rm -f "$LOCKFILE"' EXIT`. The kernel releases the lock automatically. The file itself can persist (it's just an empty file used as a lock target).

## Acceptance Criteria

- [ ] Second Ralph instance on same project directory exits immediately with error
- [ ] Error message shows PID of running instance and remediation steps
- [ ] Lock releases automatically on normal exit, SIGTERM, SIGKILL, and crash
- [ ] No stale lock files block future runs after a crash
- [ ] Graceful fallback when `flock` is not available (warning, not crash)
- [ ] `ralph --status` shows whether an instance is running
- [ ] Lock file is in `.gitignore`

## Test Plan

```bash
@test "acquire_instance_lock succeeds on first invocation" {
    source "$RALPH_DIR/ralph_loop.sh"
    LOCKFILE="$TEST_DIR/.ralph.lock"

    run acquire_instance_lock
    assert_success
    assert [ -f "$LOCKFILE" ]
}

@test "acquire_instance_lock fails when lock already held" {
    LOCKFILE="$TEST_DIR/.ralph.lock"

    # Hold lock in background
    exec 99>"$LOCKFILE"
    flock -n 99

    # Attempt to acquire in subprocess
    run bash -c "
        source '$RALPH_DIR/ralph_loop.sh'
        LOCKFILE='$LOCKFILE'
        acquire_instance_lock
    "
    assert_failure
    assert_output --partial "Another Ralph instance is already running"

    # Release lock
    exec 99>&-
}

@test "lock auto-releases when process exits" {
    LOCKFILE="$TEST_DIR/.ralph.lock"

    # Acquire and immediately exit in subprocess
    bash -c "exec 99>'$LOCKFILE'; flock -n 99; echo \$\$ > '$LOCKFILE'"

    # Lock should now be available
    exec 99>"$LOCKFILE"
    run flock -n 99
    assert_success
    exec 99>&-
}

@test "fallback when flock not available" {
    source "$RALPH_DIR/ralph_loop.sh"
    LOCKFILE="$TEST_DIR/.ralph.lock"

    # Override command check
    command() { return 1; }

    run acquire_instance_lock
    assert_success
    assert_output --partial "flock not available"
}
```

## References

- [flock(1) man page](https://man7.org/linux/man-pages/man1/flock.1.html)
- [BashFAQ/045 — Avoiding Race Conditions](https://mywiki.wooledge.org/BashFAQ/045)
- [Baeldung — Ensure Only One Instance of a Script Running](https://www.baeldung.com/linux/bash-ensure-instance-running)
- [Locking Critical Sections in Shell Scripts](https://stegard.net/2022/05/locking-critical-sections-in-shell-scripts/)
- [GitHub Actions Concurrency Groups](https://docs.github.com/actions/writing-workflows/choosing-what-your-workflow-does/control-the-concurrency-of-workflows-and-jobs)
- [Terraform State Locking](https://stategraph.com/blog/terraform-state-locking-explained)
