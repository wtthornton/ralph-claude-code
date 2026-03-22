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
RALPH_SANDBOX_NETWORK="${RALPH_SANDBOX_NETWORK:-true}"
RALPH_SANDBOX_REQUIRED="${RALPH_SANDBOX_REQUIRED:-false}"

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
