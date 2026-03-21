# Implementation Plan: Fix JSONL Crash in Live Mode

**Status:** Ready for implementation
**Blocking issue:** Ralph cannot loop in live mode on WSL2/Windows — every session dies silently after 1 loop
**Root spec:** `ralph-jsonl-crash-bug.md`
**Confirmed reproductions:** 3 (2026-03-21 07:59, 08:45, 08:48 — all identical crash pattern)

---

## Problem Statement

In live mode, Ralph's pipeline produces NDJSON output (one JSON object per line).
A stream extraction step is supposed to reduce this to a single `result` JSON object
before analysis. This extraction silently fails on WSL2/Windows (suspected NTFS
metadata race), leaving the raw NDJSON file. `parse_json_response` then processes
every line independently, corrupting all bash variables with multi-line values. The
script crashes silently — no error logged, no loop completed, no next loop started.

**Latest reproduction (2026-03-21 08:45):**
- Output file: 2309 lines of NDJSON, 1 result object
- No `_stream.log` backup created (extraction block never executed)
- ralph.log ends at "Analyzing Claude Code response..." with no further entries
- Identical to the 07:59 crash (5249 lines) and the original spec's example (1466 lines)

This is a **100% reproduction rate** on this environment. Every live mode run crashes.

---

## Changes Required

Four changes across two files. Fix 1 alone resolves the crash. Fixes 2-4 are
defense-in-depth.

### File 1: `~/.ralph/lib/response_analyzer.sh`

#### Fix 1: JSONL detection in `parse_json_response` [CRITICAL]

**Location:** After line 137 (end of array format handling), before line 139 (field extractions)

**What:** Detect when the input file is NDJSON (multiple JSON objects, one per line)
and extract only the last `type: "result"` object into a temp file. Redirect all
subsequent parsing to this single-object file.

**Why:** `jq` without `-s` (slurp) processes each NDJSON line independently. Every
`jq -r '.field'` call returns N values instead of 1, corrupting bash variables.
The array format handler (lines 107-137) already does something similar — this adds
the same pattern for NDJSON.

**Insert after line 137:**

```bash
    # Check if file is JSONL (multiple JSON objects, one per line)
    # This happens in live mode when stream extraction fails to reduce the file.
    # jq processes each object independently; without this guard, every field
    # extraction returns N values instead of 1, corrupting all downstream variables.
    local line_count
    line_count=$(wc -l < "$output_file" 2>/dev/null || echo "1")
    line_count=$((line_count + 0))  # Ensure integer

    if [[ $line_count -gt 1 ]]; then
        # JSONL detected -- extract the "result" type message for analysis
        normalized_file=$(mktemp)

        local result_obj
        result_obj=$(jq -c 'select(.type == "result")' "$output_file" 2>/dev/null | tail -1)

        if [[ -n "$result_obj" ]]; then
            echo "$result_obj" > "$normalized_file"

            # Extract session_id from init message as fallback
            local init_session_id
            init_session_id=$(jq -r 'select(.type == "system" and .subtype == "init") | .session_id // empty' "$output_file" 2>/dev/null | head -1)

            # Merge session_id into result if not already present
            local result_session_id
            result_session_id=$(echo "$result_obj" | jq -r '.session_id // .sessionId // empty' 2>/dev/null)
            if [[ -z "$result_session_id" || "$result_session_id" == "null" ]] && [[ -n "$init_session_id" ]]; then
                echo "$result_obj" | jq -c --arg sid "$init_session_id" '. + {sessionId: $sid}' > "$normalized_file"
            fi

            output_file="$normalized_file"
            [[ "${VERBOSE_PROGRESS:-}" == "true" ]] && \
                echo "DEBUG: JSONL detected ($line_count lines), extracted result object" >&2
        else
            # No result message found -- provide empty object so field extraction doesn't crash
            echo '{}' > "$normalized_file"
            output_file="$normalized_file"
            echo "WARN: JSONL detected ($line_count lines) but no result object found" >&2
        fi
    fi
```

**Verification:** After this block, `$output_file` points to a single JSON object.
All subsequent `jq -r '.field'` calls return exactly 1 value. No multi-line corruption.

---

#### Fix 2: Accurate return code from `parse_json_response` [IMPORTANT]

**Location:** Lines 320-327 (end of function)

**What:** Check whether the `jq -n` construction actually wrote a valid file. If not,
return 1 instead of hardcoded 0.

**Why:** Currently the function always returns 0 even when `jq -n --argjson` fails
(e.g., from corrupted variables). The caller (`analyze_response`) enters the
success branch and tries to read fields from an empty/missing `.json_parse_result`,
causing further silent failures.

**Replace lines 320-327:**

