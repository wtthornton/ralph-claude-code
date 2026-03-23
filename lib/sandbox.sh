#!/bin/bash

# lib/sandbox.sh — Docker Sandbox Execution (Phase 11, RALPH-SANDBOX)
#
# SANDBOX-1: Sandbox interface and Docker integration
# SANDBOX-2: Docker sandbox execution runner
#
# Provides filesystem and resource isolation for Ralph's autonomous loop.
# Multi-provider (E2B, Daytona, Cloudflare) is TheStudio premium.

# Configuration
RALPH_SANDBOX_IMAGE="${RALPH_SANDBOX_IMAGE:-ralph-sandbox}"
RALPH_SANDBOX_CPU_LIMIT="${RALPH_SANDBOX_CPU_LIMIT:-2}"
RALPH_SANDBOX_MEMORY_LIMIT="${RALPH_SANDBOX_MEMORY_LIMIT:-4g}"
RALPH_SANDBOX_TIMEOUT="${RALPH_SANDBOX_TIMEOUT:-60}"
RALPH_SANDBOX_NETWORK="${RALPH_SANDBOX_NETWORK:-none}"
RALPH_SANDBOX_REQUIRED="${RALPH_SANDBOX_REQUIRED:-false}"

# SANDBOXV2-1: Extended configuration
RALPH_SANDBOX_ALLOWED_HOSTS="${RALPH_SANDBOX_ALLOWED_HOSTS:-}"
RALPH_SANDBOX_CPUS="${RALPH_SANDBOX_CPUS:-2}"
RALPH_SANDBOX_MEMORY="${RALPH_SANDBOX_MEMORY:-4g}"
RALPH_SANDBOX_PIDS="${RALPH_SANDBOX_PIDS:-256}"

# SANDBOXV2-3: Runtime configuration
RALPH_SANDBOX_RUNTIME="${RALPH_SANDBOX_RUNTIME:-auto}"

# =============================================================================
# SANDBOX-1: Interface functions
# =============================================================================

# sandbox_available — Check if Docker is available
sandbox_available() {
    command -v docker &>/dev/null && docker info &>/dev/null
}

# sandbox_create — Build/pull the Ralph sandbox image
sandbox_create() {
    local dockerfile="${SCRIPT_DIR:-$(dirname "${BASH_SOURCE[0]}")/..}/Dockerfile.sandbox"

    if ! sandbox_available; then
        echo "Error: Docker not available"
        return 1
    fi

    if docker image inspect "$RALPH_SANDBOX_IMAGE" &>/dev/null; then
        echo "Sandbox image '$RALPH_SANDBOX_IMAGE' already exists"
        return 0
    fi

    if [[ -f "$dockerfile" ]]; then
        echo "Building sandbox image from $dockerfile..."
        docker build -t "$RALPH_SANDBOX_IMAGE" -f "$dockerfile" "$(dirname "$dockerfile")"
    else
        echo "Building sandbox image with inline Dockerfile..."
        docker build -t "$RALPH_SANDBOX_IMAGE" - << 'DOCKEREOF'
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    bash \
    curl \
    git \
    jq \
    tmux \
    python3 \
    python3-pip \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js 22 LTS
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# Install Claude Code CLI
RUN npm install -g @anthropic-ai/claude-code

# Working directory
WORKDIR /workspace

# Default command runs Ralph loop
ENTRYPOINT ["bash"]
CMD ["/workspace/.ralph/../ralph_loop.sh"]
DOCKEREOF
    fi
}

# sandbox_status — Get container status
sandbox_status() {
    local container_name="${1:-ralph-sandbox-$$}"
    if docker ps --filter "name=$container_name" --format '{{.Status}}' 2>/dev/null | head -1; then
        return 0
    fi
    echo "not running"
    return 1
}

# sandbox_logs — Stream container logs
sandbox_logs() {
    local container_name="${1:-ralph-sandbox-$$}"
    docker logs -f "$container_name" 2>/dev/null
}

# sandbox_stop — Stop a running sandbox container
sandbox_stop() {
    local container_name="${1:-ralph-sandbox-$$}"
    docker stop "$container_name" 2>/dev/null || true
}

# sandbox_cleanup — Remove stopped sandbox containers
sandbox_cleanup() {
    docker ps -a --filter "name=ralph-sandbox-" --filter "status=exited" -q 2>/dev/null | \
        xargs -r docker rm 2>/dev/null || true
}

