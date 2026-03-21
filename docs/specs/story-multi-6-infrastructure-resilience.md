# Story RALPH-MULTI-6: Fix Startup Hook and Add MCP Pre-Flight Check

**Epic:** [Multi-Task Loop Violation and Cascading Failures](epic-multi-task-cascading-failures.md)
**Priority:** Medium
**Status:** Done
**Effort:** Small
**Component:** `.claude/settings.json` (hook config), `ralph_loop.sh` (MCP check)

---

## Problem

Two infrastructure issues silently degraded the March 21 session:

### 6a: SessionStart Hook Failure

The startup hook runs a PowerShell command, but Ralph executes in WSL/bash where
`powershell` is not in PATH:

```
hook_name: "SessionStart:startup"
stderr: "/bin/sh: 1: powershell: not found"
exit_code: 127
outcome: "error"
```

**Research finding (2026):** SessionStart hooks CANNOT block session startup. Exit
code 2 shows stderr to the user but the session continues. Exit code 127 is a
non-blocking error shown only in verbose mode. The hook failure is cosmetically noisy
but functionally harmless.

However, there is a known issue ([#34713](https://github.com/anthropics/claude-code/issues/34713))
where false "Hook Error" labels cause Claude to prematurely end turns. If the startup
hook error confuses Claude, it could affect the session quality.

### 6b: MCP Server Failures

3 of 5 MCP servers failed to connect:
```json
{"name": "tapps-mcp", "status": "failed"}
{"name": "docs-mcp", "status": "failed"}
{"name": "playwright", "status": "connected"}
```

**Research finding (2026):** There is no built-in MCP health check API (Issue #29626).
No auto-reconnect exists (Issue #34696). Claude Code's MCP health checker has a
protocol bug (#7404) that causes false "Failed to connect" for some servers.

**Impact:** PROMPT.md instructs Claude to call `tapps_session_start()` and
`tapps_quick_check()`, but these tools are unavailable when tapps-mcp is down.
Claude either skips them silently or errors on the tool call.

## Solution

### Fix 6a: Make startup hook cross-platform

**Option A (recommended):** Rewrite the hook in bash:
```json
{
  "hooks": {
    "SessionStart": [{
      "type": "command",
      "command": "bash -c 'echo \"Ralph session started at $(date)\"'",
      "matcher": "startup"
    }]
  }
}
```

**Option B:** Gate on shell availability:
```json
{
  "command": "command -v powershell >/dev/null 2>&1 && powershell -Command '...' || echo 'PowerShell not available, skipping hook'"
}
```

**Option C:** Remove the hook if it only served a diagnostic purpose.

### Fix 6b: Add MCP pre-flight check to Ralph startup

Add a check after Claude execution starts (in the stream output) or as a pre-flight
step that verifies Docker containers are running:

```bash
# ralph_loop.sh -- add to startup section, before first loop iteration

# Pre-flight: Check MCP Docker containers (if configured)
if command -v docker >/dev/null 2>&1; then
    local mcp_containers_down=()
    while IFS= read -r container; do
        [[ -z "$container" ]] && continue
        if ! docker inspect --format='{{.State.Running}}' "$container" 2>/dev/null | grep -q "true"; then
            mcp_containers_down+=("$container")
        fi
    done < <(docker ps -a --filter "label=ralph.mcp=true" --format '{{.Names}}' 2>/dev/null)

    if [[ ${#mcp_containers_down[@]} -gt 0 ]]; then
        log_status "WARN" "MCP containers not running: ${mcp_containers_down[*]}"
        log_status "INFO" "Start with: docker compose up -d (or check docker-compose.yml)"
    fi
fi
```

**Alternative (simpler):** Parse the `system:init` event from stream-json output
after Claude starts, and log warnings for failed servers:

```bash
# After Claude execution completes, check for MCP failures in the stream
if [[ -f "$output_file" ]]; then
    local failed_mcps
    failed_mcps=$(grep '"type".*"system"' "$output_file" 2>/dev/null | head -1 | \
        jq -r '[.mcp_servers[]? | select(.status == "failed") | .name] | join(", ")' 2>/dev/null)
    if [[ -n "$failed_mcps" ]]; then
        log_status "WARN" "MCP servers failed to connect: $failed_mcps"
    fi
fi
```

## Design Notes

- **6a is cosmetic:** The hook failure doesn't prevent session startup but generates
  noise. The fix is trivial and eliminates the error.
- **6b Docker check:** Uses a `ralph.mcp=true` label convention to identify MCP
  containers. This requires containers to be labeled, which is a one-time setup.
- **6b stream parsing alternative:** Requires no Docker setup but only detects
  failures post-hoc (after Claude already started with degraded capabilities).
  Better than nothing but doesn't prevent the degraded session.
- **Neither fix prevents the session from starting.** They provide visibility so the
  operator can take action.

## Acceptance Criteria

- [ ] Startup hook does not produce "powershell not found" error in WSL
- [ ] MCP server failures are logged with server names
- [ ] Operator guidance is provided (how to start containers, or which tools are affected)
- [ ] Checks are non-blocking (do not prevent session startup)

## Test Plan

```bash
@test "startup hook works in bash environment" {
    # Verify the hook command works without powershell
    run bash -c 'echo "Ralph session started at $(date)"'
    assert_success
}

@test "MCP failure detection from system event" {
    local output_file="$TEST_DIR/stream.log"
    echo '{"type":"system","mcp_servers":[{"name":"tapps-mcp","status":"failed"},{"name":"playwright","status":"connected"}]}' > "$output_file"

    local failed_mcps
    failed_mcps=$(grep '"type".*"system"' "$output_file" | head -1 | \
        jq -r '[.mcp_servers[]? | select(.status == "failed") | .name] | join(", ")' 2>/dev/null)

    assert_equal "$failed_mcps" "tapps-mcp"
}
```

## References

- SessionStart hooks cannot block: [code.claude.com/docs/en/hooks](https://code.claude.com/docs/en/hooks)
- Hook error labels cause premature turn end: [Issue #34713](https://github.com/anthropics/claude-code/issues/34713)
- SessionStart hook fails on Windows: [Issue #21468](https://github.com/anthropics/claude-code/issues/21468)
- No MCP health check API: [Issue #29626](https://github.com/anthropics/claude-code/issues/29626)
- No MCP auto-reconnect: [Issue #34696](https://github.com/anthropics/claude-code/issues/34696)
- MCP protocol violation in health checker: [Issue #7404](https://github.com/anthropics/claude-code/issues/7404)
