---
title: "ADR-0002: Hook-based response analysis"
status: accepted
date: 2025-11-04
deciders: Ralph maintainers
tags: [hooks, parsing, loop, state]
audience: [contributor]
diataxis: explanation
last_reviewed: 2026-04-23
---

# ADR-0002: Hook-based response analysis

## Context

Early Ralph parsed Claude's output inline inside `ralph_loop.sh` via `lib/response_analyzer.sh`. The loop read raw JSONL from the CLI's `--output-format json`, extracted the `RALPH_STATUS` block, derived completion indicators, and updated the circuit breaker — all in one monolithic codepath.

Problems that accumulated:

1. **Tight coupling.** The loop, the SDK, the monitor, and downstream tools all wanted to read the same fields. Each had its own slightly-different parser. Bugs multiplied.
2. **JSONL stream complexity.** Claude Code's stream has `type:"assistant"` messages with `.message.usage`, tool-use records, sub-agent results, and the final `type:"result"` line. Handling all the edge cases (JSON-encoded `\n` in RALPH_STATUS, multi-result filtering, unescaping) grew hairy.
3. **Atomicity.** The loop wanted to update `.call_count`, `.exit_signals`, `.circuit_breaker_state`, and `status.json` from a single logical event. Inline parsing made atomic multi-file updates awkward.
4. **Session boundaries.** Per-session cost, token, and MCP-call accumulators needed resetting when the run ID changed. Inline parsing had no natural seam for that.
5. **Text fallback.** When the JSONL stream was incomplete (WSL/9P filesystem truncation, crashed CLI), text-pattern fallback extraction was needed. Inlining both code paths made the loop function huge.

## Decision

Move response analysis into the `Stop` hook (`templates/hooks/on-stop.sh`). The hook is the **single sanitization point** for Claude's output. The loop never reads raw output — it reads only `status.json`.

Contract:

1. Claude Code fires the `Stop` hook after every response.
2. The hook reads the transcript + stream log for that response.
3. The hook extracts `RALPH_STATUS` fields (auto-unescaping embedded `\n`), `usage` blocks, tool calls, sub-agent results, and permission denials.
4. The hook writes a structured `status.json` atomically (`rm -f` + `mv` for WSL/NTFS).
5. The hook updates `.circuit_breaker_state` in-place with the same atomic pattern.
6. The hook emits structured log lines for `ralph-monitor` and the metrics collector.
7. The loop reads only `status.json` on the next iteration.

The removed `lib/response_analyzer.sh` module's logic is split between the hook (extraction + CB update) and `lib/metrics.sh` (session boundaries, cost aggregation).

## Consequences

### Positive

- **Single parser.** Monitor, SDK, Linear backend, and loop all read the same `status.json` schema. A bug fixed in the hook fixes it everywhere.
- **Atomic multi-file updates.** The hook owns the entire "one response → update all state files" transaction.
- **Session-boundary tracking.** A UUID `run_id` written to `.ralph/.ralph_run_id` is compared inside the hook; mismatches reset per-session accumulators.
- **Text fallback isolated.** Inferring `WORK_TYPE: IMPLEMENTATION` when files are modified but the field is UNKNOWN lives in the hook, not the loop.
- **Testability.** The hook has its own test file (`tests/unit/test_hooks_on_stop.bats`), decoupled from the loop.
- **Claude Code native.** We're using the hook mechanism for what it's designed for instead of fighting the CLI.

### Negative

- **Hook drift risk.** `templates/hooks/on-stop.sh` is the source of truth. Projects' `.ralph/hooks/on-stop.sh` must be kept in sync. Fixed by `ralph-doctor` (warns on drift) + `ralph-upgrade-project` (syncs templates). A unit test enforces the repo's own `.ralph/hooks/` stays byte-identical to the template.
- **Corrupt state recovery.** The hook must self-heal a corrupt `.circuit_breaker_state` — crashing the loop on parse failure would be catastrophic. Resolved: the hook reinitializes to `{state:CLOSED,…}` with a WARN (TAP-538).
- **The `grep -c | echo "0"` pitfall.** A subtle bash idiom (`count=$(grep -c PAT || echo "0")` produces `"0\n0"`) corrupted `status.json` at one point. Fixed by piping through `tr -cd '0-9'` before arithmetic. Now documented in [CLAUDE.md](../../CLAUDE.md) so future contributors don't reintroduce it.

### Neutral

- **Harder debugging.** A loop misbehavior that would have been visible inline is now behind a hook process boundary. Mitigation: structured log lines and a standalone `on-stop.sh` test harness.

## Considered alternatives

- **Keep inline analysis.** Rejected — tight coupling was the source of bugs.
- **Parse in the SDK only.** Rejected — would fork behavior between bash CLI mode and SDK mode, breaking [ADR-0005](0005-bash-sdk-duality.md).
- **Use a long-running sidecar process.** Rejected — extra moving part, process lifecycle management, no clear win over hook pattern.

## Related

- [ADR-0001](0001-dual-condition-exit-gate.md) — the exit gate consumes `status.json`, the hook's output
- [ADR-0005](0005-bash-sdk-duality.md) — the SDK reads the same `status.json` schema
- [ARCHITECTURE.md](../ARCHITECTURE.md#hooks) — hook pipeline
- [CLAUDE.md](../../CLAUDE.md#hook-based-response-analysis) — contract invariants
- TAP-538 — hook resilience and drift detection
