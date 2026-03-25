# Story: USYNC-7 — Tmux Live Output: Sub-Agent Progress Display

> **Epic:** RALPH-USYNC (Upstream Sync) | **Priority:** Low | **Size:** S | **Status:** Done (already implemented in awk live filter, lines 2985-3010)
> **Upstream ref:** Issue #216, commit `f702543`

## Problem

When Ralph runs in `--live` mode with tmux, sub-agent activity (ralph-explorer, ralph-tester, ralph-reviewer, ralph-architect) is not visible in the live output pane. Operators see the main agent's tool calls but sub-agent progress is hidden, making it appear that Ralph is idle during delegated work.

Upstream PR #216 adds sub-agent progress display to the tmux live output filter.

## Solution

Update the live-mode awk stream filter to detect and display sub-agent events from the NDJSON stream.

## Implementation

### 1. Identify sub-agent event patterns in NDJSON

Sub-agent events appear in the JSONL stream with `subtype` or `parent_tool_use_id` fields. Identify the patterns:

```json
{"type": "assistant", "subtype": "agent", "agent_name": "ralph-tester", ...}
{"type": "tool_result", "parent_tool_use_id": "...", ...}
```

### 2. Update the awk live filter

The live-mode filter in `ralph_loop.sh` (the `awk` block that processes NDJSON for tmux display) should:

1. Detect sub-agent start events and display: `[sub-agent] ralph-tester started`
2. Show sub-agent tool calls with agent name prefix: `[ralph-tester] Bash: npm test`
3. Detect sub-agent completion and display: `[sub-agent] ralph-tester completed`

### 3. Suppress sub-agent noise

Not all sub-agent events need display. Filter to show:
- Agent start/stop
- Agent tool calls (file paths, commands)
- Agent errors

Suppress internal sub-agent metadata, intermediate text blocks, and other low-value events.

## Acceptance Criteria

- [ ] Sub-agent start events shown in tmux live output
- [ ] Sub-agent tool calls shown with agent name prefix
- [ ] Sub-agent completion shown with result summary
- [ ] Sub-agent metadata/noise suppressed
- [ ] Main agent events still display normally (no regression)
- [ ] Works with all 4 sub-agents (explorer, tester, reviewer, architect)

## Dependencies

- None (independent)

## Files to Modify

- `ralph_loop.sh` — update awk live stream filter
- `ralph_monitor.sh` — optionally update dashboard to show active sub-agents
