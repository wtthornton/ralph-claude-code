# Epic: OpenTelemetry & Observability v2 (Phase 14)

**Epic ID:** RALPH-OTEL
**Priority:** High
**Status:** Done
**Affects:** Observability, cost tracking, debugging, TheStudio integration
**Components:** `ralph_loop.sh`, `lib/metrics.sh`, new `lib/tracing.sh`, `.claude/hooks/`
**Related specs:** [epic-observability.md](epic-observability.md) (Phase 8 — lightweight predecessor)
**Target Version:** v2.1.0
**Depends on:** None (builds on RALPH-OBSERVE infrastructure)

---

## Problem Statement

Ralph's current observability (Phase 8, RALPH-OBSERVE) uses local JSONL metrics and a tmux dashboard. While functional for standalone use, it has three critical gaps against 2026 industry standards:

1. **No trace correlation** — Loop iterations, sub-agent invocations, hooks, and tool calls have no shared correlation ID. Debugging a failed iteration requires manually correlating timestamps across `ralph.log`, `claude_output_*.log`, and `status.json`.

2. **No OpenTelemetry compatibility** — The 2026 industry has converged on OpenTelemetry (OTel) with GenAI Semantic Conventions (`gen_ai.usage.input_tokens`, `gen_ai.request.model`, etc.) as the standard for AI agent telemetry. Ralph's JSONL format is proprietary and incompatible with Langfuse, Helicone, Datadog, and other observability platforms.

3. **No per-trace cost attribution** — Ralph tracks aggregate token usage but cannot attribute costs to individual tasks, sub-agents, or tool calls. As agents autonomously chain multiple API calls, per-trace cost visibility is essential for optimization.

### Evidence

- Langfuse SDK v3 is built as a thin OTel layer; Pydantic AI, smolagents, and Strands Agents emit OTel traces natively
- GenAI Semantic Conventions define shared vocabulary: `gen_ai.usage.input_tokens`, `gen_ai.usage.output_tokens`, `gen_ai.request.model`
- Any language can integrate by pointing an OTLP exporter at an observability endpoint with GenAI attributes

## TheStudio Relationship

| Capability | Ralph Standalone (Current) | Ralph Standalone (OTEL) | TheStudio Premium |
|------------|---------------------------|------------------------|-------------------|
| Trace format | Proprietary JSONL | OTel-compatible JSONL | Full OTLP export |
| Correlation | None (timestamp matching) | trace_id per iteration | Distributed traces across pipeline |
| Cost tracking | Aggregate per session | Per-trace attribution | Fleet-wide cost dashboards |
| Backends | Local files only | Local + optional OTLP export | Langfuse + Grafana + custom |
| GenAI attrs | Custom fields | GenAI Semantic Conventions | Full OTel + custom dimensions |

Ralph's OTel-compatible traces become consumable by TheStudio's observability stack when running in embedded mode — this is the upgrade path.

## Research-Informed Design

### OpenTelemetry GenAI Semantic Conventions (2026)

The GenAI Semantic Conventions define standardized attributes for AI observability:

| Attribute | Type | Description |
|-----------|------|-------------|
| `gen_ai.system` | string | AI system identifier (e.g., `anthropic`) |
| `gen_ai.request.model` | string | Model ID (e.g., `claude-sonnet-4-6`) |
| `gen_ai.usage.input_tokens` | int | Tokens consumed in request |
| `gen_ai.usage.output_tokens` | int | Tokens generated in response |
| `gen_ai.request.temperature` | float | Sampling temperature |
| `gen_ai.response.finish_reason` | string | Why generation stopped |

Reference: [OTel GenAI Semantic Conventions](https://opentelemetry.io/docs/specs/semconv/gen-ai/), [Langfuse OTel Integration](https://langfuse.com/blog/2024-10-opentelemetry-for-llm-observability)

### Trace ID Propagation Pattern

Every trace starts at the loop iteration level and propagates through:
1. Loop iteration → `trace_id` generated
2. Claude CLI invocation → `trace_id` passed via environment
3. Sub-agent spawns → `trace_id` inherited, new `span_id` per agent
4. Hook executions → `trace_id` available via `RALPH_TRACE_ID` env var
5. Status writes → `trace_id` included in `status.json`

Reference: [LangWatch — Trace IDs in AI](https://langwatch.ai/blog/trace-ids-llm-observability-and-distributed-tracing)

### Log Sanitization

All trace entries must pass through a sanitizer that strips:
- API keys and tokens
- File contents that may contain secrets
- PII from error messages

Reference: [Fast.io — AI Agent Production Logging 2026](https://fast.io/resources/ai-agent-production-logging/)

## Stories

| Story | Title | Priority | Effort | Status |
|-------|-------|----------|--------|--------|
| [OTEL-1](story-otel-1-trace-generation.md) | OTel Trace Generation with GenAI Semantic Conventions | High | Medium | **Done** |
| [OTEL-2](story-otel-2-trace-propagation.md) | Trace ID Propagation Across Sub-Agents and Hooks | High | Small | **Done** |
| [OTEL-3](story-otel-3-cost-attribution.md) | Per-Trace Cost Attribution and Budget Alerts | Medium | Small | **Done** |
| [OTEL-4](story-otel-4-otlp-exporter.md) | OTLP Exporter for External Backends | Medium | Medium | **Done** |

## Implementation Order

1. **OTEL-1** (High) — Foundation: generate OTel-compatible trace records with GenAI attributes
2. **OTEL-2** (High) — Propagate trace_id to sub-agents, hooks, and status writes
3. **OTEL-3** (Medium) — Add per-trace cost calculation and budget alerting
4. **OTEL-4** (Medium) — Optional OTLP HTTP exporter for Langfuse/Helicone/Datadog

## Acceptance Criteria (Epic-level)

- [ ] Every loop iteration has a unique `trace_id` (UUID v4)
- [ ] Sub-agent invocations and hook executions inherit the parent `trace_id`
- [ ] Trace records include GenAI Semantic Convention attributes
- [ ] `ralph --stats` shows per-task cost breakdown
- [ ] Optional OTLP export sends traces to configurable endpoint
- [ ] `status.json` includes `trace_id` for correlation
- [ ] All trace entries are sanitized (no API keys, secrets, or PII)
- [ ] Backward-compatible: existing JSONL metrics continue to work

## Rollback

OTel tracing is additive. Disabling `RALPH_OTEL_ENABLED=false` reverts to current JSONL-only metrics. No existing behavior is modified.
