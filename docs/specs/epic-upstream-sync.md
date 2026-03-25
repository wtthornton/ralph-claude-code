# Epic: RALPH-USYNC — Upstream Sync (frankbria/ralph-claude-code)

> **Created:** 2026-03-25 | **Priority:** High | **Stories:** 7/7 Done | **Status:** Done
> **Source:** Comparison of upstream `frankbria/ralph-claude-code` (commit `b31640a`, 2026-03-24) against fork v2.4.0

## Motivation

The upstream Ralph repository has accumulated significant bug fixes and correctness improvements from community contributions (PRs #100, #134, #188, #189, #190, #194, #198, #199, #208, #215, #216, #224, #228). Our fork removed `response_analyzer.sh` (story SKILLS-3) and simplified `circuit_breaker.sh` (story SKILLS-5) in favor of hook-based architecture, but several upstream improvements were not ported during that transition.

This epic cherry-picks the **7 highest-value items** (score >= 7) from the upstream diff. Items already present in the fork (is_error:true detection, stale exit signal clearing, Extra Usage quota detection, set -e removal, productive work on timeout) are excluded — the fork already has these, often in enhanced form.

## Architectural Context

The fork uses a **push model** (on-stop.sh hook writes `status.json`) instead of upstream's **pull model** (`response_analyzer.sh` called from loop). All ported features must integrate with `status.json` and the hook pipeline, NOT re-introduce `response_analyzer.sh`.

## Stories

| ID | Story | Priority | Size | Upstream Issue |
|----|-------|----------|------|----------------|
| USYNC-1 | Question pattern detection in on-stop.sh | Critical | M | #190 | **Done** |
| USYNC-2 | Question-loop corrective guidance injection | Critical | S | #190 Bug 2 | **Done** |
| USYNC-3 | Circuit breaker: question-detection suppression | High | S | #190 | **Done** |
| USYNC-4 | Circuit breaker: permission denial tracking | High | M | #101 | **Done** |
| USYNC-5 | Stuck-loop detection (cross-output error comparison) | Medium | M | — | **Done** |
| USYNC-6 | Heuristic exit suppression in JSON mode | Medium | S | #224 | **Done** (pre-existing) |
| USYNC-7 | Tmux live output: sub-agent progress display | Low | S | #216 | **Done** (pre-existing) |

## Dependency Graph

```
USYNC-1 ──▶ USYNC-2  (guidance needs detection)
USYNC-1 ──▶ USYNC-3  (CB suppression needs detection)
USYNC-4     (independent)
USYNC-5     (independent)
USYNC-6     (independent)
USYNC-7     (independent)
```

## Acceptance Criteria (Epic-level)

1. All 17 upstream question patterns are detected and surfaced in `status.json`
2. Headless loops inject corrective guidance when previous loop asked questions
3. Circuit breaker does NOT penalize question-asking loops as "no progress"
4. Permission denial tracking trips circuit breaker after configurable threshold
5. Repeated identical errors across 3+ outputs are detected as stuck loops
6. No regression in existing BATS tests; new tests cover all ported behaviors
7. `response_analyzer.sh` is NOT re-introduced — all changes use hook/status.json architecture

## Out of Scope

- Upstream's `file_protection.sh` (fork has superior PreToolUse hooks — story SKILLS-4)
- Upstream's `validate_claude_command()` (fork already validates CLI at startup)
- Upstream's Bash 3 `tr` compat (fork already uses `tr` patterns)
- Upstream's CI workflow changes (fork has its own CI)
- Wholesale replacement of `ralph_loop.sh` (architectures have diverged too far)
