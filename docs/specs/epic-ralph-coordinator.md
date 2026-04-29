# Epic: ralph-coordinator — brain-backed task briefing + two-way consultation

**Epic IDs:** [TAP-912](https://linear.app/tappscodingagents/issue/TAP-912) (foundation) + [TAP-919](https://linear.app/tappscodingagents/issue/TAP-919) (persistent sessions)
**Priority:** High (TAP-912) / Medium (TAP-919)
**Status:** Backlog — spec-ready, not yet started
**Source:** Design conversation 2026-04-22 — comparison of Ralph vs ChatDev multi-agent patterns
**Depends on:** None (Epic 1); Epic 1 must be Done before Epic 2

---

## Problem Statement

Ralph has 5 sub-agents (`ralph`, `ralph-architect`, `ralph-reviewer`, `ralph-tester` + `ralph-bg-tester`, `ralph-explorer`) organized as a one-way pipeline: the main `ralph` agent spawns specialists via the `Task` tool, consumes results, and proceeds. This is fundamentally different from ChatDev's multi-agent "seminar" model where agents hold two-way conversations to reach consensus before acting.

Three concrete gaps in the current architecture:

1. **No shared task context across sub-agents.** Each spawned agent starts with only its narrow prompt. No agent holds the *why* of the current task or its acceptance criteria beyond what the main ralph inlines into the prompt.

2. **tapps-brain is registered but unused by agents.** `.mcp.json` configures tapps-brain as an MCP server with `brain_recall`/`brain_remember`/`brain_learn_*` tools. Grepping all six agent `.md` files shows zero references. The shell hook `lib/brain_client.sh` bypasses Claude entirely and POSTs to `/v1/remember` directly from `on-stop.sh` — its own comment admits "Claude never organically called brain_recall/remember from a non-brain repo" ([lib/brain_client.sh:6-8](../../lib/brain_client.sh#L6-L8)). As a result brain writes are coarse (loop-success / loop-failure only) and no agent reads from brain at all.

3. **Sub-agents are spawn-and-die.** The `Task` tool kills the agent when it returns. Each invocation starts amnesiac — no continuity of context within a task, no way for a sub-agent to push back mid-execution.

### Impact

- Same architectural mistakes recur across sessions (brain has no useful entries to prevent them)
- No mechanism to dynamically inject QA/architect mid-task based on observed risk — only epic-boundary deferral
- Ralph cannot consult a second opinion before committing to an approach, even on HIGH-risk changes
- Ralph-wide institutional memory does not exist — every session re-discovers the same patterns

## Solution Overview

Introduce a new **`ralph-coordinator`** sub-agent (Haiku, narrow-scope) whose primary tool surface is `mcp__tapps-brain__*`. Deliver in two epics:

- **Epic 1 (TAP-912)** — Coordinator as one-shot briefer per loop. Reads brain at task start, writes a structured `.ralph/brief.json` all sub-agents consume, records outcomes to brain at task boundary.
- **Epic 2 (TAP-919)** — Coordinator session persists across multiple exchanges within a task via `--continue session_id`. Main `ralph` can consult the coordinator mid-task; coordinator can push back (APPROVE/RECONSIDER/BLOCK) and dynamically elevate QA requirements.

## Architecture

### Current state (one-way pipeline)

```
 LOOP HARNESS
     │
     ▼
 build_loop_context()  ──► --append-system-prompt
     │
     ▼
 main ralph agent (Sonnet)
     │ Task(explorer)  ──► ralph-explorer (Haiku)  [dies on return]
     │ Task(tester)    ──► ralph-tester (Sonnet)   [dies on return]
     │ Task(reviewer)  ──► ralph-reviewer (Sonnet) [dies on return]
     │ Task(architect) ──► ralph-architect (Opus)  [dies on return]
     ▼
 status.json
     │
     ▼
 on-stop.sh hook  ──► lib/brain_client.sh  ──► POST /v1/remember  (coarse: pass/fail)
```

### Target state with Epic 1 (briefer model)

```
 LOOP HARNESS
     │
     ▼
 ralph_coordinator_invoke brief
     │
     ▼
 ralph-coordinator (Haiku)
     │ brain_recall(keywords=[task_id, modules, task_type])
     │ risk classification (LOW/MEDIUM/HIGH)
     │ writes .ralph/brief.json
     ▼
 build_loop_context()  ──► --append-system-prompt (with brief.json hint)
     │
     ▼
 main ralph agent  ──► reads brief.json first
     │ Task(explorer)  ──► ralph-explorer      ──► reads brief.json
     │ Task(tester)    ──► ralph-tester        ──► reads brief.json (qa_scope)
     │ Task(reviewer)  ──► ralph-reviewer      ──► reads brief.json (risk_level)
     ▼
 ralph_coordinator_invoke debrief (at task boundary)
     │ brain_learn_success|brain_learn_failure
     │ brain_remember (non-obvious insight)
     │ brief_clear
     ▼
 on-stop.sh hook  ──► lib/brain_client.sh  [DEMOTED — fallback only when brief.json missing]
```

### Target state with Epic 2 (persistent advisor)

```
 Within a single task:

 LOOP HARNESS
     │
     ▼
 ralph_coordinator_invoke brief
     │                             ┐
     ▼                             │
 coordinator spawns                │
 captures session_id ──► .ralph/.coordinator_session
                                   │
 main ralph works                  │  persistent session
     │                             │  accumulates context
     │ bash lib/coordinator_rpc.sh │  across all invocations
     │      consult "PLAN: X"      │
     │                             ▼
     │ ◄─── --continue $sid ──► ralph-coordinator (same session)
     │         verdict: APPROVE|RECONSIDER|BLOCK
     │         elevated_qa: true|false
     │
     ├─► if elevated_qa: patch brief.qa_required = true (forces tester mid-epic)
     ├─► if BLOCK: write .coordinator_block flag (loop skips commit this loop)
     │
     ▼ more exchanges across the task...
 ralph_coordinator_invoke debrief
     │ (same session_id — remembers the whole arc)
     ▼
 brief_clear + session_clear (lifecycle trigger: task complete, CB, is_error)
```

## Key Design Decisions

### D1: Coordinator is Haiku, not Sonnet or Opus
The coordinator does not write code, read large files, or execute tests. It reads task context, calls brain, classifies risk, writes a short JSON file. Haiku is sufficient and keeps per-loop cost trivial (the primary objection to persistent-session designs).

### D2: Coordinator is the ONLY agent with brain write tools
Concentrating brain-write authority in the coordinator avoids the "everyone kinda writes to brain" anti-pattern. Other agents read the brief (which contains brain-retrieved learnings); they do not write to brain directly. This makes brain write cadence predictable and auditable.

### D3: `.ralph/brief.json` is stateless per task, not per loop
The brief is written at task start, updated mid-task via `brief_patch_field` (Epic 2), and cleared at task boundary (on EXIT_SIGNAL or no-remaining-tasks). Mirrors the lifecycle of `.claude_session_id`.

### D4: Shell-hook brain writes demoted, not removed
`lib/brain_client.sh` stays in the codebase as a fallback. When `RALPH_COORDINATOR_DISABLED=true` or `brief.json` is absent (coordinator crashed / timed out), `on-stop.sh` falls back to the direct POST. This is defense-in-depth — we never silently stop writing to brain.

### D5: Persistent sessions use `--continue <session_id>`, not new infrastructure
Ralph's main session already uses `--continue` for cross-loop continuity. The same mechanism applies to the coordinator. No new transport, no new protocol — just capture the session_id from JSONL output (pattern proven at [sdk/ralph_sdk/agent.py:1335-1348](../../sdk/ralph_sdk/agent.py#L1335-L1348)) and pass it back on subsequent invocations.

### D6: Consultation is opt-in per risk level
The main ralph agent consults the coordinator ONLY on HIGH-risk tasks (per `brief.risk_level`). LOW and MEDIUM tasks skip consultation entirely. This preserves Ralph's per-loop throughput on routine work. Consultation is for architectural judgment, not micromanagement.

### D7: Three verdicts with well-defined semantics
- `APPROVE` — proceed, no concerns
- `RECONSIDER` — valid concern exists, alternative suggested, ralph evaluates and may override
- `BLOCK` — hard constraint violated (acceptance criteria, security, published API), loop skips commit this iteration; ralph retries next loop with feedback baked in

`BLOCK` does not auto-rollback uncommitted changes — ralph keeps its work-in-progress and tries again. This avoids catastrophic loss of work from a coordinator false-positive.

### D8: What the coordinator KNOWS that ralph doesn't
The coordinator's value is in holding information ralph lacks:
- Brain-retrieved prior learnings (what failed last time on similar tasks)
- Accumulated session context across ralph's implementation choices within the current task (Epic 2 only)
- Acceptance criteria cross-checked against the plan
- Risk classification informed by prior-failure density

Without this information asymmetry, consultation is theater. The two-way communication only has value because the coordinator brings what ralph cannot derive from the code.

## `.ralph/brief.json` Schema (v1)

```json
{
  "schema_version": 1,
  "task_id": "TAP-912",
  "task_source": "linear|file",
  "task_summary": "one sentence",
  "risk_level": "LOW|MEDIUM|HIGH",
  "affected_modules": ["lib/linear_backend.sh", "ralph_loop.sh"],
  "acceptance_criteria": ["criterion 1", "criterion 2"],
  "prior_learnings": [
    {"source": "brain_recall", "tier": "procedural", "content": "..."}
  ],
  "qa_required": true,
  "qa_scope": "tests/unit/test_linear.bats",
  "delegate_to": "ralph|ralph-architect",
  "coordinator_confidence": 0.9,
  "created_at": "2026-04-22T22:30:00Z"
}
```

Validation + helpers in `lib/brief.sh` (see TAP-914).

## Consultation Response Schema (Epic 2)

```json
{
  "verdict": "APPROVE|RECONSIDER|BLOCK",
  "reason": "one sentence explaining verdict",
  "alternative": "one sentence (only when RECONSIDER or BLOCK)",
  "elevated_qa": false
}
```

## Stories

### Epic 1 — TAP-912

| # | Ticket | Title | Complexity | Blocked by |
|---|--------|-------|------------|------------|
| 1.1 | [TAP-913](https://linear.app/tappscodingagents/issue/TAP-913) | Create ralph-coordinator agent definition | SMALL | — |
| 1.2 | [TAP-914](https://linear.app/tappscodingagents/issue/TAP-914) | Define `.ralph/brief.json` schema + bash helpers | SMALL | — |
| 1.3 | [TAP-915](https://linear.app/tappscodingagents/issue/TAP-915) | Spawn coordinator in `ralph_loop.sh` before main ralph | MEDIUM | 1.1, 1.2 |
| 1.4 | [TAP-916](https://linear.app/tappscodingagents/issue/TAP-916) | Update 6 existing sub-agents to consume `brief.json` | MEDIUM | 1.3 |
| 1.5 | [TAP-917](https://linear.app/tappscodingagents/issue/TAP-917) | Coordinator `brain_recall` at start, `brain_learn` at end | MEDIUM | 1.3 |
| 1.6 | [TAP-918](https://linear.app/tappscodingagents/issue/TAP-918) | Metrics + demote shell-hook writes to fallback | MEDIUM | 1.5 |

### Epic 2 — TAP-919 (blocked by Epic 1 complete)

| # | Ticket | Title | Complexity | Blocked by |
|---|--------|-------|------------|------------|
| 2.1 | [TAP-920](https://linear.app/tappscodingagents/issue/TAP-920) | Capture + persist coordinator `session_id` | SMALL | TAP-912 epic |
| 2.2 | [TAP-921](https://linear.app/tappscodingagents/issue/TAP-921) | Resume-or-spawn pattern via `--continue` | MEDIUM | 2.1 |
| 2.3 | [TAP-922](https://linear.app/tappscodingagents/issue/TAP-922) | Main ralph consults coordinator on HIGH-risk | MEDIUM | 2.2 |
| 2.4 | [TAP-923](https://linear.app/tappscodingagents/issue/TAP-923) | Dynamic QA injection + BLOCK enforcement | MEDIUM | 2.3 |
| 2.5 | [TAP-924](https://linear.app/tappscodingagents/issue/TAP-924) | Session lifecycle cleanup | SMALL | 2.2 |

## Out of Scope

- Replacing `lib/brain_client.sh` entirely (stays as fallback — D4)
- Extending persistent sessions to other sub-agents — tester/reviewer/explorer remain ephemeral
- Cross-task persistent sessions — task boundary clears session; cross-task memory is via brain
- Making consultation mandatory on MEDIUM/LOW risk tasks — preserves throughput
- New coordinator verdicts beyond APPROVE/RECONSIDER/BLOCK
- Auto-rollback on BLOCK — ralph retries with feedback, never discards work

## Verified Facts (as of 2026-04-22)

- 6 agents in `.claude/agents/`: `ralph`, `ralph-architect`, `ralph-reviewer`, `ralph-tester`, `ralph-explorer`, `ralph-bg-tester`
- `grep -l "mcp__tapps-brain__" .claude/agents/*.md` → empty (no agent declares brain tools in its definition)
- Brain tools listed in project-level `ALLOWED_TOOLS` at [templates/ralphrc.template:72](../../templates/ralphrc.template#L72) — applies to main ralph CLI invocation only, NOT to Task-spawned sub-agents
- `lib/brain_client.sh` comment (line 6-8) confirms soft-prompt approach failed; current brain writes are shell-hook-only
- Linear project: `Ralph Continuous Coding` (id `73125846-2148-4fd0-8a8e-902e7cc6b36c`) in team `TappsCodingAgents`
- Labels applied: `Feature`/`Improvement`, `agent-core`, `brain-api` (where applicable), `spec-ready`

## Related

- [lib/brain_client.sh](../../lib/brain_client.sh) — existing shell-hook brain writer, demoted to fallback in story 1.6
- [.mcp.json](../../.mcp.json) — tapps-brain MCP server registration
- [docs/LINEAR-WORKFLOW.md](../LINEAR-WORKFLOW.md) — state lifecycle for Linear-managed tickets
- [templates/ralphrc.template](../../templates/ralphrc.template) — project-level `ALLOWED_TOOLS` config
