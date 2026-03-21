# Epic: Hooks + Agent Definition (Phase 1)

**Epic ID:** RALPH-HOOKS
**Priority:** Critical
**Affects:** Core loop reliability, tool permission management, response parsing
**Components:** `ralph_loop.sh`, `lib/response_analyzer.sh`, `lib/file_protection.sh`
**Related specs:** `claude-code-2026-enhancements.md` (§4.1, §4.2, §5 Phase 1)
**Target Version:** v1.0.0

---

## Problem Statement

Ralph v0.11.x invokes Claude Code via `claude -p "$(cat PROMPT.md)"` with inline
`--allowedTools` parsing, bash-based response analysis (935 lines), and shell string
splitting for tool permissions. Claude Code 2026 provides custom agent definitions
(`.claude/agents/*.md`) and lifecycle hooks (22 event types) that replace this fragile
infrastructure with deterministic, platform-native mechanisms.

## Research-Informed Adjustments

Web research on Claude Code 2026 documentation (March 2026) identified the following
adjustments to the original RFC:

1. **Hook types expanded:** Four hook types now available (`command`, `http`, `prompt`,
   `agent`), not just `command`. The `prompt` type enables single-turn LLM evaluation
   for complex validation without shell scripts.

2. **22 hook events available:** The RFC listed ~6 events. Additional relevant events
   include `PostToolUseFailure`, `StopFailure` (rate limit detection), `SessionEnd`,
   `PreCompact`/`PostCompact`, and `ConfigChange`.

3. **PreToolUse exit 0 JSON output:** Hooks can return `permissionDecision: "allow|deny|ask"`
   in structured JSON, not just exit codes. This is more robust than exit 2 for blocking.

4. **PermissionRequest hooks don't fire in non-interactive mode (`-p`).** Since Ralph
   uses `-p` mode, `PreToolUse` is the correct hook for permission enforcement (confirmed
   by the RFC design).

5. **Agent frontmatter fields:** Additional fields available: `effort` (`low`/`medium`/
   `high`/`max`), `hooks` (agent-scoped), `mcpServers`, `skills` (preloaded).

6. **Task tool renamed to Agent:** `Task(...)` still works as alias but `Agent` is the
   canonical name (v2.1.63+).

7. **Hook environment variables:** `CLAUDE_PROJECT_DIR`, `CLAUDE_ENV_FILE` (SessionStart
   only) available to hook scripts.

8. **Shell profile gotcha:** Shell profiles with unconditional `echo` statements break
   JSON parsing from stdout in command hooks. Hook scripts must not source profiles that
   echo.

## Stories

| Story | Title | Priority | Effort | Status |
|-------|-------|----------|--------|--------|
| [RALPH-HOOKS-1](story-hooks-1-agent-definition.md) | Create ralph.md custom agent definition | Critical | Small | Open |
| [RALPH-HOOKS-2](story-hooks-2-settings-json.md) | Create hooks configuration in settings.json | Critical | Medium | Open |
| [RALPH-HOOKS-3](story-hooks-3-session-start-hook.md) | Implement on-session-start.sh hook | Important | Small | Open |
| [RALPH-HOOKS-4](story-hooks-4-stop-hook.md) | Implement on-stop.sh hook (replace response_analyzer) | Critical | Medium | Open |
| [RALPH-HOOKS-5](story-hooks-5-file-protection-hooks.md) | Implement file protection PreToolUse hooks | Important | Small | Open |
| [RALPH-HOOKS-6](story-hooks-6-cli-integration.md) | Add --agent ralph to build_claude_command() | Important | Small | Open |

## Implementation Order

1. **RALPH-HOOKS-1** (Critical) — Agent definition is the foundation. All other stories depend on it.
2. **RALPH-HOOKS-2** (Critical) — Hooks config must exist before hook scripts can fire.
3. **RALPH-HOOKS-3 + RALPH-HOOKS-5** (Important) — Independent of each other, can be done in parallel.
4. **RALPH-HOOKS-4** (Critical) — Core replacement for response_analyzer. Depends on hooks config.
5. **RALPH-HOOKS-6** (Important) — CLI integration. Ship last as the activation switch.

## Verification Criteria

- [ ] Ralph completes a 5-task fix plan using `--agent ralph`
- [ ] All 566 existing BATS tests pass
- [ ] Hook scripts fire on every Stop/PreToolUse/PostToolUse event (check `.ralph/live.log`)
- [ ] File protection hook blocks `.ralph/PROMPT.md` modification
- [ ] `on-stop.sh` writes correct `status.json` after every loop
- [ ] Fallback to `-p` mode works when `RALPH_USE_AGENT=false`
- [ ] No regressions in exit detection accuracy

## Rollback

Remove `--agent ralph` flag from `build_claude_command()`. Hooks are additive and don't
break existing flow. `response_analyzer.sh` is retained as fallback until Phase 3.
