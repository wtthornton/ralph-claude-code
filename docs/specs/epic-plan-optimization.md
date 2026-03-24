# Epic: Fix Plan Optimization on Startup

**Epic ID:** RALPH-PLANOPT
**Priority:** High
**Affects:** Token efficiency, task ordering, context switching overhead, loop throughput, quality
**Components:** `lib/plan_optimizer.sh`, `lib/import_graph.sh`, `on-session-start.sh`, `ralph_import.sh`, `on-task-completed.sh`, `on-stop.sh`, `ralph.md`
**Related specs:** `epic-hooks-agent-definition.md`, `epic-skills-bash-reduction.md`, `epic-sdk-context-management.md`, `epic-subagents.md`
**Target Version:** v2.4.0

---

## Goal

Automatically reorder fix_plan.md tasks at session start for optimal autonomous execution —
minimizing wasted loops from dependency violations, reducing token usage from scattered file
reads, and improving batch density — while preserving human intent via section boundaries,
stable sort tiebreakers, and explicit dependency metadata overrides.

## Problem statement

Ralph executes fix_plan.md tasks top-down in whatever order the human wrote them. Humans
are bad at optimizing task order for AI execution. Common problems:

1. **Scattered file edits** — Tasks touching the same module are spread across sections,
   forcing repeated explorer calls and file re-reads across loops.
2. **Dependency violations** — A task depends on another task that appears later in the plan.
   Ralph implements the dependent task first, then wastes an entire loop discovering the
   prerequisite doesn't exist.
3. **Poor batching** — Interleaving SMALL, MEDIUM, and LARGE tasks prevents efficient
   batching. A sequence of [SMALL, LARGE, SMALL, SMALL] can't batch, but
   [SMALL, SMALL, SMALL, LARGE] batches the first three.
4. **Suboptimal epic boundaries** — Tasks within a `##` section have no locality, so
   epic-boundary QA runs cover scattered files instead of focused modules.
5. **Phase disorder** — Tasks that create new entities are interleaved with tasks that
   consume those entities, rather than following the create→implement→test→document
   ordering that top SWE-bench agents converge on.

The fix_plan changes frequently — humans add tasks, reprioritize, and insert hotfixes.
A one-time optimization at import is insufficient. **Optimization must run on every
startup**, but only re-process sections that actually changed.

## Research Foundations

This design is grounded in published research and established tooling patterns:

| Source | Key Insight | How We Apply It |
|--------|-------------|-----------------|
| SWE-Agent (Yang et al., Princeton 2024) | Structured plan (localize→edit→test) outperforms ad-hoc ordering | Phase ordering within module groups |
| Agentless (Xia et al., UIUC 2024) | Non-iterative pipeline matches agents; batching edits per file reduces switching cost | Module grouping for file locality |
| "Lost in the Middle" (Liu et al., Stanford 2023) | LLMs perform worst on information in the middle of context | Place highest-impact tasks at visible boundaries |
| Reflexion (Shinn et al., 2023) | Injecting "lessons learned" at context reset reduces wasted cycles | Progress re-grounding at session start |
| Nx / Turborepo | File-level import graph for affected analysis; `dependsOn` metadata for explicit ordering | AST import graph for real dependency detection |
| Bazel / Pants | DAG-based task scheduling with topological sort; hermetic output validation | Unix `tsort` for ordering; semantic equivalence check |
| Aider | Repo map (file paths + signatures) reduces token usage 60-80% | Coordinate with ContextManager's progressive trimming |
| Anthropic Prompt Caching (2024-2025) | 90% cost reduction on stable prefixes | Optimizer modifies dynamic suffix only, never stable prefix |

## Proposed Solution

### Core approach: import-graph-driven reordering with `tsort`

Replace the original NLP-heuristic dependency detection with **real file dependency
analysis** via AST import graph parsing, and replace the custom jq topological sort
with Unix `tsort` (POSIX coreutil, battle-tested, handles cycle detection).

### Pipeline (runs once per session start, per changed section):

