---
title: "ADR-0006: Delete legacy `-p` mode and the `ALLOWED_TOOLS` allowlist"
status: accepted
date: 2026-04-28
deciders: Ralph maintainers
tags: [cli, agent-mode, security, breaking-change]
audience: [contributor, integrator, operator]
diataxis: explanation
last_reviewed: 2026-04-28
---

# ADR-0006: Delete legacy `-p` mode and the `ALLOWED_TOOLS` allowlist

## Context

Up through this ADR, `ralph_loop.sh` had two ways to invoke the Claude Code CLI per loop:

| Mode | CLI | Tool gating |
|---|---|---|
| **Agent mode** (modern) | `claude --agent ralph` | `tools:` allowlist + `disallowedTools:` blocklist in `.claude/agents/ralph.md` |
| **Legacy `-p` mode** (older) | `claude -p <prompt> --allowedTools <list>` | `ALLOWED_TOOLS=` allowlist in `.ralphrc` |

Choice was driven by `RALPH_USE_AGENT` plus an auto-fallback when the project's `.ralphrc` had a custom `ALLOWED_TOOLS` value (Issue #154). Agent mode honors the agent file's `model:`, `permissionMode:`, `effort:`, `maxTurns:`, and `memory:` directives. Legacy mode honored none of them — those fields were silently dropped.

