# Epic: Sub-agents (Phase 2)

**Epic ID:** RALPH-SUBAGENTS
**Priority:** Important
**Affects:** Codebase exploration efficiency, test isolation, code review quality
**Components:** `.claude/agents/`, `ralph_loop.sh`
**Related specs:** `claude-code-2026-enhancements.md` (§4.1.2–4.1.4, §4.5, §4.7, §5 Phase 2)
**Target Version:** v1.0.0
**Depends on:** RALPH-HOOKS (Phase 1)

---

## Problem Statement

Ralph v0.11.x runs everything in a single `claude -p` call. Codebase exploration,
test execution, and code review all happen in the main agent context, consuming tokens
and creating a noisy context window. Claude Code 2026 provides sub-agents spawned via
the `Agent` tool, with model-specific optimization (haiku for search, sonnet for tests)
and worktree isolation for file safety.

## Research-Informed Adjustments

Web research on Claude Code 2026 documentation (March 2026) identified the following
adjustments to the original RFC:

1. **Subagents cannot spawn other subagents.** Only the main thread (invoked via
   `--agent ralph`) can spawn them. This is fine for the RFC design since Ralph IS
   the main agent, but sub-agents (explorer, tester, reviewer) cannot chain-spawn
   each other.

2. **Built-in subagent types exist:** `Explore` (Haiku, read-only), `Plan` (inherits,
   read-only), and `general-purpose` (inherits, all tools) are built-in. The custom
   `ralph-explorer` may overlap with the built-in `Explore` agent. Consider whether
   the built-in is sufficient or customization is needed.

3. **Subagent resumption:** Completed subagents can be resumed via `SendMessage` with
   the agent's ID. This enables follow-up questions to the same agent context.

4. **Subagent transcripts:** Stored at `~/.claude/projects/{project}/{sessionId}/
   subagents/agent-{agentId}.jsonl` for debugging.

5. **Worktree auto-cleanup:** Worktrees are automatically cleaned if the subagent
   makes no changes. Only worktrees with committed changes persist.

6. **SubagentStop hook:** Fires when a subagent finishes. Can be used to capture
   results and update Ralph state.

7. **`tools: Agent(worker, researcher)` syntax:** Restricts which sub-agent types
   the main agent can spawn (allowlist). Useful for preventing unintended spawning.

## Stories

| Story | Title | Priority | Effort | Status |
|-------|-------|----------|--------|--------|
| [RALPH-SUBAGENTS-1](story-subagents-1-explorer.md) | Create ralph-explorer.md agent definition | Important | Small | Open |
| [RALPH-SUBAGENTS-2](story-subagents-2-tester.md) | Create ralph-tester.md agent with worktree isolation | Important | Small | Open |
| [RALPH-SUBAGENTS-3](story-subagents-3-reviewer.md) | Create ralph-reviewer.md agent definition | Nice-to-have | Small | Open |
| [RALPH-SUBAGENTS-4](story-subagents-4-ralph-integration.md) | Update ralph.md to reference and spawn sub-agents | Important | Small | Open |
| [RALPH-SUBAGENTS-5](story-subagents-5-failure-handling.md) | Add sub-agent failure handling and SubagentStop hook | Important | Medium | Open |

## Implementation Order

1. **RALPH-SUBAGENTS-1 + 2 + 3** — Agent definitions are independent, create in parallel.
2. **RALPH-SUBAGENTS-4** — Update main agent to reference sub-agents. Depends on 1-3.
3. **RALPH-SUBAGENTS-5** — Failure handling. Depends on 4.

## Verification Criteria

- [ ] `ralph-explorer` spawns and returns codebase search results
- [ ] `ralph-tester` runs in worktree without file conflicts
- [ ] `ralph-reviewer` produces structured code review output
- [ ] Main agent context reduced by 30%+ (measured via `/cost`)
- [ ] Sub-agent failures don't crash the main loop
- [ ] SubagentStop hook logs sub-agent completion to `.ralph/live.log`

## Rollback

Remove sub-agent definitions from `.claude/agents/`. Ralph falls back to in-context
exploration and testing (v0.11.x behavior). No code changes needed in `ralph_loop.sh`.
