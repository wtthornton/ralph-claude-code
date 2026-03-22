# Story UPKEEP-2: MCP Server Failure Suppression

**Epic:** [Update & Log Reliability](epic-update-log-reliability.md)
**Priority:** Medium
**Status:** Pending
**Effort:** Small
**Component:** `ralph_loop.sh` (MCP status handling), `.ralph/hooks/on-session-start.sh`

---

## Problem

Two MCP servers (`tapps-mcp`, `docs-mcp`) fail to connect in every single session. Each failure is logged individually across 48+ log files per day, creating significant log noise. No mechanism exists to:
1. Detect that an MCP server is consistently failing
2. Suppress repeated failure messages
3. Alert the user that an MCP dependency is permanently broken

**Root cause confirmed by:** TheStudio logs 2026-03-22, `tapps-mcp` and `docs-mcp` failed in every `claude_output_*.log`.

## Solution

Implement a "log once per session" pattern for MCP failures. Track which servers have failed, log the first failure at WARN level, suppress subsequent failures at DEBUG level, and emit a summary at session end.

## Implementation

### Step 1: Track MCP failures in session state

```bash
MCP_FAILURE_FILE="${RALPH_DIR}/.mcp_failures_session"

ralph_init_mcp_tracking() {
    : > "$MCP_FAILURE_FILE"  # Reset at session start
}

ralph_record_mcp_failure() {
    local server_name="$1"
    local timestamp
    timestamp=$(date +%s)

    # Check if already recorded this session
    if grep -q "^${server_name}$" "$MCP_FAILURE_FILE" 2>/dev/null; then
        log "DEBUG" "MCP server '$server_name' still failing (suppressed — logged at session start)"
        return 0
    fi

    # First failure for this server this session
    echo "$server_name" >> "$MCP_FAILURE_FILE"
    log "WARN" "MCP server '$server_name' failed to connect — subsequent failures will be suppressed"
}
```

### Step 2: Parse MCP status from Claude output

```bash
# In the post-invocation analysis, extract MCP server statuses:
ralph_check_mcp_status() {
    local output_file="$1"

    # Extract MCP server status lines from JSONL stream
    local failed_servers
    failed_servers=$(jq -r 'select(.type == "system") | .mcp_servers[]? | select(.status == "failed") | .name' \
        "$output_file" 2>/dev/null | sort -u)

    if [[ -n "$failed_servers" ]]; then
        while IFS= read -r server; do
            ralph_record_mcp_failure "$server"
        done <<< "$failed_servers"
    fi
}
```

### Step 3: Emit session summary

```bash
# At session end or during --status:
ralph_mcp_failure_summary() {
    if [[ ! -f "$MCP_FAILURE_FILE" ]] || [[ ! -s "$MCP_FAILURE_FILE" ]]; then
        return 0
    fi

    local count
    count=$(wc -l < "$MCP_FAILURE_FILE" | tr -d '[:space:]')
    local servers
    servers=$(paste -sd',' "$MCP_FAILURE_FILE")

    log "WARN" "MCP servers failed this session ($count): $servers"
    log "INFO" "Check MCP configuration: claude mcp list"
}
```

### Step 4: Integrate with startup

```bash
# In ralph_loop.sh startup sequence:
ralph_init_mcp_tracking

# After each Claude invocation:
ralph_check_mcp_status "$OUTPUT_FILE"
```

## Design Notes

- **"Log once" pattern**: Follows the OpenTelemetry Log Deduplication pattern — collapse repeated events into a single record. The sentinel file (`$MCP_FAILURE_FILE`) acts as an in-session deduplication cache.
- **Session-scoped**: The failure file is reset at session start. If an MCP server is fixed mid-session, it won't be in the file and the next failure would be logged.
- **DEBUG for suppressed failures**: The information is still available in verbose/debug mode but doesn't pollute the default log output.
- **Prometheus Alertmanager parallel**: This is analogous to Alertmanager's "grouping" — combine related alerts into a single notification with a count.
- **systemd journald parallel**: journald's `RateLimitIntervalSec` + `RateLimitBurst` serves the same purpose — "N messages suppressed due to ratelimiting."
- **Not fixing MCP connections**: Ralph can't fix MCP server configuration — that's the user's responsibility. Ralph's job is to report the problem clearly without drowning useful logs in noise.

