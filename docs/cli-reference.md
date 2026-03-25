# Ralph CLI Reference

**Version**: v1.4.0 | **Platform**: Linux, macOS, WSL, Git Bash (Windows)

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
| `--live` | `-l` | Real-time Claude output | false |
| `--timeout MIN` | `-t` | Per-iteration timeout (1-120) | 15 |

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
| `--dry-run` | Preview without API calls | false |
| `--log-max-size MB` | Max ralph.log size before rotation | 10 |
| `--log-max-files NUM` | Max rotated log files | 5 |

### SDK Mode (v1.3.0+)

| Flag | Description |
|------|-------------|
| `--sdk` | Run in Python SDK mode |
| `--sdk-model MODEL` | Claude model for SDK mode |
| `--sdk-max-turns NUM` | Max turns per iteration |

### Observability (v1.5.0+)

| Flag | Description |
|------|-------------|
| `--stats` | Show metrics summary |
| `--stats-json` | Metrics as JSON |
| `--stats-last PERIOD` | Filter metrics (e.g., `7d`, `30d`) |
| `--rollback` | Restore latest backup |
| `--rollback-list` | List available backups |

### GitHub Issues (v1.7.0+)

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

### Sandbox (v1.8.0+)

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
| `ralph-enable-ci` | Non-interactive setup (CI/automation) |
| `ralph-import FILE` | Convert PRD/spec to Ralph tasks |
| `ralph-monitor` | Standalone tmux dashboard |
| `ralph-migrate` | Migrate to `.ralph/` directory structure |
| `ralph-sdk` | Direct SDK entry point |
| `ralph-doctor` | Verify all dependencies |

## Configuration Files

### Precedence (highest → lowest)

1. CLI flags (`--calls 50`)
2. Environment variables (`MAX_CALLS_PER_HOUR=50`)
3. `ralph.config.json` (JSON, machine-readable)
4. `.ralphrc` (bash, human-readable)
5. Built-in defaults

### .ralphrc

Bash file sourced at startup. See `templates/ralphrc.template` for all options.

### ralph.config.json

JSON alternative to `.ralphrc`. See `templates/ralph.config.json` for schema.

```json
{
  "maxCallsPerHour": 50,
  "timeoutMinutes": 30,
  "dryRun": false
}
```

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

# SDK mode
ralph --sdk --sdk-model claude-opus-4-20250514

# GitHub issue workflow
ralph --issue 42 --live

# Check health
ralph-doctor
```
