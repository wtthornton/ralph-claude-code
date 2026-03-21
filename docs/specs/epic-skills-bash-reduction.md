# Epic: Skills + Bash Reduction (Phase 3)

**Epic ID:** RALPH-SKILLS
**Priority:** Important
**Affects:** Codebase maintainability, loop orchestration, test coverage
**Components:** `ralph_loop.sh`, `lib/response_analyzer.sh`, `lib/file_protection.sh`, `lib/circuit_breaker.sh`
**Related specs:** `claude-code-2026-enhancements.md` (§4.3, §5 Phase 3)
**Target Version:** v1.0.0
**Depends on:** RALPH-HOOKS (Phase 1), RALPH-SUBAGENTS (Phase 2)

---

## Problem Statement

After Phase 1 (hooks) and Phase 2 (sub-agents), Ralph still carries ~1,800 lines of
bash code that duplicates what hooks and agents now handle natively. The
`response_analyzer.sh` (935 lines) and `file_protection.sh` (58 lines) are fully
superseded by hook scripts. The `circuit_breaker.sh` (475 lines) can be simplified
since hooks now provide state data. Additionally, common loop operations can be
formalized as reusable Claude Code skills.

## Research-Informed Adjustments

Web research on Claude Code 2026 documentation (March 2026) identified the following
adjustments to the original RFC:

1. **Skill format confirmed:** `.claude/skills/<name>/SKILL.md` with YAML frontmatter.
   Fields include `name`, `description`, `argument-hint`, `user-invocable`,
   `disable-model-invocation`, `allowed-tools`, `model`, `effort`, `context`, `agent`,
   `hooks`.

2. **Dynamic context injection:** Skills support `` !`command` `` syntax to run shell
   commands and inject output before content is sent to Claude. Useful for injecting
   fix_plan.md status dynamically.

3. **`context: fork` confirmed:** Runs skill in a subagent context, keeping main context
   clean. The `agent:` field specifies which subagent type.

4. **Supporting files:** Templates, scripts, and examples can live alongside SKILL.md
   in the skill directory.

5. **Skill description budget:** Descriptions consume ~2% of context window (~16K chars).
   Override with `SLASH_COMMAND_TOOL_CHAR_BUDGET` env var if needed.

6. **Legacy commands still work:** `.claude/commands/*.md` is merged with skills. Both
   work, but skills take precedence.

7. **String substitutions:** `$ARGUMENTS`, `$ARGUMENTS[N]`, `$N` (positional),
   `${CLAUDE_SESSION_ID}`, `${CLAUDE_SKILL_DIR}` available in skill content.

## Stories

| Story | Title | Priority | Effort | Status |
|-------|-------|----------|--------|--------|
| [RALPH-SKILLS-1](story-skills-1-loop-skill.md) | Create ralph-loop skill | Important | Small | Open |
| [RALPH-SKILLS-2](story-skills-2-research-skill.md) | Create ralph-research skill | Nice-to-have | Small | Open |
| [RALPH-SKILLS-3](story-skills-3-remove-response-analyzer.md) | Remove response_analyzer.sh (hooks handle it) | Important | Medium | Open |
| [RALPH-SKILLS-4](story-skills-4-remove-file-protection.md) | Remove file_protection.sh (hooks handle it) | Important | Trivial | Open |
| [RALPH-SKILLS-5](story-skills-5-simplify-circuit-breaker.md) | Simplify circuit_breaker.sh (hooks provide state) | Important | Medium | Open |

## Implementation Order

1. **RALPH-SKILLS-1 + 2** — Skills are additive, create in parallel. No risk.
2. **RALPH-SKILLS-4** (Trivial) — Remove file_protection.sh. Low risk, quick win.
3. **RALPH-SKILLS-3** (Medium) — Remove response_analyzer.sh. Higher risk, needs careful
   test adaptation. Depends on Phase 1 hooks being validated in production.
4. **RALPH-SKILLS-5** (Medium) — Simplify circuit_breaker.sh. Depends on on-stop.sh
   hook providing reliable state data.

## Verification Criteria

- [ ] `ralph_loop.sh` reduced to <600 lines
- [ ] `response_analyzer.sh` removed (hooks handle all parsing)
- [ ] `file_protection.sh` removed (hooks handle protection)
- [ ] 640+ BATS tests pass (74 new tests for hooks + skills)
- [ ] No regressions in exit detection accuracy
- [ ] Circuit breaker triggers correctly on stuck loop
- [ ] `/ralph-loop` skill invocable from CLI

## Rollback

Individual removals can be reverted via git. Skills are additive and don't affect
existing code. Circuit breaker simplification should be behind `RALPH_USE_AGENT` flag
to allow fallback.
