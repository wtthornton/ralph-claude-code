# Epic: Sandbox Hardening (Phase 14)

**Epic ID:** RALPH-SANDBOXV2
**Priority:** Medium
**Status:** Done
**Affects:** Security, isolation, resource control, compliance
**Components:** `lib/sandbox.sh`, `docker/ralph-sandbox/Dockerfile`
**Related specs:** [epic-docker-sandbox.md](epic-docker-sandbox.md) (Phase 11 — initial Docker sandbox)
**Target Version:** v2.2.0
**Depends on:** RALPH-SANDBOX (Phase 11)

---

## Problem Statement

Ralph's Phase 11 Docker sandbox provides basic container isolation with bind mounts. The 2026 security landscape demands stronger isolation:

1. **No network egress control** — Claude Code inside the container can access the internet freely. OpenAI Codex blocks all network access during task execution. The 2026 standard is "block by default, allow by exception."

2. **Root Docker by default** — Standard Docker requires root privileges and shares the host kernel. Container escape vulnerabilities (CVE-2024-21626, CVE-2025-*) are a recurring risk. Rootless Docker eliminates this class of attack.

3. **No resource usage reporting** — Ralph limits CPU/memory but doesn't report actual usage. Operators can't identify resource-hungry tasks or optimize container sizing.

### Evidence

- OpenAI Codex architecture: "Internet access is disabled during task execution" (mandatory)
- Google GKE Agent Sandbox: powered by gVisor for user-space kernel isolation
- NVIDIA guidance: "Defense-in-depth: isolation + resource limits + network controls + permission scoping + monitoring"
- Firecracker MicroVMs: boot in ~125ms with <5 MiB overhead (strongest isolation)

## Stories

| Story | Title | Priority | Effort | Status |
|-------|-------|----------|--------|--------|
| [SANDBOXV2-1](story-sandboxv2-1-rootless-egress.md) | Rootless Docker Mode and Network Egress Control | Medium | Medium | **Done** |
| [SANDBOXV2-2](story-sandboxv2-2-resource-reporting.md) | Resource Usage Reporting | Medium | Small | **Done** |
| [SANDBOXV2-3](story-sandboxv2-3-gvisor.md) | gVisor Runtime Support | Low | Medium | **Done** |

## Implementation Order

1. **SANDBOXV2-1** (Medium) — Highest security impact: rootless + network blocking
2. **SANDBOXV2-2** (Medium) — Operational visibility: know what resources tasks consume
3. **SANDBOXV2-3** (Low) — Optional stronger isolation for GKE/production environments

## Acceptance Criteria (Epic-level)

- [x] Container runs rootless by default when rootless Docker is available
- [x] Network egress blocked by default during execution (configurable allowlist)
- [x] Resource usage (CPU, memory, duration) reported per-iteration
- [x] gVisor runtime supported as optional stronger isolation
- [x] Fallback to standard Docker when rootless/gVisor unavailable
- [x] All sandbox modes have BATS tests

## Rollback

Sandbox is opt-in via `--sandbox`. Rootless and gVisor are automatic detection with fallback. Removing any enhancement reverts to Phase 11 Docker behavior.
