# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

Ralph is an autonomous AI development loop for Claude Code. It repeatedly invokes the Claude Code CLI, tracks progress, detects completion, and manages rate limits and error recovery. The entire codebase is **bash/shell** — no JavaScript, Python, or TypeScript runtime code.

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
./install.sh uninstall
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
| `task_sources.sh` | Task import from beads, GitHub Issues, or PRD documents |
| `wizard_utils.sh` | Interactive prompt utilities (confirm, select, text input) |
| `date_utils.sh` | Cross-platform date/epoch utilities |
| `timeout_utils.sh` | Cross-platform timeout command detection (`timeout` on Linux, `gtimeout` on macOS) |
| `metrics.sh` | Lightweight metrics — monthly JSONL in `.ralph/metrics/`, `ralph --stats` summary (Phase 8) |
| `notifications.sh` | Local notifications — terminal, OS native, webhook POST, sound (Phase 8) |
| `backup.sh` | State backup/rollback — auto-snapshots, `ralph --rollback`, max 10 backups (Phase 8) |
| `github_issues.sh` | GitHub Issue integration — import, assess, filter, batch, lifecycle (Phase 10) |
| `sandbox.sh` | Docker sandbox — `ralph --sandbox`, container management, signal forwarding (Phase 11) |
| ~~`response_analyzer.sh`~~ | Removed — response analysis handled by `on-stop.sh` hook → `status.json` |
| ~~`file_protection.sh`~~ | Removed — file protection handled by PreToolUse hooks |

### SDK (sdk/)

Python Agent SDK for dual-mode operation (Phase 6):

| Module | Purpose |
|--------|---------|
| `ralph_sdk/agent.py` | Core agent class — RalphAgent, RalphAgentInterface, TaskInput, TaskResult |
| `ralph_sdk/config.py` | Configuration loader — .ralphrc, ralph.config.json, environment, with full precedence chain |
| `ralph_sdk/tools.py` | Custom tools — ralph_status, ralph_rate_check, ralph_circuit_state, ralph_task_update |
| `ralph_sdk/status.py` | Status management — RalphStatus, CircuitBreakerState (compatible with bash status.json) |
| `ralph_sdk/__main__.py` | CLI entry point — `ralph --sdk` or `python -m ralph_sdk` |

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

Environment variables override `.ralphrc` settings.

## Testing

- **Framework**: BATS (Bash Automated Testing System) with bats-assert and bats-support
- **Prerequisites**: Node.js 18+, jq, git
- **Quality gate**: 100% test pass rate (code coverage via kcov is informational only due to subprocess tracing limitations)
- Tests live in `tests/unit/` and `tests/integration/`; helpers in `tests/helpers/`

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
