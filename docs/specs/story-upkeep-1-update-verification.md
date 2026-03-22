# Story UPKEEP-1: CLI Auto-Update Verification

**Epic:** [Update & Log Reliability](epic-update-log-reliability.md)
**Priority:** Medium
**Status:** Pending
**Effort:** Small
**Component:** `ralph_loop.sh` (auto-update logic)

---

## Problem

Ralph's CLI auto-update reports success even when the version doesn't change:
```
[INFO] Claude CLI update available: 2.1.80 -> 2.1.81. Attempting auto-update...
[SUCCESS] Claude CLI updated: 2.1.80 -> 2.1.80
```

The second line shows the version stayed at 2.1.80 — the update failed silently but was reported as success. This happened 13 consecutive times in tapps-brain.

**Root cause confirmed by:** tapps-brain logs 2026-03-21, lines 790–2679.

## Solution

After running the update command, re-check the actual installed version. Report failure if the version didn't change. Add a retry limit to stop attempting updates that consistently fail.

## Implementation

### Step 1: Add post-update verification

```bash
ralph_auto_update_cli() {
    local current_version target_version

    # Get current version
    current_version=$($CLAUDE_CODE_CMD --version 2>/dev/null | head -1 | tr -d '[:space:]')

    # Check if update is available (existing logic)
    # ... existing update detection ...

    if [[ -n "$target_version" ]] && [[ "$current_version" != "$target_version" ]]; then
        log "INFO" "Claude CLI update available: $current_version -> $target_version. Attempting auto-update..."

        # Run update command
        $CLAUDE_CODE_CMD update 2>/dev/null || npm update -g @anthropic-ai/claude-code 2>/dev/null

        # Post-update verification
        local new_version
        new_version=$($CLAUDE_CODE_CMD --version 2>/dev/null | head -1 | tr -d '[:space:]')

        if [[ "$new_version" == "$target_version" ]]; then
            log "SUCCESS" "Claude CLI updated: $current_version -> $new_version"
        elif [[ "$new_version" != "$current_version" ]]; then
            log "WARN" "Claude CLI updated but to unexpected version: $current_version -> $new_version (expected $target_version)"
        else
            log "WARN" "Claude CLI update failed — version unchanged at $current_version"
            ralph_record_update_failure "$target_version"
        fi
    fi
}
```

### Step 2: Add update failure tracking and suppression

```bash
UPDATE_FAILURE_FILE="${RALPH_DIR}/.update_failures"
MAX_UPDATE_ATTEMPTS=3

ralph_record_update_failure() {
    local target_version="$1"
    local now
    now=$(date +%s)
    echo "$now $target_version" >> "$UPDATE_FAILURE_FILE"

    # Count recent failures for this target version
    local failures
    failures=$(grep -c "$target_version" "$UPDATE_FAILURE_FILE" 2>/dev/null || echo "0")

    if [[ "$failures" -ge "$MAX_UPDATE_ATTEMPTS" ]]; then
        log "WARN" "Update to $target_version has failed $failures times — suppressing further attempts"
        log "WARN" "Update manually: npm install -g @anthropic-ai/claude-code@$target_version"
    fi
}

ralph_should_attempt_update() {
    local target_version="$1"

    if [[ ! -f "$UPDATE_FAILURE_FILE" ]]; then
        return 0  # No failures recorded, attempt update
    fi

    local failures
    failures=$(grep -c "$target_version" "$UPDATE_FAILURE_FILE" 2>/dev/null || echo "0")

    if [[ "$failures" -ge "$MAX_UPDATE_ATTEMPTS" ]]; then
        return 1  # Too many failures, skip
    fi

    return 0
}
```

### Step 3: Integrate check before update attempt

```bash
# Before attempting update:
if ! ralph_should_attempt_update "$target_version"; then
    log "DEBUG" "Skipping update to $target_version (previous failures exceeded threshold)"
    return 0
fi
```

### Step 4: Clear failure tracking on successful update or new version

```bash
# After successful update:
: > "$UPDATE_FAILURE_FILE"  # Clear failures on success

# When a new target version appears:
ralph_record_update_failure() {
    local target_version="$1"
    # Clear old version failures when a new version is available
    if [[ -f "$UPDATE_FAILURE_FILE" ]]; then
        grep "$target_version" "$UPDATE_FAILURE_FILE" > "${UPDATE_FAILURE_FILE}.tmp" 2>/dev/null || true
        mv "${UPDATE_FAILURE_FILE}.tmp" "$UPDATE_FAILURE_FILE"
    fi
    # ... rest of function ...
}
```

## Design Notes

- **Post-update verification**: Mirrors the Rustup pattern — verify the installed version matches the target after update. This is the key missing step.
- **3-attempt limit**: After 3 failures for the same version, stop trying. The update likely requires manual intervention (permissions, network, npm config).
- **Manual command in warning**: Giving the user the exact command to run manually is more helpful than just saying "failed."
- **Version-scoped failures**: Failures are tracked per target version. When a new version is released, the counter resets — the new version might succeed where the old one failed.
- **NVM-Windows parallel**: NVM-Windows includes a full backup-and-rollback cycle. We don't need that complexity, but the post-verify step is essential.

## Acceptance Criteria

- [ ] Update reports failure when version doesn't change (not success)
- [ ] After 3 failed attempts for same version, further attempts are suppressed
- [ ] Warning includes manual update command
- [ ] Failure counter resets when target version changes
- [ ] Successful update clears failure tracking
- [ ] Existing `CLAUDE_AUTO_UPDATE=false` still disables auto-update entirely

## Test Plan

```bash
@test "auto-update reports failure when version unchanged" {
    source "$RALPH_DIR/ralph_loop.sh"
    CLAUDE_CODE_CMD="echo 2.1.80"  # Always returns same version

    run ralph_auto_update_cli
    assert_output --partial "update failed"
    refute_output --partial "SUCCESS"
}

@test "auto-update suppresses after MAX_UPDATE_ATTEMPTS" {
    source "$RALPH_DIR/ralph_loop.sh"
    UPDATE_FAILURE_FILE="$TEST_DIR/.update_failures"
    MAX_UPDATE_ATTEMPTS=3

    echo "1 2.1.81" > "$UPDATE_FAILURE_FILE"
    echo "2 2.1.81" >> "$UPDATE_FAILURE_FILE"
    echo "3 2.1.81" >> "$UPDATE_FAILURE_FILE"

    run ralph_should_attempt_update "2.1.81"
    assert_failure
}

@test "auto-update resets on new target version" {
    source "$RALPH_DIR/ralph_loop.sh"
    UPDATE_FAILURE_FILE="$TEST_DIR/.update_failures"
    MAX_UPDATE_ATTEMPTS=3

    echo "1 2.1.81" > "$UPDATE_FAILURE_FILE"
    echo "2 2.1.81" >> "$UPDATE_FAILURE_FILE"
    echo "3 2.1.81" >> "$UPDATE_FAILURE_FILE"

    # New version 2.1.82 should be attempted
    run ralph_should_attempt_update "2.1.82"
    assert_success
}
```

## References

- [Rustup Self-Update Source](https://github.com/rust-lang/rustup/blob/main/src/cli/self_update.rs)
- [NVM-Windows Self-Update System](https://deepwiki.com/coreybutler/nvm-windows/3.5-self-update-system)
- [Homebrew Attestation Verification](https://brew.sh/2024/05/14/homebrew-4.3.0/)
- [ASDF Version Manager Deep Dive](https://bitrise.io/blog/post/a-deep-dive-into-asdf-and-version-managers)
