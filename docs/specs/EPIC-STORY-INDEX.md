# Ralph Claude Code — Epic & Story Index

> **Generated:** 2026-03-21 | **Updated:** 2026-03-21 | **Total Epics:** 18 | **Total Stories:** 76 (66 Done, 10 Open)

---

## Execution Plan Overview

```
COMPLETED (v1.2.0)
Phase 0 (DONE)     Phase 0.5 (DONE)    Phase 1 (DONE)       Phase 2 (DONE)       Phase 3 (DONE)       Phase 4 (DONE)       Phase 5 (DONE)
┌──────────────┐   ┌──────────────┐   ┌──────────────┐    ┌──────────────┐    ┌──────────────┐    ┌──────────────┐    ┌──────────────┐
│ RALPH-JSONL  │──▶│ RALPH-LOOP   │──▶│ RALPH-HOOKS  │───▶│RALPH-SUBAGENTS│──▶│ RALPH-SKILLS │──▶│ RALPH-TEAMS  │──▶│RALPH-STREAM  │
│ 4/4 Done     │   │ 5/5 Done     │   │ 6/6 Done     │    │ 5/5 Done      │   │ 5/5 Done     │   │ 5/5 Done     │   │ 3/3 Done     │
│ RALPH-MULTI  │   │ Critical     │   │ Critical     │    │ Important     │   │ Important    │   │ Nice-to-have │   │ RALPH-WSL    │
│ 6/6 Done     │   │ P0 Regrssion │   │ Foundation   │    │ Sub-agents    │   │ -1,368 lines │   │ Experimental │   │ 2/2 Done     │
└──────────────┘   └──────────────┘   └──────────────┘    └──────────────┘    └──────────────┘    └──────────────┘    └──────────────┘

COMPLETED (v1.8.0)
Phase 6 (DONE)     Phase 7 (DONE)      Phase 8 (DONE)       Phase 9 (DONE)       Phase 10 (DONE)      Phase 11 (DONE)
┌──────────────┐   ┌──────────────┐   ┌──────────────┐    ┌──────────────┐    ┌──────────────┐    ┌──────────────┐
│ RALPH-SDK    │──▶│ RALPH-CONFIG │   │RALPH-OBSERVE │    │ RALPH-TEST   │    │RALPH-GHISSUE │    │RALPH-SANDBOX │
│ 4/4 Done     │   │ 3/3 Done     │   │ 3/3 Done     │    │ 7/7 Done     │    │ 5/5 Done     │    │ 2/2 Done     │
│ High         │   │ Medium       │   │ Medium       │    │ Medium       │    │ Important    │    │ Medium       │
│ SDK + Studio │   │ JSON + Docs  │   │ Metrics/Notif│    │ Full coverage│    │ GH Standalone│    │ Docker only  │
└──────────────┘   └──────────────┘   └──────────────┘    └──────────────┘    └──────────────┘    └──────────────┘
       │                  │                                       ▲
       └──────────────────┴───────────────────────────────────────┘ (Phase 9 depends on 6+7)

OPEN (tapps-brain integration review)
Phase 12 (OPEN)
┌──────────────┐   ┌──────────────┐   ┌──────────────┐
│RALPH-BRAINSEC│──▶│RALPH-BRAINPLN│   │RALPH-BRAINDSN│
│ 2/2 Open     │   │ 4/4 Open     │   │ 4/4 Open     │
│ Critical     │   │ High         │   │ Medium       │
│ Crypto+Bypass│   │ Plan Quality │   │ Design Gaps  │
└──────────────┘   └──────────────┘   └──────────────┘
                                             ▲
       ──────────────────────────────────────┘ (BRAINDESIGN depends on BRAINSEC)
```

---

## Phase 0 — Complete (Foundation Fixes)

### RALPH-JSONL: JSONL Stream Processing Resilience
**Priority:** Critical | **Status:** Done | **Stories:** 4/4 Done

