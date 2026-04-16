# ralph-claude-code

## What's New in v2.6.0

**14 open issues resolved**, 24 pre-existing test failures fixed, 1,026 total tests passing.

- **Token-based rate limiting** (#223) — `MAX_TOKENS_PER_HOUR` tracks cumulative token usage alongside invocation count. `--max-tokens` CLI flag, status line display, hourly reset.
- **SDK parity** (#226) — Progressive context (`trim_fix_plan` with section targeting), 3-strategy `extract_files_changed()` (Write/Edit + git add + git diff --name-only), stall detection config alignment.
- **E2E integration tests** (#225) — Mock Claude CLI (`tests/mock_claude.sh`) with 7 scenarios. 28 new E2E tests for completion, circuit breaker, rate limit, and permission denial flows.
- **Task import tests** (#152) — 28 integration tests for beads JSON/text parsing, GitHub filtering, combined sources, deduplication.
- **Plan limit exhaustion** (#102) — Parses reset time from Claude output ("resets 9pm"), calculates wait, auto-sleeps with countdown timer.
- **Monorepo support** (#163) — `--service NAME` flag scopes Ralph to a service directory. Auto-detection in `ralph-enable`. `MONOREPO_SERVICES` / `MONOREPO_ROOT` config.
- **Windows native** (#156) — `ralph.ps1` PowerShell wrapper (WSL/Git Bash auto-detection), `ralph.cmd` CMD wrapper, `--wt` Windows Terminal split-pane monitoring.
- **Nix flake** (#157) — `nix shell github:frankbria/ralph-claude-code` for instant usage. Dev shell with all dependencies.
- **Badge automation** (#138) — GitHub Actions workflow auto-updates version/test count badges on push to main.
- **Beads integration** (#87) — Enhanced `fetch_beads_tasks()` with priority/assignee extraction, `BEADS_PROJECT` scoping, `--beads` CLI shortcut.
- **KEEP_MONITOR_AFTER_EXIT** (#213) — Preserves tmux monitor panes after loop exits.
- **.zshrc loading** (#211) — Sources shell rc files and checks nvm/fnm/volta paths before "CLI not found" error.
- **Session format consistency** (#123) — `save_claude_session()` now writes JSON format with backward-compatible reading.
- **README update** (#82) — Features table (24 capabilities), CLI flags (+8), library modules (+11), updated roadmap.

<details>
<summary><strong>v2.5.0</strong></summary>

- **SDK plan optimizer** — Plan optimization now runs inside `RalphAgent.run()` before the first iteration. TheStudio and all SDK consumers get automatic task reordering for free — no integration changes needed. Disable with `RALPH_NO_OPTIMIZE=true`.
- **SDK import graph** — Python AST + JS/TS regex dependency graph with JSON caching and staleness detection. Cross-platform path normalization.
- **SDK complexity classifier** — 5-level task classifier (TRIVIAL→ARCHITECTURAL) ported from bash. Annotation overrides, keyword scoring, file count heuristics, retry escalation. Feeds into `select_model()` for dynamic model routing.
- **SDK episodic memory** — Cross-session memory with pluggable `MemoryBackend` protocol. Keyword-based retrieval with failure bias and age decay. Project index auto-detection.
- **Build-time version manifest** — `generate_version_manifest.sh` reads versions from canonical sources, writes `version.json`. SDK exposes `get_versions()`. Dockerfile updated with OCI labels.
- **Default rate limit bumped to 200/hr** — Better match for current Claude plan tiers.
- **Upstream sync epic** — Question detection, permission denial CB fast-trip, stuck loop detection, heuristic exit suppression.
- **SDK v2.1.0** — 5 new modules: `complexity.py`, `memory.py`, `import_graph.py`, `plan_optimizer.py`, `versions.py`.

</details>

<details>
<summary><strong>v2.4.0</strong></summary>

- **Plan optimization (bash)** — Automatic fix_plan.md task reordering at session start. AST-based import graph (Python/JS/TS) detects real file dependencies, Unix `tsort` for topological ordering, module grouping, phase ordering (create→implement→test→document), size clustering for better batching.
- **ralph-explorer task resolution** — Vague tasks without file paths automatically resolved to specific files via ralph-explorer (Haiku)
- **Batch hints** — Session start context includes batch boundary annotations
- **Progress re-grounding** — Session context includes last completed task (Reflexion pattern)
- **`/optimize` skill** — Manual plan optimization via slash command
- **CLAUDE_MODEL / CLAUDE_EFFORT config** — New `.ralphrc` variables
- **48 new tests** — Import graph (12), plan optimizer (12), session start integration (24)

</details>

<details>
<summary><strong>v2.3.2</strong></summary>

- **jq bootstrap** — Installer auto-downloads official jq static binary to `~/.local/bin` when jq is missing (Linux/macOS)
- **ralph-doctor** — Prepends `~/.local/bin` to PATH so bundled jq is detected correctly
- **RELEASE.md** — Release checklist for version bumps, docs, tests, and deploy
- **WSL/CRLF** — README notes for `bash install.sh` and line-ending handling on Windows checkouts

</details>

<details>
<summary><strong>v2.3.1</strong></summary>

- Version bump — Ralph v2.3.1, SDK v2.0.3 (now superseded by SDK v2.1.0)

</details>

<details>
<summary><strong>v1.9.0</strong></summary>

- **Cost-aware agent routing** — Main ralph agent runs on Sonnet for speed; complex/architectural tasks delegate to ralph-architect (Opus) with mandatory code review
- **Task batching** — Up to 8 small / 5 medium tasks per invocation with epic-boundary QA deferral
- **Speed optimizations** — `bypassPermissions` mode, disabled PostToolUse hooks, reduced inter-loop pause (5s → 2s), subprocess batching (~50 → ~10 jq calls per loop), version caching
- **Epic-boundary deferral** — QA (tester + reviewer), explorer, backups, and log rotation deferred to epic boundaries for faster throughput
- **Live stream text filtering** — Stream metadata, raw JSON dumps, and UUID patterns suppressed; text collapsed and truncated for readability
- **Circuit breaker decay** — Sliding window and session reinitialization support
- **Cross-platform compatibility** — Hook environment detection, version divergence fixes, Python3 WSL alias handling

</details>

<details>
<summary><strong>Previous releases</strong></summary>

**v1.8.2** — Agent mode prompt fix, live stream JSONL suppression, Windows `.cmd` wrapper, WSL deploy line-ending fixes

**v1.8.1** — Phases 6-11 (SDK integration, observability, GitHub Issues, Docker sandbox, validation testing), version badge correction

**v1.2.0** — Stream Parser v2, RALPH_STATUS auto-unescaping, WSL reliability polish, 42/42 epic stories complete

**v1.1.0** — Agent teams + parallelism, log rotation, dry-run mode, WSL/Windows version divergence detection

**v1.0.0** — Hooks + agent definitions, sub-agents (explorer, tester, reviewer), skills framework, bash reduction (-1,385 lines)

**v0.11.x** — Live streaming, interactive enable wizard, stream resilience, session continuity, circuit breaker auto-recovery

</details>

## Features

| Category | Capability |
|----------|-----------|
| **Core Loop** | Autonomous development cycles with structured task execution |
| **Exit Detection** | Dual-condition gate: completion indicators + explicit `EXIT_SIGNAL` |
| **Rate Limiting** | Hourly API call + token limits with countdown timers and plan exhaustion auto-sleep |
| **Circuit Breaker** | Three-state pattern (CLOSED/HALF_OPEN/OPEN) with auto-recovery, fast-trip, stall detection |
| **Session Continuity** | Context preserved across loops with 24-hour expiration |
| **Live Streaming** | Real-time Claude Code output with `--live` flag |
| **Agent Teams** | Parallel task execution with teammate coordination (experimental) |
| **Sub-agents** | Explorer (read-only), tester (worktree isolation), reviewer, architect, background tester |
| **Hook System** | 8 hook events for response analysis, file protection, and command validation |
| **Monitoring** | tmux dashboard with loop count, API usage, and live logs (`KEEP_MONITOR_AFTER_EXIT` option) |
| **Task Import** | From PRDs, beads, or GitHub Issues via `ralph-enable` wizard |
| **Configuration** | `.ralphrc` per-project settings with tool permission control |
| **Log Rotation** | Automatic `ralph.log` rotation at configurable size limit |
| **Dry-Run Mode** | Preview loop execution without API calls (`--dry-run`) |
| **Metrics** | Monthly JSONL metrics, `ralph --stats` summary, `--stats-json` for machine-readable |
| **Notifications** | Terminal, OS native, webhook POST, and terminal bell alerts |
| **Backup/Rollback** | Auto-snapshots before each loop, `ralph --rollback` to restore state |
| **GitHub Issues** | `ralph --issue NUM` import, `ralph --batch` processing, lifecycle management |
| **Docker Sandbox** | `ralph --sandbox` runs loop inside Docker container with signal forwarding |
| **Cost Dashboard** | `ralph --cost-dashboard` with per-model breakdown and budget tracking |
| **Plan Optimization** | Automatic fix_plan.md task reordering by dependency graph at session start |
| **Python SDK** | Full SDK (`sdk/ralph_sdk/`) with async agent loop, Pydantic v2 models, pluggable state |

## Quick Start

```
INSTALL ONCE              USE EVERYWHERE
+-----------------+          +----------------------+
| ./install.sh    |    ->    | ralph-setup project1 |
|                 |          | ralph-enable         |
| Adds global     |          | ralph-import prd.md  |
| commands        |          | ...                  |
+-----------------+          +----------------------+
```

### 1. Install Ralph (one time)

```bash
git clone https://github.com/frankbria/ralph-claude-code.git
cd ralph-claude-code
./install.sh
```

This adds `ralph`, `ralph-monitor`, `ralph-setup`, `ralph-import`, `ralph-migrate`, `ralph-enable`, and `ralph-enable-ci` to your PATH.

**Dependencies:** Node.js, `git`, `jq`, GNU coreutils (`timeout`). **`jq`:** If `jq` is not installed, the installer can download an official static binary into `~/.local/bin/jq` on Linux and macOS (requires `curl` or `wget`). To skip that and require a system package instead, set `RALPH_SKIP_JQ_BOOTSTRAP=1` before running `install.sh`.

**WSL / Windows checkouts:** Run install from WSL. Put `~/.local/bin` on your `PATH` so `ralph` and bundled `jq` are found. Repo shell scripts use LF line endings (see `.gitattributes`); if you still see `$'\r'` errors, run `sed -i 's/\r$//' install.sh` in WSL or use `git config core.autocrlf input` and re-checkout.

### Alternative: Install with Nix

If you use [Nix](https://nixos.org/) with flakes enabled, you can run Ralph without cloning:

```bash
nix shell github:frankbria/ralph-claude-code
ralph --version

git clone https://github.com/frankbria/ralph-claude-code.git
cd ralph-claude-code
nix develop
```

### 2. Set up a project

```bash
cd my-project
ralph-enable                    # Interactive wizard

ralph-import requirements.md my-app

ralph-setup my-project
```

### 3. Run

```bash
ralph --monitor                 # Integrated tmux monitoring (recommended)
ralph --live                    # Real-time streaming output
ralph                           # Headless mode
```

### Uninstalling

```bash
./uninstall.sh
```

## How It Works

```
┌─────────────────────────────────────────────────────────┐
│                    Ralph Main Loop                       │
│                                                         │
│  1. Read PROMPT.md ──> 2. Execute Claude Code           │
│         ↑                        │                      │
│         │                        ▼                      │
│  5. Repeat ◄──── 4. Evaluate ◄── 3. on-stop.sh hook    │
│     (or exit)       exit gate       writes status.json  │
└─────────────────────────────────────────────────────────┘
```

**Dual-condition exit gate** — Ralph exits only when BOTH conditions are met:
1. `completion_indicators >= 2` (NLP heuristics)
2. Claude's explicit `EXIT_SIGNAL: true` in the RALPH_STATUS block

This prevents premature exits when Claude says "done" mid-phase but hasn't actually finished.

**Other exit conditions:** all fix_plan.md tasks complete, consecutive done signals, test saturation, permission denied, or API limit reached.

## Architecture

### Scripts

| Script | Purpose |
|--------|---------|
| `ralph_loop.sh` | Core autonomous loop (~2,500 lines) |
| `ralph_monitor.sh` | Live tmux dashboard |
| `ralph_enable.sh` | Interactive project enablement wizard |
| `ralph_enable_ci.sh` | Non-interactive enablement for CI |
| `ralph_import.sh` | PRD/specification document importer |
| `install.sh` / `uninstall.sh` | Global installation management |

### Library Modules (`lib/`)

| Module | Purpose |
|--------|---------|
| `circuit_breaker.sh` | Three-state pattern with cooldown/auto-recovery |
| `enable_core.sh` | Shared enablement logic |
| `task_sources.sh` | Task import from beads/GitHub/PRD |
| `wizard_utils.sh` | Interactive prompt utilities |
| `date_utils.sh` | Cross-platform date/epoch utilities |
| `timeout_utils.sh` | Cross-platform timeout detection |
| `metrics.sh` | Monthly JSONL metrics, `--stats` summary |
| `notifications.sh` | Terminal, OS native, webhook notifications |
| `backup.sh` | State backup/rollback, auto-snapshots |
| `github_issues.sh` | GitHub issue import, assess, filter, batch, lifecycle |
| `sandbox.sh` | Docker sandbox execution, signal forwarding |
| `tracing.sh` | OpenTelemetry traces, OTLP export |
| `complexity.sh` | Task complexity classification, dynamic model routing |
| `memory.sh` | Cross-session episodic + semantic memory |
| `import_graph.sh` | AST-based file dependency graph |
| `plan_optimizer.sh` | Fix plan task reordering via topological sort |
| `context_management.sh` | Progressive context loading, task decomposition hints |

### Agent Definitions (`.claude/agents/`)

| Agent | Model | Purpose |
|-------|-------|---------|
| `ralph.md` | Opus | Main development agent (maxTurns 50) |
| `ralph-explorer.md` | Haiku | Read-only codebase exploration |
| `ralph-tester.md` | Sonnet | Testing with worktree isolation |
| `ralph-reviewer.md` | Sonnet | Code review (read-only) |
| `ralph-bg-tester.md` | Sonnet | Background testing (report-only) |

### Hook System (`.claude/settings.json`)

8 hook events: SessionStart, Stop, PreToolUse (x2), PostToolUse (x2), SubagentStop, StopFailure

Key hooks:
- **`on-stop.sh`** — Parses RALPH_STATUS, writes `status.json`, updates circuit breaker
- **`protect-ralph-files.sh`** — Blocks modifications to `.ralph/` configuration
- **`validate-command.sh`** — Blocks destructive git commands

## Configuration

### Project Configuration (`.ralphrc`)

```bash
PROJECT_NAME="my-project"
PROJECT_TYPE="typescript"
CLAUDE_CODE_CMD="claude"
MAX_CALLS_PER_HOUR=200
MAX_TOKENS_PER_HOUR=0            # 0 = disabled; set to e.g. 500000 to cap token usage
CLAUDE_TIMEOUT_MINUTES=15
CLAUDE_OUTPUT_FORMAT="json"

ALLOWED_TOOLS="Write,Read,Edit,Bash(git add *),Bash(git commit *),..."

SESSION_CONTINUITY=true
SESSION_EXPIRY_HOURS=24

CB_NO_PROGRESS_THRESHOLD=3
CB_COOLDOWN_MINUTES=30
CB_AUTO_RESET=false

LOG_MAX_SIZE_MB=10               # Rotate ralph.log at this size
LOG_MAX_FILES=5                  # Rotated log files to keep
LOG_MAX_OUTPUT_FILES=20          # Max claude_output_*.log files

DRY_RUN=false                    # Also: ralph --dry-run

KEEP_MONITOR_AFTER_EXIT=false    # Keep tmux panes alive after loop exits

RALPH_ENABLE_TEAMS=false
RALPH_MAX_TEAMMATES=2
```

### CLI Options

```bash
ralph [OPTIONS]
  -V, --version           Show version
  -h, --help              Show help
  -c, --calls NUM         Max calls per hour (default: 200)
  --max-tokens NUM        Max tokens per hour (default: 0 = disabled)
  -p, --prompt FILE       Custom prompt file
  -s, --status            Show status and exit
  -m, --monitor           Start with tmux monitoring
  -v, --verbose           Detailed progress output
  -l, --live              Real-time streaming output
  -t, --timeout MIN       Execution timeout (1-120 min)
  --output-format FORMAT  json (default) or text
  --allowed-tools TOOLS   Tool permission list
  --no-continue           Disable session continuity
  --session-expiry HOURS  Session expiration (default: 24)
  --dry-run               Preview without API calls
  --reset-circuit         Reset circuit breaker
  --auto-reset-circuit    Auto-reset on startup
  --reset-session         Clear session state
  --log-max-size MB       Max log size before rotation
  --log-max-files NUM     Max rotated log files
  --stats                 Show metrics summary and exit
  --stats-json            Show metrics as JSON and exit
  --rollback              Restore state from last backup
  --sdk                   Run via Python SDK instead of bash
  --sandbox               Run loop inside Docker container
  --issue NUM             Import GitHub issue into fix_plan.md
  --issues                List GitHub issues for selection
  --batch                 Process multiple issues sequentially
  --cost-dashboard        Show cost tracking dashboard
```

## Understanding Ralph Files

| File | Purpose | Action |
|------|---------|--------|
| `.ralph/PROMPT.md` | Development instructions | **Review & customize** |
| `.ralph/fix_plan.md` | Prioritized task list | **Add/modify tasks** |
| `.ralph/AGENT.md` | Build/run instructions | Auto-maintained |
| `.ralph/specs/` | Project specifications | Add when needed |
| `.ralphrc` | Loop configuration | Rarely edit |

Design specs for loop reliability live in [`docs/specs/`](docs/specs/) (50 epics, 148 stories — all complete).

## Project Structure

```
my-project/
├── .ralph/                 # Ralph configuration and state
│   ├── PROMPT.md           # Development instructions
│   ├── fix_plan.md         # Task list
│   ├── AGENT.md            # Build/run instructions
│   ├── specs/              # Project specifications
│   ├── hooks/              # Hook scripts (from settings.json)
│   ├── logs/               # Execution logs
│   ├── status.json         # Current loop status
│   └── .circuit_breaker_state
├── .claude/                # Claude Code configuration
│   ├── agents/             # Agent definitions
│   ├── skills/             # Skill definitions
│   └── settings.json       # Hook declarations
├── .ralphrc                # Project configuration
└── src/                    # Your source code
```

## System Requirements

| Requirement | Notes |
|-------------|-------|
| **Bash 4.0+** | Script execution |
| **Claude Code CLI** | `npm install -g @anthropic-ai/claude-code` |
| **jq** | JSON processing |
| **Git** | Version control |
| **tmux** | Monitoring dashboard (recommended) |
| **GNU coreutils** | `timeout` command (macOS: `brew install coreutils`) |

### Windows Users

Ralph is a bash script and requires a Unix shell. On Windows, run Ralph through **WSL** (Windows Subsystem for Linux):

```powershell
wsl ralph --version          # Check installed version
wsl ralph --live             # Run with live streaming
wsl ralph --monitor          # Run with tmux dashboard
```

> **Note:** Running `ralph` directly from PowerShell or CMD will trigger a "Select an app to open" dialog because the script has no `.exe`/`.cmd` extension. Always use the `wsl ralph` prefix, or use the provided `ralph.cmd` wrapper (see below).

**Optional: Native wrapper** — Copy `ralph.cmd` from the repo root to a directory on your Windows PATH. This lets you run `ralph --live` directly from PowerShell/CMD without the `wsl` prefix.

## Testing

```bash
npm install          # Install BATS framework
npm test             # Run all 858+ tests
npm run test:unit    # Unit tests only
npm run test:integration  # Integration tests only
```

- **858+ tests** across 17+ test files
- **100% pass rate** (quality gate)
- Framework: BATS (Bash Automated Testing System)
- Coverage: kcov (informational only due to subprocess limitations)

See [TESTING.md](TESTING.md) for the comprehensive testing guide.

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Ralph exits silently on first loop | Check Claude Code CLI is installed and on PATH. Set `CLAUDE_CODE_CMD` in `.ralphrc` |
| Premature exit | Verify `EXIT_SIGNAL: false` is set in RALPH_STATUS when work remains |
| Permission denied | Update `ALLOWED_TOOLS` in `.ralphrc`, then `ralph --reset-session` |
| 5-hour API limit | Ralph auto-detects and prompts to wait or exit |
| Stuck loops | Check `.ralph/fix_plan.md` for unclear tasks |
| timeout not found (macOS) | `brew install coreutils` |
| MCP servers failed | Check `ralph.log` for details |
| Session expired | `ralph --reset-session` to start fresh |

## Contributing

We welcome contributions! See [CONTRIBUTING.md](CONTRIBUTING.md) for the complete guide.

```bash
git clone https://github.com/YOUR_USERNAME/ralph-claude-code.git
cd ralph-claude-code
npm install && npm test  # All 858+ tests must pass
```

**Priority areas:** test coverage, documentation, real-world testing, feature development.

## Roadmap

All 148 stories are complete across 50 epics and 17 phases. See [IMPLEMENTATION_STATUS.md](IMPLEMENTATION_STATUS.md) for details.

**Open backlog** (14 issues):
- **P1**: SDK parity with bash CLI (#226)
- **P2**: E2E integration tests (#225), token-aware rate limiting (#223)
- **P3**: Monorepo support (#163), Windows native (#156), Nix flake (#157), task import tests (#152)
- **P4**: Beads integration (#87), README updates (#82)

## License

MIT License — see [LICENSE](LICENSE).

## Acknowledgments

- Inspired by the [Ralph technique](https://ghuntley.com/ralph/) by Geoffrey Huntley
- Built for [Claude Code](https://claude.ai/code) by Anthropic
- Featured in [Awesome Claude Code](https://github.com/hesreallyhim/awesome-claude-code)

---

<p align="center">
  <a href="IMPLEMENTATION_PLAN.md">Roadmap</a> &bull;
  <a href="CONTRIBUTING.md">Contributing</a> &bull;
  <a href="TESTING.md">Testing</a> &bull;
  <a href="docs/specs/EPIC-STORY-INDEX.md">Epic Index</a>
</p>

<!-- docsmcp:start:table-of-contents -->
## Table of Contents

- [Features](#features)
- [Installation](#installation)
- [Usage](#usage)
- [Development](#development)
- [License](#license)
<!-- docsmcp:end:table-of-contents -->

<!-- docsmcp:start:installation -->
## Installation

```bash
npm install ralph-claude-code
```
<!-- docsmcp:end:installation -->

<!-- docsmcp:start:usage -->
## Usage

```javascript
const ralph_claude_code = require("ralph-claude-code");
```
<!-- docsmcp:end:usage -->

<!-- docsmcp:start:api-reference -->
## API Reference

See the [API documentation](docs/api.md) for detailed reference.
<!-- docsmcp:end:api-reference -->

<!-- docsmcp:start:development -->
## Development

```bash
git clone https://github.com/wtthornton/ralph-claude-code.git
cd ralph-claude-code

npm install

npm test
```
<!-- docsmcp:end:development -->
