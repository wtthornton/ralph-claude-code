# Epic: Agent Evaluation Framework (Phase 14)

**Epic ID:** RALPH-EVALS
**Priority:** Medium
**Affects:** Quality assurance, regression detection, agent behavior validation
**Components:** new `tests/evals/`, `ralph_loop.sh`, CI configuration
**Related specs:** [epic-validation-testing.md](epic-validation-testing.md) (Phase 9 — BATS testing)
**Target Version:** v2.2.0
**Depends on:** RALPH-OTEL (trace data for eval analysis)

---

## Problem Statement

Ralph has 736+ BATS tests for bash code correctness. But there are no **agent-level evaluations** — tests that verify the AI agent's behavior, decision quality, and task completion accuracy:

1. **No golden-file tests**: No recorded successful agent runs to compare against for regression detection
2. **No quality scoring**: No systematic measurement of whether the agent completes tasks correctly, partially, or incorrectly
3. **No stochastic testing**: Agent output is non-deterministic. Binary pass/fail is insufficient — the 2026 standard is three-valued outcomes (Pass/Fail/Inconclusive) with confidence intervals

### 2026 Research

- **Anthropic guidance**: "Choose deterministic graders where possible, LLM graders where necessary, human graders judiciously"
- **AgentAssay** (March 2026): Three-valued probabilistic outcomes backed by confidence intervals and sequential analysis
- **MAESTRO**: Multi-Agent Evaluation Suite for Testing, Reliability, and Observability — framework-agnostic execution traces
- Coding agents benefit from deterministic evaluation since software correctness is generally straightforward to verify

## Stories

| Story | Title | Priority | Effort | Status |
|-------|-------|----------|--------|--------|
| [EVALS-1](story-evals-1-golden-files.md) | Golden-File Test Infrastructure | Medium | Medium | **Done** |
| [EVALS-2](story-evals-2-deterministic-suite.md) | Deterministic Agent Eval Suite | Medium | Medium | **Done** |
| [EVALS-3](story-evals-3-stochastic-suite.md) | Stochastic Eval Suite with Three-Valued Outcomes | Medium | Medium | **Done** |

## Implementation Order

1. **EVALS-1** (Medium) — Build infrastructure: recording format, golden file storage, comparison tools
2. **EVALS-2** (Medium) — Deterministic evals: tool sequence matching, exit condition verification
3. **EVALS-3** (Medium) — Stochastic evals: semantic similarity, confidence intervals, nightly runs

## Acceptance Criteria (Epic-level)

- [x] Golden-file format defined for recording agent runs
- [x] Deterministic eval suite verifies tool sequences and exit conditions
- [x] Stochastic eval suite uses three-valued outcomes (Pass/Fail/Inconclusive)
- [x] Deterministic suite runs in pre-merge CI (<5 min)
- [x] Stochastic suite runs nightly with results dashboard
- [x] Eval results include confidence intervals and sample counts

## Rollback

Eval framework is in `tests/evals/` — completely separate from production code. Removing it has no impact on Ralph's functionality.
