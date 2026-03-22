# Epic: WSL Reliability Polish

**Epic ID:** RALPH-WSL
**Priority:** Low
**Affects:** Temp file cleanup, git status noise, trap handler robustness
**Components:** `templates/hooks/on-stop.sh`, `ralph_loop.sh` (cleanup function)
**Source:** [ralph-feedback-report.md](../../../../tapps-brain/ralph-feedback-report.md) (2026-03-21, Issues #3, #4)

---

## Problem Statement

Ralph runs reliably on WSL/NTFS, but two low-severity issues create operational friction:

1. **Orphaned temp files:** Atomic writes use `mktemp` + `mv`, but on WSL's cross-filesystem
   NTFS mount (`/mnt/c/`), `mv` may perform copy+unlink rather than rename. If the unlink
   fails (file locking, cross-fs), the temp file persists. 9 orphaned `status.json.*` files
   were observed, 5 showing as untracked in `git status`.

2. **SIGINT child process noise:** When Ralph receives SIGINT (Ctrl+C, WSL session termination),
   the `cleanup()` trap handler runs but doesn't explicitly kill pipeline children (jq, tee,
   awk stream filter). They receive their own SIGINT and log their own exit code 130 errors,
   making the crash log noisy.

### Impact

Both issues are cosmetic/friction — no data loss, no incorrect behavior. But they add noise
for developers monitoring Ralph.

## Stories

| # | ID | Story | Priority | Effort | Status |
|---|-----|-------|----------|--------|--------|
| 1 | WSL-1 | Add Temp File Cleanup After Atomic Writes | Low | Trivial | **Done** |
| 2 | WSL-2 | Add Child Process Cleanup to Trap Handler | Low | Small | **Done** |

## Acceptance Criteria (Epic Level)

- [ ] No orphaned `status.json.*` files accumulate across loops
- [ ] SIGINT crash logs show one clean exit, not multiple child process errors
