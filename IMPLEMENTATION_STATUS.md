---
title: Implementation status
description: Snapshot of current Ralph state — version, test counts, epic completion, and active development focus.
audience: [contributor, operator, maintainer]
diataxis: reference
last_reviewed: 2026-04-23
---

# Implementation status

**Current version:** v2.8.3 (CLI) + SDK v2.1.0 • **Tests:** 1117+ passing (100% gate) • **Epic stories:** 148/148 complete across 50 epics (Phases 0-17)

## What "status" means now

Ralph's phase-based roadmap completed in v2.6.0. Since then the project has been in **maintenance + incremental feature** mode, driven by:

- **Linear tickets** (`TAP-XXX`) in the `TappsCodingAgents` workspace
- **Code review passes** that surface hardening opportunities
- **Production incident reports** from deployments running Ralph against real backlogs

See the `[Unreleased]` section of [CHANGELOG.md](CHANGELOG.md) for what's heading into the next release.

## Current state snapshot

| Area | State |
|---|---|
| **Core loop** | Stable; dual-condition exit gate, epic-boundary QA deferral, pre-flight empty-plan check |
| **Circuit breaker** | Three-state with cooldown, fast-trip, stall detection, session boundary reset |
| **Rate limiting** | Hourly call + token counters; plan-exhaustion auto-sleep |
| **Hooks** | Stop + PreToolUse (file-protect, command-validate); SessionStart/SubagentStop/StopFailure for telemetry |
| **Sub-agents** | ralph + ralph-architect + ralph-explorer + ralph-tester + ralph-reviewer + ralph-bg-tester |
| **Task sources** | File (`fix_plan.md`) and Linear (with push-mode fallback); GitHub Issues import |
| **SDK** | v2.1.0 — async, Pydantic v2, pluggable state backend, 17 modules |
| **MCP integration** | Probes tapps-mcp, tapps-brain, docs-mcp; injects guidance |
| **Platforms** | Linux, macOS, WSL2, Windows (via WSL or .cmd wrapper), Nix |
| **CI** | Blocking: unit + integration + deterministic evals. Informational: coverage, stochastic evals. |

## Recent releases

See [CHANGELOG.md](CHANGELOG.md) for full release notes. Recent notable versions:

| Version | Date | Theme |
|---|---|---|
| v2.8.3 | 2026-04-20 | TAP-741 push-mode Linear counts; monitor zero-token repair; MCP probe hang fix |
| v2.8.2 | 2026-04-20 | SKILLS-INJECT 5-8: friction detection, retro apply, periodic reconcile, telemetry |
| v2.8.1 | 2026-04-20 | Hardening: CB history cap, hook upgrade validation, SDK cost tracking, April 2026 model IDs |
| v2.7.2 | 2026-04-20 | Linear In-Review rule tightening; signal-trap cleanup |
| v2.7.1 | 2026-04-20 | 14-commit security hardening pass (TAP-621 through TAP-651) |
| v2.7.0 | 2026-04-19 | Global skill baseline (TAP-574/575); hook resilience (TAP-538); atomic state writes (TAP-535) |
| v2.6.0 | 2026-04 | Linear backend; `ralph-upgrade-project`; all 148 stories complete |
| v2.3.0 | 2026-01 | Phase 14 — OTel, sandbox v2, memory, cost routing |
| v2.0.0 | 2025-11 | SDK v2 + hook-based analysis + sub-agents (Phases 12-13) |

## Test coverage

| Layer | Files | Count | Blocking CI |
|---|---|---|---|
| Unit | ~25 files under `tests/unit/` | ~900 | Yes |
| Integration | ~10 files under `tests/integration/` | ~150 | Yes (TAP-537 removed `\|\| true` masking) |
| Deterministic evals | `tests/evals/deterministic/` | 64 | Yes |
| E2E | `tests/e2e/` with mock Claude CLI | varies | Yes |
| SDK | `sdk/tests/` pytest | ~150 | Yes for SDK PRs |
| Stochastic evals | `tests/evals/stochastic/` | N per run | No (nightly/manual) |

**Quality gate:** 100% pass rate. Run `npm test` for the live count; the 1117+ figure in README badges is updated via GitHub Actions.

## Active development focus

Rather than maintaining a rolling "what's in progress" section that goes stale the moment a ticket moves, the canonical sources are:

- **Short-term work (< 1 week):** `[Unreleased]` section of [CHANGELOG.md](CHANGELOG.md)
- **In-flight tickets:** Linear workspace `TappsCodingAgents`
- **Open GitHub issues:** https://github.com/wtthornton/ralph-claude-code/issues
- **Open design questions:** [docs/decisions/](docs/decisions/) with `status: proposed`

## Closed historical categories

These categories used to have active backlogs tracked in this file. All items are now complete or superseded:

- ✅ **Phase 1 — CLI Modernization** (v0.9.x): JSON output, modern CLI flags, session continuity
- ✅ **Phase 2 — Agent SDK** (v2.0.0): async agent, Pydantic models, pluggable state
- ✅ **Phase 3 — Configuration** (v1.8.x): `.ralphrc`, `ralph.config.json`, SDK install
- ✅ **Phase 4 — Validation testing** (v1.8.x): tmux, monitor, backward compat, E2E
- ✅ **Phase 5 — GitHub Issues** (v1.8.x): import, filter, batch, lifecycle
- ✅ **Phase 6 — Sandbox** (v1.8.x + v2.3.0): Docker v1 and v2 with rootless/gVisor
- ✅ **Phase 12 — Hooks + sub-agents** (v1.0.0): response analysis migrated out of the loop
- ✅ **Phase 13 — Guard rails** (v2.0.x): adaptive timeout, stream capture, CB decay
- ✅ **Phase 14 — Observability & cost** (v2.3.0): OTel, memory, cost routing
- ✅ **Phase 15 — Enable wizard** (v2.1.0): state detection, input validation, force safety
- ✅ **Phase 16 — LOGFIX** (v2.2.0): 8 production bug fixes from log analysis
- ✅ **Phase 17 — Upstream sync** (v2.5.0): question detection, stuck loop, heuristic exit suppression

## What's removed

For historical reference, major deletions during development:

- `lib/response_analyzer.sh` (−1,042 lines) — replaced by `on-stop.sh` hook
- `lib/file_protection.sh` (−58 lines) — replaced by PreToolUse hooks
- `lib/circuit_breaker.sh` simplification (−285 lines) — progress detection moved to hook

Total: ~1,385 lines of bash removed over the lifetime of the project, replaced by a smaller + cleaner hook-driven architecture.

## Related

- [CHANGELOG.md](CHANGELOG.md) — per-version change details
- [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md) — historical phase plan
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — how the system is built today
- [docs/specs/EPIC-STORY-INDEX.md](docs/specs/EPIC-STORY-INDEX.md) — full epic catalog (frozen)
- [docs/decisions/](docs/decisions/) — architecture decision records
