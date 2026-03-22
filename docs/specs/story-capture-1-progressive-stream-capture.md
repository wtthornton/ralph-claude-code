# Story CAPTURE-1: Progressive Stream Capture Before SIGTERM

**Epic:** [Stream Capture & Recovery](epic-stream-capture-recovery.md)
**Priority:** High
**Status:** Pending
**Effort:** Medium
**Component:** `ralph_loop.sh` (Claude CLI invocation pipeline)

---

## Problem

When Ralph's timeout fires SIGTERM at Claude Code, buffered NDJSON output is lost. C stdio uses 4KB block buffering when writing to a pipe, so the last ~4KB of output never reaches the log file. Post-timeout, `ralph_extract_result_from_stream` fails with `Stream extraction failed: no valid result object in stream`.

This means after every timeout, Ralph has:
- No idea which tools were used
- No idea what files were changed
- No RALPH_STATUS block to parse
- No ability to update circuit breaker state accurately

**Root cause confirmed by:** TheStudio logs 2026-03-22, 20 consecutive stream extraction failures.

## Solution

Force line-buffered output from the Claude CLI pipeline so each NDJSON line is written to disk immediately. Add a SIGTERM trap handler that gives the child process a grace period to flush before killing.

## Implementation

### Step 1: Use `stdbuf -oL` for line-buffered output

Wrap the Claude CLI command with `stdbuf -oL` to force line buffering:

```bash
# Current (block-buffered — loses data on SIGTERM):
$CLAUDE_CMD --print --output-format json ... < "$PROMPT_FILE" \
    | awk '{...}' > "$OUTPUT_FILE" 2>"$STDERR_FILE"

# New (line-buffered — each NDJSON line flushed immediately):
stdbuf -oL $CLAUDE_CMD --print --output-format json ... < "$PROMPT_FILE" \
    | stdbuf -oL awk '{...}' \
    | tee "$OUTPUT_FILE" > /dev/null 2>"$STDERR_FILE"
```

### Step 2: Add `tee` for progressive file output

```bash
# Ensure output hits disk progressively via tee
# tee writes each line to the file AND passes it through
stdbuf -oL $CLAUDE_CMD ... < "$PROMPT_FILE" 2>"$STDERR_FILE" \
    | stdbuf -oL tee "$RAW_STREAM_FILE" \
    | stdbuf -oL awk '{... stream filter ...}' > "$LIVE_OUTPUT_FILE"
```

### Step 3: Add graceful SIGTERM handler with child flush

```bash
CHILD_PID=""

# Trap handler: give child time to flush, then kill
cleanup_child() {
    local signal="${1:-TERM}"
    if [[ -n "$CHILD_PID" ]] && kill -0 "$CHILD_PID" 2>/dev/null; then
        log "INFO" "Sending SIG$signal to Claude CLI (PID: $CHILD_PID), waiting 5s for flush..."
        kill -"$signal" "$CHILD_PID" 2>/dev/null

        # Wait up to 5 seconds for graceful shutdown
        local wait_count=0
        while kill -0 "$CHILD_PID" 2>/dev/null && [[ "$wait_count" -lt 5 ]]; do
            sleep 1
            wait_count=$((wait_count + 1))
        done

        # Force kill if still running
        if kill -0 "$CHILD_PID" 2>/dev/null; then
            log "WARN" "Claude CLI didn't exit gracefully — sending SIGKILL"
            kill -9 "$CHILD_PID" 2>/dev/null
        fi

        wait "$CHILD_PID" 2>/dev/null
    fi

    # Sync filesystem to ensure all buffered writes hit disk
    sync 2>/dev/null
}

# Set up trap before launching child
trap 'cleanup_child TERM' SIGTERM
trap 'cleanup_child INT' SIGINT
```

### Step 4: Launch Claude in background for trap-ability

```bash
# Traps only fire when bash is not waiting on a foreground process
# Run in background + wait to allow trap handler to execute

stdbuf -oL $CLAUDE_CMD ... < "$PROMPT_FILE" 2>"$STDERR_FILE" \
    | stdbuf -oL tee "$RAW_STREAM_FILE" \
    | stdbuf -oL awk '{...}' > "$LIVE_OUTPUT_FILE" &
CHILD_PID=$!

wait "$CHILD_PID"
EXIT_CODE=$?
CHILD_PID=""
```

### Step 5: Handle stdbuf unavailability

```bash
# stdbuf may not be available on all systems (e.g., macOS without coreutils)
if command -v stdbuf &>/dev/null; then
    STDBUF_CMD="stdbuf -oL"
else
    STDBUF_CMD=""
    log "WARN" "stdbuf not available — stream output may be lost on timeout"
fi

$STDBUF_CMD $CLAUDE_CMD ... | $STDBUF_CMD tee "$RAW_STREAM_FILE" | ...
```

### Step 6: Extract partial result from incomplete streams

