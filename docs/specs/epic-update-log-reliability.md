# Epic: Update & Log Reliability

**Epic ID:** RALPH-UPKEEP
**Priority:** Medium
**Status:** Done
**Affects:** Operational reliability, log quality, dependency health
**Components:** `ralph_loop.sh` (auto-update), MCP connection handling
**Related specs:** [epic-observability.md](epic-observability.md)
**Depends on:** None
**Target Version:** v1.9.0

---

## Problem Statement

Two operational reliability issues cause misleading logs and wasted resources:

### Issue 1: Silent Auto-Update Failure

Ralph's CLI auto-update reports success but the version doesn't actually change:
```
[INFO] Claude CLI update available: 2.1.80 -> 2.1.81. Attempting auto-update...
[SUCCESS] Claude CLI updated: 2.1.80 -> 2.1.80
```

The "SUCCESS" message claims it updated, but the version remains at 2.1.80. This happened 13 times in tapps-brain, meaning the update was attempted and "succeeded" 13 times without ever working.

### Issue 2: MCP Server Failure Noise

Two MCP servers (`tapps-mcp`, `docs-mcp`) fail to connect in every single session. Each failure is logged, creating repetitive noise across 48+ log files. No retry, degradation, or suppression mechanism exists.

### Evidence

- **tapps-brain 2026-03-21**: 13 "successful" updates from 2.1.80 → 2.1.80 (version never changed)
- **TheStudio 2026-03-22**: `tapps-mcp` and `docs-mcp` failed in every session; `claude.ai Google Calendar` and `claude.ai Gmail` stuck at `pending`

## Research-Informed Adjustments

### CLI Auto-Update Verification (2025 Best Practices)

Production CLI tools verify updates actually applied:

- **Rustup**: Downloads SHA-256 checksum file first, validates download integrity, only reports success after verification
- **NVM-Windows**: Full backup → download → verify → replace → post-verify lifecycle. If post-verify fails, rolls back from backup.
- **GitHub CLI (gh)**: Does not auto-update — delegates to package managers. Avoids the problem entirely.

Reference: [Rustup self_update.rs](https://github.com/rust-lang/rustup/blob/main/src/cli/self_update.rs), [NVM-Windows Self-Update](https://deepwiki.com/coreybutler/nvm-windows/3.5-self-update-system)

### Log Noise Reduction (2025 Best Practices)

- **systemd journald**: Rate limits messages per service (default 10,000/30s), emits "N messages suppressed" summary
- **OpenTelemetry Log Deduplication Processor**: Collapses repeated log lines into a single record with count and timestamps
- **"Log once" pattern**: Use a sentinel file or in-memory set to track what's been logged. Emit once, suppress duplicates.

Reference: [systemd journald.conf](https://www.freedesktop.org/software/systemd/man/latest/journald.conf.html), [OpenTelemetry Log Deduplication](https://opentelemetry.io/blog/2026/log-deduplication-processor/)

### MCP Health Checks (2025 Best Practices)

- **MCP Ping**: Standard `ping` method in the MCP spec for health checks
- **Consecutive failure threshold**: After N failures, disable retry for that session
- **Graceful degradation**: `drop_failed_servers=True` pattern from OpenAI Agents SDK

Reference: [MCP Ping Specification](https://modelcontextprotocol.io/specification/2025-03-26/basic/utilities/ping), [AWS — Build Resilient AI Agents](https://aws.amazon.com/blogs/architecture/build-resilient-generative-ai-agents/)

## Stories

| Story | Title | Priority | Effort | Status |
|-------|-------|----------|--------|--------|
| [UPKEEP-1](story-upkeep-1-update-verification.md) | CLI Auto-Update Verification | Medium | Small | Pending |
| [UPKEEP-2](story-upkeep-2-mcp-failure-suppression.md) | MCP Server Failure Suppression | Medium | Small | Pending |

## Implementation Order

1. **UPKEEP-1** (Medium) — Fixes misleading success messages.
2. **UPKEEP-2** (Medium) — Reduces log noise from known-failing MCP servers.

## Acceptance Criteria (Epic-level)

- [ ] Auto-update reports failure when version doesn't change
- [ ] Failed MCP servers are logged once, then suppressed for the session
- [ ] All fixes have BATS tests

## Out of Scope

- Changing the Claude CLI auto-update mechanism itself
- MCP server reconnection or retry logic (that's Claude CLI's responsibility)
- Full observability pipeline (covered in RALPH-OBSERVE)
