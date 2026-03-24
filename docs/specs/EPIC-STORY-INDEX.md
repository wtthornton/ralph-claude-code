# Ralph Claude Code — Epic & Story Index

> **Generated:** 2026-03-21 | **Updated:** 2026-03-24 | **Total Epics:** 41 | **Total Stories:** 153 (153 Done, 0 Open)

---

## Execution Plan Overview

```
COMPLETED (v1.2.0)
Phase 0 (DONE)     Phase 0.5 (DONE)    Phase 1 (DONE)       Phase 2 (DONE)       Phase 3 (DONE)       Phase 4 (DONE)       Phase 5 (DONE)
┌──────────────┐   ┌──────────────┐   ┌──────────────┐    ┌──────────────┐    ┌──────────────┐    ┌──────────────┐    ┌──────────────┐
│ RALPH-JSONL  │──▶│ RALPH-LOOP   │──▶│ RALPH-HOOKS  │───▶│RALPH-SUBAGENTS│──▶│ RALPH-SKILLS │──▶│ RALPH-TEAMS  │──▶│RALPH-STREAM  │
│ 4/4 Done     │   │ 5/5 Done     │   │ 6/6 Done     │    │ 5/5 Done      │   │ 5/5 Done     │   │ 5/5 Done     │   │ 3/3 Done     │
│ RALPH-MULTI  │   │ Critical     │   │ Critical     │    │ Important     │   │ Important    │   │ Nice-to-have │   │ RALPH-WSL    │
│ 6/6 Done     │   │ P0 Regression│   │ Foundation   │    │ Sub-agents    │   │ -1,368 lines │   │ Experimental │   │ 2/2 Done     │
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

COMPLETED (tapps-brain integration review)
Phase 12 (DONE)
┌──────────────┐   ┌──────────────┐   ┌──────────────┐
│RALPH-BRAINSEC│──▶│RALPH-BRAINPLN│   │RALPH-BRAINDSN│
│ 2/2 Done     │   │ 4/4 Done     │   │ 4/4 Done     │
│ Critical     │   │ High         │   │ Medium       │
│ Crypto+Bypass│   │ Plan Quality │   │ Design Gaps  │
└──────────────┘   └──────────────┘   └──────────────┘
                                             ▲
       ──────────────────────────────────────┘ (BRAINDESIGN depends on BRAINSEC)

COMPLETED (Reliability & Resilience — sourced from 12-hour log review 2026-03-22)
Phase 13 (DONE)
┌──────────────┐   ┌──────────────┐   ┌──────────────┐   ┌──────────────┐
│ RALPH-GUARD  │   │ RALPH-LOCK   │   │RALPH-CAPTURE │   │RALPH-CBDECAY │
│ 2/2 Done     │   │ 1/1 Done     │   │ 3/3 Done     │   │ 2/2 Done     │
│ Critical     │   │ Critical     │   │ High         │   │ High         │
│ Progress Det.│   │ Instance Lock│   │ Stream Recov.│   │ Failure Decay│
└──────────────┘   └──────────────┘   └──────────────┘   └──────────────┘
       │                                                         │
       ▼                                                         │
┌──────────────┐   ┌──────────────┐   ┌──────────────┐          │
│RALPH-ADAPTIVE│   │ RALPH-XPLAT  │   │RALPH-UPKEEP  │          │
│ 2/2 Done     │   │ 3/3 Done     │   │ 2/2 Done     │          │
│ High         │   │ Medium       │   │ Medium       │          │
│ Adapt+Deadline│  │ WSL/Platform │   │ Update + MCP │          │
└──────────────┘   └──────────────┘   └──────────────┘          │
       ▲                                                         │
       └─────────────────────────────────────────────────────────┘ (ADAPTIVE depends on GUARD)

┌──────────────┐
│ RALPH-DEPLOY │
│ 2/2 Done     │
│ High         │
│ Pre-QA Deploy│
└──────────────┘

COMPLETED (2026 Best Practices Modernization)
Phase 14 (DONE)
┌──────────────┐   ┌──────────────┐   ┌──────────────┐   ┌──────────────┐
│RALPH-FAILSPEC│   │ RALPH-OTEL   │   │RALPH-COSTROUTE│  │RALPH-CTXMGMT │
│ 4/4 Done     │   │ 4/4 Done     │   │ 4/4 Done      │  │ 3/3 Done     │
│ Critical     │   │ High         │   │ High          │   │ High         │
│ Compliance   │   │ Observability│   │ Cost 30-70%↓  │   │ Context Mgmt │
└──────────────┘   └──────────────┘   └──────────────┘   └──────────────┘

┌──────────────┐   ┌──────────────┐   ┌──────────────┐
│RALPH-AGENTMEM│   │RALPH-SANDBOXV2│  │ RALPH-EVALS  │
│ 3/3 Done     │   │ 3/3 Done     │   │ 3/3 Done     │
│ Medium       │   │ Medium       │   │ Medium       │
│ Memory       │   │ Security     │   │ Agent Evals  │
└──────────────┘   └──────────────┘   └──────────────┘

Phase 15 (DONE)
┌──────────────┐
│ RALPH-ENABLE │
│ 7/7 Done     │
│ High         │
│ Wizard UX    │
└──────────────┘

Phase 16 (DONE — Production Log Fixes)
┌──────────────┐
│ RALPH-LOGFIX │
│ 8/8 Done     │
│ Critical     │
│ Prod Bugs    │
└──────────────┘

Phase 17 (DONE — SDK v2.1.0 Enhancements)
┌──────────────┐   ┌──────────────┐   ┌──────────────┐
│RALPH-SDK     │   │RALPH-SDK     │   │RALPH-SDK     │
│  -SAFETY     │   │  -CONTEXT    │   │  -COST       │
│ 3/3 Done     │   │ 3/3 Done     │   │ 3/3 Done     │
│ P0-P1        │   │ P0-P2        │   │ P1-P2        │
│ Stall Detect │   │ Context Mgmt │   │ Cost Intel   │
└──────────────┘   └──────────────┘   └──────────────┘

┌──────────────┐   ┌──────────────┐
│RALPH-SDK     │   │RALPH-SDK     │
│  -OUTPUT     │   │  -LIFECYCLE  │
│ 4/4 Done     │   │ 3/3 Done     │
│ P1-P2        │   │ P1-P3        │
│ Structured   │   │ Resilience   │
└──────────────┘   └──────────────┘

v2.4.0 — Plan Optimization
Phase 18 (NEW)
┌──────────────┐
│RALPH-PLANOPT │
│ 5 stories    │
│ High         │
│ Task Ordering│
│ tsort+AST    │
└──────────────┘
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
| Critical | 0 | 22 | 22 |
| High | 0 | 25 | 25 |
| Important | 0 | 16 | 16 |
| Medium | 0 | 47 | 47 |
| Nice-to-have | 0 | 2 | 2 |
| Defensive/Low | 0 | 5 | 5 |
| P0–P3 (SDK) | 0 | 31 | 31 |
| **Total** | **0** | **148** | **148** |

## Critical Path

All phases complete (v2.2.0). 148 stories across 40 epics are done.

### Product Strategy

Ralph is a **standalone product** with full value on its own. TheStudio is the **premium upgrade** with Ralph embedded as Primary Agent.

| Feature Area | Ralph Standalone | TheStudio Premium |
|-------------|-----------------|-------------------|
| GitHub Issues | Basic import + filter + lifecycle | Full pipeline: intake, intent, expert routing, QA |
| Sandbox | Docker + rootless + gVisor | Docker + E2B + Daytona + Cloudflare + plugins |
| Metrics | OTel-compatible JSONL + CLI summary | Full OTel + NATS + dashboards + Reputation Engine |
| Notifications | Terminal + webhook + budget alerts | SSE + Slack/email/Discord |
| Quality Gates | Circuit breaker + exit gate + evals | Verification Gate + QA Agent + expert review |
| Compliance | FAILURE.md + audit log | Full EU AI Act + ISO 42001 |
| Cost Optimization | Model routing + prompt caching | Fleet-wide cost dashboards + policy engine |

```
Phase 0–13:  ALL DONE (93/93 stories, v1.9.0)
Phase 14–17: ALL DONE (55/55 stories, v2.2.0)
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

