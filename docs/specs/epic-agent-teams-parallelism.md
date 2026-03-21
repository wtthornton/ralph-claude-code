# Epic: Agent Teams + Parallelism (Phase 4)

**Epic ID:** RALPH-TEAMS
**Priority:** Nice-to-have (Experimental)
**Affects:** Large fix plan execution speed, parallel task processing
**Components:** `.claude/agents/`, `.claude/settings.json`, `.claude/settings.local.json`
**Related specs:** `claude-code-2026-enhancements.md` (§4.4, §4.5, §4.6, §5 Phase 4)
**Target Version:** v1.1.0 (post-v1.0 release)
**Depends on:** RALPH-HOOKS (Phase 1), RALPH-SUBAGENTS (Phase 2)

---

## Problem Statement

Ralph v0.11.x processes fix plan tasks sequentially — one `claude -p` call per task.
For large fix plans (60+ tasks), this takes hours. Claude Code 2026's agent teams
feature enables parallel execution with multiple teammates working on independent tasks
simultaneously, potentially reducing wall-clock time by 40%+ for large plans.

## Research-Informed Adjustments

Web research on Claude Code 2026 documentation (March 2026) identified the following
critical adjustments and **cautions** for the original RFC:

1. **Agent teams remain EXPERIMENTAL** as of March 2026. Enable via
   `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`. Known bugs include teammate message
   delivery issues and no session resumption with in-process teammates.

2. **Team architecture differs from sub-agents:** Teams use a shared task list with
   dependency tracking and file-locked claiming. Teammates are separate Claude Code
   instances (not sub-agents). They communicate via an inbox-based messaging system.

3. **Display mode limitations:**
   - `in-process` (default): all in main terminal, Shift+Down to cycle
   - `tmux` / `auto`: split panes (requires tmux or iTerm2)
   - **Split panes NOT supported in VS Code terminal, Windows Terminal, or Ghostty**
   - Configure via `teammateMode` in settings or `--teammate-mode` flag

4. **Team constraints:**
   - No session resumption with in-process teammates
   - One team per session, no nested teams
   - Lead is fixed (cannot transfer leadership)
   - All teammates start with lead's permission mode

5. **Background agents confirmed:** `background: true` in agent frontmatter is valid.
   Background agents run concurrently. Permissions are pre-approved at launch;
   unapproved tools are auto-denied. Press `Ctrl+B` to background a running task.

6. **Team hooks:** `TeammateIdle` (exit 2 keeps them working) and `TaskCompleted`
   (exit 2 prevents completion) are the relevant team hook events.

7. **Storage locations:**
   - Team config: `~/.claude/teams/{team-name}/config.json`
   - Task list: `~/.claude/tasks/{team-name}/`

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Feature instability (experimental) | High | High | Gate behind `RALPH_ENABLE_TEAMS=false` default |
| VS Code/Windows Terminal display issues | High | Medium | Document `tmux` mode requirement |
| Teammate message delivery bugs | Medium | High | Implement fallback to sequential mode |
| File conflicts between worktrees | Medium | High | Strict file ownership per teammate |
| No session resumption | Medium | Medium | Design for short-lived teammate sessions |

## Stories

| Story | Title | Priority | Effort | Status |
|-------|-------|----------|--------|--------|
| [RALPH-TEAMS-1](story-teams-1-config.md) | Enable agent teams configuration | Important | Small | **Done** |
| [RALPH-TEAMS-2](story-teams-2-team-strategy.md) | Implement team spawning strategy in ralph.md | Important | Medium | **Done** |
| [RALPH-TEAMS-3](story-teams-3-bg-tester.md) | Create ralph-bg-tester.md background agent | Nice-to-have | Small | **Done** |
| [RALPH-TEAMS-4](story-teams-4-team-hooks.md) | Add TeammateIdle and TaskCompleted hooks | Important | Small | **Done** |
| [RALPH-TEAMS-5](story-teams-5-worktree-support.md) | Add worktree support and .gitignore updates | Important | Trivial | **Done** |

## Implementation Order

1. **RALPH-TEAMS-5** (Trivial) — `.gitignore` update. No risk, do first.
2. **RALPH-TEAMS-1** (Small) — Configuration. Foundation for other stories.
3. **RALPH-TEAMS-3** (Small) — Background tester. Independent of teams.
4. **RALPH-TEAMS-4** (Small) — Team hooks. Depends on config.
5. **RALPH-TEAMS-2** (Medium) — Team strategy. Depends on all above.

## Verification Criteria

- [ ] 2-teammate run completes 4 independent tasks in parallel
- [ ] Wall-clock time reduced by 40%+ vs single-threaded (measured)
- [ ] No file conflicts between worktrees
- [ ] Background tester reports results while main agent works
- [ ] Team gracefully handles teammate failure
- [ ] Sequential fallback works when `RALPH_ENABLE_TEAMS=false`

## Rollback

Set `RALPH_ENABLE_TEAMS=false` (the default). All team infrastructure is gated behind
this flag. Background agent can be removed independently.
