# Epic: Linear-mode task optimizer (LINOPT)

**Epic ID:** TAP-589
**Priority:** High
**Status:** Done
**Affects:** Linear-mode task selection, cache hit rate, per-loop cost
**Components:** `lib/linear_optimizer.sh`, `lib/import_graph.sh`, `templates/hooks/on-stop.sh`, `ralph_loop.sh:build_loop_context()`, `templates/skills-local/ralph-workflow/SKILL.md`

---

## Problem

When `RALPH_TASK_SOURCE=linear`, Ralph picks tasks via `linear_get_next_task()`
(strict Linear-priority order). Two costs result:

1. **Cache thrash.** Consecutive loops jump to unrelated modules whenever the
   highest-priority open issue lives in a different part of the tree. Anthropic
   prompt-cache hit rate drops because Claude has to re-read different files
   each loop. On a 50-loop campaign across `lib/`, `sdk/`, and `tests/`, the
   per-loop cost grows because cache reads vs. cache creates flip every time
   the focus moves.

2. **Premature test-before-impl.** Linear's manual `blocks/blocked-by` field
   captures dependencies <10% of the time. Locality-only scoring would happily
   pick `tests/test_foo.py` before `src/foo.py` is implemented, because both
   live in the same module as the last-completed work.

Pure priority order ignores both. Pure locality ignores the second.

## Goal

A read-only optimizer that:

- Scores open issues by **module-locality overlap** with the last-completed
  file set (Jaccard + parent-dir bonus).
- **Demotes candidates with import-graph dependencies on still-open issue
  files** so we never start tests before their implementation lands.
- Writes the winning issue ID to `.ralph/.linear_next_issue` for
  `build_loop_context()` to consume as a `LOCALITY HINT` in Claude's prompt.
- **Never overrides Linear**: hint is advisory, the prompt remains in charge,
  Claude can ignore the hint if the issue is Done/Cancelled or the suggestion
  looks wrong.

## Architecture

```
on-stop.sh hook (per loop)
   │
   │  walks JSONL session transcript for Edit/Write/MultiEdit/NotebookEdit
   ▼
.ralph/.last_completed_files (one path per line, capped at 100)
   │
   │  consumed by linear_optimizer_run() at next session start
   ▼
linear_optimizer.sh
   │
   │  Phase 1: fetch top-N open issues, extract paths from bodies, score
   │           (Jaccard + 0.3 * shared-dir bonus). Top-3 priority issues
   │           with no body paths get a ralph-explorer fallback (Haiku,
   │           cached at .ralph/.linear_optimizer_cache.json, capped at 3
   │           calls/session).
   │  Phase 2: import-graph dependency demotion. Build FILES_OWNED_BY_OPEN
   │           map from every candidate's path set. Walk each candidate's
   │           predecessors via import_graph_predecessors(). Demote any
   │           candidate that imports a file owned by another open issue.
   │           Pick first clean survivor; fall back to lowest-dep-count.
   ▼
.ralph/.linear_next_issue (issue ID + "# scored: NNNN" comment line)
   │
   │  read by build_loop_context() at next loop entry
   ▼
"LOCALITY HINT: <ID>" injected into --append-system-prompt
   │
   ▼
ralph-workflow skill step 0: honor hint or fall through to step 1
```

## Stories (all shipped)

| Story | Linear ID | Title |
|-------|-----------|-------|
| LINOPT-1 | TAP-590 | Capture last-completed file set in `on-stop.sh` |
| LINOPT-2 | TAP-591 | `lib/linear_optimizer.sh` skeleton + module-locality scoring |
| LINOPT-3 | TAP-592 | Import-graph dependency demotion |
| LINOPT-4 | TAP-593 | Inject `.linear_next_issue` hint into `build_loop_context()` |
| LINOPT-5 | TAP-594 | Telemetry + 5 fail-loud safety rails |
| LINOPT-6 | TAP-595 | Docs + tapps-brain rollout + integration test (this story) |

## Scoring

```
score(candidate, last_completed) = Jaccard(A, B) + 0.3 * shared_dir_bonus
```

- `A` = `.ralph/.last_completed_files` (deduplicated, sorted)
- `B` = file paths extracted from candidate's issue body (regex on common
  extensions; `node_modules/` and `.git/` filtered out)
- `Jaccard(A, B) = |A ∩ B| / |A ∪ B|`, range 0..1
- `shared_dir_bonus = inter / max(|A|, |B|)`, range 0..1

Tiebreaker: lower Linear `priority` field (1=Urgent → 4=Low; 0=None mapped to 99).

## Phase 2: dependency demotion

Read by `_optimizer_select_winner()`:

1. Sort candidates by score DESC, then priority ASC (`sort -g` general numeric
   — not lexicographic; awk's `-0` formatting bites when compared as strings).
2. Build `FILES_OWNED_BY_OPEN` map: every file path mentioned in any
   candidate's issue body becomes a key, the candidate ID becomes the value.
3. For each candidate in score order, walk `import_graph_predecessors(file)`
   for each of the candidate's files. If any predecessor is owned by a
   *different* candidate, count it.
4. First candidate with `dep_count == 0` wins (clean pick).
5. If all candidates have ≥1 dep, fall back to the lowest-dep-count
   candidate (then highest score).

`RALPH_NO_DEP_DEMOTE=true` skips phase 2 and picks by score only.
Missing import graph cache (`.ralph/.import_graph.json`) also skips phase 2
with a `linear_optimizer: import graph cache missing — skipping dep demotion`
INFO log.

## Safety rails (TAP-594)

1. **Stale hint cleanup**: at session start, if `.linear_next_issue` points at
   an issue that's no longer Backlog/Todo/In-Progress, delete the hint.
2. **Fail-loud on Linear API error**: any non-zero exit from `list_issues`
   preserves the existing hint (no destructive overwrite during a transient
   outage). Telemetry records `fallback_reason: "linear_api_error"`.
3. **Project-unset guard**: `RALPH_LINEAR_PROJECT` empty + `RALPH_TASK_SOURCE=linear`
   → ERROR log, `fallback_reason: "project_unset"`, no crash.
4. **Opt-out guard**: `RALPH_NO_LINEAR_OPTIMIZE=true` → INFO log once,
   `fallback_reason: "opt_out"`, zero API calls.
5. **Lock file**: `.ralph/.linear_optimizer.lock` with PID. Stale locks
   (PID not alive) auto-cleaned. Concurrent invocations record
   `fallback_reason: "concurrent_run_skipped"`.

## Telemetry

`.ralph/metrics/linear_optimizer_YYYY-MM.jsonl` — one JSONL record per
session, monthly file rotation. Fields:

```json
{
  "ts": "2026-04-29T00:00:00Z",
  "session_id": "1777487318984RANDOM",
  "candidates_evaluated": 18,
  "explorer_calls": 2,
  "hint_written": "TAP-587",
  "hint_score": 0.7143,
  "hint_dep_clean": true,
  "fallback_reason": null,
  "duration_ms": 1240
}
```

Ad-hoc analysis with `jq`:

```bash
# Hit rate over the last month
jq -s 'group_by(.hint_written != null) | map({with_hint:.[0].hint_written != null,count:length})' \
  .ralph/metrics/linear_optimizer_*.jsonl

# Most-common fallback reasons
jq -s '[.[] | select(.fallback_reason)] | group_by(.fallback_reason) | map({reason:.[0].fallback_reason,count:length})' \
  .ralph/metrics/linear_optimizer_*.jsonl
```

## Configuration

All variables live in `.ralphrc` (see `templates/ralphrc.template` for the
documented defaults):

| Variable | Default | Effect |
|---|---|---|
| `RALPH_NO_LINEAR_OPTIMIZE` | `false` | Disable optimizer entirely (no API calls, no hint) |
| `RALPH_NO_DEP_DEMOTE` | `false` | Skip phase 2 dependency demotion |
| `RALPH_OPTIMIZER_FETCH_LIMIT` | `20` | Max issues fetched per run |
| `RALPH_OPTIMIZER_EXPLORER_MAX` | `3` | Max ralph-explorer (Haiku) calls per session |

Environment variables override `.ralphrc` (precedence: CLI flag > env > rc > defaults).

## Manual rerun

```bash
ralph --optimize-linear
```

Loads `.ralphrc` + secrets, gates on `RALPH_TASK_SOURCE=linear`, runs the
optimizer once, exits.

## Test coverage

`tests/unit/test_linear_optimizer.bats` — 16 unit tests:

- 5 LINOPT-2 tests: Jaccard scoring, priority tiebreaker, empty-fallthrough,
  explorer-budget, explorer-cache.
- 5 LINOPT-3 tests: dependency demotion, Done-issue exclusion, missing-cache
  fallthrough, all-deps fallback, opt-out flag.
- 6 LINOPT-5 tests: API-error preserves hint, stale-hint cleanup, stale-lock
  cleanup, opt-out short-circuit, project-unset, valid JSONL emission.

Plus 8 LINOPT-1 tests in `tests/unit/test_on_stop_hook.bats` covering the
file-set capture in the on-stop hook.

## Out of scope

- **Visualization dashboard.** JSONL + `jq` is enough for ad-hoc analysis;
  build a dashboard separately if A/B telemetry warrants it.
- **OTEL trace integration.** `lib/tracing.sh` exists but adding a span for
  the optimizer is a follow-up.
- **Cross-session moving averages.** Same — JSONL allows reconstruction
  on demand.
- **Persistent coordinator session.** That belongs to the ralph-coordinator
  epic (TAP-912 / TAP-919), not LINOPT.
