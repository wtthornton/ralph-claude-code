# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

---

## [Unreleased]

---

## [2.22.0] — 2026-06-01

Minor release — MCP-disconnect resilience. A fresh `claude` invocation that comes up with all of its MCP servers disconnected at loop start is now retried instead of counted as no-progress, so transient MCP-client flakiness can no longer trip the circuit breaker on an otherwise-healthy campaign. SDK unchanged.

### Added

- **MCP disconnect retry (MCP-DISCONNECT-RETRY).** Intermittently `claude -p` starts a loop with all MCP servers disconnected (transient client flakiness — not a zombie/resource leak); the agent can't `session_start`, read Linear, or run the quality gate, so it emits `STATUS: BLOCKED` with 0 files / 0 tasks. Two complementary mechanisms keep this from tripping the no-progress circuit breaker:
  - **Detection + no-penalize (`on-stop.sh`).** A new structured flag `mcp_disconnect: true` is written into `status.json` when the loop reports a disconnect — recognized via the canonical `RECOMMENDATION: mcp_unreachable` **or** a free-text fallback (`mcp…(disconnect|unreachable|not connected|failed to connect)` / `all mcp servers`), gated on files=0 ∧ tasks=0 ∧ `EXIT_SIGNAL ≠ true` so a productive or clean-exit loop can never trip it. Such a loop bumps `.mcp_blocked_count` **without** incrementing `consecutive_no_progress`. A genuinely-blocked backlog (no mcp/disconnect token) still counts as no-progress.
  - **Retry, don't halt (`ralph_loop.sh`).** The main loop reads `status.json.mcp_disconnect`, drops the possibly-poisoned session, backs off (2s/5s/10s), and re-invokes Claude fresh next iteration (a cold start almost always reconnects). After `RALPH_MCP_RETRY_MAX` consecutive disconnects the harness gives up and halts (`exit_reason=mcp_unreachable_quorum`).
- **`RALPH_MCP_RETRY_MAX` (default 3).** Max consecutive MCP-disconnect loops tolerated before giving up; the loops leading up to the cap are retried and never penalized. Legacy alias `RALPH_MCP_BLOCKED_QUORUM` (the new name takes precedence when both are set).
- **`RALPH_MCP_HEALTH_GATE` (default false).** Optional pre-loop MCP health gate that re-probes the required MCP servers (with the same backoff) before spending a Claude invocation. Off by default because the live `claude mcp list` probe adds per-loop latency; the post-loop retry recovers disconnects without it.

### Tests

- `tests/unit/test_mcp_health_signal.bats` — 7 new cases covering the free-text disconnect-exempt path, the genuine-no-progress path, `RALPH_MCP_RETRY_MAX` threshold precedence, and the clean-exit guard.
- `tests/unit/test_mcp_disconnect_retry.bats` — new file covering the loop-side helpers (`ralph_loop_was_mcp_disconnect`, `ralph_mcp_retry_backoff`, `ralph_mcp_health_gate`).

---

## [2.21.5] — 2026-06-01

Patch release — harness fix. The coordinator could delegate HIGH-risk tasks to `ralph-architect`, but the harness never acted on it. SDK unchanged.

### Fixed

