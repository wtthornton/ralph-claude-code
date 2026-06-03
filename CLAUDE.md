---
title: Claude Code guidance for the Ralph repository
description: Contributor-facing reference that preserves Ralph's hard-won invariants for any AI agent working in this codebase. Do not introduce changes that contradict these without a design discussion.
audience: [claude-code-agent, contributor]
diataxis: reference
last_reviewed: 2026-04-23
---

# CLAUDE.md

This file provides guidance to [Claude Code](https://claude.ai/code) when working with code in this repository. Human contributors should read [CONTRIBUTING.md](CONTRIBUTING.md) first; this file documents the **invariants** that must be preserved across any change.

Quick navigation:

- **Architecture overview:** [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- **Design decisions (ADRs):** [docs/decisions/](docs/decisions/)
- **Terminology:** [docs/GLOSSARY.md](docs/GLOSSARY.md)
- **Operations + troubleshooting:** [docs/OPERATIONS.md](docs/OPERATIONS.md) • [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)
- **Testing:** [TESTING.md](TESTING.md)
- **Release process:** [RELEASE.md](RELEASE.md)

## Repository Overview

Ralph is an autonomous AI development loop for Claude Code. It repeatedly invokes the Claude Code CLI, tracks progress, detects completion, and manages rate limits and error recovery. The core loop and tooling are **bash/shell**; the optional Agent SDK (`sdk/`) is **Python 3.12+**.

## Commands

```bash
# Install dependencies (BATS testing framework)
npm install

# Run all tests
npm test

# Run unit or integration tests only
npm run test:unit
npm run test:integration

# Run a single test file
bats tests/unit/test_cli_parsing.bats

# Install Ralph globally (~/.local/bin/ and ~/.ralph/)
./install.sh

# Uninstall
./uninstall.sh
```

## Architecture

### Main Scripts (root)

- **ralph_loop.sh** (~2300 lines) — Core autonomous loop. Reads instructions, executes Claude Code CLI, tracks progress, evaluates completion, repeats. Manages rate limiting, session continuity, circuit breaker state, live-stream extraction, and pre-analysis output normalization (`ralph_prepare_claude_output_for_analysis (calls ralph_extract_result_from_stream)`).
- **ralph_monitor.sh** — Live tmux dashboard showing loop count, API usage, and recent logs.
- **setup.sh** — Creates new Ralph-managed projects with `.ralph/` directory structure.
- **ralph_import.sh** — Converts PRD/specification documents into Ralph task format using Claude Code CLI with JSON output.
- **ralph_enable.sh** — Interactive wizard to enable Ralph in existing projects. Detects project type, imports tasks from beads/GitHub/PRD sources.
- **ralph_enable_ci.sh** — Non-interactive version of ralph_enable for CI/automation (JSON output, exit codes 0/1/2).
- **create_files.sh** — Bootstrap script that creates the Ralph system files.

### Library Modules (lib/)

| Module | Purpose |
|--------|---------|
| `circuit_breaker.sh` | Simplified three-state pattern (CLOSED/HALF_OPEN/OPEN) — reads state written by `on-stop.sh` hook, handles cooldown/auto-recovery |
| `enable_core.sh` | Shared logic for ralph_enable and ralph_enable_ci (idempotency, detection, template generation) |
| `task_sources.sh` | Task import from beads, GitHub Issues, or PRD documents. Includes deduplication, normalization, per-source/total caps |
| `wizard_utils.sh` | Interactive prompt utilities (confirm, select, text input) |
| `date_utils.sh` | Cross-platform date/epoch utilities |
| `timeout_utils.sh` | Cross-platform timeout command detection (`timeout` on Linux, `gtimeout` on macOS) |
| `metrics.sh` | Lightweight metrics — monthly JSONL in `.ralph/metrics/`, `ralph --stats` summary (Phase 8) |
| `notifications.sh` | Local notifications — terminal, OS native, webhook POST, sound (Phase 8) |
| `backup.sh` | State backup/rollback — auto-snapshots, `ralph --rollback`, max 10 backups (Phase 8) |
| `github_issues.sh` | GitHub Issue integration — import, assess, filter, batch, lifecycle (Phase 10) |
| `sandbox.sh` | Docker sandbox — `ralph --sandbox`, container management, signal forwarding (Phase 11). V2: rootless Docker detection, `--network none` egress control, gVisor runtime support, resource usage reporting (Phase 14) |
| `tracing.sh` | OpenTelemetry traces — GenAI Semantic Conventions, JSONL OTLP format, secret sanitization (Phase 14) |
| `complexity.sh` | Task classification + model routing — Task-type classifier (docs/tools/code/arch) with QA failure escalation. `ralph_classify_task_type` for type-aware routing (Phase 14+), `ralph_select_model` for model selection (type-based + 3-fail opus escalation), per-routing logging to `.model_routing.jsonl` |
| `qa_failures.sh` | QA failure state tracking — persistent per-issue failure counters in `.ralph/.qa_failures.json`. Incremented on QA failure, reset on PASSING. Read by router to escalate to Opus after 3+ consecutive failures on same issue. |
| `memory.sh` | Cross-session memory — episodic (what worked/failed), semantic (project index), decay/pruning (Phase 14) |
| `import_graph.sh` | AST-based file dependency graph — Python `ast`, JS/TS `madge`/grep fallback. Cached in `.ralph/.import_graph.json` with mtime staleness detection. Async background rebuild, incremental invalidation via hooks. (PLANOPT epic) |
| `plan_optimizer.sh` | Fix plan task reordering — parses fix_plan.md, resolves vague tasks via ralph-explorer (Haiku), detects dependencies via import graph + explicit metadata + phase convention, orders via Unix `tsort`, validates semantic equivalence before atomic write. Runs at session start for changed sections only. (PLANOPT epic) |
| `linear_optimizer.sh` | Linear task cache-locality optimizer (LINOPT-2 / TAP-591). `linear_optimizer_run` runs at session start to score open issues. **Two execution paths**: (1) **direct-API mode** — when `LINEAR_API_KEY` is set the bash function fetches the top-N open issues itself, scores them via `_optimizer_score_jaccard`, and atomically writes `.ralph/.linear_next_issue`; (2) **OAuth-via-MCP mode** (the only mode operators actually run today) — the bash function short-circuits at the `LINEAR_API_KEY` guard, and the **`ralph-coordinator` agent's MODE=brief step 4** does the locality scoring instead, using `mcp__plugin_linear_linear__list_issues` and writing the same `.ralph/.linear_next_issue` hint file. Consumer (`build_loop_context()` → `LOCALITY HINT:`) is identical for both paths. Guards: `RALPH_NO_LINEAR_OPTIMIZE=true`, `.ralph/.linear_optimize_disabled` sentinel (coordinator-side opt-out), missing project config. |
| `linear_backend.sh` | Linear task backend — `linear_get_open_count`, `linear_get_done_count`, `linear_check_configured`. Used when `RALPH_TASK_SOURCE=linear`. **OAuth-via-MCP is the only supported mode**: counts are read from `.ralph/status.json`, written by the on-stop hook from Claude's `RALPH_STATUS` block (TAP-741). Entries older than `RALPH_LINEAR_COUNTS_MAX_AGE_SECONDS` (default 900) abstain via the TAP-536 fail-loud path so a stale count cannot trip a false `plan_complete` exit. Iteration 1 has no prior hook write so it abstains (logged INFO, not WARN); iteration 2+ reads fresh counts. Task selection happens entirely via the Linear MCP — Claude lists, picks, and updates issues using `mcp__plugin_linear_linear__*` tools. `linear_check_configured` requires only `RALPH_LINEAR_PROJECT`. |
| `skills_install.sh` | Global Claude skill install/uninstall with `.ralph-managed` sidecar manifest (TAP-574). `skills_install_global` syncs `templates/skills/global/<name>/` into `~/.claude/skills/<name>/` idempotently: fresh dirs get a copy + sha256 manifest; dirs with a matching sidecar refresh only Ralph-owned files and WARN on user-modified ones; dirs without a sidecar are left alone (user-authored). `skills_uninstall_global` is symmetric — removes only files whose current hash matches the manifest, preserving user edits. Sourced by `install.sh` in `main`/`upgrade`/`uninstall` and by `uninstall.sh`. Story 2 (TAP-575) will populate `templates/skills/global/`. **Adopt mode (`RALPH_SKILLS_ADOPT=1`)**: closes the pre-sidecar adoption gap — a Ralph-shipped skill installed before the sidecar mechanism existed has no manifest, so the no-sidecar case skips it forever and it drifts. With the env var set, a no-sidecar dir whose name matches a shipped skill (the installer is only ever called with a real `src`, so the name is provably Ralph's) is moved to `~/.claude/skills/.ralph-backup/<name>-<ts>-<pid>/` and re-installed fresh + sidecar. Opt-in + reversible (stow `--adopt` model); the default never auto-clobbers a name collision. `ralph-doctor` flags orphaned no-sidecar copies and prints the remediation. |
| `skill_retro.sh` | Skill friction detection and retro apply (SKILLS-INJECT-5/6/7). `skill_retro_detect_friction` reads `status.json` and stream logs after each loop, identifies friction signals (permission denials, repeated stalls, test failures, tool errors), and emits a structured JSON friction report. `skill_retro_apply` acts on the report — advisory mode (`RALPH_SKILL_AUTO_TUNE=false`) logs recommendations; auto-tune mode installs ≤1 skill per call from `~/.claude/skills/`. `skill_retro_periodic_reconcile` re-runs Tier A project detection every N loops (default 10, `RALPH_SKILL_REDETECT_INTERVAL`) and installs newly-applicable skills. |
| `branch_cleanup.sh` | Squash-merged branch janitor (TAP-1880, parent epic TAP-1878). `ralph_cleanup_merged_branches` is invoked once per Ralph invocation from `main()`; scans local branches matching `RALPH_BRANCH_PREFIX` (default `tap-`), authorizes deletion only on `git cherry main <branch>` evidence (the squash-merge-aware primitive — `git branch --merged` does NOT detect squash-merges), and deletes both local and origin copies. Safety envelope: `RALPH_BRANCH_CLEANUP_PROTECTED` glob list (default `main:master:develop:release/*`), `RALPH_BRANCH_CLEANUP_MIN_AGE_HOURS` (default 24), currently-checked-out branch + `RALPH_CURRENT_BRANCH` skip. All failures (network, permission, missing remote) are WARN-only; the orchestrator always returns 0 so a botched cleanup never trips the CB. Pairs with the prompt-side fix in TAP-1879 as the harness-side safety net for branches the LLM forgot to delete. |
| `pending_merges.sh` | Async PR-merge queue (T5 / 2.16.0, opt-in via `RALPH_ASYNC_MERGE=true`, default OFF). State file: `.ralph/pending-merges.json` (schema v1). API: `pending_merges_enabled`, `pending_merges_init`, `pending_merges_add <pr> <ticket> <branch>` (returns 2 at cap), `pending_merges_count`, `pending_merges_poll` (called from `main()` BEFORE the coordinator each loop — checks `gh pr checks` per open entry, merges greens via `gh pr merge --squash --delete-branch`, marks reds failed), `pending_merges_get_merged`, `pending_merges_surface_failed`, `pending_merges_drop <pr>`, `pending_merges_force_drain` (called when queue hits cap). Envelope: `RALPH_ASYNC_MERGE_MAX_PENDING` (default 5), `RALPH_ASYNC_MERGE_DRAIN_RETRIES` (default 6), `RALPH_ASYNC_MERGE_DRAIN_SLEEP_SECONDS` (default 30). See [docs/decisions/0007-async-pr-merge-via-pending-queue-vs-github-merge-queue.md](docs/decisions/0007-async-pr-merge-via-pending-queue-vs-github-merge-queue.md) for design rationale. 12 BATS cases in `tests/unit/test_pending_merges.bats`. |
| `stream_filter.awk` | Live-mode NDJSON stream filter (TAP-1470). Extracted from `execute_claude_code`'s heredoc — invoked via `awk -f "$SCRIPT_DIR/lib/stream_filter.awk"` from `exec_run_live`. Compact display: tool calls with parameters, per-tool elapsed time, sub-agent events, error indicators (`is_error:true`), summary stats line at end. Text-block buffering with metadata-noise suppression (session_id, uuid, parent_tool_use_id) and 200-char truncation. 13 BATS tests in `tests/unit/test_stream_filter.bats` cover each event type via 9 NDJSON fixtures. |
| `exec_helpers.sh` | Helpers extracted from `execute_claude_code` across the TAP-541 epic + follow-ups (TAP-1470, 1473–1477, 1484). Reduced the function from **920 → 230 lines** (75%). Nine helpers: (1) `exec_build_live_argv` — pure `CLAUDE_CMD_ARGS → LIVE_CMD_ARGS` transform (`--output-format json` → `stream-json`, `--verbose --include-partial-messages` append); (2) `exec_run_live` — foreground/live runner wiring `awk -f stream_filter.awk` to the Claude CLI subprocess + post-pipeline housekeeping (stats, WSL2/9P session-id retry); (3) `exec_run_background` — backgrounded runner with progress-spinner monitoring (returns sentinel 99 on early-launch failure → caller `return 1`); (4) `exec_classify_api_error` — unified `is_error:true` classifier (returns 0/1/4 for not-error / generic / monthly-cap; runs BEFORE exit-code branching to handle Issue #134/#199); (5) `exec_track_deferred_tests` — `CONSECUTIVE_DEFERRED_TEST_COUNT` state machine, trips CB at 2× `CB_MAX_DEFERRED_TESTS` and `break`s the main loop; (6) `exec_handle_timeout` — exit-code-124 handler with productive (return 0) vs unproductive (return 1, CB-trip at `MAX_CONSECUTIVE_TIMEOUTS` → 3) split; (7) `exec_detect_rate_limit` — 4-layer Anthropic 5-hour cap + Extra Usage detection, filters echoed `tool_result` / `tool_use_id` lines to avoid false positives (returns 0/2); (8) `exec_post_run_coordinator` — coordinator post-run state machine combining TAP-917 debrief decision, TAP-923 `.coordinator_block` flag, TAP-924 task-boundary cleanup; enforces the ordering invariant (debrief reads `brief.json` BEFORE cleanup wipes it); (9) `exec_detect_output_errors` — 2-stage error pattern detection (Stage 1 filters JSON field names, Stage 2 greps for `Error:` / `Exception` / `Fatal` / `FATAL` markers). Each helper has dedicated BATS coverage under `tests/unit/test_exec_*.bats` (51 cases total). |
| ~~`response_analyzer.sh`~~ | Removed — response analysis handled by `on-stop.sh` hook → `status.json` |
| ~~`file_protection.sh`~~ | Removed — file protection handled by PreToolUse hooks |

### SDK (sdk/) — v2.1.0

Python Agent SDK for dual-mode operation. All models are **Pydantic v2 BaseModels**. The agent loop is **fully async** with a `run_sync()` wrapper for CLI. State I/O goes through a **pluggable state backend** (`FileStateBackend` default, `NullStateBackend` for testing/embedding).

| Module | Purpose |
|--------|---------|
| `ralph_sdk/agent.py` | Async agent class — `RalphAgent`, `run_sync()` wrapper, run-loop helpers (`_execute_iteration`, `_check_*`, `_initialize_run`, `_finalize_result`), session lifecycle, Claude CLI orchestration. Standalone models live in `agent_models.py` and are re-exported here for the public import surface. |
| `ralph_sdk/agent_models.py` | Standalone models + helpers split out of `agent.py` (TAP-1515): `TaskInput` (frozen), `TaskResult`, `ProgressSnapshot`, `CancelResult`, `DecompositionHint`, `IterationRecord`, `ContinueAsNewState`, `TracerProtocol`, `RalphAgentInterface`, `compute_adaptive_timeout`, `detect_decomposition_needed`. |
| `ralph_sdk/config.py` | Pydantic configuration — validation ranges, .ralphrc/.json/env precedence chain. Includes cost, safety, context, lifecycle, and adaptive timeout settings. |
| `ralph_sdk/status.py` | Pydantic status models — RalphStatus, CircuitBreakerState, WorkType/RalphLoopStatus/ErrorCategory enums |
| `ralph_sdk/state.py` | Pluggable state backend — RalphStateBackend Protocol (18 methods), FileStateBackend (async aiofiles), NullStateBackend (in-memory). Includes session metadata, history, and continue-as-new state. |
| `ralph_sdk/parsing.py` | 3-strategy response parser — JSON fenced block → JSONL result → text fallback. Includes `extract_files_changed()` from tool use records and `detect_permission_denials()`. |
| `ralph_sdk/circuit_breaker.py` | Active circuit breaker — sliding window failure detection, no-progress tracking, cooldown recovery. V2: FastTripDetector, DeferredTestDetector, ConsecutiveTimeoutDetector (Phase 17). |
| `ralph_sdk/context.py` | Context management — ContextManager (progressive fix_plan trimming), PromptParts (stable prefix/dynamic suffix), PromptCacheStats, token estimation (Phase 17). |
| `ralph_sdk/cost.py` | Cost intelligence — CostTracker (per-model pricing, budget alerts), select_model() (complexity-based routing with retry escalation), TokenRateLimiter (hourly window) (Phase 17). |
| `ralph_sdk/metrics.py` | Metrics collection — MetricsCollector Protocol, JsonlMetricsCollector (monthly JSONL), NullMetricsCollector, MetricEvent model (Phase 17). |
| `ralph_sdk/converters.py` | TaskPacket conversion — TaskPacketInput/IntentSpecInput mirror models, complexity→max_turns, trust→permissions |
| `ralph_sdk/evidence.py` | EvidenceBundle output — test/lint extraction (pytest/jest/BATS/ruff/eslint), JSON round-trip |
| `ralph_sdk/tools.py` | Custom tools — ralph_status, ralph_rate_check, ralph_circuit_state, ralph_task_update |
| `ralph_sdk/complexity.py` | 5-level task classifier (TRIVIAL→ARCHITECTURAL) — annotation overrides, keyword scoring, file count, retry escalation. Feeds into `cost.select_model()`. |
| `ralph_sdk/memory.py` | Cross-session episodic + semantic memory — pluggable `MemoryBackend` protocol, keyword retrieval with failure bias, age decay, project index auto-detection. |
| `ralph_sdk/import_graph.py` | AST-based Python + regex JS/TS file dependency graph — `CachedImportGraph` with JSON caching, staleness detection, cross-platform path normalization. |
| `ralph_sdk/plan_optimizer.py` | Fix plan task reordering — 3-layer dependency detection (import graph → metadata → phase), Kahn's toposort, secondary sort (module/phase/size), semantic equivalence validation, atomic write. Auto-runs in `RalphAgent.run()`. |
| `ralph_sdk/versions.py` | Build-time version manifest reader — `get_versions()` returns all component versions from `version.json`. |
| `ralph_sdk/__main__.py` | CLI entry point — `ralph --sdk` or `python -m ralph_sdk` (uses run_sync()) |

### Key Design Patterns

**Dual-condition exit gate**: Loop exit requires BOTH `completion_indicators >= 2` (NLP heuristics) AND Claude's explicit `EXIT_SIGNAL: true` in the RALPH_STATUS block. This prevents premature exits when Claude says "done" mid-phase.

**Pre-flight empty-plan check (PREFLIGHT-EMPTY-PLAN)**: `should_exit_gracefully()` in [ralph_loop.sh:1408](ralph_loop.sh#L1408) runs at the top of every iteration *before* Claude is invoked. When `RALPH_TASK_SOURCE=file`, it greps `fix_plan.md` for unchecked `- [ ]` items; if zero, it short-circuits with `plan_complete` and exits cleanly — no Claude call is made. Same logic applies to the Linear branch via `linear_get_open_count` (with TAP-536 fail-loud: API errors **abstain** rather than treat unknown as zero, so a transient outage cannot trip a false `plan_complete`). Without this check, an empty plan cost 3 wasted Claude calls per launch before the no-progress CB tripped with a misleading `stagnation_detected` reason. Both `grep -c` reads in this function are sanitized via `tr -cd '0-9'` to neutralize the `grep -c | echo "0"` pitfall (see EXIT-CLEAN below).

**EXIT-CLEAN branch in `on-stop.sh` (templates/hooks/on-stop.sh)**: A 4th branch in the CB-update logic — between `has_permission_denials` and the no-progress fallback — recognizes `EXIT_SIGNAL: true` paired with `STATUS: COMPLETE` *or* `STATUS: BLOCKED` as a *clean* exit signal even when `files_modified=0` and `tasks_completed=0`. Two grounds map onto this branch, both documented in the ralph-workflow skill's "EXIT_SIGNAL gate" section:

- **Grounds 1 — `STATUS: COMPLETE`** (plan done): an end-of-campaign loop where Claude correctly reports "all done, exit." Without the bypass these get classified as no-progress (because no files changed) and consecutive empty-plan loops trip the breaker on the same signal Claude is using to ask for shutdown. Defense in depth for cases the pre-flight check can't catch (e.g., the last task is completed *during* a Claude invocation, leaving the plan empty by the next iteration).
- **Grounds 2 — `STATUS: BLOCKED`** (whole queue blocked): every open Linear issue carries a `blocked:foo` label / every fix_plan task depends on credentials/upstream/humans Claude cannot resolve, so there is genuinely nothing actionable to pick. Without the bypass, NLTlabsPE-shaped projects whose entire backlog is gated on AgentForge or NLTWeb would burn 3 Claude calls then trip the no-progress breaker on what is actually a correct "nothing to do right now" assessment. The skill's contract requires Claude to actually walk the queue before emitting Grounds 2 — single-task blockers stay `EXIT_SIGNAL: false` so they keep counting toward the CB threshold.

`STATUS: BLOCKED` paired with `EXIT_SIGNAL: false` (single-task block, queue may still have actionable work) does **not** hit this branch — it falls through to no-progress so consecutive single-task blocks still trip the CB and surface visibility to the operator. Tests `tests/unit/test_on_stop_hook.bats:142-205` cover all four corners (true/false × COMPLETE/BLOCKED).

**`grep -c | echo "0"` pitfall in shell hooks**: `grep -c PATTERN <<< "text"` exits 1 with stdout `"0"` when there's no match, so the idiom `count=$(grep -c PAT 2>/dev/null || echo "0")` produces `"0\n0"` — two zeros — which then crashes bash arithmetic AND injects a stray `0\n` into any heredoc that interpolates the value. In `on-stop.sh` this corrupted `status.json` (`"permission_denial_count": 0\n0`), causing every downstream `jq` read in `ralph_loop.sh` to fall back to defaults (`exit_signal` silently became `"false"`, `.exit_signals.completion_indicators` never grew, dual-condition gate never fired). Fix: pipe through `tr -cd '0-9'` and apply `${var:-0}` before any arithmetic. The template hook has this fix; older project hooks need `ralph-upgrade` to sync.

**Four-layer API limit detection**: (1) Timeout guard (exit code 124), (2) Structural JSON `rate_limit_event` parsing, (3) Filtered text fallback on last 30 lines, (4) Extra Usage quota detection. Layers 3-4 filter out echoed project file content to avoid false positives.

**Circuit breaker auto-recovery**: OPEN state is not terminal — after a cooldown period (default 30 min) it transitions to HALF_OPEN, then back to CLOSED on progress. `CB_AUTO_RESET=true` bypasses cooldown for unattended operation.

**Session continuity**: Claude session IDs persist in `.ralph/.claude_session_id` with 24-hour expiration. Sessions auto-reset on circuit breaker open, manual interrupt, or `is_error: true` API responses.

**File protection**: Two layers — (1) the agent file `.claude/agents/ralph.md` `disallowedTools:` blocklist prevents destructive bash patterns and `tools:` allowlists the surface; (2) PreToolUse hooks (`protect-ralph-files.sh`, `validate-command.sh`) block modifications to `.ralph/`, `.claude/`, and `.ralphrc` in real-time and hard-block destructive patterns (`rm -rf`, `git reset --hard`, `git clean`, `git rm`) regardless of agent config. The historical `ALLOWED_TOOLS` allowlist in `.ralphrc` was removed with legacy `-p` mode — see [docs/decisions/0006-delete-legacy-mode.md](docs/decisions/0006-delete-legacy-mode.md) and [MIGRATING.md](MIGRATING.md).

**Hook-based response analysis**: The `on-stop.sh` hook runs after every Claude response, extracts RALPH_STATUS fields (auto-unescaping JSON-encoded `\n` from JSONL stream output), writes `status.json`, and updates circuit breaker state. The loop reads from `status.json` instead of parsing raw CLI output. The hook includes a text fallback when no JSON path matches the response payload, and infers `WORK_TYPE: IMPLEMENTATION` when files are modified but the field is UNKNOWN. Atomic writes use `rm -f` after `mv` to prevent orphaned temp files on WSL/NTFS.

**Session guard (RALPH_LOOP_ACTIVE contract)**: The `on-stop.sh` hook includes a guard that exits early (no-op) when invoked from an interactive Claude Code session instead of a ralph autonomous loop. This guard distinguishes two invocation contexts: (1) **Interactive sessions** — the user is working in Claude Code directly; the Stop hook fires but should NOT mutate `.ralph/` state. (2) **Autonomous loops** — `ralph_loop.sh:main()` is executing; the Stop hook should process the response and update state. The guard works via the `RALPH_LOOP_ACTIVE` environment variable: `ralph_loop.sh:main()` exports `RALPH_LOOP_ACTIVE=1` before invoking Claude; the hook checks `if [[ "${RALPH_LOOP_ACTIVE:-}" != "1" ]]; then exit 0; fi` at the start of its main body. Without this guard, every interactive Stop event in a ralph-managed repo increments `loop_count`, tallies `session_cost_usd` against zero ralph iterations, and pollutes `.no_status_block_count`. The incident of May 2026 in ralph-claude-code is instructive: 885 interactive Stop events over several months accumulated $16,489 in false session_cost_usd and 885 fake loop increments, all against zero actual ralph work — the harness had no visibility into this false activity because interactive responses never carry a RALPH_STATUS block. `ralph-doctor` checks that `.ralph/hooks/on-stop.sh` contains the `RALPH_LOOP_ACTIVE` guard and warns with the TAP-1531 code if missing. **Sync command:** `ralph-upgrade` refreshes `~/.ralph/templates/` only — `ralph-upgrade-project` is what copies the new template into a managed repo's `.ralph/hooks/`. Running `ralph-upgrade` alone will leave existing repos drifted (this was a UX defect in 2.14.2 fixed in 2.14.3).

**Shared-worktree foreign-WIP guard (TAP-2797)**: The instance lock (LOCK-1, `flock(2)`) stops a second `ralph_loop.sh` on one project but is blind to a **manual / interactive writer sharing the same git working tree**. Two writers in one tree race: the campaign's commit/push/branch-switch cadence collides with hand edits, and the **FleetView orchestrator layer (external to this repo)** — not the harness — pauses loops by auto-stashing uncommitted work under `paused-ralph-loop-<branch>-wip-<ts>` and switching branches, which can silently bury work the campaign did not author (observed 2026-06-01: a manual harness-fix session's WIP was stashed + its branch switched out from under it; the work survived only because it had been committed early). The harness never stashes/switches, so the durable fix is **one git worktree per writer** (`git worktree add ../proj-campaign "$(git branch --show-current)"`); the harness-side defense is `ralph_guard_shared_worktree`, which runs in `main()` right after `acquire_instance_lock` and inspects `git status` for uncommitted changes to tracked, **non-`.ralph/`** files (work Ralph did not author — `.ralph/` state is Ralph-owned and excluded). Default behavior is a loud `WARN` recommending a dedicated worktree, then proceed; `RALPH_REQUIRE_CLEAN_TREE=true` escalates to refuse-on-start (`exit 1`); `RALPH_ALLOW_SHARED_TREE=true` acknowledges and silences. The producer string lives in **no** checked-in source on the host (confirmed: not in `ralph_loop.sh`, `lib/`, `~/.ralph/`, `~/.claude/skills/`) — it is the FleetView orchestrator, which cannot be patched from this repo. See [docs/OPERATIONS.md](docs/OPERATIONS.md) (“Never share one working tree…”). Covered by `tests/unit/test_shared_worktree_guard.bats`.

**Log rotation**: `rotate_ralph_log()` rotates `ralph.log` when it exceeds `LOG_MAX_SIZE_MB` (default 10). `cleanup_old_output_logs()` prunes old `claude_output_*.log` files beyond `LOG_MAX_OUTPUT_FILES` (default 20). Both run at startup and every loop iteration.

**Dry-run mode**: `--dry-run` or `DRY_RUN=true` simulates a loop iteration without calling the Claude API. Writes a `status.json` with `status: "DRY_RUN"` and exits after one iteration. Useful for validating configuration and tool permissions.

**WSL/Windows version divergence detection**: `check_version_divergence()` runs at startup in WSL environments. Compares `RALPH_VERSION` between `~/.ralph/ralph_loop.sh` (WSL) and `/mnt/c/Users/*/.ralph/ralph_loop.sh` (Windows). Warns if versions differ and detects stale `response_analyzer.sh` files.

**WSL PowerShell auto-patching (XPLAT-2b)**: `ralph_validate_hooks()` now also inspects the target project's `.claude/settings.json` for hooks calling bare `powershell` (which is unavailable in WSL — requires `powershell.exe`). When detected, Ralph auto-patches the settings file in-place via `sed`, skipping lines that already use `powershell.exe`. This prevents session-start hook errors when running Ralph against Windows-native projects from WSL.

**Atomic state writes + pipefail (TAP-535)**: All counter / state-file writes (`CALL_COUNT_FILE`, `TOKEN_COUNT_FILE`, `TIMESTAMP_FILE`, `persistent_loop_file`) go through the `atomic_write <file> <value>` helper near the top of `ralph_loop.sh`. The helper writes to a unique temp path (`${file}.tmp.$$.${RANDOM}`), best-effort fsyncs, then `mv -f`s into place — so a SIGTERM landing between truncate and write can no longer leave a zero-byte counter that silently defaults to 0 on the next read. The script also enables `set -o pipefail` after library sourcing so jq/grep pipelines don't silently mask broken inputs, and rejects Bash < 4 at startup.

**Hook resilience + drift detection (TAP-538)**: `templates/hooks/on-stop.sh` self-heals a corrupt `.circuit_breaker_state`: if `jq -e 'type == "object"'` fails on the current state file, the hook re-initializes it to `{state:CLOSED, consecutive_no_progress:0, ...}` and emits a single `WARN: .circuit_breaker_state is corrupt — reinitializing to CLOSED` line on stderr instead of crashing the loop. `templates/hooks/` is the source of truth for project hooks; `ralph-doctor` now compares each project's `.ralph/hooks/*.sh` against `~/.ralph/templates/hooks/*.sh` and warns on drift (re-run `ralph-upgrade` to sync). The repo's own `.ralph/hooks/*.sh` is kept byte-identical to the template; a unit test enforces this so the runtime copy cannot quietly diverge again.

**MCP server process cleanup (MCP-CLEANUP)**: Claude Code spawns MCP servers (tapps-mcp, docsmcp via `uv`) as grandchild processes. On Windows, these survive after the CLI exits because process group teardown doesn't cascade — each loop iteration leaks one `uv` + `python` pair per MCP server. `ralph_cleanup_orphaned_mcp()` runs after every CLI invocation and in the exit trap, killing only **orphaned** MCP processes (parent process dead) to avoid disrupting MCP servers belonging to the user's editor (Cursor, VS Code). On Windows/MINGW it uses a temp PowerShell script with `Get-CimInstance Win32_Process` + parent-alive check (10s timeout guard); on Linux/macOS/WSL it uses `pgrep`/`kill` filtering by PPID==1. `tapps-brain` is intentionally excluded from the cleanup regex — it runs as a dockerized HTTP MCP server with its own container lifecycle.

**MCP probe + prompt guidance (TAP-583 / TAP-585)**: Ralph probes three MCP servers at startup via `ralph_probe_mcp_servers()` — **docs-mcp**, **tapps-mcp**, and **tapps-brain** — setting `RALPH_MCP_{DOCS,TAPPS,BRAIN}_AVAILABLE`. `build_loop_context()` injects a short "when to use" block per server into `--append-system-prompt` so Claude actually reaches for the MCP tools instead of falling back to Read/Grep/Bash. **Each MCP is registered by the project** (via `.mcp.json` or `claude mcp add`), never by Ralph — if a server is not registered, the probe fails and the guidance block is omitted. Gating rules: **docs-mcp** is injected only when the current task looks docs-related (`ralph_task_is_docs_related` scans the next unchecked task / Linear issue for README/ADR/architecture/changelog/`.md` keywords, fail-closed on empty or missing); **tapps-mcp** and **tapps-brain** are injected unconditionally when their servers are reachable because their recommended tools (`tapps_quality_gate`, `tapps_lookup_docs`, `brain_recall`) apply across task types. Run `ralph --mcp-status` to see which probes succeeded without grepping logs.

**STDIO MCP catalog loss on session resume (MCP-RESUME, Issues 1 + 4)**: STDIO MCP servers (`tapps-mcp`, `docs-mcp`) are child processes spawned per `claude` invocation. On `claude --resume <id>` they die with the prior process and are not always re-spawned/re-registered before the agent issues tool calls — the agent then no-ops the loop with `No such tool available: mcp__tapps-mcp__…`. The startup probe (`ralph_probe_mcp_servers`) cannot catch this: it ran once, in a different process, and is cached up to 24h, so it reports *server connection* status, not the *tool catalog* the resumed agent process actually sees (Issue 4). Two harness mechanisms address it: (1) `execute_claude_code` calls `exec_mcp_catalog_lost` (lib/exec_helpers.sh) on the post-run stream — it fires on the `No such tool available: mcp__` signature OR on a `type:"system"` init message that reports an expected STDIO server failed/absent — and on a resume loop that did no real work, retries the loop ONCE with a fresh (non-resumed) session instead of burning it (bounded: a single linear retry; the poisoned session id is dropped so the next loop also cold-starts). (2) `build_loop_context()` computes `MCP_HEALTH: tapps=` via `exec_mcp_health_label`, which forces `down` when the `.mcp_catalog_lost` sentinel is present even if the startup flag says available — so health reflects catalog truth, not probe liveness. The HTTP server (`tapps-brain`) is an external long-lived service that survives resume and is intentionally excluded from the expected-STDIO set. Covered by `tests/unit/test_exec_mcp_catalog.bats`. **Upstream:** the root cause (STDIO MCP servers not re-registered on `claude --resume`) is filed as [anthropics/claude-code#64016](https://github.com/anthropics/claude-code/issues/64016) — retire this harness retry once the CLI re-registers the catalog on resume.

**Explicit timeout status (TIMEOUT-STATUS, Issue 3)**: On a SIGTERM execution timeout the on-stop.sh Stop hook does not run, so `status.json` retains the PREVIOUS loop's content. Before the fix, the timeout path read that stale file back and surfaced a wrong summary (the field symptom: a loop that had edited files mid-work reported "backlog confirmed empty — stopping", verbatim from a different run). `exec_handle_timeout` now calls `exec_emit_timeout_status` on BOTH the productive and the sub-threshold unproductive paths, overwriting `status.json` with `{status:"timeout", summary, files_modified:<actual count>, exit_signal:"false", tasks_completed:0}` before any read — so a timed-out loop never reports a prior run's status, and no false exit/completion signal is inferred. The at-threshold path keeps its explicit HALTED status. Covered by `tests/unit/test_exec_handle_timeout.bats`. **Upstream:** the root cause (the Stop hook never fires when the CLI is SIGTERM-killed) is filed as [anthropics/claude-code#64017](https://github.com/anthropics/claude-code/issues/64017) — retire this explicit status-write once the CLI fires the Stop hook (or a termination hook) on SIGTERM.

**MCP disconnect retry (MCP-DISCONNECT-RETRY, 2026-06-01)**: Intermittently a fresh `claude -p` invocation comes up with ALL of its MCP servers disconnected at loop start (transient MCP-client startup flakiness, NOT a zombie/resource leak — verified no orphaned servers, `uv run` cold-start ~150ms, no version drift). The agent can't `session_start`, read Linear, run the quality gate, or mark work done, so it reports `STATUS: BLOCKED` with `FILES_MODIFIED: 0` / `TASKS_COMPLETED_THIS_LOOP: 0`. Two complementary mechanisms keep this from tripping the no-progress circuit breaker: (1) **detection + no-penalize** — `on-stop.sh` recognizes the disconnect via the canonical `RECOMMENDATION: mcp_unreachable` OR a free-text fallback (`mcp…(disconnect|unreachable|not connected|failed to connect)` / `all mcp servers`, gated on files=0 ∧ tasks=0 ∧ `EXIT_SIGNAL != true` so a productive or clean-exit loop can never trip it), writes the structured flag `mcp_disconnect: true` into `status.json`, and bumps `.mcp_blocked_count` *without* touching `consecutive_no_progress`; a genuinely-blocked backlog (no mcp/disconnect token) still falls through to the no-progress arm. (2) **retry, don't halt** — the main loop reads `status.json.mcp_disconnect` (`ralph_loop_was_mcp_disconnect`), drops the possibly-poisoned session (`reset_session "mcp_disconnect"`), backs off (`ralph_mcp_retry_backoff` — 2s/5s/10s), and `continue`s so the next iteration cold-starts a fresh `claude` invocation (which almost always reconnects). After `RALPH_MCP_RETRY_MAX` (default 3; legacy alias `RALPH_MCP_BLOCKED_QUORUM`) consecutive disconnect loops, `on-stop.sh` writes `.harness_halt_reason=mcp_unreachable_quorum` and the harness gives up. A pre-loop health gate (`ralph_mcp_health_gate`, **TAP-2786: default ON** via `RALPH_MCP_HEALTH_GATE=true`) re-probes the required MCP servers with the same backoff before spending a Claude invocation — cutting the disconnect spiral at the source: a Claude invocation launched into an all-MCP-disconnected state no-ops AND can hang up to the adaptive timeout, leaking a worker (TAP-2777), far more costly than the gate's ~1.3s warm `claude mcp list` probe (<1% of a multi-minute loop, measured 2026-06-02). The gate **self-skips** on projects that don't use tapps-mcp: `main()` captures `RALPH_MCP_TAPPS_EXPECTED` from the one-time startup probe (right after `ralph_probe_mcp_servers`), and the gate returns early when it is not `true`, so a file-mode / no-tapps-mcp project is never charged the per-loop probe or the ~11s unreachable backoff. Opt out with `RALPH_MCP_HEALTH_GATE=false` (e.g. a host with highly variable MCP cold-start latency where the per-loop probe is itself disruptive — the post-loop retry still recovers disconnects). Covered by `tests/unit/test_mcp_health_signal.bats` (disconnect-exempt + genuine-no-progress paths) and `tests/unit/test_mcp_disconnect_retry.bats` (loop-side helpers). **TODO:** have the agent emit a structured marker (e.g. `MCP_STATUS: disconnected`) so the free-text fallback match can be retired.

**Sub-agents**: Four specialized agents keep search, testing, review, and complex architecture work out of the main context:
- **ralph-explorer** (Haiku) — fast codebase search
- **ralph-tester** (Opus 4.8, worktree-isolated) — test runner
- **ralph-reviewer** (Opus 4.8, read-only) — code review
- **ralph-architect** (Opus 4.8) — complex/architectural tasks with mandatory code review

The main Ralph agent (Sonnet) handles routine work with task batching (up to 5 small / 3 medium tasks per invocation) and delegates LARGE tasks to ralph-architect.

**Agent model lineup — single source of truth ([agent-models.json](agent-models.json))**: every `.claude/agents/<name>.md` `model:` field MUST match the corresponding entry in [agent-models.json](agent-models.json). The drift guard at [tests/unit/test_agent_models_lockstep.bats](tests/unit/test_agent_models_lockstep.bats) fails CI in either direction (manifest without file, file without manifest, or values that don't match). Bumping a model is a two-step operator flow (the protect hook blocks `.claude/` writes from any Claude Code session): edit `agent-models.json` from a plain terminal, then run `bash scripts/apply-agent-models.sh` to propagate. See [docs/OPERATOR-EDITS.md](docs/OPERATOR-EDITS.md) for the full playbook. The legacy per-agent drift assertions in `test_agent_contract_tap646.bats` (TAP-646 A) and `test_subagent_brief_consumption.bats` (TAP-916) now read from the manifest too — so a model bump is one edit + one script run, not a coordinated edit across five files.

**Parallel QA fan-out at epic boundary (TAP-1684)**: at the last `- [ ]` under a `##` section (file mode) or the last open issue in a Linear epic, the main agent dispatches `ralph-tester`, `ralph-reviewer`, and `tapps-validator` in **one message with three `Task` calls** — they run concurrently and the epic-boundary wall-clock drops from "sum of three" (typical 4–7 min) to "slowest of three" (typical 3–5 min). The aggregation rule is **any FAIL or TIMEOUT collapses to FAIL**, the same semantics serial mode had via early-exit. Two enforcement surfaces keep the rule honest: (1) the ralph-workflow skill and `.claude/agents/ralph.md` both carry the worked example so the agent applies the rule in prose, and (2) the harness-side helper `exec_aggregate_qa_results` in `lib/exec_helpers.sh` implements the same rule for any harness-driven aggregation. The `on-subagent-done.sh` hook maintains a `.ralph/.subagent_in_flight` sidecar (one agent_id per line) and sets `.subagent_defer_cb` while `>1` agent is outstanding, so downstream CB-update sites don't race on the first-returning verdict. The sidecar is absent in serial mode (mid-epic explorer, one-off tester) so all non-fan-out paths behave exactly as before.

**Speed optimizations** (v1.8.4+): The main ralph agent runs on Sonnet with `bypassPermissions` mode and `effort: medium` for faster throughput. PostToolUse hooks (`on-file-change.sh`, `on-bash-command.sh`) are disabled to reduce per-tool-call overhead. Safety is maintained via PreToolUse hooks (file protection, command validation) and the `disallowedTools` list.

**Epic-boundary deferral** (v1.8.5): Multiple expensive operations are deferred until epic boundaries — the completion of the last `- [ ]` task under a `##` section in fix_plan.md:
- **QA**: ralph-tester and ralph-reviewer skipped mid-epic (set `TESTS_STATUS: DEFERRED`). Mandatory before `EXIT_SIGNAL: true` and for LARGE tasks.
- **Explorer**: ralph-explorer skipped for consecutive SMALL tasks in the same module. Use Glob/Grep directly instead.
- **Backups**: State snapshots deferred to epic boundaries instead of every loop.
- **Batch sizes**: Increased to 8 SMALL / 5 MEDIUM (safe because QA catches regressions at boundaries).
- **Subprocess batching**: on-stop.sh, exit signal updates, status reads, and JSON config loading all use single jq calls instead of multiple spawns (reduced from ~50 to ~10 jq calls per loop).
- **Version caching**: Claude CLI version checked once at startup instead of 4 times.
- **Inter-loop pause**: Reduced from 5s to 2s.
- **Log rotation**: Every 10 loops instead of every loop.

**Live / JSONL pipeline**: `--live` captures NDJSON via an `awk` stream filter that shows tool names with parameters (file paths, commands, patterns), per-tool elapsed time, sub-agent events, error messages (extracted from `result`/`content` fields on `is_error:true`, truncated to 120 chars), and a summary stats line. Claude's text output is buffered per content block and filtered at block boundaries: text containing stream metadata (`session_id`, `parent_tool_use_id`, `uuid`), raw JSON dumps, or UUID patterns is suppressed; remaining text is collapsed to a single line, truncated to 200 chars, and shown with `>` prefix. JSON string value extraction uses a placeholder technique (`\001`) to protect escaped quotes before finding the closing quote. The loop copies the full stream, retries `-f` on the output file (WSL2/9P), extracts the last `type: "result"` line when `CLAUDE_USE_CONTINUE` is true, then `ralph_prepare_claude_output_for_analysis` logs permission denials and failed MCP init, and `ralph_extract_result_from_stream` isolates the result object from the JSONL stream (filtering subagent results from the multi-result count).

**Continue-As-New (CTXMGMT-3)**: Temporal-inspired pattern for long sessions. After `RALPH_MAX_SESSION_ITERATIONS` (default 20) or `RALPH_MAX_SESSION_AGE_MINUTES` (default 120), the session resets while carrying forward essential state (current task, progress, recommendation). Controlled by `RALPH_CONTINUE_AS_NEW_ENABLED` (default true). Research shows agent success rate drops after ~35 min. The SDK implements the same pattern via `ContinueAsNewState` in `agent.py`.

**Completion indicator decay (SDK-SAFETY-3)**: When productive work occurs (files_modified > 0 or tasks_completed > 0) AND exit_signal is false, completion_indicators are reset to `[]`. This prevents stale "done" signals from combining with later legitimate signals for premature exit.

**Agent evaluation framework (EVALS)**: Golden-file test infrastructure in `tests/evals/`. Deterministic suite (64 BATS tests, no LLM calls, <5 min) verifies exit gate, circuit breaker, tool restrictions, and hooks. Stochastic suite runs N golden-file comparisons with three-valued outcomes (Pass/Fail/Inconclusive) and Wilson score confidence intervals for nightly CI.

**Linear task backend (`RALPH_TASK_SOURCE=linear`)**: When set, Ralph replaces all `fix_plan.md` reads with Linear via the Linear MCP plugin. **OAuth-via-MCP is the only supported mode** — there is no harness-side API key. Claude lists, picks, and updates Linear issues using `mcp__plugin_linear_linear__*` tools; the harness reads counts from `.ralph/status.json` written by the on-stop hook from Claude's `RALPH_STATUS` block. Five integration points in `ralph_loop.sh` branch on this variable: exit-condition check, dry-run status display, `build_loop_context()` (injects next issue + Linear MCP instructions into `--append-system-prompt`), `ralph_continue_as_new()` (saves open/done counts), and startup pre-seeding of exit signals. The backend is sourced from `lib/linear_backend.sh` at startup. Requires `RALPH_LINEAR_PROJECT` (exact project name in Linear). The full state-transition rules (what moves where, who moves it, the hard rule that Done requires commits on `main`) are documented in **[docs/LINEAR-WORKFLOW.md](docs/LINEAR-WORKFLOW.md)**; this is the shared workflow for every Ralph-managed project in the `TappsCodingAgents` team. **TAP-536 fail-loud handling**: each integration point distinguishes "exit non-zero" (count unknown — stale or no hook write yet) from "exit 0 + value" (real result). The exit-condition check **skips the gate entirely** on a failure so a stale count cannot trip `plan_complete`. `build_loop_context()` injects "Remaining tasks (Linear): unknown (counts not yet reported — do NOT emit EXIT_SIGNAL)" so Claude does not emit a stale done signal.

**Linear cache-locality optimizer (LINOPT epic)**: Two execution paths share one consumer site. In **direct-API mode** (`LINEAR_API_KEY` set), `linear_optimizer_run()` runs as a background job at session start (fire-and-forget) — fetches the top-N open issues, extracts likely file paths from issue bodies via regex, falls back to ralph-explorer (Haiku, capped at 3 calls/session) for top-3 priority issues with no body paths, and scores each candidate with `Jaccard(last_completed_files, candidate_files) + 0.3 * shared_dir_bonus`. In **OAuth-via-MCP mode** (no `LINEAR_API_KEY`, which is the only mode operators actually run), `linear_optimizer_run()` short-circuits and the `ralph-coordinator` agent does the equivalent scoring inside its MODE=brief step 4 — same algorithm, but via `mcp__plugin_linear_linear__list_issues` and prose-driven set arithmetic instead of GraphQL + awk. The coordinator's `list_issues` call is **state-narrowed** (TAP-2472, ship-as-patch in `docs/specs/tap-2472-coordinator-narrowing.patch`): `state="started"` first with `limit=50`, falling back to `state="unstarted"` only if started returned <3 candidates. Pre-TAP-2472 the call was `limit=15` with no state filter and client-side discard; on large backlogs the response body pushed wall-clock past the 126s adaptive coordinator timeout in all 3 sibling projects observed 2026-05-22/23. Both paths write the highest scorer's identifier to `.ralph/.linear_next_issue`. `build_loop_context()` reads this file on the next loop and injects `LOCALITY HINT: <ID>` into the system prompt; the ralph-workflow skill (step 0) tells Claude to prefer the hint if the issue is still open, then delete the file. This compresses context-switch cost by keeping Claude in the same module across consecutive loops. The `on-stop.sh` hook (TAP-590 / LINOPT-1) is the shared data source: it walks the JSONL session transcript after each loop to extract edited file paths → `.ralph/.last_completed_files`. Coordinator-side opt-out: create `.ralph/.linear_optimize_disabled` (sentinel file, presence-only) to suppress the locality step without touching `.ralphrc`.

**Design documentation**: Reliability epics and stories live in **`docs/specs/`** (e.g. `epic-jsonl-stream-resilience.md`, `epic-multi-task-cascading-failures.md`). Long-term platform integration is drafted in `docs/specs/claude-code-2026-enhancements.md`.

### State Files (in `.ralph/` within managed projects)

**Committed vs ignored (TAP-1882):** `templates/.gitignore` uses an allowlist for `.ralph/` — `.ralph/*` ignores everything except the small known-good set: `PROMPT.md`, `AGENT.md`, `fix_plan.md`, and `hooks/`. Every other file documented below (counters, status, caches, JSONL logs) is ephemeral state and is **never** committed. New `.ralph/<thing>` writers do not need to update `templates/.gitignore` — the allowlist absorbs them automatically. The merge helper `merge_gitignore_block` in `lib/enable_core.sh` is called from both `enable_core.sh` (fresh install) and `ralph_upgrade_project.sh` (backfill into existing repos) so consumer repos converge on the same allowlist without losing user-added entries.

- `.call_count` / `.last_reset` — Rate limit tracking (hourly reset)
- `.exit_signals` — Exit signal history
- `status.json` — Real-time status and response analysis (written by on-stop.sh hook)
- `.circuit_breaker_state` — Circuit breaker state (JSON)
- `.claude_session_id` — Session persistence
- `PROMPT.md` — Main development instructions driving each loop
- `fix_plan.md` — Prioritized task list
- `AGENT.md` — Build/run instructions
- `.last_completed_files` — One repo-relative file path per line, written by `on-stop.sh` after each loop (LINOPT-1 / TAP-590). Read by `linear_optimizer.sh` to score issue locality.
- `.linear_next_issue` — Single line: Linear issue identifier (e.g. `TAP-591`). Written atomically by either `linear_optimizer_run` (direct-API mode, session start) or `ralph-coordinator` MODE=brief step 4 (OAuth-via-MCP mode, per loop). Consumed by `build_loop_context()` as `LOCALITY HINT`; deleted by Claude after honoring.
- `.linear_optimize_disabled` — Sentinel file (presence-only, content ignored). Suppresses the coordinator-side locality scoring step without touching `.ralphrc`. Equivalent to `RALPH_NO_LINEAR_OPTIMIZE=true` for the OAuth-via-MCP path. Useful when triaging a project whose Linear descriptions are too noisy to score reliably.
- `.linear_optimizer_cache.json` — Explorer-fallback path cache keyed by `issue_id:updatedAt`. Prevents re-paying the Haiku cost for the same issue across sessions.
- `.mcp_catalog_lost` — Sentinel (presence-only) written by the MCP-RESUME retry path in `execute_claude_code` when a fresh-session retry STILL comes up without its STDIO MCP tool catalog (transport genuinely down, not a resume artifact). Read by `build_loop_context()` via `exec_mcp_health_label` so the next loop's `MCP_HEALTH:` line shows `tapps=down` even though the 24h-cached startup probe said available (Issue 4). Removed automatically when a retry restores the catalog.
- `.coordinator_phase_timings.jsonl` — One JSON line per coordinator invocation: `{ts, mode, total_seconds, exit_code, tool_calls, brain_recall_calls, brain_recall_invoked, dominant_phase}`. Written by `ralph_record_coordinator_phase_timing`. Attributes coordinator wall-clock to synthesis vs. brain recall (the slow-step question from the field report) — capped at 30 entries like `.coordinator_timings.jsonl`.

### Configuration

Project-level config lives in `.ralphrc` (sourced as bash). Key variables:
- `CLAUDE_CODE_CMD` — CLI command (default: `"claude"`, fallback: `"npx @anthropic-ai/claude-code"`)
- `CLAUDE_OUTPUT_FORMAT` — `json` (default) or `text`
- `CLAUDE_MODEL` — Model override (e.g. `claude-sonnet-4-6`); falls through to the agent file's `model:` directive when unset
- `RALPH_AGENT_NAME` — Agent file basename (default: `"ralph"`, resolves to `.claude/agents/ralph.md`)
- `CLAUDE_USE_CONTINUE` — Session continuity toggle
- `CLAUDE_AUTO_UPDATE` — Auto-update CLI at startup (disable for Docker/air-gapped)
- `RALPH_SHELL_INIT_FILE` — Shell init file (e.g. `~/.zshrc`) sourced before launching Claude. Use case: zsh / Nix / asdf users whose `claude` lives on a PATH set by their shell init; Ralph runs under bash and won't see it otherwise. Missing file warns, doesn't abort. (Issue #211, ported from upstream)
- `CB_COOLDOWN_MINUTES`, `CB_AUTO_RESET` — Circuit breaker recovery config
- `LOG_MAX_SIZE_MB` — Max ralph.log size before rotation (default: 10)
- `LOG_MAX_FILES` — Number of rotated log files to keep (default: 5)
- `LOG_MAX_OUTPUT_FILES` — Max claude_output_*.log files to keep (default: 20)
- `DRY_RUN` — Preview loop execution without API calls (also `--dry-run` flag)
- `RALPH_TASK_SOURCE` — Task backend: `"file"` (default, reads `fix_plan.md`) or `"linear"` (Claude picks via the Linear MCP, OAuth-via-MCP only)
- `RALPH_LINEAR_PROJECT` — Linear project name, must exactly match workspace (required when `RALPH_TASK_SOURCE=linear`)
- `RALPH_NO_OPTIMIZE` — Disable automatic fix_plan.md reordering on session start
- `RALPH_NO_EXPLORER_RESOLVE` — Disable ralph-explorer file resolution for vague tasks
- `RALPH_NO_DESLOP` — Skip the epic-boundary deslop pass (ralph-workflow skill step 7.5 — invokes the `simplify` skill on changed files). Agent-honored flag, not read by harness bash: it is exported to the Claude CLI subprocess via `set -a` and the skill checks it (default: `false`)
- `RALPH_MAX_EXPLORER_RESOLVE` — Max vague tasks to resolve per optimization run (default: 5)
- `RALPH_NO_LINEAR_OPTIMIZE` — Disable Linear cache-locality optimizer entirely (no API calls, no hint file written)
- `RALPH_OPTIMIZER_FETCH_LIMIT` — Max issues to fetch and score per optimizer run (default: 20)
- `RALPH_OPTIMIZER_EXPLORER_MAX` — Max ralph-explorer calls per optimizer session (default: 3)
- `RALPH_MCP_PROBE_TIMEOUT_SECONDS` — Upper bound on the startup `claude mcp list` probe (default: 30). High default covers cold-start cases where stdio MCP servers spawn child processes and HTTP MCPs do auth round-trips. Warm runs return in 1–2s so the cap is invisible.
- `RALPH_MCP_HEALTH_GATE` — Pre-loop MCP health gate (**TAP-2786: default `true`**). Before each loop, `ralph_mcp_health_gate` re-probes the required MCP servers via a fresh `claude mcp list` (~1.3s warm, <1% of a multi-minute loop) and waits out a transient disconnect (escalating 2s/5s/10s backoff, up to `RALPH_MCP_RETRY_MAX` probes) before spending a Claude invocation — cheaper than launching into an all-MCP-disconnected state, which no-ops the loop AND can hang up to the adaptive timeout, leaking a worker (TAP-2777). **Self-skips** on projects that don't use tapps-mcp (gated on `RALPH_MCP_TAPPS_EXPECTED`, captured from the startup probe), so file-mode / no-tapps-mcp projects pay nothing. Set `false` to opt out (the post-loop MCP-DISCONNECT-RETRY still recovers disconnects without it).
- `RALPH_MODEL_ROUTING_ENABLED` — Per-task type + QA escalation → model routing (default: `true`). When enabled, `build_claude_command` classifies the next task via `ralph_classify_task_type` (docs/tools/code/arch) and calls `ralph_select_model` with the QA failure count (from `.ralph/.qa_failures.json` for the current Linear issue). Routing: docs/tools → `haiku` (~1/5 cost), code → `sonnet` (floor), arch → `opus`, QA failures ≥3 → `opus` (safety escalation). Task text comes from the next Linear issue (or in-progress one if present) or first unchecked `fix_plan.md` line; routing decisions append to `.ralph/.model_routing.jsonl` (includes `task_type` and `reason` fields). Falls back to `CLAUDE_MODEL` when task text is empty. Old complexity-band variables (`RALPH_MODEL_TRIVIAL`, etc.) are deprecated but still recognized for backwards compatibility.
- `RALPH_SKILL_AUTO_TUNE` — When `true`, `skill_retro_apply` installs up to 1 recommended skill per loop automatically (default: `false`)
- `RALPH_SKILL_RETRO_WINDOW` — Number of recent loops to examine for friction patterns (default: 5)
- `RALPH_SKILL_REDETECT_INTERVAL` — Run periodic Tier A skill re-detection every N loops (default: 10)
- `RALPH_SKILLS_ADOPT` — When `1`, `skills_install_global` adopts orphaned pre-sidecar skills in `~/.claude/skills/`: any no-sidecar dir whose name matches a Ralph-shipped skill is backed up under `~/.claude/skills/.ralph-backup/<name>-<ts>-<pid>/` and re-installed fresh + sidecar (default: unset → such dirs are skipped as user-authored). Threads through `ralph-upgrade` / `ralph-upgrade-project` via the environment, e.g. `RALPH_SKILLS_ADOPT=1 ralph-upgrade`. Use after `ralph-doctor` reports an orphaned skill; review the backup diff before deleting it.
- `RALPH_COORDINATOR_TIMEOUT_SECONDS` — Hard override for the coordinator timeout. When unset (the recommended default), Ralph computes the timeout adaptively via `ralph_compute_coordinator_timeout`: P95×2 of the last 30 wall-clock samples in `.ralph/.coordinator_timings.jsonl`, clamped to `[RALPH_COORDINATOR_TIMEOUT_MIN_SECONDS, RALPH_COORDINATOR_TIMEOUT_MAX_SECONDS]` (defaults 180 and 600), falling back to `RALPH_COORDINATOR_TIMEOUT_FALLBACK_SECONDS` (default 300) when fewer than `RALPH_COORDINATOR_TIMEOUT_MIN_SAMPLES` (default 3) samples exist. The coordinator is a full Claude subagent whose observed completion latency is 150–250s, so the floor/fallback are sized to cover that band — the pre-fix defaults (30/120) sat below it and killed healthy briefs (154s/248s field timeouts). Two further corrections keep the adaptive value honest: timed-out samples (`exit_code` 124) are **right-censored** (the true latency exceeded the budget), so they are inflated 1.5× before the percentile is taken; and the P95 index uses ceiling rounding so small sample sets bias toward the slow tail rather than the median. Per-loop phase attribution (synthesis vs. brain recall) lands in `.ralph/.coordinator_phase_timings.jsonl` (`dominant_phase`, `brain_recall_invoked`, `tool_calls`) — brain recall is a sub-second MCP round-trip, so any multi-second total is synthesis-bound. Set this env var to pin a value during incident response; set `0` to disable the watchdog entirely (only useful when MCP cold-start latency is highly variable). Set `RALPH_COORDINATOR_DISABLED=true` to skip the coordinator altogether. (TAP-1682)
- `RALPH_BRIEF_CACHE_MAX_AGE_SECONDS` — Coordinator brief cache TTL in seconds (default: `1800`, i.e. 30 minutes). When the same Linear issue is the current task across consecutive loops, `ralph_spawn_coordinator` reads back the previous brief from `.ralph/.brief_cache/<linear_issue_id>.json` instead of re-spawning Haiku. Cache entries are evicted when this age is exceeded OR when the coordinator surfaces a newer `linear_issue_updated_at` than the cached one. On a coordinator timeout (exit 124) the harness retries the cache with a 24-hour TTL as graceful degradation — even a stale brief is better than none. File mode loops bypass the cache (no per-issue identity). (TAP-1682) **TAP-1875 reinforcement:** when `_coordinator_invoke_claude` returns rc=0 but `.ralph/brief.json` is missing or fails `brief_validate`, the harness retries the invocation exactly once with an explicit "your previous response did not write the file" header (the resumed Claude session still has the task context). If the retry also fails, `brain_client_write_failure(source="coordinator-brief")` records the regression for skill-retro detection before the WARN-and-clear path fires. The agent contract in `.claude/agents/ralph-coordinator.md` MODE=brief is paired with this: it ships a literal Write-tool example + the full required JSON schema inline so the coordinator can't shortcut to "summarize only."
- `RALPH_BRIEF_CACHE_DIR` — Override the cache directory (default: `$RALPH_DIR/.brief_cache`). Tests use a tmpdir; operators rarely touch this. (TAP-1682)
- `RALPH_PERMISSION_MODE` — Override the Claude CLI permission mode for the next loop. When unset (the default), `.claude/agents/ralph.md`'s frontmatter `permissionMode: bypassPermissions` takes effect. When set, the harness appends `--permission-mode <value>` to the CLI invocation and the agent file is overridden. The coordinator-driven HIGH-risk path automatically sets this to `plan` for the affected loop only (see "Plan Mode for HIGH-risk tasks" below); operators can also pin a value during incident response. Accepts any mode Claude Code recognizes (`plan`, `acceptEdits`, `default`, `bypassPermissions`). (TAP-1686)
- `RALPH_CACHE_HIT_RATE_WARN` — Threshold percentage (default: `30`). When the rolling-session prompt-cache hit rate falls below this value, `ralph-monitor` renders the "Prompt cache" panel in red and appends a one-line investigation hint ("session hit rate X% < threshold Y% — investigate prompt-prefix instability"). The math is `cache_read / (cache_read + cache_create + input_uncached)`. Cold-start loops render as `0%` (not NaN) because the loop denominator is non-zero even when `cache_read=0`. Missing `loop_cache_*` / `session_cache_*` fields default to `0` at both the hook write and the monitor read. See **Observability: prompt cache** below. (TAP-1685)
- `RALPH_QUESTION_LOOP_THRESHOLD` — Maximum number of consecutive loops Ralph tolerates Claude asking questions instead of acting before forcing an advance (default: `2`). USYNC-1 (in `on-stop.sh`) already detects the question patterns; this knob is the **policy** that turns that signal into action. At `counter >= threshold`, the next loop's `--append-system-prompt` is **prepended** (so the 1500-char truncation cannot drop it) with a hardened "decide and act" directive. At `counter > threshold`, the hook advances past the current task: in linear mode it writes `.ralph/.linear_advance_action` so the next loop tells Claude to apply a `blocked:waiting-for-answer` label via the Linear MCP and pivot to a different ticket; in file mode it appends `<!-- BLOCKED: questions -->` directly to the first unchecked task line in `fix_plan.md`. The counter resets to zero on any productive loop (`tasks_completed >= 1` OR `files_modified >= 1`). Origin: USYNC-1 was passive telemetry; AgentForge field data (2026-04 → 2026-05) showed the same project re-entering the question/CB cycle hundreds of times before this policy landed. (TAP-1683)
- `RALPH_PUSH_EVERY_LOOP` — After each successful loop iteration that produced commits, run `git push` so origin reflects the autonomous work in real time (default: `true`). Closes the AgentForge-feedback drift pattern where multi-epic sessions accumulated 12+ unpushed commits because the per-task `gh pr merge --squash --auto` flow (ralph-workflow R1) was the only push path and only fired when the agent actually executed the merge. The harness-side `ralph_push_pending_commits` helper runs after `cb_record_success`; silent skip when the branch has no upstream / detached HEAD / zero unpushed commits; on failure, WARN with a tail of `git push` output in `.ralph/.push-failure.err` and never trip the circuit breaker. Set to `false` for runs that intentionally batch pushes (e.g., signing every push manually). Honors `DRY_RUN`. **Project-side pre-push hook interaction**: `ralph_push_pending_commits` invokes `git push` *without* `--no-verify`, so any `.git/hooks/pre-push` or `core.hooksPath`-installed pre-push gate (e.g. a `.githooks/pre-push` that runs the test suite or a version-sync check) runs on every loop. This is by design — your gate is not bypassed. Two failure modes to be aware of: (1) a slow pre-push (full test suite) adds its wall-clock to every loop; (2) when pre-push *fails*, the commit stays local, Ralph emits a `WARN` and continues, and a backlog of locally-committed-but-un-pushable commits accumulates silently — operators monitoring this knob should `tail -F .ralph/.push-failure.err` or set `RALPH_PUSH_EVERY_LOOP=false` and push manually at session end.

- `RALPH_REQUIRE_CLEAN_TREE` — When `true`, the TAP-2797 shared-worktree guard (`ralph_guard_shared_worktree`, runs in `main()` after `acquire_instance_lock`) **refuses to start** (`exit 1`) if the working tree has uncommitted changes to tracked, non-`.ralph/` files — i.e. work Ralph did not author, the signature of a manual session sharing the tree (default: `false` → loud `WARN` then proceed). Use on unattended hosts where a concurrent hand-editing session is possible.
- `RALPH_ALLOW_SHARED_TREE` — When `true`, silences the TAP-2797 shared-worktree guard entirely (acknowledges deliberate shared-tree use). Overrides `RALPH_REQUIRE_CLEAN_TREE`. Default: `false`. The durable alternative is one `git worktree` per writer — see [docs/OPERATIONS.md](docs/OPERATIONS.md).

Environment variables override `.ralphrc` settings.

### `.ralphrc.local` — operator-only override surface

`.ralphrc.local` is an optional sibling of `.ralphrc` for **operator-set
per-repo overrides that the agent must not be able to self-unlock**.

- **Where it's sourced:** `load_ralphrc()` in `ralph_loop.sh` sources it
  immediately after `.ralphrc`, wrapped in `set -a` / `set +a` so every
  variable auto-exports to the Claude CLI invocation and downstream hook
  subprocesses. **Caveat:** `load_ralphrc()` returns early when `.ralphrc`
  is absent — `.ralphrc.local` is only sourced when a base `.ralphrc`
  also exists. Operators who want overrides without a base `.ralphrc`
  must `touch .ralphrc` first.
- **Precedence:** CLI flag > env var > `.ralphrc.local` > `.ralphrc` > script default.
- **Edit protection:** `protect-ralph-files.sh` blocks the agent from
  editing `.ralphrc.local` with the same anchoring rules as `.ralphrc`
  (project root + bare path; sibling-repo files are not caught).
- **Gitignored:** the `.ralphrc.local` entry in `templates/.gitignore` and
  the repo's own `.gitignore` keeps the override file out of commits.

**Primary motivator: R0 bypass for direct-to-main workflows.** The
`validate-command.sh` hook refuses `git push origin main` unless
`RALPH_ALLOW_PUSH_MAIN=1` is in the agent's environment. Setting that var
inside `.ralphrc` would not work — `.ralphrc` is also agent-blocked, AND
without `set -a` the value would not export to the hook subprocess. The
documented `RALPH_ALLOW_PUSH_MAIN=1 ralph` escape requires re-exporting on
every harness restart. `.ralphrc.local` exists so the operator writes
`RALPH_ALLOW_PUSH_MAIN=1` **once** and the agent inside the harness can
never erase or rewrite it.

Example for a direct-to-main repo (run as the operator, outside Claude
Code, since the protect hook will block this from inside the harness):

```bash
cat > .ralphrc.local <<'EOF'
# Direct-to-master workflow — bypass R0 push-to-main block in
# templates/hooks/validate-command.sh. Agent cannot modify this file
# (protect-ralph-files.sh blocks it), so the bypass cannot be self-unlocked.
RALPH_ALLOW_PUSH_MAIN=1
EOF
```

## Plan Mode for HIGH-risk tasks (TAP-1686)

When the coordinator writes `.ralph/brief.json` with `risk_level: HIGH`,
`build_loop_context` flips the next Claude invocation into Plan Mode:

1. **`RALPH_PERMISSION_MODE=plan`** is exported for the loop (only if no
   operator override is already set).
2. **`build_claude_command`** reads that variable and appends
   `--permission-mode plan` to the CLI invocation, overriding the agent
   file's `bypassPermissions` default for this single loop.
3. **The agent file (`.claude/agents/ralph.md`)** carries a "When Plan
   Mode applies" section telling Claude to emit a numbered plan + post
   it as a Linear comment / `<!-- PLAN -->` marker in `fix_plan.md`, AND
   to set `WORK_TYPE: PLANNING` + `FILES_MODIFIED: 0` in its
   `RALPH_STATUS` block.
4. **`on-stop.sh`** has a dedicated branch that treats
   `WORK_TYPE: PLANNING + RALPH_STATUS block present` as **productive** —
   `consecutive_no_progress` is reset, the same way EXIT-CLEAN resets it
   on a legitimate exit. Without this branch the zero-file Plan Mode
   loop would fall through to the no-progress arm and trip the CB.

The next loop (with the plan now in Linear / `fix_plan.md` and the brief
potentially still HIGH) either remains in Plan Mode or transitions back
to `bypassPermissions` once the coordinator is satisfied — the brief's
`risk_level` is the gate.

**Operator safety knobs**:
- Set `RALPH_PERMISSION_MODE` in the environment to pin a value (the
  harness honors a pre-set override and does NOT clobber it on HIGH-risk
  briefs — useful when an operator wants `acceptEdits` for an
  incident-response loop regardless of the coordinator's classification).
- A bare `WORK_TYPE: PLANNING` text response without a parseable
  `RALPH_STATUS` block does NOT trip the productivity branch — the
  no-progress counter still increments, so a stuck planner can be caught
  by the CB.

## Observability: Prompt Cache (TAP-1685)

Prompt caching is the single biggest input-token saving on the Ralph hot
path — when the stable system-prompt prefix (`CLAUDE.md` + agent file +
skill content) survives across loops, each loop pays cache-read prices on
those tokens instead of full input prices. When the prefix changes between
loops (template edits, skill updates, locality hints inserted at the wrong
position, USYNC-2 directive injections), the cache is busted and every
loop pays full freight. `status.json` captures the token-level signal
correctly via `loop_cache_read_tokens` / `loop_cache_create_tokens` /
`session_cache_read_tokens` / `session_cache_create_tokens`; `ralph-monitor`
surfaces it via a dedicated "Prompt cache" panel.

**Panel contents:**

```
┌─ Prompt cache (TAP-1685) ──────────────────────────────────────────────┐
│ Loop:           93% hit  (read=89000, create=200, in=6000)
│ Session:        91% hit  (read=910000, create=8000, in=80000)
└─────────────────────────────────────────────────────────────────────────┘
```

When the session hit rate drops below `RALPH_CACHE_HIT_RATE_WARN` (default
`30%`) the panel turns red and emits an extra line:

```
│ WARN:           session hit rate 12% < threshold 30% — investigate prompt-prefix instability (locality hints, skill edits, agent file drift)
```

Common causes of low hit rate:
- A skill / agent / CLAUDE.md edit landed mid-session (every subsequent loop refreshes the prefix).
- `build_loop_context` started injecting variable content high in the prompt — locality hints (TAP-593) and USYNC-2 directives (TAP-1683) are *prepended* on purpose, but any new prefix you add should go after the stable block.
- The session was Continue-As-New reset (CTXMGMT-3) — first post-reset loop is always cold.

Single-loop cold cache is normal (first loop after Continue-As-New, fresh
session, or after a Ralph install upgrade). The dashboard does not warn on
the loop-level percentage; only the rolling-session number triggers the
WARN, because that's the one that signals a sustained regression rather
than a one-off cold start.

## Observability: Task-Type Routing & QA Escalation

### Model Routing Decisions (.model_routing.jsonl)

When `RALPH_MODEL_ROUTING_ENABLED=true`, every loop appends a JSON line to `.ralph/.model_routing.jsonl` describing the routing decision — including loops where Claude bailed out before picking up a task (TAP-1210):

```json
{"timestamp":"2026-04-30T14:23:45Z","task_type":"code","model":"sonnet","retry_count":0,"reason":"type_code"}
{"timestamp":"2026-04-30T14:24:12Z","task_type":"docs","model":"haiku","retry_count":0,"reason":"type_haiku"}
{"timestamp":"2026-04-30T14:25:30Z","task_type":"code","model":"opus","retry_count":3,"reason":"qa_failure_escalation"}
{"timestamp":"2026-04-30T14:26:08Z","task_type":"none","model":"sonnet","retry_count":0,"reason":"no_task_fallback"}
```

**Fields**:
- `timestamp`: ISO-8601 time of routing decision
- `task_type`: `docs`, `tools`, `code`, `arch`, or `none` (empty-task / fallback path)
- `model`: Selected model (`haiku`, `sonnet`, `opus`)
- `retry_count`: QA failure count for the current issue (0–N)
- `reason`: Routing signal (`type_haiku`, `type_code`, `type_arch`, `qa_failure_escalation`, `no_task_fallback`)

**Observability queries**:

```bash
# Count routing decisions by type and model
jq -s 'group_by(.task_type) | map({type: .[0].task_type, count: length, models: (map(.model) | unique)})' .ralph/.model_routing.jsonl

# Find all QA escalations (retry_count >= 3)
jq 'select(.retry_count >= 3)' .ralph/.model_routing.jsonl

# Average model cost per task type (rough estimate: haiku~1, sonnet~3, opus~5)
jq -s 'group_by(.task_type) | map({type: .[0].task_type, avg_cost: (map({haiku:1, sonnet:3, opus:5}[.model]) | add / length)})' .ralph/.model_routing.jsonl

# Check for stuck tasks (same issue failing QA repeatedly)
jq 'select(.reason == "qa_failure_escalation") | {task_type, retry_count, timestamp}' .ralph/.model_routing.jsonl
```

### QA Failure State (.qa_failures.json)

Tracks consecutive QA failures per Linear issue:

```json
{"TAP-123": 2, "TAP-456": 1}
```

**Query**: Check current failure count for an issue:

```bash
jq '.["TAP-123"]' .ralph/.qa_failures.json
```

The count increments on QA failure (called by on-stop hook), resets on PASSING (via `qa_failures_reset`), and triggers Opus escalation at count ≥3.

## Observability: Telemetry Analyzer (`ralph --analyze`)

`ralph --analyze` (lib/telemetry_analyze.sh, `ralph_telemetry_analyze`) is a **read-only, always-exit-0** analyzer over the harness's *control-path* telemetry — the JSONL/state files each consumed by exactly one internal decision and otherwise never surfaced. It is the closed loop from telemetry → finding → action; it deliberately does **not** duplicate `ralph --stats` (which reads `.ralph/metrics/*.jsonl` for run counts / work-type / brain / skills). Human `[OK]/[WARN]/[SKIP]/[INFO]` output by default; `ralph --analyze --json` emits `{generated_at, findings:[{rule, severity, value, threshold, detail, hint}]}` (stable keys for dashboards). Never writes `.ralph/`.

Five v1 rules (each degrades to `[SKIP]` on a missing/empty file, so a fresh project is never an error):

1. **coordinator_timeout** — censored-p95 of `.coordinator_timings.jsonl` vs the live `ralph_compute_coordinator_timeout` budget; `WARN` at p95 ≥ 90% of budget.
2. **mainloop_timeout** — censored-p95 of `.invocation_latencies` vs `ralph_compute_adaptive_timeout` (minutes→seconds); same 90% rule.
3. **cache_hit_rate** — `session_cache_read / (read + create + session_input)` from `status.json` (the exact ralph_monitor.sh:480 formula) vs `RALPH_CACHE_HIT_RATE_WARN` (default 30); `WARN` below.
4. **opus_escalation** — counts `qa_failure_escalation` in the last `RALPH_ANALYZE_ROUTING_WINDOW` (default 200) lines of `.model_routing.jsonl`, naming stuck issues (`.qa_failures.json` value ≥3).
5. **coordinator_phase** — synthesis-dominated share + brain_recall-invoked count from `.coordinator_phase_timings.jsonl`. **This is the field signal OPERATOR-NOTES item #2 (coordinator→Haiku trial) is gated on** — when synthesis dominates, the analyzer says so.

The two timeout rules reuse the PR #54/#58 right-censor (`exit_code 124` → ×1.5) + ceiling-p95 method via the shared `_ta_percentile` helper, so the analyzer's percentile agrees with the value the harness enforces. Design: [docs/specs/story-telemetry-harvester.md](docs/specs/story-telemetry-harvester.md). Covered by `tests/unit/test_telemetry_analyze.bats` (17 cases).

## Testing

- **Framework**: BATS (Bash Automated Testing System) with bats-assert and bats-support
- **Prerequisites**: Node.js 18+, jq, git, gawk (mawk lacks `match(s, re, arr)` array capture used by PLANOPT-2)
- **Quality gate**: 100% test pass rate (code coverage via kcov is informational only due to subprocess tracing limitations)
- Tests live in `tests/unit/` and `tests/integration/`; helpers in `tests/helpers/`
- **Agent evals**: `tests/evals/deterministic/` (64 BATS tests, no LLM calls) and `tests/evals/stochastic/` (golden-file comparisons with Wilson score CI). Run via `npm run test:evals:deterministic` and `npm run test:evals:stochastic`.

### CI: blocking vs informational (TAP-537)

The `Test Suite` workflow in `.github/workflows/test.yml` has two job categories. Only the **blocking** ones gate merges. **Informational** ones must still surface failure signal — never silence with bare `|| true`:

| Step | Status | Why |
|------|--------|-----|
| `npm run test:unit` | **blocking** | Core invariants — every PR must keep these green |
| `npm run test:integration` | **blocking** | Was masked with `|| true`; mask hid real regressions for multiple releases (stale version assertion, missing exec bit on `tests/mock_claude.sh`, missing `ralph_upgrade_project.sh` test fixture). Now hard-fails. |
| `npm run test:evals:deterministic` | **blocking** | 64 deterministic checks of loop-correctness invariants (exit gate, circuit breaker, tool restrictions, hooks). No LLM cost. |
| `kcov` coverage steps | informational | Subprocess tracing is structurally incomplete in BATS-spawned bash. We keep it running but log stderr to `coverage/<label>.stderr.log` and emit a `::warning::` annotation instead of swallowing the exit code with `|| true`. |
| `npm run test:evals:stochastic` | informational | Runs N golden-file comparisons against live LLM; intended for nightly/manual jobs, not PR gating. |

When adding a new CI step, decide its category up front. If informational, capture stderr to an artifact + emit a GitHub annotation rather than `|| true` — silent masking is what TAP-537 rolled back.

## Versioning

The version string exists in **two** files that **must stay in sync**:

| File | Location | Format |
|------|----------|--------|
| `package.json` | `"version": "X.Y.Z"` | npm standard |
| `ralph_loop.sh` | `RALPH_VERSION="X.Y.Z"` (near top of file) | bash variable, powers `ralph --version` / `ralph -V` |

**When bumping the version** (release, build, or deploy), update **both** files to the same value. A mismatch means `ralph --version` will report a different version than `npm version` / `package.json`.

## Development Standards

- **Conventional commits**: `feat(module):`, `fix(module):`, `test(module):`, etc.
- **Branch naming**: `feature/<name>`, `fix/<name>`, `docs/<name>`
- All features must have passing tests, be committed and pushed, and have fix_plan.md updated
- Update this CLAUDE.md when introducing new patterns or changing loop behavior
- Keep template files in `templates/` synchronized with implementation changes

## Global Installation Layout

- **Commands** (`~/.local/bin/`): `ralph`, `ralph-monitor`, `ralph-setup`, `ralph-import`, `ralph-migrate`, `ralph-enable`, `ralph-enable-ci`, `ralph-sdk`, `ralph-doctor`, `ralph-upgrade`
- **Scripts and libs** (`~/.ralph/`): Main scripts + `lib/` modules
- **Templates** (`~/.ralph/templates/`): Project scaffolding templates
- **Upgrade backfill** (TAP-1883): `ralph-upgrade-project` now backfills missing `templates/.gitignore` patterns into consumer repos via the shared `merge_gitignore_block` helper. Runs as a Tier 2 merge alongside `.ralphrc` and `settings.json`. Idempotent (second run is a no-op), preserves user-added `.gitignore` entries byte-for-byte, honors `--dry-run`.
- **Global Claude skills** (`~/.claude/skills/`): Tier S baseline synced from `templates/skills/global/` via `lib/skills_install.sh`. Ralph-installed skill dirs carry a `.ralph-managed` sidecar; user-authored skills or user-modified files are never touched (TAP-574). The canonical library is maintained in-repo under `templates/skills/global/<name>/` with `SKILL.md` + `examples/` — currently 6 Tier S skills: `search-first`, `tdd-workflow`, `simplify`, `context-audit`, `agentic-engineering`, **`ralph-runner`** (operator-side skill that orchestrates a Ralph campaign end-to-end — startup, monitor, friction-reporting). Each is enforced by `tests/unit/test_skill_frontmatter.bats` + `test_skill_content.bats` (TAP-575). **Three install paths** all call `skills_install_global` and are idempotent: (1) `install.sh main` at fresh Ralph install, (2) `install.sh upgrade` invoked by `ralph-upgrade` after pulling a new Ralph version, (3) `ralph-upgrade-project` — runs the host-wide skill sync once before per-project Tier 1/2 work, so an operator who only runs `ralph-upgrade-project` after pulling Ralph still gets new operator skills without a separate `ralph-upgrade` step. The `python-introspection` skill ships in the directory but is intentionally outside the test set (read-only utility skill, not part of the Tier S enforcement contract).

<!-- BEGIN: karpathy-guidelines c9a44ae (MIT, forrestchang/andrej-karpathy-skills) -->
<!--
  Vendored from https://github.com/forrestchang/andrej-karpathy-skills
  Pinned commit: c9a44ae835fa2f5765a697216692705761a53f40 (2026-04-15)
  License: MIT (c) forrestchang
  Do not edit by hand — update KARPATHY_GUIDELINES_SOURCE_SHA in prompt_loader.py
  and re-run the vendor script, then bump tapps-mcp version.
-->
## Karpathy Behavioral Guidelines

> Source: https://github.com/forrestchang/andrej-karpathy-skills @ c9a44ae835fa2f5765a697216692705761a53f40 (MIT)
> Derived from [Andrej Karpathy's observations](https://x.com/karpathy/status/2015883857489522876) on LLM coding pitfalls.

Behavioral guidelines to reduce common LLM coding mistakes. Merge with project-specific instructions as needed.

**Tradeoff:** These guidelines bias toward caution over speed. For trivial tasks, use judgment.

### 1. Think Before Coding

**Don't assume. Don't hide confusion. Surface tradeoffs.**

Before implementing:
- State your assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them - don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

### 2. Simplicity First

**Minimum code that solves the problem. Nothing speculative.**

- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility" or "configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.

### 3. Surgical Changes

**Touch only what you must. Clean up only your own mess.**

When editing existing code:
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor things that aren't broken.
- Match existing style, even if you'd do it differently.
- If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:
- Remove imports/variables/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.

### 4. Goal-Driven Execution

**Define success criteria. Loop until verified.**

Transform tasks into verifiable goals:
- "Add validation" → "Write tests for invalid inputs, then make them pass"
- "Fix the bug" → "Write a test that reproduces it, then make it pass"
- "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:
```
1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]
```

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

---

**These guidelines are working if:** fewer unnecessary changes in diffs, fewer rewrites due to overcomplication, and clarifying questions come before implementation rather than after mistakes.
<!-- END: karpathy-guidelines -->

<!-- BEGIN: tapps-obligations v3.8.0 -->
# TAPPS Quality Pipeline

This project uses the TAPPS MCP server for code quality enforcement.
Every tool response includes `next_steps` - consider following them.
Full pipeline details are in `.claude/rules/tapps-pipeline.md` (auto-loaded for Python and infra files).

## Recommended Tool Call Obligations

You should follow these steps to avoid broken, insecure, or hallucinated code.

### Session Start

You should call `tapps_session_start()` as the first action in every session.
This returns server info (version, checkers, config) and project context.

### Before Using Any Library API

You should call `tapps_lookup_docs(library, topic)` before writing code that uses an external library.
This prevents hallucinated APIs. Prefer looking up docs over guessing from memory.

### After Editing Any Python File

You should call `tapps_quick_check(file_path)` after editing any Python file.
This runs scoring + quality gate + security scan in a single call.

### Before Declaring Work Complete

For multi-file changes: You should call `tapps_validate_changed(file_paths="file1.py,file2.py")` with explicit paths to batch-validate changed files. **Always pass `file_paths`** — auto-detect scans all git-changed files and can be very slow. Default is quick mode; only use `quick=false` as a last resort (pre-release, security audit).
Run the quality gate before considering work done.
You should call `tapps_checklist(task_type)` as the final step to verify no required tools were skipped.

### Domain Decisions

You should call `tapps_lookup_docs(library, topic)` when you need domain-specific guidance
(security patterns, testing strategy, API design, database best practices, etc.).

### Refactoring or Deleting Files

You should call `tapps_impact_analysis(file_path)` before refactoring or deleting any file.
This maps the blast radius via import graph analysis.

### Infrastructure Config Changes

You should call `tapps_validate_config(file_path)` when changing Dockerfile, docker-compose, or infra config.

## Memory System

`tapps_memory` provides persistent cross-session knowledge with **33 actions** (save, search, consolidate, federation, profiles, hive, health, and more). **Tiers:** architectural (180d), pattern (60d), procedural (30d), context (14d). **Scopes:** project, branch, session, shared. Max 1500 entries. Configure `memory_hooks` in `.tapps-mcp.yaml` for auto-recall and auto-capture.

## Quality Gate Behavior

Gate failures are sorted by category weight (highest-impact first).
A security floor of 50/100 is enforced regardless of overall score.

## Upgrade & Rollback

After upgrading TappsMCP, run `tapps_upgrade` to refresh generated files.
A timestamped backup is created before overwriting. Use `tapps-mcp rollback` to restore.
To protect customized files from upgrade, add them to `upgrade_skip_files` in `.tapps-mcp.yaml`.
<!-- END: tapps-obligations -->
