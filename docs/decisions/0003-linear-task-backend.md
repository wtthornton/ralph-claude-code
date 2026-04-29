---
title: "ADR-0003: Linear task backend with fail-loud abstention"
status: accepted
date: 2026-01-10
deciders: Ralph maintainers
tags: [linear, task-source, safety, fail-loud]
audience: [contributor, operator]
diataxis: explanation
last_reviewed: 2026-04-23
---

# ADR-0003: Linear task backend with fail-loud abstention

## Context

Ralph originally drove itself from `.ralph/fix_plan.md`. When we started running Ralph against real product backlogs in Linear, a file-based plan became duplicative and stale — the source of truth already lived in Linear, and Ralph forcing operators to maintain a mirror file was friction.

We added `RALPH_TASK_SOURCE=linear`, which replaces `fix_plan.md` reads with Linear GraphQL API calls at five integration points: the exit-condition check, the dry-run status display, `build_loop_context()`, `ralph_continue_as_new()`, and the startup pre-seed of exit signals.

The first naïve implementation had a failure mode that cost us an incident:

- Linear API transient error (timeout, 5xx, network blip)
- `linear_get_open_count` returned `"0"` on stdout (defaulted from empty output)
- Loop interpreted this as "no work left"
- Exit gate tripped `plan_complete`
- Ralph exited cleanly in the middle of an active backlog
- Operator found it hours later

Root cause: silently defaulting to `0` made transient failures indistinguishable from real completion.

## Decision

On any failure path — API timeout, network error, non-200 HTTP, GraphQL errors, parse errors — the Linear backend functions **print nothing to stdout** and **return non-zero**. A single structured error line goes to stderr:

```
linear_api_error: op=<name> reason=<timeout|network|http_NNN|graphql_errors|parse|...>
```

No secrets in the error line. No fallback values.

**All callers must distinguish:**

- `exit non-zero` → **unknown** — do not treat as anything.
- `exit 0 + value on stdout` → real result.

Concretely:

- **Exit-condition check** skips the gate entirely on any failure. A transient outage cannot trip a false `plan_complete`.
- **`build_loop_context`** injects `"Remaining tasks (Linear): unknown (API error — do NOT emit EXIT_SIGNAL)"` into the system prompt so Claude does not emit a stale done signal.
- **Startup pre-seed** marks `linear_open_count: null` with a timestamp, preventing stale counts from influencing the first iteration.

We call this pattern **fail-loud abstention**: the system loudly says "I don't know" instead of defaulting to a value that could be wrong.

### Push-mode (TAP-741)

A follow-up decision: some deployments use OAuth-via-MCP with no `LINEAR_API_KEY` on the harness. For those, `linear_get_open_count` / `linear_get_done_count` fall back to reading `linear_open_count` / `linear_done_count` from `.ralph/status.json`, written by the Stop hook from Claude's `RALPH_STATUS` block.

Push-mode precedence:

```
API key set? → try GraphQL; on failure, abstain (original TAP-536 path)
API key unset? → read from status.json; if stale (> RALPH_LINEAR_COUNTS_MAX_AGE_SECONDS, default 900) or missing, abstain
```

`linear_check_configured` now requires only `RALPH_LINEAR_PROJECT` (API key is optional). Iteration 1 has no hook write yet and abstains (logged INFO, not WARN).

## Consequences

### Positive

- **No false `plan_complete` from transient API errors.** The incident class that motivated the change is closed.
- **OAuth-via-MCP deployments work.** Ralph runs against Linear without a pre-provisioned API key.
- **Push-mode preserves the contract.** "Unknown" still means abstain; it doesn't become "zero."
- **Structured stderr line** makes monitoring/alerting trivial (`grep linear_api_error`).

### Negative

- **More failure modes to document.** Each caller needs explicit handling; the contract "exit non-zero + empty stdout = unknown" must be obeyed everywhere.
- **Longer stalls during Linear outages.** Ralph will retry and loop; operators must notice and intervene. Mitigation: `linear_api_error` lines are visible in `ralph.log` and the monitor.
- **`.ralph/status.json` now carries Linear fields in push-mode.** The schema grew. Not breaking because all readers tolerate missing fields.

### Neutral

- Tests for the Linear backend grew from ~5 cases to ~20+ (all push-mode paths: fresh, stale, missing file, malformed JSON, missing timestamp, non-numeric value, zero count, API-key precedence).

## Considered alternatives

- **Silent default to 0 on failure.** Rejected — the incident that motivated this ADR.
- **Silent default to a sentinel like `-1`.** Rejected — every caller would still need defensive parsing; abstention is cleaner.
- **Retry internally with exponential backoff.** Rejected — hides the failure from operators and delays visibility; better to return non-zero immediately and let the loop's next iteration try again.
- **Cache last successful value and reuse on failure.** Rejected — would return stale data silently, same class of bug.

## Related

- TAP-536 — the fail-loud refactor
- TAP-741 — push-mode fallback for OAuth-via-MCP deployments
- [LINEAR-WORKFLOW.md](../LINEAR-WORKFLOW.md) — state transitions and review rules
- [CLAUDE.md](../../CLAUDE.md) — invariant documentation in the Linear backend section
- [FAILURE.md](../../FAILURE.md) — FM-001 (API rate limit), FM-012 (MCP failure)
