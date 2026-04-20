# Linear Workflow for Ralph-Managed Projects

This is the source of truth for how Ralph (and the humans working alongside it) use Linear statuses. All Ralph-enabled projects in the `TappsCodingAgents` team follow this. The key enforcement points are the Ralph prompt at [ralph_loop.sh:2043](../ralph_loop.sh#L2043) and the backend query at [lib/linear_backend.sh:168](../lib/linear_backend.sh#L168).

## State lifecycle

| State | Linear type | Who moves here | Meaning |
|-------|------------|----------------|---------|
| **Backlog** | `backlog` | Human (triage) | Captured idea. Spec not yet ready, or the work is blocked on something upstream we haven't resolved. |
| **Todo** | `unstarted` | Human (when ready) | Spec-complete, unblocked, ready for Ralph to pick next. |
| **In Progress** | `started` | Claude (automatic) | Ralph is actively working this issue in the current loop. |
| **In Review** | `started` | Claude (rare — hard blockers only) | Work cannot proceed without a human, and Claude has no safe default to pick. The last comment must name one of the four valid reasons in R2. An unmerged branch is **not** an In Review reason — that stays In Progress. |
| **Done** | `completed` | Claude (happy path) | Commits are on `main` AND acceptance criteria are substantively met. Cosmetic AC mismatches (e.g. "AC says 14 tools, tests assert 15") do not block Done. |
| **Canceled** | `canceled` | Human | Won't do. |
| **Duplicate** | `canceled` | Human | Superseded by another issue. |

## Hard rules

**R1. Done requires `main`. Unmerged branches stay In Progress, not In Review.**
Before marking a ticket Done, Claude runs `git log main --grep='<TICKET-ID>'` and confirms at least one matching commit exists on `main`. If the work is only on a branch, Claude **attempts to self-merge** (`gh pr merge --squash --auto`, direct `git merge`, etc.). If the merge is blocked (no permission, required checks pending, unresolvable conflicts), Claude posts a Linear comment listing the unmerged commit SHAs and leaves the ticket **In Progress** so Ralph retries next loop. "Unmerged branch" is explicitly **not** an In Review reason — before this rule change it was the single largest cause of In Review pileup in tapps-brain.

**R2. In Review is for hard blockers only — the four valid reasons.**
Ralph is headless. There is no human on standby to review code, answer questions, or make cosmetic decisions. There is no human reviewer — "needs code review" is not a valid reason. Claude may move a ticket to In Review **only** when all four of these are true: work cannot proceed, Claude cannot self-resolve in another loop, no safe default exists, and the blocker matches **exactly** one of:

1. **Missing credentials or API keys** Claude cannot generate (e.g. a third-party OAuth token requiring a human to click through).
2. **Explicit budget or spend cap reached** (Anthropic spend limit, cloud quota) where continuing would exceed sanctioned cost.
3. **Irreversible destructive operation requiring human sign-off** — production database migration dropping data, secret rotation, mass deletion, credential exfiltration risk. Security *bug fixes* and security *hardening* are **not** this reason — those go to Done.
4. **Genuinely ambiguous product decision** where both interpretations have real cost and neither is a safe default.

**When in doubt between Done and In Review: pick Done if AC is substantively met, In Progress if it is not. Never pick In Review out of uncertainty.**

The last Linear comment on an In Review ticket **must** name one of these four reasons verbatim. If Claude cannot name one, it picks Done (if AC substantively met) or leaves the ticket In Progress for retry.

**Explicitly NOT In Review reasons** (these stay In Progress or go Done):
- Branch not yet on `main` → In Progress, retry (R1)
- Flaky tests, red build, lint failures → fix them
- "Code probably works but I'm unsure" → Done if AC substantively met
- "Needs code review" → Done (no reviewer exists — there is no human reviewer)
- "Couldn't figure out how to do X this loop" → In Progress, retry with fresh context
- Cosmetic AC mismatch (numbers/wording off) → Done
- Security bug fix or security hardening → Done (this is not a destructive action)
- Uncertainty about correctness → Done if AC substantively met

**R3. Ralph does not pick up In Review or In Progress.**
`linear_get_next_task` queries only `state.type IN [backlog, unstarted]`. Tickets left in In Review or In Progress become invisible to Ralph and pile up silently. Because In Review is now rare, In Progress becomes Ralph's self-retry lane — a ticket sitting In Progress across loops means Ralph is working it, not that a human must act.

**R4. Backlog vs Todo is a signal for humans, not Ralph.**
Ralph treats them identically (same priority-sorted queue). Use Backlog for "triaged but not yet ready"; use Todo for "spec-ready, pick this next". Tickets returning from In Review after a blocker clears go back to Todo, not Backlog.

**R5. Claude never moves tickets to Backlog, Canceled, or Duplicate.**
Those are triage decisions humans make. If Claude thinks a ticket should be canceled or duplicates another, it posts a comment recommending it and leaves the state alone.

## Transition table — what Claude does

| From | To | Trigger |
|------|-----|---------|
| Backlog / Todo | In Progress | Loop pickup |
| In Progress | Done | Commits on `main`, AC substantively met (R1) |
| In Progress | In Progress (stays) | Unmerged branch, flaky tests, unresolved this loop — Ralph retries next loop (R1, R2) |
| In Progress | In Review | **Rare.** Hard blocker matching one of R2's four reasons, with that reason named in the last comment |

## Transition table — what humans do

| From | To | Trigger |
|------|-----|---------|
| (new) | Backlog | Triage |
| Backlog | Todo | Spec is ready, unblocked |
| In Review | Todo | Blocker cleared, Ralph can resume |
| Any | Canceled / Duplicate | Won't do / superseded |

## Required Linear team configuration

This workflow assumes a Linear team with these statuses (names are flexible as long as the underlying Linear type matches):

| Name | Linear type |
|------|------------|
| Backlog | `backlog` |
| Todo | `unstarted` |
| In Progress | `started` |
| In Review | `started` |
| Done | `completed` |
| Canceled | `canceled` |
| Duplicate | `canceled` |

If your team renames these (e.g. "Ready" instead of "Todo"), Ralph still picks them up correctly — it queries by type, not by name. But the names in this doc match the `TappsCodingAgents` team's conventions today.

## Related

- Prompt enforcement: [ralph_loop.sh:2043](../ralph_loop.sh#L2043)
- Pickup query: [lib/linear_backend.sh:168](../lib/linear_backend.sh#L168)
- Fail-loud API handling (TAP-536): [lib/linear_backend.sh](../lib/linear_backend.sh)
