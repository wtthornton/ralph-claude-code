<p align="center">
  <h1 align="center">Ralph for Claude Code</h1>
  <p align="center">
    <strong>Autonomous AI development loop with intelligent exit detection and rate limiting</strong>
  </p>
</p>

<p align="center">
  <a href="https://github.com/frankbria/ralph-claude-code/actions/workflows/test.yml"><img src="https://github.com/frankbria/ralph-claude-code/actions/workflows/test.yml/badge.svg" alt="CI"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg" alt="License: MIT"></a>
  <img src="https://img.shields.io/badge/version-1.8.2-blue" alt="Version">
  <img src="https://img.shields.io/badge/tests-736%20passing-green" alt="Tests">
  <a href="https://github.com/frankbria/ralph-claude-code/issues"><img src="https://img.shields.io/github/issues/frankbria/ralph-claude-code" alt="GitHub Issues"></a>
  <a href="https://github.com/hesreallyhim/awesome-claude-code"><img src="https://awesome.re/mentioned-badge.svg" alt="Mentioned in Awesome Claude Code"></a>
  <a href="https://x.com/FrankBria18044"><img src="https://img.shields.io/twitter/follow/FrankBria18044?style=social" alt="Follow on X"></a>
</p>

<p align="center">
  <a href="#quick-start">Quick Start</a> &bull;
  <a href="#features">Features</a> &bull;
  <a href="#how-it-works">How It Works</a> &bull;
  <a href="#configuration">Configuration</a> &bull;
  <a href="#contributing">Contributing</a>
</p>

---

Ralph is an implementation of Geoffrey Huntley's technique for Claude Code named after [Ralph Wiggum](https://ghuntley.com/ralph/). It enables continuous autonomous development cycles where Claude Code iteratively improves your project until completion, with built-in safeguards to prevent infinite loops and API overuse.

**Install once, use everywhere** — Ralph becomes a global command available in any directory.

## What's New in v1.8.2

- **Agent mode prompt fix** — `--agent ralph` with `--output-format json` now correctly passes prompt content via `-p`, fixing "Input must be provided" CLI errors
- **Live stream cleanup** — Raw JSONL events no longer leak to terminal in `--live` mode; only formatted tool summaries, text output, and stats are shown
- **Windows support** — Added `ralph.cmd` wrapper for native PowerShell/CMD invocation and a Windows Users section in docs
- **WSL deploy fix** — Line-ending issues resolved for cross-platform installs; stale `response_analyzer.sh` cleanup

<details>
<summary><strong>Previous releases</strong></summary>

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
| **Rate Limiting** | Hourly API call limits with countdown timers and 5-hour limit handling |
| **Circuit Breaker** | Three-state pattern (CLOSED/HALF_OPEN/OPEN) with auto-recovery |
| **Session Continuity** | Context preserved across loops with 24-hour expiration |
| **Live Streaming** | Real-time Claude Code output with `--live` flag |
| **Agent Teams** | Parallel task execution with teammate coordination (experimental) |
| **Sub-agents** | Explorer (read-only), tester (worktree isolation), reviewer, background tester |
| **Hook System** | 8 hook events for response analysis, file protection, and command validation |
| **Monitoring** | tmux dashboard with loop count, API usage, and live logs |
| **Task Import** | From PRDs, beads, or GitHub Issues via `ralph-enable` wizard |
| **Configuration** | `.ralphrc` per-project settings with tool permission control |

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

### 2. Set up a project

```bash
# Option A: Enable in existing project (recommended)
cd my-project
ralph-enable                    # Interactive wizard

# Option B: Import existing requirements
ralph-import requirements.md my-app

# Option C: Create from scratch
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
MAX_CALLS_PER_HOUR=100
CLAUDE_TIMEOUT_MINUTES=15
CLAUDE_OUTPUT_FORMAT="json"

# Tool permissions
ALLOWED_TOOLS="Write,Read,Edit,Bash(git add *),Bash(git commit *),..."

# Session management
SESSION_CONTINUITY=true
SESSION_EXPIRY_HOURS=24

# Circuit breaker
CB_NO_PROGRESS_THRESHOLD=3
CB_COOLDOWN_MINUTES=30
CB_AUTO_RESET=false

# Agent teams (experimental)
RALPH_ENABLE_TEAMS=false
RALPH_MAX_TEAMMATES=2
```

### CLI Options

```bash
ralph [OPTIONS]
  -V, --version           Show version
  -h, --help              Show help
  -c, --calls NUM         Max calls per hour (default: 100)
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
```

## Understanding Ralph Files

| File | Purpose | Action |
|------|---------|--------|
| `.ralph/PROMPT.md` | Development instructions | **Review & customize** |
| `.ralph/fix_plan.md` | Prioritized task list | **Add/modify tasks** |
| `.ralph/AGENT.md` | Build/run instructions | Auto-maintained |
| `.ralph/specs/` | Project specifications | Add when needed |
| `.ralphrc` | Loop configuration | Rarely edit |

Design specs for loop reliability live in [`docs/specs/`](docs/specs/) (9 epics, 42 stories — all complete).

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
npm test             # Run all 736+ tests
npm run test:unit    # Unit tests only
npm run test:integration  # Integration tests only
```

- **736+ tests** across 17 test files
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
npm install && npm test  # All 736+ tests must pass
```

**Priority areas:** test coverage, documentation, real-world testing, feature development.

## Roadmap

All 42 epic stories are complete across 5 phases. See [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md) for planned enhancements:

- Agent SDK integration
- GitHub Issue import
- Sandbox execution environments (Docker, E2B, Daytona, Cloudflare)
- Metrics and analytics

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