# =============================================================================
# SANDBOX-2: Execution runner
# =============================================================================

# ralph_sandbox_run — Run Ralph loop inside Docker container
#
# Usage: ralph --sandbox [OPTIONS]
#
ralph_sandbox_run() {
    local ralph_dir="${RALPH_DIR:-.ralph}"
    local project_dir="$(pwd)"
    local container_name="ralph-sandbox-$$"

    # Pre-flight checks
    if ! sandbox_available; then
        if [[ "${RALPH_SANDBOX_REQUIRED}" == "true" ]]; then
            echo "Error: Docker required but not available (RALPH_SANDBOX_REQUIRED=true)"
            return 1
        else
            echo "Warning: Docker not available, falling back to host execution"
            return 2  # Signal to caller to fall back
        fi
    fi

    # Dry run check
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        echo "Sandbox dry-run: Docker $(docker --version 2>/dev/null || echo 'not available')"
        echo "Image: $RALPH_SANDBOX_IMAGE"
        echo "CPU limit: $RALPH_SANDBOX_CPU_LIMIT"
        echo "Memory limit: $RALPH_SANDBOX_MEMORY_LIMIT"
        echo "Network: $RALPH_SANDBOX_NETWORK"
        return 0
    fi

    # Ensure image exists
    if ! docker image inspect "$RALPH_SANDBOX_IMAGE" &>/dev/null; then
        echo "Building sandbox image..."
        sandbox_create || {
            echo "Error: Failed to build sandbox image"
            return 1
        }
    fi

    echo "Starting Ralph in Docker sandbox..."
    echo "  Container: $container_name"
    echo "  CPU limit: $RALPH_SANDBOX_CPU_LIMIT"
    echo "  Memory: $RALPH_SANDBOX_MEMORY_LIMIT"
    echo ""

    # Build docker run command
    local docker_args=(
        "run"
        "--name" "$container_name"
        "--rm"
        "--cpus" "$RALPH_SANDBOX_CPU_LIMIT"
        "--memory" "$RALPH_SANDBOX_MEMORY_LIMIT"
        # Mount project at /workspace
        "-v" "$project_dir:/workspace"
        # Mount .claude/ read-only
        "-v" "$project_dir/.claude:/workspace/.claude:ro"
        # Pass API key
        "-e" "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}"
        # Working directory
        "-w" "/workspace"
    )

    # Network isolation
    if [[ "${RALPH_SANDBOX_NETWORK}" == "false" ]]; then
        docker_args+=("--network" "none")
    fi

    # Timeout
    if [[ -n "$RALPH_SANDBOX_TIMEOUT" ]]; then
        docker_args+=("--stop-timeout" "$((RALPH_SANDBOX_TIMEOUT * 60))")
    fi

    # Image and command
    docker_args+=("$RALPH_SANDBOX_IMAGE")

    # Ralph loop command inside container
    local ralph_script="/workspace/ralph_loop.sh"
    if [[ -f "$project_dir/ralph_loop.sh" ]]; then
        docker_args+=("bash" "$ralph_script" "--live")
    else
        # Use installed Ralph
        docker_args+=("bash" "-c" "ralph --live")
    fi

    # Trap SIGINT/SIGTERM to stop container
    trap "echo 'Stopping sandbox...'; docker stop $container_name 2>/dev/null; exit 130" INT TERM

    # Run container with stdout/stderr streaming to host
    docker "${docker_args[@]}"
    local exit_code=$?

    # Reset trap
    trap - INT TERM

    # Report
    if [[ $exit_code -eq 0 ]]; then
        echo ""
        echo "Sandbox completed successfully"
    else
        echo ""
        echo "Sandbox exited with code $exit_code"
    fi

    return $exit_code
}

# =============================================================================
# SANDBOXV2-1: Rootless Docker Mode and Network Egress Control
# =============================================================================

