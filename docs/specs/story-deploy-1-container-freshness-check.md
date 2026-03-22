# Story DEPLOY-1: Container Freshness Check Before Integration Tests

**Epic:** [Pre-QA Environment Verification](epic-pre-qa-deployment.md)
**Priority:** High
**Status:** Pending
**Effort:** Small
**Component:** `.claude/agents/ralph-tester.md`, `ralph_loop.sh`

---

## Problem

Ralph runs pytest (including integration/e2e tests) against Docker containers that haven't been rebuilt in over a day. The code changes made during implementation are not reflected in the running containers, so test results are meaningless.

**Evidence:** TheStudio 2026-03-22 — Docker Desktop shows all containers "Last started: 1 day ago" while Ralph had just completed 28 implementation tasks and was running QA.

## Solution

Add a container freshness check that runs before integration/e2e tests. If containers are stale (started before the latest code change), either rebuild them or skip integration tests and report the staleness.

## Implementation

### Step 1: Add freshness check function

```bash
# In ralph_loop.sh or a new lib/deploy.sh:

DEPLOY_COMMAND="${DEPLOY_COMMAND:-}"  # e.g., "docker compose up --build -d"
DEPLOY_HEALTH_TIMEOUT="${DEPLOY_HEALTH_TIMEOUT:-120}"  # seconds to wait for healthy

ralph_check_container_freshness() {
    local project_dir="$1"

    # Skip if no docker-compose file exists
    local compose_file=""
    for f in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
        if [[ -f "$project_dir/$f" ]]; then
            compose_file="$project_dir/$f"
            break
        fi
    done
    [[ -z "$compose_file" ]] && return 0  # Not a Docker project

    # Get most recent code change timestamp
    local last_code_change
    last_code_change=$(cd "$project_dir" && git log -1 --format=%ct -- src/ lib/ app/ 2>/dev/null || echo "0")
    [[ "$last_code_change" == "0" ]] && return 0  # No git history

    # Get oldest running container start time
    local container_names
    container_names=$(cd "$project_dir" && docker compose ps --format '{{.Name}}' 2>/dev/null)
    [[ -z "$container_names" ]] && return 0  # No running containers

    local oldest_start=999999999999
    while IFS= read -r container; do
        local start_epoch
        start_epoch=$(docker inspect --format='{{.State.StartedAt}}' "$container" 2>/dev/null \
            | xargs -I{} date -d {} +%s 2>/dev/null || echo "0")
        [[ "$start_epoch" -lt "$oldest_start" ]] && oldest_start=$start_epoch
    done <<< "$container_names"

    if [[ "$last_code_change" -gt "$oldest_start" ]]; then
        local age_hours=$(( ($(date +%s) - oldest_start) / 3600 ))
        log "WARN" "Docker containers are stale (started ${age_hours}h ago, code changed since)"
        log "WARN" "Integration/e2e tests may not reflect current code"

        if [[ -n "$DEPLOY_COMMAND" ]]; then
            log "INFO" "Running deploy command: $DEPLOY_COMMAND"
            if (cd "$project_dir" && eval "$DEPLOY_COMMAND"); then
                log "SUCCESS" "Containers rebuilt successfully"
                # Wait for health checks
                sleep 5
                return 0
            else
                log "ERROR" "Deploy command failed — skipping integration tests"
                return 1
            fi
        else
            log "WARN" "No DEPLOY_COMMAND configured in .ralphrc — cannot auto-rebuild"
            log "WARN" "Set DEPLOY_COMMAND='docker compose up --build -d' in .ralphrc"
            return 1  # Signal that integration tests should be skipped
        fi
    fi

    return 0  # Containers are fresh
}
```

### Step 2: Add .ralphrc configuration

```bash
# In .ralphrc template:
# DEPLOY_COMMAND=""                    # Command to rebuild/restart containers (e.g., "docker compose up --build -d")
# DEPLOY_HEALTH_TIMEOUT=120           # Seconds to wait for containers to be healthy after deploy
# DEPLOY_AUTO_REBUILD=false            # Auto-rebuild stale containers before integration tests
# DEPLOY_SOURCE_DIRS="src/ lib/ app/"  # Directories to check for code changes (space-separated)
```

