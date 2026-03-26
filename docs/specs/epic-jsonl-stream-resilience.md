# Epic: JSONL Stream Processing Resilience

**Epic ID:** RALPH-JSONL
**Priority:** Critical
**Status:** Done
**Affects:** Live mode (`--live`) reliability, autonomous loop continuity
**Components:** `response_analyzer.sh`, `ralph_loop.sh`
**Related specs:** `ralph-jsonl-crash-bug.md`, `ralph-multi-task-loop-and-cascading-failures.md`

---

## Problem Statement

In live mode, Ralph's response analysis crashes silently when the Claude Code CLI
`stream-json` output (JSONL/NDJSON format) is not successfully extracted to a single
result JSON object before being passed to `parse_json_response`. The parser assumes
single-object or array input; JSONL input causes every `jq` extraction to return N
lines instead of 1, corrupting bash variables and terminating the loop without any
logged error.

This is the **root cause** of the silent loop termination observed in production on
2026-03-21, and is confirmed to be a contributing factor in the cascading failures
documented in `ralph-multi-task-loop-and-cascading-failures.md`.

## Verification Status

All findings from `ralph-jsonl-crash-bug.md` have been independently verified:

| Claim | Verified | Method |
|-------|----------|--------|
| `jq` produces N lines on JSONL input | YES | jq 1.8 docs confirm per-line processing |
| `parse_json_response` line numbers match | YES | Direct source inspection (lines 100, 107, 146-327) |
| Bash `$(())` crashes on multi-line vars | YES | Documented bash failure mode |
| `return 0` at line 327 is unconditional | YES | Direct source inspection |
| Caller at line 360 uses `2>/dev/null` | YES | Direct source inspection |
| WSL2/NTFS 9P race condition is real | YES | Microsoft WSL release notes, GitHub issues #4197, #4515 |
| `stream-json` format is JSONL/NDJSON | YES | Claude Code CLI docs, community tooling |

## Research-Informed Adjustments

Web research on 2026 best practices identified one adjustment to the original spec:

- **Fix 3 (`sync` for WSL2 race):** Research confirms `sync` flushes Linux filesystem
  buffers but has **limited effectiveness** on WSL2 9P-mounted NTFS because the
  bottleneck is the protocol bridge, not Linux buffers. The story has been updated to
  use a **retry loop with backoff** instead of a single `sync + sleep 0.2`.

## Stories

| Story | Title | Priority | Effort | Status |
|-------|-------|----------|--------|--------|
| [RALPH-JSONL-1](story-jsonl-1-parser-detection.md) | Add JSONL detection to parse_json_response | Critical | Small | Done |
| [RALPH-JSONL-2](story-jsonl-2-return-code-accuracy.md) | Fix parse_json_response return code | Important | Trivial | Done |
| [RALPH-JSONL-3](story-jsonl-3-wsl-filesystem-resilience.md) | Add WSL2/NTFS filesystem resilience | Defensive | Small | Done |
| [RALPH-JSONL-4](story-jsonl-4-fallback-extraction.md) | Add fallback JSONL extraction in ralph_loop | Defensive | Small | Done |

## Implementation Order

1. **RALPH-JSONL-1** (Critical) -- Resolves the crash entirely. Can ship alone.
2. **RALPH-JSONL-2** (Important) -- Enables proper error propagation. Ship with or after #1.
3. **RALPH-JSONL-3** (Defensive) -- Reduces race condition window. Independent of #1-2.
4. **RALPH-JSONL-4** (Defensive) -- Belt-and-suspenders catch. Depends on #1 being absent or as additional safety.

Stories 1+2 together eliminate the crash and enable proper error handling.
Stories 3+4 are defense-in-depth to prevent the JSONL from reaching the parser at all.

## Acceptance Criteria (Epic-level)

- [ ] Ralph `--live` survives 10+ consecutive loops without silent termination *(validate in production)*
- [x] Raw JSONL output files are correctly handled (not just tolerated) — `parse_json_response` + `ralph_emergency_jsonl_normalize`
- [x] `_stream.log` backups preserved on live extract; emergency path creates backup when needed
- [x] No silent failures on parse path — invalid/empty `.json_parse_result` returns 1 and logs WARN
- [ ] All fixes have BATS tests covering the failure scenarios *(follow-up: add JSONL regression tests)*

**Implementation note (2026-03-21):** Stories JSONL-1–4 landed in `lib/response_analyzer.sh` and `ralph_loop.sh`. JSONL detection uses `jq -s 'length' > 1` (handles pretty-printed single objects; avoids `wc -l` false positives).

## Related Epic

[RALPH-MULTI: Multi-Task Loop and Cascading Failures](epic-multi-task-cascading-failures.md)
addresses the contributing factors that compound the JSONL crash, including:
- Multi-task violations that produce multiple `type: "result"` objects (RALPH-MULTI-5)
- Permission denial masking when analysis crashes (RALPH-MULTI-2)
- ALLOWED_TOOLS gaps that cause unnecessary denials (RALPH-MULTI-3)

RALPH-JSONL-1 (this epic) is the root cause fix. RALPH-MULTI stories are
defense-in-depth and observability improvements.

## Out of Scope

- Moving Ralph's working directory off NTFS to native ext4 (operational change, not code fix)
- Multi-result JSONL handling -- covered in [RALPH-MULTI-5](story-multi-5-dual-result-warning.md)
- Claude Code CLI changes to output format
