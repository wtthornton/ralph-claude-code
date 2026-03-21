# Story RALPH-HOOKS-6: Add --agent ralph to build_claude_command()

**Epic:** [Hooks + Agent Definition](epic-hooks-agent-definition.md)
**Priority:** Important
**Status:** Done
**Effort:** Small
**Component:** `ralph_loop.sh`

---

## Problem

Ralph v0.11.x builds the Claude CLI command with inline flags:
```bash
claude -p "$(cat .ralph/PROMPT.md)" \
  --output-format json \
  --allowedTools Write Read Edit Bash(git add *) ... \
  --resume "$session_id"
```

With the custom agent definition (RALPH-HOOKS-1), this reduces to:
```bash
claude --agent ralph --output-format json
```

The `build_claude_command()` function in `ralph_loop.sh` needs to support both the
new agent mode and legacy fallback.

## Solution

Modify `build_claude_command()` in `ralph_loop.sh` to:
1. Check for agent support (`check_agent_support()`)
2. Use `--agent ralph` when supported and `RALPH_USE_AGENT=true`
3. Fall back to `-p` mode when not supported or `RALPH_USE_AGENT=false`
4. Remove `--allowedTools` parsing when in agent mode (agent definition handles it)

## Implementation

### Add version detection function

```bash
# Check if Claude Code CLI supports --agent flag (requires v2.1+)
check_agent_support() {
  local version
  version=$(${CLAUDE_CODE_CMD:-claude} --version 2>/dev/null | grep -oP '\d+\.\d+' | head -1)

  if [[ -z "$version" ]]; then
    return 1  # Can't determine version, fall back
  fi

  # Compare major.minor >= 2.1
  local major minor
  major=$(echo "$version" | cut -d. -f1)
  minor=$(echo "$version" | cut -d. -f2)

  if [[ "$major" -gt 2 ]] || [[ "$major" -eq 2 && "$minor" -ge 1 ]]; then
    return 0  # Agent mode supported
  fi

  return 1  # Fall back to legacy mode
}
```

### Modify build_claude_command()

Add agent mode branch at the top of the command building logic:

```bash
build_claude_command() {
  local cmd="${CLAUDE_CODE_CMD:-claude}"
  local args=()

  # Agent mode (v1.0+)
  if [[ "${RALPH_USE_AGENT:-true}" == "true" ]] && check_agent_support; then
    args+=("--agent" "${RALPH_AGENT_NAME:-ralph}")
    args+=("--output-format" "${CLAUDE_OUTPUT_FORMAT:-json}")

    # maxTurns is in agent definition, no --allowedTools needed
    # Session continuity handled by agent memory, no --resume needed

    log_info "Using agent mode: --agent ${RALPH_AGENT_NAME:-ralph}"
  else
    # Legacy mode (v0.11.x compatible)
    args+=("-p" "$(cat .ralph/PROMPT.md)")
    args+=("--output-format" "${CLAUDE_OUTPUT_FORMAT:-json}")

    # Build --allowedTools from ALLOWED_TOOLS (existing logic)
    if [[ -n "${ALLOWED_TOOLS:-}" ]]; then
      args+=("--allowedTools")
      IFS=',' read -ra tools <<< "$ALLOWED_TOOLS"
      for tool in "${tools[@]}"; do
        args+=("$(echo "$tool" | xargs)")  # trim whitespace
      done
    fi

    # Session continuity (existing logic)
    if [[ "${CLAUDE_USE_CONTINUE:-false}" == "true" && -n "${session_id:-}" ]]; then
      args+=("--resume" "$session_id")
    fi

    log_info "Using legacy mode: -p with --allowedTools"
  fi

  echo "$cmd ${args[*]}"
}
```

### New .ralphrc variables

```bash
# Agent mode (v1.0)
RALPH_USE_AGENT=true          # Use --agent instead of -p
RALPH_AGENT_NAME="ralph"      # Agent definition name
```

### Key Design Decisions

1. **`RALPH_USE_AGENT=true` by default:** New installs use agent mode. Existing installs
   can set `false` to keep legacy behavior.

2. **Version detection is conservative:** Falls back to legacy mode if version can't be
   determined. No risk of breaking existing setups.

3. **No `--resume` in agent mode:** Agent memory (`memory: project`) replaces session
   continuity. The agent persists learnings across invocations natively.

4. **No `--allowedTools` in agent mode:** Tool restrictions defined in the agent
   definition YAML. Removes ~30 lines of bash string splitting.

5. **Logging:** Logs which mode is active for debugging.

## Testing

```bash
@test "build_claude_command uses --agent in agent mode" {
  RALPH_USE_AGENT=true
  # Mock check_agent_support to return 0
  check_agent_support() { return 0; }

  local cmd
  cmd=$(build_claude_command)

  [[ "$cmd" == *"--agent ralph"* ]]
  [[ "$cmd" != *"-p"* ]]
  [[ "$cmd" != *"--allowedTools"* ]]
}

@test "build_claude_command falls back to -p in legacy mode" {
  RALPH_USE_AGENT=false
  ALLOWED_TOOLS="Write,Read,Edit"

  local cmd
  cmd=$(build_claude_command)

  [[ "$cmd" == *"-p"* ]]
  [[ "$cmd" == *"--allowedTools"* ]]
  [[ "$cmd" != *"--agent"* ]]
}

@test "build_claude_command falls back when CLI too old" {
  RALPH_USE_AGENT=true
  # Mock check_agent_support to return 1
  check_agent_support() { return 1; }

  local cmd
  cmd=$(build_claude_command)

  [[ "$cmd" == *"-p"* ]]
  [[ "$cmd" != *"--agent"* ]]
}

@test "check_agent_support detects v2.1+" {
  # Mock claude --version
  claude() { echo "Claude Code v2.3.1"; }
  export -f claude
  CLAUDE_CODE_CMD=claude

  check_agent_support
  [[ $? -eq 0 ]]
}

@test "check_agent_support rejects v1.x" {
  claude() { echo "Claude Code v1.9.2"; }
  export -f claude
  CLAUDE_CODE_CMD=claude

  ! check_agent_support
}
```

## Acceptance Criteria

- [ ] `build_claude_command()` uses `--agent ralph` when `RALPH_USE_AGENT=true` and CLI supports it
- [ ] `build_claude_command()` falls back to `-p` mode when `RALPH_USE_AGENT=false`
- [ ] `build_claude_command()` falls back when CLI version < 2.1
- [ ] `--allowedTools` parsing removed in agent mode
- [ ] `--resume` removed in agent mode (agent memory replaces it)
- [ ] `RALPH_USE_AGENT` and `RALPH_AGENT_NAME` added to `.ralphrc` template
- [ ] `check_agent_support()` function added with version detection
- [ ] Existing BATS tests pass (legacy mode behavior unchanged)