## Phase 12 — Complete (tapps-brain Integration Review)

### RALPH-BRAINSEC: tapps-brain Integration — Security Design Hardening
**Priority:** Critical | **Status:** Done | **Dependencies:** None
**Source:** Review of [TAPPS_BRAIN_INTEGRATION_RECOMMENDATIONS.md](../../../../TappMCP/docs/planning/TAPPS_BRAIN_INTEGRATION_RECOMMENDATIONS.md)

| # | ID | Story | Priority | Effort | Status |
|---|-----|-------|----------|--------|--------|
| 1 | BRAINSEC-1 | [Upgrade R02 from SHA-256 to HMAC-SHA256](epic-brain-security-design.md) | Critical | Small | **Done** |
| 2 | BRAINSEC-2 | [Add Access Control to R01 Safety Bypass](epic-brain-security-design.md) | Critical | Small | **Done** |

### RALPH-BRAINPLAN: tapps-brain Integration — Planning Rigor
**Priority:** High | **Status:** Done | **Dependencies:** None

| # | ID | Story | Priority | Effort | Status |
|---|-----|-------|----------|--------|--------|
| 1 | BRAINPLAN-1 | [Align Priority Tiers with Roadmap Phases](epic-brain-planning-rigor.md) | High | Trivial | **Done** |
| 2 | BRAINPLAN-2 | [Demote R04 from P0 to P1](epic-brain-planning-rigor.md) | High | Trivial | **Done** |
| 3 | BRAINPLAN-3 | [Add Performance Budget Section](epic-brain-planning-rigor.md) | High | Small | **Done** |
| 4 | BRAINPLAN-4 | [Add Migration and Rollback Strategy](epic-brain-planning-rigor.md) | High | Small | **Done** |

