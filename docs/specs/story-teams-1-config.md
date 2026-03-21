# Story RALPH-TEAMS-1: Enable Agent Teams Configuration

**Epic:** [Agent Teams + Parallelism](epic-agent-teams-parallelism.md)
**Priority:** Important
**Status:** Done
**Effort:** Small
**Component:** `.claude/settings.local.json`, `.ralphrc`, `ralph_loop.sh`

---

## Problem

Agent teams is an experimental Claude Code feature that enables parallel task execution.
It requires explicit opt-in via environment variable and configuration. Ralph needs a
clean way to enable/disable teams with appropriate defaults and guards.

## Solution

Add teams configuration to `.claude/settings.local.json` (not committed — experimental)
and `.ralphrc`, with `RALPH_ENABLE_TEAMS=false` as the safe default.

## Implementation

### .claude/settings.local.json

```jsonc
{
  "env": {
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"
  },
  "teammateMode": "tmux"
}
```

**Note:** This file is NOT committed to version control. It's project-local and
experimental. Added to `.gitignore`.

### .ralphrc additions

```bash
# =============================================================================
# PARALLELISM (v1.0 Phase 4 — Experimental)
# =============================================================================

# Enable agent teams for parallel execution
# WARNING: Experimental feature. Requires Claude Code v2.1.32+
# Known limitations:
#   - No session resumption with in-process teammates
#   - Split panes not supported in VS Code terminal or Windows Terminal
#   - Requires tmux or iTerm2 for split pane display
RALPH_ENABLE_TEAMS=false
RALPH_MAX_TEAMMATES=3

# Background testing (independent of teams)
RALPH_BG_TESTING=false

# Teammate display mode: "in-process" | "tmux" | "auto"
# "tmux" recommended for Ralph (already uses tmux for monitoring)
RALPH_TEAMMATE_MODE="tmux"
```

### ralph_loop.sh integration

```bash
# Setup teams if enabled
setup_teams() {
  if [[ "${RALPH_ENABLE_TEAMS:-false}" != "true" ]]; then
    return 0
  fi

  # Check CLI version supports teams (v2.1.32+)
  if ! check_teams_support; then
    log_warn "Agent teams require Claude Code v2.1.32+. Falling back to sequential."
    RALPH_ENABLE_TEAMS=false
    return 0
  fi

  # Create local settings with teams env var
  local settings_local=".claude/settings.local.json"
  mkdir -p .claude
  cat > "$settings_local" <<EOF
{
  "env": {
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"
  },
  "teammateMode": "${RALPH_TEAMMATE_MODE:-tmux}"
}
EOF

  log_info "Agent teams enabled (max ${RALPH_MAX_TEAMMATES:-3} teammates, mode=${RALPH_TEAMMATE_MODE:-tmux})"
}

check_teams_support() {
  local version
  version=$(${CLAUDE_CODE_CMD:-claude} --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1)
  # Require 2.1.32+
  # ... version comparison logic
}
```

### .gitignore addition

```
# Claude Code local settings (experimental, not committed)
.claude/settings.local.json
```

### Key Design Decisions

1. **`RALPH_ENABLE_TEAMS=false` default:** Teams are experimental with known bugs.
   Must be explicitly opted in.

2. **`tmux` display mode:** Ralph already uses tmux for its monitoring dashboard.
   Using tmux for teammate display integrates naturally.

3. **`.claude/settings.local.json` not committed:** Experimental config stays local.
   Different developers can have different settings.

4. **Version check:** Teams require v2.1.32+. Ralph gracefully falls back to sequential
   mode on older CLIs.

5. **Known limitations documented:** The `.ralphrc` template includes warnings about
   VS Code terminal, Windows Terminal, and session resumption limitations.

## Testing

```bash
@test "setup_teams creates settings.local.json when enabled" {
  RALPH_ENABLE_TEAMS=true
  check_teams_support() { return 0; }  # Mock

  setup_teams

  [[ -f ".claude/settings.local.json" ]]
  jq -e '.env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS' ".claude/settings.local.json" >/dev/null
}

@test "setup_teams does nothing when disabled" {
  RALPH_ENABLE_TEAMS=false
  setup_teams

  [[ ! -f ".claude/settings.local.json" ]]
}

@test "setup_teams falls back on old CLI" {
  RALPH_ENABLE_TEAMS=true
  check_teams_support() { return 1; }  # Mock — too old

  setup_teams

  [[ "${RALPH_ENABLE_TEAMS}" == "false" ]]
}
```

## Acceptance Criteria

- [ ] `RALPH_ENABLE_TEAMS`, `RALPH_MAX_TEAMMATES`, `RALPH_BG_TESTING`, `RALPH_TEAMMATE_MODE` in `.ralphrc` template
- [ ] `setup_teams()` creates `.claude/settings.local.json` when enabled
- [ ] `setup_teams()` does nothing when disabled (default)
- [ ] `setup_teams()` falls back gracefully on old CLI versions
- [ ] `.claude/settings.local.json` added to `.gitignore`
- [ ] Known limitations documented in `.ralphrc` comments
