# Story SANDBOX-1: Sandbox Interface and Docker Integration

**Epic:** [RALPH-SANDBOX](epic-docker-sandbox.md)
**Priority:** Medium
**Status:** Open
**Effort:** Large
**Component:** new `lib/sandbox.sh`, new `docker/ralph-sandbox/Dockerfile`

---

## Problem

Ralph executes directly on the host filesystem with no isolation boundary. For shared infrastructure, CI environments, or elevated-trust autonomous runs, true container isolation is needed. Before building the execution runner (SANDBOX-2), we need:
1. A Docker image with all Ralph dependencies
2. A simple interface for managing container lifecycle
3. Configuration for resource limits

## Solution

Create a Ralph sandbox Docker image and a `lib/sandbox.sh` module that provides functions for creating, starting, stopping, and cleaning up sandbox containers.

## Implementation

### 1. Docker Image (`docker/ralph-sandbox/Dockerfile`)
```dockerfile
FROM ubuntu:24.04

# System dependencies
RUN apt-get update && apt-get install -y \
    bash curl git jq tmux \
    nodejs npm python3 python3-pip python3-venv \
    && rm -rf /var/lib/apt/lists/*

# Claude Code CLI
RUN npm install -g @anthropic-ai/claude-code

# Ralph
COPY ralph_loop.sh /usr/local/bin/ralph
COPY lib/ /usr/local/lib/ralph/
COPY .claude/ /usr/local/share/ralph/.claude/

# Working directory
WORKDIR /workspace

# Entrypoint
ENTRYPOINT ["/usr/local/bin/ralph"]
```

### 2. Sandbox Interface (`lib/sandbox.sh`)
```bash
sandbox_create() {
  local project_dir="$1"
  local container_name="ralph-sandbox-$$"

  # Resource limits from config
  local cpu_limit="${RALPH_SANDBOX_CPUS:-2}"
  local mem_limit="${RALPH_SANDBOX_MEMORY:-4g}"
  local timeout="${RALPH_SANDBOX_TIMEOUT:-3600}"  # 1 hour default

  docker run -d \
    --name "$container_name" \
    --cpus="$cpu_limit" \
    --memory="$mem_limit" \
    --stop-timeout "$timeout" \
    -v "$project_dir:/workspace" \
    -v "$HOME/.claude:/root/.claude:ro" \
    -e "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}" \
    ralph-sandbox:latest \
    --project /workspace "$@"

  echo "$container_name"
}

sandbox_status() {
  local container_name="$1"
  docker inspect "$container_name" --format '{{.State.Status}}' 2>/dev/null
}

sandbox_logs() {
  local container_name="$1"
  docker logs --tail 50 "$container_name" 2>/dev/null
}

sandbox_stop() {
  local container_name="$1"
  docker stop "$container_name" 2>/dev/null
  docker rm "$container_name" 2>/dev/null
}

sandbox_cleanup() {
  # Remove all stopped ralph-sandbox containers
  docker ps -a --filter "name=ralph-sandbox-" --filter "status=exited" -q | \
    xargs -r docker rm
}

sandbox_available() {
  command -v docker &>/dev/null && docker info &>/dev/null
}
```

### 3. Configuration
```bash
RALPH_SANDBOX_CPUS="2"           # CPU limit
RALPH_SANDBOX_MEMORY="4g"        # Memory limit
RALPH_SANDBOX_TIMEOUT="3600"     # Container timeout (seconds)
RALPH_SANDBOX_IMAGE="ralph-sandbox:latest"  # Custom image
RALPH_SANDBOX_NETWORK="none"     # Network mode (none, bridge, host)
```

### Key Design Decisions

1. **Volume mount, not copy:** Project files are bind-mounted into the container. Changes are immediately visible on the host. No sync complexity needed for standalone Ralph.
2. **Read-only Claude config:** `.claude/` is mounted read-only to prevent the sandbox from modifying agent definitions or hooks.
3. **API key via env var:** The Anthropic API key is passed as an environment variable, not baked into the image.
4. **Network default "none":** Maximum isolation by default. Users can override for projects that need network access.
5. **Container naming:** `ralph-sandbox-$$` uses PID to avoid name collisions across concurrent runs.

## Testing

```bash
@test "sandbox_available detects Docker" {
  source lib/sandbox.sh
  if command -v docker &>/dev/null; then
    sandbox_available
  else
    run sandbox_available
    [ "$status" -ne 0 ]
  fi
}

@test "sandbox_create returns container name" {
  skip_if_no_docker
  source lib/sandbox.sh
  container=$(sandbox_create "$TEST_PROJECT" --dry-run)
  [[ "$container" == ralph-sandbox-* ]]
  sandbox_stop "$container"
}

@test "sandbox_stop cleans up container" {
  skip_if_no_docker
  source lib/sandbox.sh
  container=$(sandbox_create "$TEST_PROJECT" --dry-run)
  sandbox_stop "$container"
  run docker inspect "$container"
  [ "$status" -ne 0 ]
}

@test "sandbox respects resource limits" {
  skip_if_no_docker
  source lib/sandbox.sh
  RALPH_SANDBOX_CPUS=1 RALPH_SANDBOX_MEMORY=512m \
    container=$(sandbox_create "$TEST_PROJECT" --dry-run)
  cpus=$(docker inspect "$container" --format '{{.HostConfig.NanoCpus}}')
  [ "$cpus" -eq 1000000000 ]  # 1 CPU in nanocpus
  sandbox_stop "$container"
}

@test "Docker image builds successfully" {
  skip_if_no_docker
  run docker build -t ralph-sandbox:test docker/ralph-sandbox/
  [ "$status" -eq 0 ]
}
```

## Acceptance Criteria

- [ ] Docker image builds with all Ralph dependencies
- [ ] `sandbox_create` starts a container with project mounted at /workspace
- [ ] Resource limits (CPU, memory, timeout) are configurable
- [ ] `sandbox_stop` removes the container cleanly
- [ ] `sandbox_cleanup` removes all stopped Ralph containers
- [ ] `sandbox_available` detects Docker availability
- [ ] API key passed via environment variable (not in image)
- [ ] `.claude/` mounted read-only
- [ ] Network isolation configurable (default: none)
