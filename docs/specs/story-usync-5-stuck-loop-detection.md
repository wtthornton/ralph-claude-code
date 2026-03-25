# Story: USYNC-5 — Stuck-Loop Detection (Cross-Output Error Comparison)

> **Epic:** RALPH-USYNC (Upstream Sync) | **Priority:** Medium | **Size:** M | **Status:** Done
> **Upstream ref:** `lib/response_analyzer.sh` lines 781-827

## Problem

The upstream `detect_stuck_loop()` function compares error patterns across the 3 most recent output files. If the exact same set of errors appears in all 3 outputs AND the current output, the loop is declared "stuck" — meaning Claude is hitting the same wall repeatedly without making progress.

The fork's circuit breaker handles no-progress detection via the `consecutive_no_progress` counter and CBDECAY-1 sliding window, but does NOT perform cross-output error comparison. This means:

1. A loop producing different errors each time (genuine exploration) is indistinguishable from one producing the same error 5 times
2. The circuit breaker can't provide specific diagnostics like "stuck on: Permission denied on /etc/passwd" — it only knows "no progress for 3 loops"

## Solution

Implement stuck-loop detection as a lightweight function in `ralph_loop.sh` that runs after each iteration, comparing error fingerprints across recent outputs. Surface the result in `status.json` and use it for smarter circuit breaker decisions.

## Implementation

### 1. Add `detect_stuck_loop()` function to `ralph_loop.sh`

Port the upstream algorithm adapted to the fork's file layout:

```bash
detect_stuck_loop() {
    local current_output="$1"
    local history_dir="${RALPH_DIR}/logs"

    # Get 3 most recent output files (excluding current)
    local recent_files
    recent_files=$(ls -t "$history_dir"/claude_output_*.log 2>/dev/null | head -3)

    [[ -z "$recent_files" ]] && return 1  # Not enough history

    # Extract error lines from current output (filter out JSON field false positives)
    local current_errors
    current_errors=$(grep -v '"[^"]*error[^"]*":' "$current_output" 2>/dev/null \
        | grep -E '(^Error:|^ERROR:|^error:|\]: error|Error occurred|failed with error|[Ee]xception|Fatal|FATAL)' \
        | sort | uniq)

    [[ -z "$current_errors" ]] && return 1  # No errors = not stuck

    # Check if ALL recent files contain ALL current errors
    local all_match=true
    while IFS= read -r file; do
        while IFS= read -r error_line; do
            if ! grep -qF "$error_line" "$file" 2>/dev/null; then
                all_match=false
                break 2
            fi
        done <<< "$current_errors"
    done <<< "$recent_files"

    [[ "$all_match" == "true" ]]
}
```

### 2. Surface in `status.json`

Update `on-stop.sh` or add a post-analysis step in the loop to write:

```json
{
  "is_stuck": true,
  "stuck_errors": ["Error: EACCES permission denied /etc/passwd"]
}
```

### 3. Integrate with circuit breaker

When stuck-loop is detected, the circuit breaker should trip with a descriptive reason including the repeating error pattern. This is more actionable than "no progress for N loops."

### 4. Integration point in main loop

Call `detect_stuck_loop` after the on-stop.sh hook has written `status.json` and before the next iteration begins:

```bash
if detect_stuck_loop "$output_file"; then
    log_status "WARN" "Stuck loop detected: same errors in last 3+ outputs"
    # Update status.json with stuck state
    # Let circuit breaker handle the rest
fi
```

## Acceptance Criteria

- [ ] `detect_stuck_loop()` compares error patterns across last 3 output files
- [ ] JSON field patterns (e.g., `"is_error": false`) are filtered out to avoid false positives
- [ ] Returns true only when ALL errors in current output appear in ALL 3 recent files
- [ ] Returns false when no errors are present (not stuck)
- [ ] Returns false when fewer than 3 history files exist (insufficient data)
- [ ] `status.json` includes `is_stuck` flag and `stuck_errors` array when detected
- [ ] Circuit breaker trip reason includes the stuck error pattern
- [ ] BATS test: 4 identical error outputs → stuck detected
- [ ] BATS test: 4 different error outputs → not stuck
- [ ] BATS test: 3 error outputs + 1 clean → not stuck
- [ ] BATS test: JSON field "error" in output → not a false positive

## Dependencies

- None (independent of other USYNC stories)

## Files to Modify

- `ralph_loop.sh` — add `detect_stuck_loop()` function and call site
- `templates/hooks/on-stop.sh` — optionally surface stuck state in status.json
- `tests/unit/test_exit_detection.bats` — add stuck-loop detection tests
