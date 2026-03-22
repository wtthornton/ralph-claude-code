# Epic: Observability — Metrics, Notifications & Recovery (Phase 8)

**Epic ID:** RALPH-OBSERVE
**Priority:** Medium
**Affects:** Monitoring, alerting, state recovery
**Components:** `ralph_loop.sh`, `.ralph/metrics/`, `.ralph/status.json`, new notification module
**Related specs:** `IMPLEMENTATION_PLAN.md` (§Phase 3)
**Target Version:** v1.5.0
**Depends on:** None (standalone features)

---

## Problem Statement

Ralph currently has basic operational visibility (tmux dashboard, status.json, logs) but lacks:

1. **Persistent metrics** — No historical tracking of loop performance, token usage, or success rates across sessions
2. **Proactive notifications** — Users must watch the terminal or dashboard; no alerts on completion, failure, or circuit breaker trips
3. **State recovery** — If a loop fails mid-task, the only recovery is manual (re-read fix_plan.md, restart)

These features are scoped as **lightweight standalone** implementations. TheStudio provides the premium versions: full OpenTelemetry tracing, NATS JetStream signals, Outcome Ingestor, Reputation Engine, and Admin UI dashboards.

## TheStudio Relationship

| Capability | Ralph Standalone | TheStudio Premium |
|------------|-----------------|-------------------|
| Metrics storage | Local JSON files | PostgreSQL + NATS JetStream |
| Visualization | CLI summary + tmux | Admin UI Fleet Dashboard |
| Notifications | Terminal + webhook | SSE + Slack/email/Discord |
| Learning | Circuit breaker adapts | Reputation Engine + Outcome Ingestor |
| Recovery | Local .ralph/ snapshots | Temporal workflow replay + tier system |

Ralph's observability emits data in formats that TheStudio's Outcome Ingestor can consume when running in embedded mode — this is the upgrade path.

## Stories

| Story | Title | Priority | Effort | Status |
|-------|-------|----------|--------|--------|
| [OBSERVE-1](story-observe-1-lightweight-metrics.md) | Lightweight Metrics and Analytics | Medium | Medium | **Open** |
| [OBSERVE-2](story-observe-2-notifications.md) | Local Notification System | Medium | Small | **Open** |
| [OBSERVE-3](story-observe-3-backup-rollback.md) | State Backup and Rollback | Low | Small | **Open** |

## Implementation Order

1. **OBSERVE-1 (Medium)** — Metrics collection is foundational; notifications and recovery benefit from it
2. **OBSERVE-2 (Medium)** — Notifications consume metrics events; can partially overlap with OBSERVE-1
3. **OBSERVE-3 (Low)** — Recovery is independent but benefits from metrics tracking state

## Verification Criteria

- [ ] Metrics persisted to `.ralph/metrics/` after each loop iteration
- [ ] `ralph --stats` displays historical metrics summary
- [ ] Webhook notification fires on loop completion and circuit breaker trip
- [ ] `.ralph/` state snapshot created before each loop iteration
- [ ] `ralph --rollback` restores previous fix_plan.md and session state
- [ ] Metrics output format is compatible with TheStudio Outcome Ingestor schema

## Rollback

All features are opt-in via `.ralphrc` / `ralph.config.json` flags. Disabling returns to current behavior.
