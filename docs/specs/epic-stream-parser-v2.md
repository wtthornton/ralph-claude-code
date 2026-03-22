# Epic: Stream Parser v2 — JSONL as Primary Path

**Epic ID:** RALPH-STREAM
**Priority:** Medium
**Affects:** Stream parsing, multi-result detection, RALPH_STATUS extraction, log clarity
**Components:** `ralph_loop.sh` (`ralph_emergency_jsonl_normalize`), `templates/hooks/on-stop.sh`
**Related specs:** `epic-jsonl-stream-resilience.md` (Phase 0), `epic-loop-stability.md` (Phase 0.5)
**Source:** [ralph-feedback-report.md](../../../../tapps-brain/ralph-feedback-report.md) (2026-03-21, Issues #1, #2, #7)

---

## Problem Statement

Claude CLI v2.1+ (stream-json / `--output-format json`) always emits JSONL with interleaved
`stream_event`, `assistant`, `user`, and `result` message types. Ralph's stream parser still
treats JSONL as an exceptional case:

1. **Naming:** The primary extraction function is called `ralph_emergency_jsonl_normalize` and
   logs "Emergency JSONL extraction" on every loop — 100% false alarm rate. This masks genuine
   parsing failures.

2. **Multi-result false positives:** When Claude delegates to background agents (ralph-tester,
   ralph-explorer), each agent's completion emits its own `"type":"result"` object. The parser
   counts ALL result objects (line 480-486) and warns "Multi-task loop violation detected" even
   though Ralph correctly completed exactly one task. Observed in 3/6 loops (2026-03-21).
   Currently cosmetic, but dangerous if future code acts on this signal.

3. **RALPH_STATUS field extraction fails on JSONL:** The on-stop.sh hook receives the response
   as stdin and greps for `WORK_TYPE:`, `STATUS:`, etc. When the response is a JSON result
   object (from JSONL extraction), the RALPH_STATUS block is JSON-escaped — literal `\n`
   instead of newlines. The grep misses, defaulting to `WORK_TYPE: UNKNOWN` and empty summary.
   Observed on Loop #6 (2026-03-21).

### Impact

- Log noise from "emergency" warnings obscures real errors
- False multi-task violations could trigger false penalties in future versions
- Lost work_type/summary degrades monitoring and circuit breaker intelligence

## Stories

| # | ID | Story | Priority | Effort | Status |
|---|-----|-------|----------|--------|--------|
| 1 | STREAM-1 | Promote JSONL Parsing to Primary Path | Medium | Small | **Done** |
| 2 | STREAM-2 | Filter Multi-Result Count by Parent Context | Medium | Trivial | **Done** |
| 3 | STREAM-3 | Unescape RALPH_STATUS Before Field Extraction | Medium | Small | **Done** |

## Acceptance Criteria (Epic Level)

- [ ] No "emergency" or "Emergency" appears in log output during normal JSONL processing
- [ ] Multi-result warnings only fire for actual top-level result duplicates, not subagent results
- [ ] WORK_TYPE, STATUS, and recommendation are correctly extracted from JSONL-sourced responses
- [ ] All existing tests pass; new tests cover JSONL-as-primary-path scenarios