### RALPH-BRAINDESIGN: tapps-brain Integration — Technical Design Refinements
**Priority:** Medium | **Status:** Done | **Dependencies:** RALPH-BRAINSEC

| # | ID | Story | Priority | Effort | Status |
|---|-----|-------|----------|--------|--------|
| 1 | BRAINDESIGN-1 | [Add Success Criteria to P0 Security Recommendations](epic-brain-design-refinements.md) | Medium | Small | **Done** |
| 2 | BRAINDESIGN-2 | [Add Privacy Safeguards to R08 Hive and R14 Auto-Save](epic-brain-design-refinements.md) | Medium | Small | **Done** |
| 3 | BRAINDESIGN-3 | [Gate R10 Graph Boost on Relation Density](epic-brain-design-refinements.md) | Medium | Trivial | **Done** |
| 4 | BRAINDESIGN-4 | [Add Batch-Mode Exemption to R03 Rate Limiting](epic-brain-design-refinements.md) | Medium | Trivial | **Done** |

---

## Phase 13 — Complete (Reliability & Resilience)

**Source:** 12-hour log review of TheStudio and tapps-brain (2026-03-22). All issues identified from production Ralph logs.

### RALPH-GUARD: Loop Progress Detection & Guard Rails
**Priority:** Critical | **Status:** Done | **Target:** v1.9.0 | **Dependencies:** None

| # | ID | Story | Priority | Effort | Status |
|---|-----|-------|----------|--------|--------|
| 1 | [GUARD-1](story-guard-1-baseline-snapshotting.md) | Git Diff Baseline Snapshotting | Critical | Small | **Done** |
| 2 | [GUARD-2](story-guard-2-consecutive-timeout-breaker.md) | Consecutive Timeout Circuit Breaker | Critical | Small | **Done** |

### RALPH-LOCK: Concurrent Instance Prevention
**Priority:** Critical | **Status:** Done | **Target:** v1.9.0 | **Dependencies:** None

| # | ID | Story | Priority | Effort | Status |
|---|-----|-------|----------|--------|--------|
| 1 | [LOCK-1](story-lock-1-flock-instance-locking.md) | Flock-Based Instance Locking | Critical | Small | **Done** |

### RALPH-CAPTURE: Stream Capture & Recovery
**Priority:** High | **Status:** Done | **Target:** v1.9.0 | **Dependencies:** None

| # | ID | Story | Priority | Effort | Status |
|---|-----|-------|----------|--------|--------|
| 1 | [CAPTURE-1](story-capture-1-progressive-stream-capture.md) | Progressive Stream Capture Before SIGTERM | High | Medium | **Done** |
| 2 | [CAPTURE-2](story-capture-2-multi-result-merging.md) | Multi-Result Stream Merging Strategy | Medium | Small | **Done** |
| 3 | [CAPTURE-3](story-capture-3-stats-newline-fix.md) | Fix Execution Stats Newline Parsing | Low | Trivial | **Done** |

### RALPH-CBDECAY: Circuit Breaker Failure Decay
**Priority:** High | **Status:** Done | **Target:** v1.9.0 | **Dependencies:** None