Current:
```bash
        }' > "$result_file"

    # Cleanup temporary normalized file if created (for array format handling)
    if [[ -n "$normalized_file" && -f "$normalized_file" ]]; then
        rm -f "$normalized_file"
    fi

    return 0
}
```

New:
```bash
        }' > "$result_file"

    local jq_exit=$?

    # Cleanup temporary normalized file if created (for array/JSONL format handling)
    if [[ -n "$normalized_file" && -f "$normalized_file" ]]; then
        rm -f "$normalized_file"
    fi

    # Return failure if jq construction failed or result file is empty
    if [[ $jq_exit -ne 0 || ! -s "$result_file" ]]; then
        echo "ERROR: Failed to construct analysis result (jq exit=$jq_exit)" >&2
        return 1
    fi

    return 0
}
```

---

### File 2: `~/.ralph/ralph_loop.sh`

#### Fix 3: Filesystem sync before extraction check [DEFENSIVE]

**Location:** Before line 1339 (the `# Extract session ID from stream-json output` comment)

**What:** Call `sync` and add a brief pause before checking if the output file exists.

**Why:** On WSL2 with NTFS mounts, `tee` writes data through the NTFS driver but
the file metadata (inode) may not be visible to a subsequent `[[ -f ]]` test
immediately. This is the suspected cause of the stream extraction block silently
skipping — the file exists on disk but the `-f` test returns false.

**Insert before line 1339:**

```bash
        # Ensure filesystem has flushed the tee output before checking file existence
        # WSL2/NTFS mount race: tee writes data but inode may not be visible to -f test
        # immediately. sync forces metadata flush; sleep gives NTFS driver time to propagate.
        sync 2>/dev/null || true
        sleep 0.5
```

---

#### Fix 4: Fallback JSONL extraction before analysis [DEFENSIVE]

**Location:** After line 1380 (end of the stream extraction if-block), before the
`else` at line 1381 that starts background mode. This is inside the
`if [[ "$LIVE_OUTPUT" == "true" ]]` block.

**What:** After the primary stream extraction, check if the output file is still
NDJSON. If so, perform an emergency extraction directly.

**Why:** Fix 3 reduces the race window but may not eliminate it. Fix 4 guarantees
that even if the primary extraction fails for any reason, the file is reduced to a
single JSON object before `analyze_response` processes it.

**Insert after line 1380 (`fi` closing the stream extraction block):**

```bash
        # Safety net: verify output file was reduced to single JSON object
        # If stream extraction failed (race condition, NTFS lag, or unknown cause),
        # the file is still raw NDJSON. Detect and fix before analyze_response crashes.
        if [[ -f "$output_file" ]]; then
            local post_extract_lines
            post_extract_lines=$(wc -l < "$output_file" 2>/dev/null || echo "1")
            if [[ $post_extract_lines -gt 5 ]]; then
                log_status "WARN" "Output file still has $post_extract_lines lines after extraction — attempting emergency JSONL fix"
                local emergency_result
                emergency_result=$(grep -E '"type"[[:space:]]*:[[:space:]]*"result"' "$output_file" 2>/dev/null | tail -1)
                if [[ -n "$emergency_result" ]] && echo "$emergency_result" | jq -e . >/dev/null 2>&1; then
                    # Back up stream if not already done
                    local backup="${output_file%.log}_stream.log"
                    if [[ ! -f "$backup" ]]; then
                        cp "$output_file" "$backup"
                    fi
                    echo "$emergency_result" > "$output_file"
                    log_status "INFO" "Emergency JSONL extraction successful — reduced to single result object"
                else
                    log_status "ERROR" "Emergency JSONL extraction failed — no valid result object found in $post_extract_lines-line file"
                fi
            fi
        fi
```

---

## Exact Edit Locations (current line numbers)

| Fix | File | Action | Anchor |
|-----|------|--------|--------|
| 1 | `response_analyzer.sh` | INSERT after line 137 | After `fi` closing the array format block, before line 139 (`# Detect JSON format`) |
| 2 | `response_analyzer.sh` | REPLACE lines 320-327 | From `}' > "$result_file"` through `return 0` / `}` |
| 3 | `ralph_loop.sh` | INSERT before line 1339 | Before `# Extract session ID from stream-json output` comment |
| 4 | `ralph_loop.sh` | INSERT after line 1380 | After the `fi` that closes `if [[ -f "$output_file" ]]`, before `else` at line 1381 |

---

## Interaction Between Fixes

