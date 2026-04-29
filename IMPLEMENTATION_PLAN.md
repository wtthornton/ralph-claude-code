---
title: Implementation plan
description: Ralph's historical development plan. All 148 stories across 50 epics are complete; current work is tracked in Linear.
audience: [contributor, maintainer]
diataxis: reference
last_reviewed: 2026-04-23
---

# Implementation plan

> **Status: historical.** Ralph's original phase-based implementation plan completed in v2.6.0. All **148 stories across 50 epics** (Phases 0-17) shipped. See [IMPLEMENTATION_STATUS.md](IMPLEMENTATION_STATUS.md) for the delivery summary. Current development is tracked in the **[TappsCodingAgents](https://linear.app/) Linear workspace** and per-issue via [TAP-XXX](https://linear.app/) tickets referenced in [CHANGELOG.md](CHANGELOG.md).

## Current development model

Ralph is in a post-roadmap phase. The historical "phases" structure that appeared in this file (Phase 1: CLI Modernization, Phase 2: SDK Integration, …) is complete. Ongoing work falls into three categories:

| Category | Where it's tracked |
|---|---|
| **Reliability fixes + features** | Linear tickets (`TAP-XXX`) → [CHANGELOG.md](CHANGELOG.md) |
| **New design decisions** | [docs/decisions/](docs/decisions/) ADRs |
| **Open backlog in GitHub** | [Issues](https://github.com/wtthornton/ralph-claude-code/issues) |

The full epic/story history lives in [docs/specs/](docs/specs/) — **frozen** as provenance, not rewritten.

## Completed phases (high-level)

| Phase | Focus | Version delivered |
|---|---|---|
| Phase 0 | Core autonomous loop, circuit breaker, rate limiting | v1.0 |
| Phase 1 | CLI modernization, session continuity, JSON output | v0.9.x |
| Phase 2 | Agent SDK integration (proof of concept) | v2.0.0 |
| Phase 3 | Configuration, JSON config, metrics, notifications, backup | v1.8.x |
| Phase 4 | Validation testing (tmux, monitor, status, E2E) | v1.8.x |
| Phase 5 | Stream parser v2, WSL reliability polish | v1.2.0 |
| Phase 6 | SDK Agent integration — hybrid CLI/SDK architecture | v2.0.0 |
| Phase 7 | JSON config, SDK installation, CLI + SDK docs | v1.8.x |
| Phase 8 | Metrics, notifications, backup/rollback | v1.8.x |
| Phase 9 | Validation testing (CLI, SDK, backward compat, E2E) | v1.8.x |
| Phase 10 | GitHub Issues integration | v1.8.x |
| Phase 11 | Docker sandbox v1 | v1.8.x |
| Phase 12 | Hooks, sub-agents, skills, bash reduction | v1.0.0 |
| Phase 13 | Guard rails, circuit breaker decay, adaptive timeout, stream capture | v2.0.x |
| Phase 14 | OTel tracing, sandbox v2, cross-session memory, cost routing | v2.3.0 |
| Phase 15 | Enable wizard hardening | v2.1.0 |
| Phase 16 | LOGFIX — production bug fixes from log analysis | v2.2.0 |
| Phase 17 | Upstream sync (USYNC) — question detection, CB permission-denial, stuck loop | v2.5.0 |

## Architecture decisions

Where a phase produced a decision worth preserving, we wrote it up as an ADR:

- [ADR-0001](docs/decisions/0001-dual-condition-exit-gate.md) — Dual-condition exit gate
- [ADR-0002](docs/decisions/0002-hook-based-response-analysis.md) — Hook-based response analysis
- [ADR-0003](docs/decisions/0003-linear-task-backend.md) — Linear task backend with fail-loud abstention
- [ADR-0004](docs/decisions/0004-epic-boundary-qa-deferral.md) — Epic-boundary QA deferral
- [ADR-0005](docs/decisions/0005-bash-sdk-duality.md) — Bash + Python SDK duality

## Current work

Open Linear tickets drive day-to-day work. See the `[Unreleased]` section of [CHANGELOG.md](CHANGELOG.md) for what's heading into the next release.

## Related

- [CHANGELOG.md](CHANGELOG.md) — release-by-release summary
- [IMPLEMENTATION_STATUS.md](IMPLEMENTATION_STATUS.md) — current state snapshot
- [docs/specs/EPIC-STORY-INDEX.md](docs/specs/EPIC-STORY-INDEX.md) — index of all 50 epics
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — architectural overview