| # | ID | Story | Priority | Effort | Status |
|---|-----|-------|----------|--------|--------|
| 1 | [CBDECAY-1](story-cbdecay-1-sliding-window.md) | Time-Weighted Sliding Window | High | Medium | **Done** |
| 2 | [CBDECAY-2](story-cbdecay-2-session-reinitialization.md) | Session State Reinitialization After CB Reset | Medium | Small | **Done** |

### RALPH-ADAPTIVE: Adaptive Timeout Strategy
**Priority:** High | **Status:** Done | **Target:** v1.9.0 | **Dependencies:** RALPH-GUARD

| # | ID | Story | Priority | Effort | Status |
|---|-----|-------|----------|--------|--------|
| 1 | [ADAPTIVE-1](story-adaptive-1-percentile-timeout.md) | Percentile-Based Adaptive Timeout | High | Medium | **Done** |
| 2 | [ADAPTIVE-2](story-adaptive-2-sub-agent-deadline-budget.md) | Sub-Agent Deadline Budget | High | Medium | **Done** |

### RALPH-DEPLOY: Pre-QA Environment Verification
**Priority:** High | **Status:** Done | **Target:** v1.9.0 | **Dependencies:** None

| # | ID | Story | Priority | Effort | Status |
|---|-----|-------|----------|--------|--------|
| 1 | [DEPLOY-1](story-deploy-1-container-freshness-check.md) | Container Freshness Check Before Integration Tests | High | Small | **Done** |
| 2 | [DEPLOY-2](story-deploy-2-agent-build-instructions.md) | Add Build/Deploy Instructions to QA Agent Prompts | Medium | Small | **Done** |

### RALPH-XPLAT: Cross-Platform Compatibility
**Priority:** Medium | **Status:** Done | **Target:** v1.9.0 | **Dependencies:** None

| # | ID | Story | Priority | Effort | Status |
|---|-----|-------|----------|--------|--------|
| 1 | [XPLAT-1](story-xplat-1-version-divergence-fix.md) | Fix False Version Divergence Warning | Medium | Trivial | **Done** |
| 2 | [XPLAT-2](story-xplat-2-hook-environment-detection.md) | Cross-Platform Hook Environment Detection | Medium | Small | **Done** |
| 3 | [XPLAT-3](story-xplat-3-python3-wsl-alias.md) | Python3 Alias in WSL Agent Environments | Low | Trivial | **Done** |

### RALPH-UPKEEP: Update & Log Reliability
**Priority:** Medium | **Status:** Done | **Target:** v1.9.0 | **Dependencies:** None

| # | ID | Story | Priority | Effort | Status |
|---|-----|-------|----------|--------|--------|
| 1 | [UPKEEP-1](story-upkeep-1-update-verification.md) | CLI Auto-Update Verification | Medium | Small | **Done** |
| 2 | [UPKEEP-2](story-upkeep-2-mcp-failure-suppression.md) | MCP Server Failure Suppression | Medium | Small | **Done** |

---

## Phase 14 — Complete (2026 Best Practices Modernization)

**Source:** Comprehensive 2026 research review covering: AI agent loop architecture, reliability patterns, security standards, OpenTelemetry, testing frameworks, cost optimization, and EU AI Act compliance. Research drawn from Anthropic, AWS, OpenAI Codex, Google GKE, Langfuse, AgentAssay, FAILURE.md spec, and 30+ industry references.

```
Phase 14 (DONE)
┌──────────────┐   ┌──────────────┐   ┌──────────────┐   ┌──────────────┐
│RALPH-FAILSPEC│   │ RALPH-OTEL   │   │RALPH-COSTROUTE│  │RALPH-CTXMGMT │
│ 4/4 Done     │   │ 4/4 Done     │   │ 4/4 Done      │  │ 3/3 Done     │
│ Critical     │   │ High         │   │ High          │   │ High         │
│ Compliance   │   │ Observability│   │ Cost 30-70%↓  │   │ Context Mgmt │
└──────────────┘   └──────────────┘   └──────────────┘   └──────────────┘
                          │                  │
                          ▼                  │
┌──────────────┐   ┌──────────────┐   ┌──────────────┐
│RALPH-AGENTMEM│   │RALPH-SANDBOXV2│  │ RALPH-EVALS  │◀─┘
│ 3/3 Done     │   │ 3/3 Done     │   │ 3/3 Done     │
│ Medium       │   │ Medium       │   │ Medium       │
│ Cross-session│   │ Security     │   │ Agent testing │
└──────────────┘   └──────────────┘   └──────────────┘
       ▲
       └──────────── OTEL provides trace data for AGENTMEM and EVALS
```

