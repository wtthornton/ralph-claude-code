---
title: Ralph operations runbook
description: Run Ralph against one or more projects in production — deployment, multi-project patterns, secrets, symptom-based troubleshooting.
audience: [operator]
diataxis: how-to
last_reviewed: 2026-04-23
---

# Ralph operations runbook

Operational guide for running Ralph against one or more projects on a shared server (e.g. `tapps-brain` alongside other managed projects). Focused on deployment, multi-project patterns, and symptom-based troubleshooting. For the full failure catalog see [../FAILURE.md](../FAILURE.md). For symptom-first recovery see [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

For installation see [README.md](../README.md). For CLI flags see [cli-reference.md](cli-reference.md). For the Python SDK see [sdk-guide.md](sdk-guide.md).

---

## Pre-flight Checklist

Before enabling Ralph on a new project:

1. **Dependencies present** — run `ralph-doctor`. Must report: `claude` CLI, `jq`, `git`, `bash >= 4`, `gawk` (not mawk), and hook templates in sync.
2. **Claude CLI authenticated** — `claude --version` works and a manual `claude -p "hello"` succeeds without prompting for auth.
3. **Project is a git repo** — Ralph's backup and diff paths assume `git`.
4. **`.ralph/` not already present from another tool** — if it is, inspect before running `ralph-enable`.
5. **Disk headroom** — Ralph writes `ralph.log` (rotated at `LOG_MAX_SIZE_MB`), plus `claude_output_*.log` files (capped by `LOG_MAX_OUTPUT_FILES`). Expect ~50–200 MB per long-running project.
6. **Rate limit budget** — check `MAX_CALLS_PER_HOUR` in `.ralphrc`. Default is 200. For shared Anthropic accounts, divide the account budget across active projects.

---

## Multi-project Deployment

Ralph is designed to run against many projects from one global install. Each managed project has its own isolated `.ralph/` state directory.

### Installing once, using everywhere

```bash
# One-time install (puts binaries in ~/.local/bin, templates in ~/.ralph)
./install.sh

# Enable Ralph on each project
cd ~/code/tapps-brain  && ralph-enable
cd ~/code/other-project && ralph-enable
```

After enabling, each project gets its own:
- `.ralph/` — state, logs, metrics, circuit breaker, session IDs
- `.ralphrc` — per-project config overrides
- `.claude/` — agent and hook definitions

**No state is shared between projects.** Rate limit counters, circuit breaker state, session IDs, and metrics are all per-project.

### Running Ralph in parallel against multiple projects

Ralph uses `flock(2)` at `ralph_loop.sh:3936-3974` to prevent two instances running against the same project. Running Ralph against **different** projects in parallel is safe:

```bash
# Terminal 1
cd ~/code/tapps-brain && ralph --live

# Terminal 2 (different project — safe)
cd ~/code/other-project && ralph --live
```

Running Ralph twice against the **same** project is blocked by the lock file (`<project>/.ralph/.ralph.lock`). The second instance exits immediately with a `lock held` message.

### Shared Anthropic rate-limit considerations

Rate-limit counters (`.call_count`, `.token_count`) are per-project. If all your projects share one Anthropic account, the sum of concurrent Ralph instances can still exhaust the account quota. Options:

- Lower `MAX_CALLS_PER_HOUR` in each project's `.ralphrc` so the sum fits the account budget.
- Stagger starts (don't kick all projects off at the same minute).
- Use `ralph --dry-run` to validate config without burning budget.

### tmux / systemd patterns

For unattended multi-project runs:

```bash
# tmux: one window per project
tmux new-session -d -s ralph -n brain  'cd ~/code/tapps-brain && ralph --live'
tmux new-window -t ralph -n other      'cd ~/code/other-project && ralph --live'
tmux attach -t ralph
```

For systemd user units, use `WorkingDirectory=` to point at each project; the systemd unit should set `CB_AUTO_RESET=true` so a circuit-breaker trip doesn't wedge the service until you SSH in.

---

## Linear Backend Setup

Ralph can pull its task list from a Linear project instead of `fix_plan.md`.

### One-time setup

1. Generate a Linear personal API key at <https://linear.app/settings/api>.
2. Identify the **exact** Linear project name (case-sensitive, must match the workspace).
3. Add to the project's `.ralphrc`:

   ```bash
   export RALPH_TASK_SOURCE="linear"
   export RALPH_LINEAR_PROJECT="Tapps Brain"   # exact match
   export LINEAR_API_KEY="lin_api_..."         # or set as env var
   ```

   Prefer putting `LINEAR_API_KEY` in an env var (systemd `Environment=`, shell profile, or secrets manager) rather than checking it into `.ralphrc`. `.ralphrc` is readable by anyone on the host.

4. Verify: `ralph --dry-run` should log `task source: linear` and print the current open-issue count.

### Operational behavior

- Claude uses the Linear MCP tools to list issues, work the highest-priority one, and mark it `Done`. `fix_plan.md` is not read or modified in this mode.
- **Fail-loud (TAP-536):** on any API, network, or parse error the backend returns non-zero and prints no value. The exit-condition check abstains so a transient Linear outage cannot trip a false `plan_complete` exit. You will see `linear_api_error: op=<name> reason=<...>` on stderr.
- To switch back to file mode: unset `RALPH_TASK_SOURCE` (or set to `"file"`) and ensure `fix_plan.md` exists with tasks.

### Troubleshooting Linear

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `linear_api_error: op=... reason=http_401` | Bad API key | Regenerate key, update env |
| `linear_api_error: op=... reason=http_404` | Project name mismatch | Check exact name at linear.app |
| Ralph says "0 open issues" but there are issues in Linear | Wrong project, or issues not assigned to this project | Verify `RALPH_LINEAR_PROJECT` matches |
| Ralph never emits `EXIT_SIGNAL: true` | Expected — the exit gate abstains on any API error | Check stderr for `linear_api_error` |

---

## Troubleshooting by Symptom

### Ralph loop won't start

| Symptom | Check |
|---------|-------|
| `lock held` on startup | Another instance running, or stale lock from a crash. Check `ps aux \| grep ralph_loop`. If no process, remove `.ralph/.ralph.lock`. |
| `claude: command not found` | CLAUDE CLI not installed or not on `$PATH`. Run `ralph-doctor`. |
| `bash: version too old` | Ralph requires bash ≥ 4. On macOS, install via Homebrew and update shebang. |
| `jq: command not found` | Install via package manager; Ralph cannot run without it. |

### Loop runs but doesn't make progress

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Circuit breaker `OPEN`, no recovery | Cooldown not yet elapsed | Wait `CB_COOLDOWN_MINUTES` (default 30), or set `CB_AUTO_RESET=true` in `.ralphrc` |
| Same task appearing every loop | `EXIT_SIGNAL` never fires; completion indicators decaying | Inspect `.ralph/status.json` — if `work_type` is `UNKNOWN` every loop, Claude isn't completing the task. Simplify the task or bump complexity classification. |
| Rate limit exhausted early | `MAX_CALLS_PER_HOUR` too low, or other projects sharing quota | Check `.ralph/.call_count` against `MAX_CALLS_PER_HOUR`. Wait for hourly reset or lower concurrent projects. |
| `status: stuck` | Three consecutive loops with no files modified and no exit signal | Inspect `ralph.log` tail. Often indicates Claude lost context — cleaning `.ralph/.claude_session_id` forces a fresh session. |

### State / file corruption

| Symptom | Fix |
|---------|-----|
| `.circuit_breaker_state` JSON invalid | `on-stop.sh` hook auto-heals (TAP-538) — you'll see `WARN: .circuit_breaker_state is corrupt — reinitializing to CLOSED`. No action needed. |
| Zero-byte `.call_count` after crash | Should not happen post-TAP-535 (atomic writes). If it does, delete the file — Ralph recreates with `0` at next loop. |
| `status.json` missing or malformed | Delete it; `on-stop.sh` rewrites every loop. |
| `fix_plan.md` was reordered and you don't like the new order | Set `RALPH_NO_OPTIMIZE=true` in `.ralphrc` to disable the auto-reorder. Restore from `.ralph/.upgrade-backups/` or git. |

### MCP server process leaks

Claude Code spawns MCP servers (`tapps-mcp`, `docsmcp`, etc.) as grandchild processes. `ralph_cleanup_orphaned_mcp` at `ralph_loop.sh:2898` runs after every CLI invocation and on the exit trap to kill orphans where the parent is dead. On a shared server, `ps aux | grep -E 'uv|mcp'` after Ralph exits should show no Ralph-spawned survivors — if it does, file a bug with the output of `pstree -p $$`.

### Hook execution failures

| Symptom | Check |
|---------|-------|
| `PreToolUse: validate-command.sh: permission denied` | Run `chmod +x .ralph/hooks/*.sh`. |
| PowerShell hooks failing in WSL | Should auto-patch at startup — if not, run `ralph-upgrade-project .` (WSL detects `powershell` vs `powershell.exe` at `ralph_loop.sh` hook validation). |
| Hook drift warning from `ralph-doctor` | Run `ralph-upgrade-project /path/to/project` to sync hooks with `~/.ralph/templates/hooks/`. |

### Upgrading a managed project

See [cli-reference.md](cli-reference.md#ralph-upgrade-project) for full `ralph-upgrade-project` docs. Three-tier upgrade:

- **Tier 1 (overwrite):** hook scripts, agent definitions
- **Tier 2 (merge):** `.ralphrc`, `.claude/settings.json` — appends missing sections, does not clobber your overrides
- **Tier 3 (never touch):** `fix_plan.md`, `status.json`, `.circuit_breaker_state`, session state

Always run with `--dry-run` first to preview.

---

## Secrets Management

Ralph handles three kinds of secrets: the Anthropic auth the Claude CLI manages itself, optional `LINEAR_API_KEY`, and whatever secrets your project's code references (`.env` files, etc.).

**Rules of thumb:**

- Never put `LINEAR_API_KEY` directly in `.ralphrc` if the host is shared — use env vars.
- `templates/hooks/protect-ralph-files.sh` blocks Claude from editing `.ralphrc` and `.env` files through PreToolUse hooks.
- `ralph.log` does not redact secrets — if you log failed CLI invocations with `--live`, API error bodies may contain partial keys. Review before sharing logs.
- On rotation, delete `.ralph/.claude_session_id` to force a fresh session with the new credential.

---

## Cost & Budget Controls

The SDK (`sdk/ralph_sdk/cost.py`) tracks per-model cost. Currently the budget is **advisory** — Ralph logs warnings but does not hard-stop on budget overrun. For true cost enforcement:

- Set `MAX_CALLS_PER_HOUR` and `MAX_TOKENS_PER_HOUR` conservatively.
- Monitor `ralph --stats` (reads `.ralph/metrics/YYYY-MM.jsonl`) daily.
- For OTel export, set `RALPH_OTEL_ENABLED=true` and configure `RALPH_OTEL_ENDPOINT` in `.ralphrc`.

---

## Related Docs

- [README.md](../README.md) — overview, installation, features
- [cli-reference.md](cli-reference.md) — all flags, config precedence, commands
- [sdk-guide.md](sdk-guide.md) — Python Agent SDK
- [user-guide/](user-guide/) — getting-started tutorials
- [specs/](specs/) — design documents for reliability epics
