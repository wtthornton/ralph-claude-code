# Story RALPH-MULTI-5: Warn on Multiple Result Objects in Stream

**Epic:** [Multi-Task Loop Violation and Cascading Failures](epic-multi-task-cascading-failures.md)
**Priority:** Medium
**Status:** Done
**Effort:** Trivial
**Components:** `lib/response_analyzer.sh`, `ralph_loop.sh`

---

## Problem

When Claude completes multiple tasks in one loop invocation (violating the execution
contract), the NDJSON output contains multiple `type: "result"` objects. This has
two effects:

### JSON path (parse_json_response)
The JSONL detection code (RALPH-JSONL-1) uses `jq -c 'select(.type == "result")' |
tail -1` to extract the last result. This silently discards earlier result objects
without warning. The operator has no visibility into the multi-task violation.

### Text fallback path (analyze_response)
The text parser uses `grep "EXIT_SIGNAL:" | cut -d: -f2 | xargs` which concatenates
values from all RALPH_STATUS blocks. With two blocks, `exit_sig` becomes `"false false"`
which doesn't match `"true"` -- correct by accident, but fragile. If one task set
`EXIT_SIGNAL: true` and the other `false`, the joined value `"true false"` would
fail to match `"true"`, potentially suppressing a valid completion signal.

## Solution

Add result object counting in two places:

### In response_analyzer.sh (JSONL detection path)

Add after extracting `result_obj` in the JSONL handler (RALPH-JSONL-1):

```bash
# Count result objects -- multiple results indicate multi-task violation
local result_count
result_count=$(jq -c 'select(.type == "result")' "$output_file" 2>/dev/null | wc -l | tr -d '[:space:]')
result_count="${result_count:-1}"
if [[ "$result_count" -gt 1 ]]; then
    log_status "WARN" "Multiple result objects found ($result_count). Claude may have completed multiple tasks in one loop. Using last result."
fi
```

### In ralph_loop.sh (fallback extraction path, RALPH-JSONL-4)

Add result counting to the emergency extraction:

```bash
# Count results in the JSONL
local _result_count
_result_count=$(grep -c '"type"[[:space:]]*:[[:space:]]*"result"' "$output_file" 2>/dev/null || echo "0")
if [[ "$_result_count" -gt 1 ]]; then
    log_status "WARN" "Stream contains $_result_count result objects (expected 1). Multi-task loop violation detected."
fi
```

### In response_analyzer.sh (text fallback path)

Fix the text parser to handle multiple RALPH_STATUS blocks by taking only the last one:

```bash
# Text parsing fallback -- take only the LAST status block to handle multi-result streams
local status exit_sig
if grep -q -- "---RALPH_STATUS---" "$output_file"; then
    # Extract only the last RALPH_STATUS block
    local last_block
    last_block=$(awk '/---RALPH_STATUS---/{found=1; block=""} found{block=block"\n"$0} /---END_RALPH_STATUS---/{found=0; last=block} END{print last}' "$output_file")

    status=$(echo "$last_block" | grep "STATUS:" | tail -1 | cut -d: -f2 | xargs)
    exit_sig=$(echo "$last_block" | grep "EXIT_SIGNAL:" | tail -1 | cut -d: -f2 | xargs)
```

## Design Notes

- **Warning, not error:** Multi-task execution is a prompt violation, not a system
  error. The results are usually valid. A warning provides observability without
  disrupting the loop.
- **"Using last result"** matches the existing `.[-1]` behavior in the JSON parser
  and `tail -1` in grep extraction. The last result is the most complete (cumulative
  cost, total turns).
- **Text parser fix:** The `awk` approach extracts only the last RALPH_STATUS block,
  preventing value concatenation. `tail -1` on STATUS/EXIT_SIGNAL lines within that
  block handles edge cases.

## Acceptance Criteria

- [ ] Warning logged when >1 result object found in JSONL
- [ ] Warning logged when >1 RALPH_STATUS block found in text fallback
- [ ] Text parser extracts values from the last RALPH_STATUS block only
- [ ] `exit_sig` is a single value ("true" or "false"), not joined ("true false")
- [ ] Single-result streams produce no warning (no false positives)

## Test Plan

```bash
@test "warns on multiple result objects in JSONL" {
    local output_file="$TEST_DIR/dual_result.log"
    echo '{"type":"result","status":"IN_PROGRESS","exit_signal":false}' > "$output_file"
    echo '{"type":"result","status":"SUCCESS","exit_signal":true}' >> "$output_file"

    local result_count
    result_count=$(jq -c 'select(.type == "result")' "$output_file" | wc -l | tr -d '[:space:]')
    assert_equal "$result_count" "2"
}

@test "text parser extracts last RALPH_STATUS block only" {
    local output_file="$TEST_DIR/dual_status.log"
    cat > "$output_file" <<'EOF'
---RALPH_STATUS---
STATUS: IN_PROGRESS
EXIT_SIGNAL: false
---END_RALPH_STATUS---
Some text between blocks
---RALPH_STATUS---
STATUS: COMPLETE
EXIT_SIGNAL: true
---END_RALPH_STATUS---
EOF

    # Using awk to extract last block
    local last_block
    last_block=$(awk '/---RALPH_STATUS---/{found=1; block=""} found{block=block"\n"$0} /---END_RALPH_STATUS---/{found=0; last=block} END{print last}' "$output_file")

    local exit_sig
    exit_sig=$(echo "$last_block" | grep "EXIT_SIGNAL:" | tail -1 | cut -d: -f2 | xargs)
    assert_equal "$exit_sig" "true"
}

@test "single RALPH_STATUS block produces no warning" {
    local output_file="$TEST_DIR/single_status.log"
    cat > "$output_file" <<'EOF'
---RALPH_STATUS---
STATUS: COMPLETE
EXIT_SIGNAL: true
---END_RALPH_STATUS---
EOF

    local block_count
    block_count=$(grep -c "---RALPH_STATUS---" "$output_file")
    assert_equal "$block_count" "1"
}
```

## Dependencies

- **RALPH-JSONL-1:** The JSONL detection code is where the JSON-path warning is added.
  This story extends RALPH-JSONL-1 with result counting.
- **RALPH-MULTI-1:** The stop instruction fix prevents multi-task violations at the
  source. This story provides observability when violations still occur.