# ralph_detect_docker_mode — Detect Docker rootless mode availability
#
# Returns: "rootless" if running in rootless mode,
#          "rootless-available" if rootless is installed but not active,
#          "standard" otherwise.
#
ralph_detect_docker_mode() {
    if ! command -v docker &>/dev/null; then
        echo "standard"
        return 1
    fi

    local docker_info
    docker_info=$(docker info 2>/dev/null) || {
        echo "standard"
        return 1
    }

    # Check if currently running in rootless mode
    # Rootless Docker sets SecurityOptions to include "rootless" and
    # the Docker root dir is typically under the user's home directory
    if echo "$docker_info" | grep -qi "rootless" 2>/dev/null; then
        echo "rootless"
        return 0
    fi

    # Check if rootless Docker binary is available but not the active context
    if command -v dockerd-rootless.sh &>/dev/null || \
       command -v dockerd-rootless-setuptool.sh &>/dev/null; then
        echo "rootless-available"
        return 0
    fi

    echo "standard"
    return 0
}

# ralph_build_sandbox_network_args — Build Docker network arguments based on config
#
# Uses RALPH_SANDBOX_NETWORK: none, host, allowlist
# Uses RALPH_SANDBOX_ALLOWED_HOSTS for allowlist mode
#
# Outputs network args to stdout (space-separated).
#
ralph_build_sandbox_network_args() {
    local network="${RALPH_SANDBOX_NETWORK:-none}"
    local args=()

    case "$network" in
        none)
            args+=("--network" "none")
            ;;
        host)
            args+=("--network" "host")
            ;;
        allowlist)
            # Allowlist mode: use bridge network with DNS but restrict via iptables
            # The container gets bridge networking; host-level iptables rules must
            # restrict egress. We pass allowed hosts as an environment variable
            # so the container entrypoint can configure firewall rules.
            args+=("--network" "bridge")
            if [[ -n "${RALPH_SANDBOX_ALLOWED_HOSTS:-}" ]]; then
                args+=("-e" "RALPH_ALLOWED_HOSTS=${RALPH_SANDBOX_ALLOWED_HOSTS}")
                # Add DNS restriction label for external tooling
                args+=("--label" "ralph.network.allowlist=${RALPH_SANDBOX_ALLOWED_HOSTS}")
            fi
            ;;
        true)
            # Legacy compat: RALPH_SANDBOX_NETWORK=true means bridge (allow network)
            args+=("--network" "bridge")
            ;;
        false)
            # Legacy compat: RALPH_SANDBOX_NETWORK=false means none
            args+=("--network" "none")
            ;;
        *)
            # Treat as a Docker network name
            args+=("--network" "$network")
            ;;
    esac

    echo "${args[@]}"
}

# ralph_build_sandbox_security_args — Build security hardening flags for Docker
#
# Returns Docker CLI flags for:
# - Read-only root filesystem
# - Writable /tmp with noexec,nosuid
# - No new privilege escalation
# - Drop all capabilities except DAC_OVERRIDE
# - PID limit
#
ralph_build_sandbox_security_args() {
    local pids_limit="${RALPH_SANDBOX_PIDS:-256}"
    local args=(
        "--read-only"
        "--tmpfs" "/tmp:rw,noexec,nosuid"
        "--security-opt" "no-new-privileges"
        "--cap-drop" "ALL"
        "--cap-add" "DAC_OVERRIDE"
        "--pids-limit" "$pids_limit"
    )

    echo "${args[@]}"
}

# =============================================================================
# SANDBOXV2-2: Resource Usage Reporting
# =============================================================================