### RALPH-FAILSPEC: Failure Protocol Compliance
**Priority:** Critical | **Status:** Done | **Target:** v2.0.0 | **Dependencies:** None
**Compliance:** FAILURE.md/FAILSAFE.md/KILLSWITCH.md open specs + EU AI Act (August 2026)

| # | ID | Story | Priority | Effort | Status |
|---|-----|-------|----------|--------|--------|
| 1 | [FAILSPEC-1](story-failspec-1-failure-md.md) | Implement FAILURE.md Specification | Critical | Medium | **Done** |
| 2 | [FAILSPEC-2](story-failspec-2-failsafe-md.md) | Implement FAILSAFE.md Safe Fallback Behaviors | Critical | Small | **Done** |
| 3 | [FAILSPEC-3](story-failspec-3-killswitch-md.md) | Implement KILLSWITCH.md Emergency Stop | Critical | Small | **Done** |
| 4 | [FAILSPEC-4](story-failspec-4-audit-logging.md) | Structured Audit Log for Compliance | High | Medium | **Done** |

### RALPH-OTEL: OpenTelemetry & Observability v2
**Priority:** High | **Status:** Done | **Target:** v2.1.0 | **Dependencies:** None
**Upgrade:** Extends Phase 8 RALPH-OBSERVE with OTel GenAI Semantic Conventions

| # | ID | Story | Priority | Effort | Status |
|---|-----|-------|----------|--------|--------|
| 1 | [OTEL-1](story-otel-1-trace-generation.md) | OTel Trace Generation with GenAI Semantic Conventions | High | Medium | **Done** |
| 2 | [OTEL-2](story-otel-2-trace-propagation.md) | Trace ID Propagation Across Sub-Agents and Hooks | High | Small | **Done** |
| 3 | [OTEL-3](story-otel-3-cost-attribution.md) | Per-Trace Cost Attribution and Budget Alerts | Medium | Small | **Done** |
| 4 | [OTEL-4](story-otel-4-otlp-exporter.md) | OTLP Exporter for External Backends | Medium | Medium | **Done** |

### RALPH-COSTROUTE: Cost-Aware Model Routing
**Priority:** High | **Status:** Done | **Target:** v2.1.0 | **Dependencies:** None
**Impact:** 30-70% cost reduction via dynamic model selection + prompt caching

| # | ID | Story | Priority | Effort | Status |
|---|-----|-------|----------|--------|--------|
| 1 | [COSTROUTE-1](story-costroute-1-complexity-classifier.md) | Task Complexity Classifier | High | Medium | **Done** |
| 2 | [COSTROUTE-2](story-costroute-2-dynamic-model-selection.md) | Dynamic Model Selection Based on Complexity | High | Medium | **Done** |
| 3 | [COSTROUTE-3](story-costroute-3-prompt-cache-optimization.md) | Prompt Structure Optimization for Cache Hits | High | Small | **Done** |
| 4 | [COSTROUTE-4](story-costroute-4-token-budget.md) | Token Budget and Cost Dashboard | Medium | Small | **Done** |

### RALPH-CTXMGMT: Context Window Management
**Priority:** High | **Status:** Done | **Target:** v2.1.0 | **Dependencies:** None
**Research:** Success rate drops after 35 min; doubling duration quadruples failure rate

| # | ID | Story | Priority | Effort | Status |
|---|-----|-------|----------|--------|--------|
| 1 | [CTXMGMT-1](story-ctxmgmt-1-progressive-loading.md) | Progressive Context Loading Strategy | High | Medium | **Done** |
| 2 | [CTXMGMT-2](story-ctxmgmt-2-task-decomposition.md) | Task Decomposition Signals | High | Small | **Done** |
| 3 | [CTXMGMT-3](story-ctxmgmt-3-continue-as-new.md) | Continue-As-New Pattern for Long Sessions | Medium | Medium | **Done** |

### RALPH-ENABLE: Enable Wizard Hardening & UX Improvements
**Priority:** High | **Status:** Done | **Target:** v2.1.0 | **Dependencies:** None
**Source:** Interactive `ralph enable` review focused on reliability, safety, and first-run UX.