| ID | Story | Priority | Status | Effort |
|----|-------|----------|--------|--------|
| JSONL-1 | Add JSONL Detection to parse_json_response | Critical | **Done** | Small |
| JSONL-2 | Fix parse_json_response Return Code | Important | **Done** | Trivial |
| JSONL-3 | Add WSL2/NTFS Filesystem Resilience | Defensive | **Done** | Small |
| JSONL-4 | Add Fallback JSONL Extraction in ralph_loop | Defensive | **Done** | Small |

### RALPH-MULTI: Multi-Task Loop Violation and Cascading Failures
**Priority:** High | **Status:** Done | **Stories:** 6/6 Done

| ID | Story | Priority | Status | Effort |
|----|-------|----------|--------|--------|
| MULTI-1 | Strengthen PROMPT.md Stop Instruction | Critical | **Done** | Trivial |
| MULTI-2 | Add Pre-Analysis Permission Denial Scan | High | **Done** | Small |
| MULTI-3 | Fix ALLOWED_TOOLS Template Patterns | High | **Done** | Trivial |
| MULTI-4 | Reset Circuit Breaker State on Startup | Low | **Done** | Trivial |
| MULTI-5 | Warn on Multiple Result Objects in Stream | Medium | **Done** | Trivial |
| MULTI-6 | Fix Startup Hook and Add MCP Pre-Flight Check | Medium | **Done** | Small |

---

## Phase 0.5 — Complete (P0 Regression Fixes)

### RALPH-LOOP: Loop Stability & Analysis Resilience
**Priority:** Critical | **Status:** Done | **Target:** v0.12.0 | **Dependencies:** None

| # | ID | Story | Priority | Effort | Status |
|---|-----|-------|----------|--------|--------|
| 1 | LOOP-1 | Replace `jq -s` with Streaming JSON Counting | Critical | Small | **Done** |
| 2 | LOOP-3 | Handle Compound Bash Command Permissions | High | Trivial | **Done** |
| 3 | LOOP-2 | Aggregate Permission Denials Across All Result Objects | High | Small | **Done** |
| 4 | LOOP-4 | Add Error Handling to Post-Analysis Pipeline | Medium | Small | **Done** |
| 5 | LOOP-5 | Add Loop Crash Diagnostics and Recovery | Medium | Small | **Done** |

---

## Phase 1 — Complete (Hooks Foundation)

### RALPH-HOOKS: Hooks + Agent Definition
**Priority:** Critical | **Status:** Done | **Target:** v1.0.0 | **Dependencies:** RALPH-LOOP (Phase 0.5)

| # | ID | Story | Priority | Effort | Status |
|---|-----|-------|----------|--------|--------|
| 1 | HOOKS-1 | Create ralph.md Custom Agent Definition | Critical | Small | **Done** |
| 2 | HOOKS-2 | Create Hooks Configuration in settings.json | Critical | Medium | **Done** |
| 3 | HOOKS-6 | Add --agent ralph to build_claude_command() | Important | Small | **Done** |
| 4 | HOOKS-3 | Implement on-session-start.sh Hook | Important | Small | **Done** |
| 5 | HOOKS-5 | Implement File Protection PreToolUse Hooks | Important | Small | **Done** |
| 6 | HOOKS-4 | Implement on-stop.sh Hook | Critical | Medium | **Done** |

---

## Phase 2 — Complete (Sub-agents)

### RALPH-SUBAGENTS: Sub-agents
**Priority:** Important | **Status:** Done | **Target:** v1.0.0 | **Dependencies:** RALPH-HOOKS (Phase 1)

