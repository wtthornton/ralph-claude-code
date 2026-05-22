---
title: "ADR-0008: Parallel ticket execution stays under the teammate flow, not a new coordinator fan-out"
status: accepted
date: 2026-05-22
deciders: Ralph maintainers
tags: [parallelism, worktrees, teammates, agent-architecture]
audience: [contributor, integrator]
diataxis: explanation
last_reviewed: 2026-05-22
---

# ADR-0008: Parallel ticket execution stays under the teammate flow, not a new coordinator fan-out

## Context

The 2026-05-22 post-AgentForge campaign review surfaced a proposal to add a `parallel_safe: bool` field to coordinator `brief.json`, with the main loop agent spawning up to N=2 parallel worktrees via `EnterWorktree` for `parallel_safe` siblings. Goal: ship 3 independent tickets in ~loop-time-of-one × 1.3 instead of 3×.

Ralph already has a parallelism path: the **teammate** concept in `.claude/agents/ralph.md` (lines 260–299):

- Lead agent (the main loop's Claude instance) identifies independent tasks via file-ownership scope
- Up to `RALPH_MAX_TEAMMATES` (default 3) sibling agents spawn, each in its own worktree
- Lead coordinates and merges results
- Idle teammates are reaped by the `.ralph/hooks/on-teammate-idle.sh` hook
- Sequential fallback when tasks have file dependencies

Both proposals serve the same goal (parallel ticket throughput) with different mechanisms. Doing both creates two ways to express the same intent and two failure surfaces.

## Decision

**Reject the new `parallel_safe` coordinator-driven fan-out. Keep the teammate flow as the single parallelism path in Ralph.**

The teammate flow has these properties the new proposal lacks:

1. **File-ownership-scope isolation already enforced.** `.claude/agents/ralph.md:267-269` already groups by file-ownership scope (backend / frontend / config-docs). The `parallel_safe` proposal would need to re-derive this in the coordinator.
2. **Worktree management already wired.** Idle reaping, worktree pruning, and conflict surfacing all flow through the existing `on-teammate-idle.sh` hook. A second worktree-spawn path would need parallel handling.
3. **Sequential fallback is part of the same contract.** Teammate flow degrades gracefully — when tasks have shared files, lead runs them serially. The coordinator-fan-out proposal needs its own fallback logic, duplicating the decision.

What we DO take from the proposal:

- **Coordinator-side file-overlap analysis as a HINT for the teammate flow.** The coordinator already analyzes affected_modules. Extending `brief.json` with a `siblings_parallel_safe: [TAP-ID, TAP-ID, ...]` array (purely advisory) would give the lead agent a starting point for teammate assignment without forcing a new spawn path. This is a future enhancement, not a structural change.

## Rationale

| Concern | Teammate flow (current) | New `parallel_safe` fan-out (proposed) | Choice |
|---|---|---|---|
| Where parallelism decisions live | Agent prose contract (.claude/agents/ralph.md) | Coordinator brief.json field | Teammate (single source of truth) |
| Worktree spawn mechanism | `EnterWorktree` per teammate | `EnterWorktree` per parallel sibling | Tie (same primitive) |
| Conflict handling on shared files | Sequential fallback in the contract | Mid-loop bail to serial | Teammate (declarative) |
| Idle / failed worker handling | `on-teammate-idle.sh` hook | Would need new hook | Teammate (already shipped) |
| Operator visibility | Teammate scope in agent log + worktree dir names | New coordinator log section + brief.json field | Teammate (existing) |
| Coordination cost | Lead reads fix_plan / Linear, picks teammates | Coordinator computes parallel_safe + lead reads | Teammate (1 hop) |
| Scope of change | Zero new code | New brief.json field + coordinator analysis + lead-side fan-out logic + tests | Teammate (smaller delta) |

## Consequences

- **Positive.** One parallelism path, one mental model. Future ticket-throughput improvements layer on top of the teammate flow rather than competing with it.
- **Positive.** Coordinator stays read-mostly (its current contract). Adding `parallel_safe` analysis would expand its responsibility into "decide and act."
- **Negative.** Operators reading the post-campaign review proposal will look for `parallel_safe` and not find it. This ADR is the answer.
- **Future enhancement.** If teammate adoption is low, the friction is likely "lead doesn't know which siblings to group." The 2026-mid-year community consensus (4–8 worktrees per developer, reliably; 6–10 upper end) suggests Ralph's current cap of 3 is conservative. Raising `RALPH_MAX_TEAMMATES` default to 4 and surfacing the coordinator's `affected_modules` as a teammate-assignment hint is the lowest-risk next step.

## Reversibility

If teammate flow proves insufficient over the next 2–3 campaigns, this ADR can be superseded. The signal would be: campaigns where the lead consistently ignores teammate assignment despite multiple `parallel_safe` opportunities in the brief. At that point a coordinator-driven fan-out becomes the right answer because the agent isn't acting on the prose contract.

## Alternatives considered

- **Ship both.** Rejected — two parallelism paths means two failure surfaces and double the cognitive load for contributors.
- **Replace teammate flow with the new fan-out.** Rejected — teammate flow is shipped, tested, and has operator muscle memory. Replacing it for marginal gain (the new flow doesn't structurally beat it) is churn.

## References

- `.claude/agents/ralph.md` lines 260–299 (Team Mode contract)
- `.ralph/hooks/on-teammate-idle.sh`
- [Claude Code Worktrees Guide 2026 (ClaudeDirectory)](https://www.claudedirectory.org/blog/claude-code-worktrees-guide) — 4–8 worktrees per dev reliable, 6–10 upper end
- [Claude Code Subagents 2026 (Tembo)](https://www.tembo.io/blog/claude-code-subagents) — `isolation: worktree` as the default