| # | ID | Story | Priority | Effort | Status |
|---|-----|-------|----------|--------|--------|
| 1 | [ENABLE-1](story-enable-1-state-detection-alignment.md) | Align Enabled-State Detection with Required Artifacts | Critical | Small | **Done** |
| 2 | [ENABLE-2](story-enable-2-cli-input-validation.md) | Strict CLI Validation for `--from` and `--prd` | High | Small | **Done** |
| 3 | [ENABLE-3](story-enable-3-import-failure-transparency.md) | Source-Level Import Result Reporting | High | Medium | **Done** |
| 4 | [ENABLE-4](story-enable-4-force-safety-and-backups.md) | Harden `--force` Behavior and Preserve User Files | High | Medium | **Done** |
| 5 | [ENABLE-5](story-enable-5-task-normalization-dedup.md) | Normalize, Deduplicate, and Cap Imported Tasks | Medium | Medium | **Done** |
| 6 | [ENABLE-6](story-enable-6-dry-run-and-json-output.md) | Add `--dry-run` and `--json` for Automation | Medium | Medium | **Done** |
| 7 | [ENABLE-7](story-enable-7-wizard-ux-improvements.md) | Improve Prompt UX and Final Summary Guidance | Medium | Small | **Done** |

### RALPH-AGENTMEM: Cross-Session Agent Memory
**Priority:** Medium | **Status:** Done | **Target:** v2.2.0 | **Dependencies:** RALPH-OTEL
**Research:** 4 memory types (working, episodic, semantic, procedural) — adding episodic + semantic

| # | ID | Story | Priority | Effort | Status |
|---|-----|-------|----------|--------|--------|
| 1 | [AGENTMEM-1](story-agentmem-1-episodic-memory.md) | Episodic Memory Store (What Worked/Failed) | Medium | Medium | **Done** |
| 2 | [AGENTMEM-2](story-agentmem-2-semantic-memory.md) | Codebase Pattern Memory (Semantic) | Medium | Medium | **Done** |
| 3 | [AGENTMEM-3](story-agentmem-3-memory-decay.md) | Memory Decay and Relevance Scoring | Medium | Small | **Done** |

### RALPH-SANDBOXV2: Sandbox Hardening
**Priority:** Medium | **Status:** Done | **Target:** v2.2.0 | **Dependencies:** RALPH-SANDBOX (Phase 11)
**Security:** Rootless Docker, network egress blocking (OpenAI Codex pattern), gVisor option

| # | ID | Story | Priority | Effort | Status |
|---|-----|-------|----------|--------|--------|
| 1 | [SANDBOXV2-1](story-sandboxv2-1-rootless-egress.md) | Rootless Docker Mode and Network Egress Control | Medium | Medium | **Done** |
| 2 | [SANDBOXV2-2](story-sandboxv2-2-resource-reporting.md) | Resource Usage Reporting | Medium | Small | **Done** |
| 3 | [SANDBOXV2-3](story-sandboxv2-3-gvisor.md) | gVisor Runtime Support | Low | Medium | **Done** |

### RALPH-EVALS: Agent Evaluation Framework
**Priority:** Medium | **Status:** Done | **Target:** v2.2.0 | **Dependencies:** RALPH-OTEL
**Research:** AgentAssay 3-valued outcomes, golden-file testing, deterministic + stochastic suites

| # | ID | Story | Priority | Effort | Status |
|---|-----|-------|----------|--------|--------|
| 1 | [EVALS-1](story-evals-1-golden-files.md) | Golden-File Test Infrastructure | Medium | Medium | **Done** |
| 2 | [EVALS-2](story-evals-2-deterministic-suite.md) | Deterministic Agent Eval Suite | Medium | Medium | **Done** |
| 3 | [EVALS-3](story-evals-3-stochastic-suite.md) | Stochastic Eval Suite with Three-Valued Outcomes | Medium | Medium | **Done** |

---

## Phase 16 — Done (Production Log Issue Fixes)

**Source:** Log review of TheStudio, tapps-brain, TappMCP production Ralph instances (2026-03-23).

### RALPH-LOGFIX: Production Log Issue Fixes
**Priority:** Critical | **Status:** Done | **Target:** v2.2.0 | **Dependencies:** None

