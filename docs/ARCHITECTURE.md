---
title: Ralph architecture
description: How Ralph's loop, hooks, sub-agents, and state files fit together.
audience: [operator, contributor]
diataxis: explanation
last_reviewed: 2026-04-23
---

# Ralph architecture

This document explains how Ralph works. It complements:

- **[Main README](../README.md)** — what Ralph does and how to run it
- **[CLI reference](cli-reference.md)** — every flag and env var
- **[GLOSSARY](GLOSSARY.md)** — vocabulary used throughout this doc
- **[ADRs](decisions/)** — why the design choices below were made
- **[`../CLAUDE.md`](../CLAUDE.md)** — invariants and design notes for contributors

## One-paragraph summary

Ralph is a bash loop that invokes the Claude Code CLI with a carefully constructed prompt, parses the response via a `Stop` hook into `status.json`, evaluates a dual-condition exit gate, and repeats until the work is done or a safety mechanism fires. Everything around that core — rate limiting, circuit breakers, session continuity, sub-agent delegation, file protection, metrics, notifications, sandboxing — is built out of small bash modules in [`lib/`](../lib/) plus hook scripts in [`templates/hooks/`](../templates/hooks/). An optional Python SDK in [`sdk/ralph_sdk/`](../sdk/ralph_sdk/) mirrors the same state machine for embedding inside other applications.

## The loop

```
┌──────────────────────────────────────────────────────────────┐
│ Pre-flight                                                   │
│  • Validate Claude CLI exists and version check              │
│  • Acquire flock on .ralph/.ralph.lock                       │
│  • Check .killswitch sentinel                                │
│  • Probe MCP servers (tapps-mcp, tapps-brain, docs-mcp)      │
│  • Run plan optimizer over fix_plan.md                       │
│  • Pre-flight empty-plan check (short-circuit if no work)    │
└──────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌──────────────────────────────────────────────────────────────┐
│ Loop iteration                                               │
│                                                              │
│  1. should_exit_gracefully()                                 │
│        │                                                     │
│        ▼                                                     │
│  2. build_loop_context() — compose --append-system-prompt    │
│        │  (injects Linear issue, MCP guidance, skill hints)  │
│        ▼                                                     │
│  3. Invoke Claude CLI via timeout + stream capture           │
│        │                                                     │
│        ▼                                                     │
│  4. Stop hook (on-stop.sh) fires:                            │
│       • parses RALPH_STATUS block                            │
│       • writes status.json atomically                        │
│       • updates .circuit_breaker_state                       │
│       • records metrics and Linear counts                    │
│        │                                                     │
│        ▼                                                     │
│  5. Loop reads status.json (not raw output)                  │
│        │                                                     │
│        ▼                                                     │
│  6. Evaluate exit gate and circuit breaker                   │
│        │                                                     │
│        ├── exit conditions met → cleanup and exit            │
│        ├── CB open, no auto-reset → cleanup and exit         │
│        └── else → sleep 2s, go to 1                          │
└──────────────────────────────────────────────────────────────┘
```

[`ralph_loop.sh`](../ralph_loop.sh) is ~2,500 lines of bash. It sources library modules from [`lib/`](../lib/), and never parses Claude's output directly — that's the hook's job.

## Exit gate

Two independent signals must both agree:

1. **`completion_indicators >= 2`** — the bash loop keeps a rolling count of "looks done" signals derived from text NLP on the response (phrases like "all tests passing", "task completed", explicit `DONE` markers in logs).
2. **`EXIT_SIGNAL: true`** — Claude writes a structured `RALPH_STATUS` block at the end of each response. The `EXIT_SIGNAL` field is a boolean the model sets when it believes nothing is left to do.

**Why both.** Either signal alone is too fragile: heuristics produce false positives when the agent talks about other tests that pass; Claude's own "done" claim is unreliable mid-epic because the model optimizes for a locally plausible stopping point.

