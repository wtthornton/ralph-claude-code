# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

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
| `complexity.sh` | Task complexity classifier — 5-level (TRIVIAL→ARCHITECTURAL), dynamic model routing (Phase 14) |
| `memory.sh` | Cross-session memory — episodic (what worked/failed), semantic (project index), decay/pruning (Phase 14) |
| `import_graph.sh` | AST-based file dependency graph — Python `ast`, JS/TS `madge`/grep fallback. Cached in `.ralph/.import_graph.json` with mtime staleness detection. Async background rebuild, incremental invalidation via hooks. (PLANOPT epic) |
| `plan_optimizer.sh` | Fix plan task reordering — parses fix_plan.md, resolves vague tasks via ralph-explorer (Haiku), detects dependencies via import graph + explicit metadata + phase convention, orders via Unix `tsort`, validates semantic equivalence before atomic write. Runs at session start for changed sections only. (PLANOPT epic) |
| ~~`response_analyzer.sh`~~ | Removed — response analysis handled by `on-stop.sh` hook → `status.json` |
| ~~`file_protection.sh`~~ | Removed — file protection handled by PreToolUse hooks |

### SDK (sdk/) — v2.1.0

Python Agent SDK for dual-mode operation. All models are **Pydantic v2 BaseModels**. The agent loop is **fully async** with a `run_sync()` wrapper for CLI. State I/O goes through a **pluggable state backend** (`FileStateBackend` default, `NullStateBackend` for testing/embedding).

| Module | Purpose |
|--------|---------|
| `ralph_sdk/agent.py` | Async agent class — RalphAgent, TaskInput (frozen), TaskResult, ProgressSnapshot, CancelResult, DecompositionHint, ContinueAsNewState, run_sync() wrapper. Includes adaptive timeout, completion indicator decay, session lifecycle management. |
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

**Four-layer API limit detection**: (1) Timeout guard (exit code 124), (2) Structural JSON `rate_limit_event` parsing, (3) Filtered text fallback on last 30 lines, (4) Extra Usage quota detection. Layers 3-4 filter out echoed project file content to avoid false positives.

**Circuit breaker auto-recovery**: OPEN state is not terminal — after a cooldown period (default 30 min) it transitions to HALF_OPEN, then back to CLOSED on progress. `CB_AUTO_RESET=true` bypasses cooldown for unattended operation.

**Session continuity**: Claude session IDs persist in `.ralph/.claude_session_id` with 24-hour expiration. Sessions auto-reset on circuit breaker open, manual interrupt, or `is_error: true` API responses.

**File protection**: Two layers — (1) granular `ALLOWED_TOOLS` restrictions prevent destructive git commands, (2) PreToolUse hooks (`protect-ralph-files.sh`, `validate-command.sh`) block modifications to `.ralph/` in real-time.

**Hook-based response analysis**: The `on-stop.sh` hook runs after every Claude response, extracts RALPH_STATUS fields (auto-unescaping JSON-encoded `\n` from JSONL stream output), writes `status.json`, and updates circuit breaker state. The loop reads from `status.json` instead of parsing raw CLI output. The hook includes a text fallback when no JSON path matches the response payload, and infers `WORK_TYPE: IMPLEMENTATION` when files are modified but the field is UNKNOWN. Atomic writes use `rm -f` after `mv` to prevent orphaned temp files on WSL/NTFS.

**Log rotation**: `rotate_ralph_log()` rotates `ralph.log` when it exceeds `LOG_MAX_SIZE_MB` (default 10). `cleanup_old_output_logs()` prunes old `claude_output_*.log` files beyond `LOG_MAX_OUTPUT_FILES` (default 20). Both run at startup and every loop iteration.

**Dry-run mode**: `--dry-run` or `DRY_RUN=true` simulates a loop iteration without calling the Claude API. Writes a `status.json` with `status: "DRY_RUN"` and exits after one iteration. Useful for validating configuration and tool permissions.

**WSL/Windows version divergence detection**: `check_version_divergence()` runs at startup in WSL environments. Compares `RALPH_VERSION` between `~/.ralph/ralph_loop.sh` (WSL) and `/mnt/c/Users/*/.ralph/ralph_loop.sh` (Windows). Warns if versions differ and detects stale `response_analyzer.sh` files.

**WSL PowerShell auto-patching (XPLAT-2b)**: `ralph_validate_hooks()` now also inspects the target project's `.claude/settings.json` for hooks calling bare `powershell` (which is unavailable in WSL — requires `powershell.exe`). When detected, Ralph auto-patches the settings file in-place via `sed`, skipping lines that already use `powershell.exe`. This prevents session-start hook errors when running Ralph against Windows-native projects from WSL.

