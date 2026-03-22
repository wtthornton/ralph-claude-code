# Story RALPH-STREAM-1: Promote JSONL Parsing to Primary Path

**Epic:** [Stream Parser v2](epic-stream-parser-v2.md)
**Priority:** Medium
**Status:** Done
**Effort:** Small
**Component:** `ralph_loop.sh` (`ralph_emergency_jsonl_normalize`)

---

## Problem

The function `ralph_emergency_jsonl_normalize()` is the **normal** code path for Claude CLI
v2.1+, yet it's named "emergency" and logs a WARN on every invocation:

```
[WARN] Emergency JSONL extraction: converted multi-value stream to single result object
```

This fires on 100% of loops, creating log noise that masks genuine parsing failures. If a
real extraction error occurs, it looks identical to this routine warning.

## Solution

1. Rename `ralph_emergency_jsonl_normalize` → `ralph_extract_result_from_stream`
2. Change the success log from WARN to INFO and rename the message:
   - Before: `"Emergency JSONL extraction: converted multi-value stream to single result object"`
   - After: `"Stream extraction: isolated result object from JSONL stream"`
3. Add a structured log field `extraction_method` (value: `"stream"` or `"direct"`) so
   downstream log analysis can distinguish the paths without relying on message text
4. Keep the ERROR log for genuine failures (no valid result object found)
5. Update the backup file naming from `_stream.log` to keep current convention (no change needed)

## Implementation

### Change 1: `ralph_loop.sh` — Rename function and log messages

```bash
# BEFORE:
ralph_emergency_jsonl_normalize() {
    ...
    log_status "WARN" "Emergency JSONL extraction: converted multi-value stream to single result object"
    ...
    log_status "ERROR" "Emergency JSONL extraction failed: no valid result object in stream"

# AFTER:
ralph_extract_result_from_stream() {
    ...
    log_status "INFO" "Stream extraction: isolated result object from JSONL stream (extraction_method=stream)"
    ...
    log_status "ERROR" "Stream extraction failed: no valid result object in stream"
```

### Change 2: Update all call sites

Search for `ralph_emergency_jsonl_normalize` and update to `ralph_extract_result_from_stream`.

### Change 3: Update tests

Any tests referencing the old function name or log messages should be updated.

## Acceptance Criteria

- [ ] No "emergency" or "Emergency" in function names or log output for normal JSONL processing
- [ ] ERROR level still used for genuine extraction failures
- [ ] All existing tests pass with updated function name
- [ ] Log output distinguishes stream extraction from direct parsing
