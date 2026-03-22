# Story RALPH-WSL-1: Add Temp File Cleanup After Atomic Writes

**Epic:** [WSL Reliability Polish](epic-wsl-reliability-polish.md)
**Priority:** Low
**Status:** Done
**Effort:** Trivial
**Component:** `templates/hooks/on-stop.sh`

---

## Problem

The `on-stop.sh` hook uses atomic writes (mktemp + mv) for `status.json` and
`.circuit_breaker_state`. On POSIX, `mv` removes the source file. On WSL's NTFS mount,
`mv` may copy+unlink, and the unlink can fail due to cross-filesystem behavior or file
locking.

9 orphaned `status.json.XXXXXX` files were observed in `.ralph/`, with 5 appearing as
untracked in `git status`.

## Solution

### Change 1: Add explicit cleanup after each `mv`

After every `mv "$local_tmp" "$target"`, add:

```bash
rm -f "$local_tmp" 2>/dev/null
```

This is a no-op on POSIX (file already gone from rename) but catches WSL copy+unlink failures.

Apply to all three atomic write sites in `on-stop.sh`:
- Line 80: `mv "$local_tmp" "$RALPH_DIR/status.json"`
- Line 89: `mv "$local_tmp" "$RALPH_DIR/.circuit_breaker_state"` (progress path)
- Line ~98: `mv "$local_tmp" "$RALPH_DIR/.circuit_breaker_state"` (no-progress path)

### Change 2: Add `.gitignore` pattern

Add to the project's `.ralph/.gitignore` (or template):

```
status.json.*
.circuit_breaker_state.*
```

### Change 3: Stale temp cleanup on loop startup

In `ralph_loop.sh`, add to the initialization section:

```bash
# Clean stale temp files from previous runs (WSL cross-fs orphans)
find "$RALPH_DIR" -name "status.json.*" -mmin +60 -delete 2>/dev/null
find "$RALPH_DIR" -name ".circuit_breaker_state.*" -mmin +60 -delete 2>/dev/null
```

## Acceptance Criteria

- [ ] No `status.json.*` orphans accumulate across 10+ loop iterations
- [ ] `git status` shows no untracked temp files in `.ralph/`
- [ ] Stale temp files older than 1 hour are cleaned on startup