```
1. Build/refresh file dependency graph (AST import parsing, cached)
     ↓
2. Parse fix_plan.md into task metadata (file refs, phase, size)
     ↓
3. Detect dependencies:
   a. Import graph: if task A's file imports task B's file → B before A
   b. Explicit metadata: <!-- depends: task-id --> comments
   c. Phase convention: create → implement → test → document
     ↓
4. Feed dependency pairs to `tsort` for topological ordering
     ↓
5. Secondary sort: module grouping → phase ordering → size clustering
     ↓
6. Validate: semantic equivalence check (same tasks in, same tasks out)
     ↓
7. Write optimized plan (atomic, backup kept for 1 loop)
     ↓
8. Inject context: progress summary + batch annotations
```

### Claude Code feature integration

The optimizer leverages Ralph's full sub-agent and hook ecosystem:

| Feature | How it's used | Story |
|---------|---------------|-------|
| **ralph-explorer** (Haiku) | Resolves vague tasks ("Fix auth flow") to specific file paths when regex extraction finds no files. Cheap (~500 tokens per task on Haiku). | PLANOPT-2 |
| **ralph-explorer** (Haiku) | Maps PRD requirements to actual codebase files during `ralph_import` | PLANOPT-4 |
| **TaskCompleted hook** | Marks import graph entries stale for files created/modified by each task. Enables incremental graph invalidation. | PLANOPT-5 |
| **Stop hook (on-stop.sh)** | Extracts `files_changed` from Claude's response and writes to `.files_modified_this_loop` for incremental graph invalidation. | PLANOPT-5 |
| **SessionStart hook** | Runs the optimizer, injects progress re-grounding and batch annotations. Async graph rebuild when stale. | PLANOPT-3 |
| **ralph.md agent prompt** | Updated to be optimization-aware: trust task ordering, use batch hints, write `<!-- depends: -->` when discovering dependencies. | PLANOPT-3 |
| **Background subprocess** | Import graph rebuild runs async (non-blocking) when stale; uses cached graph for current loop. | PLANOPT-1, PLANOPT-3 |

### What the optimizer does NOT do:
- Move tasks between `##` sections (epic boundaries are sacred)
- Touch checked `[x]` tasks (history is immutable)
- Change task wording (only reorder lines, optionally annotate `<!-- resolved: -->`)
- Run on sections that haven't changed (section-level hashing)
- Modify the prompt's stable prefix (preserves prompt cache hit rate)

## Stories

| ID | Story | Effort | Priority |
|----|-------|--------|----------|
| PLANOPT-1 | [File dependency graph](story-planopt-1-file-dependency-graph.md) | Medium | Critical |
| PLANOPT-2 | [Plan analysis and reordering engine](story-planopt-2-analysis-and-reorder.md) | Medium | Critical |
| PLANOPT-3 | [Session-start integration](story-planopt-3-session-start.md) | Small | Critical |
| PLANOPT-4 | [Import-time optimization](story-planopt-4-import-optimization.md) | Small | Normal |
| PLANOPT-5 | [Observability and logging](story-planopt-5-observability.md) | Small | Normal |

## Implementation Order (Story Dependencies)

```
PLANOPT-1 (import graph)          ← foundation, no dependencies
    ↓
PLANOPT-2 (reorder engine)        ← depends on PLANOPT-1 (import_graph_lookup)
    ↓
PLANOPT-5 (observability + hooks) ← depends on PLANOPT-1 (invalidate_file) + PLANOPT-2 (orchestrator logging)
    ↓
PLANOPT-3 (session-start)         ← depends on PLANOPT-1 + PLANOPT-2; benefits from PLANOPT-5 hooks
    ↓
PLANOPT-4 (import optimization)   ← depends on PLANOPT-1 + PLANOPT-2; independent of PLANOPT-3/5
```

**Note:** PLANOPT-2 guards calls to `plan_opt_log` with `declare -f plan_opt_log &>/dev/null`
so it can ship before PLANOPT-5. Logging is enhanced (not required) by PLANOPT-5.

PLANOPT-3 and PLANOPT-4 can be implemented in parallel after PLANOPT-2.

## Token Savings Estimate (Conservative)

