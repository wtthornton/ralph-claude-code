# Story TELEMETRY-HARVESTER: Closed-Loop Telemetry Analyzer

**Epic:** [Observability](epic-observability.md)
**Priority:** Medium
**Status:** Design — approved (command surface + v1 rules signed off); implementation pending follow-up
**Effort:** Medium
**Component:** `lib/telemetry_analyze.sh` (new), `ralph_loop.sh` (CLI dispatch), `tests/unit/test_telemetry_analyze.bats` (new)

> **This is a design doc, not an implementation.** Per the long-term-recommendations
> review, the harvester is "design before build." Nothing ships until the command
> surface, file set, rule layer, and output format below are signed off.

---

## Problem

The harness already writes rich per-loop telemetry, but every file is either
(a) consumed by exactly one internal control path and never surfaced to a human,
or (b) summarized only at the coarse `ralph --stats` level. An operator who wants
to answer "is the adaptive coordinator timeout healthy?", "why is my cache hit
rate low?", or "how often is the router escalating to Opus?" must hand-write `jq`
against undocumented schemas. There is no closed loop from telemetry → finding →
action.

Concretely, these signals exist but have **no human-facing reader**:

| File | Written by | Currently read by |
|------|-----------|-------------------|
| `.ralph/.coordinator_timings.jsonl` | `ralph_record_coordinator_timing` (ralph_loop.sh:4607) | only `ralph_compute_coordinator_timeout` |
| `.ralph/.coordinator_phase_timings.jsonl` | `ralph_record_coordinator_phase_timing` (ralph_loop.sh:4638) | **nothing** |
| `.ralph/.model_routing.jsonl` | `ralph_select_model` (lib/complexity.sh:263) | **nothing** |
| `.ralph/.invocation_latencies` | `ralph_record_latency` (ralph_loop.sh:4480) | only `ralph_compute_adaptive_timeout` |
| `.ralph/status.json` cache fields (TAP-1685) | on-stop.sh hook | only `ralph-monitor` panel (live, not historical) |
| `.ralph/.qa_failures.json` | `qa_failures_increment` (lib/qa_failures.sh:35) | only `ralph_select_model` |

`ralph --stats` (lib/metrics.sh) already covers run counts, success rate, CB trips,
work-type breakdown, brain connectivity, and skills lifecycle from
`.ralph/metrics/*.jsonl`. **The harvester must not duplicate that** — it reads the
*control-path* telemetry above and turns it into findings.

## Solution

A read-only analyzer that joins the control-path telemetry, applies a small rule
layer, and prints prioritized findings (`OK` / `INFO` / `WARN`), with an optional
`--json` for piping into dashboards. Read-only: it never writes to `.ralph/`.

### Decision 1 — Command surface: **`ralph --analyze`** (APPROVED)

Three options were considered; **`ralph --analyze` was selected at sign-off.**