**MCP server process cleanup (MCP-CLEANUP)**: Claude Code spawns MCP servers (tapps-mcp, docsmcp via `uv`) as grandchild processes. On Windows, these survive after the CLI exits because process group teardown doesn't cascade — each loop iteration leaks one `uv` + `python` pair per MCP server. `ralph_cleanup_orphaned_mcp()` runs after every CLI invocation and in the exit trap, killing only **orphaned** MCP processes (parent process dead) to avoid disrupting MCP servers belonging to the user's editor (Cursor, VS Code). On Windows/MINGW it uses a temp PowerShell script with `Get-CimInstance Win32_Process` + parent-alive check (10s timeout guard); on Linux/macOS/WSL it uses `pgrep`/`kill` filtering by PPID==1.

**Sub-agents**: Four specialized agents keep search, testing, review, and complex architecture work out of the main context:
- **ralph-explorer** (Haiku) — fast codebase search
- **ralph-tester** (Sonnet, worktree-isolated) — test runner
- **ralph-reviewer** (Sonnet, read-only) — code review
- **ralph-architect** (Opus) — complex/architectural tasks with mandatory code review

The main Ralph agent (Sonnet) handles routine work with task batching (up to 5 small / 3 medium tasks per invocation) and delegates LARGE tasks to ralph-architect.

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

**Design documentation**: Reliability epics and stories live in **`docs/specs/`** (e.g. `epic-jsonl-stream-resilience.md`, `epic-multi-task-cascading-failures.md`). Long-term platform integration is drafted in `docs/specs/claude-code-2026-enhancements.md`.

### State Files (in `.ralph/` within managed projects)

- `.call_count` / `.last_reset` — Rate limit tracking (hourly reset)
- `.exit_signals` — Exit signal history
- `status.json` — Real-time status and response analysis (written by on-stop.sh hook)
- `.circuit_breaker_state` — Circuit breaker state (JSON)
- `.claude_session_id` — Session persistence
- `PROMPT.md` — Main development instructions driving each loop
- `fix_plan.md` — Prioritized task list
- `AGENT.md` — Build/run instructions

### Configuration

Project-level config lives in `.ralphrc` (sourced as bash). Key variables:
- `CLAUDE_CODE_CMD` — CLI command (default: `"claude"`, fallback: `"npx @anthropic-ai/claude-code"`)
- `CLAUDE_OUTPUT_FORMAT` — `json` (default) or `text`
- `ALLOWED_TOOLS` / `CLAUDE_ALLOWED_TOOLS` — Tool permission whitelist (defaults include `Bash(git -C *)`, `Bash(grep *)`, `Bash(find *)`; see `templates/ralphrc.template`)
- `CLAUDE_USE_CONTINUE` — Session continuity toggle
- `CLAUDE_AUTO_UPDATE` — Auto-update CLI at startup (disable for Docker/air-gapped)
- `CB_COOLDOWN_MINUTES`, `CB_AUTO_RESET` — Circuit breaker recovery config
- `LOG_MAX_SIZE_MB` — Max ralph.log size before rotation (default: 10)
- `LOG_MAX_FILES` — Number of rotated log files to keep (default: 5)
- `LOG_MAX_OUTPUT_FILES` — Max claude_output_*.log files to keep (default: 20)
- `DRY_RUN` — Preview loop execution without API calls (also `--dry-run` flag)
- `RALPH_NO_OPTIMIZE` — Disable automatic fix_plan.md reordering on session start
- `RALPH_NO_EXPLORER_RESOLVE` — Disable ralph-explorer file resolution for vague tasks
- `RALPH_MAX_EXPLORER_RESOLVE` — Max vague tasks to resolve per optimization run (default: 5)

Environment variables override `.ralphrc` settings.

## Testing

- **Framework**: BATS (Bash Automated Testing System) with bats-assert and bats-support
- **Prerequisites**: Node.js 18+, jq, git
- **Quality gate**: 100% test pass rate (code coverage via kcov is informational only due to subprocess tracing limitations)
- Tests live in `tests/unit/` and `tests/integration/`; helpers in `tests/helpers/`
- **Agent evals**: `tests/evals/deterministic/` (64 BATS tests, no LLM calls) and `tests/evals/stochastic/` (golden-file comparisons with Wilson score CI). Run via `npm run test:evals:deterministic` and `npm run test:evals:stochastic`.

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
