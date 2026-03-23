# Story ENABLE-1: Align Enabled-State Detection with Required Artifacts

**Epic:** [RALPH-ENABLE](epic-enable-wizard-hardening.md)
**Priority:** Critical
**Status:** Open
**Effort:** Small
**Component:** `lib/enable_core.sh`, `ralph_enable.sh`

---

## Problem

`check_existing_ralph()` marks a project as complete based on `.ralph/PROMPT.md`, `.ralph/fix_plan.md`, and `.ralph/AGENT.md`, while Phase 5 verification treats `.ralphrc` as critical. This can report "already enabled" for an incomplete setup.

## Solution

Unify completeness criteria so pre-check and post-verification use the same required artifact set.

## Implementation

1. Update `check_existing_ralph()` required files to include `.ralphrc`.
2. Expose a single source-of-truth list for required artifacts.
3. Ensure partial-state reporting includes missing `.ralphrc`.
4. Keep `--force` semantics unchanged.

## Acceptance Criteria

- [ ] A project missing `.ralphrc` is reported as `partial`, never `complete`.
- [ ] Pre-check and verification use the same required files.
- [ ] Existing fully enabled projects continue to return `complete`.
- [ ] Tests cover none/partial/complete states including `.ralphrc`.