# ralph_capture_sandbox_stats — Capture Docker container resource usage stats
#
# Usage: ralph_capture_sandbox_stats <container_id>
#
# Returns JSON with: cpu_percent, mem_usage, mem_percent, net_io, pids
# Returns empty JSON object on failure.
#
ralph_capture_sandbox_stats() {
    local container_id="${1:?Usage: ralph_capture_sandbox_stats <container_id>}"

    if ! command -v docker &>/dev/null; then
        echo '{}'
        return 1
    fi

    local raw_stats
    raw_stats=$(docker stats --no-stream --format '{{json .}}' "$container_id" 2>/dev/null) || {
        echo '{}'
        return 1
    }

    if [[ -z "$raw_stats" ]]; then
        echo '{}'
        return 1
    fi

    # Parse Docker stats JSON into normalized output
    # Docker stats fields: CPUPerc, MemUsage, MemPerc, NetIO, PIDs
    if command -v jq &>/dev/null; then
        echo "$raw_stats" | jq -c '{
            cpu_percent: (.CPUPerc // "0%" | gsub("%"; "") | tonumber),
            mem_usage: (.MemUsage // "0B / 0B"),
            mem_percent: (.MemPerc // "0%" | gsub("%"; "") | tonumber),
            net_io: (.NetIO // "0B / 0B"),
            pids: (.PIDs // "0" | tonumber)
        }' 2>/dev/null || echo '{}'
    else
        # Fallback: extract fields without jq using basic string parsing
        local cpu mem_usage mem_pct net_io pids
        cpu=$(echo "$raw_stats" | grep -o '"CPUPerc":"[^"]*"' | cut -d'"' -f4 | tr -d '%')
        mem_usage=$(echo "$raw_stats" | grep -o '"MemUsage":"[^"]*"' | cut -d'"' -f4)
        mem_pct=$(echo "$raw_stats" | grep -o '"MemPerc":"[^"]*"' | cut -d'"' -f4 | tr -d '%')
        net_io=$(echo "$raw_stats" | grep -o '"NetIO":"[^"]*"' | cut -d'"' -f4)
        pids=$(echo "$raw_stats" | grep -o '"PIDs":"[^"]*"' | cut -d'"' -f4)

        printf '{"cpu_percent":%s,"mem_usage":"%s","mem_percent":%s,"net_io":"%s","pids":%s}\n' \
            "${cpu:-0}" "${mem_usage:-0B / 0B}" "${mem_pct:-0}" "${net_io:-0B / 0B}" "${pids:-0}"
    fi
}

# ralph_record_sandbox_metrics — Record sandbox stats to JSONL metrics file
#
# Usage: ralph_record_sandbox_metrics <container_id> <loop_count>
#
# Writes to .ralph/metrics/sandbox-YYYY-MM.jsonl
# Tracks peak usage across iterations.
#
ralph_record_sandbox_metrics() {
    local container_id="${1:?Usage: ralph_record_sandbox_metrics <container_id> <loop_count>}"
    local loop_count="${2:-0}"

    local metrics_dir="${RALPH_DIR:-.ralph}/metrics"
    mkdir -p "$metrics_dir"

    local month_file="$metrics_dir/sandbox-$(date '+%Y-%m').jsonl"
    local peak_file="$metrics_dir/.sandbox_peak.json"
    local timestamp
    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    # Capture current stats
    local stats
    stats=$(ralph_capture_sandbox_stats "$container_id")

    if [[ "$stats" == "{}" ]]; then
        return 1
    fi

    # Extract numeric values for peak tracking
    local cpu_pct mem_pct pids_count
    if command -v jq &>/dev/null; then
        cpu_pct=$(echo "$stats" | jq -r '.cpu_percent // 0')
        mem_pct=$(echo "$stats" | jq -r '.mem_percent // 0')
        pids_count=$(echo "$stats" | jq -r '.pids // 0')
    else
        cpu_pct=$(echo "$stats" | grep -o '"cpu_percent":[0-9.]*' | cut -d: -f2)
        mem_pct=$(echo "$stats" | grep -o '"mem_percent":[0-9.]*' | cut -d: -f2)
        pids_count=$(echo "$stats" | grep -o '"pids":[0-9]*' | cut -d: -f2)
        cpu_pct="${cpu_pct:-0}"
        mem_pct="${mem_pct:-0}"
        pids_count="${pids_count:-0}"
    fi

    # Build JSONL record
    local record
    if command -v jq &>/dev/null; then
        record=$(jq -nc \
            --arg ts "$timestamp" \
            --arg cid "$container_id" \
            --argjson loop "$loop_count" \
            --argjson stats "$stats" \
            '{
                timestamp: $ts,
                container_id: $cid,
                loop_count: $loop,
                stats: $stats
            }')
    else
        record=$(printf '{"timestamp":"%s","container_id":"%s","loop_count":%s,"stats":%s}' \
            "$timestamp" "$container_id" "$loop_count" "$stats")
    fi

    echo "$record" >> "$month_file"

    # Update peak usage tracking
    if command -v jq &>/dev/null; then
        local peak_cpu=0 peak_mem=0 peak_pids=0 peak_iterations=0
        if [[ -f "$peak_file" ]]; then
            peak_cpu=$(jq -r '.peak_cpu_percent // 0' "$peak_file" 2>/dev/null)
            peak_mem=$(jq -r '.peak_mem_percent // 0' "$peak_file" 2>/dev/null)
            peak_pids=$(jq -r '.peak_pids // 0' "$peak_file" 2>/dev/null)
            peak_iterations=$(jq -r '.total_iterations // 0' "$peak_file" 2>/dev/null)
        fi

        peak_iterations=$((peak_iterations + 1))

        # Update peaks using awk for float comparison
        peak_cpu=$(awk -v a="$cpu_pct" -v b="$peak_cpu" 'BEGIN{print (a>b)?a:b}')
        peak_mem=$(awk -v a="$mem_pct" -v b="$peak_mem" 'BEGIN{print (a>b)?a:b}')
        peak_pids=$(awk -v a="$pids_count" -v b="$peak_pids" 'BEGIN{print (a>b)?a:b}')

        # Atomic write: write to temp then move
        local tmp_peak="${peak_file}.tmp.$$"
        jq -nc \
            --argjson pcpu "$peak_cpu" \
            --argjson pmem "$peak_mem" \
            --argjson ppids "$peak_pids" \
            --argjson iters "$peak_iterations" \
            --arg updated "$timestamp" \
            '{
                peak_cpu_percent: $pcpu,
                peak_mem_percent: $pmem,
                peak_pids: $ppids,
                total_iterations: $iters,
                last_updated: $updated
            }' > "$tmp_peak" && mv "$tmp_peak" "$peak_file"
        rm -f "$tmp_peak"
    fi

    return 0
}

# ralph_sandbox_capacity_summary — Display peak resource usage summary
#
# Usage: ralph_sandbox_capacity_summary [--json]
#
ralph_sandbox_capacity_summary() {
    local format="human"
    [[ "${1:-}" == "--json" ]] && format="json"

    local peak_file="${RALPH_DIR:-.ralph}/metrics/.sandbox_peak.json"

    if [[ ! -f "$peak_file" ]]; then
        if [[ "$format" == "json" ]]; then
            echo '{"error":"No sandbox metrics data found"}'
        else
            echo "No sandbox metrics data found. Run Ralph in sandbox mode to generate metrics."
        fi
        return 0
    fi

    if ! command -v jq &>/dev/null; then
        echo "Error: jq required for capacity summary"
        return 1
    fi

    if [[ "$format" == "json" ]]; then
        cat "$peak_file"
    else
        local peak_cpu peak_mem peak_pids iterations updated
        peak_cpu=$(jq -r '.peak_cpu_percent // 0' "$peak_file")
        peak_mem=$(jq -r '.peak_mem_percent // 0' "$peak_file")
        peak_pids=$(jq -r '.peak_pids // 0' "$peak_file")
        iterations=$(jq -r '.total_iterations // 0' "$peak_file")
        updated=$(jq -r '.last_updated // "unknown"' "$peak_file")

        echo "Sandbox Capacity Summary"
        echo "========================"
        echo "  Peak CPU usage:    ${peak_cpu}%"
        echo "  Peak memory usage: ${peak_mem}%"
        echo "  Peak PIDs:         ${peak_pids}"
        echo "  Total iterations:  ${iterations}"
        echo "  Last updated:      ${updated}"
        echo ""
        echo "Configured limits:"
        echo "  CPUs:    ${RALPH_SANDBOX_CPUS}"
        echo "  Memory:  ${RALPH_SANDBOX_MEMORY}"
        echo "  PIDs:    ${RALPH_SANDBOX_PIDS}"
    fi
}

# =============================================================================
# SANDBOXV2-3: gVisor Runtime Support
# =============================================================================

# ralph_detect_gvisor — Check if gVisor (runsc) runtime is available
#
# Returns 0 if gVisor is available, 1 otherwise.
# Checks docker info for the runsc runtime.
#
ralph_detect_gvisor() {
    if ! command -v docker &>/dev/null; then
        return 1
    fi

    local docker_info
    docker_info=$(docker info 2>/dev/null) || return 1

    # Check if runsc runtime is registered in Docker
    # docker info shows "Runtimes:" section listing available runtimes
    if echo "$docker_info" | grep -qi "runsc" 2>/dev/null; then
        return 0
    fi

    # Also check via docker info --format for more reliable parsing
    local runtimes
    runtimes=$(docker info --format '{{json .Runtimes}}' 2>/dev/null) || true
    if echo "$runtimes" | grep -qi "runsc" 2>/dev/null; then
        return 0
    fi

    return 1
}

# ralph_get_runtime_args — Get Docker runtime arguments based on configuration
#
# Uses RALPH_SANDBOX_RUNTIME: auto, gvisor, docker
# In auto mode, uses gVisor if detected, otherwise standard Docker.
#
# Outputs runtime args to stdout (empty string if standard Docker).
#
ralph_get_runtime_args() {
    local runtime="${RALPH_SANDBOX_RUNTIME:-auto}"
    local args=""

    case "$runtime" in
        gvisor)
            if ralph_detect_gvisor; then
                args="--runtime=runsc"
                echo "  Runtime: gVisor (runsc) [configured]" >&2
            else
                echo "Warning: gVisor requested but runsc not found, falling back to standard Docker" >&2
            fi
            ;;
        auto)
            if ralph_detect_gvisor; then
                args="--runtime=runsc"
                echo "  Runtime: gVisor (runsc) [auto-detected]" >&2
            else
                echo "  Runtime: Docker (standard)" >&2
            fi
            ;;
        docker)
            echo "  Runtime: Docker (standard) [configured]" >&2
            ;;
        *)
            # Treat as a custom runtime name
            args="--runtime=$runtime"
            echo "  Runtime: $runtime [custom]" >&2
            ;;
    esac

    echo "$args"
}