See [ADR-0001](decisions/0001-dual-condition-exit-gate.md) and the `should_exit_gracefully()` function in [`ralph_loop.sh`](../ralph_loop.sh).

**Preflight empty-plan check.** Before Claude is even invoked, Ralph greps `fix_plan.md` for unchecked `- [ ]` items (or asks the Linear backend for the open count). If zero, the loop short-circuits with `plan_complete` — no wasted Claude call. API failures from Linear **abstain** rather than treat unknown as zero, so a transient outage cannot trip a false `plan_complete`.

**Defense in depth: `EXIT-CLEAN` branch.** A 4th branch in the CB-update logic in `on-stop.sh` recognizes `EXIT_SIGNAL: true && STATUS: COMPLETE` with zero files/tasks as a *clean* exit — without it, an end-of-campaign loop where Claude correctly reports "all done" would be classified as no-progress and trip the breaker on the same signal Claude uses to ask for shutdown.

## RALPH_STATUS

After each response, Claude emits a structured block:

```
RALPH_STATUS
STATUS: IN_PROGRESS | COMPLETE | BLOCKED
WORK_TYPE: IMPLEMENTATION | TESTING | REVIEW | DEBUG | DOCS | EXPLORATION | UNKNOWN
TASKS_COMPLETED: 2
FILES_MODIFIED: 5
TESTS_STATUS: PASS | FAIL | DEFERRED | N/A
EXIT_SIGNAL: false
RECOMMENDATION: <one-sentence next step>
LINEAR_OPEN_COUNT: 7      # push-mode only
LINEAR_DONE_COUNT: 142    # push-mode only
```

The [`templates/hooks/on-stop.sh`](../templates/hooks/on-stop.sh) script parses this block from the JSONL stream (auto-unescaping embedded `\n` escapes), writes to `status.json` atomically, and updates the circuit breaker file. The loop reads only `status.json` — never the raw stream. This is a critical decoupling: it means any downstream consumer (the monitor, the Linear backend, SDK wrappers) sees a consistent shape.

See [ADR-0002](decisions/0002-hook-based-response-analysis.md).

## Circuit breaker

A three-state pattern in [`lib/circuit_breaker.sh`](../lib/circuit_breaker.sh):

```
            ┌─────────────────────────────────┐
            │                                 │
         progress                        CB_COOLDOWN_MINUTES
            │                                 │ elapsed
            ▼                                 ▼
    ┌──────────────┐                ┌──────────────────┐
    │    CLOSED    │ ── failures ─▶ │       OPEN       │
    │ (nominal)    │   threshold    │ (halted)         │
    └──────────────┘                └──────────────────┘
            ▲                                 │
            │                                 │
          success                       cooldown expires
            │                                 │
            └────── HALF_OPEN ◄───────────────┘
                    (probe)
```

- **CLOSED → OPEN**: sliding window in `CB_FAILURE_DECAY_MINUTES` (default 30) hits `CB_FAILURE_THRESHOLD` (default 5), **or** consecutive no-progress iterations hit `CB_NO_PROGRESS_THRESHOLD` (default 3).
- **OPEN → HALF_OPEN**: `CB_COOLDOWN_MINUTES` (default 30) elapses. `CB_AUTO_RESET=true` bypasses this for unattended operation.
- **HALF_OPEN → CLOSED**: next iteration records progress.
- **HALF_OPEN → OPEN**: next iteration records failure.

Fast-trip detectors (SDK-SAFETY-1): consecutive 0-tool-use runs under 30s, consecutive `TESTS_STATUS: DEFERRED`, consecutive timeouts. These bypass the window and open immediately.

## Session continuity

Claude session IDs persist in `.ralph/.claude_session_id` with a 24-hour expiration. Each invocation passes `--resume <id>` so the model keeps context. Sessions auto-reset on circuit-breaker OPEN, manual interrupt, or `is_error: true` from the API.