- **Brief `delegate_to` is now honored — `ralph-architect` actually runs for HIGH-risk tasks.** The coordinator writes `delegate_to: "ralph-architect"` into `.ralph/brief.json` and `lib/brief.sh` validated it, but nothing mapped the field onto the launched agent — every loop relaunched `--agent ralph`. A delegated brief then produced a BLOCK→re-select→BLOCK spin that burned no-progress loops toward the circuit breaker, and the architect agent never ran. `build_claude_command` now reads `.delegate_to` and overrides the `--agent` flag via a loop-local var (never mutating `RALPH_AGENT_NAME`, so a stale brief can't pin the architect across iterations), falling back to `ralph` with a WARN when the delegated agent file is absent. Composes with the TAP-1686 plan-mode override (both keyed off the same HIGH-risk brief). Implemented in `build_claude_command` rather than `build_loop_context` because the latter runs in a command-substitution subshell, where an `export` is lost before `--agent` is assembled.

---

## [2.21.4] — 2026-06-01

Patch release — Ralph Continuous Coding backlog sweep. The substantive change ships in the `PROMPT.md` template; the rest is test coverage and repo hygiene. SDK unchanged.

### Added

- **`templates/PROMPT.md` editing-discipline rules (TAP-2333, upstreams TAP-2332).** Promoted two field-tested friction patterns from a per-project AgentForge edit into the upstream template's managed (`RALPH:START`/`RALPH:END`) section, so every Ralph-managed project inherits them on the next `ralph-upgrade-project`:
  - **Read before first Edit** — issue a `Read` before the first Edit/Write to a file in a loop (avoids the recurring `File has not been read yet` Edit rejection).
  - **Shared/busy-directory guard** — run `git status` before editing a shared directory; if unstaged changes don't trace to the current ticket, emit `STATUS: BLOCKED` and pivot. Busy-dir list is operator-configurable via the new `.ralphrc` knob `RALPH_BUSY_DIRS` (space/colon-separated; default empty — agent-honored, no harness change).
  - Pattern 1 (`python3 -c` → `/tmp/snippet.py` / `python-introspection`) was already present; a `tests/unit/test_prompt_template.bats` regression guard now asserts all three patterns stay present.

### Fixed

- **TAP-2345 acceptance gap closed.** The Bash/Edit `.claude/` policy unification merged earlier (PR #33) shipped without test coverage; added 8 cases in `tests/unit/test_validate_command.bats` asserting `.claude/rules|skills|commands` are writable via Bash while `.claude/agents|hooks|settings.json` stay blocked.

### Chore

- **`.gitignore`** now ignores `.tapps-mcp-cache/` (tapps-mcp doc/lookup + linear-snapshot cache) and `.ralph/.consecutive_questions` (USYNC-1 question-loop counter) — ephemeral, host-specific runtime artifacts that were surfacing as untracked noise.

> Backlog note: the other five open issues in this sweep (TAP-2471, TAP-2473, TAP-2485, TAP-2343, TAP-2341) were verified already-implemented on `main` (from PRs #49/#32 and the R0 enforcement path) and closed Done with file:line evidence — no code change required.

---

## [2.21.3] — 2026-05-31

Patch release — harness correctness/security hardening: sweep of 15 correctness/security bugs across the loop, hooks, and libs (#66). See the PR for the per-bug detail.

---

## [2.21.2] — 2026-05-31

Patch release — documentation/config follow-up from a full verification pass on the `ralph-workflow` skill. Every harness-contract claim the skill makes (RALPH_STATUS schema, `no_status_block_3x` halt, TAP-1899 productivity guard, dual-condition EXIT_SIGNAL gate, `exec_aggregate_qa_results`, `pending_merges_add` caps, `validate-command.sh` blocks, `build_loop_context` injection lines, `NEXT_INTENDED_ISSUE`/`brief-next.json` lookahead, brief paths) was confirmed against the code and is accurate. CLI/docs-only — no behavior change; SDK remains at 2.2.0.

### Fixed

- **`RALPH_NO_DESLOP` knob was referenced only inside the `ralph-workflow` skill** — undocumented in [templates/ralphrc.template](templates/ralphrc.template) and [CLAUDE.md](CLAUDE.md), so operators had no way to discover it. The flag is honorable by the agent (`.ralphrc` vars export to the Claude CLI subprocess via `set -a` and the skill checks it at epic-boundary step 7.5), but the operator-facing surface was missing. Added a documented `RALPH_NO_DESLOP=false` block to `ralphrc.template` and the config list in `CLAUDE.md`. No skill body change — the skill was already contract-correct, so no `ralph-upgrade-project` skill propagation is required; the `ralphrc.template` default backfills as a Tier-2 merge on the next project upgrade.

---

## [2.21.1] — 2026-05-31

Patch release — three autonomous-campaign friction fixes surfaced running Ralph 2.21.0 against a Linear backlog (AgentForge). All fixed at the source templates so they ship via `install.sh`; the runtime `.ralph/hooks/` copies stay byte-identical (parity-guard tests). CLI-only — the Python SDK remains at 2.2.0. **Operators running Ralph against managed repos should `ralph-upgrade` then `ralph-upgrade-project` to pick up the hook + prompt changes.**

### Fixed

- **TAP-2599: `validate-command.sh` no longer blocks Ralph deleting its own transient locality hint** ([templates/hooks/validate-command.sh](templates/hooks/validate-command.sh#L222)). The ralph-workflow skill (step 0) tells the agent to `rm -f .ralph/.linear_next_issue` after honoring a `LOCALITY HINT`, but the blanket `.ralph/*` protection cancelled that tool call every task-selection loop — a noisy `BLOCKED: write to protected path` + a burned tool call per loop. A carve-out as the first arm of `_is_protected_path()` allows `rm`/`mv`/`cp` of `.linear_next*` (the ephemeral hint, rewritten every session) while durable state (`status.json`, `fix_plan.md`, `.circuit_breaker_state`, `.harness_halt_reason`) stays protected. Synced into `.ralph/hooks/`; 6 new BATS cases in [tests/unit/test_validate_command.bats](tests/unit/test_validate_command.bats).
- **TAP-2599: squash-merge resume guidance now deletes the remote branch** ([ralph_loop.sh](ralph_loop.sh)). The `build_loop_context` RESUME guidance suggested bare `gh pr merge --squash --auto`, leaving `origin/<feature-branch>` behind after the auto-merge fired (observed: PR #406 merged but `origin/tap-2599-…` remained). Both occurrences now use `--squash --auto --delete-branch`, matching the ralph-workflow skill and the async `pending_merges_poll` helper (which already used `--delete-branch`). Static guard in [tests/unit/test_merge_delete_branch.bats](tests/unit/test_merge_delete_branch.bats).
- **TAP-2636: benign no-status-block loops no longer halt (or stick) a successful campaign** ([templates/hooks/on-stop.sh](templates/hooks/on-stop.sh), [ralph_loop.sh](ralph_loop.sh)). A loop that completed a story by squash-merging a PR modifies zero working-tree files and may emit no `RALPH_STATUS` footer — but `HEAD` moved. (a) The on-stop productivity guard now treats a commit landing this loop (current `HEAD` vs `.loop_start_sha`) as productive and resets the no-status-block counter, alongside the existing files/tasks signals. (b) At startup, a `no_status_block_Nx` halt sentinel is auto-cleared (instead of refusing to run) when the prior loop's `status.json` shows success (`tasks_completed`/`files_modified` ≥ 1 or `exit_signal: true`) via the new `ralph_no_status_halt_is_benign` helper. Genuine zero-progress loops keep the hard halt. Synced into `.ralph/hooks/`; new BATS cases in [tests/unit/test_on_stop_halt_productivity.bats](tests/unit/test_on_stop_halt_productivity.bats) and [tests/unit/test_no_status_halt_clear.bats](tests/unit/test_no_status_halt_clear.bats).

---

## [2.21.0] — 2026-05-30

Feature + reliability bundle accumulated on `main` since the 2.20.1 stamp (PRs #54–#62). Adds the `ralph --analyze` telemetry analyzer and the `agent-models.json` single-source-of-truth, routes Opus-tier agents to Opus 4.8, and lands two harness-reliability fixes surfaced by a live campaign. CLI-only release — the Python SDK remains at 2.2.0 (its unreleased Opus 4.8 pricing change ships under the CLI but is not separately version-stamped this cycle).

### Added

- **`ralph --analyze` — closed-loop telemetry analyzer ([lib/telemetry_analyze.sh](lib/telemetry_analyze.sh), PR #62).** Read-only, always-exit-0 analysis over the harness's *control-path* telemetry (the JSONL/state files each consumed by one internal decision and otherwise never surfaced). Five rules — coordinator/main-loop timeout health (censored-p95 vs the live adaptive budget), prompt-cache hit-rate, Opus QA-failure escalation cluster, and coordinator phase attribution. Human `[OK]/[WARN]/[SKIP]/[INFO]` by default; `--analyze --json` emits a stable-key schema for dashboards. Does not duplicate `ralph --stats`. The phase-attribution rule is the field signal the coordinator→Haiku trial is gated on. Design: [docs/specs/story-telemetry-harvester.md](docs/specs/story-telemetry-harvester.md).
- **`agent-models.json` single source of truth + operator-edits playbook (PR #59).** The repo-root [agent-models.json](agent-models.json) is now the canonical `{agent-name → model-id}` map; `scripts/apply-agent-models.sh` propagates it to `.claude/agents/*.md`, and [tests/unit/test_agent_models_lockstep.bats](tests/unit/test_agent_models_lockstep.bats) fails CI in either direction. A model bump is now one edit + one script run instead of a coordinated change across five files. Playbook: [docs/OPERATOR-EDITS.md](docs/OPERATOR-EDITS.md).
- **Opus 4.8 pricing in cost routing (PR #55).** Adds Opus 4.8 to the per-model pricing table so `--cost-dashboard` and budget alerts price Opus-4.8 routed work correctly.

### Changed

- **Opus-tier agents routed to Opus 4.8 (PRs #55, #56).** `ralph-architect`, `ralph-reviewer`, and `ralph-tester` now target Opus 4.8 for maximum reasoning depth on the quality lanes; the main loop stays on Sonnet.

### Fixed

- **MCP resume catalog recovery, explicit timeout status, and coordinator adaptive timeout (PR #54).** Four live-campaign harness bugs: (1) STDIO MCP tool catalog lost after `claude --resume` is now detected and retried once with a fresh session; (2) MCP health reflects catalog truth, not just probe liveness; (3) a SIGTERM execution timeout now writes an explicit `status:"timeout"` instead of falling back to the previous loop's stale `status.json`; (4) the coordinator adaptive timeout no longer under-computes (right-censors timed-out samples, raises floor/fallback to cover the observed 150–250s band). Upstream root causes for (1) and (3) are filed as [anthropics/claude-code#64016](https://github.com/anthropics/claude-code/issues/64016) and [#64017](https://github.com/anthropics/claude-code/issues/64017).
- **Main-loop adaptive timeout right-censoring + ceiling p95 (PR #58).** Mirrors the coordinator-timeout fix into `ralph_compute_adaptive_timeout`: timed-out samples (`exit_code` 124) are inflated 1.5× before the percentile, and the p95 index uses ceiling rounding so small sample sets bias to the slow tail rather than the median. Legacy plain-int latency logs auto-migrate to JSONL. Covered by [tests/unit/test_adaptive_timeout.bats](tests/unit/test_adaptive_timeout.bats).

### Removed

- **COSTROUTE-3 prompt-cache scaffolding ([lib/complexity.sh](lib/complexity.sh), [tests/unit/test_cost_optimization.bats](tests/unit/test_cost_optimization.bats), PR #57).** `RALPH_PROMPT_CACHE_ENABLED`, `ralph_build_cacheable_prompt`, and `ralph_get_stable_prefix_hash` had zero production callers — the spec shipped marked Done in [epic-cost-aware-routing.md:39](docs/specs/epic-cost-aware-routing.md#L39) but the wiring was never landed, and the function targeted file mode (`PROMPT.md` / `AGENT.md` / `fix_plan.md`) which no real user runs (`RALPH_TASK_SOURCE=linear` is the active backend). Removed to eliminate the trust hazard — operators flipping the flag would observe no behavior change. The COSTROUTE-3 story is now marked **Reverted**; COSTROUTE-4 cost-dashboard tests in the same file are untouched. Any future prompt-cache-structure work should be re-scoped against the linear-mode runtime path (`build_claude_command` → user-message concatenation) and gated on TAP-1685 cache-hit field data showing a sustained regression.

---

## [2.17.1] — 2026-05-23

Patch release — cross-project harness reliability fixes from the 2026-05-22/23 sibling-repo audit. Root cause for all five fixes was the same architectural pattern: the harness wrote state under `.ralph/` but the agent surface (protect-hook allowlist + validate-command rm-block) couldn't reach it to clear or recover. **Operators running Ralph against `tapps-mcp` / `AgentForge` / `NLTlabsPE` should `ralph-upgrade` then `ralph-upgrade-project` in each sibling repo** to pick up these fixes.

### Fixed

- **TAP-2471: `protect-ralph-files.sh` allows coordinator-owned `.ralph/` paths** ([templates/hooks/protect-ralph-files.sh:38-60](templates/hooks/protect-ralph-files.sh#L38-L60)). Adds `brief.json`, `.linear_next_issue`, `.last_completed_files`, and `.brief_cache/*` to the Edit-side allowlist. Pre-TAP-2471 every coordinator Write tool call to `.ralph/brief.json` exited 2 — silently masked by the TAP-1875 retry-once + WARN-and-clear path. Evidence: `tapps-mcp/.ralph/.coordinator-brief.err` captured Claude's own thinking — "caught in a circular dependency." This is also the root cause of the MODE=brief 126s timeouts observed in all 3 sibling projects.
- **TAP-2472: coordinator MODE=brief narrows `list_issues`** ([.claude/agents/ralph-coordinator.md:104-129](.claude/agents/ralph-coordinator.md#L104-L129)). Replaces `limit=15` + no state filter + client-side discard with `state="started"` first (`limit=50`), falling back to `state="unstarted"` if the started set returns <3 candidates. Defense-in-depth against the 126s timeout even after TAP-2471 fixes the root cause. Shipped as `docs/specs/tap-2472-coordinator-narrowing.patch` in PR #49 because the agent file is blocked from agent edits (TAP-623); applied as a separate operator commit in PR #50.
- **TAP-2473: `ralph_push_pending_commits` fetches + rebases on rejected push** ([ralph_loop.sh:4490-4624](ralph_loop.sh#L4490-L4624)). When `git push` is rejected with "fetch first" / "cannot lock ref", the helper now runs `git fetch origin` + `git rebase --autostash origin/<branch>` + retry once. Rebase conflict → `git rebase --abort` + log to `.push-failure.err` as today. **Hard rule: no `--force` / `--force-with-lease`** — the R0 push-to-main block in `validate-command.sh` stays effective. Cross-project audit 2026-05-22/23 found 7 stranded commits from rejected pushes (tapps-mcp 3, NLTlabsPE 2, AgentForge 2); this prevents future stranding (does not recover the existing 7 — operator must `git pull --rebase && git push` once in each sibling).
- **TAP-2485: auto-clear `.push-failure.err` + `.coordinator-{brief,debrief,consult}.err` on writer success** ([ralph_loop.sh:_ralph_push_clear_failure_marker, _coordinator_record_outcome](ralph_loop.sh)). Stale failure markers under `.ralph/` were stranded forever — the agent can't `rm` them (`validate-command.sh` blanket-blocks rm against `.ralph/*`, intentional per TAP-2344) and the protect-hook allowlist stays narrow on purpose. Now the writer clears its own marker on next success. Failure semantics unchanged; mode-isolated (a `brief` success only clears `.coordinator-brief.err`). Surfaces from a well-evidenced ticket filed by a sibling-project Claude session during post-TAP-2470 cleanup.

### Changed

- **CLAUDE.md "Linear cache-locality optimizer (LINOPT epic)"** updated to document the TAP-2472 state-narrowed call shape ([CLAUDE.md:194](CLAUDE.md#L194)).

### Test coverage added

- 13 new BATS cases in `tests/unit/test_protect_ralph_files.bats` (6 new-allowed paths + 6 still-blocked regression guards + 1 patch-mechanism check).
- 5 new BATS cases in `tests/unit/test_coordinator_agent.bats` (self-detect pre-patch state via the obsolete `limit=15` sentinel, skip-then-pass after operator apply).
- 5 new BATS cases in `tests/unit/test_push_pending_commits.bats` (clean rebase + retry succeeds, rebase conflict → abort + .push-failure.err, force-push regression guard, DRY_RUN short-circuit, RALPH_PUSH_EVERY_LOOP=false short-circuit).
- 4 new BATS cases in `tests/unit/test_push_pending_commits.bats` for TAP-2485 (clear on happy path, clear on rebase-recovery, preserve on failure, no allowlist widening regression guard).
- 9 new BATS cases in `tests/unit/test_coordinator_record_outcome.bats` for `_coordinator_record_outcome` (failure write + success clear + mode isolation + per-mode marker names + no allowlist widening).

Total: 2000+ unit tests pass (1986 baseline + 36 new TAP-2470-bundle cases).

### Notes for operators

- After upgrading, the **post-merge sibling-cleanup prompt is shorter** — no more `rm -f .ralph/...` instructions (TAP-2485 makes them obsolete + invalid).
- The TAP-1875 retry-once + WARN-and-clear "regression detector" path may be dead code after this release. Watch sibling `.coordinator-brief.err` files for 24h post-upgrade; if they stay empty, file a cleanup ticket.
- **Free-rider:** `tests/unit/test_agent_contract_tap646.bats` regex was updated to recognize `mcp__plugin_linear_linear__list_issues` (pre-existing test failure from PR #48 that would have blocked CI).

---

## [2.17.0] — 2026-05-22

Minor release adding `.ralphrc.local` — the operator-only override surface that closes the "R0 escape hatch is agent-unreachable" gap surfaced by the tapps-mcp upgrade review (every Ralph-managed repo with `protect-ralph-files.sh` could neither bypass the R0 push-to-main block from inside the harness nor land the bypass without an out-of-band shell ritual).

### Added

- **`.ralphrc.local` — operator-only override surface** ([CLAUDE.md](CLAUDE.md#L252)).
  - `load_ralphrc()` in [ralph_loop.sh:341-353](ralph_loop.sh#L341-L353) sources `.ralphrc.local` immediately after `.ralphrc`, wrapped in `set -a` / `set +a` so values auto-export to the Claude CLI invocation and downstream hook subprocesses. Precedence: CLI > env > `.ralphrc.local` > `.ralphrc` > script default.
  - [templates/hooks/protect-ralph-files.sh:64-72](templates/hooks/protect-ralph-files.sh#L64-L72) blocks agent edits to `.ralphrc.local` with the same anchoring as `.ralphrc` (project root + bare path; sibling-repo files in cross-repo hotfix workflows are not caught).
  - Added to `templates/.gitignore` and the repo's own `.gitignore` so the override file stays out of commits.
  - **Caveat documented:** `load_ralphrc()` returns early when `.ralphrc` is absent, so `.ralphrc.local` is only sourced when a base `.ralphrc` exists. Operators wanting overrides-only must `touch .ralphrc` first.
  - **Primary motivator:** persist `RALPH_ALLOW_PUSH_MAIN=1` once for direct-to-main workflows instead of re-exporting on every harness restart. The agent can never erase or rewrite the file from inside Claude Code, so the R0 push-to-main block in `validate-command.sh` cannot be self-unlocked.

### Tests

- 3 new cases in [tests/unit/test_protect_ralph_files.bats:102-128](tests/unit/test_protect_ralph_files.bats#L102-L128): project blocked, relative blocked, sibling-repo allowed.
- 5 new cases in [tests/unit/test_cli_rc_precedence.bats:137-216](tests/unit/test_cli_rc_precedence.bats#L137-L216): override beats `.ralphrc`, env still beats `.ralphrc.local`, absent file is a no-op, no-base-`.ralphrc` early-return is asserted (not a silent regression), and auto-export to subprocesses is verified by checking the exported environment after `load_ralphrc`.

---

## [2.16.1] — 2026-05-22

Patch release bundling three post-2.16.0 changes from downstream feedback (tapps-mcp upgrade review + AgentForge campaign). No harness contract changes; no new config knobs.

### Fixed

- **TAP-2345 follow-up (PR [#42](https://github.com/wtthornton/ralph-claude-code/pull/42))** — coordinator's T4 consume step (`brief-next.json` → `brief.json`) now runs **before** the `claude-cmd` guard fires. Previously the order swallowed the prewarmed brief on cold-start sessions and forced a synchronous coordinator spawn on the next loop, defeating the T4 win.
- **TAP-2344 (PR [#43](https://github.com/wtthornton/ralph-claude-code/pull/43))** — `HOOKS-5` eval now asserts that `.ralphrc` creation through `Write` is blocked by `protect-ralph-files.sh`. The assertion shape was off after the TAP-2345 Edit/Bash policy unification; test was passing for the wrong reason.

### Changed

- **`merge_ralphrc` upgrader log granularity.** [`ralph_upgrade_project.sh`](ralph_upgrade_project.sh#L664) now logs one line per appended section instead of joining section names with spaces. Section names containing parentheticals (e.g. `BRANCH HYGIENE (TAP-1878 / TAP-1880)`) made the old summary line ambiguous — a downstream operator running `ralph-upgrade-project` reported reading the trailing `PERIODIC PUSH (AgentForge feedback #1)` as two separate headings.
- **`ralph-workflow` SKILL.md bumped 1.1.0 → 1.2.0** with a new `Revision history` section. The 1.1.0 stamp had been stretched across R0 ([#27](https://github.com/wtthornton/ralph-claude-code/pull/27), [#29](https://github.com/wtthornton/ralph-claude-code/pull/29)), F1+F2+F3 ([#32](https://github.com/wtthornton/ralph-claude-code/pull/32)), T3 sub-agent fan-out ([#37](https://github.com/wtthornton/ralph-claude-code/pull/37)), T4 brief lookahead ([#39](https://github.com/wtthornton/ralph-claude-code/pull/39)), T5 async PR merge ([#41](https://github.com/wtthornton/ralph-claude-code/pull/41)), the `linear-read` mandate ([#36](https://github.com/wtthornton/ralph-claude-code/pull/36)), and TAP-2256 (python-introspection). Downstream projects can now pin a known set of rules. The in-repo `.claude/skills/ralph-workflow/` and `.cursor/skills/ralph-workflow/` mirrors are also synced (they had been drifted, missing the [#36](https://github.com/wtthornton/ralph-claude-code/pull/36) linear-read text).

### Documentation

- **`RALPH_PUSH_EVERY_LOOP` × project-side pre-push hook interaction** documented in [CLAUDE.md](CLAUDE.md). `git push` is invoked *without* `--no-verify`, so any `.githooks/pre-push` gate runs every loop — failure mode is a silent backlog of locally-committed-but-un-pushable commits, mitigation is `tail -F .ralph/.push-failure.err` or `RALPH_PUSH_EVERY_LOOP=false`. Originated from a tapps-mcp upgrade review where the project's pre-push runs the full test suite + `bump-versions.py`.
- **`.ralph/.upgrade-backups/` rollback procedure** documented in [docs/OPERATIONS.md](docs/OPERATIONS.md) under *Upgrading a managed project* — per-file `cp -a` restore is safe, the upgrader keeps no state ledger beyond the backup files themselves, and the directory rotates at `MAX_UPGRADE_BACKUPS=5` runs.

---

## [2.16.0] — 2026-05-22

### Async PR-merge queue (T5, opt-in)

- **T5 — async PR-merge queue behind `RALPH_ASYNC_MERGE=true` (default OFF).** Decouples the agent's "ticket done" decision from the GitHub merge actually landing. Today's flow waits ~2–4 min per PR for CI green; with this queue the agent opens the PR, records the pending merge, and immediately picks the next ticket. The harness polls pending PRs at loop boundaries and merges any that are green; CI failures surface to the next loop's prompt.

  New module: [`lib/pending_merges.sh`](lib/pending_merges.sh) with `pending_merges_{enabled,init,add,count,poll,get_merged,surface_failed,drop,force_drain}`. State file: `.ralph/pending-merges.json` (schema v1). Wired into `main()` BEFORE the coordinator each loop. `build_loop_context` surfaces `PENDING LINEAR CLEANUP: ...` (PRs merged but Linear still In Progress) and `PENDING-MERGE FAILURES: ...` lines for the agent to act on. Envelope: `RALPH_ASYNC_MERGE_MAX_PENDING` (default 5), `RALPH_ASYNC_MERGE_DRAIN_RETRIES` (default 6, sleeps `RALPH_ASYNC_MERGE_DRAIN_SLEEP_SECONDS` between, default 30). When the queue hits cap, `pending_merges_add` returns 2 and the caller should `pending_merges_force_drain` synchronously. The semver bump to 2.16.0 reflects the workflow change even though the default is off.

  Agent contract (ralph-workflow skill, R1 async-merge mode section): in async mode, **open PR → `pending_merges_add` → stop**, do NOT call `gh pr merge` yourself. Move Linear to Done on the NEXT loop after seeing the PENDING LINEAR CLEANUP surface.

  Soak plan: ship with `RALPH_ASYNC_MERGE=false` (default) through 2.16.0. Flip default to `true` in 2.16.1 after one campaign with operators voluntarily setting the flag shows zero stranded PRs.

  12 BATS cases in `tests/unit/test_pending_merges.bats`. Background and design context in [ADR-0007](docs/decisions/0007-async-pr-merge-via-pending-queue-vs-github-merge-queue.md) (why custom queue over GitHub Merge Queue).

### Design ADRs

- **[ADR-0007](docs/decisions/0007-async-pr-merge-via-pending-queue-vs-github-merge-queue.md) — async PR merge via custom pending queue, not GitHub Merge Queue.** Decision rationale for T5. Three decisive factors: Linear coupling (the harness owns the Done transition directly, no webhook bridge), zero-setup deployability across N managed projects (vs per-repo Merge Queue config), and the March 2026 GitHub `--auto` 422 change is a small handler not a structural problem.

- **[ADR-0008](docs/decisions/0008-parallel-tickets-via-teammates-not-coordinator-fanout.md) — parallel ticket execution stays under the teammate flow, not a new coordinator fan-out.** Decision against the post-AgentForge-review proposal of a `parallel_safe` field on `brief.json` + main-loop fan-out. The existing teammate concept (`.claude/agents/ralph.md:260-299`, `.ralph/hooks/on-teammate-idle.sh`) already handles parallel ticket execution with file-ownership-scope isolation. Adding a second path would create two failure surfaces and double the cognitive load. Future enhancement: surface `affected_modules` to the teammate-assignment hint instead.

---

## [2.15.9] — 2026-05-22

### Coordinator brief lookahead (T4)

- **T4 (PR [#39](https://github.com/wtthornton/ralph-claude-code/pull/39)) — brief lookahead via `NEXT_INTENDED_ISSUE` + `.ralph/brief-next.json`.** Adds a pre-warm path for the coordinator's brief so a multi-loop campaign can skip the cold-start coordinator spawn (~5–15 s) on the loop after Claude tells the harness what ticket it intends to pick next.

  - Claude emits optional `NEXT_INTENDED_ISSUE: TAP-NNNN` in `RALPH_STATUS`
  - `on-stop.sh` extracts it (shape-validated against `^[A-Z][A-Z0-9]*-[0-9]+$`) to `.ralph/.next_intended_issue`
  - Main loop forks `ralph_prewarm_next_brief` in background after `cb_record_success`
  - Background coordinator writes `.ralph/brief-next.json` (separate from `brief.json`)
  - Next loop's `ralph_spawn_coordinator` consumes it on `task_id` match and skips its own spawn; mismatch or malformed brief → silently dropped, fall through to cache → spawn

  Guards: `RALPH_PREWARM_NEXT_BRIEF=false` (opt-out), `RALPH_BRIEF_NEXT_MAX_AGE_SECONDS` (default 1800), `RALPH_PREWARM_TIMEOUT_SECONDS` (default 90, caps the background spawn), `brief_validate` gate on output. Same-ticket prewarm is skipped (the existing `brief_cache` will hit anyway).

  9 BATS cases under `tests/unit/test_brief_lookahead.bats`. Documented in the ralph-workflow skill's status-block section.

---

## [2.15.8] — 2026-05-22

### Throughput improvements (post-AgentForge campaign feedback)

Three coordinated changes targeting the 9.2 min avg per-PR ship time observed in the 2026-05-22 AgentForge campaign (41 PRs / 16 productive loops / 6.26 hr). Goal: route trivial PRs to Haiku, enforce the linear-read snapshot dance consistently, and curb sub-agent over-spawn. Soak campaign before further changes in 2.15.9.

- **T1 (PR [#35](https://github.com/wtthornton/ralph-claude-code/pull/35)) — `RALPH_CURRENT_TASK_TEXT` wired from `brief.json` in OAuth-via-MCP Linear mode.** Every routing decision in the 2026-05-22 campaign logged `task_type:"none" / reason:"no_task_fallback"` (31/31) because `linear_get_in_progress_task` and `linear_get_next_task` early-return empty without `LINEAR_API_KEY`. `build_loop_context` now reads coordinator `brief.json` (`task_id + task_summary + affected_modules`) as the FIRST source for the routing classifier input, falling back to the legacy chain when no brief exists. Expected impact: ~20%+ of trivial docs/CHANGELOG/lint PRs route to Haiku (~1/5 sonnet cost). 5 BATS cases under `tests/unit/test_routing_task_text_wiring.bats`.

- **T2 (PR [#36](https://github.com/wtthornton/ralph-claude-code/pull/36)) — `linear-read` skill mandatory for multi-issue reads.** PROMPT.md, agent contract, and ralph-workflow skill now direct Claude to use the `linear-read` skill (mandatory `tapps_linear_snapshot_get` → on-miss `list_issues` → `snapshot_put` cache-first dance) instead of calling `list_issues` directly. AGENTS.md operator note recommends flipping `linear_enforce_cache_gate: "block"` after a one-session soak shows zero entries in `.cache-gate-violations.jsonl`. The TAP-1224 cache layer is already enforced server-side; default `warn` only logs if Claude forgets — `block` makes the rule actual. Pure prompt/doc change; no code.

- **T3 (PR [#37](https://github.com/wtthornton/ralph-claude-code/pull/37)) — sub-agent fan-out anti-patterns + monitor avg/loop warn.** Sub-agent spawn overhead (~10–30 s + fresh context) dominates several single-ticket loops. Four bright-line anti-patterns added to `.claude/agents/ralph.md` and `templates/skills-local/ralph-workflow/SKILL.md`: don't spawn for single-Bash ops, Linear writes, `ralph-explorer` when `brief.json` names files, or single Read/Grep. `ralph-monitor` soft-warns when session sub-agent avg/loop exceeds `RALPH_SUBAGENT_AVG_WARN` (default 5). The math reads existing `session_subagents` / `loop_count` fields in `status.json` — no new state plumbing. `--once` flag added to `ralph-monitor` for harness testing. 3 BATS cases under `tests/unit/test_subagent_fanout_warn.bats`.

### Measurement campaign

After running `ralph-upgrade-project --yes <consumer-repo>`, re-run `/tmp/loop_stats.py` and capture:

- Avg PR ship time (target: <6 min from 9.2)
- Haiku routing % via `.ralph/.model_routing.jsonl` (target: ≥20% from 0%)
- Sub-agent count per loop (target: ≤4 from ~7)

Soak before bundling T4 (brief lookahead, 2.15.9) and T5 (async PR merge, 2.16.0).

---

## [2.15.6] — 2026-05-22

### Added

- **TAP-2340 — Harness-side R0 enforcement: block `git push origin main`.** `templates/hooks/validate-command.sh` now rejects any `git push` whose refspec targets `main` or `master`, regardless of shape (bare `main`, `HEAD:main`, `<branch>:main`, with leading `--tags` or other flags). Pairs with the prose-side R0 rule shipped in TAP-2339 below — prose covers the agent's contract, the hook covers the case Claude races past the contract. Allow-list preserved: feature-branch pushes, `git push origin --delete <branch>`, same-name `<branch>:<branch>` refspecs, bare `git push` (defaults to upstream), and read-only `git fetch` / `git pull` all pass through. Escape hatch: `RALPH_ALLOW_PUSH_MAIN=1` env var bypasses for legitimate cases (reverting a botched merge, operator-authorized hotfix). 11 new BATS cases under the `R0-harness:` prefix in `tests/unit/test_validate_command.bats`. Merged in PR [#29](https://github.com/wtthornton/ralph-claude-code/pull/29) at commit `8c0b12b`.

### Fixed

- **TAP-2339 — R0 branch-first rule + python `-c` hardening + emit-always RALPH_STATUS directive.** Three coordinated workflow fixes prompted by the AgentForge AOS-pivot campaign on 2026-05-21:

  1. **R0 in `templates/skills-local/ralph-workflow/SKILL.md`** mandates `git checkout -b <branch>` before the first commit on a ticket, sanity-checked via `git rev-parse --abbrev-ref HEAD`. R1 (Done requires `main`) was strengthened to additionally require the ` (#NNN)` PR-merge suffix on the main commit — without it, R1 was satisfied equally well by direct-to-main pushes, which is exactly how the AgentForge campaign accumulated 13 of 20 recent commits without going through review. R0 is now the *mechanism* by which R1 is satisfied. Execution-contract step 3.5 enforces branch creation up-front; new step 8 verifies R0 was honored at loop end by running `git log -1 --format='%H %s' main` and flagging missing `(#NNN)` suffixes in `RECOMMENDATION`.

  2. **`validate-command.sh` interpreter `-c`/`-e` block (TAP-1876) hardened against three bypass shapes** observed in production: absolute paths (`/usr/bin/python3 -c '…'`), versioned binaries (`python3.12 -c '…'`, `pypy3.10 -c '…'`), and wrapper commands (`uv run python -c '…'`, `poetry run python -c '…'`, `pipx run python -c '…'`). Fix: normalize `CMD0` to its basename via `${CMD0##*/}`, strip leading `uv|pipx|poetry run` wrappers when followed by an interpreter, and match interpreter family via a new `_interp_family` helper that handles `python3.*`, `python2.*`, `pypy3.*`, `perl5.*`, `node[0-9]*`, `ruby[0-9]*`. Snippet-path remediation (the carrot that points at `/tmp/snippet.py`) unchanged.

  3. **Emit-always directive in the ralph-workflow skill's execution contract** (step 9). The contract now explicitly enumerates the four loop shapes — productive / no-op / early-exit / error — and the correct status block for each, with the reminder that *three consecutive missing blocks trip the `no_status_block_3x` halt detector and stop the campaign*. The TAP-1899 productivity guard (shipped in 2.15.5) handles truncated-but-productive responses; this directive closes the prose-discipline side for the truly-no-op-without-a-block case that triggered the AgentForge halt at `loop=6 response_bytes=385`. References the actual harness-parsed schema (`STATUS`, `TASKS_COMPLETED_THIS_LOOP`, `FILES_MODIFIED`, `TESTS_STATUS`, `WORK_TYPE`, `EXIT_SIGNAL`, `RECOMMENDATION`) — not a redesigned one.

  Merged in PR [#27](https://github.com/wtthornton/ralph-claude-code/pull/27) at commit `a4b5eb0`. 6 new BATS cases under the `TAP-2336:` prefix.

### Follow-up

- **TAP-2341 — Track R0 adoption.** After this release ships and `ralph-upgrade-project --yes` propagates the new template + hook to AgentForge, the next autonomous campaign should produce **zero direct-to-main commits**. Verify via `git -C /home/wtthornton/code/AgentForge log main --oneline -30 | awk '/\(#[0-9]+\)$/ {pr++} !/\(#[0-9]+\)$/ {direct++} END {print "PR:", pr, "Direct:", direct}'`. If any direct pushes appear, characterize the specific shape that bypassed both layers and file a follow-up.

### Propagation

These fixes need to reach every Ralph-managed project to take effect:

1. **`./install.sh upgrade`** in this repo — syncs the patched `templates/hooks/validate-command.sh` + `templates/skills-local/ralph-workflow/SKILL.md` into `~/.ralph/templates/` and refreshes `~/.ralph/ralph_loop.sh`.
2. **`ralph-upgrade-project`** in each managed repo — pulls the updated `validate-command.sh` from `~/.ralph/templates/hooks/` into the project's `.ralph/hooks/`, and refreshes the local copy of the ralph-workflow skill.

The byte-identity unit test (`test_validate_command.bats:231`) verifies `.ralph/hooks/validate-command.sh` matches the template at every commit, so the repo's own runtime copy cannot drift.

---

## [2.15.5] — 2026-05-22

### Fixed

- **TAP-1899 — `no_status_block_3x` halt fires on productive timeouts.** Field driver: AgentForge 2026-05-21 19:35 UTC — Ralph shipped TAP-2294/2295/2296 to `main` over a 30-minute adaptive-timeout window (`Files Changed: 15`, `Recorded productive timeout latency: 1803s`), but the inner `claude` CLI was killed by `portable_timeout` before it could emit the `---RALPH_STATUS---` footer. The `on-stop.sh` hook saw an empty `_status_block`, incremented `.no_status_block_count`, and tripped `no_status_block_3x` at the start of the next loop — halting the campaign on a response the harness had **already classified as productive** one log line earlier. Root cause: the halt detector at [templates/hooks/on-stop.sh:802-824](templates/hooks/on-stop.sh#L802-L824) only checked `_status_block`; it did not consult `$files_modified` / `$tasks_done` even though both vars were in scope (set at lines [188](templates/hooks/on-stop.sh#L188), [248-255](templates/hooks/on-stop.sh#L248-L255), and used 35 lines later by the USYNC-2 counter at [line 859](templates/hooks/on-stop.sh#L859)). Fix: when `_status_block` is empty AND (`files_modified >= 1` OR `tasks_done >= 1`), the counter is reset rather than incremented — same treatment USYNC-2 already gives its own counter. Stalls with zero file/task progress still increment + trip on schedule, so the halt detector retains its original purpose (catch the tapps-brain-style hot loop where Claude asks questions forever with no work output). One new INFO log line per productive-no-block loop: `on-stop: no RALPH_STATUS block but loop was productive (files=N tasks=M) — counter reset (TAP-1899)`. 4 new BATS cases in `tests/unit/test_on_stop_halt_productivity.bats`.

- **TAP-1900 — coordinator `--resume` retries forever on a dead session id.** Same AgentForge incident, separate signal: `.ralph/.coordinator-debrief.err` showed `No conversation found with session ID: f40dca1e-83af-4538-a18d-b5ad91f72e69` — the stored coordinator session_id had aged past Claude's session-store TTL. `coordinator_session_read` at [lib/coordinator_session.sh:46-58](lib/coordinator_session.sh#L46-L58) only checks file mtime against `COORDINATOR_SESSION_MAX_AGE_SECONDS` (default 3600); it cannot know Claude has already evicted the conversation. The failure path at [ralph_loop.sh:2495-2500](ralph_loop.sh#L2495-L2500) WARN'd and returned non-zero, but never **cleared** the dead id — so the next loop's debrief re-tried the same ghost, re-failed, and burned another ~1s + a WARN line per loop until a successful capture happened to overwrite the file. Did **not** cause the halt (TAP-1530's `RALPH_COORDINATOR_INVOCATION=1` guard prevents the coordinator response from counting against `.no_status_block_count`), but it's a per-loop reliability tax in long campaigns. Fix: after `_rc != 0` with `--resume` in `_continue_args`, grep the stream for the "No conversation found" sentinel and call `coordinator_session_clear` so the next invocation cold-starts. Logged at DEBUG: `coordinator: cleared dead session id after --resume failure`.

### Propagation

These fixes need to reach every Ralph-managed project to take effect:

1. **`./install.sh`** in this repo — syncs the patched `templates/hooks/on-stop.sh` into `~/.ralph/templates/hooks/` and refreshes `~/.ralph/ralph_loop.sh`.
2. **`ralph-upgrade-project`** in each managed repo — pulls the updated `on-stop.sh` from `~/.ralph/templates/hooks/` into the project's `.ralph/hooks/`.

`ralph-doctor` already drift-checks `.ralph/hooks/*.sh` against `~/.ralph/templates/hooks/*.sh`, so any project still on the old hook will surface a WARN until step 2 runs.

---

## [2.15.4] — 2026-05-21

### Added

- **ralph-workflow skill 1.0.0 → 1.1.0 — read-only audit-session support.** Native handling for tickets emitted by `tapps_audit_campaign` so Ralph no longer needs a per-project `PROMPT.md` shim to run them. Closes the AgentForge feedback bundle's "Repo 1" items (TAP-2258 campaign with 34 children TAP-2259..TAP-2292 was the field driver):
  - **WORK_TYPE enum gains `AUDIT`** — distinct from `VERIFICATION` so telemetry / circuit-breaker logic can tell "scanned code and filed findings" apart from "verified prior fix is still in place."
  - **R1 exemption clause** inserted after the Hard Rules block in linear mode. When `WORK_TYPE` is `AUDIT` and `FILES_MODIFIED` is `0`, the `git log main --grep=<TICKET>` check is skipped — audit work is by-design non-mutating, so no commit on `main` will exist and that is correct. Detection via **either** an `audit-readonly` Linear label **or** a `<!-- ralph: audit-readonly -->` body marker in the first 500 characters (belt-and-suspenders so a missing label doesn't break the contract).
  - **Step 5 of the execution contract** carries the AUDIT short-circuit — if the signal is present, close with summary comment + Linear → Done without R1.
  - **New "Read-only audit task" scenario block** with full status-block example: `STATUS: COMPLETE`, `TASKS_COMPLETED_THIS_LOOP: 1`, `FILES_MODIFIED: 0`, `WORK_TYPE: AUDIT`, `EXIT_SIGNAL: false`. The `TASKS_COMPLETED_THIS_LOOP: 1` is load-bearing — it's what tells the harness this loop made progress so `consecutive_no_progress` resets even though zero files changed.
  - **New "Linear writes — delegation pattern" section** documenting the canonical `Task` subagent route for Linear mutations. The main Ralph agent's `tools:` list intentionally omits `mcp__plugin_linear_linear__*` so `.claude/rules/agent-scope.md` stays enforceable; this section names the workaround (route through `linear-issue` / `linear-read` skills, spawn `general-purpose` subagent for the write).

  Replicated byte-identical across all three skill copies — `templates/skills-local/ralph-workflow/SKILL.md` (template / source of truth for `ralph-upgrade-project`), `.claude/skills/ralph-workflow/SKILL.md` (repo dev), `.cursor/skills/ralph-workflow/SKILL.md` (Cursor IDE mirror).

- **`ralph-upgrade-project` 1.0.0 → 1.1.0 — audit-campaign shim deprecation detector.** New `detect_audit_campaign_workaround()` scans the unmanaged region of `.ralph/PROMPT.md` (everything outside the `RALPH:START`/`RALPH:END` markers, since user content lives there) after every PROMPT.md merge. Fires a WARN when it finds the legacy R1-skip wording paired with audit-campaign keywords, or an explicit `audit-readonly` reference. No auto-removal — users may have customized the workaround region, so the prompt only surfaces it. Pairs with the skill change: once the consumer relabels existing audit tickets with `audit-readonly`, the shim becomes safe to remove and this warning makes the decommission explicit.

### Tests

- ralph-claude-code unit suite still 100% pass on `npm test`. tapps-mcp counterpart (the emit-side label + body marker + closure-language change in `audit_session_template.py`) ships separately on the tapps-mcp release train; this release does not depend on tapps-mcp version.

---

## [2.15.2] — 2026-05-17

### Fixed

- **TAP-1881 — `.gitignore` audit: allowlist pattern + idempotent upgrade backfill.** Closes [TAP-1682](https://linear.app/tappscodingagents/issue/TAP-1682) origin: every Ralph-managed consumer repo's `git status` was leaking 14 untracked `.ralph/` state files (`.brief_cache/`, `.coordinator_timings.jsonl`, `.model_routing.jsonl`, `.qa_failures.json`, `.import_graph.json`, `brief.json`, …) because `templates/.gitignore` was a hand-maintained denylist and `lib/enable_core.sh:884-897` carried a duplicate hardcoded list with a marker-skip merge that froze after first install. Two stories collapse three failure modes into one source of truth:
  - **TAP-1882** — `templates/.gitignore` switches to `.ralph/*` + `!` allowlist exceptions (`PROMPT.md`, `AGENT.md`, `fix_plan.md`, `hooks/`, `.gitkeep`). Any new state-file writer under `.ralph/` is absorbed automatically — no template churn per feature. `lib/enable_core.sh` loses its duplicate hardcoded list and marker-skip merge; new top-level `merge_gitignore_block` helper reads canonical patterns from `templates/.gitignore` and appends missing ones via `grep -qxF` membership check. User content above and below the Ralph block is preserved byte-for-byte. 12 new BATS cases in `tests/unit/test_gitignore_merge.bats`.
  - **TAP-1883** — `ralph_upgrade_project.sh` reuses `merge_gitignore_block` as a Tier-2 merge so `ralph upgrade` retrofits the allowlist into existing consumer repos without losing user-added entries. New `dry_run=true` mode on the helper publishes the would-be-appended count via `GITIGNORE_MERGE_APPENDED` so `--dry-run` still surfaces the operator-visible diff. Bottom of `ralph_upgrade_project.sh` gains a `BASH_SOURCE` guard so its functions are sourceable from tests without running `main()`. 9 new BATS cases.

### Added

- **TAP-1988 — Tool Search BETA opt-in via `ANTHROPIC_BETA` header.** Parent epic [TAP-1983](https://linear.app/tappscodingagents/issue/TAP-1983) — without the `advanced-tool-use-2025-11-20` beta header, the Anthropic API hides every tool annotated `defer_loading: true` from the catalog entirely and the agent has no recovery path. `ralph_loop.sh:build_claude_command` now exports `ANTHROPIC_BETA` before every Claude CLI invocation, read by the Anthropic SDK and forwarded as the `anthropic-beta` HTTP header. Multi-value-safe: an operator-set `ANTHROPIC_BETA="other-beta"` is preserved and the tool-search token is appended; if the token is already present, the env var is left untouched (no duplication across repeated calls). `RALPH_BETA_TOOL_SEARCH=false` is the escape hatch. New `templates/ralphrc.template` section "ANTHROPIC BETA FEATURES" documents the override. 6 new BATS cases in `tests/unit/test_build_claude_command.bats`.

- **TAP-1878 — Branch hygiene: auto-cleanup of squash-merged Ralph working branches.** Consumer-repo audit in `wtthornton/tapps-brain` 2026-05-16 found 32 local + 17 origin stale `tap-*` branches accumulated across loops; every consumer repo hits this without harness-side cleanup. Two complementary mechanisms ship together:
  - **TAP-1879** — `ralph_loop.sh:2228` prompt and `templates/skills-local/ralph-workflow/SKILL.md` (R1) both gain the same sentence: after a successful squash-merge to `main`, run `git branch -D <branch>` locally and `git push origin --delete <branch>` on origin, framed best-effort so network/permission errors don't block the loop. Lockstep enforced per the `feedback_default_doc_lockstep` memory. 9 new BATS cases in `tests/unit/test_branch_cleanup_prompt.bats`.
  - **TAP-1880** — new `lib/branch_cleanup.sh` module (`ralph_cleanup_merged_branches` orchestrator + 4 helpers) invoked once per Ralph invocation from `main()` as the harness-side safety net for branches the LLM forgot to delete. Detection uses `git cherry main <branch>` — the only squash-merge-aware primitive (`git branch --merged` does NOT detect squash-merges because squash creates a new commit on `main`). Four-layer safety envelope makes false-positive deletion structurally impossible: cherry evidence + `RALPH_BRANCH_CLEANUP_PROTECTED` glob list (default `main:master:develop:release/*`) + `RALPH_BRANCH_PREFIX` filter (default `tap-`) + `RALPH_BRANCH_CLEANUP_MIN_AGE_HOURS` threshold (default 24). Currently-checked-out branch and `RALPH_CURRENT_BRANCH` pin are always preserved. All failures (network, permission, missing remote) are WARN-only — orchestrator always returns 0 so a botched cleanup never trips the CB. 18 new BATS cases in `tests/unit/test_branch_cleanup.bats`. Real-world validation post-merge: deleted 2 stale `tap-1838-*` branches in this repo on first run with no manual intervention.

### Tests

- Unit suite grew from **1751 → 1778 cases** (+27) across 4 new BATS files: `test_gitignore_merge.bats` (+21), `test_build_claude_command.bats` (+6), `test_branch_cleanup_prompt.bats` (+9), `test_branch_cleanup.bats` (+18), with adjacent existing files (`test_enable_core.bats`) picking up the rewrites against the new helper. All green; full unit suite still 100% pass.

---

## [2.15.1] — 2026-05-16

### Fixed

- **TAP-1875 — Coordinator brief.json missing on ~88% of cache-miss spawns.** The ralph-coordinator subagent was returning the one-line summary without invoking the Write tool on 44 of 50 loops in the 2026-05-15 → 2026-05-16 tapps-brain campaign, defeating the TAP-1682 brief cache and forcing every cache-miss loop to re-derive risk classification from scratch. Three reinforcing fixes: (1) `.claude/agents/ralph-coordinator.md` `MODE=brief` now carries a literal Write-tool example + the full required JSON schema inline and flags "summary without writing the file" as a contract violation; (2) `ralph_loop.sh:ralph_spawn_coordinator` rewrites the prompt body from "Write per the schema" to a numbered REQUIRED ACTION block naming every required field + enum constraints; (3) on rc=0-no-file, the harness retries the brief invocation once with an explicit "your previous response did not write the file" header — the resumed session preserves the task context — then calls `brain_client_write_failure(source="coordinator-brief")` if the retry still fails so skill-retro can surface a sustained regression next campaign. 5 new BATS cases in `tests/unit/test_coordinator_brief.bats`.

- **TAP-1876 — `python3 -c` friction in validate-command.sh denial flow.** Claude burned a tool call on ~28 of 50 loops retrying `python3 -c "…"` for read-only introspection (imports, version checks, AST parses). The hook correctly denied each attempt, but the denial message said nothing about the workaround — file-based execution is allowed. The fix names the remediation per-interpreter: `templates/hooks/validate-command.sh` section 4 now emits `BLOCKED: $CMD0 $arg script-execution not allowed. Write the snippet to /tmp/snippet.<ext> (or similar) and run "$CMD0 /tmp/snippet.<ext>" instead: …` with the right extension (`.py`/`.js`/`.pl`/`.rb`/`.sh`) per interpreter. New Tier-B `python-introspection` skill ships under `templates/skills/global/python-introspection/` (SKILL.md + import-check example). `lib/skill_retro.sh` gains an `interpreter_dash_c_denials` friction signal that auto-installs the new skill once ≥3 denials accumulate in the rolling window. `.ralph/hooks/validate-command.sh` kept byte-identical to the template per the TAP-624 parity rule. 15 new BATS cases in `tests/unit/test_validate_command.bats`.

- **TAP-1877 — Execution stats WARN line leaked `(00 scope, N system)` double-zero.** Canonical `grep -c | ... || echo 0` pitfall documented in CLAUDE.md, leaking through `lib/exec_helpers.sh:131-137`. `grep -c` on a no-match exits 1 with stdout `"0"`, so the `|| echo 0` branch appended another `"0"` and `tr -d '[:space:]'` collapsed the pair into the literal `"00"` that landed in the operator-facing WARN line (9 of 50 lines in the 2026-05-15 → 2026-05-16 tapps-brain ralph.log). Replaced the inline idiom with the documented `tr -cd '0-9' || true` + `${var:-0}` pattern and extracted the stats-line emission into a new `exec_log_execution_stats` helper so the regression surface is unit-testable. 5 new BATS cases in `tests/unit/test_exec_post_run.bats`.

### Added

- **TAP-1838 — MCP probe sentinel: skip `claude mcp list` when inputs are unchanged.** `ralph_probe_mcp_servers()` ran `claude mcp list` (up to 30s) on every session start, even when the `claude` binary version and both MCP config files (`.mcp.json`, `~/.claude.json`) were unchanged from the last run. A new `ralph_mcp_compute_probe_hash()` helper computes a SHA-256 over those three inputs; on a successful live probe the result is written to `.ralph/.mcp-probe-sentinel` (key=value format: `ts`, `hash`, `tapps`, `docs`, `brain`, `brain_auth_failed`). Subsequent startups that find a sentinel younger than `RALPH_MCP_PROBE_SENTINEL_MAX_AGE` seconds (default 86400 / 24 h) with a matching hash load the cached flags immediately and skip the live probe entirely. New knob: `RALPH_MCP_PROBE_SKIP_IF_UNCHANGED=true` (default true) — set to `false` to always run the live probe. Sentinel is not written when (a) `claude mcp list` returns empty output (probe failed), or (b) no SHA-256 command is available (safe degradation: probe runs every time). 17 new BATS cases in `tests/unit/test_mcp_probe_sentinel.bats`.

### Tests

- Unit suite grew from **1707 → 1751 cases** (+44) across 4 new BATS files: `test_mcp_probe_sentinel.bats` (TAP-1838, +17), `test_coordinator_brief.bats` (TAP-1875, +5), `test_validate_command.bats` (TAP-1876, +15), `test_exec_post_run.bats` (TAP-1877, +5), with adjacent existing files picking up the remaining +2. All green; integration suite 203/203.

---

## [2.15.0] — 2026-05-14

### Added

- **TAP-1681 — `ralph-doctor` detects PROMPT.md / ralph.md drift in Linear mode + templates branch on `RALPH_TASK_SOURCE`.** Linear-mode projects whose `.ralph/PROMPT.md` and `.claude/agents/ralph.md` were templated before they switched task sources still said "Read .ralph/fix_plan.md", so every loop opened with a Read error on a file that didn't exist (AgentForge field telemetry: 35 sessions over 30 days, hundreds of no-progress CB opens). `ralph-doctor` now warns when `RALPH_TASK_SOURCE=linear` and either file carries `fix_plan.md is the single source of truth` or `Read .ralph/fix_plan.md` outside a `<!--TASK_SOURCE:linear:*-->` block. `templates/PROMPT.md` and `.claude/agents/ralph.md` ship paired `<!--TASK_SOURCE:{file,linear}:{start,end}-->` blocks; `ralph_upgrade_project.sh` gains a `--resync-templates` flag and a `resolve_task_source_blocks()` helper that strips the inactive branch on every template copy (controlled by `.ralphrc:RALPH_TASK_SOURCE`, default `file`). 13 new BATS cases in `tests/unit/test_ralph_doctor_linear.bats`. Also fixes a pipefail trap in `detect_task_source` that aborted the upgrade when `.ralphrc` had no `RALPH_TASK_SOURCE` line.

- **TAP-1682 — Per-issue coordinator brief cache + adaptive timeout.** The static 120s coordinator ceiling was bandaging a shape problem: the same Linear issue often hits the coordinator on 4–8 consecutive loops, and the first call cold-starts MCP (legitimately needs the budget) while the next several regenerate the same brief. `lib/exec_helpers.sh` gains `exec_load_cached_brief` / `exec_save_brief_cache` (cache at `.ralph/.brief_cache/<linear_issue_id>.json`, atomic-write per the TAP-535 pattern, eviction on issue-updated-at mismatch or `RALPH_BRIEF_CACHE_MAX_AGE_SECONDS` default 1800). `ralph_loop.sh:ralph_spawn_coordinator` checks the cache before invoking and saves after a successful brief write. On timeout (exit 124), the harness retries the cache with a 24h TTL as graceful degradation — even a stale brief beats no brief. `ralph_compute_coordinator_timeout` returns P95×2 of the last 30 wall-clock samples (clamped `[30, 600]`s, fallback 120s, sample log `.ralph/.coordinator_timings.jsonl`). `RALPH_COORDINATOR_TIMEOUT_SECONDS` remains a hard override for incident response. 20 new BATS cases in `tests/unit/test_coordinator_brief_cache.bats`.

- **TAP-1683 — USYNC-2 policy: act on consecutive question-pattern loops.** USYNC-1 has emitted `Detected N question pattern(s)` since 2026-03 but nothing acted on the signal; AgentForge field data shows the same project re-entering the question→CB-open→cooldown→restart cycle hundreds of times. `templates/hooks/on-stop.sh` now maintains `.ralph/.consecutive_questions` — incremented when `asking_questions=true` AND no RALPH_STATUS block was present, reset on any productive loop. `build_loop_context` **prepends** (not appends — would otherwise be dropped by the 1500-char output cap) a hardened `ESCALATION (USYNC-2)` directive when the counter ≥ `RALPH_QUESTION_LOOP_THRESHOLD` (default 2). At threshold+1 the hook advances past the current task: linear mode writes `.ralph/.linear_advance_action` so the next loop tells Claude to apply a `blocked:waiting-for-answer` label via the Linear MCP and pivot; file mode appends `<!-- BLOCKED: questions -->` to the first unchecked `fix_plan.md` task. 14 new BATS cases in `tests/unit/test_question_loop_policy.bats`. `.ralph/hooks/on-stop.sh` synced byte-identical (TAP-538 parity test).

- **TAP-1684 — Epic-boundary QA: parallel fan-out across `ralph-tester`, `ralph-reviewer`, `tapps-validator`.** Three QA agents used to run serially because that's how the contract was written; Claude Code's `Task` tool actually runs sibling calls concurrently. `templates/skills-local/ralph-workflow/SKILL.md` (+ `.claude/skills/` and `.cursor/skills/` byte-mirrors) and `.claude/agents/ralph.md` both mandate the three-Task single-message dispatch with a worked example; aggregation rule "any FAIL or TIMEOUT collapses to FAIL". `lib/exec_helpers.sh` ships `exec_aggregate_qa_results` for harness-side aggregation. `templates/hooks/on-subagent-done.sh` gains an in-flight guard via `.ralph/.subagent_in_flight` + `.subagent_defer_cb` so a fast FAIL from one agent doesn't race a slow PASS from another. Wall-clock impact: 4–7min serial → 3–5min parallel per epic. 15 new BATS cases in `tests/unit/test_parallel_qa_aggregation.bats`.

- **TAP-1685 — `ralph-monitor` prompt-cache hit-rate panel + cold-cache WARN.** `status.json` already tracked `loop_cache_read_tokens` / `session_cache_read_tokens` etc., but the monitor only showed a one-line summary buried in the Status panel — a sustained cache regression was invisible until the cost line jumped. `ralph_monitor.sh` now renders a dedicated `Prompt cache (TAP-1685)` panel with per-loop and rolling-session hit-rate percentages plus the contributing token counts. When the session hit rate drops below `RALPH_CACHE_HIT_RATE_WARN` (default 30%) the panel turns red and emits an investigation hint naming the common causes (locality hints, skill edits, agent file drift). Cold-start loops render `0%`, not NaN. Single-loop cold cache does NOT trigger WARN — only the rolling session number gates the warn. 7 new BATS cases in `tests/unit/test_cache_hit_rate_panel.bats`.

- **TAP-1686 — Plan Mode for HIGH-risk coordinator verdicts.** The pre-TAP-1686 HIGH-risk protocol was "coordinator consult, then proceed with bypassPermissions if APPROVE" — bypass mode mismatches the *intent* of HIGH-risk. Now the harness flips the next loop to `--permission-mode plan` when `.ralph/brief.json` has `risk_level: HIGH`. `ralph_loop.sh:build_claude_command` reads `RALPH_PERMISSION_MODE` and appends `--permission-mode <value>` to the CLI argv, overriding the agent file's `bypassPermissions` default for the single loop. `build_loop_context` exports `RALPH_PERMISSION_MODE=plan` on HIGH-risk briefs (honors a pre-set operator override and does NOT clobber it) and injects a `PLAN MODE ACTIVE` directive telling Claude to emit a numbered plan + post it as a Linear comment + set `WORK_TYPE: PLANNING` + `FILES_MODIFIED: 0` in RALPH_STATUS. `templates/hooks/on-stop.sh` gains a productivity branch that treats `WORK_TYPE: PLANNING + status block present` as legitimate work (resets `consecutive_no_progress=0`) so a zero-file Plan Mode loop doesn't trip toward CB OPEN. Bare planning text without the block still falls through to no-progress (stuck-planner guard). `.claude/agents/ralph.md` documents the Plan Mode contract. 13 new BATS cases in `tests/unit/test_plan_mode_high_risk.bats`.

### Tests

- Unit suite grew from **1638 → 1707 cases** (+69) across 6 new BATS files; all green.

---

## [2.14.3] — 2026-05-11

### Fixed

- **TAP-1532 — `ralph-doctor` remediation text named the wrong sync command.** `ralph-doctor`'s drift WARN, TAP-1530 FAIL, and (new in 2.14.2) TAP-1531 FAIL all instructed operators to "Run 'ralph-upgrade' to sync" — but `ralph-upgrade` only refreshes `~/.ralph/templates/` and `~/.local/bin/`, never the per-repo `.ralph/hooks/` tree. The actual command that syncs templates into an existing repo is `ralph-upgrade-project` (which execs `~/.ralph/ralph_upgrade_project.sh::upgrade_hooks`). Anyone who installed 2.14.2 expecting the TAP-1531 session guard to land automatically still had the guard missing in their managed repos because re-running `ralph-upgrade` is idempotent at the global layer and does not converge per-repo drift. Three call sites in `install.sh` (drift WARN, TAP-1530 FAIL, TAP-1531 FAIL) and the matching three in `~/.local/bin/ralph-doctor` updated to name `ralph-upgrade-project` and explain the global-vs-per-repo split. The `ralph-upgrade` wrapper now also prints a post-success hint pointing operators at `ralph-upgrade-project` so the per-repo step is discoverable without consulting the doctor. `MIGRATING.md` (the 2026-05 TAP-1531 section) and `CLAUDE.md` ("Hook-based response analysis" → session guard contract) updated to call out the two-command flow explicitly. Reported by an operator who hit the issue after upgrading to 2.14.2: `ralph-upgrade` reported success, templates refreshed to the 50,210-byte version, but the managed repo's hook stayed at the May-7 48,865-byte version and `ralph-doctor`'s remediation text told them to re-run the command that had just failed to fix it. Re-running `ralph-upgrade` three times in a row produced zero convergence (correct behavior; wrong diagnostic).

---

## [2.14.2] — 2026-05-11

### Fixed

- **TAP-1531 — Session guard prevents interactive Claude Code sessions from polluting ralph state.** The `on-stop.sh` Stop hook (installed in `.claude/settings.json`) now includes a guard that distinguishes interactive Claude Code sessions from ralph autonomous loops. Without the guard, every interactive Stop event would increment `loop_count`, accumulate `session_cost_usd` against zero ralph iterations, and pollute `.no_status_block_count` — potentially tripping the `no_status_block_3x` halt detector. The fix: `ralph_loop.sh:main()` exports `RALPH_LOOP_ACTIVE=1` before invoking Claude; the hook checks `if [[ "${RALPH_LOOP_ACTIVE:-}" != "1" ]]; then exit 0; fi` at the start of its main body. When the var is unset (interactive session), the hook exits immediately (no-op). When the var is "1" (autonomous loop), the hook proceeds normally. The real-world incident (May 2026, ralph-claude-code): 885 interactive Stop events over several months accumulated $16,489 in false `session_cost_usd` and 885 fake loop increments with zero actual ralph work. The fix is transparent to existing workflows — interactive sessions work unchanged, they just won't pollute state anymore. `ralph-doctor` includes a TAP-1531 check that greps the project's `.ralph/hooks/on-stop.sh` for the `RALPH_LOOP_ACTIVE` guard and warns with run-`ralph-upgrade` instructions when missing. Syncs automatically on next upgrade or loop run via the existing `ralph-upgrade` mechanism.

---

## [2.14.1] — 2026-05-07

### Fixed

- **TAP-1530 follow-up — coordinator guard defense in depth + softened routing-stale warning.** Three small harness hardenings prompted by a tapps-brain incident where a stale project `on-stop.sh` was missing the `RALPH_COORDINATOR_INVOCATION` guard, causing every coordinator sub-agent invocation to be counted as a missing `RALPH_STATUS` block and tripping `no_status_block_3x` after one productive loop:
  - **`lib/coordinator_rpc.sh`** now `export`s `RALPH_COORDINATOR_INVOCATION=1` before its claude spawns, mirroring the existing exports at `ralph_loop.sh:2380` and `:2388`. Either entry point reaching the CLI now sets the marker; the on-stop guard cannot be bypassed by the consult path. Three new BATS cases in `tests/unit/test_coordinator_rpc.bats` cover the timeout=0 path, the `timeout` path, and a static source-order check (the export must precede both invocations).
  - **`ralph-doctor`** gains a TAP-1530-named check that greps the project's `.ralph/hooks/on-stop.sh` for the `RALPH_COORDINATOR_INVOCATION` guard string and emits a high-severity `[FAIL]` with run-`ralph-upgrade` instructions when missing. Generic hook-drift warnings missed this signal in the wild — now it is called out by name. Two new BATS cases in `tests/unit/test_startup_guards.bats` cover both the FAIL-on-missing-guard and OK-when-present paths.
  - **Routing-log staleness warning** at startup softened from `WARN ".model_routing.jsonl is Nmin stale … routing may be silently disabled. Run 'ralph --version' and verify lib/complexity.sh:23 default."` to `INFO` describing the actual signal. The default at `lib/complexity.sh:23` is `true`; a stale log just means no productive loops have appended a routing decision since the prior session — not a default-drift bug. The old warning sent operators to chase a non-existent regression.

---

## [2.13.1] — 2026-05-05

### Fixed

- **Stop hook transcript fallback for Claude Code 2.1.x.** Claude Code 2.1.x removed the `"type":"result"` line from the stop hook stdin payload and from the transcript, leaving `on-stop.sh` unable to parse the `RALPH_STATUS` block — `status.json` defaulted across the board (`exit_signal=false`, `tasks_completed=0`, `files_modified=0`), the dual-condition exit gate never fired, and question-pattern / permission-denial detection ran against an empty `response_text`. Hook now falls back to reading the last `assistant` message's text content from `transcript_path` when the initial `_status_block` parse comes back empty, then re-runs `sed`. Also restores `response_text` so downstream detectors work. Three new BATS cases in `tests/unit/test_on_stop_hook.bats` cover (1) status parsed from transcript, (2) `LINEAR_ISSUE` extracted from transcript, (3) graceful UNKNOWN status when transcript has no RALPH_STATUS block. Both `templates/hooks/on-stop.sh` and the in-repo `.ralph/hooks/on-stop.sh` are updated; `ralph-upgrade` will sync this fix into existing projects.

---

## [2.12.0] — 2026-05-04

SDK bumped to **2.2.0** alongside this release (TAP-1104 + TAP-542 + per-task model routing all touch the SDK surface).

### Added

- **TAP-542 — SDK quality gate (ruff + mypy + pytest-asyncio + pytest-timeout).** New blocking CI job `sdk-quality` runs alongside the bash test job. `ruff check` (E/W/F/I/B/UP families), `mypy` (pragmatic disable list for the str+Enum classes pending a follow-up StrEnum migration), `pytest-asyncio` mode=auto for the ~50 async tests, and a 30s `pytest-timeout` default. UP042 deferred — see `sdk/pyproject.toml` for the rationale. Documented `TracerProtocol` for the previously `Any | None` tracer parameter.
- **TAP-1201 — ralph-monitor mid-loop visibility + accurate liveness detection.** New `_classify_liveness` (`HEALTHY` / `STALE` / `DEAD` / `UNKNOWN`) factors in `status.json` mtime, `live.log` mtime within `LIVE_LOG_FRESH_SECS` (default 60s), and `ralph_loop.sh` PID liveness via `pgrep`. `DEAD` now requires BOTH stale `status.json` AND no live process — the conditions that masked the April-2026 NLTlabsPE Loop 1 false alarm. Added always-render "Working on:" / "Model:" rows with `(awaiting first loop)` placeholders. New PreToolUse hook `templates/hooks/on-linear-tool.sh` writes `.ralph/.current_issue` atomically when Claude calls a Linear MCP tool; per-project opt-in via `.claude/settings.json` matcher `mcp__plugin_linear_linear__.*`.
- **Per-task complexity-based model routing in the SDK.** New `model_routing_enabled` config flag (default off; opt-in). When enabled, `_build_claude_command` routes each Claude CLI invocation to the cheapest model that can credibly do the work (haiku → sonnet floor → opus) based on the next unchecked `fix_plan` task. Mirrors the bash `lib/complexity.sh::ralph_select_model` contract.
- **TAP-540 — first-time BATS coverage for `lib/github_issues.sh`.** 19 cases covering repo detection (SSH/HTTPS/missing remote), input validation (TAP-651 regression guard), happy-path import, gh failure modes (404/403/429/malformed JSON), label/assignee filters, idempotent re-import, batch processing, and assessment scoring. PATH-shim a fake `gh` binary controlled by env vars; stub `git remote get-url origin` via function shadowing.

### Changed

- **TAP-1104 — SDK only supports agent mode (mirror of bash ADR-0006).** Removed `use_agent` field + every reader (env / JSON / .ralphrc / export round-trip). `_build_claude_command` always emits `--agent <name>` and never emits `--allowedTools`. Bumped `claude_min_version` default `2.0.76 → 2.1.0` and added `_preflight_claude_version` that runs at `RalphAgent.run()` start; raises `RalphConfigError` (new typed exception) when the installed CLI is older. Cannot-detect degrades to a WARN log to mirror bash `check_claude_version`.
- **`HOOKS-2: hook scripts reference a known hook directory`** rewritten to accept BOTH `.ralph/hooks/` and `.claude/hooks/`. Original test rejected `.claude/hooks/` entries and broke as soon as tapps-mcp registered hooks there.
- **`all hook commands start with 'bash '`** widened to also accept the bare `.claude/hooks/<name>.sh` form that tapps-mcp / linear-MCP plugins emit. Still catches tool names (Write/Edit) or garbage strings landing in `command` fields.
- **`PreToolUse has exactly two entries`** rewritten as a positive invariant check: Ralph's Bash hook must wire to `validate-command.sh` AND its Edit|Write hook must wire to `protect-ralph-files.sh`. Plugin-injected entries are allowed; what is protected is removal or rewiring of Ralph's own defenses.
- **`.gitignore`** adds 7 new runtime-state entries (`.ralph/.model_routing.jsonl`, `.qa_failures.json`, `.current_issue`, `.coordinator_session`, `brief.json`, `forensic-*/`).
- **`docs/epics/`** committed: docs-mcp-generated epic + 9 story specs that previously lived untracked in working trees.

### Fixed

- **TAP-668 — Dockerfile.sandbox HEALTHCHECK readability + HOME env for ralph user.** Three concrete bugs: `ENV HOME=/home/ralph` was missing (npm/gh/claude config writes silently failed under the dropped user with `$HOME=/`); `HEALTHCHECK` used `test -f` which couldn't distinguish missing-file from permission-denied (now `test -r`); failure now emits a stderr cause line so `docker inspect --format='{{json .State.Health}}'` shows the actual reason. Documented bind-mount UID alignment requirement above `WORKDIR`.
- **Test count mismatch (`Executed 1455 instead of expected 1456 tests`).** Removed dead `dry_run_simulate logs allowed tools count` test in `tests/unit/test_log_rotation_dryrun.bats`. Asserted on a `CLAUDE_ALLOWED_TOOLS` log line that ADR-0006 deleted; sourcing `ralph_loop.sh` in the bats env triggered the post-ADR-0006 startup `exit`, so bats counted the @test in `1..N` but never produced an `ok N` line. Surfaced once the previously inactive Test Suite workflow was enabled.
- **Two integration tests asserting `setup.sh` ships `ALLOWED_TOOLS=...` in `.ralphrc`** replaced with a single negative invariant (`! grep -qE '^ALLOWED_TOOLS=' .ralphrc`) so the legacy field stays deleted.
- **One eval test (`FILE PROTECTION: blocks edit to .ralphrc`)** was asserting the wrong half of the hook contract — it ran with no `.ralphrc` fixture, but the hook's contract (HOOKS-5) is allow-create-when-absent / block-edit-when-present. Split into two tests covering both halves.
- **`.github/workflows/codeql-analysis.yml`** now pins `defaults.run.shell: bash` per TAP-667. Was the only hand-authored workflow without this; only became visible to CI once the Test Suite workflow was enabled.

### CI / Infrastructure

- **Test Suite workflow enabled.** `gh workflow enable "Test Suite"` registered the previously inactive workflow, giving end-to-end CI signal on every PR for the first time in this version range. The previously-undetected gaps fixed under "Fixed" above were all surfaced by this single change.

---

## [2.11.5] — 2026-05-02

### Changed

- **TappsMCP tooling refresh to 3.8.0.** Ran `tapps_upgrade` to resync project-managed agents, skills, hooks, and platform configs against TappsMCP 3.8.0. `AGENTS.md` excised the Karpathy block and refreshed the platform-hooks section. Claude Code platform: `CLAUDE.md` updated; new hooks (`tapps-pre-bash.sh`, `tapps-pre-linear-write.sh`, `tapps-pre-linear-list.sh`, `tapps-post-docs-validate.sh`, `tapps-post-linear-snapshot-get.sh`); 4 tapps agents and 14 skills updated; 2 new skills (`linear-read`, `linear-release-update`); new `.claude/rules/integration-hygiene.md`. Cursor platform: regenerated MCP config, 4 agents + 15 skills + 3 cursor rule types. GitHub: Copilot agent profiles, path instructions, issue/PR templates, dependabot, and ruleset scripts created; CodeQL workflow updated. Backup at `.tapps-mcp/backups/2026-05-02-171935`. No Ralph runtime behavior changed — tooling/dev-environment refresh only.

---

## [2.11.4] — 2026-04-30

### Fixed

- **Session-ID lazy-init was a lie (chronic `session_id is empty` warning).** `ralph_initialize_session` wrote `session_id: ""` "for lazy init" — but the lazy-init step that was supposed to fill it later never existed. `save_claude_session` writes the Claude CLI's session ID to `.claude_session_id` (a separate file), not `.ralph_session`. `get_session_id()` is also vestigial — defined but called nowhere. Net effect: every loop fired `WARN: Session file exists but session_id is empty — reinitializing`, the function rewrote empty, the next loop warned again, forever. The fix has `ralph_initialize_session` generate a real Ralph-internal ID via the existing `generate_session_id` helper (matching `init_session_tracking`'s pattern) so the file always has a non-empty session_id when valid. The misleading `(awaiting session_id from next Claude invocation)` log line is replaced with the actual generated id.

### Changed

- **Coordinator timeout configurable + default raised 60s → 120s.** The TAP-915 coordinator sub-agent that writes `.ralph/brief.json` had a hardcoded `timeout 60` that was too tight for setups with multiple MCP servers (tapps-mcp, docs-mcp, tapps-brain, Linear plugin) — the coordinator's `session_start` + Linear queue scan + brief write often exceeds 60s on cold start. NLTlabsPE saw 3 timeouts in 10 loops at the old default. New env var `RALPH_COORDINATOR_TIMEOUT_SECONDS` (default `120`); set `0` to disable the timeout altogether. The coordinator's failure log now distinguishes `timed out after Ns` (rc=124) from `spawn failed (exit N)` so the operator can tell whether to raise the timeout or debug a CLI/agent-config issue. Original "spawn failed or timed out" generic message removed.

### Tests

- 3 new regression tests in `tests/unit/test_session_init_repair.bats`:
  - `SESSION-ID-FIX: ralph_initialize_session writes a non-empty session_id` — asserts the generated id matches the canonical `ralph-<epoch>-<rand>` format.
  - `SESSION-ID-FIX: ralph_validate_session does NOT loop after ralph_initialize_session` — repro of the chronic-warning loop; asserts validate returns 0 with no `session_id is empty` warning after initialize.
  - `SESSION-ID-FIX: log message names the generated id` — asserts the misleading `awaiting session_id` text is gone.
- 1 new regression test in `tests/unit/test_coordinator_spawn.bats`:
  - `COORDINATOR-TIMEOUT: rc=124 emits 'timed out' message + names the env var to raise` — asserts the rc=124 path now emits the duration and the env var name so operators know the lever.
- Existing `TAP-915: spawn failure WARNs and leaves no brief` test updated: mock now returns rc=1 (generic spawn failure) instead of 124 (timeout), and asserts the new `spawn failed (exit 1)` message format. The rc=124 case is covered by the new COORDINATOR-TIMEOUT test.

---

## [2.11.3] — 2026-04-30

### Fixed

- **on-stop.sh status-block parser hardening (NLTlabsPE 2026-04-30 incident).** Two simultaneous parser bugs caused exit-gate bypass when Claude correctly reported `STATUS: BLOCKED + EXIT_SIGNAL: true` on a fully-blocked Linear backlog (10 wasted loops + CB trip):
  - **Field-name case drift.** Projects whose `PROMPT.md` uses lowercase `linear_open_count: 0` had the value silently dropped because the original grep was case-sensitive against `LINEAR_OPEN_COUNT:`. The hook now runs an `awk` pre-pass that uppercases the field-identifier portion of every `<ident>: <value>` line before extraction, so downstream parsing is case-insensitive without requiring every project to migrate its prompt.
  - **Unanchored greps + prose colon.** A `RECOMMENDATION:` line containing `STATUS:BLOCKED` in free-text prose poisoned `grep "STATUS:"` — `tail -1` picked the recommendation, `sed` stripped up to the *last* `STATUS:` occurrence, and the captured value was `BLOCKED)` (closing paren of the parenthetical). The EXIT-CLEAN equality check at `on-stop.sh:607` then failed and the hook fell through to the no-progress branch, incrementing `consecutive_no_progress` instead of recognising clean exit. Every field-extraction grep is now anchored to `^[[:space:]]*` so prose mid-line cannot be selected. The brittle `grep -v "TESTS_STATUS\|END_RALPH"` and `grep -v "LINEAR_EPIC_DONE\|LINEAR_EPIC_TOTAL"` workarounds are removed — the line anchor makes them redundant.

### Tests

- 3 new regression tests in `tests/unit/test_on_stop_hook.bats`:
  - `PARSER-HARDENING: RECOMMENDATION prose containing 'STATUS:BLOCKED' does NOT poison the STATUS field` — replays the exact NLTlabsPE Loop-12 payload and asserts `status=BLOCKED` (not `BLOCKED)`) and that EXIT-CLEAN Grounds 2 fires (counter resets, state stays CLOSED).
  - `PARSER-HARDENING: lowercase linear_open_count / linear_done_count (PROMPT.md drift) parses correctly` — asserts `linear_open_count=0` and `linear_done_count=142` with all-lowercase field names in the input.
  - `PARSER-HARDENING: TESTS_STATUS does NOT bleed into STATUS field via unanchored grep` — defense regression after removing the legacy `grep -v` filter.

---

## [2.11.2] — 2026-04-30

### Removed

- **Per-iteration cost cap (`RALPH_COST_CAP_USD`).** Briefly added in 2.11.1 (unreleased to operators), then removed: the Anthropic API's monthly spend cap is the real safety net (already detected via exit code 4 → `monthly_api_spend_cap`), and a per-loop cap creates false-positive trips on legitimately large loops. The four files that reference it (`ralph_loop.sh` post-execution block, `ralph_monitor.sh` cost colouring, `templates/ralphrc.template` `# COST CAP` section, CLAUDE.md config list) all reverted.

---

## [2.11.1] — 2026-04-30

### Fixed

- **Routing-default regression (April 2026 incident).** `lib/complexity.sh:23` defaulted `RALPH_MODEL_ROUTING_ENABLED` to `false` while CLAUDE.md, RELEASE.md, and the 2.11.0 changelog all promised `true`. Projects that did not explicitly set the variable in `.ralphrc` had every loop pinned to `CLAUDE_MODEL` (Opus where set) at ~$57/loop, with no routing decisions logged to `.ralph/.model_routing.jsonl`. A second hardcoded `:-false` fallback in `ralph_loop.sh:2918` would have continued masking a fix to the lib alone. Both now default `true`. Two regression tests in `tests/unit/test_complexity.bats` lock the default in place — one verifies the lib-level default in a clean subshell, one exercises `ralph_select_model` end-to-end with the env var unset.

### Added

- **Startup routing-health visibility.** `ralph` now logs `Model routing: ENABLED/DISABLED` at startup and emits a `WARN` if `RALPH_MODEL_ROUTING_ENABLED=true` but `.ralph/.model_routing.jsonl` is more than an hour stale — the same signal that would have flagged the routing-default regression on day one.
- **Monitor dashboard routing-log decision count.** A `Routing log: N decisions` line surfaces routing-log volume; if the log is >1h stale while `loop_count` keeps incrementing, the line goes red with a "likely inert" warning. Read-only diagnostic — no behaviour change.

---

## [2.9.2] — 2026-04-29

### Changed

- **MCP probe default timeout** raised again from 15s to 30s. Cold-start cases where stdio MCP servers spawn child processes plus HTTP MCPs do auth round-trips can occasionally exceed 15s on the very first invocation; warm runs return in 1–2s so the higher default has no visible cost. Override via `RALPH_MCP_PROBE_TIMEOUT_SECONDS`.

---

## [2.9.1] — 2026-04-29

### Changed

- **MCP probe timeout** is now configurable via `RALPH_MCP_PROBE_TIMEOUT_SECONDS` (default `15`, was hardcoded `5`). The previous 5-second cap was too tight for setups with 5+ MCP servers — `claude mcp list` health-checks each server in turn, so machines with Drive/Calendar/Gmail/Linear/docs-mcp/tapps-mcp/tapps-brain regularly tripped the timeout and lost the prompt-side guidance for the reachable servers. The probe failure was cosmetic (Claude's own MCP loading is independent), but the lost guidance reduced the chance Claude reaches for `mcp__tapps-brain__*` etc. organically.

---

## [2.9.0] — 2026-04-29

### Added

- **TAP-589 LINOPT epic — Linear cache-locality optimizer.** End-to-end:
  - **TAP-590 (LINOPT-1)**: `templates/hooks/on-stop.sh` walks the JSONL session transcript after each loop, extracts edited file paths from Edit/Write/MultiEdit/NotebookEdit tool uses, dedupes/caps at 100, strips `CLAUDE_PROJECT_DIR` prefix, writes `.ralph/.last_completed_files` atomically (8 BATS tests).
  - **TAP-591 (LINOPT-2)**: new `lib/linear_optimizer.sh` with `linear_optimizer_run` entry point — fetches top-N open issues, scores by `Jaccard(last_completed_files, issue_body_paths) + 0.3 × shared-parent-dir bonus`, ralph-explorer (Haiku) fallback for top-3 priority issues with no body paths (cached at `.ralph/.linear_optimizer_cache.json`, capped at 3 calls/session), atomic write to `.ralph/.linear_next_issue` (5 BATS tests).
  - **TAP-592 (LINOPT-3)**: import-graph dependency demotion. New `import_graph_predecessors` helper in `lib/import_graph.sh`. Two-phase optimizer: phase-1 collects scored candidates, phase-2 walks `FILES_OWNED_BY_OPEN` map and demotes candidates that import another open issue's file. `RALPH_NO_DEP_DEMOTE=true` opts out (5 BATS tests).
  - **TAP-593 (LINOPT-4)**: `build_loop_context()` in `ralph_loop.sh` reads `.ralph/.linear_next_issue`, sanitizes to `[A-Z0-9a-z-]`, injects `LOCALITY HINT: <ID>` into Claude's `--append-system-prompt`. ralph-workflow skill step 0 instructs Claude to honor the hint and delete the file after use (2 BATS tests).
  - **TAP-594 (LINOPT-5)**: telemetry + 5 fail-loud safety rails — stale-hint cleanup, fail-loud on Linear API error (preserves existing hint), project-unset guard, opt-out guard, PID-based lock file with stale-lock auto-cleanup. Per-session JSONL telemetry at `.ralph/metrics/linear_optimizer_YYYY-MM.jsonl`. New `ralph --optimize-linear` CLI flag for manual reruns (6 BATS tests).
  - **TAP-595 (LINOPT-6)**: full epic spec at `docs/specs/epic-linear-mode-optimizer.md`, README + `templates/ralphrc.template` + CLAUDE.md updated.

### Fixed

- **TAP-1103**: `ralph --dry-run` (and other CLI flags) silently overridden by `.ralphrc` because `load_ralphrc()` ran AFTER arg parsing and re-sourced variables of the same name. Burned $5.81 in NLTlabsPE before being killed. Fix: parallel `_cli_*` capture for every flag with a config-file counterpart (`--dry-run`, `--no-continue`, `--session-expiry`, `--output-format`, `--auto-reset-circuit`, `--log-max-size`, `--log-max-files`), restored AFTER `load_ralphrc()` and `load_json_config()`. Final precedence is now CLI > env > .ralphrc/json > defaults — same shape as the existing `_env_*` block. 7 BATS tests in `tests/unit/test_cli_rc_precedence.bats`.

### Configuration

- New `.ralphrc` knobs (all defaulted):
  - `RALPH_NO_LINEAR_OPTIMIZE=false` — disable optimizer entirely
  - `RALPH_NO_DEP_DEMOTE=false` — skip phase-2 dependency demotion
  - `RALPH_OPTIMIZER_FETCH_LIMIT=20` — max issues fetched per run
  - `RALPH_OPTIMIZER_EXPLORER_MAX=3` — max ralph-explorer calls per session

---

## [2.8.3] — 2026-04-20

### Added
- **TAP-741**: Push-mode Linear counts via `RALPH_STATUS` — `linear_get_open_count` / `linear_get_done_count` read `linear_open_count` / `linear_done_count` from `.ralph/status.json`, written by the on-stop hook from Claude's RALPH_STATUS block; entries older than `RALPH_LINEAR_COUNTS_MAX_AGE_SECONDS` (default 900) abstain via the TAP-536 fail-loud path; `linear_check_configured` requires only `RALPH_LINEAR_PROJECT`. (OAuth-via-MCP is the only supported Linear-mode integration.)

### Fixed
- Monitor: repair zero-token / zero-cost display, staleness detection, and silent-UNKNOWN fallback
- MCP probe: use temp file + `--kill-after` to prevent probe hang on unresponsive servers
- `build_loop_context`: `tapps-mcp` guidance block is now injected unconditionally when the server is reachable (drops the stale `! ralph_task_is_docs_related` gate that silently suppressed the block on mixed docs/code loops); matches the documented design in CLAUDE.md

---

## [2.8.2] — 2026-04-20

### Added
- **SKILLS-INJECT-5**: `lib/skill_retro.sh` — friction signal detection: reads `status.json` and stream logs after each loop, identifies signals (permission denials, repeated stalls, test failures, tool errors), emits a structured JSON friction report
- **SKILLS-INJECT-6**: Retro apply in `lib/skill_retro.sh` — advisory mode by default (`RALPH_SKILL_AUTO_TUNE=false`); when enabled, installs ≤1 recommended skill per loop based on friction report; checksum-guard prevents overwriting user-modified skills
- **SKILLS-INJECT-7**: Periodic re-detection (`skill_retro_periodic_reconcile`) — re-runs Tier A project detection every N loops (default 10, `RALPH_SKILL_REDETECT_INTERVAL`) and reconciles installed skills against current project state
- **SKILLS-INJECT-8**: `record_skill_metric` / `ralph_show_skill_stats` in `lib/metrics.sh` — append skill events to `.ralph/metrics/skills.jsonl`; `ralph --stats` now includes a skill breakdown section

---

## [2.8.1] — 2026-04-20

### Added
- **SKILLS-INJECT-1–4**: Project skill detection, install, and PROMPT.md hints — `detect_tier_a_skills()` and `install_project_tier_a_skills()` in `lib/enable_core.sh`; `inject_skill_hints_into_prompt()` appends an "Available Skills" section to `.ralph/PROMPT.md` idempotently; 20 new BATS tests
- Session run-ID boundary tracking — `on-stop.sh` resets cost/token/MCP accumulators when run ID changes, preventing stale totals bleeding into a new session
- Monitor: Linear issue display with `(executing...)` fallback and MCP activity row (top-3 tools per loop by call count)

### Fixed
- **TAP-658**: Cap circuit breaker history at 200 entries (prevents jq OOM on long runs); atomic `mv` instead of `>` redirect
- **TAP-661**: Validate template hooks before and after copy in `ralph_upgrade_project.sh` — skip empty/syntax-invalid sources with WARN; write to tmp, `bash -n` verify, then atomic mv
- **TAP-662**: Track `_tokens_extracted` flag in `_extract_session_id()`; missing usage block emits `logger.warning` instead of silently recording $0 cost
- **TAP-659**: Replace sed-based JSON escape in `lib/notifications.sh` webhook with `jq --arg` — eliminates JSON injection vector
- **TAP-657**: Bump `actions/checkout` and `actions/setup-node` from v3 → v4 in `.github/workflows/test.yml`
- **TAP-656**: Remove corrupt duplicate hook entries from `.claude/settings.json`; add `tests/unit/test_settings_json.bats` (6 assertions) to guard against recurrence
- **TAP-730**: `ralph_upgrade_project.sh` now chmod u+w before overwriting read-only (555) hook/agent files
- Monitor: show cache% block when cache data present but tokens are zero
- Linear: tighten In Review rules — security bug fixes and hardening now default to Done; uncertainty defaults to Done (AC met) or In Progress, never In Review
- Signal trap cleanup now passes explicit 130/143 into `cleanup()` — stray loop iterations after `kill <pid>` eliminated
- `lib/tracing.sh`: build JSONL spans via `jq --arg` instead of shell interpolation; add jq validity check before appending

### Changed
- Upgrade Claude model IDs to April 2026 lineup — `claude-sonnet-4-6` (was `claude-sonnet-4-20250514`), `claude-opus-4-7` for LARGE/ARCHITECTURAL routing
- `templates/PROMPT.md`: RALPH:START/END marker support so `ralph-upgrade` can refresh only the managed section
- `templates/skills-local/ralph-workflow/SKILL.md`: step 6.5 deslop pass at epic boundaries via simplify skill; controlled by `RALPH_NO_DESLOP=true`
- `.mcp.json`: tapps-brain MCP server registered for this project

---

## [2.7.2] — 2026-04-20

### Fixed
- Linear workflow: codify In Review as rare/hard-blocker-only with four valid reasons; unmerged branches stay In Progress for self-retry
- Signal trap: SIGINT/SIGTERM pass explicit 130/143 exit codes; stray loop iteration after kill eliminated
- CI: remove dormant PR review workflows (`claude.yml`, `claude-code-review.yml`, `opencode-review.yml`) with unconfigured secrets

---

## [2.7.1] — 2026-04-20

Hardening release. 14 fix commits on top of 2.7.0 — no new features, all security/reliability/CI fixes surfaced by the internal code-review sweep.

### Security
- **TAP-622**: Stop splicing `fix_plan.md` content into an awk-driven shell command in `plan_section_hashes` — fixes shell injection via crafted task titles
- **TAP-623**: `protect-ralph-files.sh` now guards `.claude/` (agents, hooks, settings) in addition to `.ralph/`, so the loop cannot edit its own control plane
- **TAP-624**: Close multiple destructive-command bypasses in `validate-command.sh` whitelist
- **TAP-633**: Stop interpolating unquoted `project_root` into the `python3 -c` body in `lib/import_graph.sh` — fixes Python heredoc command injection
- **TAP-641**: `ralph.ps1` now passes arguments via argv splat instead of `bash -c` interpolation — fixes command injection via whitespace-containing args
- **TAP-643**: Replace in-place `sed` with a jq-based patch + backup when adjusting `.claude/settings.json` — prevents silent JSON corruption

### Fixed
- **TAP-621**: SDK token usage is now read from `obj["usage"]` (correct JSON level), re-enabling `CostTracker` and `TokenRateLimiter`
- **TAP-625**: `FileStateBackend` text writers all go through atomic write — SIGTERM races no longer corrupt rate-limit/counter state
- **TAP-628**: `plan_optimizer._validate_equivalence` actually checks the invariant (previously compared `sorted(same objects)` against itself)
- **TAP-630**: `CircuitBreaker` cooldown uses tz-aware datetime — fixes `time.mktime` / `tm_gmtoff` mis-parse on macOS/BSD
- **TAP-636**: `install.sh` enables `pipefail` on the sed|tr pipeline — prevents silent truncation of `ralph_loop.sh` on failure
- **TAP-638**: `uninstall.sh` lists stay in sync with `install.sh` — removes the dangling `ralph-upgrade-project` wrapper
- **TAP-646**: `ralph-tester` model matches docs (sonnet, not haiku); `ralph` / `ralph-architect` use valid `Agent(...)` tool schema
- **TAP-649**: `update-badges.yml` surfaces test failures instead of masking with `|| true`, and sanitizes `grep -c` output
- **TAP-651**: `lib/metrics.sh` and `lib/github_issues.sh` now build JSON/JSONL with `jq -n` instead of manual concat — no more JSON injection / corruption via field content
- Close missing `fi` branch introduced by the TAP-643 jq-patch refactor

---

## [2.7.0] — 2026-04-19

### Added
- **TAP-575**: Ralph-owned canonical skill library — `templates/skills/global/` now ships 5 Tier S skills (`search-first`, `tdd-workflow`, `simplify`, `context-audit`, `agentic-engineering`), each with Ralph-hardened `SKILL.md` + concrete loop examples under `examples/`. Every skill carries the Ralph frontmatter standard (name/description/version/ralph/ralph_version_min/attribution/user-invocable/disable-model-invocation/allowed-tools) and the four-section contract (When to invoke, Ralph-specific guidance, sub-agent integration, Exit criteria). 13 BATS cases in `tests/unit/test_skill_frontmatter.bats` + `test_skill_content.bats` enforce the schema so the retro/auto-tune loop (TAP-578/579) can rely on a stable shape. Combined with TAP-574, running `install.sh` now seeds `~/.claude/skills/` with the full Ralph baseline.
- **TAP-574**: Global Claude skill baseline via `install.sh` — new `lib/skills_install.sh` syncs `templates/skills/global/<name>/` into `~/.claude/skills/<name>/` with `.ralph-managed` sidecar for idempotency. Three install cases: fresh copy + sidecar; re-install refreshes only files whose hash still matches Ralph's baseline (WARN on user-modified); user-authored dirs without a sidecar are skipped. `uninstall.sh` and `install.sh uninstall` remove only Ralph-owned files, preserving user edits. `ralph-upgrade` picks up new baselines automatically. 13 BATS cases in `tests/unit/test_skills_install.bats`.

### Fixed
- **TAP-538**: Sync `.ralph/hooks/` with templates and harden circuit breaker self-healing — corrupt `.circuit_breaker_state` is now auto-reinitialized to `CLOSED` instead of crashing the loop; `ralph-doctor` warns on hook drift vs templates
- **TAP-537**: Unmask integration tests — `npm run test:integration` is now a hard-failing CI gate; deterministic eval suite added to required CI; stale version assertion, missing mock exec bit, and missing fixture repaired
- **TAP-535**: Atomic state writes and `pipefail` — all counter/state-file writes go through `atomic_write()` helper (write→fsync→mv); `set -o pipefail` enabled after library sourcing; Bash < 4 rejected at startup
- **TAP-534/533/536**: Security — sed/eval injection fixes in `ralph_loop.sh`; Linear API backend now fail-loud (returns non-zero + stderr on any error, never silently defaults to "complete")

---

## [2.6.0] — 2026-04

### Added
- **Linear task backend** (`RALPH_TASK_SOURCE=linear`) — replaces `fix_plan.md` reads with Linear via the Linear MCP plugin (OAuth); requires `RALPH_LINEAR_PROJECT`; fail-loud on stale counts (TAP-536 pattern)
- **`ralph-upgrade-project`** — propagate runtime files (hooks, templates) to existing managed projects without re-running full setup

### Changed
- Resolved 14 open issues; fixed 24 pre-existing test failures from integration gate

---

## [2.5.0] — 2026-03

### Added
- **Structured hook logging** — `on-stop.sh`, `on-session-start.sh`, `on-task-completed.sh` emit structured JSON lines for observability
- **Import graph + plan optimizer** (`lib/import_graph.sh`, `lib/plan_optimizer.sh`) — auto-reorder `fix_plan.md` tasks by dependency; Python SDK counterparts in `sdk/ralph_sdk/import_graph.py` and `sdk/ralph_sdk/plan_optimizer.py`
- **Episodic memory** (`sdk/ralph_sdk/memory.py`) — cross-session keyword-indexed failure/success recall with age decay
- **Task complexity classifier** (`sdk/ralph_sdk/complexity.py`, `lib/complexity.sh`) — 5-level TRIVIAL→ARCHITECTURAL classifier feeds dynamic model routing

### Changed
- Version bumped to 2.5.0; documentation updated

---

## [2.4.0] — 2026-02

### Added
- **Plan optimization epic** — automatic `fix_plan.md` task reordering at session start (`RALPH_NO_OPTIMIZE` disables); vague task file resolution via `ralph-explorer` (Haiku)
- **`RALPH_NO_OPTIMIZE`**, **`RALPH_NO_EXPLORER_RESOLVE`**, **`RALPH_MAX_EXPLORER_RESOLVE`** config variables

### Fixed
- `CLAUDE_CODE_CMD` from `.ralphrc` now respected in agent mode
- `ALLOWED_TOOLS` works correctly in agent mode

### Changed
- Default `MAX_CALLS_PER_HOUR` raised from 100 to 200 (v2.4.1 patch)

---

## [2.3.0] — 2026-01

### Added
- **Phase 14-17 features**: OpenTelemetry tracing (`lib/tracing.sh`), Docker sandbox v2 with rootless + gVisor support (`lib/sandbox.sh`), cross-session memory (`lib/memory.sh`), cost-aware routing with token rate limiting (`sdk/ralph_sdk/cost.py`), adaptive timeout with percentile tracking (`sdk/ralph_sdk/circuit_breaker.py`)
- **Continue-As-New** (`CTXMGMT-3`) — Temporal-inspired session reset after `RALPH_MAX_SESSION_ITERATIONS` (default 20) or `RALPH_MAX_SESSION_AGE_MINUTES` (default 120)
- **Completion indicator decay** (SDK-SAFETY-3) — stale "done" signals reset when productive work occurs without `EXIT_SIGNAL: true`
- **MCP server process cleanup** (`ralph_cleanup_orphaned_mcp`) — kills orphaned MCP grandchild processes after each CLI invocation; Windows uses PowerShell CIM; Linux/macOS uses pgrep/kill
- **Upstream sync epic** (USYNC) — question detection, stuck-loop detection, CB permission denial, heuristic exit suppression, tmux sub-agent progress

### Fixed
- `jq` bootstrap in install path
- `ralph-doctor` PATH resolution
- WSL PowerShell auto-patching — bare `powershell` hooks auto-patched to `powershell.exe`

---

## [2.2.0] — 2025-12

### Added
- **SDK v2.1.0** — `ContinueAsNewState`, `plan_optimizer`, `import_graph`, `memory`, `complexity` modules; all models Pydantic v2; fully async with `run_sync()` wrapper
- **LOGFIX epic** — 8 production bug fixes from log analysis

### Fixed
- Block `git commit --trailer "Made-with: Cursor"` short `--no-verify` flag in hooks

---

## [2.0.0] — 2025-11

### Added
- **Python SDK v2.0.0** — full async agent, Pydantic v2 models, pluggable `RalphStateBackend` (File + Null), `EvidenceBundle` output, TaskPacket conversion, `CircuitBreaker` class, `ContextManager`, `CostTracker`, `MetricsCollector`, `JsonlMetricsCollector`
- **Sub-agents** — ralph-explorer (Haiku), ralph-tester (Sonnet, worktree-isolated), ralph-reviewer (Sonnet), ralph-architect (Opus)
- **Epic-boundary QA deferral** — ralph-tester and ralph-reviewer skipped mid-epic; mandatory before `EXIT_SIGNAL: true`
- **Speed optimizations** (v1.8.4+) — `bypassPermissions`, `effort: medium`, disabled PostToolUse hooks for throughput; increased batch sizes to 8 SMALL / 5 MEDIUM
- **FAILURE.md / FAILSAFE.md / KILLSWITCH.md** — failure protocol documents with audit logging
- **Hook-based response analysis** — `on-stop.sh` writes `status.json`; loop reads from it instead of parsing raw CLI output; `response_analyzer.sh` removed
- **File protection hooks** — `protect-ralph-files.sh` and `validate-command.sh` as PreToolUse hooks replace `file_protection.sh` module

### Changed
- **Phase 14 modernization** — `lib/metrics.sh`, `lib/notifications.sh`, `lib/backup.sh`, `lib/github_issues.sh`, `lib/sandbox.sh`, `lib/tracing.sh`, `lib/complexity.sh`, `lib/memory.sh` added
- `response_analyzer.sh` removed (replaced by hook)
- `file_protection.sh` removed (replaced by hooks)

---

## [1.9.0] — 2025-10

### Added
- **Cost-aware routing** — task complexity classifier, dynamic model routing, token rate limiting (Phase 8)
- **Task batching** — up to 8 SMALL / 5 MEDIUM tasks per invocation

---

## [1.8.x] — 2025-10

### Added
- **`--live` JSONL pipeline** — real-time streaming with tool names, elapsed time, sub-agent events, error extraction
- **Windows / Git Bash support** — MINGW detection, PowerShell MCP cleanup, WSL2 filesystem resilience
- **WSL version divergence detection** — compares WSL vs Windows `~/.ralph/` versions at startup
- **Log rotation** — `rotate_ralph_log()` on size threshold; `cleanup_old_output_logs()` beyond file count limit
- **Dry-run mode** (`--dry-run` / `DRY_RUN=true`) — simulates a loop without API calls
- **`ralph-enable` / `ralph-enable-ci`** — interactive and non-interactive setup wizards
- **`ralph-import`** — PRD/spec → Ralph task conversion
- **`ralph-doctor`** — dependency verification
- **`ralph-migrate`** — `.ralph/` directory migration

### Fixed
- Stream filter suppresses raw JSONL leaking to terminal in `--live` mode
- SIGTERM/SIGINT treated as clean stops, not crashes
- Compound command pattern support (`&&`, `||`, `;` in `ALLOWED_TOOLS`)

---

## [1.2.0] — 2025-10 (Phase 5)

### Added
- Stream parser v2 — JSONL primary path, multi-result filtering, unescape RALPH_STATUS
- WSL reliability polish — temp file cleanup, child process cleanup
- Circuit breaker decay — sliding window failure detection, session reinitialization

---

## [1.0.0] — 2025-09 (Initial)

### Added
- Core autonomous loop (`ralph_loop.sh`) — dual-condition exit gate, four-layer rate limit detection, session continuity
- Circuit breaker — three-state CLOSED/HALF_OPEN/OPEN with cooldown auto-recovery
- `ralph-setup` — project scaffolding with `.ralph/` directory structure
- `ralph-monitor` — live tmux dashboard
- BATS test suite — unit and integration tests via `npm test`