| # | ID | Story | Priority | Effort | Status |
|---|-----|-------|----------|--------|--------|
| 1 | LOGFIX-1 | Fix Graceful Exit Logged as Crash (exit code 2) | Critical | Small | **Done** |
| 2 | LOGFIX-2 | Harden Concurrent Instance Lock (auto-kill stale PID) | High | Small | **Done** |
| 3 | LOGFIX-3 | Downgrade Stream Extraction to WARN on Timeout | High | Trivial | **Done** |
| 4 | LOGFIX-4 | Fast-Trip Circuit Breaker on Broken Invocations | Medium | Small | **Done** |
| 5 | LOGFIX-5 | Categorize Error Counts (expected vs system) | Medium | Small | **Done** |
| 6 | LOGFIX-6 | Stall Detection for Persistent Deferred Tests | Medium | Small | **Done** |
| 7 | LOGFIX-7 | Fix Permission Denied Warning Message | Medium | Trivial | **Done** |
| 8 | LOGFIX-8 | Circuit Breaker State Consistency | Low | Trivial | **Done** |

---

## Phase 17 — Complete (SDK v2.1.0 Enhancements)

**Source:** SDK upgrade evaluation comparing CLI v2.2.0 capabilities against SDK v2.0.2 gaps. Research integrated from 4 agents: Claude API pricing, prompt caching, Temporal patterns, circuit breaker best practices — all validated against 2026 sources.

```
Phase 17 (DONE — SDK v2.1.0)
┌──────────────┐   ┌──────────────┐   ┌──────────────┐
│RALPH-SDK     │   │RALPH-SDK     │   │RALPH-SDK     │
│  -SAFETY     │   │  -CONTEXT    │   │  -COST       │
│ 3/3 Done     │   │ 3/3 Done     │   │ 3/3 Done     │
│ P0-P1        │   │ P0-P2        │   │ P1-P2        │
│ Stall Detect │   │ Context Mgmt │   │ Cost Intel   │
└──────────────┘   └──────────────┘   └──────────────┘
       │                  │
       ▼                  ▼
┌──────────────┐   ┌──────────────┐
│RALPH-SDK     │   │RALPH-SDK     │
│  -OUTPUT     │   │  -LIFECYCLE  │
│ 4/4 Done     │   │ 3/3 Done     │
│ P1-P2        │   │ P1-P3        │
│ Structured   │   │ Resilience   │
└──────────────┘   └──────────────┘
       ▲                  ▲
       └──────────────────┘ (LIFECYCLE depends on SAFETY)
```

### RALPH-SDK-SAFETY: SDK Loop Safety
**Priority:** P0–P1 | **Status:** Done | **Target:** SDK v2.1.0 | **Dependencies:** None
**Impact:** Stall detection, decomposition hints, completion decay — matching CLI v2.2.0 safety

| # | ID | Story | Priority | Effort | Status |
|---|-----|-------|----------|--------|--------|
| 1 | [SDK-SAFETY-1](story-sdk-safety-1-stall-detection.md) | Stall Detection (fast-trip, deferred-test, consecutive timeout) | P0 | 1–2 days | **Done** |
| 2 | [SDK-SAFETY-2](story-sdk-safety-2-task-decomposition.md) | Task Decomposition Detection | P1 | 1 day | **Done** |
| 3 | [SDK-SAFETY-3](story-sdk-safety-3-completion-decay.md) | Completion Indicator Decay | P1 | 0.5 day | **Done** |

### RALPH-SDK-CONTEXT: SDK Context Management
**Priority:** P0–P2 | **Status:** Done | **Target:** SDK v2.1.0 | **Dependencies:** None
**Impact:** Progressive loading, prompt cache optimization, session lifecycle — token efficiency

| # | ID | Story | Priority | Effort | Status |
|---|-----|-------|----------|--------|--------|
| 1 | [SDK-CONTEXT-1](story-sdk-context-1-progressive-loading.md) | Progressive Context Loading | P0 | 1–2 days | **Done** |
| 2 | [SDK-CONTEXT-2](story-sdk-context-2-prompt-cache.md) | Prompt Cache Optimization | P2 | 1 day | **Done** |
| 3 | [SDK-CONTEXT-3](story-sdk-context-3-session-lifecycle.md) | Session Lifecycle Management and Continue-As-New | P2 | 2 days | **Done** |

### RALPH-SDK-COST: SDK Cost Intelligence
**Priority:** P1–P2 | **Status:** Done | **Target:** SDK v2.1.0 | **Dependencies:** None
**Impact:** Cost tracking, model routing, token rate limiting — 30-70% cost reduction