| # | ID | Story | Priority | Effort | Status |
|---|-----|-------|----------|--------|--------|
| 1 | SUBAGENTS-1 | Create ralph-explorer.md Agent Definition | Important | Small | **Done** |
| 2 | SUBAGENTS-2 | Create ralph-tester.md Agent with Worktree Isolation | Important | Small | **Done** |
| 3 | SUBAGENTS-3 | Create ralph-reviewer.md Agent Definition | Nice-to-have | Small | **Done** |
| 4 | SUBAGENTS-4 | Update ralph.md to Reference and Spawn Sub-agents | Important | Small | **Done** |
| 5 | SUBAGENTS-5 | Add Sub-agent Failure Handling and SubagentStop Hook | Important | Medium | **Done** |

---

## Phase 3 — Complete (Skills & Bash Reduction)

### RALPH-SKILLS: Skills + Bash Reduction
**Priority:** Important | **Status:** Done | **Target:** v1.0.0 | **Dependencies:** RALPH-HOOKS (Phase 1), RALPH-SUBAGENTS (Phase 2)
**Impact:** Removed ~1,368 lines of bash code.

| # | ID | Story | Priority | Effort | Status | Lines Removed |
|---|-----|-------|----------|--------|--------|---------------|
| 1 | SKILLS-1 | Create ralph-loop Skill | Important | Small | **Done** | — |
| 2 | SKILLS-2 | Create ralph-research Skill | Nice-to-have | Small | **Done** | — |
| 3 | SKILLS-4 | Remove file_protection.sh | Important | Trivial | **Done** | -58 |
| 4 | SKILLS-5 | Simplify circuit_breaker.sh | Important | Medium | **Done** | -375 |
| 5 | SKILLS-3 | Remove response_analyzer.sh | Important | Medium | **Done** | -935 |

---

## Phase 4 — Complete (Agent Teams, Experimental)

### RALPH-TEAMS: Agent Teams + Parallelism
**Priority:** Nice-to-have | **Status:** Done | **Target:** v1.1.0 | **Dependencies:** RALPH-HOOKS, RALPH-SUBAGENTS
**Risk:** High — feature is experimental, display issues on non-tmux terminals, potential instability.

| # | ID | Story | Priority | Effort | Status |
|---|-----|-------|----------|--------|--------|
| 1 | TEAMS-1 | Enable Agent Teams Configuration | Important | Small | **Done** |
| 2 | TEAMS-5 | Add Worktree Support and .gitignore Updates | Important | Trivial | **Done** |
| 3 | TEAMS-2 | Implement Team Spawning Strategy in ralph.md | Important | Medium | **Done** |
| 4 | TEAMS-3 | Create ralph-bg-tester.md Background Agent | Nice-to-have | Small | **Done** |
| 5 | TEAMS-4 | Add TeammateIdle and TaskCompleted Hooks | Important | Small | **Done** |

---

## Phase 5 — Complete (Stream & WSL Polish)

