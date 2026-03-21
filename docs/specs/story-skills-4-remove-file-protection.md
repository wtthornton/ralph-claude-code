# Story RALPH-SKILLS-4: Remove file_protection.sh (Hooks Handle It)

**Epic:** [Skills + Bash Reduction](epic-skills-bash-reduction.md)
**Priority:** Important
**Status:** Open
**Effort:** Trivial
**Component:** `lib/file_protection.sh`, `ralph_loop.sh`
**Depends on:** RALPH-HOOKS-5 (file protection hooks validated)

---

## Problem

After Phase 1, the `protect-ralph-files.sh` and `validate-command.sh` PreToolUse hooks
handle all file protection that `lib/file_protection.sh` (58 lines) previously performed.
The hooks are strictly superior: they prevent edits **before** they happen (PreToolUse),
while the bash module only validated **before** each loop iteration (pre-loop check).

## Solution

Remove `lib/file_protection.sh` and the `validate_ralph_integrity()` call in
`ralph_loop.sh`.

## Implementation

### Step 1: Remove the source

In `ralph_loop.sh`, remove:
```bash
source lib/file_protection.sh
```

### Step 2: Remove validate_ralph_integrity() call

In the main loop, remove the pre-loop integrity check:
```bash
# Remove this block
validate_ralph_integrity || {
  log_error "Ralph integrity check failed"
  # ... error handling
}
```

### Step 3: Delete the file

```bash
rm lib/file_protection.sh
```

### Step 4: Update tests

Remove or adapt `test_file_protection.bats` to test the hook scripts instead.

## Testing

```bash
@test "file_protection.sh is removed" {
  [[ ! -f "lib/file_protection.sh" ]]
}

@test "ralph_loop.sh does not source file_protection" {
  ! grep -q "file_protection" ralph_loop.sh
}

@test "ralph_loop.sh does not call validate_ralph_integrity" {
  ! grep -q "validate_ralph_integrity" ralph_loop.sh
}
```

## Acceptance Criteria

- [ ] `lib/file_protection.sh` deleted (-58 lines)
- [ ] `source lib/file_protection.sh` removed from `ralph_loop.sh`
- [ ] `validate_ralph_integrity()` call removed from main loop
- [ ] File protection hook tests pass (from RALPH-HOOKS-5)
- [ ] No regressions in file protection behavior
