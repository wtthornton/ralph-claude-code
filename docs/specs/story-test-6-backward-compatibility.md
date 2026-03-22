# Story TEST-6: Implement Backward Compatibility Tests

**Epic:** [RALPH-TEST](epic-validation-testing.md)
**Priority:** Medium
**Status:** Open
**Effort:** Medium
**Component:** `tests/integration/test_backward_compat.bats`

---

## Problem

Ralph's file formats, CLI flags, and configuration keys form an implicit API contract with users. Version upgrades (especially the SDK additions) must not break existing setups. Without backward compatibility tests, regressions are discovered by users, not CI.

## Solution

Create tests that verify current behavior contracts are preserved across versions. Tests run against fixture projects representing each supported version's configuration format.

## Implementation

```bash
@test ".ralphrc from v0.11 is still readable" {
  cp tests/fixtures/ralphrc-v0.11 "$TEST_PROJECT/.ralphrc"
  run ralph --project "$TEST_PROJECT" --dry-run
  [ "$status" -eq 0 ]
}

@test ".ralphrc from v1.0 is still readable" {
  cp tests/fixtures/ralphrc-v1.0 "$TEST_PROJECT/.ralphrc"
  run ralph --project "$TEST_PROJECT" --dry-run
  [ "$status" -eq 0 ]
}

@test "status.json v1.0 format is still parseable" {
  cp tests/fixtures/status-v1.0.json "$TEST_PROJECT/.ralph/status.json"
  run parse_status "$TEST_PROJECT/.ralph/status.json"
  [ "$status" -eq 0 ]
}

@test "fix_plan.md checkbox format unchanged" {
  echo "- [ ] task one" > "$TEST_PROJECT/.ralph/fix_plan.md"
  echo "- [x] task two" >> "$TEST_PROJECT/.ralph/fix_plan.md"
  run count_tasks "$TEST_PROJECT/.ralph/fix_plan.md"
  [[ "$output" == *"1 remaining"* ]]
  [[ "$output" == *"1 complete"* ]]
}

@test "deprecated flags produce warnings not errors" {
  # If any flags are deprecated in future, they should warn, not crash
  run ralph --project "$TEST_PROJECT" --dry-run
  [ "$status" -eq 0 ]
}

@test "ALLOWED_TOOLS patterns from v1.0 still match" {
  cp tests/fixtures/ralphrc-v1.0 "$TEST_PROJECT/.ralphrc"
  source "$TEST_PROJECT/.ralphrc"
  # Verify known patterns still work
  [[ "$ALLOWED_TOOLS" == *"Bash(git"* ]]
}

@test "hooks directory structure preserved" {
  [ -d "$RALPH_HOOKS_DIR" ]
  [ -f "$RALPH_HOOKS_DIR/on-stop.sh" ]
  [ -f "$RALPH_HOOKS_DIR/on-session-start.sh" ]
}
```

### Fixture Files
Create `tests/fixtures/` with:
- `ralphrc-v0.11` — Earliest supported .ralphrc format
- `ralphrc-v1.0` — v1.0 .ralphrc format
- `status-v1.0.json` — v1.0 status.json format

## Acceptance Criteria

- [ ] All supported `.ralphrc` versions parse correctly
- [ ] status.json from all versions is readable
- [ ] fix_plan.md checkbox format is stable
- [ ] Deprecated flags warn rather than error
- [ ] ALLOWED_TOOLS patterns are backward compatible
- [ ] Hook directory structure is stable
- [ ] Fixture files created for each supported version
