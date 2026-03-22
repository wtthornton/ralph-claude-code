# Story CBDECAY-2: Session State Reinitialization After CB Reset

**Epic:** [Circuit Breaker Failure Decay](epic-circuit-breaker-decay.md)
**Priority:** Medium
**Status:** Pending
**Effort:** Small
**Component:** `ralph_loop.sh` (session management)

---

## Problem

After a circuit breaker trip resets the session, `.ralph_session` contains empty fields:

```json
{
  "session_id": "",
  "created_at": "",
  "last_used": "",
  "reset_at": "2026-03-22T05:47:34+00:00",
  "reset_reason": "circuit_breaker_trip"
}
```

The `session_id`, `created_at`, and `last_used` fields are empty strings. When the loop resumes after CB recovery (HALF_OPEN → CLOSED), session continuity is broken because no valid session ID exists.

**Root cause confirmed by:** Both TheStudio and tapps-brain `.ralph_session` files showing empty fields after CB trip.

## Solution

After CB reset clears the session, the next loop iteration must detect the empty session and reinitialize it properly — either by creating a new session ID or by letting the first successful Claude invocation populate it.

## Implementation

### Step 1: Add session validation function

```bash
ralph_validate_session() {
    local session_file="${RALPH_DIR}/.ralph_session"

    if [[ ! -f "$session_file" ]]; then
        log "INFO" "No session file — will initialize on first successful invocation"
        return 1
    fi

    local session_id
    session_id=$(jq -r '.session_id // ""' "$session_file" 2>/dev/null)

    if [[ -z "$session_id" ]]; then
        log "WARN" "Session file exists but session_id is empty — reinitializing"
        ralph_initialize_session
        return $?
    fi

    return 0
}
```

### Step 2: Add session initialization function

```bash
ralph_initialize_session() {
    local session_file="${RALPH_DIR}/.ralph_session"
    local now
    now=$(date -u +%Y-%m-%dT%H:%M:%S+00:00)

    # Write new session with all fields populated
    local new_session
    new_session=$(jq -n \
        --arg created "$now" \
        --arg last_used "$now" \
        --arg reset_reason "reinitialized" \
        '{
            session_id: "",
            created_at: $created,
            last_used: $last_used,
            reset_at: $created,
            reset_reason: $reset_reason
        }')

    # Atomic write
    local tmpfile="${session_file}.tmp.$$"
    echo "$new_session" > "$tmpfile"
    mv "$tmpfile" "$session_file"
    rm -f "$tmpfile" 2>/dev/null  # WSL cleanup

    log "INFO" "Session reinitialized at $now (awaiting session_id from next Claude invocation)"
}
```

### Step 3: Call validation at loop start

```bash
# In the main loop, before each Claude invocation:
ralph_validate_session

# After successful Claude invocation, update session_id if it was empty:
if [[ -n "$CLAUDE_SESSION_ID" ]]; then
    local current_id
    current_id=$(jq -r '.session_id // ""' "$session_file" 2>/dev/null)
    if [[ -z "$current_id" ]]; then
        # First successful invocation after reset — populate session_id
        local now
        now=$(date -u +%Y-%m-%dT%H:%M:%S+00:00)
        jq --arg sid "$CLAUDE_SESSION_ID" --arg now "$now" \
            '.session_id = $sid | .last_used = $now' \
            "$session_file" > "${session_file}.tmp.$$"
        mv "${session_file}.tmp.$$" "$session_file"
        rm -f "${session_file}.tmp.$$" 2>/dev/null
        log "INFO" "Session ID populated: ${CLAUDE_SESSION_ID:0:12}..."
    fi
fi
```

### Step 4: Update CB reset to preserve timestamps

```bash
# In the CB trip handler, ensure reset writes valid timestamps:
cb_reset_session() {
    local session_file="${RALPH_DIR}/.ralph_session"
    local now
    now=$(date -u +%Y-%m-%dT%H:%M:%S+00:00)
    local reason="${1:-circuit_breaker_trip}"

    jq -n \
        --arg now "$now" \
        --arg reason "$reason" \
        '{
            session_id: "",
            created_at: "",
            last_used: "",
            reset_at: $now,
            reset_reason: $reason
        }' > "${session_file}.tmp.$$"
    mv "${session_file}.tmp.$$" "$session_file"
    rm -f "${session_file}.tmp.$$" 2>/dev/null
}
```

## Design Notes

- **Lazy initialization**: The session_id is intentionally left empty after CB reset. It gets populated by the first successful Claude invocation. This is cleaner than generating a fake ID.
- **Atomic writes**: All session file updates use write-to-temp-then-rename, following the npm/write-file-atomic pattern. The `rm -f` after `mv` handles WSL/NTFS orphaned temp files (existing pattern from v1.0.0).
- **Timestamp always populated**: Even when session_id is empty, `reset_at` and `reset_reason` are always set so debugging is possible.
- **Validation at loop start**: Catches both CB-reset empty sessions and manually corrupted session files.

## Acceptance Criteria

- [ ] After CB trip and recovery, session file is validated before next invocation
- [ ] Empty `session_id` triggers reinitialization log message (not silent)
- [ ] First successful Claude invocation after reset populates `session_id`
- [ ] `reset_at` and `reset_reason` are always populated (never empty)
- [ ] Atomic writes prevent partial/corrupt session files
- [ ] `--status` shows "Session: reinitializing" when session_id is empty

## Test Plan

```bash
@test "ralph_validate_session detects empty session_id" {
    source "$RALPH_DIR/ralph_loop.sh"
    RALPH_DIR="$TEST_DIR"

    echo '{"session_id":"","created_at":"","last_used":"","reset_at":"2026-03-22T00:00:00+00:00","reset_reason":"test"}' \
        > "$TEST_DIR/.ralph_session"

    run ralph_validate_session
    assert_failure  # Empty session needs reinitialization
}

@test "ralph_validate_session passes with valid session" {
    source "$RALPH_DIR/ralph_loop.sh"
    RALPH_DIR="$TEST_DIR"

    echo '{"session_id":"abc123","created_at":"2026-03-22T00:00:00+00:00","last_used":"2026-03-22T01:00:00+00:00"}' \
        > "$TEST_DIR/.ralph_session"

    run ralph_validate_session
    assert_success
}

@test "ralph_initialize_session populates timestamps" {
    source "$RALPH_DIR/ralph_loop.sh"
    RALPH_DIR="$TEST_DIR"

    ralph_initialize_session

    run jq -r '.created_at' "$TEST_DIR/.ralph_session"
    refute_output ""

    run jq -r '.reset_reason' "$TEST_DIR/.ralph_session"
    assert_output "reinitialized"
}

@test "session file is not corrupt after atomic write" {
    source "$RALPH_DIR/ralph_loop.sh"
    RALPH_DIR="$TEST_DIR"

    ralph_initialize_session

    # Validate JSON is parseable
    run jq '.' "$TEST_DIR/.ralph_session"
    assert_success
}
```

## References

- [npm/write-file-atomic](https://github.com/npm/write-file-atomic) — Atomic write pattern
- [crash-safe-write-file](https://github.com/CharlieHess/crash-safe-write-file) — Crash-safe file operations
- [LWN.net — Atomic File Writes](https://lwn.net/Articles/789600/)
- [WAL and ARIES Recovery](https://sookocheff.com/post/databases/write-ahead-logging/) — Write-ahead logging patterns
