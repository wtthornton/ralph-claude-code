---
title: "ADR-0004: Epic-boundary QA deferral"
status: accepted
date: 2025-12-01
deciders: Ralph maintainers
tags: [performance, cost, quality, sub-agents]
audience: [contributor, operator]
diataxis: explanation
last_reviewed: 2026-04-23
---

# ADR-0004: Epic-boundary QA deferral

## Context

By late 2025, Ralph had four sub-agents: `ralph` (main), `ralph-explorer`, `ralph-tester`, and `ralph-reviewer`. The initial policy was "run the full suite every loop iteration." It was safe but slow and expensive:

- **ralph-tester** runs the full test suite in a worktree. On a medium project this is 30-120 seconds per call.
- **ralph-reviewer** does a line-by-line diff review. Token-heavy.
- **ralph-explorer** does a codebase scan. Fast, but still one model call per loop.
- **Backups** snapshotted state every iteration.
- **Log rotation** checked on every loop.

Cost and latency analysis on a representative 20-loop session showed roughly 40% of the Claude call budget going to QA that was re-running over unchanged work. The operator-visible feedback loop was slower than needed.

But we couldn't just skip QA: **regressions land at the end of epics**, and without QA the dual-condition exit gate could fire with broken tests.

## Decision

Defer expensive operations to **epic boundaries** — the completion of the last `- [ ]` task under a `##` section in `fix_plan.md`.

| Operation | Mid-epic | At epic boundary | Mandatory before `EXIT_SIGNAL: true` |
|---|---|---|---|
| **ralph-tester** | Skip; set `TESTS_STATUS: DEFERRED` | Run | Yes |
| **ralph-reviewer** | Skip | Run | Yes |
| **ralph-explorer** | Skip for consecutive SMALL tasks in the same module; use Glob/Grep directly | Run if needed | N/A |
| **Backups** | Skip | Snapshot | Yes |
| **Log rotation** | Check every 10 loops | Check | N/A |
| **Batch size** | Up to 8 SMALL / 5 MEDIUM tasks per invocation | N/A | N/A |

Additional mandatory QA conditions:

- **LARGE or ARCHITECTURAL tasks** (from the complexity classifier) always get both tester and reviewer, mid-epic or not.
- **`EXIT_SIGNAL: true`** requires tester and reviewer to have run successfully since the last productive change.

## Consequences

### Positive

- **~3x throughput increase** on observed sessions. Mid-epic iterations are now in the 1-3 minute range instead of 5-10.
- **Cost reduction** — per-loop Claude spend dropped substantially because the QA agents are Opus-class when invoked, and they're invoked far less often.
- **Better batching economics.** Increased batch sizes (8 SMALL / 5 MEDIUM) are safe because epic-boundary QA catches regressions.
- **Clear mental model.** Operators can think in epics, not loops. The sub-agent invocation pattern matches how humans work.

### Negative

- **Regressions can land mid-epic.** If a SMALL task in the middle of an epic breaks an unrelated test, it won't be caught until the boundary. Risk reduced by:
  - `file_protection.sh` blocking modifications to critical areas
  - Fast failure patterns — syntax errors surface immediately in Claude's own tool output
  - Epic boundaries are typically 3-8 tasks, not 30
- **Epic detection brittleness.** A malformed `fix_plan.md` (wrong heading depth, missing `##` sections) can confuse the boundary detector. Mitigation: the plan optimizer normalizes headings at session start.
- **`TESTS_STATUS: DEFERRED` ambiguity.** Mid-epic, tests aren't green — they're unrun. A consumer that treats `DEFERRED` as a pass-equivalent would miss regressions. We document this explicitly and enforce "tests must PASS for exit" in the gate.

### Neutral

- Operators who want the old behavior can set `RALPH_NO_DEFER_QA=true` (implementation: sub-agents run unconditionally). Rarely used; kept for compatibility.

## Considered alternatives

- **Always run full QA** — the previous default. Rejected because of cost and latency.
- **Time-based deferral** — run QA every N minutes. Rejected because clock time doesn't correlate with logical progress; a slow compile step could push QA off forever.
- **Let Claude decide** — ask the model whether QA is needed. Rejected because the model is biased toward saying yes (safer-feeling option) and the prompt complexity was high.
- **Background tester (ralph-bg-tester) only** — run tests asynchronously in parallel with the next iteration. Kept as an option but not the default; works well for some topologies but complicates failure attribution.

## Related

- [ADR-0001](0001-dual-condition-exit-gate.md) — why test-pass can't be part of the exit gate (DEFERRED is legitimate)
- [ARCHITECTURE.md](../ARCHITECTURE.md#epic-boundary-deferral) — implementation details
- [GLOSSARY.md](../GLOSSARY.md#epic-boundary) — term definition
- [CLAUDE.md](../../CLAUDE.md) — epic-boundary deferral invariants
