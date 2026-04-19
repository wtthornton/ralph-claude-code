# Example: Routing a cross-module rename

## Loop snapshot

- Task (from `fix_plan.md`):
  `- [ ] Rename RalphStatus.WorkType to RalphStatus.TaskType across sdk/ and tests/ <!-- complexity: LARGE -->`
- Classifier (`lib/complexity.sh`): LARGE
- Touches ~30 files (estimated by `Grep("WorkType", path="sdk/")`).

## Eval (Input / Success / Failure)

- **Input**: `WorkType` enum referenced in 14 `ralph_sdk/*.py` files and
  22 `sdk/tests/test_*.py` files; no references in shell libs.
- **Success**: `cd sdk && .venv/bin/pytest` passes end-to-end; `Grep`
  returns zero hits for `WorkType` in `sdk/`.
- **Failure**: a test fails that was green on `main @ HEAD` — revert
  and ask architect for a dependency-order plan.

## Routing decision

- SMALL chunks across 30 files would blow the main loop's batch cap.
- Search can be parallelized and doesn't need Sonnet — delegate the
  file enumeration to ralph-explorer.
- The rename itself is mechanical but cross-module — Sonnet's main
  loop handles mechanical edits, but because the blast radius is 30
  files, invoke ralph-architect to plan the edit order (shared
  modules first, test modules last) and take its post-review as the
  gate. This is the one place Opus earns its keep on this task.
- After architect, run ralph-tester (required at this blast radius).

## What not to do

- Don't route "find all files containing WorkType" to architect — that's
  Haiku's lane, via explorer.
- Don't skip the architect review on a 30-file rename — if a test path
  uses the enum in a string (`"WorkType"`), mechanical rename will miss
  it and reviewer will catch it.
- Don't batch this with another LARGE task in the same loop. LARGE tasks
  run one at a time; the loop's cost accounting assumes it.

## Why this matters for the loop

Getting the routing right the first time saves 2-3 retries' worth of
token spend. If the loop routed the whole thing to Sonnet, it would
likely finish but miss 1-2 files and burn a follow-up loop. If it
routed everything to Opus, the explorer phase alone would cost ~10x
what it should.