### Step 3: Integrate with QA phase

```bash
# Before spawning ralph-tester for integration/e2e tests:
if ! ralph_check_container_freshness "$PROJECT_DIR"; then
    log "WARN" "Skipping integration/e2e tests — containers are stale"
    log "INFO" "Running unit tests and static analysis only"
    # Modify QA scope to unit-only
    QA_SCOPE="unit-only"
fi
```

### Step 4: Pass scope to ralph-tester agent

Update the ralph-tester agent spawn to include scope information:

```bash
# When spawning ralph-tester:
if [[ "$QA_SCOPE" == "unit-only" ]]; then
    TESTER_PROMPT="Run unit tests only (NOT integration/e2e). Containers are stale — integration tests would be invalid. Run: pytest tests/unit/ -q --tb=short"
else
    TESTER_PROMPT="Run full QA suite including integration tests."
fi
```

## Design Notes

- **Docker Compose detection**: Check for `docker-compose.yml`, `docker-compose.yaml`, `compose.yml`, `compose.yaml` (all valid filenames per Docker docs).
- **Source directory heuristic**: `src/`, `lib/`, `app/` cover most project layouts. Configurable via `DEPLOY_SOURCE_DIRS`.
- **Stale = code changed after container started**: This is the CI/CD standard definition. If `git log -1 --format=%ct -- src/` is after `docker inspect .State.StartedAt`, containers need rebuild.
- **Unit tests still run**: Even when containers are stale, unit tests and static analysis (ruff, mypy) are valid — they don't depend on running containers.
- **DEPLOY_COMMAND flexibility**: Supports any rebuild command: `docker compose up --build -d`, `make deploy`, `./scripts/deploy.sh`, etc.
- **Not blocking by default**: When no DEPLOY_COMMAND is configured, Ralph warns and skips integration tests rather than failing entirely. This preserves backward compatibility.

## Acceptance Criteria

- [ ] Detects Docker Compose projects automatically
- [ ] Compares container start time against latest code change
- [ ] Warns when containers are stale with age in hours
- [ ] Auto-rebuilds when `DEPLOY_COMMAND` and `DEPLOY_AUTO_REBUILD=true` are set
- [ ] Skips integration/e2e tests (not unit tests) when containers are stale and can't rebuild
- [ ] Works with standard Docker Compose file names
- [ ] Gracefully skips check for non-Docker projects

## Test Plan

```bash
@test "ralph_check_container_freshness skips non-Docker projects" {
    source "$RALPH_DIR/ralph_loop.sh"
    # No docker-compose.yml in test dir
    run ralph_check_container_freshness "$TEST_DIR"
    assert_success  # Returns 0 — no check needed
}

@test "ralph_check_container_freshness detects compose file" {
    source "$RALPH_DIR/ralph_loop.sh"
    touch "$TEST_DIR/docker-compose.yml"

    # Mock git and docker commands for this test
    # ...
}

@test "ralph_check_container_freshness warns on stale containers" {
    source "$RALPH_DIR/ralph_loop.sh"
    touch "$TEST_DIR/docker-compose.yml"

    # Mock: code changed 1 hour ago, container started 25 hours ago
    git() { echo "$(( $(date +%s) - 3600 ))"; }
    docker() {
        if [[ "$1" == "compose" ]]; then echo "app-1"; fi
        if [[ "$1" == "inspect" ]]; then echo "2026-03-21T00:00:00Z"; fi
    }

    run ralph_check_container_freshness "$TEST_DIR"
    assert_failure  # Stale containers detected
}
```

## References

- [Docker Compose Watch — Auto-rebuild](https://docs.docker.com/compose/how-tos/file-watch/)
- [GitHub Actions — Deploy then Test Pattern](https://docs.github.com/en/actions/using-workflows/events-that-trigger-workflows)
- [docker inspect — Container State](https://docs.docker.com/reference/cli/docker/inspect/)
- [GitLab CI Stages — Build, Deploy, Test](https://docs.gitlab.com/ee/ci/yaml/#stages)
