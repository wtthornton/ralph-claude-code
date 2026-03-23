# Ralph SDK — Fix Plan

<!-- CRITICAL: Ralph must work identically without TheStudio. All changes are additive. -->

## Completed

v2.0.0 shipped (9 epics, 3 phases, 56 tasks). RFC-001 fully implemented:
Pydantic v2 models, pluggable state backend, structured parsing, async SDK,
active circuit breaker, correlation ID, TaskPacket conversion, EvidenceBundle output.

---

## v2.0.2 Integration Polish

> Triggered by: TheStudio Epic 43 gap analysis (2026-03-22)
> These are quick fixes that save bridge-layer workarounds in TheStudio's `ralph_bridge.py`.
> Total effort: ~2 hours. All additive, no breaking changes.

- [x] POLISH-1: Export `ComplexityBand`, `TrustTier`, `RiskFlag`, `IntentSpecInput`, `TaskPacketInput` from `__init__.py` — users shouldn't need internal module paths
- [x] POLISH-2: Add `created_at: datetime = Field(default_factory=lambda: datetime.now(UTC))` to `EvidenceBundle` in `evidence.py` — every consumer needs this timestamp
- [x] POLISH-3: Make `NullStateBackend` and `FileStateBackend` explicitly inherit from `RalphStateBackend` Protocol — prevents silent breakage if Protocol methods change
- [x] POLISH-4: Fix version: sync `__version__` in `__init__.py` with pyproject.toml (both → `"2.0.2"`)
- [x] POLISH-5: Add `system_prompt: str | None = None` parameter to `run_iteration()` in `agent.py` — pass through to Claude CLI via `--system-prompt` flag. RFC §9 Q4 recommended this; TheStudio needs it for `DeveloperRoleConfig.build_system_prompt()` injection
- [x] POLISH-6: Add public `cancel()` method to `RalphAgent` — wraps `self._running = False`. Epic 43 Temporal timeout needs this; using a private attribute directly is fragile
- [x] POLISH-7: Add `tokens_in: int = 0` and `tokens_out: int = 0` fields to `TaskResult` and `EvidenceBundle`. Extract from Claude CLI JSONL output (`input_tokens`/`output_tokens` in `result` messages) when available. TheStudio needs accurate token counts for `ModelCallAudit` — without this, cost estimation falls back to chars//4 heuristic

## Discovered
<!-- Ralph will add discovered tasks here during implementation -->
