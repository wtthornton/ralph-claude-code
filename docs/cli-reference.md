# Ralph CLI Reference

**Version**: v2.6.0 | **Platform**: Linux, macOS, WSL, Git Bash (Windows)

## Commands

### `ralph` — Main Loop

The primary command. Runs the autonomous development loop.

```bash
ralph [OPTIONS]
```

### Core Options

| Flag | Short | Description | Default |
|------|-------|-------------|---------|
| `--version` | `-V` | Show version and exit | — |
| `--help` | `-h` | Show help message | — |
| `--calls NUM` | `-c` | Max API calls per hour | 200 |
| `--prompt FILE` | `-p` | Prompt file path | `.ralph/PROMPT.md` |
| `--status` | `-s` | Show current status and exit | — |
| `--monitor` | `-m` | Start with tmux dashboard | false |
| `--verbose` | `-v` | Verbose progress logging | false |
| `--live` | `-l` | Real-time Claude output (JSONL stream) | false |
| `--timeout MIN` | `-t` | Per-iteration timeout (1-120) | 15 |
| `--dry-run` | — | Preview loop without API calls | false |

### Session & Recovery

| Flag | Description |
|------|-------------|
| `--reset-circuit` | Reset circuit breaker to CLOSED and exit |
| `--circuit-status` | Show circuit breaker state and exit |
| `--auto-reset-circuit` | Auto-reset circuit breaker on startup |
| `--reset-session` | Clear session continuity state and exit |
| `--no-continue` | Disable session continuity for this run |
| `--session-expiry HOURS` | Session expiration time (default: 24) |

### Output & Logging

| Flag | Description | Default |
|------|-------------|---------|
| `--output-format FORMAT` | `json` or `text` | json |
| `--allowed-tools TOOLS` | Comma-separated tool list | (see .ralphrc) |
| `--log-max-size MB` | Max ralph.log size before rotation | 10 |
| `--log-max-files NUM` | Max rotated log files | 5 |

### SDK Mode

| Flag | Description |
|------|-------------|
| `--sdk` | Run in Python SDK mode |
| `--sdk-model MODEL` | Claude model for SDK mode |
| `--sdk-max-turns NUM` | Max turns per iteration |

### Observability

| Flag | Description |
|------|-------------|
| `--stats` | Show metrics summary |
| `--stats-json` | Metrics as JSON |
| `--stats-last PERIOD` | Filter metrics (e.g., `7d`, `30d`) |
| `--rollback` | Restore latest backup |
| `--rollback-list` | List available backups |

### GitHub Issues

| Flag | Description |
|------|-------------|
| `--issue NUM` | Import GitHub issue into fix_plan.md |
| `--issues` | List open issues |
| `--issue-label LABEL` | Filter by label |
| `--issue-assignee USER` | Filter by assignee |
| `--assess-only` | Show assessment without importing |
| `--batch` | Process multiple issues |
| `--batch-issues NUMS` | Comma-separated issue numbers |
| `--stop-on-failure` | Stop batch on first failure |

### Sandbox

| Flag | Description |
|------|-------------|
| `--sandbox` | Run inside Docker container |
| `--sandbox-required` | Fail if Docker unavailable |

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success (exit conditions met) |
| 1 | Error (configuration, missing files, etc.) |
| 2 | Circuit breaker tripped |
| 124 | Timeout (per-iteration) |
| 130 | Interrupted (Ctrl+C) |

## Companion Commands

| Command | Description |
|---------|-------------|
| `ralph-setup NAME` | Create new Ralph project |
| `ralph-enable` | Interactive setup wizard for existing projects |
| `ralph-enable-ci` | Non-interactive setup (CI/automation, JSON output) |
| `ralph-import FILE` | Convert PRD/spec to Ralph tasks |
| `ralph-monitor` | Standalone tmux dashboard |
| `ralph-migrate` | Migrate to `.ralph/` directory structure |
| `ralph-sdk` | Direct SDK entry point |
| `ralph-doctor` | Verify all dependencies and hook drift |
| `ralph-upgrade` | Upgrade Ralph installation to latest version |
| `ralph-upgrade-project` | Propagate runtime files (hooks, templates) to existing managed projects |

## Configuration Files

### Precedence (highest → lowest)

1. CLI flags (`--calls 50`)
2. Environment variables (`MAX_CALLS_PER_HOUR=50`)
3. `ralph.config.json` (JSON, machine-readable)
4. `.ralphrc` (bash, human-readable)
5. Built-in defaults

### .ralphrc Key Variables

Bash file sourced at startup. See `templates/ralphrc.template` for all options.

