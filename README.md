---
title: Ralph for Claude Code
description: Autonomous AI development loop with dual-condition exit gate, circuit breaker, and hourly rate limiting.
audience: [user, operator, contributor]
diataxis: how-to
last_reviewed: 2026-04-23
---

# Ralph for Claude Code

[![Version](https://img.shields.io/badge/version-2.8.3-blue)](CHANGELOG.md)
[![Tests](https://img.shields.io/badge/tests-1117%2B-brightgreen)](TESTING.md)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

Ralph is an autonomous development loop for [Claude Code](https://claude.ai/code). It reads your `PROMPT.md`, invokes the Claude Code CLI, evaluates the response, and repeats — with rate limiting, circuit breakers, session continuity, and a strict dual-condition exit gate to stop cleanly when the work is done. Named after [Geoffrey Huntley's Ralph technique](https://ghuntley.com/ralph/).

**Core loop** is bash; the optional embedded mode is [Python SDK v2.1.0](docs/sdk-guide.md) (`sdk/ralph_sdk/`).

## Table of contents

- [Why Ralph](#why-ralph)
- [Install](#install)
- [Quick start](#quick-start)
- [How it works](#how-it-works)
- [Features](#features)
- [Project layout](#project-layout)
- [Configuration](#configuration)
- [CLI reference](#cli-reference)
- [Documentation map](#documentation-map)
- [System requirements](#system-requirements)
- [Testing](#testing)
- [Contributing](#contributing)
- [License](#license)

## Why Ralph

Running Claude Code by hand for a long-running project is slow and error-prone: you have to babysit rate limits, catch stalls, decide when to stop, and re-enter context between sessions. Ralph automates that harness. It reads your `fix_plan.md`, asks Claude to do the next thing, and exits only when Claude and the harness both agree the work is complete — so you can leave a backlog running overnight and trust the stop condition.

## Install

```bash
git clone https://github.com/wtthornton/ralph-claude-code.git
cd ralph-claude-code
./install.sh
```

Installs `ralph`, `ralph-monitor`, `ralph-setup`, `ralph-import`, `ralph-enable`, `ralph-enable-ci`, `ralph-migrate`, `ralph-doctor`, `ralph-upgrade`, and `ralph-sdk` into `~/.local/bin/`. Put that on your `$PATH`.

**Dependencies:** Node.js 18+, `git`, `jq`, GNU `timeout` (macOS: `brew install coreutils`). If `jq` is missing, the installer can bootstrap an official static binary into `~/.local/bin/jq` on Linux/macOS. Set `RALPH_SKIP_JQ_BOOTSTRAP=1` to require a system package instead.

### Alternatives

| Platform | Command |
|---|---|
| Nix (flakes) | `nix shell github:wtthornton/ralph-claude-code` |
| Windows | Run through WSL: `wsl ralph --live`. Or copy `ralph.cmd` to `%PATH%`. |
| WSL/CRLF | If you see `$'\r'` errors: `sed -i 's/\r$//' install.sh` or set `git config core.autocrlf input` |

Upgrade: re-run `./install.sh upgrade`. Uninstall: `./uninstall.sh`.

## Quick start

```bash
cd my-project
ralph-enable              # Interactive wizard — detects project type, sets up .ralph/
ralph --monitor           # Run with live tmux dashboard (recommended)
```

Three alternative flows:

```bash
ralph-import requirements.md my-app    # Convert a PRD into Ralph tasks
ralph-setup my-project                 # Scaffold a new project from scratch
ralph --live                           # Headless with real-time streaming output
```

See the [user guide](docs/user-guide/) for a hands-on tutorial.

## How it works

```
┌────────────────────────────────────────────────────────┐
│                      Ralph loop                        │
│                                                        │
│  1. Read PROMPT.md + fix_plan.md                       │
│         │                                              │
│         ▼                                              │
│  2. Invoke Claude Code CLI                             │
│         │                                              │
│         ▼                                              │
│  3. on-stop.sh hook → parses RALPH_STATUS →            │
│     writes status.json + updates circuit breaker       │
│         │                                              │
│         ▼                                              │
│  4. Loop evaluates exit gate                           │
│         │                                              │
│         ├── BOTH conditions met → exit                 │
│         └── else → back to step 1                      │
└────────────────────────────────────────────────────────┘
```

**Dual-condition exit gate.** Ralph exits only when **both** are true:

1. `completion_indicators >= 2` — the loop's NLP heuristic agrees work is done.
2. Claude emits `EXIT_SIGNAL: true` in the `RALPH_STATUS` block — the agent explicitly says so.

This prevents premature exits when Claude says "done" mid-phase. See [ADR-0001: Dual-condition exit gate](docs/decisions/0001-dual-condition-exit-gate.md).

Other exit conditions: all `fix_plan.md` tasks complete, consecutive done signals, test saturation, permission denied after retries, API limit reached.

## Features

| Category | Capability |
|---|---|
| **Core loop** | Autonomous cycles, dual-condition exit gate, epic-boundary QA deferral |
| **Rate limiting** | Hourly call + token limits, plan-exhaustion auto-sleep, countdown timers |
| **Circuit breaker** | Three-state CLOSED/HALF_OPEN/OPEN with auto-recovery, fast-trip, stall detection |
| **Session continuity** | Session IDs persist 24h; auto-reset on CB open, interrupt, or `is_error: true` |
| **Live streaming** | `--live` JSONL pipeline with tool names, elapsed time, sub-agent events |
| **Sub-agents** | explorer (Haiku), tester (worktree), reviewer (read-only), architect (Opus), bg-tester |
| **Hook system** | 8 events — response analysis, file protection, command validation |
| **Monitoring** | tmux dashboard with loop count, API usage, live logs, cost breakdown |
| **Task sources** | `fix_plan.md` (file), Linear API, GitHub Issues, PRD import |
| **Config** | Per-project `.ralphrc` with tool permission whitelist |
| **Log rotation** | Automatic rotation on size + retention caps |
| **Dry-run** | Preview a loop iteration without API calls (`--dry-run`) |
| **Metrics** | Monthly JSONL, `ralph --stats` summary, `--stats-json` machine-readable |
| **Notifications** | Terminal, OS native, webhook POST, sound |
| **Backup/rollback** | Auto-snapshot at epic boundaries, `ralph --rollback` |
| **GitHub Issues** | `ralph --issue NUM`, `--batch`, lifecycle management |
| **Docker sandbox** | `ralph --sandbox` with rootless, `--network none`, gVisor support |
| **Cost dashboard** | `ralph --cost-dashboard` with per-model breakdown |
| **Plan optimizer** | Automatic `fix_plan.md` reordering by import graph at session start |
| **Python SDK** | Full async agent loop, Pydantic v2 models, pluggable state backend |
| **OTel tracing** | GenAI Semantic Conventions, JSONL OTLP format |
| **MCP integration** | Probes `tapps-mcp`, `tapps-brain`, `docs-mcp`; injects guidance |

## Project layout

```
ralph-claude-code/
├── ralph_loop.sh              # Core autonomous loop (~2,500 lines)
├── ralph_monitor.sh           # Live tmux dashboard
├── ralph_enable.sh            # Interactive project enablement
├── ralph_enable_ci.sh         # Non-interactive enablement for CI
├── ralph_import.sh            # PRD/spec document importer
├── install.sh / uninstall.sh  # Global installation
├── lib/                       # Modular library (18 modules)
├── sdk/ralph_sdk/             # Python SDK v2.1.0 (17 modules)
├── templates/                 # Project scaffolding
├── tests/                     # BATS suite (unit/integration/e2e/evals)
├── docs/                      # This guide set (see docs/README.md)
└── .claude/                   # Agents, hooks, skills, settings
```

A project managed by Ralph gets:

```
my-project/
├── .ralph/
│   ├── PROMPT.md              # Development instructions (you customize)
│   ├── fix_plan.md            # Task list (you + Ralph maintain)
│   ├── AGENT.md               # Build/run instructions (auto-maintained)
│   ├── specs/                 # Detailed specs (optional)
│   ├── hooks/                 # Hook scripts
│   ├── logs/                  # Execution logs
│   ├── status.json            # Current loop status
│   └── .circuit_breaker_state
├── .claude/
│   ├── agents/                # Sub-agent definitions
│   ├── skills/                # Skill definitions
│   └── settings.json          # Hook declarations
├── .ralphrc                   # Per-project config
└── src/                       # Your code
```

## Configuration

`.ralphrc` is sourced as bash at loop startup. Environment variables override file values. The most useful keys:

```bash
PROJECT_NAME="my-project"
PROJECT_TYPE="typescript"             # python|typescript|generic
CLAUDE_CODE_CMD="claude"              # fallback: "npx @anthropic-ai/claude-code"
MAX_CALLS_PER_HOUR=200
MAX_TOKENS_PER_HOUR=0                 # 0 = disabled
CLAUDE_TIMEOUT_MINUTES=15

ALLOWED_TOOLS="Write,Read,Edit,Bash(git add *),..."   # See templates/ralphrc.template

SESSION_CONTINUITY=true
SESSION_EXPIRY_HOURS=24

CB_NO_PROGRESS_THRESHOLD=3
CB_COOLDOWN_MINUTES=30
CB_AUTO_RESET=false

RALPH_TASK_SOURCE="file"              # "file" (default) | "linear"
RALPH_LINEAR_PROJECT=""               # required when task source = linear

DRY_RUN=false
KEEP_MONITOR_AFTER_EXIT=false
```

Full reference: [docs/cli-reference.md](docs/cli-reference.md).

## CLI reference

```bash
ralph [OPTIONS]
  -V, --version           Show version
  -h, --help              Show help
  -c, --calls NUM         Max calls per hour (default: 200)
      --max-tokens NUM    Max tokens per hour (0 = disabled)
  -p, --prompt FILE       Custom prompt file
  -s, --status            Show status and exit
  -m, --monitor           Start with tmux monitoring
  -v, --verbose           Detailed progress output
  -l, --live              Real-time streaming output
  -t, --timeout MIN       Execution timeout (1-120 min)
      --output-format     json (default) or text
      --allowed-tools     Tool permission list
      --no-continue       Disable session continuity
      --session-expiry H  Session expiration (default: 24)
      --dry-run           Preview without API calls
      --reset-circuit     Reset circuit breaker
      --reset-session     Clear session state
      --stats             Metrics summary
      --stats-json        Metrics as JSON
      --rollback          Restore state from last backup
      --sdk               Run via Python SDK instead of bash
      --sandbox           Run inside Docker container
      --issue NUM         Import GitHub issue into fix_plan.md
      --issues            List GitHub issues for selection
      --batch             Process multiple issues sequentially
      --cost-dashboard    Show cost tracking dashboard
      --mcp-status        Show which MCP servers are reachable
```

Full CLI reference: [docs/cli-reference.md](docs/cli-reference.md).

## Documentation map

| I want to... | Start here |
|---|---|
| Install and run Ralph on a project | This README + [user guide](docs/user-guide/) |
| Understand the architecture | [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) |
| Fix something that's broken | [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) |
| Look up Ralph-specific terminology | [docs/GLOSSARY.md](docs/GLOSSARY.md) |
| Run Ralph in production | [docs/OPERATIONS.md](docs/OPERATIONS.md) |
| Embed Ralph in another Python app | [docs/sdk-guide.md](docs/sdk-guide.md) |
| Drive Ralph from Linear | [docs/LINEAR-WORKFLOW.md](docs/LINEAR-WORKFLOW.md) |
| Stack Ralph + tapps-mcp + tapps-brain | [docs/RALPH-STACK-GUIDE.md](docs/RALPH-STACK-GUIDE.md) |
| Understand a design decision | [docs/decisions/](docs/decisions/) |
| Contribute code | [CONTRIBUTING.md](CONTRIBUTING.md) |
| Report a vulnerability | [SECURITY.md](SECURITY.md) |
| Add or run tests | [TESTING.md](TESTING.md) |
| See what's shipped recently | [CHANGELOG.md](CHANGELOG.md) |
| Review completed epics | [docs/specs/README.md](docs/specs/README.md) |

Complete index: [docs/README.md](docs/README.md).

## System requirements

| Requirement | Notes |
|---|---|
| Bash 4.0+ | Ralph rejects older versions at startup |
| Claude Code CLI | `npm install -g @anthropic-ai/claude-code` |
| `jq` | JSON processing (installer can bootstrap it) |
| Git | Progress detection via diff baseline |
| tmux | Recommended for `--monitor` |
| GNU coreutils | `timeout` command (macOS: `brew install coreutils`) |
| gawk | mawk lacks `match(s, re, arr)` array capture used by plan optimizer |

## Testing

```bash
npm install          # Install BATS framework
npm test             # Run unit + integration (1117+ tests, 100% pass gate)
npm run test:unit
npm run test:integration
npm run test:evals:deterministic
```

Full testing guide: [TESTING.md](TESTING.md).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Priority areas: test coverage, documentation, real-world testing, feature development. Before opening a PR:

```bash
git clone https://github.com/wtthornton/ralph-claude-code.git
cd ralph-claude-code
npm install && npm test   # All 1117+ tests must pass
```

## License

MIT License — see [LICENSE](LICENSE).

## Acknowledgments

- Inspired by the [Ralph technique](https://ghuntley.com/ralph/) by Geoffrey Huntley
- Built on [Claude Code](https://claude.ai/code) by Anthropic
- Featured in [Awesome Claude Code](https://github.com/hesreallyhim/awesome-claude-code)

---

<p align="center">
  <a href="docs/ARCHITECTURE.md">Architecture</a> •
  <a href="docs/TROUBLESHOOTING.md">Troubleshooting</a> •
  <a href="CONTRIBUTING.md">Contributing</a> •
  <a href="TESTING.md">Testing</a> •
  <a href="docs/specs/EPIC-STORY-INDEX.md">Epic index</a>
</p>
