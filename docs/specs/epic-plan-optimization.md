# Epic: Fix Plan Optimization on Startup

**Epic ID:** RALPH-PLANOPT
**Priority:** High
**Affects:** Token efficiency, task ordering, context switching overhead, loop throughput
**Components:** `on-session-start.sh`, `ralph.md`, `ralph_import.sh`, new `optimize-plan.sh`
**Related specs:** `epic-hooks-agent-definition.md`, `epic-skills-bash-reduction.md`
**Target Version:** v1.9.0

---

## Problem Statement

Ralph executes fix_plan.md tasks top-down in whatever order the human wrote them. Humans
are bad at optimizing task order for AI execution. Common problems:

1. **Scattered file edits** — Tasks touching the same module are spread across sections,
   forcing repeated explorer calls and file re-reads across loops.
2. **Dependency violations** — A task depends on another task that appears later in the plan.
   Ralph implements the dependent task first, then has to revisit or patch when the
   dependency is completed.
3. **Poor batching** — Interleaving SMALL, MEDIUM, and LARGE tasks prevents efficient
   batching. A sequence of [SMALL, LARGE, SMALL, SMALL] can't batch, but
   [SMALL, SMALL, SMALL, LARGE] batches the first three.
4. **Suboptimal epic boundaries** — Tasks within a `##` section have no locality, so
   epic-boundary QA runs cover scattered files instead of focused modules.

The fix_plan changes frequently — humans add tasks, reprioritize, and insert hotfixes.
A one-time optimization at import is insufficient. **Optimization must run on every
startup**, before the first task is picked up.

## Proposed Solution

Add a **plan optimization step** that runs once per loop on startup (loop 1 and every
subsequent loop where fix_plan.md has changed since last optimization). The optimizer:

1. Reads fix_plan.md and the project's file structure
2. Reorders unchecked tasks **within each `##` section** (preserves epic boundaries)
3. Applies optimization rules: module grouping, dependency ordering, size clustering
4. Writes the optimized plan back to fix_plan.md
5. Records a hash so unchanged plans aren't re-optimized

### What the optimizer does NOT do:
- Move tasks between `##` sections (epic boundaries are sacred)
- Touch checked `[x]` tasks (history is immutable)
- Change task wording (only reorder lines)
- Run on every loop if the plan hasn't changed (hash check)

## Stories

| ID | Story | Effort | Priority |
|----|-------|--------|----------|
| PLANOPT-1 | [Plan analysis and dependency detection](story-planopt-1-plan-analysis.md) | Medium | Critical |
| PLANOPT-2 | [Task reordering engine](story-planopt-2-reorder-engine.md) | Medium | Critical |
| PLANOPT-3 | [Session-start integration](story-planopt-3-session-start.md) | Small | Critical |
| PLANOPT-4 | [Import-time optimization](story-planopt-4-import-optimization.md) | Small | Normal |
| PLANOPT-5 | [Optimization metrics and logging](story-planopt-5-metrics.md) | Small | Normal |

## Token Savings Estimate

Conservative estimate per loop iteration:
- **Explorer calls avoided:** 1-2 per loop (grouped module tasks skip explorer) → ~500-1000 tokens saved
- **File re-reads avoided:** 2-4 per loop (adjacent tasks share files in context) → ~2000-8000 tokens saved
- **Better batching:** 1 additional task batched per loop on average → ~1 fewer loop iteration per epic
- **Focused QA:** Epic-boundary tests cover fewer modules → ~500 tokens in tester prompt

Over a 20-loop session: **~60K-200K tokens saved**, plus 2-5 fewer loop iterations.

## Risks

1. **Optimizer rewrites break the plan** — Mitigated by only reordering lines within
   sections, never modifying task text. Backup before write.
2. **Dependency detection is wrong** — Mitigated by conservative heuristics (file path
   matching, keyword detection). When uncertain, preserve original order.
3. **Cost of optimization itself** — Mitigated by hash check (skip if unchanged) and
   lightweight bash/jq implementation (no Claude API call needed for basic reordering).
4. **Human intent overridden** — Mitigated by `--no-optimize` flag and preserving
   section boundaries.

## Success Criteria

- [ ] Unchecked tasks within each section are grouped by module/file proximity
- [ ] Dependency ordering is respected (data model before feature that uses it)
- [ ] Size clustering improves batching (SMALL tasks adjacent where possible)
- [ ] No optimization runs when fix_plan.md is unchanged since last run
- [ ] `--no-optimize` flag disables optimization
- [ ] Checked tasks and section headers are never moved
