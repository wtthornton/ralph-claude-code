# Fix: coordinator must not write `no-task` EXIT briefs from brain memory alone

**Origin:** AgentForge campaign 2026-05-26 18:03–18:17 (PID 878326). 2 loops; loop 1 ignored a bad brief and worked on TAP-2591; loop 2 trusted the bad brief and exited the campaign on a non-empty backlog (TAP-2591 was still open at exit).

**Linear:** follow-up under [TAP-2493](https://linear.app/tappscodingagents/issue/TAP-2493) (idle-runaway fix epic). Distinct mechanism from the on-stop parser bug — that one mis-recorded a legitimate exit signal as no-progress. This one *correctly* records an *illegitimate* exit signal that the coordinator pre-emitted.

## Root cause

Three reinforcing layers:

1. `linear_get_next_task` in [lib/linear_backend.sh:412](../../lib/linear_backend.sh#L412) early-returns when `LINEAR_API_KEY` is unset (OAuth-via-MCP mode). In that mode — the only one operators actually run — `TASK_INPUT:` passed to the coordinator is empty every loop.
2. The coordinator's `MODE=brief` contract in [.claude/agents/ralph-coordinator.md:50-65](../../.claude/agents/ralph-coordinator.md#L50) does not specify what to do with an empty `TASK_INPUT` in Linear mode. The coordinator falls back to `brain_recall`.
3. A poisoned `brain_remember` entry (`agentforge-e946ee8e9b10058f`, tier=procedural, confidence=0.6, tagged `failure`) tells future coordinators: "team=TappsCodingAgents / project=AgentForge Platform — backlog confirmed empty, emit EXIT_SIGNAL." Each empty-input session's debrief reinforces the lie. The coordinator writes a `task_id: "no-task"` brief whose `acceptance_criteria` mandates `EXIT_SIGNAL: true`, the worker trusts it, and the campaign exits on a non-empty backlog.

The coordinator's actual `list_issues` calls were correctly scoped to `team=TappsCodingAgents` (verified in the stream log). The wrong-team mechanism the operator initially suspected didn't fire this incident — but the underlying contract gap (the coordinator agent file says "team/project from your input" while the spawn body in `ralph_spawn_coordinator` didn't include them) is a real latent issue addressed by the bash-side half of this fix.

## Fix shape

Two changes, applied together:

1. **Bash side (already landed in this PR):** [ralph_loop.sh](../../ralph_loop.sh) — `ralph_spawn_coordinator` now injects `RALPH_LINEAR_TEAM=` and `RALPH_LINEAR_PROJECT=` lines into the coordinator's input body when both are set and `task_source=linear`. Three new BATS cases in [tests/unit/test_coordinator_spawn.bats](../../tests/unit/test_coordinator_spawn.bats) lock this in.

2. **Agent contract side (must be applied manually — see patch below):** [.claude/agents/ralph-coordinator.md](../../.claude/agents/ralph-coordinator.md) `MODE=brief` step 1–3 — mandate a fresh `list_issues` probe across all three open states (`started`, `unstarted`, `backlog`) before writing any brief whose `acceptance_criteria` mentions `EXIT_SIGNAL`. Brain memory is explicitly demoted from "evidence" to "hint to verify."

The agent contract change cannot be made via `Edit`/`Write` from inside the Claude Code harness — [.ralph/hooks/protect-ralph-files.sh](../../.ralph/hooks/protect-ralph-files.sh) blocks all writes under `.claude/agents/` to prevent the autonomous loop from disarming itself. This is by design. Apply the patch below from a non-harness shell.

## How to apply the agent-file change (outside the Claude Code harness)

The replacement file lives at `docs/specs/ralph-coordinator.md.proposed` —
verify the diff, then move it into place:

```bash
cd /home/wtthornton/code/ralph-claude-code

# Inspect the diff first.
diff -u .claude/agents/ralph-coordinator.md docs/specs/ralph-coordinator.md.proposed

# Apply.
mv docs/specs/ralph-coordinator.md.proposed .claude/agents/ralph-coordinator.md
```

Run this from a non-Claude-Code shell — the project's
`.ralph/hooks/protect-ralph-files.sh` and `validate-command.sh` hooks
block writes/redirects/`mv` targets under `.claude/agents/` from inside
the harness. That is the protection layer doing its job; the operator is
the one allowed to update the agent contract.

## Verification

After applying the patch:

1. Re-source the project's Claude Code session (so the new agent contract is picked up).
2. Confirm the coordinator's `MODE=brief` body in [.claude/agents/ralph-coordinator.md](../../.claude/agents/ralph-coordinator.md) contains the strings `Empty TASK_INPUT in Linear mode — mandatory fresh probe` and `Hard rule on EXIT_SIGNAL acceptance criteria`.
3. Optional one-off cleanup (the operator's call): remove the poisoned brain entry `agentforge-e946ee8e9b10058f` so the next campaign starts clean. Once the contract change lands, the coordinator stops generating `no-task` EXIT briefs, so debrief stops reinforcing the lie and the memory ages out via the procedural-tier decay even if left in place.

## Why this is a separate fix from the TAP-2493 epic

TAP-2493 closes the case where the on-stop parser silently records a *legitimate* `EXIT_SIGNAL: true` as no-progress, opening the circuit breaker, ralph-runner relaunching, and the cycle repeating against an empty backlog. That work has shipped (see `epic-idle-runaway-fix.md`).

This fix closes the case where the coordinator pre-emits the EXIT_SIGNAL *directive* into a brief based on a stale brain memory, and a faithful worker honors it on a non-empty backlog. The parser is doing its job correctly; the input is wrong.

Same campaign, sibling bug class. Worth tracking under TAP-2493 as a follow-up rather than its own epic — the test coverage and observability work in TAP-2493 already covers this surface.