### RALPH-STREAM: Stream Parser v2 — JSONL as Primary Path
**Priority:** Medium | **Status:** Done | **Dependencies:** None
**Source:** [ralph-feedback-report.md](../../../../tapps-brain/ralph-feedback-report.md) (Issues #1, #2, #7)

| # | ID | Story | Priority | Effort | Status |
|---|-----|-------|----------|--------|--------|
| 1 | STREAM-1 | Promote JSONL Parsing to Primary Path | Medium | Small | **Done** |
| 2 | STREAM-2 | Filter Multi-Result Count by Parent Context | Medium | Trivial | **Done** |
| 3 | STREAM-3 | Unescape RALPH_STATUS Before Field Extraction | Medium | Small | **Done** |

### RALPH-WSL: WSL Reliability Polish
**Priority:** Low | **Status:** Done | **Dependencies:** None
**Source:** [ralph-feedback-report.md](../../../../tapps-brain/ralph-feedback-report.md) (Issues #3, #4)

| # | ID | Story | Priority | Effort | Status |
|---|-----|-------|----------|--------|--------|
| 1 | WSL-1 | Add Temp File Cleanup After Atomic Writes | Low | Trivial | **Done** |
| 2 | WSL-2 | Add Child Process Cleanup to Trap Handler | Low | Small | **Done** |

---

## Priority Summary

| Priority | Open | Done | Total |
|----------|------|------|-------|
| Critical | 2 | 12 | 14 |
| High | 4 | 6 | 10 |
| Important | 0 | 16 | 16 |
| Medium | 4 | 26 | 30 |
| Nice-to-have | 0 | 2 | 2 |
| Defensive/Low | 0 | 4 | 4 |
| **Total** | **10** | **66** | **76** |

## Critical Path

Phases 0-11 complete (v1.8.0). 66/66 stories done across 15 epics.
Phase 12 open: 10 stories across 3 epics (tapps-brain integration review).

### Product Strategy

Ralph is a **standalone product** with full value on its own. TheStudio is the **premium upgrade** with Ralph embedded as Primary Agent.

| Feature Area | Ralph Standalone | TheStudio Premium |
|-------------|-----------------|-------------------|
| GitHub Issues | Basic import + filter + lifecycle | Full pipeline: intake, intent, expert routing, QA |
| Sandbox | Docker only | Docker + E2B + Daytona + Cloudflare + plugins |
| Metrics | Local JSONL + CLI summary | OTel + NATS + dashboards + Reputation Engine |
| Notifications | Terminal + webhook | SSE + Slack/email/Discord |
| Quality Gates | Circuit breaker + exit gate | Verification Gate + QA Agent + expert review |

```
Phase 0 ──▶ Phase 0.5 ──▶ Phase 1 ──▶ Phase 2 ──▶ Phase 3 ──▶ Phase 4 ──▶ Phase 5
  DONE         DONE          DONE        DONE        DONE        DONE        DONE

Phase 6 ──────────▶ Phase 7 ──▶ Phase 9 (testing depends on 6+7)
 RALPH-SDK            CONFIG       TEST
  0/4 Open            0/3 Open     0/7 Open

Phase 8 (independent)   Phase 10 (independent)   Phase 11 (independent)
 RALPH-OBSERVE           RALPH-GHISSUE            RALPH-SANDBOX
  0/3 Open               0/5 Open                 0/2 Open
```

---

## Phase 6 — Complete (Agent SDK Integration)

### RALPH-SDK: Agent SDK Integration
**Priority:** High | **Status:** Done | **Target:** v1.3.0 | **Dependencies:** None (foundational)
**TheStudio:** SDK enables dual-mode — standalone CLI + embedded in TheStudio as Primary Agent

| # | ID | Story | Priority | Effort | Status |
|---|-----|-------|----------|--------|--------|
| 1 | [SDK-1](story-sdk-1-proof-of-concept.md) | Agent SDK Proof of Concept | High | Medium | **Done** |
| 2 | [SDK-2](story-sdk-2-custom-tools.md) | Define Custom Tools for Agent SDK | High | Medium | **Done** |
| 3 | [SDK-3](story-sdk-3-hybrid-architecture.md) | Implement Hybrid CLI/SDK Architecture | Critical | Large | **Done** |
| 4 | [SDK-4](story-sdk-4-migration-strategy.md) | Document SDK Migration Strategy | Medium | Small | **Done** |

---

## Phase 7 — Complete (Configuration & Infrastructure)

### RALPH-CONFIG: Configuration & Infrastructure
**Priority:** Medium | **Status:** Done | **Target:** v1.4.0 | **Dependencies:** RALPH-SDK (Phase 6)

| # | ID | Story | Priority | Effort | Status |
|---|-----|-------|----------|--------|--------|
| 1 | [CONFIG-1](story-config-1-json-configuration.md) | JSON Configuration File Support | Medium | Medium | **Done** |
| 2 | [CONFIG-2](story-config-2-sdk-installation.md) | Update Installation for SDK Support | Medium | Small | **Done** |
| 3 | [CONFIG-3](story-config-3-cli-sdk-documentation.md) | Create CLI and SDK Documentation | Medium | Medium | **Done** |

---

## Phase 8 — Complete (Observability)

### RALPH-OBSERVE: Metrics, Notifications & Recovery
**Priority:** Medium | **Status:** Done | **Target:** v1.5.0 | **Dependencies:** None
**TheStudio:** Lightweight standalone versions. TheStudio provides full OTel + dashboards + Reputation Engine

| # | ID | Story | Priority | Effort | Status |
|---|-----|-------|----------|--------|--------|
| 1 | [OBSERVE-1](story-observe-1-lightweight-metrics.md) | Lightweight Metrics and Analytics | Medium | Medium | **Done** |
| 2 | [OBSERVE-2](story-observe-2-notifications.md) | Local Notification System | Medium | Small | **Done** |
| 3 | [OBSERVE-3](story-observe-3-backup-rollback.md) | State Backup and Rollback | Low | Small | **Done** |

---

## Phase 9 — Complete (Validation Testing)

### RALPH-TEST: Validation Testing
**Priority:** Medium | **Status:** Done | **Target:** v1.6.0 | **Dependencies:** RALPH-SDK (Phase 6), RALPH-CONFIG (Phase 7)

| # | ID | Story | Priority | Effort | Status |
|---|-----|-------|----------|--------|--------|
| 1 | [TEST-1](story-test-1-tmux-integration.md) | Implement tmux Integration Tests | Medium | Medium | **Done** |
| 2 | [TEST-2](story-test-2-monitor-dashboard.md) | Implement Monitor Dashboard Tests | Medium | Medium | **Done** |
| 3 | [TEST-3](story-test-3-status-update.md) | Implement Status Update Tests | Medium | Small | **Done** |
| 4 | [TEST-4](story-test-4-cli-enhancements.md) | Implement CLI Enhancement Tests | Medium | Medium | **Done** |
| 5 | [TEST-5](story-test-5-sdk-integration.md) | Implement SDK Integration Tests | Medium | Large | **Done** |
| 6 | [TEST-6](story-test-6-backward-compatibility.md) | Implement Backward Compatibility Tests | Medium | Medium | **Done** |
| 7 | [TEST-7](story-test-7-e2e-full-loop.md) | Implement E2E Full Loop Tests | Medium | Large | **Done** |

---

## Phase 10 — Complete (GitHub Issue Integration — Standalone)

### RALPH-GHISSUE: GitHub Issue Integration
**Priority:** Important | **Status:** Done | **Target:** v1.7.0 | **Dependencies:** None
**TheStudio:** Capped scope — lightweight standalone. TheStudio provides full intake pipeline, intent, expert routing

| # | ID | Story | Priority | Effort | Status |
|---|-----|-------|----------|--------|--------|
| 1 | [GHISSUE-1](story-ghissue-1-plan-import.md) | Plan Import from GitHub Issue | Important | Medium | **Done** |
| 2 | [GHISSUE-2](story-ghissue-2-completeness-assessment.md) | Issue Completeness Assessment | Medium | Medium | **Done** |
| 3 | [GHISSUE-3](story-ghissue-3-issue-filtering.md) | GitHub Issue Filtering | Medium | Small | **Done** |
| 4 | [GHISSUE-4](story-ghissue-4-batch-processing.md) | Batch Processing and Issue Queue | Medium | Medium | **Done** |
| 5 | [GHISSUE-5](story-ghissue-5-lifecycle-management.md) | Issue Lifecycle Management | Medium | Small | **Done** |

---

## Phase 11 — Complete (Docker Sandbox — Standalone)

### RALPH-SANDBOX: Docker Sandbox Execution
**Priority:** Medium | **Status:** Done | **Target:** v1.8.0 | **Dependencies:** None
**TheStudio:** Docker-only standalone. TheStudio provides multi-provider (E2B, Daytona, Cloudflare) + plugin arch

| # | ID | Story | Priority | Effort | Status |
|---|-----|-------|----------|--------|--------|
| 1 | [SANDBOX-1](story-sandbox-1-sandbox-interface.md) | Sandbox Interface and Docker Integration | Medium | Large | **Done** |
| 2 | [SANDBOX-2](story-sandbox-2-docker-execution.md) | Docker Sandbox Execution Runner | Medium | Medium | **Done** |

---

## Phase 12 — Open (tapps-brain Integration Review)

### RALPH-BRAINSEC: tapps-brain Integration — Security Design Hardening
**Priority:** Critical | **Status:** Open | **Dependencies:** None
**Source:** Review of [TAPPS_BRAIN_INTEGRATION_RECOMMENDATIONS.md](../../../../TappMCP/docs/planning/TAPPS_BRAIN_INTEGRATION_RECOMMENDATIONS.md)

| # | ID | Story | Priority | Effort | Status |
|---|-----|-------|----------|--------|--------|
| 1 | BRAINSEC-1 | [Upgrade R02 from SHA-256 to HMAC-SHA256](epic-brain-security-design.md) | Critical | Small | **Open** |
| 2 | BRAINSEC-2 | [Add Access Control to R01 Safety Bypass](epic-brain-security-design.md) | Critical | Small | **Open** |

### RALPH-BRAINPLAN: tapps-brain Integration — Planning Rigor
**Priority:** High | **Status:** Open | **Dependencies:** None

| # | ID | Story | Priority | Effort | Status |
|---|-----|-------|----------|--------|--------|
| 1 | BRAINPLAN-1 | [Align Priority Tiers with Roadmap Phases](epic-brain-planning-rigor.md) | High | Trivial | **Open** |
| 2 | BRAINPLAN-2 | [Demote R04 from P0 to P1](epic-brain-planning-rigor.md) | High | Trivial | **Open** |
| 3 | BRAINPLAN-3 | [Add Performance Budget Section](epic-brain-planning-rigor.md) | High | Small | **Open** |
| 4 | BRAINPLAN-4 | [Add Migration and Rollback Strategy](epic-brain-planning-rigor.md) | High | Small | **Open** |

### RALPH-BRAINDESIGN: tapps-brain Integration — Technical Design Refinements
**Priority:** Medium | **Status:** Open | **Dependencies:** RALPH-BRAINSEC

| # | ID | Story | Priority | Effort | Status |
|---|-----|-------|----------|--------|--------|
| 1 | BRAINDESIGN-1 | [Add Success Criteria to P0 Security Recommendations](epic-brain-design-refinements.md) | Medium | Small | **Open** |
| 2 | BRAINDESIGN-2 | [Add Privacy Safeguards to R08 Hive and R14 Auto-Save](epic-brain-design-refinements.md) | Medium | Small | **Open** |
| 3 | BRAINDESIGN-3 | [Gate R10 Graph Boost on Relation Density](epic-brain-design-refinements.md) | Medium | Trivial | **Open** |
| 4 | BRAINDESIGN-4 | [Add Batch-Mode Exemption to R03 Rate Limiting](epic-brain-design-refinements.md) | Medium | Trivial | **Open** |

---

## TheStudio Premium — Dropped from Ralph Standalone

The following capabilities are **TheStudio premium only** and will NOT be built into Ralph standalone:

| Dropped Issue | Capability | TheStudio Handles Via |
|---------------|------------|----------------------|
| ~~#75~~ | E2B Cloud Sandbox | Execution planes + E2B adapter |
| ~~#76~~ | Sandbox File Sync (advanced) | Bidirectional sync with conflict handling |
| ~~#77~~ | Sandbox Security Policies (advanced) | Capability restrictions, audit logging |
| ~~#78~~ | Generic Sandbox Plugin Architecture | Multi-provider plugin system |
| ~~#79~~ | Daytona Sandbox | Execution planes + Daytona adapter |
| ~~#80~~ | Cloudflare Sandbox | Execution planes + Cloudflare adapter |
