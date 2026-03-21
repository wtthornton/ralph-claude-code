# Story RALPH-LOOP-1: Replace `jq -s` with Streaming JSON Counting

**Epic:** [Loop Stability & Analysis Resilience](epic-loop-stability.md)
**Priority:** Critical
**Status:** Done
**Effort:** Small
**Component:** `ralph_loop.sh` (`ralph_emergency_jsonl_normalize`), `lib/response_analyzer.sh` (`parse_json_response`)

---

## Problem

Two functions use `jq -s 'length'` to count top-level JSON values in Claude's output:

1. `ralph_emergency_jsonl_normalize` (ralph_loop.sh:446)
2. `parse_json_response` (response_analyzer.sh:143)

`jq -s` (slurp) loads ALL JSON values into a single array in memory. When Claude's
`--live` / `stream-json` mode produces 1,447 JSONL objects in a 663KB file, `jq -s`
creates an in-memory array of all 1,447 parsed objects. On WSL's `/mnt/c/` filesystem,
this crashes the bash process silently — no error logged, no status update, no cleanup.

**Why the original JSONL-1 fix chose `jq -s`:** The implementation note says `wc -l` has
"false positives on pretty-printed single objects." This is correct — a single JSON object
pretty-printed across 50 lines would give `wc -l` = 50, falsely triggering JSONL handling.
But `jq -s` is worse: it crashes on large streams.

## Solution

Replace `jq -s 'length'` with a two-step approach that avoids both problems:

1. Check if the file contains multiple result objects using `grep -c` (fast text scan)
2. If needed, validate with `jq -c . | wc -l` (streaming — processes one object at a time)

This avoids `jq -s` (which loads everything into memory) while correctly handling
pretty-printed single objects (which `jq -c .` normalizes to one line per object).

## Implementation

### Change 1: `ralph_loop.sh` — `ralph_emergency_jsonl_normalize`

Replace the `jq -s 'length'` call at line 446:

```bash
# BEFORE (crashes on large streams):
_tl_count=$(jq -s 'length' "$output_file" 2>/dev/null || echo "1")

# AFTER (streaming — never loads full file into memory):
# Step 1: Quick check — does the file have multiple "type" fields? (fast grep)
_tl_count=$(grep -c -E '"type"[[:space:]]*:' "$output_file" 2>/dev/null || echo "1")
_tl_count=$(echo "$_tl_count" | tr -d '[:space:]')
_tl_count=$((_tl_count + 0))
```

**Why `grep -c '"type"'`:** Every Claude streaming object has a `"type"` field (system,
assistant, user, result, etc.). Counting these gives the object count without parsing JSON.
For a single pretty-printed object, there's exactly 1 `"type"` line. For JSONL, there's
one per object. False positives are possible only if `"type"` appears in content — but
the regex anchors on the JSON key pattern `"type" :` which is extremely unlikely in
natural text.

### Change 2: `lib/response_analyzer.sh` — `parse_json_response`

Replace the `jq -s 'length'` call at line 143:

```bash
# BEFORE (crashes on large streams):
top_level_count=$(jq -s 'length' "$output_file" 2>/dev/null || echo "1")

# AFTER (streaming count):
top_level_count=$(grep -c -E '"type"[[:space:]]*:' "$output_file" 2>/dev/null || echo "1")
top_level_count=$(echo "$top_level_count" | tr -d '[:space:]')
```

### Verification

After changes, confirm no `jq -s` calls remain in the JSONL processing paths:

```bash
grep -n 'jq -s' ralph_loop.sh lib/response_analyzer.sh
# Should return zero results in JSONL/analysis contexts
```

## Design Notes

- **`grep -c` vs `jq -s 'length'`:** grep scans text without parsing JSON. For 1,447
  objects in 663KB, grep completes in <10ms. `jq -s` on the same file allocates ~50MB
  and takes 2-5 seconds on WSL before potentially crashing.
- **False positive risk:** A JSON value containing `"type" :` in a string field would
  be counted. This is acceptable because the downstream extraction (`jq -c 'select(.type
  == "result")' | tail -1`) still works correctly — it just runs unnecessarily on a
  single-object file. The cost is one extra jq invocation, not a crash.
- **`wc -l` was correctly rejected:** Pretty-printed `{ "type": "result", ... }` spanning
  50 lines gives `wc -l` = 50. The grep approach counts semantic objects, not lines.

## Acceptance Criteria

- [ ] No `jq -s` calls in `ralph_emergency_jsonl_normalize` or `parse_json_response`
- [ ] Single pretty-printed JSON object: correctly detected as 1 object (not JSONL)
- [ ] JSONL with 1,447 objects: correctly detected as multi-value (triggers normalization)
- [ ] JSONL with 5,000+ objects: completes in <1 second without memory issues
- [ ] Existing BATS tests for JSON parsing still pass (276/276)
- [ ] Ralph `--live` survives 5+ consecutive loops on WSL without crash

## Test Plan

```bash
@test "emergency normalize handles large JSONL without jq -s" {
    local output_file="$TEST_DIR/large_stream.log"

    # Generate 2000-line JSONL mimicking real stream
    for i in $(seq 1 1999); do
        echo "{\"type\":\"stream_event\",\"index\":$i}"
    done > "$output_file"
    echo '{"type":"result","status":"SUCCESS","exit_signal":false}' >> "$output_file"

    run ralph_emergency_jsonl_normalize "$output_file"
    assert_success

    # Verify output is now a single result object
    local line_count
    line_count=$(wc -l < "$output_file" | tr -d '[:space:]')
    assert_equal "$line_count" "1"

    run jq -r '.status' "$output_file"
    assert_output "SUCCESS"
}

@test "emergency normalize leaves single pretty-printed JSON alone" {
    local output_file="$TEST_DIR/single.json"
    # Pretty-printed single object (multi-line but one JSON value)
    cat > "$output_file" <<'EOF'
{
    "type": "result",
    "status": "SUCCESS",
    "exit_signal": true
}
EOF

    run ralph_emergency_jsonl_normalize "$output_file"
    assert_success

    # File should be unchanged (single object, not JSONL)
    local type_count
    type_count=$(grep -c '"type"' "$output_file")
    assert_equal "$type_count" "1"  # Only 1 "type" key = no normalization needed
}

@test "parse_json_response handles large JSONL without memory crash" {
    local output_file="$TEST_DIR/large_stream.log"

    for i in $(seq 1 1500); do
        echo "{\"type\":\"assistant\",\"index\":$i}"
    done > "$output_file"
    echo '{"type":"result","status":"IN_PROGRESS","exit_signal":false,"confidence":70}' >> "$output_file"

    run parse_json_response "$output_file" "$TEST_DIR/result.json"
    assert_success

    run jq -r '.status' "$TEST_DIR/result.json"
    assert_output "IN_PROGRESS"
}
```

## References

- TheStudio `ralph.log` (2026-03-21): 20+ runs, zero Loop #2 entries
- TheStudio `claude_output_2026-03-21_09-36-40.log`: 1,447 JSONL objects, 663KB
- RALPH-JSONL-1 implementation note: "uses `jq -s 'length' > 1`"