# =============================================================================
# Integration: Updated sandbox launch with V2 features
# =============================================================================

# ralph_sandbox_run_v2 — Enhanced sandbox run with V2 security, metrics, and gVisor
#
# Wraps the original ralph_sandbox_run with SANDBOXV2 features.
# Uses new network, security, resource, and runtime configurations.
#
ralph_sandbox_run_v2() {
    local ralph_dir="${RALPH_DIR:-.ralph}"
    local project_dir="$(pwd)"
    local container_name="ralph-sandbox-$$"

    # Pre-flight checks
    if ! sandbox_available; then
        if [[ "${RALPH_SANDBOX_REQUIRED}" == "true" ]]; then
            echo "Error: Docker required but not available (RALPH_SANDBOX_REQUIRED=true)"
            return 1
        else
            echo "Warning: Docker not available, falling back to host execution"
            return 2
        fi
    fi

    # Detect Docker mode
    local docker_mode
    docker_mode=$(ralph_detect_docker_mode)
    echo "  Docker mode: $docker_mode"

    # Dry run check
    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        echo "Sandbox dry-run (V2): Docker $(docker --version 2>/dev/null || echo 'not available')"
        echo "  Docker mode: $docker_mode"
        echo "  Image: $RALPH_SANDBOX_IMAGE"
        echo "  CPUs: $RALPH_SANDBOX_CPUS"
        echo "  Memory: $RALPH_SANDBOX_MEMORY"
        echo "  PIDs limit: $RALPH_SANDBOX_PIDS"
        echo "  Network: $RALPH_SANDBOX_NETWORK"
        echo "  Allowed hosts: ${RALPH_SANDBOX_ALLOWED_HOSTS:-<none>}"
        echo "  Runtime: $RALPH_SANDBOX_RUNTIME"
        echo "  Security: read-only, no-new-privileges, cap-drop ALL, cap-add DAC_OVERRIDE"
        ralph_get_runtime_args >/dev/null
        return 0
    fi

    # Ensure image exists
    if ! docker image inspect "$RALPH_SANDBOX_IMAGE" &>/dev/null; then
        echo "Building sandbox image..."
        sandbox_create || {
            echo "Error: Failed to build sandbox image"
            return 1
        }
    fi

    echo "Starting Ralph in Docker sandbox (V2)..."
    echo "  Container: $container_name"
    echo "  CPUs: $RALPH_SANDBOX_CPUS"
    echo "  Memory: $RALPH_SANDBOX_MEMORY"
    echo "  PIDs limit: $RALPH_SANDBOX_PIDS"
    echo "  Network: $RALPH_SANDBOX_NETWORK"

    # Build docker run command with V2 features
    local docker_args=(
        "run"
        "--name" "$container_name"
        "--rm"
        "--cpus" "$RALPH_SANDBOX_CPUS"
        "--memory" "$RALPH_SANDBOX_MEMORY"
        # Mount project at /workspace
        "-v" "$project_dir:/workspace"
        # Mount .claude/ read-only
        "-v" "$project_dir/.claude:/workspace/.claude:ro"
        # Pass API key
        "-e" "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}"
        # Working directory
        "-w" "/workspace"
    )

    # SANDBOXV2-1: Network args
    local network_args
    network_args=$(ralph_build_sandbox_network_args)
    if [[ -n "$network_args" ]]; then
        # shellcheck disable=SC2206
        docker_args+=($network_args)
    fi

    # SANDBOXV2-1: Security hardening args
    local security_args
    security_args=$(ralph_build_sandbox_security_args)
    if [[ -n "$security_args" ]]; then
        # shellcheck disable=SC2206
        docker_args+=($security_args)
    fi

    # SANDBOXV2-3: Runtime args (gVisor support)
    local runtime_args
    runtime_args=$(ralph_get_runtime_args)
    if [[ -n "$runtime_args" ]]; then
        # shellcheck disable=SC2206
        docker_args+=($runtime_args)
    fi

    # Timeout
    if [[ -n "$RALPH_SANDBOX_TIMEOUT" ]]; then
        docker_args+=("--stop-timeout" "$((RALPH_SANDBOX_TIMEOUT * 60))")
    fi

    # Image and command
    docker_args+=("$RALPH_SANDBOX_IMAGE")

    # Ralph loop command inside container
    local ralph_script="/workspace/ralph_loop.sh"
    if [[ -f "$project_dir/ralph_loop.sh" ]]; then
        docker_args+=("bash" "$ralph_script" "--live")
    else
        docker_args+=("bash" "-c" "ralph --live")
    fi

    # Trap SIGINT/SIGTERM to stop container
    trap "echo 'Stopping sandbox...'; docker stop $container_name 2>/dev/null; exit 130" INT TERM

    # Run container with stdout/stderr streaming to host
    docker "${docker_args[@]}" &
    local docker_pid=$!

    # SANDBOXV2-2: Background stats collection (every 30 seconds)
    local stats_loop_active=true
    (
        local loop_iter=0
        while $stats_loop_active && kill -0 $docker_pid 2>/dev/null; do
            sleep 30
            if kill -0 $docker_pid 2>/dev/null; then
                ralph_record_sandbox_metrics "$container_name" "$loop_iter" 2>/dev/null || true
                loop_iter=$((loop_iter + 1))
            fi
        done
    ) &
    local stats_pid=$!

    # Wait for Docker to finish
    wait $docker_pid
    local exit_code=$?

    # Stop stats collection
    stats_loop_active=false
    kill $stats_pid 2>/dev/null || true
    wait $stats_pid 2>/dev/null || true

    # Final stats capture
    ralph_record_sandbox_metrics "$container_name" "final" 2>/dev/null || true

    # Reset trap
    trap - INT TERM

    # Report
    if [[ $exit_code -eq 0 ]]; then
        echo ""
        echo "Sandbox (V2) completed successfully"
    else
        echo ""
        echo "Sandbox (V2) exited with code $exit_code"
    fi

    return $exit_code
}

