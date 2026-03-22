# Story SANDBOXV2-3: gVisor Runtime Support

**Epic:** [Sandbox Hardening](epic-sandbox-hardening.md)
**Priority:** Low
**Status:** Open
**Effort:** Medium
**Component:** `lib/sandbox.sh`

---

## Problem

Standard Docker containers share the host kernel. Kernel vulnerabilities can allow container escape. For production and fleet environments, stronger isolation is needed.

## Solution

Support gVisor (`runsc`) as an optional container runtime. gVisor provides a user-space kernel that intercepts system calls via a "Sentry" process, providing kernel-level isolation without the overhead of full VMs.

## Implementation

```bash
ralph_detect_gvisor() {
    if docker info 2>/dev/null | grep -q "runsc"; then
        return 0  # gVisor available
    fi
    return 1
}

ralph_get_runtime_args() {
    if [[ "${RALPH_SANDBOX_RUNTIME:-auto}" == "auto" ]]; then
        if ralph_detect_gvisor; then
            echo "--runtime=runsc"
            log "INFO" "Sandbox: using gVisor (runsc) runtime"
        else
            echo ""
            log "DEBUG" "Sandbox: using default Docker runtime"
        fi
    elif [[ "$RALPH_SANDBOX_RUNTIME" == "gvisor" ]]; then
        echo "--runtime=runsc"
    else
        echo ""
    fi
}
```

## Design Notes

- **Auto-detection**: If gVisor is installed, use it automatically. No manual configuration needed.
- **10-30% I/O overhead**: gVisor adds overhead to filesystem and network I/O. Compute overhead is minimal. Acceptable for Ralph's workload.
- **GKE native**: Google GKE offers Agent Sandbox powered by gVisor out of the box.
- **Fallback**: If gVisor is requested but unavailable, warn and use default runtime.

## Acceptance Criteria

- [ ] gVisor runtime auto-detected when available
- [ ] `--runtime=runsc` passed to Docker when gVisor detected
- [ ] Fallback to default runtime with warning when gVisor unavailable
- [ ] `RALPH_SANDBOX_RUNTIME=gvisor|docker|auto` configurable

## References

- [gVisor — Container Sandbox](https://gvisor.dev/)
- [Google GKE — Agent Sandbox](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/agent-sandbox)
- [Northflank — Best Code Execution Sandbox](https://northflank.com/blog/best-code-execution-sandbox-for-ai-agents)
