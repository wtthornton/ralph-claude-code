# Epic: Concurrent Instance Prevention

**Epic ID:** RALPH-LOCK
**Priority:** Critical
**Status:** Done
**Affects:** API cost efficiency, data integrity, loop stability
**Components:** `ralph_loop.sh` (startup sequence)
**Related specs:** [epic-loop-stability.md](epic-loop-stability.md)
**Depends on:** None
**Target Version:** v1.9.0

---

## Problem Statement

Two Ralph instances can run simultaneously on the same project, causing cascading failures: racing for API calls, corrupting state files, triggering circuit breakers, and wasting API budget.

### Evidence (from tapps-brain logs, 2026-03-21)

- Two Ralph instances ran concurrently from 17:01 to 17:48 (~47 minutes)
- ~40 consecutive failures as instances fought over state files
- 100 API calls burned with zero productive work
- Circuit breaker eventually tripped at 18:08
- One instance crashed with exit code 130 (SIGINT)

### Root Cause

Ralph has no instance locking mechanism. Starting `ralph_loop.sh` while another instance is already running on the same project directory succeeds silently. Both instances:
1. Read the same `fix_plan.md` and `PROMPT.md`
2. Write to the same `status.json`, `.call_count`, `.circuit_breaker_state`
3. Compete for the same Claude Code session ID
4. Race to write `claude_output_*.log` files

## Research-Informed Adjustments

### The `flock` Command (2025 Best Practice)

The `flock` command provides **kernel-guaranteed atomic locking** with zero race conditions, recommended by the Linux `flock(1)` man page, Greg's Bash Wiki (BashFAQ/045), and Baeldung:

- **Kernel-managed lifecycle**: Lock automatically releases on process exit, crash, or SIGKILL — no stale lock cleanup needed
- **Atomic**: Uses the `flock(2)` system call — no TOCTOU race conditions
- **Self-locking script pattern**: `[ "${FLOCKER}" != "$0" ] && exec env FLOCKER="$0" flock -en "$0" "$0" "$@"` — the script re-execs itself under flock
- **File descriptor pattern**: `exec 99>"$LOCKFILE"; flock -n 99` — lock held for script lifetime
- **Cron standard**: Production cron jobs universally use `flock -n /tmp/job.lock /path/to/job.sh`

PID files are explicitly discouraged due to TOCTOU races and PID recycling risks.

Reference: [flock(1) man page](https://man7.org/linux/man-pages/man1/flock.1.html), [BashFAQ/045](https://mywiki.wooledge.org/BashFAQ/045), [Baeldung — Ensure Only One Instance](https://www.baeldung.com/linux/bash-ensure-instance-running)

### Concurrency Patterns from Production Tools

| Tool | Mechanism | Relevant Pattern |
|------|-----------|-----------------|
| GitHub Actions | `concurrency.group` | Per-project grouping with optional cancel-in-progress |
| Terraform | DynamoDB state lock | Lock includes operator, operation, timestamp, lock ID |
| Cron (production) | `flock -n` wrapper | Non-blocking lock, exit immediately if held |
| systemd | `PIDFile=` + cgroup | Process lifecycle managed by init system |

Reference: [GitHub Docs — Concurrency](https://docs.github.com/actions/writing-workflows/choosing-what-your-workflow-does/control-the-concurrency-of-workflows-and-jobs), [Terraform State Locking](https://stategraph.com/blog/terraform-state-locking-explained)

## Stories

| Story | Title | Priority | Effort | Status |
|-------|-------|----------|--------|--------|
| [LOCK-1](story-lock-1-flock-instance-locking.md) | Flock-Based Instance Locking | Critical | Small | Pending |

## Implementation Order

1. **LOCK-1** (Critical) — Single story epic. Prevents the entire class of concurrent-instance bugs.

## Acceptance Criteria (Epic-level)

- [ ] Only one Ralph instance can run per project directory at any time
- [ ] Second instance exits immediately with a clear error message (not silently)
- [ ] Lock releases automatically on exit, crash, SIGTERM, or SIGKILL
- [ ] No stale lock files can accumulate
- [ ] BATS tests verify locking behavior

## Out of Scope

- Distributed locking across multiple machines (Ralph is single-host)
- Graceful takeover (killing old instance when new one starts) — too risky for unattended operation
- Multi-project coordination (each project has independent locking)
