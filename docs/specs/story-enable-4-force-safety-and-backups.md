# Story ENABLE-4: Harden `--force` Behavior and Preserve User Files

**Epic:** [RALPH-ENABLE](epic-enable-wizard-hardening.md)
**Priority:** High
**Status:** Open
**Effort:** Medium
**Component:** `lib/enable_core.sh`, `ralph_enable.sh`

---

## Problem

`--force` currently risks overwriting user-managed files (notably `.gitignore`) when the intent is to refresh Ralph-managed assets.

## Solution

Scope force-overwrite to Ralph-managed files by default and add backup safeguards for overwritten files.

## Implementation

1. Treat `.gitignore` as user-owned by default (skip even in force mode).
2. Add explicit opt-in flag (for example `--force-gitignore`) for template overwrite.
3. Before overwriting managed files, write a timestamped backup.
4. Surface backup locations in final summary.

## Acceptance Criteria

- [ ] `--force` does not overwrite `.gitignore` by default.
- [ ] Overwritten files have backups that can be restored.
- [ ] Backup behavior is documented and test-covered.
- [ ] Existing non-force behavior remains unchanged.
