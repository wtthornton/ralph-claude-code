# Epic: GitHub Issue Integration — Standalone (Phase 10)

**Epic ID:** RALPH-GHISSUE
**Priority:** Important
**Affects:** Task intake, GitHub workflow, issue lifecycle
**Components:** `ralph_loop.sh`, `lib/task_sources.sh`, new `lib/github_issues.sh`
**Related specs:** `IMPLEMENTATION_PLAN.md` (§Phase 5)
**Target Version:** v1.7.0
**Depends on:** None (standalone capability)

---

## Problem Statement

Ralph can import tasks from PRD documents and beads, but has no native GitHub Issue integration. Developers using Ralph standalone need to:

1. **Import a single issue** as a fix_plan.md task list
2. **Assess incomplete issues** and generate implementation plans
3. **Filter issues** by labels, assignees, milestones to find work
4. **Batch process** multiple issues in priority order
5. **Close issues** and link commits when work completes

This epic is **deliberately scoped as lightweight standalone** — good enough for individual developers working with their own repos. TheStudio provides the premium experience with full webhook ingress, deduplication, idempotency, context enrichment (complexity index, risk flags, service context packs), Intent Specification, expert routing, and evidence-backed PR publishing.

## TheStudio Relationship

| Capability | Ralph Standalone | TheStudio Premium |
|------------|-----------------|-------------------|
| Intake | `ralph --issue 42` reads description | Webhook ingress, dedup, eligibility, TaskPacket |
| Enrichment | None — user provides context in PROMPT.md | Context Agent: complexity index, risk flags, service packs |
| Planning | Generate fix_plan.md checkbox list | Intent Specification with acceptance criteria, non-goals |
| Filtering | `ralph --issues --label bug --milestone v2` | Full metadata filtering + batch queue + priority ranking |
| Lifecycle | Close issue, link commit SHA | Labels, Projects v2 sync, evidence comments, reopen tracking |
| Quality | Circuit breaker + dual exit gate | Verification Gate + QA Agent + expert review |

When Ralph runs inside TheStudio, these standalone features are bypassed — TheStudio's Intake pipeline handles everything upstream.

## Stories

| Story | Title | Priority | Effort | Status |
|-------|-------|----------|--------|--------|
| [GHISSUE-1](story-ghissue-1-plan-import.md) | Plan Import from GitHub Issue | Important | Medium | **Done** |
| [GHISSUE-2](story-ghissue-2-completeness-assessment.md) | Issue Completeness Assessment | Medium | Medium | **Done** |
| [GHISSUE-3](story-ghissue-3-issue-filtering.md) | GitHub Issue Filtering | Medium | Small | **Done** |
| [GHISSUE-4](story-ghissue-4-batch-processing.md) | Batch Processing and Issue Queue | Medium | Medium | **Done** |
| [GHISSUE-5](story-ghissue-5-lifecycle-management.md) | Issue Lifecycle Management | Medium | Small | **Done** |

## Implementation Order

1. **GHISSUE-1 (Important)** — Core capability: read one issue, produce fix_plan.md
2. **GHISSUE-3 (Medium)** — Filtering enables finding the right issue; supports GHISSUE-4
3. **GHISSUE-2 (Medium)** — Completeness assessment enhances GHISSUE-1 output quality
4. **GHISSUE-4 (Medium)** — Batch processing requires GHISSUE-1 and GHISSUE-3
5. **GHISSUE-5 (Medium)** — Lifecycle management after core workflow is proven

## Verification Criteria

- [ ] `ralph --issue 42` imports GitHub issue #42 and generates fix_plan.md
- [ ] Incomplete issues get auto-generated implementation plans via Claude
- [ ] `ralph --issues --label bug` lists and filters issues from current repo
- [ ] `ralph --batch --label "priority:high"` processes issues in sequence
- [ ] Completed issues are closed with commit reference in comment
- [ ] Works with both `gh` CLI and GitHub API token authentication
- [ ] Graceful degradation when `gh` CLI is not installed

## Rollback

All GitHub integration is additive. Existing fix_plan.md and PRD import workflows are unaffected. GitHub features require explicit flags to activate.
