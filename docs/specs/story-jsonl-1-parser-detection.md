# Story RALPH-JSONL-1: Add JSONL Detection to parse_json_response

**Epic:** [JSONL Stream Processing Resilience](epic-jsonl-stream-resilience.md)
**Priority:** Critical
**Status:** Done
**Effort:** Small
**Component:** `lib/response_analyzer.sh` (`parse_json_response` function)

---

## Problem

`parse_json_response` assumes its input is either a single JSON object or a JSON
array. When the input is JSONL (one JSON object per line, as produced by Claude Code
`--output-format stream-json`), every `jq` field extraction returns N lines instead
of 1. This corrupts all downstream bash variables and causes:

1. Bash arithmetic errors: `$((multiline_var + 0))` produces "syntax error in expression"
2. `jq --argjson` failures: multi-line strings are not valid JSON
3. Silent loop termination: the function returns 0 regardless, and the caller
   suppresses stderr with `2>/dev/null`

**Root cause confirmed by:** jq 1.8 documentation -- jq processes each JSON value in
the input independently, producing one output per input object. A 1466-line JSONL file
produces 1466 output lines per `jq` filter.

## Solution

Add JSONL detection after the existing array check (line 107) and before field
extractions (line 146). When JSONL is detected, extract the `type: "result"` object
and use it as the normalized input for the rest of the function.

## Implementation

In `response_analyzer.sh`, inside `parse_json_response`, add after line 107
(the `jq -e 'type == "array"'` check) and before field extractions:

```bash
# Detect JSONL (multiple JSON objects, one per line)
# jq processes each object independently; line count > 1 means JSONL/stream-json format
local line_count
line_count=$(wc -l < "$output_file" 2>/dev/null | tr -d '[:space:]')
line_count="${line_count:-1}"

if [[ "$line_count" -gt 1 ]]; then
    # JSONL detected -- extract the "result" type message for analysis
    local normalized_file
    normalized_file=$(mktemp)

    local result_obj
    result_obj=$(jq -c 'select(.type == "result")' "$output_file" 2>/dev/null | tail -1)

    if [[ -n "$result_obj" ]]; then
        echo "$result_obj" > "$normalized_file"

        # Preserve session_id for session continuity (--continue/--resume)
        # session_id is in the result object (confirmed by SDK type definition),
        # but fall back to system:init event if missing
        local result_session_id
        result_session_id=$(echo "$result_obj" | jq -r '.session_id // empty' 2>/dev/null)
        if [[ -z "$result_session_id" ]]; then
            local init_session_id
            init_session_id=$(jq -r 'select(.type == "system" and .subtype == "init") | .session_id // empty' "$output_file" 2>/dev/null | head -1)
            if [[ -n "$init_session_id" ]]; then
                echo "$result_obj" | jq -c --arg sid "$init_session_id" '. + {session_id: $sid}' > "$normalized_file"
            fi
        fi

        output_file="$normalized_file"
        log_status "INFO" "JSONL detected ($line_count lines), extracted result object for analysis"
    else
        # No result message found -- create minimal object to prevent crash
        echo '{"type":"unknown","status":"UNKNOWN"}' > "$normalized_file"
        output_file="$normalized_file"
        log_status "WARN" "JSONL detected ($line_count lines) but no result object found"
    fi
fi
```

Also add cleanup before every `return` in the function:

```bash
# Before each return statement in parse_json_response:
[[ -n "${normalized_file:-}" && -f "${normalized_file:-}" ]] && rm -f "$normalized_file"
```

## Design Notes

- **`wc -l` check:** Lightweight and reliable. A single JSON object is always 1 line
  (Claude Code output is compact JSON). JSONL is always >1 line by definition.
- **`jq -c 'select(.type == "result")'`:** Idiomatic jq for filtering JSONL. The `-c`
  ensures output stays on one line. `tail -1` handles the edge case of multiple result
  objects (takes the last/final one).
- **`mktemp` for normalized file:** Avoids modifying the original output file, which
  may be needed for debugging or the `_stream.log` backup.
