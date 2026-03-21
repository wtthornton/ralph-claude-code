# Story RALPH-JSONL-4: Add Fallback JSONL Extraction in ralph_loop

**Epic:** [JSONL Stream Processing Resilience](epic-jsonl-stream-resilience.md)
**Priority:** Defensive
**Status:** Done
**Effort:** Small
**Component:** `ralph_loop.sh` (after stream extraction, before analysis)

---

## Problem

Even with the filesystem resilience fix (RALPH-JSONL-3), there are scenarios where
the stream extraction block completes but fails to convert the output file from JSONL
to a single result object:

1. The `grep` for `"type":"result"` may fail on malformed or truncated result lines
2. The `jq -e .` validation may reject the extracted line
3. The `CLAUDE_USE_CONTINUE` flag may be false, bypassing extraction entirely
4. Future code changes may introduce new failure paths

In all these cases, the output file remains as raw JSONL and is passed to
`analyze_response` / `parse_json_response`, triggering the crash.

This story adds a **safety net** between stream extraction and analysis: a final check
that detects unconverted JSONL and extracts the result object before analysis begins.

## Solution

Add a JSONL safety check after the stream extraction block and before
`analyze_response` is called. This is a "belt and suspenders" defense that catches
any case where the primary extraction missed.

## Implementation

In `ralph_loop.sh`, add after the stream extraction block (after line ~1380) and
before the `analyze_response` call:

```bash
# Safety net: if output file is still JSONL after extraction, convert it now
if [[ -f "$output_file" ]]; then
    local _file_lines
    _file_lines=$(wc -l < "$output_file" 2>/dev/null | tr -d '[:space:]')
    _file_lines="${_file_lines:-1}"

    if [[ "$_file_lines" -gt 5 ]]; then
        # Still JSONL -- extract result object as last resort
        log_status "WARN" "Output file still JSONL ($_file_lines lines) after extraction phase"

        local _emergency_result
        _emergency_result=$(jq -c 'select(.type == "result")' "$output_file" 2>/dev/null | tail -1)

        if [[ -n "$_emergency_result" ]] && echo "$_emergency_result" | jq -e . >/dev/null 2>&1; then
            # Back up stream first (if not already backed up)
            local _backup="${output_file%.log}_stream.log"
            if [[ ! -f "$_backup" ]]; then
                cp "$output_file" "$_backup"
                log_status "INFO" "Created stream backup: $_backup"
            fi

            echo "$_emergency_result" > "$output_file"
            log_status "WARN" "Emergency JSONL extraction: converted $_file_lines-line stream to single result object"
        else
            log_status "ERROR" "Emergency JSONL extraction failed: no valid result object in $_file_lines-line stream"
        fi
    fi
fi
```

## Design Notes

- **Threshold of 5 lines:** A single JSON result object is 1 line. A JSON array
  wrapper might be 3 lines. 5 lines is a safe threshold to distinguish "already
  extracted" from "still JSONL." Real stream output is typically 100-5000+ lines.
- **`jq -c 'select(.type == "result")'` over `grep`:** More robust than the existing
  grep-based extraction. jq properly parses JSON structure rather than regex matching
  on string content. This catches edge cases like `"type": "result"` with varying
  whitespace or nested objects containing the string "result".
- **Stream backup:** Creates `_stream.log` if not already created by the primary
  extraction block. This preserves the full stream for debugging.
- **Warning-level logging:** This path should never execute if the primary extraction
  works correctly. WARN-level makes it visible for monitoring without triggering error
  alerts.
- **ERROR on failure:** If even the emergency extraction fails, log at ERROR level.
  This creates an actionable log entry instead of the current silent crash.

## Acceptance Criteria

- [ ] JSONL output files are detected and converted before reaching `analyze_response`
- [ ] Stream backup (`_stream.log`) is created if not already present
- [ ] Warning is logged when emergency extraction is needed
- [ ] Error is logged when emergency extraction fails
- [ ] Already-extracted single-object files pass through unchanged
- [ ] Already-extracted JSON arrays pass through unchanged

## Test Plan

```bash
@test "fallback extraction converts JSONL to single result" {
    # Simulate extraction failure: output file is still JSONL
    local output_file="$TEST_DIR/claude_output.log"

    # Write 100 stream events + 1 result
    for i in $(seq 1 99); do
        echo "{\"type\":\"stream_event\",\"index\":$i}"
    done > "$output_file"
    echo '{"type":"result","status":"SUCCESS","exit_signal":true,"confidence":80}' >> "$output_file"

    # Verify it's still JSONL (100 lines)
    local lines
    lines=$(wc -l < "$output_file" | tr -d '[:space:]')
    assert_equal "$lines" "100"

    # Run the fallback extraction logic
    source ralph_loop.sh  # or extracted function
    # ... (invoke the safety net logic)

    # Verify converted to single object
    lines=$(wc -l < "$output_file" | tr -d '[:space:]')
    assert_equal "$lines" "1"

    # Verify backup created
    assert [ -f "${output_file%.log}_stream.log" ]

    # Verify result content
    run jq -r '.status' "$output_file"
    assert_output "SUCCESS"
}

@test "fallback extraction does not modify single-object files" {
    local output_file="$TEST_DIR/claude_output.log"
    echo '{"type":"result","status":"SUCCESS"}' > "$output_file"

    local original_hash
    original_hash=$(md5sum "$output_file" | cut -d' ' -f1)

    # Run the fallback extraction logic -- should be a no-op
    # ... (invoke the safety net logic)

    local new_hash
    new_hash=$(md5sum "$output_file" | cut -d' ' -f1)
    assert_equal "$original_hash" "$new_hash"
}

@test "fallback extraction logs error when no result object exists" {
    local output_file="$TEST_DIR/claude_output.log"

    # Write 50 stream events with NO result object
    for i in $(seq 1 50); do
        echo "{\"type\":\"stream_event\",\"index\":$i}"
    done > "$output_file"

    # Run the fallback extraction logic
    # ... (invoke the safety net logic)

    # Should log ERROR about failed extraction
    # Verify via log file or captured output
}
```

## Interaction with Other Stories

- **RALPH-JSONL-1 (parser detection):** If both fixes are present, this story prevents
  JSONL from reaching the parser at all, and JSONL-1 handles it gracefully if it does.
  Together they provide two layers of defense.
- **RALPH-JSONL-3 (filesystem resilience):** This story catches cases that JSONL-3
  cannot prevent (e.g., extraction logic bugs, `CLAUDE_USE_CONTINUE` being false).
