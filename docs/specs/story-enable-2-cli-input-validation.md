# Story ENABLE-2: Strict CLI Validation for `--from` and `--prd`

**Epic:** [RALPH-ENABLE](epic-enable-wizard-hardening.md)
**Priority:** High
**Status:** Open
**Effort:** Small
**Component:** `ralph_enable.sh`

---

## Problem

The wizard accepts undefined `--from` values and does not fail early for invalid PRD paths, leading to silent no-op imports and ambiguous outcomes.

## Solution

Validate CLI arguments at parse/config time with explicit errors and remediation text.

## Implementation

1. Restrict `--from` to `beads`, `github`, or `prd`.
2. Reject unknown values with `ENABLE_INVALID_ARGS`.
3. When `--from prd` is selected, require a readable file path (via `--prd` or prompt selection).
4. Emit clear error messages with expected usage examples.

## Acceptance Criteria

- [ ] `ralph enable --from foo` fails with `ENABLE_INVALID_ARGS`.
- [ ] `ralph enable --from prd --prd missing.md` fails before generation.
- [ ] Valid inputs preserve current behavior.
- [ ] Help text documents strict validation rules.
