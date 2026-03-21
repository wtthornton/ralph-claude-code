# Story RALPH-JSONL-2: Fix parse_json_response Return Code

**Epic:** [JSONL Stream Processing Resilience](epic-jsonl-stream-resilience.md)
**Priority:** Important
**Status:** Done
**Effort:** Trivial
**Component:** `lib/response_analyzer.sh` (`parse_json_response` function)

---

## Problem

`parse_json_response` unconditionally returns 0 (line 327), regardless of whether the
`jq -n` construction at lines 286-320 succeeded or produced valid output. The caller
at line 360 uses the return code to decide whether to trust the result:

```bash
if parse_json_response "$output_file" "$RALPH_DIR/.json_parse_result" 2>/dev/null; then
    json_confidence=$(jq -r '.confidence' $RALPH_DIR/.json_parse_result 2>/dev/null || echo "0")
    confidence_score=$((json_confidence + 50))
```

When the `jq -n` command fails (e.g., due to `--argjson` receiving multi-line
strings), it writes nothing to `$result_file`. But `return 0` tells the caller it
succeeded, so the caller reads from an empty or corrupt file and continues with
garbage data.

## Solution

Replace the unconditional `return 0` with a check that verifies the result file was
written and contains valid JSON.

## Implementation

In `response_analyzer.sh`, replace the final `return 0` (line 327) with:

```bash
# Verify the result file was written and is valid JSON
if [[ ! -s "$result_file" ]] || ! jq empty "$result_file" 2>/dev/null; then
    log_status "WARN" "parse_json_response: result file invalid or empty"
    [[ -n "${normalized_file:-}" && -f "${normalized_file:-}" ]] && rm -f "$normalized_file"
    return 1
fi

# Cleanup temp file
[[ -n "${normalized_file:-}" && -f "${normalized_file:-}" ]] && rm -f "$normalized_file"
return 0
```

## Design Notes

- **`-s` test:** Checks that the file exists AND is non-empty. Catches the case where
  `jq -n` fails silently and writes nothing.
- **`jq empty` validation:** Confirms the file contains parseable JSON. Catches
  partial writes or corrupted output.
- **`log_status WARN`:** Ensures the failure is visible in `ralph.log` instead of
  being silently swallowed by the caller's `2>/dev/null` on stderr.
- **Backward compatible:** The caller already has an `else` branch for when
  `parse_json_response` returns non-zero, so no caller changes needed.

## Acceptance Criteria

- [ ] `parse_json_response` returns 1 when `jq -n` fails to produce valid output
- [ ] `parse_json_response` returns 1 when result file is empty
- [ ] `parse_json_response` returns 0 only when result file contains valid JSON
- [ ] Warning is logged when result file is invalid
- [ ] Caller's `else` branch correctly handles the non-zero return

## Test Plan

```bash
@test "parse_json_response returns 1 on invalid input" {
    echo "not valid json at all" > "$TEST_DIR/bad_input.log"

    run parse_json_response "$TEST_DIR/bad_input.log" "$TEST_DIR/result.json"
    assert_failure
}

@test "parse_json_response returns 0 on valid single JSON" {
    echo '{"type":"result","status":"SUCCESS","exit_signal":true}' > "$TEST_DIR/good.json"

    run parse_json_response "$TEST_DIR/good.json" "$TEST_DIR/result.json"
    assert_success

    # Result file should exist and be valid JSON
    run jq empty "$TEST_DIR/result.json"
    assert_success
}

@test "parse_json_response returns 1 when jq construction fails" {
    # Simulate corrupted input that passes jq empty but breaks --argjson
    # (multi-line value in a field)
    printf '{"status":"line1\nline2"}\n' > "$TEST_DIR/corrupt.json"

    run parse_json_response "$TEST_DIR/corrupt.json" "$TEST_DIR/result.json"
    # Should return 1 because jq -n --argjson will fail
    assert_failure
}
```