- **Fallback `{}` object:** Prevents crash even if no result object exists. The
  downstream logic handles `UNKNOWN` status gracefully.
- **Session ID preservation:** The `type: "result"` object contains `session_id`
  (confirmed by Claude Code Agent SDK TypeScript type `SDKResultMessage`). If missing,
  falls back to the `system:init` event which also carries `session_id`. Uses snake_case
  `session_id` consistently (matching the SDK field name). This is required for
  `--continue`/`--resume` session continuity.

## Acceptance Criteria

- [ ] `parse_json_response` handles JSONL input without crashing
- [ ] Field extractions return single values (not N lines) on JSONL input
- [ ] Bash arithmetic operations succeed on extracted values
- [ ] `jq -n --argjson` construction succeeds with normalized values
- [ ] `.json_parse_result` file is written with valid JSON
- [ ] Log message indicates JSONL was detected and which extraction path was used
- [ ] Temp file is cleaned up on all code paths (success, failure, early return)

## Test Plan

```bash
# Unit test: JSONL with result object
@test "parse_json_response handles JSONL stream with result object" {
    # Create mock JSONL with multiple event types
    cat > "$TEST_DIR/stream.log" <<'EOF'
{"type":"system","session_id":"abc123"}
{"type":"assistant","message":{"content":[{"text":"Working..."}]}}
{"type":"stream_event","event":{"type":"content_block_delta"}}
{"type":"result","status":"SUCCESS","exit_signal":true,"confidence":85}
EOF

    run parse_json_response "$TEST_DIR/stream.log" "$TEST_DIR/result.json"
    assert_success

    # Verify single-value extraction
    run jq -r '.status' "$TEST_DIR/result.json"
    assert_output "SUCCESS"

    # Verify result file is valid JSON (single object)
    run jq -e 'type == "object"' "$TEST_DIR/result.json"
    assert_success
}

# Unit test: JSONL without result object
@test "parse_json_response handles JSONL stream without result object" {
    cat > "$TEST_DIR/stream.log" <<'EOF'
{"type":"system","session_id":"abc123"}
{"type":"assistant","message":{"content":[{"text":"Working..."}]}}
{"type":"stream_event","event":{"type":"content_block_delta"}}
EOF

    run parse_json_response "$TEST_DIR/stream.log" "$TEST_DIR/result.json"
    assert_success

    run jq -r '.status' "$TEST_DIR/result.json"
    assert_output "UNKNOWN"
}

# Unit test: single JSON object still works
@test "parse_json_response still handles single JSON object" {
    echo '{"type":"result","status":"SUCCESS","exit_signal":true}' > "$TEST_DIR/output.json"

    run parse_json_response "$TEST_DIR/output.json" "$TEST_DIR/result.json"
    assert_success

    run jq -r '.status' "$TEST_DIR/result.json"
    assert_output "SUCCESS"
}

# Regression test: 1466-line JSONL (reproduces original crash)
@test "parse_json_response does not crash on large JSONL file" {
    # Generate 1466 lines of JSONL mimicking real stream output
    for i in $(seq 1 1465); do
        echo "{\"type\":\"stream_event\",\"index\":$i}"
    done > "$TEST_DIR/large_stream.log"
    echo '{"type":"result","status":"SUCCESS","exit_signal":false,"confidence":70}' >> "$TEST_DIR/large_stream.log"

    run parse_json_response "$TEST_DIR/large_stream.log" "$TEST_DIR/result.json"
    assert_success

    # Verify no multi-line corruption
    local line_count
    line_count=$(wc -l < "$TEST_DIR/result.json" | tr -d '[:space:]')
    assert_equal "$line_count" "1"
}
```

## References

- jq 1.8 manual: [jqlang.org/manual](https://jqlang.org/manual/) -- "jq reads a
  sequence of whitespace-separated JSON values which are passed through the provided
  filter one at a time"
- JSONL spec: [ndjson.com/definition](https://ndjson.com/definition/) -- one JSON
  value per line, `\n` delimited
- Claude Code CLI: `--output-format stream-json` produces JSONL with event types
  `system`, `assistant`, `user`, `stream_event`, `result`, `rate_limit_event`
