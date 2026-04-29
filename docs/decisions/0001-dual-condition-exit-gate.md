---
title: "ADR-0001: Dual-condition exit gate"
status: accepted
date: 2025-09-15
deciders: Ralph maintainers
tags: [loop, exit, safety]
audience: [contributor, operator]
diataxis: explanation
last_reviewed: 2026-04-23
---

# ADR-0001: Dual-condition exit gate

## Context

Ralph is an autonomous loop. It must stop when the work is done — and only then. Both failure modes have costs:

- **Stopping too early.** A half-finished feature merges. Rate-limit quota is wasted. Operator trust erodes.
- **Stopping too late.** Loop runs against a done plan, burning API calls and money. Eventually the circuit breaker trips on "no progress," generating a misleading failure report.

The naïve designs both failed in practice:

- **Claude's self-reported "done" alone.** Claude optimizes for locally plausible stopping points. It says "done" at the end of a subtask when more work remains — especially when a long plan's next section doesn't share context with the current one. Early Ralph versions exited prematurely on this signal.
- **Heuristic completion detection alone.** NLP on Claude's output looking for "all tests pass", "task complete", explicit `DONE` markers. False positives when the model discusses adjacent passing tests or references other completed tasks in its explanation. Also false positives when summaries use completion language mid-epic.

## Decision

Ralph exits **only when both conditions are true**:

1. **`completion_indicators >= 2`** — the loop's rolling NLP heuristic count of done-like signals.
2. **`EXIT_SIGNAL: true`** in the `RALPH_STATUS` block — Claude's structured self-report.

Both come from independent sources. Both can be wrong in isolation. Requiring agreement catches ~all premature exits while allowing genuine completion to fire promptly.

Additional safety properties layered on top:

- **Completion-indicator decay (SDK-SAFETY-3)** — when productive work occurs (files modified or tasks completed) and `EXIT_SIGNAL` is false, completion indicators are **reset to `[]`**. Stale "done" signals from earlier in the session cannot accumulate and combine with later legitimate signals for premature exit.
- **Pre-flight empty-plan check (PREFLIGHT-EMPTY-PLAN)** — `should_exit_gracefully()` runs at the top of every iteration **before** Claude is invoked. Zero unchecked `- [ ]` items in `fix_plan.md` → immediate `plan_complete` exit, no Claude call. Equivalent Linear check exists, with **fail-loud** abstention on API errors (see [ADR-0003](0003-linear-task-backend.md)).
- **`EXIT-CLEAN` branch** — the Stop hook recognizes `EXIT_SIGNAL: true && STATUS: COMPLETE` with zero files/tasks as a **clean** exit, even though it looks like "no progress." Without this, end-of-campaign loops tripped the circuit breaker on the same signal Claude was using to ask for shutdown.

## Consequences

### Positive

- **No premature exits observed** in production since this pattern stabilized in v1.0.
- **Deferred work still exits cleanly.** The EXIT-CLEAN branch handles the case where Claude legitimately says "all done" after zero new changes.
- **Independent failure modes.** A broken hook can't cause a false exit by itself; the heuristic would have to lie too.

### Negative

- **More complex to explain** than a single condition. Required explicit documentation in [CLAUDE.md](../../CLAUDE.md), [ARCHITECTURE.md](../ARCHITECTURE.md), and [GLOSSARY.md](../GLOSSARY.md).
- **Test surface is larger.** The deterministic eval suite has dedicated tests for each branch, including the `EXIT-CLEAN` case.
- **Slight latency.** A legitimately complete session takes 1-2 extra loop iterations to accumulate the second completion indicator. Accepted because the cost is tiny compared to a single premature exit.

### Neutral

- Operators must understand both conditions to diagnose "why didn't Ralph stop" vs. "why did Ralph stop early." Documentation covers this in [TROUBLESHOOTING.md](../TROUBLESHOOTING.md#exit-problems).

## Considered alternatives

- **`EXIT_SIGNAL: true` alone** — tried in v0.x, rejected. Premature exits were the #1 user complaint.
- **Three-of-three consensus** — heuristic + self-report + test-pass. Rejected because `TESTS_STATUS` is legitimately `DEFERRED` mid-epic (see [ADR-0004](0004-epic-boundary-qa-deferral.md)); requiring a test result would block every multi-epic session.
- **Operator confirmation on exit** — rejected because it defeats the "leave it running overnight" use case.

## Related

- [ADR-0002](0002-hook-based-response-analysis.md) — hook-based response parsing writes the `EXIT_SIGNAL` field the gate depends on
- [ADR-0004](0004-epic-boundary-qa-deferral.md) — why test-pass isn't one of the conditions
- [CLAUDE.md](../../CLAUDE.md#dual-condition-exit-gate) — invariant documentation
- [FAILURE.md](../../FAILURE.md) — failure modes, especially FM-003 (consecutive timeout)
