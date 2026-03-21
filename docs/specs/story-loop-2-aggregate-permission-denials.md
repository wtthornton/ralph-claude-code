# Story RALPH-LOOP-2: Aggregate Permission Denials Across All Result Objects

**Epic:** [Loop Stability & Analysis Resilience](epic-loop-stability.md)
**Priority:** High
**Status:** Done
**Effort:** Small
**Component:** `ralph_loop.sh` (`ralph_log_permission_denials_from_raw_output`), `lib/response_analyzer.sh` (`parse_json_response`)

---

## Problem

When Claude spawns background agents (e.g., for ESLint), the output file contains
**multiple `type: "result"` objects** — one per Claude invocation. The permission denial
extraction uses `tail -1` to get the last result object. But background agents complete
AFTER the main work and their results have `permission_denials: []`. The FIRST result
(from the main work) may have actual denials that are silently ignored.

**Observed in production (2026-03-21 TheStudio):**

```json
// First result (main work) — 2 denials:
{"type":"result", "permission_denials":[
  {"tool_name":"Bash","tool_input":{"command":"find ... | xargs ls -la"}},
  {"tool_name":"Bash","tool_input":{"command":"cd /path && git add && git commit"}}
]}

// Second result (background ESLint) — 0 denials:
{"type":"result", "permission_denials":[]}

// Third result (background ESLint) — 0 denials:
{"type":"result", "permission_denials":[]}
```

Both `ralph_log_permission_denials_from_raw_output` (pre-scan) and `parse_json_response`
use `tail -1`, extracting the last result with 0 denials. The 2 actual denials are lost.

## Solution

Aggregate `permission_denials` arrays from ALL result objects, not just the last one.

## Implementation

### Change 1: `ralph_loop.sh` — `ralph_log_permission_denials_from_raw_output`

Replace the `tail -1` extraction with aggregation across all results:

```bash
ralph_log_permission_denials_from_raw_output() {
    local output_file=$1
    [[ -f "$output_file" ]] || return 0

    # Aggregate permission_denials from ALL result objects (not just last)
    local _denial_count=0
    local _denied_cmds=""

    while IFS= read -r _result_line; do
        local _line_denials
        _line_denials=$(echo "$_result_line" | jq '.permission_denials | if . then length else 0 end' 2>/dev/null || echo "0")
        _line_denials=$((_line_denials + 0))
        _denial_count=$((_denial_count + _line_denials))

        if [[ $_line_denials -gt 0 ]]; then
            local _line_cmds
            _line_cmds=$(echo "$_result_line" | jq -r \
                '[.permission_denials[] |
                  if .tool_name == "Bash"
                  then "Bash(\(.tool_input.command // "?" | split("\n")[0] | .[0:60]))"
                  else .tool_name // "unknown"
                  end
                ] | join(", ")' 2>/dev/null || echo "unknown")
            if [[ -n "$_denied_cmds" ]]; then
                _denied_cmds="$_denied_cmds, $_line_cmds"
            else
                _denied_cmds="$_line_cmds"
            fi
        fi
    done < <(grep -E '"type"[[:space:]]*:[[:space:]]*"result"' "$output_file" 2>/dev/null)

    [[ $_denial_count -gt 0 ]] || return 0

    log_status "WARN" "Permission denied for $_denial_count command(s): $_denied_cmds"
    log_status "WARN" "Update ALLOWED_TOOLS in .ralphrc to include the required tools"
}
```

### Change 2: `lib/response_analyzer.sh` — `parse_json_response`

After extracting the last result object for field parsing, also aggregate permission
denials from all results:

```bash
# After extracting result_obj (the last result for status/exit_signal/etc.),
# aggregate permission_denials from ALL result objects
local all_denials_json
all_denials_json=$(grep -E '"type"[[:space:]]*:[[:space:]]*"result"' "$output_file" 2>/dev/null | \
    jq -s '[.[].permission_denials[]?]' 2>/dev/null || echo "[]")

local total_denial_count
total_denial_count=$(echo "$all_denials_json" | jq 'length' 2>/dev/null || echo "0")
total_denial_count=$((total_denial_count + 0))
```

Then use `total_denial_count` and `all_denials_json` instead of the single-result values
when writing the analysis result.

## Design Notes

- **Why aggregate instead of using the first result?** The first result isn't always the
  "main" result. In session continuity mode, Claude may resume a prior session (first
  result) and then do new work (second result). Aggregation catches denials from any
  invocation.
- **`jq -s` on grep output is safe:** The `grep | jq -s` pipeline only loads the result
  lines (typically 1-4 lines, <1KB each), not the entire 1,447-line stream. This is
  bounded and safe.
- **Backward compatible:** When there's only 1 result object, the aggregation produces
  identical output to `tail -1`.

## Acceptance Criteria

- [ ] Permission denials from the FIRST result object are detected when the LAST has none
- [ ] Permission denials from ALL result objects are aggregated (no duplicates)
- [ ] Pre-scan (`ralph_log_permission_denials_from_raw_output`) uses aggregation
- [ ] Analysis (`parse_json_response`) writes aggregated denial count to `.response_analysis`
- [ ] Existing single-result behavior is unchanged (backward compatible)

## Test Plan

```bash
@test "pre-scan aggregates denials across multiple result objects" {
    local output_file="$TEST_DIR/multi_result.log"
    cat > "$output_file" <<'EOF'
{"type":"system","session_id":"abc123"}
{"type":"result","permission_denials":[{"tool_name":"Bash","tool_input":{"command":"find /src | xargs ls"}}]}
{"type":"system","session_id":"abc123"}
{"type":"result","permission_denials":[]}
{"type":"result","permission_denials":[]}
EOF

    source "$SCRIPT_DIR/ralph_loop.sh"
    run ralph_log_permission_denials_from_raw_output "$output_file"

    # Should detect 1 denial (from first result), not 0 (from last result)
    assert_output --partial "Permission denied for 1 command"
}

@test "pre-scan handles output with no result objects" {
    local output_file="$TEST_DIR/no_result.log"
    echo '{"type":"system","session_id":"abc123"}' > "$output_file"

    run ralph_log_permission_denials_from_raw_output "$output_file"
    assert_success
    refute_output --partial "Permission denied"
}
```
