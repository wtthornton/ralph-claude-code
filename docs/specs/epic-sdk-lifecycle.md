# Epic: SDK Lifecycle & Resilience — Cancel Semantics, Adaptive Timeout, and Permission Detection

**Epic ID:** RALPH-SDK-LIFECYCLE
**Priority:** P1–P3
**Affects:** Graceful shutdown, timeout efficiency, permission awareness
**Components:** `ralph_sdk/agent.py`, `ralph_sdk/config.py`, `ralph_sdk/parsing.py`
**Related specs:** [epic-adaptive-timeout.md](epic-adaptive-timeout.md)
**Depends on:** RALPH-SDK-SAFETY (stall detection provides the safety net for adaptive timeouts)
**Target Version:** SDK v2.2.0
**Source:** [ralph-sdk-upgrade-evaluation.md](../../../TheStudio/docs/ralph-sdk-upgrade-evaluation.md) §2.2, §1.11, §1.12

---

## Problem Statement

Three lifecycle-related gaps between the CLI and SDK affect shutdown reliability, timeout efficiency, and failure detection:

1. **Undocumented cancel semantics**: TheStudio's Temporal activity calls `agent.cancel()` on timeout (`activities.py:954`), then waits 10s, then force-cancels the asyncio task. It's unclear whether `cancel()` actually sends SIGTERM to the Claude subprocess or just sets a flag. Undocumented behavior in the shutdown path is a production risk.

2. **Static timeout**: The CLI's `ADAPTIVE_TIMEOUT_ENABLED` adjusts timeout dynamically based on historical iteration durations (requires `ADAPTIVE_TIMEOUT_MIN_SAMPLES=5`). The SDK uses a static `timeout_minutes`. A 30-minute timeout is too long for trivial tasks (waste) and too short for architectural changes (premature kill).

3. **No permission denial detection**: The CLI distinguishes between bash command denials (fixable via `ALLOWED_TOOLS`) and built-in tool denials (filesystem scope). When Claude loses access to tools mid-run (sandboxed mode, permission revocation), the SDK doesn't detect this and continues looping uselessly.

### Evidence

- TheStudio `activities.py:954`: `agent.cancel()` called with unknown behavior
- CLI `ADAPTIVE_TIMEOUT_ENABLED`: Dynamic timeout based on P95 latency × multiplier
- CLI permission denial patterns: Distinguishes user-fixable vs scope-locked denials
- 19 consecutive timeouts in TheStudio at exactly 30 minutes (static timeout)

## Research Context (March 2026)

**Graceful shutdown patterns**:
- Temporal activity cancellation sends `CancelledError` to the running coroutine. The activity should catch this, send SIGTERM to subprocesses, wait for a grace period, then SIGKILL if needed.
- Python `asyncio.create_subprocess_exec()` supports `process.terminate()` (SIGTERM) and `process.kill()` (SIGKILL). The SDK should use `terminate()` first, then `kill()` after a grace period.
- Best practice: return partial results on cancellation rather than raising. The caller can decide whether to use partial output.

**Adaptive timeout patterns**:
- AWS Builders Library: "Set timeouts based on measured latency distributions, not estimates."
- P95-based adaptive timeout with 2x safety multiplier is the industry standard.
- Kubernetes `progressDeadlineSeconds` evaluates forward progress, not just elapsed time.
- For AI agents specifically, research shows agent success rate decreases after ~35 minutes — beyond this threshold, task decomposition is more effective than longer timeouts.

**Permission denial detection**:
- Claude Code outputs structured permission denial messages that can be parsed.
- Two categories: user-fixable (add to `ALLOWED_TOOLS`) and scope-locked (filesystem boundaries).
- Detection enables intelligent retry: adjust tool permissions and retry vs. circuit break.

## Stories

| Story | Title | Priority | Effort | Status |
|-------|-------|----------|--------|--------|
| [SDK-LIFECYCLE-1](story-sdk-lifecycle-1-cancel-semantics.md) | Cancel Semantics Documentation and Hardening | P1 | 0.5 day | Pending |
| [SDK-LIFECYCLE-2](story-sdk-lifecycle-2-adaptive-timeout.md) | Adaptive Timeout | P3 | 1 day | Pending |
| [SDK-LIFECYCLE-3](story-sdk-lifecycle-3-permission-denial.md) | Permission Denial Detection | P3 | 1 day | Pending |

## Implementation Order

1. **SDK-LIFECYCLE-1** (P1) — Cancel semantics. Small scope, high production impact.
2. **SDK-LIFECYCLE-2** (P3) — Adaptive timeout. Depends on metrics collection (SDK-OUTPUT-4) for latency data.
3. **SDK-LIFECYCLE-3** (P3) — Permission denial detection. Enhances parsing module.

## Acceptance Criteria (Epic-level)

- [ ] `RalphAgent.cancel()` sends SIGTERM to Claude subprocess
- [ ] `cancel()` returns `CancelResult` with partial output collected so far
- [ ] `cancel()` completes within a configurable grace period (default 10s)
- [ ] Cancel behavior is documented in docstrings and README
- [ ] Timeout adapts based on historical iteration durations (P95 × multiplier)
- [ ] Minimum sample count required before adaptive mode activates
- [ ] Timeout clamped to configurable min/max range
- [ ] Permission denials are detected and exposed as `PermissionDenialEvent` on status
- [ ] User-fixable denials distinguished from scope-locked denials
- [ ] pytest tests verify cancel, adaptive timeout, and permission detection

## Out of Scope

- Automatic permission adjustment (detection only; the caller decides how to respond)
- Streaming-based timeout (would require real-time output analysis)
- Cross-platform signal handling (SDK targets Linux/WSL; Windows signal semantics differ)
