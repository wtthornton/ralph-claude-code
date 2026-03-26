# Epic: Multi-Task Loop Violation and Cascading Failures

**Epic ID:** RALPH-MULTI
**Priority:** High
**Status:** Done
**Affects:** Loop control integrity, permission detection, session reliability
**Components:** `PROMPT.md` template, `ralph_loop.sh`, `response_analyzer.sh`, `.ralphrc` template
**Related specs:** `ralph-multi-task-loop-and-cascading-failures.md`, `ralph-jsonl-crash-bug.md`
**Depends on:** Epic RALPH-JSONL (JSONL crash is the root cause of silent termination)

---

## Problem Statement

On 2026-03-21, a single Ralph loop invocation exhibited five interconnected failures
that cascaded into silent loop termination. While the JSONL crash bug (Epic RALPH-JSONL)
was the direct cause of the silent exit, the incident exposed additional gaps:

1. Claude completed 2 tasks in one loop instead of the mandated 1
2. Permission denials went undetected because analysis crashed before extracting them
3. ALLOWED_TOOLS patterns had gaps causing 5 unnecessary permission denials
4. Infrastructure failures (MCP servers, startup hook) degraded the session silently
5. Circuit breaker state leaked across sessions

## Verification Status

All findings independently verified against source code and 2026 documentation:

| Issue | Verified | Method |
|-------|----------|--------|
| PROMPT.md lacks explicit STOP instruction | YES | Template inspection (templates/PROMPT.md) |
| "Ralph's Action" lines misinterpretable | YES | Line 252: "Continues loop" reads as self-instruction |
| `Bash(git -C *)` missing from ALLOWED_TOOLS | YES | Template inspection (templates/ralphrc.template) |
| `Bash(grep *)` missing from ALLOWED_TOOLS | YES | Template inspection |
| `Bash(find *)` missing from ALLOWED_TOOLS | YES | Template inspection (spec incorrectly claimed it was included) |
| No pre-analysis permission denial check | YES | should_exit_gracefully requires .response_analysis file |
| Circuit breaker not reset on startup | YES | Exit signals reset but not CB counters |
| Text parser joins multi-result values | YES | grep/cut/xargs concatenates: "false false" |
| SessionStart hook cannot block session | YES | Claude Code docs: exit 2 shows error, continues |
| No built-in MCP health check API | YES | Issue #29626 requested, not implemented |

## Research-Informed Insights

### PROMPT.md stop instruction is unreliable alone
Web research (2026) reveals Claude Code has documented issues (#27743, #15443, #7777)
where Claude ignores explicit CLAUDE.md/PROMPT.md stop instructions. The **recommended
pattern** for autonomous loops is the **Stop hook with completion promise** (as
implemented by the official `ralph-wiggum` plugin). However, strengthening the prompt
text is still valuable as a first line of defense.

### ALLOWED_TOOLS pattern matching
`Bash(git *)` matches any command starting with `git ` (including `git -C`), but the
template uses specific subcommand patterns (`Bash(git add *)`, `Bash(git commit *)`).
This granular approach is intentional (prevents destructive git commands like
`git clean`, `git reset --hard`) but creates gaps for flag-prefixed commands.

### SessionStart hooks cannot block sessions
Exit code 2 on SessionStart shows stderr to the user but does NOT prevent session
startup. The failing PowerShell hook is cosmetically noisy but functionally harmless.

### MCP health checks are not available
No built-in MCP health check API exists (Issue #29626). Ralph could parse the
`system:init` event from stream-json output to detect failed servers post-hoc.

## Stories

| Story | Title | Priority | Effort | Status |
|-------|-------|----------|--------|--------|
| [RALPH-MULTI-1](story-multi-1-stop-instruction.md) | Strengthen PROMPT.md stop instruction | Critical | Trivial | Done |
| [RALPH-MULTI-2](story-multi-2-permission-prescan.md) | Add pre-analysis permission denial scan | High | Small | Done |
| [RALPH-MULTI-3](story-multi-3-allowed-tools-gaps.md) | Fix ALLOWED_TOOLS template patterns | High | Trivial | Done |
| [RALPH-MULTI-4](story-multi-4-circuit-breaker-reset.md) | Reset circuit breaker state on startup | Low | Trivial | Done |
| [RALPH-MULTI-5](story-multi-5-dual-result-warning.md) | Warn on multiple result objects in stream | Medium | Trivial | Done |
| [RALPH-MULTI-6](story-multi-6-infrastructure-resilience.md) | Fix startup hook and add MCP pre-flight | Medium | Small | Done |

## Implementation Order

1. **RALPH-MULTI-1** (Critical) -- Prevents multi-task violation at the source.
2. **RALPH-MULTI-3** (High) -- Eliminates unnecessary permission denials. Trivial config change.
3. **RALPH-MULTI-2** (High) -- Ensures permission denials are visible even if analysis crashes.
4. **RALPH-MULTI-5** (Medium) -- Adds observability for dual-result edge case.
5. **RALPH-MULTI-6** (Medium) -- Cleans up infrastructure noise.
6. **RALPH-MULTI-4** (Low) -- Prevents stale CB state from affecting new sessions.

## Acceptance Criteria (Epic-level)

- [ ] Claude completes exactly 1 task per loop invocation *(prompt + warnings; not enforceable in bash alone)*
- [x] Permission denials are logged pre-analysis via `ralph_log_permission_denials_from_raw_output`
- [x] ALLOWED_TOOLS defaults include `Bash(git -C *)`, `Bash(grep *)`, `Bash(find *)` (template, `setup.sh`, `enable_core.sh`, `ralph_loop.sh` default)
- [x] Circuit breaker per-session counters reset on Ralph startup (`ralph_loop.sh`)
- [x] Multiple result objects / RALPH_STATUS blocks produce warnings; text path uses last block only
- [x] SessionStart hook uses bash (`.claude/settings.json`); MCP failures logged from stream + optional Docker label preflight

**Implementation note (2026-03-21):** MULTI-1–6 implemented as specified; copy `.claude/settings.json` into target projects or merge `SessionStart` hook as needed.

## Relationship to JSONL Epic

The JSONL crash (Epic RALPH-JSONL) is the **root cause** of the silent termination.
This epic addresses the **contributing factors** that made the incident worse:
- Multi-task violation produced a larger JSONL file (5249 lines vs typical ~1500)
- Permission denial masking was a consequence of the analysis crash
- Circuit breaker state leak could compound future incidents

If RALPH-JSONL-1 (JSONL parser detection) is implemented, the silent termination is
resolved. But the issues in this epic remain independently valid and should be fixed.

## Spec Correction

The original spec states `find` IS in ALLOWED_TOOLS (Issue 4 table: "find IS in
ALLOWED_TOOLS, but denied anyway"). Verification shows `Bash(find *)` is **not** in
the template's ALLOWED_TOOLS. The denial was because the pattern is missing entirely,
not due to a subagent scope issue. RALPH-MULTI-3 corrects this.
