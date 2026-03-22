# Story XPLAT-2: Cross-Platform Hook Environment Detection

**Epic:** [Cross-Platform Compatibility](epic-cross-platform-compatibility.md)
**Priority:** Medium
**Status:** Pending
**Effort:** Small
**Component:** `.claude/settings.json`, `.ralph/hooks/on-session-start.sh`

---

## Problem

The SessionStart hook tries to run `powershell` but fails in WSL with:
```
/bin/sh: 1: powershell: not found
exit_code: 127
```

This occurs in **every single Claude session** (48+ times in the last 12 hours on TheStudio alone). While not fatal (execution continues), it:
1. Adds noise to logs
2. Triggers error-counting logic that may contribute to circuit breaker state
3. Indicates a misconfigured hook

**Root cause confirmed by:** TheStudio logs 2026-03-22, every `claude_output_*.log` file.

## Solution

Add platform detection to hook scripts so they use the correct command for the execution environment. Additionally, validate hook executability once at startup and suppress repeated failures.

## Implementation

### Step 1: Add platform detection helper to hooks

```bash
# In .ralph/hooks/platform_detect.sh (sourced by other hooks):
ralph_detect_platform() {
    if [[ -f /proc/sys/fs/binfmt_misc/WSLInterop ]] || \
       grep -qi "microsoft" /proc/version 2>/dev/null; then
        echo "wsl"
    elif [[ "$(uname -s)" == "Darwin" ]]; then
        echo "macos"
    elif [[ "$(uname -s)" == "Linux" ]]; then
        echo "linux"
    else
        echo "unknown"
    fi
}

# Get the correct PowerShell command for this platform
ralph_get_powershell_cmd() {
    local platform
    platform=$(ralph_detect_platform)
    case "$platform" in
        wsl)
            # In WSL, Windows executables need .exe suffix
            if command -v powershell.exe &>/dev/null; then
                echo "powershell.exe"
            elif command -v pwsh &>/dev/null; then
                echo "pwsh"
            else
                echo ""
            fi
            ;;
        linux|macos)
            if command -v pwsh &>/dev/null; then
                echo "pwsh"
            else
                echo ""
            fi
            ;;
        *)
            if command -v powershell &>/dev/null; then
                echo "powershell"
            elif command -v pwsh &>/dev/null; then
                echo "pwsh"
            else
                echo ""
            fi
            ;;
    esac
}
```

### Step 2: Update SessionStart hook

```bash
#!/usr/bin/env bash
# .ralph/hooks/on-session-start.sh

# Source platform detection
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/platform_detect.sh" 2>/dev/null || true

# Get appropriate PowerShell command
PS_CMD=$(ralph_get_powershell_cmd)

if [[ -n "$PS_CMD" ]]; then
    $PS_CMD -NoProfile -Command "..." 2>/dev/null
else
    # PowerShell not available — use alternative or skip
    # Log once, not every invocation
    if [[ ! -f "${SCRIPT_DIR}/.ps_warned" ]]; then
        echo "[WARN] PowerShell not available in this environment — skipping PS-dependent startup tasks" >&2
        touch "${SCRIPT_DIR}/.ps_warned"
    fi
fi
```

### Step 3: Add hook validation at Ralph startup

```bash
# In ralph_loop.sh, during startup:
ralph_validate_hooks() {
    local hooks_dir="${RALPH_DIR}/hooks"
    [[ ! -d "$hooks_dir" ]] && return 0

    local hook
    for hook in "$hooks_dir"/*.sh; do
        [[ ! -f "$hook" ]] && continue
        if [[ ! -x "$hook" ]]; then
            log "WARN" "Hook not executable: $hook (run: chmod +x $hook)"
        fi
    done

    # Check platform-specific commands referenced in hooks
    if grep -q 'powershell' "$hooks_dir"/*.sh 2>/dev/null; then
        local ps_cmd
        ps_cmd=$(ralph_get_powershell_cmd)
        if [[ -z "$ps_cmd" ]]; then
            log "WARN" "Hooks reference 'powershell' but it's not available. Use 'powershell.exe' in WSL."
        fi
    fi
}
```

## Design Notes

- **`powershell.exe` vs `powershell`**: In WSL, Windows executables must include the `.exe` extension. `powershell.exe` calls Windows PowerShell 5.1; `pwsh` calls cross-platform PowerShell 7+.
- **"Log once" pattern**: The `.ps_warned` sentinel file ensures the warning is emitted only once per session, following the log deduplication best practice from systemd-journald (rate-limited logging).
- **Graceful degradation**: If PowerShell isn't available, the hook should skip PS-dependent tasks rather than failing. The core Ralph functionality doesn't depend on PowerShell.
- **Platform detection in hooks**: Hooks run in a subprocess, not in ralph_loop.sh's context. They need their own platform detection rather than inheriting from the parent.
- **WSL Interop file**: `/proc/sys/fs/binfmt_misc/WSLInterop` is the most reliable WSL detection method per Microsoft's documentation.

## Acceptance Criteria

- [ ] SessionStart hook uses `powershell.exe` in WSL environments
- [ ] Hook gracefully degrades when PowerShell is not available
- [ ] Warning is logged once per session, not every invocation
- [ ] Startup validation checks hook executability
- [ ] Platform detection works in WSL1, WSL2, and native Linux

## Test Plan

```bash
@test "ralph_detect_platform returns wsl in WSL environment" {
    source "$RALPH_DIR/.ralph/hooks/platform_detect.sh"
    # This test is environment-dependent
    if [[ -f /proc/sys/fs/binfmt_misc/WSLInterop ]]; then
        run ralph_detect_platform
        assert_output "wsl"
    fi
}

@test "ralph_get_powershell_cmd returns powershell.exe in WSL" {
    source "$RALPH_DIR/.ralph/hooks/platform_detect.sh"
    if [[ -f /proc/sys/fs/binfmt_misc/WSLInterop ]]; then
        run ralph_get_powershell_cmd
        assert_output "powershell.exe"
    fi
}

@test "ralph_get_powershell_cmd returns empty when unavailable" {
    source "$RALPH_DIR/.ralph/hooks/platform_detect.sh"
    # Override PATH to hide powershell
    PATH="/usr/bin" ralph_get_powershell_cmd
    # Should return empty or pwsh
}
```

## References

- [Microsoft — WSL Development Environment](https://learn.microsoft.com/en-us/windows/wsl/setup/environment)
- [Microsoft — WSL Filesystem Interop](https://learn.microsoft.com/en-us/windows/wsl/filesystems)
- [Microsoft/WSL Issue #844 — Detect WSL](https://github.com/microsoft/WSL/issues/844)
- [PowerShell.org — Cross-Platform PowerShell Code](https://powershell.org/2019/02/tips-for-writing-cross-platform-powershell-code/)
- [systemd journald.conf — Rate Limiting](https://www.freedesktop.org/software/systemd/man/latest/journald.conf.html)
