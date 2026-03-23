# Story ENABLE-3: Source-Level Import Result Reporting

**Epic:** [RALPH-ENABLE](epic-enable-wizard-hardening.md)
**Priority:** High
**Status:** Open
**Effort:** Medium
**Component:** `ralph_enable.sh`, `lib/task_sources.sh`

---

## Problem

When a selected source fails (auth missing, tool unavailable, parse error), the wizard may continue with little or no explanation.

## Solution

Track and display per-source import outcomes: attempted, imported count, empty result, and failure reason.

## Implementation

1. Add per-source result objects for `beads`, `github`, and `prd`.
2. Capture explicit failure reasons (dependency missing, auth failure, file missing, parse error).
3. Print a final import summary table in interactive mode.
4. Return structured result data for future `--json` output.

## Acceptance Criteria

- [ ] Each selected source reports success, empty, or failure with reason.
- [ ] Import summary is shown before file generation completes.
- [ ] Silent import failures are eliminated.
- [ ] Tests cover mixed outcomes across multiple sources.
