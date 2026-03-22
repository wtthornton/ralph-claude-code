# Story CONFIG-3: Create CLI and SDK Documentation

**Epic:** [RALPH-CONFIG](epic-config-infrastructure.md)
**Priority:** Medium
**Status:** Open
**Effort:** Medium
**Component:** `docs/cli-reference.md`, `docs/sdk-guide.md`

---

## Problem

Ralph's documentation is spread across README.md, inline help (`ralph --help`), and spec files. With SDK mode adding a second execution path, users need unified documentation covering:
- All CLI commands and flags
- SDK API reference
- Configuration reference (`.ralphrc` + `ralph.config.json`)
- Common workflows for both modes

## Solution

Create two focused documentation files:
1. **CLI Reference** — Complete command/flag reference with examples
2. **SDK Guide** — Python API reference with code examples

Both reference the same configuration options and link to the migration strategy (SDK-4).

## Implementation

### `docs/cli-reference.md`
- All commands: `ralph`, `ralph-monitor`, `ralph-setup`, `ralph-enable`, `ralph-enable-ci`, `ralph-import`, `ralph-migrate`, `ralph doctor`
- All flags with descriptions, defaults, and examples
- Configuration reference table (`.ralphrc` keys + `ralph.config.json` paths)
- Exit codes and their meanings
- Common recipes (e.g., "run with monitoring", "process GitHub issue", "reset circuit breaker")

### `docs/sdk-guide.md`
- Quick start (5-minute setup)
- API reference: `RalphAgent`, `TaskInput`, `TaskResult`, custom tools
- Configuration via `ralph.config.json`
- Sub-agent spawning from Python
- TheStudio embedding guide (brief, links to SDK-4 migration doc)
- Common recipes (e.g., "run programmatically", "custom tool integration")

### Key Design Decisions

1. **Two docs, not one:** CLI and SDK users have different mental models. Forcing both into one document creates noise for each audience.
2. **Recipes over reference:** Users learn faster from "how do I do X" than from exhaustive API docs. Each document includes a recipes section.
3. **Written last:** This story depends on SDK-1 through SDK-3 being complete so the documentation is accurate.

## Testing

No automated tests. Review criteria:
1. CLI reference covers every command output from `ralph --help`
2. SDK guide code examples run without errors
3. Configuration reference matches actual `.ralphrc` parser and JSON schema

## Acceptance Criteria

- [ ] `docs/cli-reference.md` covers all commands, flags, exit codes
- [ ] `docs/sdk-guide.md` covers API, configuration, and common workflows
- [ ] Configuration reference is consistent between CLI and SDK docs
- [ ] Code examples in SDK guide are tested and working
- [ ] Cross-links to migration strategy (SDK-4) document
- [ ] README.md updated to link to both docs
