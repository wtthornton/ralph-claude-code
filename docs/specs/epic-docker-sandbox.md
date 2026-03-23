# Epic: Docker Sandbox Execution (Phase 11)

**Epic ID:** RALPH-SANDBOX
**Priority:** Medium
**Affects:** Execution isolation, security, reproducibility
**Components:** `ralph_loop.sh`, new `lib/sandbox.sh`, new `docker/ralph-sandbox/`
**Related specs:** `IMPLEMENTATION_PLAN.md` (§Phase 6)
**Target Version:** v1.8.0
**Depends on:** None (standalone capability)

---

## Problem Statement

Ralph currently executes Claude Code directly on the host filesystem. While file protection hooks and ALLOWED_TOOLS provide guardrails, there is no true isolation:

1. **No filesystem isolation** — Claude Code has access to the full host filesystem within permission bounds
2. **No resource limits** — A runaway loop can consume unlimited CPU/memory
3. **No network control** — No ability to restrict network access during execution
4. **No reproducibility** — Results may vary based on host environment state

Docker sandbox execution provides true isolation for Ralph's autonomous loop, making it safe to run on shared infrastructure or with elevated trust levels.

## TheStudio Relationship

This epic provides **Docker-only sandbox** for Ralph standalone. TheStudio provides the premium multi-provider experience:

| Capability | Ralph Standalone | TheStudio Premium |
|------------|-----------------|-------------------|
| Providers | Docker only | Docker + E2B + Daytona + Cloudflare + plugin arch |
| Isolation | Basic container with bind mount | Per-repo execution planes, credential scoping |
| File sync | Volume mount (simple) | Bidirectional sync with conflict handling |
| Security | Resource limits (CPU, memory, timeout) | Capability restrictions, audit logging, network policies |
| Management | CLI flags (`ralph --sandbox`) | Admin UI, fleet-wide policies, compliance enforcement |

**Dropped from Ralph standalone** (TheStudio premium only):
- ~~#75: E2B Cloud Sandbox Integration~~
- ~~#76: Sandbox File Synchronization~~ (advanced bidirectional)
- ~~#77: Sandbox Security and Resource Policies~~ (advanced policies)
- ~~#78: Generic Sandbox Interface and Plugin Architecture~~
- ~~#79: Daytona Sandbox Integration~~
- ~~#80: Cloudflare Sandbox Integration~~

These capabilities are available when Ralph runs inside TheStudio's execution planes.

## Stories

| Story | Title | Priority | Effort | Status |
|-------|-------|----------|--------|--------|
| [SANDBOX-1](story-sandbox-1-sandbox-interface.md) | Sandbox Interface and Docker Integration | Medium | Large | **Done** |
| [SANDBOX-2](story-sandbox-2-docker-execution.md) | Docker Sandbox Execution Runner | Medium | Medium | **Done** |

## Implementation Order

1. **SANDBOX-1 (Medium)** — Define the interface and Docker image; foundational for SANDBOX-2
2. **SANDBOX-2 (Medium)** — Execution runner that uses the interface to manage container lifecycle

## Verification Criteria

- [ ] `ralph --sandbox` starts execution inside a Docker container
- [ ] Project files are accessible inside container via volume mount
- [ ] Resource limits (CPU, memory) are configurable via `.ralphrc` / `ralph.config.json`
- [ ] Container is cleaned up on loop completion, circuit breaker trip, or SIGINT
- [ ] Ralph output (status.json, logs, fix_plan.md updates) persists back to host
- [ ] `ralph --sandbox --dry-run` validates Docker availability without executing
- [ ] Fallback to host execution when Docker is not available (with warning)

## Rollback

Sandbox is opt-in via `--sandbox` flag. Default behavior remains host execution. Removing sandbox support has no impact on core Ralph functionality.

---

## 2026 Research Addendum

**Added:** 2026-03-22 | **Source:** Phase 14 research review

This epic's Docker-only sandbox remains the foundation. The 2026 security landscape adds three requirements:

1. **Network egress control**: OpenAI Codex blocks all network access during execution. The 2026 standard is "block by default, allow by exception" (`--network none`)
2. **Rootless Docker**: Standard Docker requires root and shares the host kernel. Container escape CVEs are recurring. Rootless eliminates this class
3. **gVisor runtime**: Google GKE Agent Sandbox uses gVisor for user-space kernel isolation (10-30% I/O overhead, minimal compute overhead)

**Successor epic:** [RALPH-SANDBOXV2](epic-sandbox-hardening.md) (Phase 14) adds rootless mode, network egress blocking, resource reporting, and optional gVisor support.