```bash
# After timeout, attempt to extract whatever we have
ralph_extract_partial_result() {
    local stream_file="$1"
    local result_file="$2"

    # Try normal extraction first
    if ralph_extract_result_from_stream "$stream_file" "$result_file"; then
        return 0
    fi

    # Fallback: find the last valid JSON line with type=result
    local last_result
    last_result=$(tac "$stream_file" 2>/dev/null | while IFS= read -r line; do
        if echo "$line" | jq -e '.type == "result"' >/dev/null 2>&1; then
            echo "$line"
            break
        fi
    done)

    if [[ -n "$last_result" ]]; then
        echo "$last_result" > "$result_file"
        log "INFO" "Extracted partial result from truncated stream"
        return 0
    fi

    # Last resort: count valid NDJSON lines for stats
    local valid_lines
    valid_lines=$(jq -c '.' "$stream_file" 2>/dev/null | wc -l)
    log "WARN" "No result object in stream ($valid_lines valid NDJSON lines found)"
    return 1
}
```

## Design Notes

- **`stdbuf -oL` vs `unbuffer`**: `stdbuf` is lighter (no pseudo-TTY) and available via coreutils. `unbuffer` requires the `expect` package and can cause unexpected TTY behavior.
- **Why `tee`**: Writing to a file via `tee` ensures the file is updated progressively, not just at pipe completion. Even if `stdbuf` isn't available, `tee` improves the situation.
- **Background + wait pattern**: Bash traps only fire between commands, not during a foreground `wait`. Running the child in background + explicit `wait` allows SIGTERM to trigger the trap handler immediately.
- **5-second grace period**: Gives Claude CLI time to write its final result object. Most Claude responses complete their final JSON write within 1-2 seconds of receiving SIGTERM.
- **Filesystem sync**: `sync` after kill ensures data written by the child process is flushed from kernel buffers to disk, especially important on WSL2/9P filesystem.
- **Partial result extraction**: Even a truncated stream often contains tool-use records and partial results that are better than nothing for state tracking.

## Acceptance Criteria

- [ ] NDJSON lines are written to disk progressively (not buffered until pipe closes)
- [ ] After SIGTERM timeout, stream file contains all data written before the kill
- [ ] `ralph_extract_result_from_stream` succeeds on partial streams (when a result object exists)
- [ ] New `ralph_extract_partial_result` fallback counts valid lines when no result exists
- [ ] Graceful fallback when `stdbuf` is not available
- [ ] No change to behavior when Claude exits normally (non-timeout case)

## Test Plan

```bash
@test "stdbuf availability check works" {
    source "$RALPH_DIR/ralph_loop.sh"
    if command -v stdbuf &>/dev/null; then
        assert [ -n "$STDBUF_CMD" ]
    else
        assert [ -z "$STDBUF_CMD" ]
    fi
}

@test "ralph_extract_partial_result finds last result in truncated stream" {
    cat > "$TEST_DIR/truncated.jsonl" <<'EOF'
{"type":"system","session_id":"abc"}
{"type":"tool_use","name":"Read","id":"t1"}
{"type":"result","status":"SUCCESS","content":"partial work"}
{"type":"tool_use","name":"Edit","id":"t2"}
EOF
    # Note: no final result — stream was truncated

    source "$RALPH_DIR/ralph_loop.sh"
    run ralph_extract_partial_result "$TEST_DIR/truncated.jsonl" "$TEST_DIR/result.json"
    assert_success

    run jq -r '.status' "$TEST_DIR/result.json"
    assert_output "SUCCESS"
}

@test "ralph_extract_partial_result handles stream with no result" {
    cat > "$TEST_DIR/no_result.jsonl" <<'EOF'
{"type":"system","session_id":"abc"}
{"type":"tool_use","name":"Read","id":"t1"}
EOF

    source "$RALPH_DIR/ralph_loop.sh"
    run ralph_extract_partial_result "$TEST_DIR/no_result.jsonl" "$TEST_DIR/result.json"
    assert_failure
}

@test "cleanup_child sends SIGTERM and waits" {
    # Start a sleep process as a mock child
    sleep 60 &
    CHILD_PID=$!

    source "$RALPH_DIR/ralph_loop.sh"
    cleanup_child "TERM"

    # Child should be gone
    run kill -0 "$CHILD_PID" 2>/dev/null
    assert_failure
}
```

## References

- [Julia Evans — Why Pipes Get Stuck: Buffering](https://jvns.ca/blog/2024/11/29/why-pipes-get-stuck-buffering/)
- [stdbuf(1) man page](https://man7.org/linux/man-pages/man1/stdbuf.1.html)
- [Baeldung — Turning Off Buffer in Pipe With stdbuf](https://www.baeldung.com/linux/stdbuf-pipe-turn-off-buffer)
- [Greg's Wiki — SignalTrap](https://mywiki.wooledge.org/SignalTrap)
- [Baeldung — Handling Signals in Bash Script](https://www.baeldung.com/linux/bash-signal-handling)
- [NDJSON Best Practices](https://ndjson.com/best-practices/)
- [jq 1.8 Manual — Streaming](https://jqlang.org/manual/)
