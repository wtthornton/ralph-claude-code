# Story ENABLE-7: Improve Prompt UX and Final Summary Guidance

**Epic:** [RALPH-ENABLE](epic-enable-wizard-hardening.md)
**Priority:** Medium
**Status:** Open
**Effort:** Small
**Component:** `lib/wizard_utils.sh`, `ralph_enable.sh`, docs

---

## Problem

The wizard flow is usable but not optimal for first-time users, especially when source selection/import outcomes are ambiguous.

## Solution

Improve interaction clarity and final guidance without changing core behavior.

## Implementation

1. Add stronger defaults/recommendations in prompts (for example recommended source and call limits).
2. Improve multi-select fallback behavior for non-TTY terminals.
3. Add concise final summary including: files created, files skipped, backups, tasks imported, and next commands.
4. Update README command docs with the new flow and examples.

## Acceptance Criteria

- [ ] Prompt defaults are explicit and consistent.
- [ ] Non-TTY usage does not degrade or hang on multi-select.
- [ ] Final summary includes operationally useful next steps.
- [ ] Docs reflect the revised interactive experience.
