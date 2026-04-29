---
title: TappsMCP consumer requirements
description: Host configuration required to use the tapps-mcp MCP server with Claude Code, Cursor, and VS Code.
audience: [operator]
diataxis: how-to
last_reviewed: 2026-04-23
---

# TappsMCP consumer requirements

This document lists what your MCP host (Claude Code, Cursor, VS Code) must have configured for `tapps-mcp` tools to be available. Referenced from [AGENTS.md](../AGENTS.md).

## Installation

```bash
# Install the MCP server
uv tool install tapps-mcp

# Verify
tapps-mcp --version
```

Optional checker dependencies that improve tool coverage:

```bash
uv tool install tapps-mcp --with ruff --with mypy
```

`bandit`, `radon`, `vulture`, `pylint`, and `pip-audit` are bundled with the base install.

## Host configuration

### Claude Code

`.claude/settings.json` must grant both permission entries:

```json
{
  "permissions": {
    "allow": [
      "mcp__tapps-mcp",
      "mcp__tapps-mcp__*"
    ]
  }
}
```

Both are required. The bare `mcp__tapps-mcp` entry is a fallback — wildcard `mcp__tapps-mcp__*` has had issues in some Claude Code versions (see Anthropic issues #3107, #13077, #27139).

The server itself is registered in `.mcp.json` (or `.claude.json`):

```json
{
  "mcpServers": {
    "tapps-mcp": {
      "command": "tapps-mcp",
      "args": ["serve"]
    }
  }
}
```

Fix automatically with:

```bash
tapps-mcp upgrade --host claude-code
```

### Cursor

Cursor manages MCP permissions differently — no `.claude/settings.json` needed. Open **Settings → MCP** and confirm `tapps-mcp` is listed and enabled.

Cursor has a 40-tool limit. If you exceed it, use standalone servers (tapps-mcp + docs-mcp separately) instead of the combined `tapps-platform` bundle.

### VS Code

Check `.vscode/mcp.json` for a `tapps-mcp` entry. Verify the MCP panel in the sidebar shows the server as connected.

## Verification

```bash
tapps-mcp doctor
```

If doctor hangs, use `tapps-mcp doctor --quick` (skips per-tool version checks).

In Claude Code specifically:

```
/mcp
```

Lists connected servers. `tapps-mcp` should appear.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Tools rejected on every call | Add both permission entries (see above); restart host |
| Server not visible | Run `tapps-mcp upgrade --force --host auto`, restart host |
| Doctor timeout | `tapps-mcp doctor --quick` or run in background |
| Tool schemas not loading | CLI fallback: `tapps-mcp init`, `tapps-mcp doctor` |

For the full TappsMCP tool guide, see [../AGENTS.md](../AGENTS.md). For Ralph-specific stack integration (tapps-mcp + tapps-brain + docs-mcp together), see [RALPH-STACK-GUIDE.md](RALPH-STACK-GUIDE.md).