| # | ID | Story | Priority | Effort | Status |
|---|-----|-------|----------|--------|--------|
| 1 | [SDK-COST-1](story-sdk-cost-1-cost-tracking.md) | Cost Tracking and Budget Guardrails | P1 | 2 days | **Done** |
| 2 | [SDK-COST-2](story-sdk-cost-2-model-routing.md) | Dynamic Model Routing | P1 | 1 day | **Done** |
| 3 | [SDK-COST-3](story-sdk-cost-3-token-rate-limiting.md) | Token-Based Rate Limiting | P2 | 1 day | **Done** |

### RALPH-SDK-OUTPUT: SDK Structured Output
**Priority:** P1–P2 | **Status:** Done | **Target:** SDK v2.1.0 | **Dependencies:** None
**Impact:** files_changed extraction, error categories, heartbeat snapshots, metrics collection

| # | ID | Story | Priority | Effort | Status |
|---|-----|-------|----------|--------|--------|
| 1 | [SDK-OUTPUT-1](story-sdk-output-1-files-changed.md) | Structured `files_changed` on TaskResult | P1 | 0.5 day | **Done** |
| 2 | [SDK-OUTPUT-2](story-sdk-output-2-error-categorization.md) | Error Categorization | P2 | 1 day | **Done** |
| 3 | [SDK-OUTPUT-3](story-sdk-output-3-progress-snapshot.md) | Structured Heartbeat / Progress Snapshot | P2 | 0.5 day | **Done** |
| 4 | [SDK-OUTPUT-4](story-sdk-output-4-metrics-collection.md) | Metrics Collection | P2 | 1–2 days | **Done** |

### RALPH-SDK-LIFECYCLE: SDK Lifecycle & Resilience
**Priority:** P1–P3 | **Status:** Done | **Target:** SDK v2.2.0 | **Dependencies:** RALPH-SDK-SAFETY
**Impact:** Cancel semantics, adaptive timeout, permission denial detection

| # | ID | Story | Priority | Effort | Status |
|---|-----|-------|----------|--------|--------|
| 1 | [SDK-LIFECYCLE-1](story-sdk-lifecycle-1-cancel-semantics.md) | Cancel Semantics Documentation and Hardening | P1 | 0.5 day | **Done** |
| 2 | [SDK-LIFECYCLE-2](story-sdk-lifecycle-2-adaptive-timeout.md) | Adaptive Timeout | P3 | 1 day | **Done** |
| 3 | [SDK-LIFECYCLE-3](story-sdk-lifecycle-3-permission-denial.md) | Permission Denial Detection | P3 | 1 day | **Done** |

---

## Phase 18 — v2.4.0 (Plan Optimization)

**Source:** Deep spec review with research-backed redesign. Grounded in SWE-Agent, Agentless, Reflexion, "Lost in the Middle" research + Nx/Turborepo/Bazel build system patterns. Validated via tapps_checklist and docs_check_cross_refs.

### RALPH-PLANOPT: Fix Plan Optimization on Startup
**Priority:** High | **Status:** Implemented | **Target:** v2.4.0 | **Dependencies:** None
**Impact:** Automatic task reordering for dependency order, module locality, and batch density. AST-based import graph + Unix tsort + ralph-explorer (Haiku) for vague task resolution.

| Story | Title | Status |
|-------|-------|--------|
| PLANOPT-1 | [File dependency graph](story-planopt-1-file-dependency-graph.md) | Done |
| PLANOPT-2 | [Plan analysis and reordering engine](story-planopt-2-analysis-and-reorder.md) | Done |
| PLANOPT-3 | [Session-start integration](story-planopt-3-session-start.md) | Done |
| PLANOPT-4 | [Import-time optimization](story-planopt-4-import-optimization.md) | Done |
| PLANOPT-5 | [Observability and logging](story-planopt-5-observability.md) | Done |

**Files added:** `lib/import_graph.sh` (9 functions), `lib/plan_optimizer.sh` (11 functions), `.claude/skills/ralph-optimize/SKILL.md`
**Files modified:** `on-session-start.sh`, `on-task-completed.sh`, `on-stop.sh`, `ralph.md`, `ralph_import.sh`, `ralphrc.template`, `CLAUDE.md`
**Tests:** 48 new tests across 3 BATS files

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