1. **`ralph-doctor analyze` subcommand.** `ralph-doctor` is a self-contained
   heredoc in `install.sh:539` with **zero argument parsing** — it runs a fixed
   dependency/health sequence and exits. Adding a subcommand means bolting an
   arg parser onto a script that has none, and re-implementing `jq` aggregation
   that already lives in `lib/metrics.sh` (a *different* file). It also conflates
   "are my deps installed / hooks in sync" (doctor's job) with "what is my
   telemetry telling me" (a different question). **Rejected.**
2. **New `ralph-analyze` binary.** Another entry in `~/.local/bin/`, another
   install/uninstall/`valid_commands` registration, another upgrade surface.
   Disproportionate for one analysis mode. **Rejected.**
3. **`ralph --analyze` flag on the main CLI (recommended).** The `ralph_loop.sh`
   dispatcher already hosts every sibling read-only mode — `--stats`,
   `--stats-json`, `--cost-dashboard`, `--circuit-status`, `--mcp-status` — each
   backed by a `lib/*.sh` function. `--analyze` slots in next to them with one
   `case` branch calling a new `lib/telemetry_analyze.sh::ralph_telemetry_analyze`.
   `--analyze --json` mirrors the existing `--stats` / `--stats-json` pairing.
   Zero new install surface; consistent with how operators already reach
   observability. **Selected.**

> Decided at sign-off: `ralph --analyze`. The `ralph-doctor analyze` verb from the
> original brief was considered for discoverability but rejected — doctor has no
> arg parser and answers a different question (deps/hooks health, not telemetry).
> If discoverability becomes a concern later, a thin `ralph-doctor` →
> `exec ralph --analyze "$@"` shim is a non-breaking follow-up.

### Decision 2 — Files read (read-only, all under `.ralph/`)

`.coordinator_timings.jsonl`, `.coordinator_phase_timings.jsonl`,
`.model_routing.jsonl`, `.invocation_latencies`, `.qa_failures.json`, and the
TAP-1685 cache fields in `status.json`. Each is optional: a missing file yields a
`[SKIP] <signal>: no data yet` line, never an error (matches doctor's `[SKIP]`
idiom). The cache hit-rate finding also needs the historical cache numbers — for
v1 it reads the *current* `status.json` snapshot only (session-cumulative fields
already aggregate the whole session); a future story can add per-loop history if
the on-stop hook starts appending a cache JSONL.

### Decision 3 — Rule layer (what counts as a finding)

Each rule is a pure function of one or two files plus the relevant env-var
threshold, so it stays in lockstep with the control path that consumes the same
file. v1 rules:

1. **Coordinator timeout health.** Compute p95 of `.coordinator_timings.jsonl`
   (reusing the PR #54 right-censor + ceiling-index method), compare against the
   *current* adaptive value from `ralph_compute_coordinator_timeout`.
   `WARN` if p95 ≥ 0.9 × current budget (timeouts imminent); else `OK` with the headroom.
2. **Main-loop timeout health.** Same, for `.invocation_latencies` vs
   `ralph_compute_adaptive_timeout` (PR #58 method). Surfaces the right-censored
   p95 so a string of exit_code=124 samples is visible.
3. **Cache hit-rate.** `session_cache_read / (session_cache_read +
   session_cache_create + session_input_uncached)` vs `RALPH_CACHE_HIT_RATE_WARN`
   (default 30). `WARN` below threshold, echoing the same prompt-prefix-churn hint
   `ralph-monitor` prints, but historical rather than live.
4. **Model-routing / Opus-escalation cluster.** Count `qa_failure_escalation`
   reasons in `.model_routing.jsonl` over the last N lines; `INFO` with the count
   and the distinct issue IDs from `.qa_failures.json` so a stuck-issue cluster is
   named, not just counted.
5. **Coordinator phase attribution.** From `.coordinator_phase_timings.jsonl`,
   report the share of invocations where `dominant_phase=synthesis` vs
   `brain_recall_invoked`. This is the exact signal OPERATOR-NOTES item #2
   (coordinator→Haiku trial) is gated on — the harvester is how that field data
   gets read.

Rules are data-driven (a bash array of `name|file|threshold-var|fn`) so adding
rule 6+ is one array entry + one function, no dispatcher surgery.

### Decision 4 — Output format

Human by default, `--json` opt-in (mirrors `--stats` / `--stats-json`). Human
output reuses the doctor `[OK]/[WARN]/[SKIP]` prefix vocabulary operators already
read, grouped one block per rule, with a one-line actionable hint on every
non-`OK`. `--json` emits `{"generated_at", "findings":[{rule, severity, value,
threshold, detail, hint}]}` — stable keys for dashboard ingestion. Exit code is
**always 0** (analysis is advisory; it must never gate a script or CI the way a
failing health check would).

## Implementation sketch (post-sign-off)

1. `lib/telemetry_analyze.sh` — `ralph_telemetry_analyze [--json]`; one function
   per rule; shared `_ta_percentile` helper factored to match the existing
   censor/ceiling math (consider extracting the duplicated p95 logic from
   ralph_loop.sh into a shared helper at that point — note for the build, not v1).
2. `ralph_loop.sh` dispatcher — `--analyze)` / `--analyze --json)` branch next to
   `--stats`.
3. `tests/unit/test_telemetry_analyze.bats` — fixture JSONL per file, one case per
   rule covering `OK` / `WARN` / `SKIP-on-missing`, plus a `--json` shape test.
4. Docs: a row in CLAUDE.md's observability section + `ralph --help` line.

## Acceptance

- [ ] Operator signs off on Decision 1 (command surface) and the v1 rule set.
- [ ] `ralph --analyze` reads only the six files above; never writes `.ralph/`.
- [ ] Every rule degrades to `[SKIP]` on a missing/empty file — no crash, exit 0.
- [ ] p95 rules reuse the PR #54/#58 right-censor + ceiling-index method (no drift
      to a naive percentile).
- [ ] `--json` emits the stable-key schema above; `--analyze` and `--analyze
      --json` agree on findings.
- [ ] BATS coverage for OK/WARN/SKIP per rule + `--json` shape; `npm run
      test:unit` green.
- [ ] Does NOT duplicate `ralph --stats` aggregations (run counts, work-type,
      brain, skills).

## Refs

- Telemetry map (writers + schemas): this story's investigation, `ralph_loop.sh`
  `:4480` / `:4607` / `:4638`, `lib/complexity.sh:263`, `lib/qa_failures.sh:35`.
- p95 censoring precedent: PR #54 (coordinator), PR #58 (main loop adaptive).
- Sibling read-only CLI modes: `ralph --stats` / `--cost-dashboard` /
  `--circuit-status` in `ralph_loop.sh` + `lib/metrics.sh`.
- Gates OPERATOR-NOTES item #2 (coordinator→Haiku) field-data collection via rule 5.
