# Epic: Cost-Aware Model Routing (Phase 14)

**Epic ID:** RALPH-COSTROUTE
**Priority:** High
**Status:** Done
**Affects:** Cost efficiency, throughput, model selection, prompt caching
**Components:** `ralph_loop.sh`, `.claude/agents/ralph.md`, `.claude/hooks/on-session-start.sh`
**Related specs:** [epic-adaptive-timeout.md](epic-adaptive-timeout.md) (Phase 13 — timeout adaptation), [epic-skills-bash-reduction.md](epic-skills-bash-reduction.md) (Phase 3 — existing model assignments)
**Target Version:** v2.1.0
**Depends on:** None

---

## Problem Statement

Ralph currently uses **static model assignments**: Sonnet for routine work, Haiku for explorer, Opus for architect. These assignments don't adapt to task complexity, and the prompt structure isn't optimized for Anthropic's automatic prompt caching.

The 2026 research identifies cost-aware model routing as the **#1 cost optimization** for AI agent systems, with potential savings of 30-70%:

1. **Static model assignments waste money** — Simple file renames, small edits, and trivial fixes use Sonnet ($3/$15 per 1M tokens) when Haiku ($0.80/$4) would produce identical results. Complex architectural tasks use Sonnet when Opus would produce better outcomes and fewer retry loops.

2. **Prompt structure isn't cache-optimized** — Anthropic's automatic prompt caching provides up to 90% cost reduction and 85% latency reduction for repeated prompt prefixes. Ralph's prompt includes PROMPT.md, fix_plan.md, and AGENT.md content that changes between iterations, potentially invalidating cache hits.

3. **No token budget per task** — A SMALL task that consumes 50K tokens should be flagged; a LARGE task consuming 200K tokens is expected. Without per-task budgets, runaway token consumption goes undetected.

### Evidence

- Amazon Bedrock's Intelligent Prompt Routing reduces costs by 30% without accuracy loss
- Anthropic automatic prompt caching: 90% cost reduction, 85% latency reduction for stable prefixes
- Strategic combination of caching + routing + optimization = 70%+ total cost savings
- Ralph's Phase 3 speed optimizations (v1.8.4+) already use `effort: medium` for faster throughput — routing extends this to model selection

## Stories

| Story | Title | Priority | Effort | Status |
|-------|-------|----------|--------|--------|
| [COSTROUTE-1](story-costroute-1-complexity-classifier.md) | Task Complexity Classifier | High | Medium | **Done** |
| [COSTROUTE-2](story-costroute-2-dynamic-model-selection.md) | Dynamic Model Selection Based on Complexity | High | Medium | **Done** |
| [COSTROUTE-3](story-costroute-3-prompt-cache-optimization.md) | Prompt Structure Optimization for Cache Hits | High | Small | **Done** |
| [COSTROUTE-4](story-costroute-4-token-budget.md) | Token Budget and Cost Dashboard | Medium | Small | **Done** |

## Implementation Order

1. **COSTROUTE-3** (High) — Quick win: restructure prompts for cache optimization. Independent of other stories.
2. **COSTROUTE-1** (High) — Classify task complexity from fix_plan.md task text and context.
3. **COSTROUTE-2** (High) — Route to Haiku/Sonnet/Opus based on classified complexity.
4. **COSTROUTE-4** (Medium) — Add per-task token budgets and cost dashboard.

## Research-Informed Design

### Complexity Signal Extraction

Task complexity can be estimated from multiple signals without an LLM call:

| Signal | Source | Low Complexity | High Complexity |
|--------|--------|---------------|-----------------|
| Task text keywords | fix_plan.md | "rename", "fix typo", "update version" | "refactor", "architect", "design", "migrate" |
| Estimated file count | fix_plan.md paths | 1-2 files | 5+ files |
| Task size annotation | fix_plan.md | `[SMALL]`, `[TRIVIAL]` | `[LARGE]`, `[COMPLEX]` |
| Module familiarity | Recent trace history | Same module as last 3 tasks | New module |
| Prior iteration count | Task retry history | First attempt | 3+ retries |

Reference: [Amazon Bedrock Intelligent Prompt Routing](https://aws.amazon.com/bedrock/intelligent-prompt-routing/)

### Prompt Cache Optimization

Anthropic's automatic prompt caching caches repeated prompt prefixes. To maximize hits:

1. **Stable prefix**: System prompt, agent definition, tool definitions — these rarely change
2. **Semi-stable middle**: PROMPT.md, AGENT.md — change per project but not per iteration
3. **Variable suffix**: fix_plan.md current task, loop context — changes every iteration

Structure prompts as: `[stable] + [semi-stable] + [variable]` to maximize the cached prefix length.

Reference: [Claude API — Prompt Caching](https://platform.claude.com/docs/en/build-with-claude/prompt-caching)

## Acceptance Criteria (Epic-level)

- [ ] Task complexity classified before model selection (no LLM call required)
- [ ] Model dynamically selected: Haiku for trivial, Sonnet for routine, Opus for complex
- [ ] Prompt structured for maximum cache hit rate (stable prefix → variable suffix)
- [ ] Per-task token budget with warning on exceedance
- [ ] `ralph --stats` shows cost breakdown by model tier
- [ ] All model routing decisions logged for debugging
- [ ] `RALPH_MODEL_ROUTING_ENABLED=false` reverts to static assignments
- [ ] Existing `.ralphrc` model overrides still work

## Rollback

Model routing is opt-in via `RALPH_MODEL_ROUTING_ENABLED=true`. Default behavior remains static Sonnet assignment. Disabling reverts immediately.
