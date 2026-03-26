# Epic: Loop Progress Detection & Guard Rails

**Epic ID:** RALPH-GUARD
**Priority:** Critical
**Status:** Done
**Affects:** Loop reliability, API cost efficiency, unattended operation
**Components:** `ralph_loop.sh` (progress detection, timeout handling)
**Related specs:** [epic-loop-stability.md](epic-loop-stability.md), [epic-multi-task-cascading-failures.md](epic-multi-task-cascading-failures.md)
**Depends on:** None
**Target Version:** v1.9.0

---

## Problem Statement

Ralph's loop can waste unbounded hours (10+ hours observed) repeating 30-minute timeouts with no actual progress. Two root causes:

### Root Cause 1: Stale File-Change Detection

After a timeout, Ralph checks `git diff --name-only | wc -l` to determine if the iteration was "productive." If files changed, the timeout is treated as progress rather than failure. However, this check counts **all uncommitted files**, not just files changed during the current iteration. Pre-existing uncommitted changes (e.g., 733 files from prior work) satisfy the check every time, preventing the loop from ever recognizing stagnation.

### Root Cause 2: No Consecutive Timeout Limit

Ralph has no mechanism to detect repeated timeouts. Each timeout is evaluated independently. Even 19 consecutive timeouts (9.5 hours) don't trigger circuit breaker or halt — because each one passes the stale file-change check.

### Evidence (from TheStudio logs, 2026-03-22)

- 19 consecutive 30-minute timeouts from 02:10 to 11:45 (~10 hours)
- Every timeout logged: `Timeout but 733 file(s) changed — treating iteration as productive`
- The 733-file count was identical across all iterations (stale uncommitted changes)
- Zero meaningful progress during this entire period
- Estimated ~19 API invocations wasted at 30 minutes each

## Research-Informed Adjustments

### Git Diff Baseline Snapshotting (2025 Best Practices)

Production CI systems (GitHub Actions, GitLab CI) use **baseline comparison** rather than absolute counts:

- **`git write-tree`**: Captures staged state as a tree object without creating a commit — zero-cost snapshot
- **`git diff --name-only $BASELINE_HASH`**: Shows only changes since the baseline
- **`git diff --diff-filter=ACMRT`**: Filters to meaningful changes (Added/Copied/Modified/Renamed/Type-changed)
- **Pathspec exclusions**: `git diff -- . ':!*.lock' ':!*.log'` ignores noise files

Reference: [GitHub Blog — Commits are Snapshots, Not Diffs](https://github.blog/open-source/git/commits-are-snapshots-not-diffs/), [tj-actions/changed-files](https://github.com/tj-actions/changed-files)

### Consecutive Failure Detection

AWS Step Functions and Kubernetes both implement **consecutive failure limits**:

- **Kubernetes `progressDeadlineSeconds`**: If a rollout doesn't progress within N seconds, it's marked failed
- **AWS Step Functions `HeartbeatSeconds`**: Tasks must send heartbeats within this interval or are considered failed
- **Resilience4j `minimumNumberOfCalls`**: Circuit breaker won't evaluate until N calls have occurred

Reference: [AWS Builders Library — Timeouts, retries, and backoff with jitter](https://aws.amazon.com/builders-library/timeouts-retries-and-backoff-with-jitter/)

## Stories

| Story | Title | Priority | Effort | Status |
|-------|-------|----------|--------|--------|
| [GUARD-1](story-guard-1-baseline-snapshotting.md) | Git Diff Baseline Snapshotting | Critical | Small | Pending |
| [GUARD-2](story-guard-2-consecutive-timeout-breaker.md) | Consecutive Timeout Circuit Breaker | Critical | Small | Pending |

## Implementation Order

1. **GUARD-1** (Critical) — Fixes the root cause: stale file counts masking stagnation.
2. **GUARD-2** (Critical) — Adds the safety net: halt after N consecutive timeouts regardless of file counts.

## Acceptance Criteria (Epic-level)

- [ ] Ralph detects when a timed-out iteration produced no new file changes (vs. pre-existing uncommitted files)
- [ ] After N consecutive timeouts with no progress, Ralph opens the circuit breaker or halts
- [ ] A 10-hour timeout loop like the 2026-03-22 TheStudio incident cannot recur
- [ ] All fixes have BATS tests
- [ ] `--dry-run` mode exercises the new progress detection logic

## Out of Scope

- Adaptive timeout duration (covered in RALPH-ADAPTIVE)
- Stream extraction recovery after SIGTERM (covered in RALPH-CAPTURE)
- Circuit breaker failure decay (covered in RALPH-CBDECAY)
