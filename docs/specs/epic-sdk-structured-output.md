# Epic: SDK Structured Output & Observability — Files Changed, Error Categories, Heartbeat, and Metrics

**Epic ID:** RALPH-SDK-OUTPUT
**Priority:** P1–P2
**Affects:** Integration reliability, error handling, observability, analytics
**Components:** `ralph_sdk/parsing.py`, `ralph_sdk/status.py`, `ralph_sdk/agent.py`
**Related specs:** [epic-jsonl-stream-resilience.md](epic-jsonl-stream-resilience.md)
**Depends on:** None (enhances existing SDK modules and adds new ones)
**Target Version:** SDK v2.1.0
**Source:** [ralph-sdk-upgrade-evaluation.md](../../../TheStudio/docs/ralph-sdk-upgrade-evaluation.md) §2.1, §1.7, §2.3, §1.9

---

## Problem Statement

Four output-related gaps between the CLI and SDK cause integration fragility and observability blindness:

1. **Fragile files_changed extraction**: TheStudio uses a regex heuristic to extract changed file paths from Ralph's freeform output — lines starting with `"- "` containing dots or slashes. This is duplicated in both `ralph_bridge.py:203-218` and `primary_agent.py:125-141`. False positives are common. The SDK should return `files_changed: list[str]` as a structured field populated from actual `git diff` output or Claude's tool use records (Write/Edit calls).

2. **Generic error handling**: The CLI categorizes errors into expected-scope (permission denials for built-in tools) vs system errors (crashes, hangs). The SDK treats all errors generically. TheStudio's loopback logic needs to know whether a failure is retryable (permission denial → adjust tools) vs terminal (crash → circuit break). Generic handling causes unnecessary retries on terminal failures and premature circuit breaks on fixable issues.

3. **Unstructured heartbeat data**: TheStudio's heartbeat sends `f"ralph_running elapsed={elapsed_s}s"` as a plain string. Temporal dashboards can't extract loop count, work type, or progress. The SDK should expose a `ProgressSnapshot` for structured heartbeat data.

4. **No metrics collection**: The CLI records per-iteration metrics to monthly JSONL files and provides aggregated dashboards. The SDK collects no metrics. TheStudio's Analytics & Learning epic (Epic 39) needs historical Ralph performance data that doesn't exist today.

### Evidence

- TheStudio `ralph_bridge.py:203-218`: Regex heuristic for file extraction, duplicated
- TheStudio `activities.py`: Heartbeat sends plain string, no structured data
- TheStudio Epic 39 (Analytics & Learning): Blocked on missing loop-level metrics
- TheStudio Epic 43, Story 43.14: OTEL spans added but no structured loop metrics

## Stories

| Story | Title | Priority | Effort | Status |
|-------|-------|----------|--------|--------|
| [SDK-OUTPUT-1](story-sdk-output-1-files-changed.md) | Structured `files_changed` on TaskResult | P1 | 0.5 day | Pending |
| [SDK-OUTPUT-2](story-sdk-output-2-error-categorization.md) | Error Categorization | P2 | 1 day | Pending |
| [SDK-OUTPUT-3](story-sdk-output-3-progress-snapshot.md) | Structured Heartbeat / Progress Snapshot | P2 | 0.5 day | Pending |
| [SDK-OUTPUT-4](story-sdk-output-4-metrics-collection.md) | Metrics Collection | P2 | 1–2 days | Pending |

## Implementation Order

1. **SDK-OUTPUT-1** (P1) — `files_changed` field on `TaskResult`. Immediate value for TheStudio.
2. **SDK-OUTPUT-2** (P2) — `ErrorCategory` enum on status. Enables smarter retry logic.
3. **SDK-OUTPUT-3** (P2) — `ProgressSnapshot` on agent. Small surface area, high heartbeat value.
4. **SDK-OUTPUT-4** (P2) — `MetricsCollector` protocol. Largest item; depends on stable status model.

## Acceptance Criteria (Epic-level)

- [x] `TaskResult.files_changed` is a `list[str]` populated from tool use records or git diff
- [x] File extraction does not rely on regex heuristics against freeform text
- [x] Errors are categorized as `PERMISSION_DENIED`, `TIMEOUT`, `PARSE_FAILURE`, `TOOL_UNAVAILABLE`, `SYSTEM_CRASH`, or `UNKNOWN`
- [x] Error category is returned alongside `RalphStatus`
- [x] `RalphAgent.get_progress()` returns a `ProgressSnapshot` with loop_count, work_type, current_task, elapsed_seconds, circuit_breaker_state
- [x] `MetricsCollector` protocol defines `record()` and `query()` methods
- [x] `JsonlMetricsCollector` writes monthly JSONL files (matches CLI format)
- [x] `NullMetricsCollector` is a no-op implementation for testing
- [x] pytest tests verify all output structures

## Out of Scope

- Dashboard visualization (TheStudio concern)
- OTEL span integration (TheStudio's `conventions.py` handles this)
- Real-time streaming metrics (batch JSONL is sufficient)
- Git diff execution within the SDK (SDK parses Claude's tool use output; git commands are Claude's responsibility)
