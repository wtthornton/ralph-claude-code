# Story CAPTURE-3: Fix Execution Stats Newline Parsing

**Epic:** [Stream Capture & Recovery](epic-stream-capture-recovery.md)
**Priority:** Low
**Status:** Pending
**Effort:** Trivial
**Component:** `ralph_loop.sh` (stats extraction)

---

## Problem

Execution stats output contains literal newlines, splitting across multiple log lines:

```
[INFO] Execution stats: Tools=0
0 Agents=0
0 Errors=0
0
```

Expected:
```
[INFO] Execution stats: Tools=42 Agents=3 Errors=2
```

**Root cause confirmed by:** tapps-brain logs 2026-03-21, 10+ stat lines split across entries.

## Solution

Strip newlines from the stats values before constructing the log message.

## Implementation

```bash
# Current (broken — values contain newlines from jq output):
local tools agents errors
tools=$(jq -r '.tools // 0' "$stats_source")
agents=$(jq -r '.agents // 0' "$stats_source")
errors=$(jq -r '.errors // 0' "$stats_source")
log "INFO" "Execution stats: Tools=$tools Agents=$agents Errors=$errors"

# Fixed — strip newlines and whitespace:
local tools agents errors
tools=$(jq -r '.tools // 0' "$stats_source" | tr -d '[:space:]')
agents=$(jq -r '.agents // 0' "$stats_source" | tr -d '[:space:]')
errors=$(jq -r '.errors // 0' "$stats_source" | tr -d '[:space:]')
log "INFO" "Execution stats: Tools=$tools Agents=$agents Errors=$errors"

# Alternative — single jq call (preferred for performance):
local stats_line
stats_line=$(jq -r '"Tools=\(.tools // 0) Agents=\(.agents // 0) Errors=\(.errors // 0)"' \
    "$stats_source" 2>/dev/null | tr -d '\n')
log "INFO" "Execution stats: $stats_line"
```

## Design Notes

- **Root cause**: The jq output likely includes trailing newlines or the source JSON has string values like `"0\n"` from the NDJSON extraction. `tr -d '[:space:]'` handles both.
- **Single jq call**: Reduces subprocess spawns from 3 to 1. Aligns with the existing subprocess batching optimization (v1.8.5).
- **`tr -d '\n'` vs `tr -d '[:space:]'`**: `\n` is safer if values might legitimately contain spaces, but these are numeric values so `[:space:]` is fine.

## Acceptance Criteria

- [ ] Execution stats always appear on a single log line
- [ ] Values are trimmed of whitespace/newlines
- [ ] Stats extraction uses a single jq call where possible

## Test Plan

```bash
@test "stats extraction produces single-line output" {
    echo '{"tools": 42, "agents": 3, "errors": 2}' > "$TEST_DIR/stats.json"
    source "$RALPH_DIR/ralph_loop.sh"

    local stats_line
    stats_line=$(jq -r '"Tools=\(.tools // 0) Agents=\(.agents // 0) Errors=\(.errors // 0)"' \
        "$TEST_DIR/stats.json" | tr -d '\n')
    assert_equal "$stats_line" "Tools=42 Agents=3 Errors=2"
}

@test "stats extraction handles newlines in values" {
    printf '{"tools": "42\\n", "agents": "3\\n", "errors": "2\\n"}' > "$TEST_DIR/stats.json"
    source "$RALPH_DIR/ralph_loop.sh"

    local tools
    tools=$(jq -r '.tools // 0' "$TEST_DIR/stats.json" | tr -d '[:space:]')
    assert_equal "$tools" "42"
}
```

## References

- [jq String Interpolation](https://jqlang.org/manual/#string-interpolation)
- [tr(1) man page](https://man7.org/linux/man-pages/man1/tr.1.html)
