# Epic: Enable Wizard Hardening & UX Improvements (Phase 14)

**Epic ID:** RALPH-ENABLE
**Priority:** High
**Status:** Done
**Affects:** `ralph_enable.sh`, `lib/enable_core.sh`, `lib/task_sources.sh`, `lib/wizard_utils.sh`, docs
**Components:** Interactive enable flow, task import pipeline, safety controls, reporting
**Related specs:** `epic-context-management.md`, `epic-observability-v2.md`
**Target Version:** v2.2.0
**Depends on:** None

---

## Problem Statement

`ralph enable` is the first-run experience for existing projects. The current flow is functional, but it has gaps that reduce trust and reliability in real-world repos:

1. **State detection drift** - "already enabled" logic is not fully aligned with verification requirements.
2. **Input validation gaps** - invalid `--from` values and PRD paths are not rejected early.
3. **Low failure visibility** - import failures can appear as "no tasks imported" without actionable reasons.
4. **Safety concerns** - `--force` can overwrite files that should remain user-owned.
5. **Task quality issues** - multi-source imports can produce duplicates and noisy plans.
6. **Limited automation ergonomics** - no dry-run planning or machine-readable output for CI/tooling.

## Stories

| Story | Title | Priority | Effort | Status |
|-------|-------|----------|--------|--------|
| [ENABLE-1](story-enable-1-state-detection-alignment.md) | Align Enabled-State Detection with Required Artifacts | Critical | Small | **Done** |
| [ENABLE-2](story-enable-2-cli-input-validation.md) | Strict CLI Validation for `--from` and `--prd` | High | Small | **Done** |
| [ENABLE-3](story-enable-3-import-failure-transparency.md) | Source-Level Import Result Reporting | High | Medium | **Done** |
| [ENABLE-4](story-enable-4-force-safety-and-backups.md) | Harden `--force` Behavior and Preserve User Files | High | Medium | **Done** |
| [ENABLE-5](story-enable-5-task-normalization-dedup.md) | Normalize, Deduplicate, and Cap Imported Tasks | Medium | Medium | **Done** |
| [ENABLE-6](story-enable-6-dry-run-and-json-output.md) | Add `--dry-run` and `--json` for Automation | Medium | Medium | **Done** |
| [ENABLE-7](story-enable-7-wizard-ux-improvements.md) | Improve Prompt UX and Final Summary Guidance | Medium | Small | **Done** |

## Implementation Order

1. **ENABLE-1** - correctness baseline for idempotency and trust
2. **ENABLE-2** - explicit contract for CLI behavior
3. **ENABLE-3** - visibility into import outcomes
4. **ENABLE-4** - safety guarantees before broad adoption
5. **ENABLE-5** - quality improvements for generated plans
6. **ENABLE-6** - automation and CI compatibility
7. **ENABLE-7** - polish and onboarding quality

## Verification Criteria

- [x] "Already enabled" and verification checks use the same required file set.
- [x] Invalid `--from` values return `ENABLE_INVALID_ARGS` with clear remediation.
- [x] `--from prd` validates path existence/readability before generation.
- [x] Import flow reports per-source attempted/success/failed/empty with reasons.
- [x] `--force` does not overwrite `.gitignore` unless explicitly requested.
- [x] Force operations create recoverable backups for overwritten Ralph-managed files.
- [x] Imported tasks are normalized and deduplicated across sources.
- [x] `--dry-run` prints planned operations without writing files.
- [x] `--json` emits a machine-readable summary for CI consumption.

## Rollback

All changes are additive and guarded by flags where possible. Existing `ralph enable` invocations remain valid, with stricter validation only for previously undefined/invalid inputs.
