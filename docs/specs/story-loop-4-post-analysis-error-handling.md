# Story RALPH-LOOP-4: Add Error Handling to Post-Analysis Pipeline

**Epic:** [Loop Stability & Analysis Resilience](epic-loop-stability.md)
**Priority:** Medium
**Status:** Done
**Effort:** Small
**Component:** `ralph_loop.sh` (`execute_claude_code`), `lib/response_analyzer.sh` (`update_exit_signals`, `log_analysis_summary`), `lib/circuit_breaker.sh` (`record_loop_result`)

---

## Problem

After `analyze_response` completes, four functions run in sequence without error checking.
If any crashes silently, `execute_claude_code` never returns, and the main loop never
reaches iteration 2:

```bash
# ralph_loop.sh, lines 1625-1708:
analyze_response "$output_file" "$loop_count"    # return code checked ✓
update_exit_signals                               # return code NOT checked ✗
log_analysis_summary                              # return code NOT checked ✗
record_loop_result "$loop_count" ...              # return code checked ✓
```

Each function uses multiple `jq` calls on `.response_analysis` and `.circuit_breaker_state`.
If either file is empty, malformed, or missing, jq produces errors that are swallowed
by `2>/dev/null`. Variables become empty strings, arithmetic fails, and the function
may crash in unpredictable ways.

### Specific vulnerabilities

1. **`update_exit_signals`** (response_analyzer.sh:778-829): Reads `.response_analysis`
   with `jq -r`. If the file is empty (from a failed `analyze_response`), all variables
   become empty/null. The function then tries `jq ".test_only_loops += [$loop_number]"`
   where `$loop_number` could be empty — producing invalid JSON that corrupts
   `.exit_signals`.

2. **`log_analysis_summary`** (response_analyzer.sh:832-855): Return code not checked
   at call site (ralph_loop.sh:1633). If `.response_analysis` is missing, returns 1
   but the caller ignores it.

3. **`record_loop_result`** (circuit_breaker.sh:151-336): If `.circuit_breaker_state`
   is corrupted by a previous crash, jq parsing fails. The heredoc write at line 320
   uses `$variable` interpolation — empty variables produce invalid JSON, corrupting
   the state file for all future loops.

## Solution

Add defensive checks at each step:

1. Guard `update_exit_signals` and `log_analysis_summary` calls with return code checks
2. Validate jq output before writing to state files
3. Add a fallback path that allows the loop to continue even when analysis fails

## Implementation

### Change 1: `ralph_loop.sh` — Guard post-analysis calls

```bash
# After analyze_response (around line 1628):
if [[ $analysis_exit_code -eq 0 ]]; then
    # Update exit signals based on analysis
    if ! update_exit_signals; then
        log_status "WARN" "Exit signal update failed; continuing with stale signals"
    fi

    # Log analysis summary
    if ! log_analysis_summary; then
        log_status "WARN" "Analysis summary logging failed; non-critical, continuing"
    fi
else
    log_status "WARN" "Response analysis failed (exit $analysis_exit_code); skipping signal updates"
    rm -f "$RESPONSE_ANALYSIS_FILE"
fi
```

### Change 2: `lib/response_analyzer.sh` — Validate jq in `update_exit_signals`

```bash
update_exit_signals() {
    local analysis_file=${1:-"$RALPH_DIR/.response_analysis"}
    local exit_signals_file=${2:-"$RALPH_DIR/.exit_signals"}

    if [[ ! -f "$analysis_file" ]] || ! jq empty "$analysis_file" 2>/dev/null; then
        log_status "WARN" "Cannot update exit signals: analysis file missing or invalid"
        return 1
    fi

    # ... existing logic with validated input ...
}
```

### Change 3: `lib/circuit_breaker.sh` — Validate state before write

In `record_loop_result`, validate the constructed JSON before writing:

```bash
# Before writing to CB_STATE_FILE (around line 320):
local _new_state_json
_new_state_json=$(jq -n \
    --arg state "$new_state" \
    --arg last_change "$(get_iso_timestamp)" \
    ... )

# Validate before writing
if echo "$_new_state_json" | jq empty 2>/dev/null; then
    echo "$_new_state_json" > "$CB_STATE_FILE"
else
    log_status "ERROR" "Circuit breaker state construction failed; preserving existing state"
    return 0  # Don't trip circuit breaker on internal error
fi
```

## Design Notes

- **Fail-open, not fail-closed:** When post-analysis functions fail, the loop should
  CONTINUE (fail-open) rather than halt (fail-closed). Analysis failure means we
  don't have accurate signals, but halting wastes more time than continuing.
- **No `set -e`:** The script intentionally avoids `set -e` for resilience. These
  changes add explicit error handling instead of relying on bash's error mode.
- **State file validation:** Using `jq empty` (zero-output validation) before writing
  prevents corrupted JSON from propagating to the next loop iteration.

## Acceptance Criteria

- [ ] `update_exit_signals` failure logged and loop continues
- [ ] `log_analysis_summary` failure logged and loop continues
- [ ] `record_loop_result` validates JSON before writing `.circuit_breaker_state`
- [ ] Empty/malformed `.response_analysis` does not crash post-analysis pipeline
- [ ] Loop reaches iteration 2 even when analysis produces empty output
- [ ] Existing BATS tests still pass

## Test Plan

```bash
@test "loop continues when update_exit_signals fails on empty analysis" {
    echo "" > "$RALPH_DIR/.response_analysis"  # Empty file

    run update_exit_signals "$RALPH_DIR/.response_analysis" "$RALPH_DIR/.exit_signals"
    assert_failure  # Returns 1

    # Exit signals should be unchanged (not corrupted)
    run jq -e '.' "$RALPH_DIR/.exit_signals"
    assert_success
}

@test "circuit breaker state preserved on construction failure" {
    # Write valid initial state
    echo '{"state":"CLOSED","consecutive_no_progress":0}' > "$CB_STATE_FILE"

    # Force construction failure by passing empty variables
    run record_loop_result "" "" "" ""
    # Should not corrupt the state file
    run jq -r '.state' "$CB_STATE_FILE"
    assert_output "CLOSED"
}
```
