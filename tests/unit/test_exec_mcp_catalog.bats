#!/usr/bin/env bats
# Issues 1 + 4: STDIO MCP tool catalog availability across session resume.
#
# Issue 1 — a resumed session can come up without its STDIO MCP catalog
#   (tapps-mcp / docs-mcp). The harness must DETECT the no-op signature so it
#   can retry the loop with a fresh session instead of burning it.
# Issue 4 — MCP_HEALTH must report not-ok when the tool catalog is empty even
#   though the startup probe (port/connection liveness) said "available".
#
# These cover the decision-point helpers in lib/exec_helpers.sh:
#   * exec_stream_server_status — parse a server's status from the session
#     `type:"system"` init message.
#   * exec_mcp_catalog_lost     — the resume-retry trigger (Issue 1).
#   * exec_mcp_health_label     — the catalog-aware health label (Issue 4).

bats_require_minimum_version 1.5.0
load '../helpers/test_helper'

ROOT="${BATS_TEST_DIRNAME}/../.."

setup() {
    TMPDIR_TC="$(mktemp -d)"
    OUT="$TMPDIR_TC/out.json"
    log_status() { :; }
    export -f log_status
    source "$ROOT/lib/exec_helpers.sh"
}

teardown() {
    rm -rf "$TMPDIR_TC"
}

# Healthy session: init message lists all servers connected.
_write_healthy_stream() {
    cat > "$OUT" <<'JSON'
{"type":"system","subtype":"init","session_id":"abc","mcp_servers":[{"name":"tapps-mcp","status":"connected"},{"name":"docs-mcp","status":"connected"},{"name":"tapps-brain","status":"connected"}]}
{"type":"assistant","message":{"content":[{"type":"text","text":"done"}]}}
{"type":"result","subtype":"success","result":"ok"}
JSON
}

# Resume with lost STDIO catalog: init shows tapps-mcp failed.
_write_failed_init_stream() {
    cat > "$OUT" <<'JSON'
{"type":"system","subtype":"init","session_id":"abc","mcp_servers":[{"name":"tapps-mcp","status":"failed"},{"name":"tapps-brain","status":"connected"}]}
{"type":"result","subtype":"success","result":"nothing to do"}
JSON
}

# Resume with lost catalog manifested as an agent-visible "no such tool".
_write_no_such_tool_stream() {
    cat > "$OUT" <<'JSON'
{"type":"system","subtype":"init","session_id":"abc"}
{"type":"assistant","message":{"content":[{"type":"text","text":"Error: No such tool available: mcp__tapps-mcp__tapps_session_start. The MCP server process has disconnected."}]}}
{"type":"result","subtype":"success","result":"could not start"}
JSON
}

# =============================================================================
# exec_stream_server_status
# =============================================================================

@test "exec_stream_server_status: connected server reported as connected" {
    _write_healthy_stream
    [[ "$(exec_stream_server_status "$OUT" tapps-mcp)" == "connected" ]]
}

@test "exec_stream_server_status: failed server reported as failed" {
    _write_failed_init_stream
    [[ "$(exec_stream_server_status "$OUT" tapps-mcp)" == "failed" ]]
}

@test "exec_stream_server_status: server missing from a populated list is absent" {
    _write_failed_init_stream
    [[ "$(exec_stream_server_status "$OUT" docs-mcp)" == "absent" ]]
}

@test "exec_stream_server_status: no system init line yields empty (no false signal)" {
    printf '%s\n' '{"type":"result","subtype":"success","result":"ok"}' > "$OUT"
    [[ -z "$(exec_stream_server_status "$OUT" tapps-mcp)" ]]
}

# =============================================================================
# exec_mcp_catalog_lost (Issue 1 trigger)
# =============================================================================

@test "Issue 1: healthy resumed session is NOT flagged as catalog-lost" {
    _write_healthy_stream
    export RALPH_MCP_TAPPS_AVAILABLE=true RALPH_MCP_DOCS_AVAILABLE=true
    run exec_mcp_catalog_lost "$OUT"
    [[ "$status" -ne 0 ]] || fail "healthy session must not be flagged catalog-lost"
}

@test "Issue 1: 'No such tool available: mcp__' signature flags catalog-lost" {
    _write_no_such_tool_stream
    # Signature (a) is transport-agnostic — fires regardless of startup flags.
    export RALPH_MCP_TAPPS_AVAILABLE=false RALPH_MCP_DOCS_AVAILABLE=false
    run exec_mcp_catalog_lost "$OUT"
    [[ "$status" -eq 0 ]] || fail "expected catalog-lost on 'No such tool available: mcp__'"
}

@test "Issue 1: failed init for an EXPECTED stdio server flags catalog-lost" {
    _write_failed_init_stream
    export RALPH_MCP_TAPPS_AVAILABLE=true RALPH_MCP_DOCS_AVAILABLE=true
    run exec_mcp_catalog_lost "$OUT"
    [[ "$status" -eq 0 ]] || fail "expected catalog-lost when an expected stdio server failed"
}

@test "Issue 1: failed init is NOT catalog-lost when the server was never expected" {
    _write_failed_init_stream
    # Startup probe never found tapps-mcp → a failed init is not a regression.
    export RALPH_MCP_TAPPS_AVAILABLE=false RALPH_MCP_DOCS_AVAILABLE=false
    run exec_mcp_catalog_lost "$OUT"
    [[ "$status" -ne 0 ]] || fail "must not flag catalog-lost for an unexpected server"
}

# =============================================================================
# exec_mcp_health_label (Issue 4)
# =============================================================================

@test "Issue 4: catalog-lost sentinel forces health=down even when probe said available" {
    local sentinel="$TMPDIR_TC/.mcp_catalog_lost"
    touch "$sentinel"
    [[ "$(exec_mcp_health_label true "$sentinel")" == "down" ]] \
        || fail "live probe + empty catalog must report down"
}

@test "Issue 4: available + no sentinel reports ok" {
    [[ "$(exec_mcp_health_label true "$TMPDIR_TC/.mcp_catalog_lost")" == "ok" ]]
}

@test "Issue 4: unavailable probe reports down" {
    [[ "$(exec_mcp_health_label false "$TMPDIR_TC/.mcp_catalog_lost")" == "down" ]]
}

# =============================================================================
# Wiring: ralph_loop.sh consumes the helpers
# =============================================================================

@test "Issue 1: execute_claude_code wires the resume catalog detect-and-retry" {
    grep -qE 'exec_mcp_catalog_lost' "$ROOT/ralph_loop.sh" \
        || fail "ralph_loop.sh should call exec_mcp_catalog_lost in the retry path"
    grep -qE 'fresh-session retry \(MCP-RESUME\)' "$ROOT/ralph_loop.sh" \
        || fail "ralph_loop.sh should run a fresh-session retry on catalog loss"
}

@test "Issue 4: build_loop_context uses exec_mcp_health_label for MCP_HEALTH" {
    grep -qE 'exec_mcp_health_label' "$ROOT/ralph_loop.sh" \
        || fail "MCP_HEALTH should derive tapps health from exec_mcp_health_label"
}
