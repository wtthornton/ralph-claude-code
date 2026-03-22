# Epic: Stream Capture & Recovery

**Epic ID:** RALPH-CAPTURE
**Priority:** High
**Affects:** Loop state awareness, error recovery, log quality
**Components:** `ralph_loop.sh` (stream pipeline, stats extraction, multi-result handling)
**Related specs:** [epic-jsonl-stream-resilience.md](epic-jsonl-stream-resilience.md), [epic-stream-parser-v2.md](epic-stream-parser-v2.md)
**Depends on:** None
**Target Version:** v1.9.0

---

## Problem Statement

Three related stream-handling issues degrade Ralph's ability to understand what happened during each loop iteration:

### Issue 1: Stream Extraction Failure After SIGTERM (20+ occurrences)

When Ralph's 30-minute timeout kills Claude via SIGTERM, buffered stdout data is lost. The stream log contains incomplete NDJSON, and `ralph_extract_result_from_stream` fails with: `Stream extraction failed: no valid result object in stream`. Ralph has no idea what work was completed.

### Issue 2: Multi-Result Stream Violations (5+ occurrences)

Claude sometimes produces 2–5 top-level result objects in a single NDJSON stream (violating the expected single-result contract). The current "emergency JSONL extraction" fallback works but is fragile and triggered on every successful run in some sessions (~30+ times in tapps-brain).

### Issue 3: Execution Stats Newline Parsing (10+ occurrences)

Stats output contains literal newlines, splitting across log lines:
```
[INFO] Execution stats: Tools=0
0 Agents=0
0 Errors=0
0
```

### Evidence

- **TheStudio 2026-03-22**: 20 stream extraction failures paired with timeouts
- **tapps-brain 2026-03-21**: 30+ emergency JSONL extractions, 2 multi-result violations (2 and 5 objects)
- **tapps-brain 2026-03-21**: 10+ stat lines split across multiple log entries

## Research-Informed Adjustments

### NDJSON Stream Recovery (2025 Best Practices)

- **`stdbuf -oL`**: Force line-buffered output so each NDJSON line hits the file immediately, even before SIGTERM. Reference: [Julia Evans — Why Pipes Get Stuck](https://jvns.ca/blog/2024/11/29/why-pipes-get-stuck-buffering/)
- **`tee` progressive write**: Pipe through `tee "$OUTPUT_FILE"` so output is written to disk in real-time, not buffered until process exit
- **Bash `trap` handler**: Trap SIGTERM, forward to child with grace period, then `sync` filesystem
- **`jq --seq`**: RFC 7464 record separators make truncated streams parseable. Reference: [jqlang.org/manual](https://jqlang.org/manual/)

### Multi-Result Merging (2025 Best Practices)

- **Last-writer-wins**: `jq -s '.[-1]'` — take the last complete result object
- **Type-based routing**: `jq -c 'select(.type == "result")'` — filter by message type
- **Vector.dev dedupe transform**: Production-grade deduplication with configurable field matching and LRU cache. Reference: [Vector.dev Dedupe](https://vector.dev/docs/reference/configuration/transforms/dedupe/)

## Stories

| Story | Title | Priority | Effort | Status |
|-------|-------|----------|--------|--------|
| [CAPTURE-1](story-capture-1-progressive-stream-capture.md) | Progressive Stream Capture Before SIGTERM | High | Medium | Pending |
| [CAPTURE-2](story-capture-2-multi-result-merging.md) | Multi-Result Stream Merging Strategy | Medium | Small | Pending |
| [CAPTURE-3](story-capture-3-stats-newline-fix.md) | Fix Execution Stats Newline Parsing | Low | Trivial | Pending |

## Implementation Order

1. **CAPTURE-1** (High) — Ensures stream data survives SIGTERM. Prerequisite for reliable post-timeout analysis.
2. **CAPTURE-2** (Medium) — Replaces fragile emergency extraction with a robust merging strategy.
3. **CAPTURE-3** (Low) — Cosmetic fix for log readability.

## Acceptance Criteria (Epic-level)

- [ ] Stream output file contains complete data even after SIGTERM timeout
- [ ] `ralph_extract_result_from_stream` succeeds after timeout (returns partial result)
- [ ] Multi-result streams are handled without "emergency" fallback
- [ ] Execution stats always appear on a single log line
- [ ] All fixes have BATS tests

## Out of Scope

- Changes to Claude Code CLI's output format
- Adaptive timeout duration (covered in RALPH-ADAPTIVE)
- JSONL parser rewrite (existing parser in epic-stream-parser-v2 is sufficient)