Rationale: agentic success rate drops after ~35 minutes of continuous session ([research](https://www.anthropic.com/research), internal measurement). Ralph's **Continue-As-New** pattern (CTXMGMT-3, inspired by Temporal) resets the session after `RALPH_MAX_SESSION_ITERATIONS` (default 20) or `RALPH_MAX_SESSION_AGE_MINUTES` (default 120), carrying forward only essential state (current task, progress, recommendation).

## Rate limiting

Four-layer API-limit detection in the loop:

1. **Timeout guard** — exit code 124 from `timeout` wrapper.
2. **Structural JSON** — `rate_limit_event` object in the JSONL stream.
3. **Filtered text** — quota-exceeded phrases in the last 30 lines, with echoed project content filtered out.
4. **Extra usage quota** — explicit Anthropic quota fields.

Per-hour call count in `.call_count`, hourly reset in `.last_reset`, cumulative tokens in `.token_count`. All written through `atomic_write()` (write to temp, fsync, rename). Token rate limiting is configurable via `MAX_TOKENS_PER_HOUR`.

**Plan-exhaustion auto-sleep**: When Claude hits the daily plan cap ("resets 9pm"), Ralph parses the reset time from output and sleeps with a countdown timer.

## Hooks

Eight hook events wired in [`.claude/settings.json`](../.claude/settings.json) and the project template:

| Event | Script | Purpose |
|---|---|---|
| SessionStart | `on-session-start.sh` | Emit structured log, seed metrics |
| PreToolUse (Bash) | `validate-command.sh` | Block destructive git/shell commands |
| PreToolUse (Write\|Edit) | `protect-ralph-files.sh` | Block modifications to `.ralph/` and `.claude/` |
| PostToolUse (Write\|Edit) | disabled for throughput | |
| PostToolUse (Bash) | disabled for throughput | |
| Stop | `on-stop.sh` | Parse RALPH_STATUS, write status.json, update CB |
| StopFailure | structured log | Record crash context |
| SubagentStop | structured log | Record sub-agent outcome |

Disabling `PostToolUse` hooks is a deliberate speed/safety tradeoff (v1.8.4+): `PreToolUse` catches problems before they land; skipping post hooks removes per-tool-call overhead.

The `Stop` hook writes `status.json` using atomic `mv` with `rm -f` fallback to prevent orphaned temp files on WSL/NTFS. It self-heals a corrupt `.circuit_breaker_state` by reinitializing to `CLOSED` with a WARN instead of crashing the loop (TAP-538).

## Sub-agents

Four specialized agents in [`.claude/agents/`](../.claude/agents/):

| Agent | Model | Isolation | Purpose |
|---|---|---|---|
| **ralph** | Sonnet | none (main) | Routine work, task batching, delegation router |
| **ralph-explorer** | Haiku | none | Read-only codebase search |
| **ralph-tester** | Sonnet | worktree | Test runner |
| **ralph-reviewer** | Sonnet | read-only | Code review before commit |
| **ralph-architect** | Opus | none | Complex/architectural tasks with mandatory review |
| **ralph-bg-tester** | Sonnet | background | Async test runner during next iteration |

Main Ralph runs on Sonnet with `bypassPermissions` and `effort: medium` for throughput. LARGE/ARCHITECTURAL tasks escalate to ralph-architect (Opus) with mandatory ralph-reviewer afterwards. See [ADR-0004](decisions/0004-epic-boundary-qa-deferral.md).

## Epic-boundary deferral

Mid-epic iterations are hot — the agent is in flow. End-of-epic is where mistakes land. Ralph defers expensive operations to epic boundaries (completion of the last `- [ ]` task under a `##` section):

- **QA** — ralph-tester and ralph-reviewer run at epic boundaries and before `EXIT_SIGNAL: true`. Mid-epic they're skipped and `TESTS_STATUS: DEFERRED` is set.
- **Explorer** — skipped for consecutive SMALL tasks in the same module; use Glob/Grep directly instead.
- **Backups** — `lib/backup.sh` snapshots at epic boundaries, not every loop.
- **Log rotation** — checked every 10 loops.
- **Batch sizes** — 8 SMALL / 5 MEDIUM tasks per invocation (increased because boundary QA catches regressions).

## State files

All under `.ralph/`:

| File | Written by | Read by | Purpose |
|---|---|---|---|
| `PROMPT.md` | you | loop, Claude | Development instructions |
| `fix_plan.md` | you + Claude | loop, Claude | Prioritized task list |
| `AGENT.md` | Claude | loop, Claude | Build/run instructions |
| `status.json` | `on-stop.sh` | loop, monitor | Current loop status (atomic) |
| `.call_count` / `.last_reset` | loop | loop | Hourly rate limit counter |
| `.token_count` | loop | loop | Hourly token counter |
| `.exit_signals` | loop | loop | Rolling exit-signal history |
| `.circuit_breaker_state` | `on-stop.sh`, loop | loop | CB state (JSON) |
| `.circuit_breaker_events` | loop | loop | Sliding-window failure log |
| `.claude_session_id` | loop | loop | Active session ID (24h expiry) |
| `.ralph_run_id` | loop | `on-stop.sh` | UUID-per-run, used to reset accumulators |
| `.killswitch` | operator | loop | File-sentinel emergency stop |
| `.ralph.lock` | loop (flock) | loop | Single-instance enforcement |
| `metrics/<yyyymm>.jsonl` | `lib/metrics.sh` | `ralph --stats` | Monthly metrics |
| `logs/ralph.log` | loop | operator | Rotating execution log |
| `logs/claude_output_*.log` | loop | `on-stop.sh`, operator | Per-iteration raw stream |

Writes go through `atomic_write()` (temp → fsync → rename). `set -o pipefail` is enabled after library sourcing so jq/grep pipelines don't silently mask broken inputs (TAP-535).

## Task backends

Ralph reads its work queue from one of two sources, selected by `RALPH_TASK_SOURCE`:

### File backend (default)

`RALPH_TASK_SOURCE=file`. Reads `.ralph/fix_plan.md`. Claude checks off `- [ ]` items as it goes; the loop counts unchecked items for the exit gate.

### Linear backend

`RALPH_TASK_SOURCE=linear`. Replaces `fix_plan.md` with Linear via the Linear MCP plugin (OAuth — no harness-side API key). Requires `RALPH_LINEAR_PROJECT`. Five integration points branch on this variable (exit check, dry-run display, `build_loop_context`, `ralph_continue_as_new`, startup pre-seeding). Claude lists, picks, and updates issues via `mcp__plugin_linear_linear__*`.

**Counts via on-stop hook (TAP-741).** Claude reports `LINEAR_OPEN_COUNT` and `LINEAR_DONE_COUNT` in its `RALPH_STATUS` block. The on-stop hook writes these to `.ralph/status.json`. `linear_get_open_count` / `linear_get_done_count` read from there. Entries older than `RALPH_LINEAR_COUNTS_MAX_AGE_SECONDS` (default 900) abstain.

**Fail-loud on stale counts.** When the count is unknown (no hook write yet on iteration 1, or stale beyond the max-age window), the count functions return non-zero with a structured stderr line and no stdout — callers must distinguish "exit non-zero" (unknown) from "exit 0 + value" (real result). Exit checks **abstain** on failure rather than treating unknown as zero (TAP-536). See [LINEAR-WORKFLOW.md](LINEAR-WORKFLOW.md) and [ADR-0003](decisions/0003-linear-task-backend.md).

## Bash ↔ SDK parity

The [Python SDK](sdk-guide.md) is not a thin wrapper — it's a full reimplementation of the same state machine in async Python. Modules mirror their bash counterparts 1:1:

| bash (`lib/`) | Python (`sdk/ralph_sdk/`) |
|---|---|
| `circuit_breaker.sh` | `circuit_breaker.py` |
| `complexity.sh` | `complexity.py` |
| `import_graph.sh` | `import_graph.py` |
| `plan_optimizer.sh` | `plan_optimizer.py` |
| `memory.sh` | `memory.py` |
| `metrics.sh` | `metrics.py` |

All SDK models are Pydantic v2. State I/O goes through a pluggable `RalphStateBackend` Protocol (`FileStateBackend` default, `NullStateBackend` for testing/embedding). The async agent loop has a `run_sync()` wrapper for CLI use.

**Why both.** CLI bash is fast to install, portable, and matches operator mental models. SDK Python is testable, type-checked, and embeddable. Migrating from one to the other is a deliberate runtime choice (`--sdk` flag), not a breaking change. See [ADR-0005](decisions/0005-bash-sdk-duality.md).

## MCP integration

Ralph probes three MCP servers at startup via `ralph_probe_mcp_servers()`:

| Server | Purpose | Injection gate |
|---|---|---|
| **tapps-mcp** | Code quality scoring, doc lookup, impact analysis | Unconditional |
| **tapps-brain** | Persistent cross-session memory with Hive sharing | Unconditional |
| **docs-mcp** | Doc generation, completeness/freshness/drift checks | Only when the task looks docs-related |

Each MCP is registered **by the project** (via `.mcp.json` or `claude mcp add`), never by Ralph. `build_loop_context()` injects a short "when to use" block per reachable server into `--append-system-prompt` so Claude reaches for the MCP tools instead of falling back to Read/Grep/Bash. Run `ralph --mcp-status` to see which probes succeeded.

## Cross-platform notes

- **WSL divergence**: Ralph checks `~/.ralph/ralph_loop.sh` (WSL) against `/mnt/c/Users/*/.ralph/ralph_loop.sh` (Windows) on startup and warns if versions differ.
- **WSL PowerShell**: hooks calling bare `powershell` auto-patch to `powershell.exe` in-place.
- **MCP process cleanup**: `ralph_cleanup_orphaned_mcp()` kills grandchild `uv`/`python` MCP processes that survive CLI exit. On Windows uses `Get-CimInstance Win32_Process` with parent-alive check; on Linux/macOS/WSL uses `pgrep`/`kill` filtering by `PPID==1`. `tapps-brain` is excluded (runs as dockerized HTTP MCP).
- **Bash 4 required**: rejected at startup with a clear message.

## Loop safety

- **flock on `.ralph/.ralph.lock`** — prevents concurrent instances.
- **File protection hooks** — block modifications to `.ralph/`, `.claude/`, and `.ralphrc` in real-time.
- **Agent file `tools:` + `disallowedTools:`** — tool surface allowlist + bash-pattern blocklist defined in `.claude/agents/ralph.md`.
- **`validate-command.sh` PreToolUse hook** — hard-blocks destructive bash patterns (`rm -rf`, `git reset --hard`, `git clean`, `git rm`) regardless of agent settings.
- **Git integrity** — `git status` failure halts the loop (progress detection requires it).
- **Killswitch sentinel** — `touch .ralph/.killswitch` for headless stop; checked at the top of every iteration.
- **Atomic state writes** — every counter and state file goes through `atomic_write`.
- **`pipefail`** — enabled after library sourcing, so broken pipelines can't hide.

## Further reading

- [CLAUDE.md](../CLAUDE.md) — extensive contributor notes, including historical pitfalls (grep-c, EXIT-CLEAN branch, WSL/NTFS atomic-write races)
- [FAILURE.md](../FAILURE.md) — 12 failure modes with detection, response, fallback
- [FAILSAFE.md](../FAILSAFE.md) — degradation hierarchy and safe defaults
- [KILLSWITCH.md](../KILLSWITCH.md) — emergency stop signals, cleanup guarantees
- [ADRs](decisions/) — architectural decision records
- [Epic index](specs/EPIC-STORY-INDEX.md) — historical design specs (provenance, not current reference)
