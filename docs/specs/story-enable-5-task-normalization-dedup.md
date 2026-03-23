# Story ENABLE-5: Normalize, Deduplicate, and Cap Imported Tasks

**Epic:** [RALPH-ENABLE](epic-enable-wizard-hardening.md)
**Priority:** Medium
**Status:** Open
**Effort:** Medium
**Component:** `lib/task_sources.sh`, `ralph_enable.sh`

---

## Problem

Combining tasks from multiple sources can produce duplicates, inconsistent formatting, and overly large initial plans.

## Solution

Introduce a post-import normalization pipeline that de-duplicates equivalent tasks and applies configurable limits.

## Implementation

1. Normalize all tasks to a canonical format.
2. Deduplicate exact and near-duplicate lines (case/punctuation-insensitive baseline).
3. Add per-source and total caps to avoid noisy `fix_plan.md`.
4. Include de-duplication counts in final summary.

## Acceptance Criteria

- [ ] Multi-source imports no longer duplicate identical tasks.
- [ ] Task formatting is consistent in generated `fix_plan.md`.
- [ ] Large imports are capped with a clear warning.
- [ ] Summary reports raw vs normalized task counts.
