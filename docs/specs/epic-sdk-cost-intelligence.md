# Epic: SDK Cost Intelligence — Cost Tracking, Model Routing, and Token Rate Limiting

**Epic ID:** RALPH-SDK-COST
**Priority:** P1–P2
**Affects:** Cost efficiency, model selection, budget enforcement, rate limiting accuracy
**Components:** `ralph_sdk/config.py`, `ralph_sdk/agent.py`
**Related specs:** [epic-brain-design-refinements.md](epic-brain-design-refinements.md)
**Depends on:** None (new SDK modules)
**Target Version:** SDK v2.1.0
**Source:** [ralph-sdk-upgrade-evaluation.md](../../../TheStudio/docs/ralph-sdk-upgrade-evaluation.md) §1.4, §1.5, §2.4

---

## Problem Statement

Three cost-related gaps between the CLI and SDK lead to budget waste and inaccurate tracking:

1. **Cost tracking**: The CLI tracks per-model token costs (`lib/tracing.sh` lines 185-284), enforces budget alerts at configurable thresholds, and provides cost dashboards. The SDK has no cost awareness. TheStudio's `BudgetEnforcer` estimates cost from `duration_seconds * cost_per_minute`, which is fragile and inaccurate. Per-token cost tracking from the SDK would replace this heuristic.

2. **Dynamic model routing**: The CLI's `lib/complexity.sh` routes trivial tasks to Haiku, standard to Sonnet, and complex/architectural to Opus. The SDK uses a static model from config. Routing a one-line docstring fix to Opus wastes ~10x the cost vs Haiku. The CLI's 5-level classifier (TRIVIAL through ARCHITECTURAL) with retry escalation would directly reduce per-task costs.

3. **Token-based rate limiting**: Ralph issue #223 confirms the rate limiter counts invocations, not tokens. A single high-token call counts the same as a trivial one, making budget enforcement inaccurate. Token-based rate limiting is needed alongside invocation-based.

### Evidence

- TheStudio `BudgetEnforcer`: Uses `duration_seconds * cost_per_minute` — fragile heuristic
- Ralph issue #223: Rate limiter counts calls, not tokens
- CLI `lib/complexity.sh`: 5-level classifier (TRIVIAL → ARCHITECTURAL) with model routing
- 10x cost difference between Haiku and Opus for the same task

## Research Context (March 2026)

**Claude API pricing (March 2026)**:
| Model | Input (per 1M tokens) | Output (per 1M tokens) | Prompt Cache Read | Prompt Cache Write |
|-------|----------------------|----------------------|-------------------|-------------------|
| Claude Opus 4.6 | $15.00 | $75.00 | $1.50 | $18.75 |
| Claude Sonnet 4.6 | $3.00 | $15.00 | $0.30 | $3.75 |
| Claude Haiku 4.5 | $0.80 | $4.00 | $0.08 | $1.00 |

**Cost optimization patterns for AI agents (2026)**:
- **Tiered model routing**: Route by task complexity — trivial tasks to smallest capable model, complex tasks to most capable. CrewAI and LangGraph both support per-step model configuration.
- **Budget guardrails**: Pre-check remaining budget before each iteration. Fail fast rather than burn budget on a doomed run.
- **Token-aware rate limiting**: Track cumulative tokens (input + output) per hour rather than just invocation count. Anthropic's rate limits are per-model and based on both RPM (requests per minute) and TPM (tokens per minute).
- **Retry escalation**: Start with cheaper models and escalate to more capable ones on failure. The CLI's retry escalation pattern (Haiku → Sonnet → Opus) optimizes the cost-success tradeoff.

## Stories

| Story | Title | Priority | Effort | Status |
|-------|-------|----------|--------|--------|
| [SDK-COST-1](story-sdk-cost-1-cost-tracking.md) | Cost Tracking and Budget Guardrails | P1 | 2 days | Pending |
| [SDK-COST-2](story-sdk-cost-2-model-routing.md) | Dynamic Model Routing | P1 | 1 day | Pending |
| [SDK-COST-3](story-sdk-cost-3-token-rate-limiting.md) | Token-Based Rate Limiting | P2 | 1 day | Pending |

## Implementation Order

1. **SDK-COST-1** (P1) — `CostTracker` class. Foundation for budget awareness.
2. **SDK-COST-2** (P1) — `select_model()` with complexity-based routing. Uses cost tracker for escalation decisions.
3. **SDK-COST-3** (P2) — Token-based rate limiting. Extends existing rate limiter with token tracking.

## Acceptance Criteria (Epic-level)

- [ ] SDK tracks per-iteration cost by model (input tokens, output tokens, USD)
- [ ] Cumulative session cost is queryable
- [ ] Budget alerts fire at configurable threshold (default 80%)
- [ ] Budget hard-stop prevents further iterations when exhausted
- [ ] Per-model pricing is configurable (defaults to March 2026 Claude pricing)
- [ ] Model selection considers task complexity band (TRIVIAL through ARCHITECTURAL)
- [ ] Retry escalation moves to more capable models on failure
- [ ] Rate limiter optionally tracks tokens per hour alongside invocations
- [ ] `max_tokens_per_hour` configurable in `RalphConfig`
- [ ] pytest tests verify cost tracking, model selection, and token rate limiting

## Out of Scope

- Real-time Anthropic API cost reporting (SDK estimates from token counts)
- Multi-provider cost tracking (Claude-only)
- Custom model fine-tuning or selection beyond the Claude model family
- Dashboard visualization (data collection only; visualization is a TheStudio concern)
