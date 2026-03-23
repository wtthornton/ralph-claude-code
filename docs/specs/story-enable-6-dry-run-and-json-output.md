# Story ENABLE-6: Add `--dry-run` and `--json` for Automation

**Epic:** [RALPH-ENABLE](epic-enable-wizard-hardening.md)
**Priority:** Medium
**Status:** Open
**Effort:** Medium
**Component:** `ralph_enable.sh`, `lib/enable_core.sh`

---

## Problem

Automation workflows cannot preview changes safely or parse wizard outcomes reliably.

## Solution

Add dry-run planning and machine-readable output for CI and tool integrations.

## Implementation

1. Add `--dry-run` to print planned file writes/overwrites/import sources without writing.
2. Add `--json` to emit structured output (detection, selected config, import summary, write plan/result).
3. Ensure interactive prompts and color output are suppressed/compatible with JSON mode.
4. Preserve existing human-readable output as default.

## Acceptance Criteria

- [ ] `--dry-run` performs no filesystem writes.
- [ ] `--json` emits valid JSON and exits with accurate status code.
- [ ] `--dry-run --json` returns a complete plan payload.
- [ ] Existing non-JSON behavior is unchanged.