Based on SWE-bench data showing top agents use 50K-200K tokens per issue, and that
re-reading a 500-line file costs ~2K tokens:

- **Explorer calls avoided:** 1-2 per loop (module-grouped tasks share context) → ~500-1K tokens
- **File re-reads avoided:** 2-3 per loop (adjacent tasks share files) → ~2K-6K tokens
- **Dependency ordering:** Prevents 1-2 wasted loops per 20-loop session → ~50K-100K tokens
- **Better batching:** 1 additional task batched per loop → ~1 fewer loop per epic
- **Progress re-grounding:** Claude skips re-discovery → ~500-1K tokens per loop

Over a 20-loop session: **~80K-150K tokens saved**, plus 2-4 fewer loop iterations.

Note: The SDK ContextManager trims fix_plan.md to ~5 unchecked items. Token savings
from reordering are therefore concentrated in the **visible window** — optimizing
items 6-20 has no direct token impact but still improves dependency correctness
(item 6 becomes visible after item 1 is completed).

## Configuration (.ralphrc)

New variables introduced by this epic (add to `templates/ralphrc.template`):

```bash
# Plan optimization (PLANOPT epic)
RALPH_NO_OPTIMIZE=false          # Set to true to disable plan optimization entirely
RALPH_NO_EXPLORER_RESOLVE=false  # Set to true to skip ralph-explorer file resolution
RALPH_MAX_EXPLORER_RESOLVE=5     # Max vague tasks to resolve per optimization run
```

These can also be set as environment variables (env overrides `.ralphrc`).

## Risks

1. **AST parsing fails on non-standard imports** — Mitigated by fallback to file-path
   heuristics when import graph is unavailable. Graph is additive, not required.
2. **`tsort` cycle in dependencies** — `tsort` prints a warning and produces a
   best-effort order. The optimizer logs the cycle and continues.
3. **Optimizer rewrites break the plan** — Mitigated by semantic equivalence check
   (R6): abort if task set changes. Backup kept for 1 full loop iteration.
4. **Cost of import graph build** — Mitigated by caching in `.ralph/.import_graph.json`
   with mtime-based staleness detection. Rebuild only when source files change.
5. **Human intent overridden** — Mitigated by `--no-optimize` flag, section boundary
   preservation, optional `<!-- depends: -->` metadata for human overrides, and
   original order as tiebreaker (stable sort).
6. **Python/Node dependency for AST parsing** — Projects already have their language
   runtime available. Graceful fallback: if no runtime detected, skip import graph
   and use file-path heuristics only.

## Acceptance criteria

- [ ] File dependency graph built via AST parsing (Python ast, madge/dep-cruiser for JS)
- [ ] Import graph cached and invalidated by file mtime
- [ ] Dependencies fed to `tsort` (no custom topological sort code)
- [ ] Phase ordering applied within module groups (create→implement→test→document)
- [ ] Semantic equivalence validated before write (task count + content hash)
- [ ] Section-level hashing prevents re-optimization of unchanged sections
- [ ] Backup kept for 1 loop iteration (not deleted immediately)
- [ ] Context injection includes progress summary and batch annotations
- [ ] `--no-optimize` flag disables optimization
- [ ] Optimizer source path correctly resolves from `~/.ralph/lib/`
- [ ] Completes in < 500ms for typical plans (most loops skip entirely via hash)
- [ ] Works on Linux, macOS, and WSL
- [ ] ralph-explorer resolves vague tasks to file paths (PLANOPT-2)
- [ ] TaskCompleted hook invalidates import graph for modified files (PLANOPT-5)
- [ ] ralph.md agent prompt updated for optimization awareness (PLANOPT-3)
- [ ] Import graph rebuild is non-blocking (async with stale cache fallback)

## Scoring Projections

| Criterion | Before (original design) | After (this design) |
|-----------|--------------------------|---------------------|
| Speed | 6/10 | 9/10 |
| Token savings | 4/10 | 9/10 |
| Quality | 5/10 | 9/10 |
| Implementation risk | 3/10 | 8.5/10 |
| Proportionality | 5/10 | 8/10 |