## Acceptance Criteria

- [ ] First MCP failure per server per session logs at WARN level
- [ ] Subsequent failures for same server log at DEBUG level (not WARN)
- [ ] Session summary lists all failed MCP servers with count
- [ ] Failure tracking resets at session start
- [ ] `ralph --status` shows current MCP failure state
- [ ] No impact on MCP servers that connect successfully

## Test Plan

```bash
@test "ralph_record_mcp_failure logs first occurrence at WARN" {
    source "$RALPH_DIR/ralph_loop.sh"
    MCP_FAILURE_FILE="$TEST_DIR/.mcp_failures"
    : > "$MCP_FAILURE_FILE"

    run ralph_record_mcp_failure "tapps-mcp"
    assert_output --partial "WARN"
    assert_output --partial "tapps-mcp"
}

@test "ralph_record_mcp_failure suppresses duplicates" {
    source "$RALPH_DIR/ralph_loop.sh"
    MCP_FAILURE_FILE="$TEST_DIR/.mcp_failures"
    echo "tapps-mcp" > "$MCP_FAILURE_FILE"

    run ralph_record_mcp_failure "tapps-mcp"
    assert_output --partial "DEBUG"
    assert_output --partial "suppressed"
}

@test "ralph_record_mcp_failure tracks multiple servers" {
    source "$RALPH_DIR/ralph_loop.sh"
    MCP_FAILURE_FILE="$TEST_DIR/.mcp_failures"
    : > "$MCP_FAILURE_FILE"

    ralph_record_mcp_failure "tapps-mcp"
    ralph_record_mcp_failure "docs-mcp"

    assert_equal "$(wc -l < "$MCP_FAILURE_FILE" | tr -d ' ')" "2"
}

@test "ralph_init_mcp_tracking resets state" {
    source "$RALPH_DIR/ralph_loop.sh"
    MCP_FAILURE_FILE="$TEST_DIR/.mcp_failures"
    echo "old-server" > "$MCP_FAILURE_FILE"

    ralph_init_mcp_tracking
    assert_equal "$(wc -l < "$MCP_FAILURE_FILE" | tr -d ' ')" "0"
}

@test "ralph_mcp_failure_summary shows count and names" {
    source "$RALPH_DIR/ralph_loop.sh"
    MCP_FAILURE_FILE="$TEST_DIR/.mcp_failures"
    echo "tapps-mcp" > "$MCP_FAILURE_FILE"
    echo "docs-mcp" >> "$MCP_FAILURE_FILE"

    run ralph_mcp_failure_summary
    assert_output --partial "2"
    assert_output --partial "tapps-mcp"
    assert_output --partial "docs-mcp"
}
```

## References

- [OpenTelemetry Log Deduplication Processor](https://opentelemetry.io/blog/2026/log-deduplication-processor/)
- [systemd journald.conf — Rate Limiting](https://www.freedesktop.org/software/systemd/man/latest/journald.conf.html)
- [incident.io — Guide to Preventing Alert Fatigue](https://incident.io/blog/2025-guide-to-preventing-alert-fatigue-for-modern-on-call-teams)
- [NXLog — Reduce Log Noise and Fight Alert Fatigue](https://nxlog.co/news-and-blog/posts/reduce-log-noise-and-fight-soc-alert-fatigue)
- [MCP Ping Specification](https://modelcontextprotocol.io/specification/2025-03-26/basic/utilities/ping)
- [MCP Connection Health Checks Guide](https://mcpcat.io/guides/implementing-connection-health-checks/)
- [AWS — Build Resilient AI Agents](https://aws.amazon.com/blogs/architecture/build-resilient-generative-ai-agents/)
