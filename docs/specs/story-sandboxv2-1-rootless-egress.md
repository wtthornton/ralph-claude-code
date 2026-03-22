# Story SANDBOXV2-1: Rootless Docker Mode and Network Egress Control

**Epic:** [Sandbox Hardening](epic-sandbox-hardening.md)
**Priority:** Medium
**Status:** Open
**Effort:** Medium
**Component:** `lib/sandbox.sh`, `docker/ralph-sandbox/Dockerfile`

---

## Problem

Standard Docker runs as root and allows unrestricted network access from containers. Both are unnecessary for Ralph's autonomous loop and represent security risks.

## Solution

1. Detect and prefer rootless Docker when available
2. Block network egress by default with configurable allowlist for approved domains

## Implementation

### Step 1: Rootless Docker detection

```bash
ralph_detect_docker_mode() {
    # Check for rootless Docker
    if docker info 2>/dev/null | grep -q "rootless"; then
        echo "rootless"
    elif command -v dockerd-rootless &>/dev/null; then
        echo "rootless-available"
    else
        echo "standard"
    fi
}
```

### Step 2: Network egress control

```bash
RALPH_SANDBOX_NETWORK=${RALPH_SANDBOX_NETWORK:-none}  # none, host, allowlist
RALPH_SANDBOX_ALLOWED_HOSTS=${RALPH_SANDBOX_ALLOWED_HOSTS:-""}  # comma-separated

ralph_build_sandbox_network_args() {
    case "$RALPH_SANDBOX_NETWORK" in
        none)
            echo "--network none"
            ;;
        allowlist)
            # Create a custom network with iptables rules
            local net_name="ralph-sandbox-net"
            docker network create "$net_name" 2>/dev/null || true
            echo "--network $net_name"
            # Note: iptables rules for allowlist applied post-start
            ;;
        host)
            echo "--network host"
            log "WARN" "Sandbox running with host network — no egress control"
            ;;
    esac
}
```

### Step 3: Container launch with security hardening

```bash
ralph_run_sandbox() {
    local project_dir="$1"
    local network_args
    network_args=$(ralph_build_sandbox_network_args)

    docker run \
        --rm \
        $network_args \
        --read-only \
        --tmpfs /tmp:rw,noexec,nosuid \
        --security-opt no-new-privileges \
        --cap-drop ALL \
        --cap-add DAC_OVERRIDE \
        --cpus "${RALPH_SANDBOX_CPUS:-2}" \
        --memory "${RALPH_SANDBOX_MEMORY:-4g}" \
        --pids-limit "${RALPH_SANDBOX_PIDS:-256}" \
        -v "${project_dir}:/workspace:rw" \
        -v "${RALPH_DIR}:/ralph-state:rw" \
        -e ANTHROPIC_API_KEY \
        ralph-sandbox:latest
}
```

## Design Notes

- **`--network none` as default**: Matches OpenAI Codex's approach. Claude Code doesn't need internet access during task execution — it has the codebase locally.
- **`--read-only` + tmpfs**: Prevents writes outside the workspace volume. /tmp is writable but non-executable.
- **`--cap-drop ALL`**: Remove all Linux capabilities. `DAC_OVERRIDE` is added back for file permission handling in volume mounts.
- **`--security-opt no-new-privileges`**: Prevents privilege escalation inside the container.
- **`--pids-limit 256`**: Prevents fork bombs.
- **Allowlist mode**: For tasks that genuinely need network (e.g., `npm install`), operators can allowlist specific hosts.

## Acceptance Criteria

- [ ] Rootless Docker auto-detected and preferred
- [ ] Network egress blocked by default (`--network none`)
- [ ] Allowlist mode available for approved domains
- [ ] Container runs with minimal capabilities
- [ ] Read-only filesystem with tmpfs for /tmp
- [ ] PID limit prevents fork bombs
- [ ] Fallback to standard Docker with warning

## Test Plan

```bash
@test "ralph_detect_docker_mode returns valid mode" {
    source "$RALPH_DIR/lib/sandbox.sh"
    local mode
    mode=$(ralph_detect_docker_mode)
    [[ "$mode" == "rootless" || "$mode" == "rootless-available" || "$mode" == "standard" ]]
}

@test "ralph_build_sandbox_network_args defaults to none" {
    source "$RALPH_DIR/lib/sandbox.sh"
    RALPH_SANDBOX_NETWORK="none"
    local args
    args=$(ralph_build_sandbox_network_args)
    assert_equal "$args" "--network none"
}
```

## References

- [Docker — Rootless Mode](https://docs.docker.com/engine/security/rootless/)
- [OpenAI — Unrolling the Codex Agent Loop](https://openai.com/index/unrolling-the-codex-agent-loop/)
- [Northflank — How to Sandbox AI Agents in 2026](https://northflank.com/blog/how-to-sandbox-ai-agents)
- [NVIDIA — Practical Security for Sandboxing Agentic Workflows](https://developer.nvidia.com/blog/practical-security-guidance-for-sandboxing-agentic-workflows-and-managing-execution-risk/)
