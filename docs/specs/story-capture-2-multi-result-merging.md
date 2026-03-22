# Story CAPTURE-2: Multi-Result Stream Merging Strategy

**Epic:** [Stream Capture & Recovery](epic-stream-capture-recovery.md)
**Priority:** Medium
**Status:** Pending
**Effort:** Small
**Component:** `ralph_loop.sh` (`ralph_extract_result_from_stream`)

---

## Problem

Claude sometimes emits 2–5 top-level result objects in a single NDJSON stream. The current code warns about "multi-task loop violations" and falls back to "emergency JSONL extraction." In tapps-brain, this emergency path was triggered ~30 times consecutively, indicating it's not an emergency — it's the normal operating mode for certain workloads.

The emergency extraction is fragile: it uses `jq -s '.[0]'` (first result wins), which may not be the final/authoritative result.

**Root cause confirmed by:** tapps-brain logs 2026-03-21, 30+ emergency extractions; TheStudio 2026-03-22, 2 multi-result violations.

## Solution

Replace the "emergency JSONL extraction" with a deliberate multi-result merging strategy:
1. Filter to only `type: "result"` objects (ignore system, tool_use, etc.)
2. Exclude sub-agent results (they have `parent_tool_use_id`)
3. Take the **last** top-level result as authoritative (last-writer-wins)
4. Downgrade log level from WARN to DEBUG for expected multi-result streams

## Implementation

### Step 1: Update `ralph_extract_result_from_stream`

```bash
ralph_extract_result_from_stream() {
    local stream_file="$1"
    local result_file="$2"

    # Extract all top-level result objects (exclude sub-agent results)
    local results_count
    results_count=$(jq -c 'select(.type == "result") | select(.parent_tool_use_id == null or .parent_tool_use_id == "")' \
        "$stream_file" 2>/dev/null | wc -l)

    if [[ "$results_count" -eq 0 ]]; then
        log "ERROR" "Stream extraction failed: no valid result object in stream"
        return 1
    fi

    if [[ "$results_count" -gt 1 ]]; then
        # This is expected behavior for multi-task batches, not an emergency
        log "DEBUG" "Stream contains $results_count top-level result objects — using last (authoritative)"
    fi

    # Last-writer-wins: take the final top-level result
    jq -c 'select(.type == "result") | select(.parent_tool_use_id == null or .parent_tool_use_id == "")' \
        "$stream_file" 2>/dev/null | tail -1 > "$result_file"

    # Validate the extracted result is valid JSON
    if ! jq -e '.' "$result_file" >/dev/null 2>&1; then
        log "ERROR" "Extracted result is not valid JSON"
        return 1
    fi

    return 0
}
```

### Step 2: Remove emergency JSONL extraction path

```bash
# Remove the emergency fallback — it's no longer needed
# The primary path now handles multi-result streams natively

# Delete or comment out:
# [WARN] Emergency JSONL extraction: converted multi-value stream to single result object
```

### Step 3: Add result metadata for debugging

```bash
# After extraction, log what we got for debugging
ralph_log_result_summary() {
    local result_file="$1"
    local status exit_signal work_type
    status=$(jq -r '.status // "unknown"' "$result_file" 2>/dev/null)
    exit_signal=$(jq -r '.exit_signal // "unknown"' "$result_file" 2>/dev/null)
    work_type=$(jq -r '.work_type // "unknown"' "$result_file" 2>/dev/null)
    log "DEBUG" "Result: status=$status exit_signal=$exit_signal work_type=$work_type"
}
```

## Design Notes

- **Last-writer-wins**: The last result object is the most authoritative because Claude processes tasks sequentially. The final result reflects the end state of the entire invocation. This matches production NDJSON patterns from Vector.dev and Logstash.
- **Sub-agent filtering**: Results with `parent_tool_use_id` are sub-agent completions, not the main loop result. Filtering these was already partially implemented (STREAM-2) but the emergency path bypassed it.
- **WARN → DEBUG**: Multi-result streams are expected when Claude batches tasks (8 SMALL per invocation). Logging at WARN creates noise; DEBUG preserves the information without polluting the main log.
- **No merge strategy needed**: Unlike database conflicts, NDJSON results are independent snapshots. The last one is the most complete — no need for field-level merging.

## Acceptance Criteria

- [ ] Multi-result streams extract the last top-level result (not the first)
- [ ] Sub-agent results (with `parent_tool_use_id`) are excluded from result count
- [ ] "Emergency JSONL extraction" code path is removed
- [ ] Multi-result streams log at DEBUG, not WARN
- [ ] Single-result streams continue to work unchanged
- [ ] Streams with 0 result objects still fail with clear error

## Test Plan

```bash
@test "extract_result handles single result" {
    cat > "$TEST_DIR/stream.jsonl" <<'EOF'
{"type":"system","session_id":"abc"}
{"type":"result","status":"SUCCESS","content":"done"}
EOF
    source "$RALPH_DIR/ralph_loop.sh"
    run ralph_extract_result_from_stream "$TEST_DIR/stream.jsonl" "$TEST_DIR/result.json"
    assert_success
    run jq -r '.status' "$TEST_DIR/result.json"
    assert_output "SUCCESS"
}

@test "extract_result takes last result from multi-result stream" {
    cat > "$TEST_DIR/stream.jsonl" <<'EOF'
{"type":"result","status":"PARTIAL","content":"task 1"}
{"type":"tool_use","name":"Edit","id":"t2"}
{"type":"result","status":"COMPLETE","content":"task 2 final"}
EOF
    source "$RALPH_DIR/ralph_loop.sh"
    run ralph_extract_result_from_stream "$TEST_DIR/stream.jsonl" "$TEST_DIR/result.json"
    assert_success
    run jq -r '.status' "$TEST_DIR/result.json"
    assert_output "COMPLETE"
}

@test "extract_result excludes sub-agent results" {
    cat > "$TEST_DIR/stream.jsonl" <<'EOF'
{"type":"result","parent_tool_use_id":"agent_1","status":"SUB_DONE"}
{"type":"result","parent_tool_use_id":"agent_2","status":"SUB_DONE"}
{"type":"result","status":"MAIN_DONE","content":"main result"}
EOF
    source "$RALPH_DIR/ralph_loop.sh"
    run ralph_extract_result_from_stream "$TEST_DIR/stream.jsonl" "$TEST_DIR/result.json"
    assert_success
    run jq -r '.status' "$TEST_DIR/result.json"
    assert_output "MAIN_DONE"
}

@test "extract_result fails on empty stream" {
    echo '{"type":"system","session_id":"abc"}' > "$TEST_DIR/stream.jsonl"
    source "$RALPH_DIR/ralph_loop.sh"
    run ralph_extract_result_from_stream "$TEST_DIR/stream.jsonl" "$TEST_DIR/result.json"
    assert_failure
}
```

## References

- [NDJSON Best Practices — Unique Identifiers and Deduplication](https://ndjson.com/best-practices/)
- [Vector.dev Dedupe Transform](https://vector.dev/docs/reference/configuration/transforms/dedupe/)
- [jq Manual — select and last](https://jqlang.org/manual/)
- [richrose.dev — Merge Multiple JSON Files with jq](https://richrose.dev/posts/linux/jq/jq-jsonmerge/)