| Variable | Description | Default |
|----------|-------------|---------|
| `CLAUDE_CODE_CMD` | CLI command to invoke | `"claude"` |
| `CLAUDE_OUTPUT_FORMAT` | `json` or `text` | `json` |
| `ALLOWED_TOOLS` | Tool permission whitelist | (see template) |
| `CLAUDE_USE_CONTINUE` | Session continuity toggle | true |
| `CLAUDE_AUTO_UPDATE` | Auto-update CLI at startup | true |
| `CB_COOLDOWN_MINUTES` | Circuit breaker recovery wait | 30 |
| `CB_AUTO_RESET` | Bypass CB cooldown for unattended runs | false |
| `LOG_MAX_SIZE_MB` | Max ralph.log size before rotation | 10 |
| `LOG_MAX_FILES` | Number of rotated logs to keep | 5 |
| `LOG_MAX_OUTPUT_FILES` | Max claude_output_*.log files | 20 |
| `DRY_RUN` | Simulate loop without API calls | false |
| `RALPH_TASK_SOURCE` | Task backend: `"file"` or `"linear"` | `"file"` |
| `RALPH_LINEAR_PROJECT` | Linear project name (exact match) | — |
| `LINEAR_API_KEY` | Linear personal API key | — |
| `RALPH_NO_OPTIMIZE` | Disable fix_plan.md auto-reordering | false |
| `RALPH_NO_EXPLORER_RESOLVE` | Disable explorer file resolution for vague tasks | false |
| `RALPH_MAX_EXPLORER_RESOLVE` | Max vague tasks to resolve per run | 5 |
| `RALPH_MAX_SESSION_ITERATIONS` | Continue-As-New trigger (iterations) | 20 |
| `RALPH_MAX_SESSION_AGE_MINUTES` | Continue-As-New trigger (age) | 120 |
| `RALPH_CONTINUE_AS_NEW_ENABLED` | Enable Continue-As-New pattern | true |

### ralph.config.json

JSON alternative to `.ralphrc`. See `templates/ralph.config.json` for schema.

```json
{
  "maxCallsPerHour": 50,
  "timeoutMinutes": 30,
  "dryRun": false
}
```

## Security & Reliability Notes

### Atomic State Writes (TAP-535)

All counter and state-file writes use `atomic_write <file> <value>` — write to a temp path, fsync, then `mv -f` into place. A SIGTERM between write and truncate cannot leave a zero-byte counter. `set -o pipefail` is enabled so jq/grep pipelines fail loudly.

### Hook Resilience (TAP-538)

`on-stop.sh` self-heals a corrupt `.circuit_breaker_state` — if the JSON is invalid, the hook reinitializes to `{state: CLOSED}` and emits a `WARN:` line instead of crashing the loop. `ralph-doctor` compares project hooks against `~/.ralph/templates/hooks/` and warns on drift.

### Linear Backend Fail-Loud (TAP-536)

When `RALPH_TASK_SOURCE=linear`, any API/network/parse error causes the count/task functions to print nothing to stdout and return non-zero. Callers distinguish "exit non-zero" (unknown — abstain) from "exit 0 + value" (real result). A transient outage cannot trip a false `plan_complete` exit.

### Command Injection Guards (TAP-534/533)

`sed`/`eval` patterns in `ralph_loop.sh` sanitized against injection via untrusted task content.

## Common Recipes

```bash
# Quick start
ralph-setup my-project && cd my-project && ralph --monitor

# Fast iteration with live output
ralph --live --timeout 5

# Conservative rate limiting
ralph --calls 20 --timeout 30

# Preview without API calls
ralph --dry-run

# SDK mode with a specific model
ralph --sdk --sdk-model claude-opus-4-7

# GitHub issue workflow
ralph --issue 42 --live

# Linear task backend
RALPH_TASK_SOURCE=linear RALPH_LINEAR_PROJECT="My Project" ralph --live

# Optimize fix_plan.md task order
# (runs automatically at session start unless RALPH_NO_OPTIMIZE=true)
ralph  # auto-optimizes on start

# Check health and hook drift
ralph-doctor

# Upgrade project hooks to latest templates
ralph-upgrade-project
```

## `ralph-upgrade-project`

Propagates updated runtime files (hooks, agent definitions, template merges) from the global Ralph install (`~/.ralph/`) into existing managed projects. Does **not** re-run `ralph-enable` or touch task state. Use this after running `ralph-upgrade` (which updates the global install) to sync your projects.

### Usage

```bash
ralph-upgrade-project /path/to/project       # upgrade one project
ralph-upgrade-project --all                  # discover and upgrade all projects
ralph-upgrade-project --dry-run /path        # preview without changes
ralph-upgrade-project --all --yes            # skip confirmation
ralph-upgrade-project --all --search-dir /c/cursor   # custom discovery root
```

### Three-tier upgrade policy

| Tier | Files | Behavior |
|------|-------|----------|
| **Tier 1** (always overwrite) | Hook scripts in `.ralph/hooks/`, agent definitions in `.claude/agents/` | Replaced with latest template |
| **Tier 2** (merge only) | `.ralphrc`, `.claude/settings.json` | Appends missing sections and hooks; preserves your overrides |
| **Tier 3** (never touch) | `fix_plan.md`, `status.json`, `.circuit_breaker_state`, session IDs | Untouched |

Backups of replaced Tier 1/2 files are written to `.ralph/.upgrade-backups/YYYY-MM-DD-HHMMSS/` (max 5 kept per project).

### Typical workflow

```bash
ralph-upgrade                           # 1. update global install
ralph-upgrade-project --all --dry-run   # 2. preview project changes
ralph-upgrade-project --all             # 3. apply
ralph-doctor                            # 4. verify hook parity
```