This produced a real bug. NLTlabsPE pinned a hardened `ALLOWED_TOOLS` allowlist (Issue #149 fix), which auto-tripped the legacy fallback. The agent file's `model: sonnet` directive was then bypassed every loop and Claude Code defaulted to its session model — which since Apr 2026 is `claude-opus-4-7`. NLTlabsPE quietly burned ~3× the expected per-loop cost ($1.54/loop on Opus vs ~$0.30–0.50 on Sonnet) for an entire campaign before the discrepancy was spotted.

The two modes also interleaved in 30+ branches across `ralph_loop.sh`, `templates/ralphrc.template`, `templates/ralph.config.json`, `lib/enable_core.sh`, and 8 test files. Every change to permissions or model config had to thread through both branches, plus the silent-fallback decision matrix.

## Decision

**Delete legacy mode entirely.** Always invoke `claude --agent <RALPH_AGENT_NAME>`. Hard-fail when the CLI doesn't support `--agent` rather than silently falling back.

Concrete deletions (commit `3513643` + `001131d`):

- `RALPH_USE_AGENT` toggle.
- `RALPH_DEFAULT_ALLOWED_TOOLS` constant.
- `CLAUDE_ALLOWED_TOOLS` env capture, JSON-config field, env-restore plumbing.
- `VALID_TOOL_PATTERNS` array + `validate_allowed_tools()` function.
- `--allowed-tools` CLI flag + tmux forwarding + help-text entry.
- `_allowed_tools_customized` detection logic + the entire legacy fallback branch in `build_claude_command` (~80 LOC).
- Two-mode permission-denial advice paths (now one).
- Two-mode dry-run "Mode:" line (now one).

Tool restrictions now live in:

1. **`.claude/agents/ralph.md`** — `tools:` allowlist (built-in tools and specific MCP tool names) + `disallowedTools:` blocklist (Bash sub-commands).
2. **`.claude/hooks/validate-command.sh`** — PreToolUse hook that hard-blocks destructive bash patterns (`rm -rf`, `git reset --hard`, `git clean -f*`, `git rm`, etc.) at the harness layer regardless of agent settings.
3. **`.claude/hooks/protect-ralph-files.sh`** — PreToolUse hook that protects `.ralph/`, `.claude/`, and `.ralphrc` from agent writes.

The BRAIN-PHASE-B0 narrowing (the 5 `mcp__tapps-brain__brain_*` tools that mattered, vs. the ~55-tool wildcard that didn't) migrates from `.ralphrc` `ALLOWED_TOOLS` into the agent file's `tools:` block — same constraint, new home.

`CLAUDE_MIN_VERSION` is bumped from `2.0.76` to `2.1.0` (the floor at which `--agent` is supported), so the existing startup version check fails fast on too-old CLIs.

Layer B (modern CLI flags vs. stdin piping at `ralph_loop.sh:3786`) is **kept**. That's a separate defensive fallback for CLI-version skew, low complexity, unrelated to this ADR.

## Consequences

### What gets better

- **Agent directives are always honored.** `model: sonnet`, `effort: medium`, `maxTurns: 50`, and `memory: project` from the agent file actually reach the CLI. The NLTlabsPE Opus-blow-up cannot recur silently.
- **One code path, not two.** ~290 LOC removed from `ralph_loop.sh` alone. The configuration matrix collapses from "agent ∨ legacy ∨ auto-fallback" to "agent."
- **Cleaner permissions story.** "Edit `.claude/agents/ralph.md` or `.claude/hooks/validate-command.sh`" replaces "edit `ALLOWED_TOOLS` in `.ralphrc`, but only if you want legacy mode, which auto-engages if you customize ALLOWED_TOOLS, which is incompatible with agent mode's `disallowedTools` blocklist."
- **Hard-fail on too-old CLI.** If the CLI doesn't support `--agent`, the loop logs a clear `ERROR: update to v2.1+ via $CLAUDE_CODE_CMD update` and exits — instead of silently bypassing the agent's model and tool config.

### What this breaks (downstream impact)

This is a breaking change for existing Ralph-managed projects. There is no shim, no compatibility code path, and no automated migrator (per the "we move forward, others adapt" decision). Existing projects will:

- **Silently ignore** any `RALPH_USE_AGENT=...` and `ALLOWED_TOOLS=...` lines remaining in their `.ralphrc` — these variables no longer exist in the loop, the `.ralphrc` is sourced as bash and unknown variables are just unused.
- **Lose any custom Bash sub-command allowlist entries** that were in `ALLOWED_TOOLS`. If a project had `Bash(uv *)` in its allowlist (tapps-mcp does), Claude in agent mode now reaches that command via the `Bash` umbrella in the agent's `tools:` block — non-destructive commands still work. Destructive patterns (`rm -rf`, `git reset --hard`, `git clean`) remain blocked by `validate-command.sh`. Effectively no project should see a security regression.
- **Need Claude CLI v2.1+.** Older CLIs hard-fail with a clear update instruction.

See **[MIGRATING.md](../../MIGRATING.md)** for the two-line `.ralphrc` cleanup downstream projects need to do.

### Alternative considered

**Keep both modes, fix the model-bypass bug.** Rejected. The bug was the surface symptom, not the root cause. The dual-mode design produces a configuration matrix where agent directives sometimes apply and sometimes don't depending on whether the user customized `ALLOWED_TOOLS` for security reasons. Patching the symptom would have left every future model/effort/permissions change conditional on which silent path the loop took. The cost of carrying that complexity outweighs the cost of the breaking change.

### Out of scope

- **SDK runtime** (`sdk/ralph_sdk/config.py:89` `use_agent: bool = True`) still has its own `use_agent` flag. The SDK isn't deployed anywhere today; the cleanup belongs in a follow-up TAP. While both runtimes default to agent mode, behavior matches.
- **`ralph_import.sh`** still uses `--allowedTools` for its one-shot PRD-to-fix-plan conversion. That's a separate Claude invocation outside the loop, not part of this ADR.

## References

- Originating bug discussion: NLTlabsPE Opus-cost analysis, 2026-04-28.
- Removed code: commits `3513643` (loop deletion), `001131d` (templates + tests + agent-file MCP migration), `<docs-commit>` (this ADR + MIGRATING.md + cross-doc cleanup).
- Related: ADR-0005 (Bash + Python SDK duality) — does not change; SDK still tracks the bash loop's contract.
- Issues retired: #149 (broad `Bash(git *)`), #154 (allowlist/blocklist incompatibility), HOOKS-6 stories about `RALPH_USE_AGENT`.
