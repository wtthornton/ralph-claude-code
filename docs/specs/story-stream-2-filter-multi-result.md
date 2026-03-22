# Story RALPH-STREAM-2: Filter Multi-Result Count by Parent Context

**Epic:** [Stream Parser v2](epic-stream-parser-v2.md)
**Priority:** Medium
**Status:** Done
**Effort:** Trivial
**Component:** `ralph_loop.sh` (`ralph_emergency_jsonl_normalize` → `ralph_extract_result_from_stream`)

---

## Problem

Lines 480-486 of `ralph_loop.sh` count ALL `"type":"result"` objects in the JSONL stream:

```bash
_result_count=$(grep -c -E '"type"[[:space:]]*:[[:space:]]*"result"' "$output_file")
if [[ "$_result_count" -gt 1 ]]; then
    log_status "WARN" "Stream contains $_result_count result objects (expected 1). Multi-task loop violation detected."
fi
```

When Claude uses background agents (ralph-tester, ralph-explorer, or Claude's native Agent
tool), each agent completion emits its own result object. These are **subagent results**, not
top-level results. The warning fires as a false positive — observed in 3/6 loops on 2026-03-21.

Every affected loop's `RALPH_STATUS` block correctly reports `TASKS_COMPLETED_THIS_LOOP: 1`
and produces exactly one commit.

## Solution

Filter result objects to only count **top-level** results. Subagent result objects contain a
`subagent` or `parent_tool_use_id` field (or are wrapped in a tool result context). The
top-level result is the one with no parent context.

### Approach A: Filter by `subagent` field (preferred if available in stream)

```bash
# Count only top-level result objects (no subagent field)
_result_count=$(jq -c 'select(.type == "result") | select(.subagent == null)' "$output_file" 2>/dev/null | wc -l)
```

### Approach B: Use `tail -1` and skip the warning for expected subagent patterns

If the stream format doesn't reliably distinguish subagent results, check `modelUsage` for
multi-model patterns (Haiku/Sonnet alongside Opus) and suppress the warning when subagent
usage is detected:

```bash
_has_subagents=$(jq -c 'select(.type == "result") | select(.model != null) | .model' "$output_file" 2>/dev/null | sort -u | wc -l)
if [[ "$_result_count" -gt 1 && "$_has_subagents" -le 1 ]]; then
    log_status "WARN" "Stream contains $_result_count result objects (expected 1). Multi-task loop violation detected."
elif [[ "$_result_count" -gt 1 ]]; then
    log_status "INFO" "Stream contains $_result_count result objects ($_has_subagents models detected — subagent results expected)"
fi
```

### Implementation Note

Investigate the actual JSONL stream format from a loop with subagents (backup files in
`.ralph/logs/*_stream.log`) to determine which fields distinguish subagent results from
top-level results before choosing Approach A or B.

## Acceptance Criteria

- [ ] Multi-task violation warning does NOT fire when subagents produce additional result objects
- [ ] Multi-task violation warning DOES fire when multiple top-level results exist (genuine violation)
- [ ] Subagent result count is logged at INFO level for observability
- [ ] Test with mock JSONL containing both subagent and top-level results
