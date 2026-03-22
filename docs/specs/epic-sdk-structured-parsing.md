# Epic: Structured Response Parsing (HIGH-4)

**Epic ID:** RALPH-SDK-PARSING
**Priority:** High
**Phase:** 1 — Non-Breaking Foundation (v1.4.0)
**Affects:** Response parsing reliability, status extraction, forward compatibility
**Components:** New `sdk/ralph_sdk/parsing.py`, `sdk/ralph_sdk/agent.py`
**Related specs:** [RFC-001 §4 HIGH-4](../../TheStudio/docs/architecture/RFC-001-ralph-sdk-integration.md), `epic-sdk-pydantic-models.md`, `epic-jsonl-stream-resilience.md`
**Target Version:** v1.4.0
**Status:** Done

---

## Problem Statement

The SDK's `_extract_ralph_status()` (agent.py:454-485) uses 6 regex patterns to parse
a `---RALPH_STATUS---` text block from Claude's raw output. This has known bugs:

1. **JSON-escaped `\n`**: JSONL output contains `\\n` which breaks newline matching
   (documented as STREAM-3)
2. **Case-sensitive EXIT_SIGNAL**: `"True"` and `"TRUE"` don't match the `lower()` check
   consistently across all code paths
3. **Multi-result JSONL**: Only the last result object is used, with no validation or warning
4. **No schema version**: Any format change silently breaks parsing
5. **No validation**: Extracted fields are raw strings — `tasks_completed: "banana"` passes

### Why This Benefits Standalone Ralph

Even without TheStudio, structured parsing improves Ralph SDK reliability:
- Versioned schema enables graceful handling of format changes across Ralph versions
- Pydantic validation catches malformed status blocks early
- JSON output path is more reliable than regex on text
- Known bugs (case sensitivity, multi-result) fixed for all users

## Stories

| Story | Title | Priority | Effort | Status |
|-------|-------|----------|--------|--------|
| [RALPH-SDK-PARSING-1](story-sdk-parsing-1-schema.md) | Define RalphStatusBlock Pydantic model with enums | Critical | Small | Done |
| [RALPH-SDK-PARSING-2](story-sdk-parsing-2-parser.md) | Implement multi-strategy parse_ralph_status() | Critical | Medium | Done |
| [RALPH-SDK-PARSING-3](story-sdk-parsing-3-bugfixes.md) | Fix EXIT_SIGNAL coercion and multi-result handling | High | Small | Done |
| [RALPH-SDK-PARSING-4](story-sdk-parsing-4-prompt.md) | Update agent prompt to request JSON status output | Medium | Trivial | Done |
| [RALPH-SDK-PARSING-5](story-sdk-parsing-5-wire.md) | Wire new parser into _parse_response() | High | Small | Done |

## Implementation Order

1. **PARSING-1** — Schema definition. Depends on Epic 1 enums.
2. **PARSING-2** — Parser with 3 strategies (JSON → JSONL → text fallback).
3. **PARSING-3** — Bug fixes in coercion and multi-result handling.
4. **PARSING-4** — Prompt update to request JSON output.
5. **PARSING-5** — Wire into agent, verify existing tests pass.

## Design Decisions

### Three-Strategy Parser

```
parse_ralph_status(raw_output: str) -> RalphStatusBlock
  1. JSON path: find ```json block with "version" key → validate with Pydantic
  2. JSONL path: find {"type": "result"} line → extract status fields
  3. Text fallback: regex extraction (current behavior, for backward compat)
```

The text fallback is critical — it preserves backward compatibility with the bash loop's
`on-stop.sh` hook output format. Standalone Ralph users may never see JSON status blocks
if they use the bash loop, so the text path must always work.

### Enums Shared with Epic 1

`RalphLoopStatus`, `WorkType`, and `TestsStatus` enums are defined once (in a shared
enums module or in the status models) and reused by both the status models and the
parsing schema. No duplication.

## Acceptance Criteria (Epic-level)

- [ ] `RalphStatusBlock` Pydantic model with `version`, `status`, `exit_signal`, `tasks_completed`, `files_modified`, `progress_summary`, `work_type`, `tests_status`
- [ ] JSON status block parsed correctly from fenced code block
- [ ] JSONL result object parsed correctly
- [ ] Text fallback (regex) still works for bash loop compatibility
- [ ] `EXIT_SIGNAL` coercion handles `true/True/TRUE/yes/1` uniformly
- [ ] Multi-result JSONL: last valid result used, warning logged
- [ ] Malformed input raises `ValidationError` (not silent defaults)
- [ ] Version field enables future schema evolution
- [ ] All existing tests pass
- [ ] `ralph --sdk` works unchanged

## Out of Scope

- Bash loop parsing changes (bash uses `on-stop.sh` hook — separate codebase)
- JSONL stream resilience (covered by `epic-jsonl-stream-resilience.md`)
- Agent prompt template configurability (Epic 7 / RFC §9 Q4)
