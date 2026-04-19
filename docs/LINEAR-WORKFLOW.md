# Linear Workflow for Ralph-Managed Projects

This is the source of truth for how Ralph (and the humans working alongside it) use Linear statuses. All Ralph-enabled projects in the `TappsCodingAgents` team follow this. The key enforcement points are the Ralph prompt at [ralph_loop.sh:2043](../ralph_loop.sh#L2043) and the backend query at [lib/linear_backend.sh:168](../lib/linear_backend.sh#L168).

## State lifecycle

| State | Linear type | Who moves here | Meaning |
|-------|------------|----------------|---------|
| **Backlog** | `backlog` | Human (triage) | Captured idea. Spec not yet ready, or the work is blocked on something upstream we haven't resolved. |
| **Todo** | `unstarted` | Human (when ready) | Spec-complete, unblocked, ready for Ralph to pick next. |
| **In Progress** | `started` | Claude (automatic) | Ralph is actively working this issue in the current loop. |
| **In Review** | `started` | Claude (only when blocked) | Code shipped to a branch but NOT merged to `main`, OR blocked on external input (credentials, budget approval, human decision). The last comment must state the blocker. |
| **Done** | `completed` | Claude (happy path) | Commits are on `main` AND acceptance criteria are substantively met. Cosmetic AC mismatches (e.g. "AC says 14 tools, tests assert 15") do not block Done. |
| **Canceled** | `canceled` | Human | Won't do. |
| **Duplicate** | `canceled` | Human | Superseded by another issue. |

## Hard rules

**R1. Done requires `main`.**
Before marking a ticket Done, Claude runs `git log main --grep='<TICKET-ID>'` and confirms at least one matching commit exists on `main`. An "implementation complete on branch X" comment is not sufficient — branches can go unmerged indefinitely, and that is the single most common failure mode observed in this workspace to date.

**R2. In Review requires a stated blocker.**
If a ticket sits in In Review, the last comment must explain what is blocking it (e.g. "Anthropic API spend cap not yet raised", "awaiting human design decision on X"). In Review is **not** a conservative "the code probably works but I'm unsure" state — that state is Done.

**R3. Ralph does not pick up In Review or In Progress.**
`linear_get_next_task` queries only `state.type IN [backlog, unstarted]`. Tickets left in In Review or In Progress become invisible to Ralph and pile up silently.

**R4. Backlog vs Todo is a signal for humans, not Ralph.**
Ralph treats them identically (same priority-sorted queue). Use Backlog for "triaged but not yet ready"; use Todo for "spec-ready, pick this next". Tickets returning from In Review after a blocker clears go back to Todo, not Backlog.

**R5. Claude never moves tickets to Backlog, Canceled, or Duplicate.**
Those are triage decisions humans make. If Claude thinks a ticket should be canceled or duplicates another, it posts a comment recommending it and leaves the state alone.

## Transition table — what Claude does

| From | To | Trigger |
|------|-----|---------|
| Backlog / Todo | In Progress | Loop pickup |
| In Progress | Done | Commits on `main`, AC substantively met (R1) |
| In Progress | In Review | External blocker discovered (with comment stating blocker, R2) |

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
