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

- **ralph_loop.sh** (~2200 lines) — Core autonomous loop. Reads instructions, executes Claude Code CLI, tracks progress, evaluates completion, repeats. Manages rate limiting, session continuity, and circuit breaker state.
- **ralph_monitor.sh** — Live tmux dashboard showing loop count, API usage, and recent logs.
- **setup.sh** — Creates new Ralph-managed projects with `.ralph/` directory structure.
- **ralph_import.sh** — Converts PRD/specification documents into Ralph task format using Claude Code CLI with JSON output.
- **ralph_enable.sh** — Interactive wizard to enable Ralph in existing projects. Detects project type, imports tasks from beads/GitHub/PRD sources.
- **ralph_enable_ci.sh** — Non-interactive version of ralph_enable for CI/automation (JSON output, exit codes 0/1/2).
- **create_files.sh** — Bootstrap script that creates the Ralph system files.

### Library Modules (lib/)

| Module | Purpose |
|--------|---------|
| `response_analyzer.sh` | Parses Claude CLI output (JSON/text), extracts exit signals, manages sessions, detects questions |
| `circuit_breaker.sh` | Three-state pattern (CLOSED/HALF_OPEN/OPEN) to halt runaway loops on stagnation |
| `enable_core.sh` | Shared logic for ralph_enable and ralph_enable_ci (idempotency, detection, template generation) |
| `task_sources.sh` | Task import from beads, GitHub Issues, or PRD documents |
| `wizard_utils.sh` | Interactive prompt utilities (confirm, select, text input) |
| `date_utils.sh` | Cross-platform date/epoch utilities |
| `timeout_utils.sh` | Cross-platform timeout command detection (`timeout` on Linux, `gtimeout` on macOS) |
| `file_protection.sh` | Pre-loop integrity validation of `.ralph/` directory |

### Key Design Patterns

**Dual-condition exit gate**: Loop exit requires BOTH `completion_indicators >= 2` (NLP heuristics) AND Claude's explicit `EXIT_SIGNAL: true` in the RALPH_STATUS block. This prevents premature exits when Claude says "done" mid-phase.

**Four-layer API limit detection**: (1) Timeout guard (exit code 124), (2) Structural JSON `rate_limit_event` parsing, (3) Filtered text fallback on last 30 lines, (4) Extra Usage quota detection. Layers 3-4 filter out echoed project file content to avoid false positives.

**Circuit breaker auto-recovery**: OPEN state is not terminal — after a cooldown period (default 30 min) it transitions to HALF_OPEN, then back to CLOSED on progress. `CB_AUTO_RESET=true` bypasses cooldown for unattended operation.

**Session continuity**: Claude session IDs persist in `.ralph/.claude_session_id` with 24-hour expiration. Sessions auto-reset on circuit breaker open, manual interrupt, or `is_error: true` API responses.

**File protection**: Three layers — (1) granular `ALLOWED_TOOLS` restrictions prevent destructive git commands, (2) PROMPT.md warns Claude not to modify `.ralph/`, (3) `validate_ralph_integrity()` runs before every loop iteration.

### State Files (in `.ralph/` within managed projects)

- `.call_count` / `.last_reset` — Rate limit tracking (hourly reset)
- `.exit_signals` — Exit signal history
- `.response_analysis` — Last response analysis (JSON)
- `.circuit_breaker_state` — Circuit breaker state (JSON)
- `.claude_session_id` — Session persistence
- `PROMPT.md` — Main development instructions driving each loop
- `fix_plan.md` — Prioritized task list
- `AGENT.md` — Build/run instructions
- `status.json` — Real-time status

### Configuration

Project-level config lives in `.ralphrc` (sourced as bash). Key variables:
- `CLAUDE_CODE_CMD` — CLI command (default: `"claude"`, fallback: `"npx @anthropic-ai/claude-code"`)
- `CLAUDE_OUTPUT_FORMAT` — `json` (default) or `text`
- `CLAUDE_ALLOWED_TOOLS` — Tool permission whitelist
- `CLAUDE_USE_CONTINUE` — Session continuity toggle
- `CLAUDE_AUTO_UPDATE` — Auto-update CLI at startup (disable for Docker/air-gapped)
- `CB_COOLDOWN_MINUTES`, `CB_AUTO_RESET` — Circuit breaker recovery config

Environment variables override `.ralphrc` settings.

## Testing

- **Framework**: BATS (Bash Automated Testing System) with bats-assert and bats-support
- **Prerequisites**: Node.js 18+, jq, git
- **Quality gate**: 100% test pass rate (code coverage via kcov is informational only due to subprocess tracing limitations)
- Tests live in `tests/unit/` and `tests/integration/`; helpers in `tests/helpers/`

## Development Standards

- **Conventional commits**: `feat(module):`, `fix(module):`, `test(module):`, etc.
- **Branch naming**: `feature/<name>`, `fix/<name>`, `docs/<name>`
- All features must have passing tests, be committed and pushed, and have fix_plan.md updated
- Update this CLAUDE.md when introducing new patterns or changing loop behavior
- Keep template files in `templates/` synchronized with implementation changes

## Global Installation Layout

- **Commands** (`~/.local/bin/`): `ralph`, `ralph-monitor`, `ralph-setup`, `ralph-import`, `ralph-migrate`, `ralph-enable`, `ralph-enable-ci`
- **Scripts and libs** (`~/.ralph/`): Main scripts + `lib/` modules
- **Templates** (`~/.ralph/templates/`): Project scaffolding templates