# =============================================================================
# Exports
# =============================================================================

# Phase 11 (SANDBOX) exports
export -f sandbox_available 2>/dev/null || true
export -f sandbox_create 2>/dev/null || true
export -f sandbox_status 2>/dev/null || true
export -f sandbox_logs 2>/dev/null || true
export -f sandbox_stop 2>/dev/null || true
export -f sandbox_cleanup 2>/dev/null || true
export -f ralph_sandbox_run 2>/dev/null || true

# SANDBOXV2-1: Rootless Docker Mode and Network Egress Control
export -f ralph_detect_docker_mode 2>/dev/null || true
export -f ralph_build_sandbox_network_args 2>/dev/null || true
export -f ralph_build_sandbox_security_args 2>/dev/null || true

# SANDBOXV2-2: Resource Usage Reporting
export -f ralph_capture_sandbox_stats 2>/dev/null || true
export -f ralph_record_sandbox_metrics 2>/dev/null || true
export -f ralph_sandbox_capacity_summary 2>/dev/null || true

# SANDBOXV2-3: gVisor Runtime Support
export -f ralph_detect_gvisor 2>/dev/null || true
export -f ralph_get_runtime_args 2>/dev/null || true

# V2 integrated runner
export -f ralph_sandbox_run_v2 2>/dev/null || true
