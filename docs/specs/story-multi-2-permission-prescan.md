# Story RALPH-MULTI-2: Add Pre-Analysis Permission Denial Scan

**Epic:** [Multi-Task Loop Violation and Cascading Failures](epic-multi-task-cascading-failures.md)
**Priority:** High
**Status:** Done
**Effort:** Small
**Component:** `ralph_loop.sh` (after Claude execution, before `analyze_response`)

---

## Problem

Permission denial detection depends on `.response_analysis` being written by
`analyze_response`. When `analyze_response` crashes (e.g., on JSONL input), the
`.response_analysis` file is never created. The `should_exit_gracefully` function
checks `[[ -f "$RESPONSE_ANALYSIS_FILE" ]]` and skips the permission check entirely.

In the March 21 incident, 5 permission denials went completely undetected. The user
received no feedback about ALLOWED_TOOLS gaps. The same denials would recur on the
next run.

## Solution

Add a lightweight permission denial scan that runs directly on the raw output file
**before** `analyze_response`. This scan is independent of the JSON/JSONL parsing
pipeline and survives analysis crashes.

The scan is **informational only** -- it logs warnings but does not halt the loop.
The actual halt decision remains in `should_exit_gracefully` after analysis completes.
This ensures the user sees permission denial warnings in `ralph.log` even when
analysis fails.

## Implementation

In `ralph_loop.sh`, add after "Claude Code execution completed" log message (around
line 1521) and before the `analyze_response` call:

```bash
# Pre-analysis permission denial scan (survives analysis crashes)
# Extracts denials directly from raw output, independent of parse_json_response
if [[ -f "$output_file" ]]; then
    local _raw_result
    _raw_result=$(grep -E '"type"[[:space:]]*:[[:space:]]*"result"' "$output_file" 2>/dev/null | tail -1)

    if [[ -n "$_raw_result" ]]; then
        local _denial_count
        _denial_count=$(echo "$_raw_result" | jq '.permission_denials | if . then length else 0 end' 2>/dev/null || echo "0")
        _denial_count=$((_denial_count + 0))  # Ensure integer

        if [[ $_denial_count -gt 0 ]]; then
            local _denied_cmds
            _denied_cmds=$(echo "$_raw_result" | jq -r \
                '[.permission_denials[] |
                  if .tool_name == "Bash"
                  then "Bash(\(.tool_input.command // "?" | split("\n")[0] | .[0:60]))"
                  else .tool_name // "unknown"
                  end
                ] | join(", ")' 2>/dev/null || echo "unknown")

            log_status "WARN" "Permission denied for $_denial_count command(s): $_denied_cmds"
            log_status "WARN" "Update ALLOWED_TOOLS in .ralphrc to include the required tools"
        fi
    fi
fi
```

## Design Notes

- **Why not use `jq -c 'select(.type == "result")'`?** The scan intentionally uses
  `grep` instead of `jq` on the full file. If the file is JSONL (thousands of lines),
  `jq` would process every line. `grep | tail -1` is O(N) text scan but avoids
  spawning jq on the full file. For a 5000-line file, grep is ~10x faster.
- **`tail -1`:** Takes the last result object, matching the behavior of the JSON
  parser (which uses `.[-1]`).
- **Informational only:** Does not set any state or halt the loop. The halt decision
  is in `should_exit_gracefully` which already handles permission denials correctly
  when `.response_analysis` exists.
- **Survives JSONL crash:** This code runs before `analyze_response` and does not
  depend on the parsing pipeline at all.

## Acceptance Criteria

- [ ] Permission denials are logged even when `analyze_response` crashes
- [ ] Denied command names are extracted and shown in the warning
- [ ] Warning suggests updating ALLOWED_TOOLS in .ralphrc
- [ ] Scan does not modify any state files or affect loop flow
- [ ] Scan handles missing output file gracefully (no error)
- [ ] Scan handles output file with no result object (no false positive)

## Test Plan

```bash
@test "pre-analysis scan detects permission denials in JSONL output" {
    local output_file="$TEST_DIR/claude_output.log"

    # Create JSONL with permission denials in result object
    echo '{"type":"stream_event","index":1}' > "$output_file"
    cat >> "$output_file" <<'EOF'
{"type":"result","subtype":"success","permission_denials":[{"tool_name":"Bash","tool_input":{"command":"git -C /path add file.txt"}},{"tool_name":"Bash","tool_input":{"command":"grep -r pattern /src"}}]}
EOF

    # Run the pre-analysis scan logic
    local _raw_result
    _raw_result=$(grep -E '"type"[[:space:]]*:[[:space:]]*"result"' "$output_file" | tail -1)
    local _denial_count
    _denial_count=$(echo "$_raw_result" | jq '.permission_denials | length' 2>/dev/null)

    assert_equal "$_denial_count" "2"
}

@test "pre-analysis scan handles output with no permission denials" {
    local output_file="$TEST_DIR/claude_output.log"
    echo '{"type":"result","subtype":"success","permission_denials":[]}' > "$output_file"

    local _raw_result
    _raw_result=$(grep -E '"type"[[:space:]]*:[[:space:]]*"result"' "$output_file" | tail -1)
    local _denial_count
    _denial_count=$(echo "$_raw_result" | jq '.permission_denials | if . then length else 0 end' 2>/dev/null)

    assert_equal "$_denial_count" "0"
}

@test "pre-analysis scan handles missing output file" {
    local output_file="$TEST_DIR/nonexistent.log"

    # Should not error
    if [[ -f "$output_file" ]]; then
        fail "File should not exist"
    fi
}
```
