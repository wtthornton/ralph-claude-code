# Story SDK-4: Document SDK Migration Strategy

**Epic:** [RALPH-SDK](epic-sdk-integration.md)
**Priority:** Medium
**Status:** Open
**Effort:** Small
**Component:** `docs/sdk-migration.md`

---

## Problem

Ralph users need clear guidance on:
1. When to use CLI vs SDK vs embedded mode
2. How to migrate existing `.ralph/` projects from CLI to SDK
3. What TheStudio integration looks like and when to consider upgrading
4. What features are available in each mode

Without documentation, the hybrid architecture (SDK-3) creates confusion about which mode to use.

## Solution

Create a migration strategy document that covers all three operational modes, decision criteria, and step-by-step migration paths.

## Implementation

Create `docs/sdk-migration.md` with the following sections:

### 1. Operational Modes Overview
| Mode | Entry Point | Use Case | Requirements |
|------|-------------|----------|--------------|
| CLI Standalone | `ralph` | Individual developers, simple projects | bash, Claude Code CLI |
| SDK Standalone | `ralph --sdk` | Python-native projects, custom tools | Python 3.12+, Agent SDK |
| TheStudio Embedded | TheStudio pipeline | Teams, quality gates, expert routing | TheStudio deployment |

### 2. Decision Matrix
- Use CLI when: bash-native environment, simple task lists, existing `.ralphrc` setup
- Use SDK when: need custom tools, Python project, want programmatic control
- Use TheStudio when: need quality gates, expert routing, multi-repo management, compliance

### 3. Migration Path: CLI → SDK
- Step-by-step instructions for converting a CLI project to SDK
- `.ralphrc` → `ralph.config.json` mapping
- Hook migration (bash hooks → Python callbacks)
- Sub-agent configuration differences

### 4. Migration Path: SDK → TheStudio Embedded
- How TaskPackets replace fix_plan.md
- How Signals replace status.json
- What Ralph features are superseded by TheStudio (intake, verification, QA, publishing)
- What Ralph features are preserved (loop reliability, circuit breaker, sub-agents)

### 5. Feature Comparison Matrix
- Complete feature-by-feature comparison across all three modes

### Key Design Decisions

1. **CLI is not deprecated:** The document must clearly state that CLI mode is first-class and fully supported. SDK is an additional option, not a replacement.
2. **Upgrade path is clear:** Each mode is a superset of the previous. CLI → SDK adds custom tools. SDK → TheStudio adds pipeline, experts, QA.

## Testing

No automated tests — this is a documentation deliverable. Review criteria:

1. A new user can determine which mode to use within 2 minutes of reading
2. Migration steps are copy-paste executable
3. Feature comparison is accurate against current codebase

## Acceptance Criteria

- [ ] Document covers all three operational modes with clear descriptions
- [ ] Decision matrix helps users choose the right mode
- [ ] CLI → SDK migration path is step-by-step with examples
- [ ] SDK → TheStudio migration path explains what changes and what stays
- [ ] Feature comparison matrix is complete and accurate
- [ ] Document states CLI is not deprecated and remains first-class
- [ ] Document reviewed against actual SDK-1/SDK-2/SDK-3 implementations