```
Claude completes task
        |
        v
  [Pipeline: timeout | stdbuf claude | tee output | jq | tee live.log]
        |
        v
  Fix 3: sync + sleep 0.5    <-- reduces NTFS race window
        |
        v
  Primary stream extraction (existing code, lines 1342-1380)
  - cp to _stream.log
  - grep result line
  - overwrite output file
        |
   (may silently fail on WSL2/NTFS)
        |
        v
  Fix 4: check line count     <-- catches primary extraction failure
  - if still NDJSON, emergency grep + overwrite
  - creates _stream.log backup if missing
        |
        v
  analyze_response()
        |
        v
  parse_json_response()
        |
        v
  Fix 1: detect NDJSON        <-- last-resort defense if Fix 3+4 both fail
  - wc -l > 1? extract result object to temp file
  - redirect parsing to temp file
        |
        v
  Field extractions (jq -r '.field') now get 1 value each
        |
        v
  jq -n --argjson construction
        |
        v
  Fix 2: check jq exit code   <-- return 1 if construction fails
  - caller gets accurate success/failure signal
        |
        v
  .response_analysis written (or proper error logged)
        |
        v
  update_exit_signals / log_analysis_summary
        |
        v
  === Completed Loop #1 ===   <-- THIS IS WHAT WE NEED TO SEE
```

If all four fixes are applied, the crash is prevented at THREE independent layers:
- Fix 3+4 prevent the NDJSON from reaching `parse_json_response` at all
- Fix 1 handles it if NDJSON somehow still gets through
- Fix 2 ensures proper error propagation if everything else fails

---

## What Success Looks Like

**Before (current, broken):**
```
[08:48:48] [SUCCESS] Claude Code execution completed successfully
[08:48:48] [INFO] Analyzing Claude Code response...
<EOF - script dies>
```

**After (fixed):**
```
[08:48:48] [SUCCESS] Claude Code execution completed successfully
[08:48:48] [WARN] Output file still has 2309 lines after extraction — attempting emergency JSONL fix
[08:48:48] [INFO] Emergency JSONL extraction successful — reduced to single result object
[08:48:48] [INFO] Analyzing Claude Code response...
[08:48:49] [LOOP] === Completed Loop #1 ===
[08:48:49] [INFO] Loop #2 - calling init_call_tracking...
[08:48:49] [LOOP] === Starting Loop #2 ===
```

---

## Test Plan

### Unit test (manual, before deploying)

```bash
# 1. Create a mock NDJSON file from a real crash log
cp ~/.ralph/logs/claude_output_2026-03-21_08-45-22.log /tmp/test_jsonl.log

# 2. Source the response analyzer and test parse_json_response
source ~/.ralph/lib/response_analyzer.sh
RALPH_DIR=$(mktemp -d)

# 3. Run parse_json_response on NDJSON input
parse_json_response /tmp/test_jsonl.log "$RALPH_DIR/.json_parse_result"
echo "Exit code: $?"
cat "$RALPH_DIR/.json_parse_result" | jq .

# Expected: exit 0, single JSON object with exit_signal, status, etc.
# Before fix: exit 0 but empty/corrupt file
```

### Integration test

1. Apply all four fixes
2. Run `ralph --live` on TheStudio
3. Verify `ralph.log` shows:
   - "Completed Loop #1"
   - "Starting Loop #2"
   - Loop continues until task complete or circuit breaker
4. Verify `_stream.log` backup is created (Fix 4 creates it if Fix 3 doesn't)
5. Verify `.response_analysis` file exists and contains valid JSON after each loop
6. Run for 3+ consecutive loops to confirm stability

### Regression check

- Verify background mode (non-live) still works (these fixes don't touch that path)
- Verify array format JSON (non-NDJSON) still works (Fix 1 only triggers on line_count > 1)
- Verify single-object JSON still works (line_count == 1, Fix 1 skips)

---

## Risk Assessment

| Risk | Mitigation |
|------|-----------|
| Fix 1 temp file not cleaned up | `normalized_file` cleanup already exists at line 323 — covers both array and JSONL paths |
| Fix 3 `sleep 0.5` adds latency | 0.5s per loop is negligible vs 3-10 min per Claude invocation |
| Fix 4 emergency grep misses result | Same grep pattern as primary extraction (proven to work — we tested it manually) |
| Fix 2 breaks callers expecting return 0 | `analyze_response` already handles non-zero return: logs warning, falls through to text parsing |
| `wc -l` gives wrong count on Windows | NDJSON files from Claude CLI use LF line endings (confirmed via xxd). `wc -l` is reliable. |

---

## References

- Root cause analysis: `docs/specs/ralph-jsonl-crash-bug.md`
- Cascading failures analysis: `docs/specs/ralph-multi-task-loop-and-cascading-failures.md`
- Source: `~/.ralph/lib/response_analyzer.sh` (932 lines)
- Source: `~/.ralph/ralph_loop.sh` (2190 lines after previous permission-scan patch)
- Crash logs: `.ralph/logs/claude_output_2026-03-21_07-59-02.log` (5249 lines),
  `.ralph/logs/claude_output_2026-03-21_08-45-22.log` (2309 lines)
