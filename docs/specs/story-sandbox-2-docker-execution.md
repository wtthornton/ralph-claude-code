# Story SANDBOX-2: Docker Sandbox Execution Runner

**Epic:** [RALPH-SANDBOX](epic-docker-sandbox.md)
**Priority:** Medium
**Status:** Open
**Effort:** Medium
**Component:** `ralph_loop.sh`, `lib/sandbox.sh`

---

## Problem

SANDBOX-1 provides the Docker image and container lifecycle functions. This story connects them to Ralph's main loop so that `ralph --sandbox` actually runs the autonomous loop inside a container, with output and state propagating back to the host.

## Solution

Add a `--sandbox` flag to Ralph that delegates execution to a Docker container. The host-side Ralph process manages the container lifecycle, monitors health, and collects results.

## Implementation

1. Add sandbox execution path to `ralph_loop.sh`:
   ```bash
   if [ "$RALPH_SANDBOX" = "true" ]; then
     source lib/sandbox.sh

     # Pre-flight check
     if ! sandbox_available; then
       echo "ERROR: Docker not available. Run without --sandbox or install Docker."
       exit 1
     fi

     # Build image if needed
     if ! docker image inspect "$RALPH_SANDBOX_IMAGE" &>/dev/null; then
       echo "Building Ralph sandbox image..."
       docker build -t "$RALPH_SANDBOX_IMAGE" docker/ralph-sandbox/
     fi

     # Start container
     container=$(sandbox_create "$PROJECT_DIR" "${RALPH_ARGS[@]}")
     echo "Started sandbox container: $container"

     # Monitor container
     trap "sandbox_stop $container" EXIT INT TERM

     # Stream logs to terminal
     docker logs -f "$container" &
     LOG_PID=$!

     # Wait for container to finish
     exit_code=$(docker wait "$container")

     # Cleanup
     kill $LOG_PID 2>/dev/null
     sandbox_stop "$container"

     exit $exit_code
   fi
   ```

2. Add `--sandbox` flag parsing:
   ```bash
   --sandbox) RALPH_SANDBOX=true; shift ;;
   ```

3. Add `--sandbox --dry-run` validation:
   ```bash
   if [ "$RALPH_SANDBOX" = "true" ] && [ "$DRY_RUN" = "true" ]; then
     echo "Sandbox dry-run: checking Docker availability and image..."
     sandbox_available && echo "Docker: OK" || echo "Docker: NOT AVAILABLE"
     docker image inspect "$RALPH_SANDBOX_IMAGE" &>/dev/null && echo "Image: OK" || echo "Image: NOT BUILT"
     exit 0
   fi
   ```

4. Host-side health monitoring:
   ```bash
   monitor_sandbox() {
     local container="$1"
     local check_interval=30

     while docker inspect "$container" --format '{{.State.Running}}' 2>/dev/null | grep -q true; do
       # Check for stale status
       if [ -f "$PROJECT_DIR/.ralph/status.json" ]; then
         check_status_staleness "$PROJECT_DIR/.ralph/status.json" 300
       fi

       # Check resource usage
       docker stats --no-stream --format '{{.CPUPerc}} {{.MemUsage}}' "$container"

       sleep $check_interval
     done
   }
   ```

5. Fallback behavior when Docker is unavailable:
   ```bash
   if [ "$RALPH_SANDBOX" = "true" ] && ! sandbox_available; then
     if [ "$RALPH_SANDBOX_REQUIRED" = "true" ]; then
       echo "ERROR: Sandbox required but Docker not available"
       exit 1
     else
       echo "WARNING: Docker not available, falling back to host execution"
       RALPH_SANDBOX=false
     fi
   fi
   ```

### Key Design Decisions

1. **Host monitors container:** The host-side Ralph process stays alive to monitor the container, handle signals (Ctrl+C), and clean up. It's not fire-and-forget.
2. **Log streaming:** Container stdout/stderr streams to the host terminal in real-time. Users see the same output as non-sandbox mode.
3. **Graceful fallback:** By default, missing Docker falls back to host execution with a warning. `RALPH_SANDBOX_REQUIRED=true` makes it strict.
4. **Status via volume mount:** Because the project is bind-mounted, status.json and fix_plan.md updates are immediately visible on the host. No special sync needed.
5. **Signal forwarding:** SIGINT/SIGTERM on the host process stops the container. No orphaned containers.

## Testing

```bash
@test "ralph --sandbox starts Docker container" {
  skip_if_no_docker
  run ralph --sandbox --project "$TEST_PROJECT" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Docker: OK"* ]]
}

@test "ralph --sandbox falls back without Docker" {
  export PATH="/usr/bin"  # Remove docker from PATH
  run ralph --sandbox --project "$TEST_PROJECT" --dry-run
  [[ "$output" == *"Docker not available"* ]]
}

@test "ralph --sandbox --required fails without Docker" {
  export PATH="/usr/bin"
  export RALPH_SANDBOX_REQUIRED=true
  run ralph --sandbox --project "$TEST_PROJECT"
  [ "$status" -ne 0 ]
}

@test "sandbox container is cleaned up on exit" {
  skip_if_no_docker
  container=$(sandbox_create "$TEST_PROJECT" --dry-run)
  # Simulate SIGINT
  sandbox_stop "$container"
  run docker inspect "$container"
  [ "$status" -ne 0 ]
}

@test "sandbox status.json visible on host" {
  skip_if_no_docker
  container=$(sandbox_create "$TEST_PROJECT" --dry-run)
  # Container writes status.json to /workspace/.ralph/
  sleep 2
  [ -f "$TEST_PROJECT/.ralph/status.json" ]
  sandbox_stop "$container"
}
```

## Acceptance Criteria

- [ ] `ralph --sandbox` runs the loop inside a Docker container
- [ ] Container stdout/stderr streams to host terminal
- [ ] Ctrl+C on host stops the container cleanly
- [ ] Container cleaned up on exit (no orphans)
- [ ] status.json and fix_plan.md updates visible on host via bind mount
- [ ] `--sandbox --dry-run` validates Docker availability and image
- [ ] Graceful fallback to host execution when Docker unavailable (default)
- [ ] Strict mode via `RALPH_SANDBOX_REQUIRED=true`
- [ ] Health monitoring reports CPU/memory usage periodically
- [ ] Exit code from container propagated to host process
