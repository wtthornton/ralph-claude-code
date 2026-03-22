# Story SANDBOXV2-2: Resource Usage Reporting

**Epic:** [Sandbox Hardening](epic-sandbox-hardening.md)
**Priority:** Medium
**Status:** Open
**Effort:** Small
**Component:** `lib/sandbox.sh`, `lib/metrics.sh`

---

## Problem

Ralph limits CPU and memory via Docker flags but doesn't report actual usage. Operators can't identify which tasks are resource-hungry or optimize container sizing.

## Solution

Capture Docker stats after each sandboxed iteration and include resource usage in metrics and trace records.

## Implementation

```bash
ralph_capture_sandbox_stats() {
    local container_id="$1"
    docker stats --no-stream --format '{{json .}}' "$container_id" 2>/dev/null | \
        jq -c '{
            cpu_percent: .CPUPerc,
            mem_usage: .MemUsage,
            mem_percent: .MemPerc,
            net_io: .NetIO,
            pids: .PIDs
        }'
}
```

## Acceptance Criteria

- [ ] CPU and memory usage captured per sandboxed iteration
- [ ] Resource stats included in OTel trace (if OTEL enabled)
- [ ] Resource stats included in `ralph --stats` output
- [ ] Peak usage highlighted for capacity planning

## References

- [Docker — Container Stats](https://docs.docker.com/reference/cli/docker/container/stats/)
