---
title: "ADR-0007: Async PR merge via custom pending queue, not GitHub Merge Queue"
status: accepted
date: 2026-05-22
deciders: Ralph maintainers
tags: [workflow, github, pr-merge, throughput]
audience: [contributor, operator]
diataxis: explanation
last_reviewed: 2026-05-22
---

# ADR-0007: Async PR merge via custom pending queue, not GitHub Merge Queue

## Context

The 2026-05-22 AgentForge campaign shipped 41 PRs in 6.26 h — average **9.2 min per PR**. Loop-level breakdown:

- **Batch loops** (5–7 PRs in one Claude invocation): ~5–8 min per PR
- **Single-ticket loops**: 15–25 min per PR

The 2.4× gap is dominated by **agent-idle CI wait**. Today's flow per PR:

1. `git push origin feature/...`
2. `gh pr create`
3. `gh pr merge --squash --auto --delete-branch` (server enqueues; client waits)
4. The agent then synchronously verifies the merge landed via `git log main --grep=<TICKET-ID>` before moving on
5. Linear "Done" transition

Step 4 is the cost. CI for this repo runs 2–4 min; for AgentForge ~3 min. Across 41 PRs that's ~120 min of pure agent-idle wait — roughly **one-third of the wall-clock campaign**.

Two paths to remove the wait:

### Option A — GitHub Merge Queue (server-side)

GitHub's native [Merge Queue](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/configuring-pull-request-merges/managing-a-merge-queue) batches PRs server-side. The agent enqueues and moves on; GitHub validates each PR against the latest `main` and merges sequentially.

### Option B — Custom pending-merges queue (client-side)

Ralph tracks open PRs in `.ralph/pending-merges.json`. The agent picks the next ticket immediately after `gh pr create`. At each loop boundary, the harness polls pending PRs via `gh pr checks` and merges any that are green.

## Decision

**Adopt Option B** (custom pending-merges queue) as the default in 2.16.0, behind a feature flag (`RALPH_ASYNC_MERGE=true`, default `false` for one soak campaign).

## Rationale

| Dimension | Option A (Merge Queue) | Option B (custom queue) | Winner |
|---|---|---|---|
| Setup burden on consumer repos | Repo-admin must enable; needs branch protection rules + queue config | Zero — ships with Ralph upgrade | **B** |
| Plan-tier requirement | GitHub Enterprise or Pro for some features; merge queue available on most plans but limited per-repo concurrency | Works on any plan with `gh` CLI access | **B** |
| Linear "Done" transition | Asynchronous webhook needed to flip Linear; coupling to GitHub Actions | Ralph harness controls the transition directly after merge poll | **B** |
| Failure recovery | Merge Queue retries one slot at a time; complex backoff | Ralph re-opens the ticket and surfaces in next-loop prompt | **B** |
| Cross-platform (WSL/macOS/Linux) | Server-side — no client variance | Pure bash + `gh` CLI — equally portable | tie |
| Operator visibility | GitHub UI shows queue state | `.ralph/pending-merges.json` + `ralph-monitor` panel | tie (B more direct for autonomous ops) |
| Multi-repo (Ralph manages N projects) | Per-repo config | One Ralph behavior across all managed repos | **B** |
| Risk: PR pile-up if CI is slow or down | GitHub enforces queue cap | Ralph enforces `pending_count <= 5` with force-drain above | tie |
| Risk: PR conflicts when next ticket touches same files | Merge Queue rebases automatically | Ralph's coordinator-side file-overlap analysis (T6 follow-up) detects, falls back to serial | B (controllable) |
| March 2026 GitHub change: `--auto` returns 422 when no checks present | Bypassed (queue handles it) | Ralph must detect 422 + retry after 30s | A |
| Reversibility if it goes wrong | Disable in repo settings | Flip `RALPH_ASYNC_MERGE=false` env var | tie |

The **decisive factors** are:

1. **Linear coupling.** Ralph treats Linear as the single source of truth for ticket state. Moving Linear → Done after the merge actually lands requires the harness to *know* when that happened. With Option A that means GitHub Actions → webhook → some bridge → Linear MCP, all without losing the ticket ID. With Option B, the harness polls `gh pr checks`, sees green, calls `gh pr merge`, and immediately calls the Linear MCP — one process, one log, one failure surface.
2. **Zero-setup deployability across N managed projects.** Every Ralph-managed repo already gets `.ralph/` scaffolding. Adding `pending-merges.json` is one more file. Asking every consumer repo's admin to enable Merge Queue is a per-repo coordination tax that scales badly.
3. **The March 2026 GitHub change is a single 422 handler**, not a structural problem. Mitigation cost is small.

## Consequences

- **Positive.** Eliminates the 120-min/campaign agent-idle wait; cuts avg per-PR ship time from 9.2 → projected <6 min. Single Ralph behavior across every consumer repo regardless of GitHub plan tier. Linear Done transitions remain deterministic.
- **Negative.** Ralph now owns a piece of stateful PR orchestration. CI-failure recovery is in our code, not GitHub's. The pending queue is bounded (`pending_count <= 5`) to prevent unbounded growth.
- **Operator escape hatch.** `RALPH_ASYNC_MERGE=false` reverts to today's synchronous behavior exactly. The flag stays default-off through 2.16.0 to soak with willing operators before flipping in 2.16.1.

## Reversibility

Reversing is one env var change in `.ralphrc`. The pending-merges queue is drained on session start (the harness verifies each pending PR's status before picking new work), so disabling the flag mid-campaign won't strand PRs.

## Alternatives considered

- **Hybrid (use Merge Queue when available, fall back to custom).** Rejected: doubles the code paths Ralph maintains and makes the Linear-Done timing non-deterministic depending on per-repo config.
- **Skip the queue entirely; just `gh pr merge --auto` and trust GitHub.** This is what we do today. The agent still waits for the verification step (`git log --grep`) before declaring Done. Without the verification, Linear Done would diverge from what's actually on `main`. So we'd be trading "wait for CI" for "trust that auto-merge succeeded without confirming."

## References

- [Managing a merge queue (GitHub Docs)](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/configuring-pull-request-merges/managing-a-merge-queue)
- [GitHub Auto-Merge Bug (March 2026)](https://devactivity.com/insights/github-auto-merge-bug-undocumented-change-disrupts-pr-workflows-and-developer-performance/) — the 422-when-no-checks behavior change
- [continuous-claude](https://github.com/AnandChowdhary/continuous-claude) — reference Ralph-loop-with-PRs implementation
- [Claude Code Autonomous Agent Workflows 2026 (Sitepoint)](https://www.sitepoint.com/claude-code-as-an-autonomous-agent-advanced-workflows-2026/)
