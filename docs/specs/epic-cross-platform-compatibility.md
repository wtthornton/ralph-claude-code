# Epic: Cross-Platform Compatibility

**Epic ID:** RALPH-XPLAT
**Priority:** Medium
**Affects:** Log quality, hook reliability, agent environments
**Components:** `ralph_loop.sh` (version check), `.claude/settings.json` (hooks), `.claude/agents/ralph.md` (agent prompts)
**Related specs:** [epic-wsl-reliability-polish.md](epic-wsl-reliability-polish.md)
**Depends on:** None
**Target Version:** v1.9.0

---

## Problem Statement

Three cross-platform issues degrade Ralph's reliability in WSL environments:

### Issue 1: False Version Divergence Warning

The version comparison logic triggers a warning even when WSL and Windows versions match:
```
[WARN] VERSION DIVERGENCE: WSL=1.8.1, Windows=1.8.1
```
This is a string comparison bug — likely a trailing newline or carriage return (`\r`) in one of the version strings extracted from the Windows filesystem.

### Issue 2: SessionStart Hook "powershell: not found"

Every session logs `powershell: not found` (exit code 127) because the SessionStart hook tries to run `powershell` in WSL, where it's not in `PATH`. The hook should detect the execution environment and use the appropriate command, or validate executability at startup.

### Issue 3: Agent Uses `python` Instead of `python3`

In WSL environments, `python` is not available — only `python3`. Agent tool calls that use `python` fail with `command not found` (exit code 127).

### Evidence

- **tapps-brain 2026-03-21**: False divergence at line 2288: `WSL=1.8.1, Windows=1.8.1`
- **TheStudio 2026-03-22**: `powershell: not found` in every single session (48+ occurrences)
- **TheStudio 2026-03-22**: `python: command not found` exit code 127 in agent execution

## Research-Informed Adjustments

### WSL Detection Best Practices (2025)

Three reliable methods, ranked by reliability:

1. **`/proc/sys/fs/binfmt_misc/WSLInterop`** file existence — most reliable
2. **`$WSL_DISTRO_NAME`** environment variable — injected by WSL
3. **`grep -i microsoft /proc/version`** — fallback

### Cross-Platform Script Patterns

- **Platform-specific branching**: `case "$(detect_platform)" in wsl|linux|macos)` dispatch
- **PowerShell in WSL**: Use `powershell.exe` (not `powershell`) — Windows executables need `.exe` suffix in WSL
- **Python aliasing**: Modern Ubuntu/Debian use `python3` only. The `python` command requires `python-is-python3` package.

Reference: [Microsoft — WSL Development Environment](https://learn.microsoft.com/en-us/windows/wsl/setup/environment), [Microsoft — WSL Filesystems](https://learn.microsoft.com/en-us/windows/wsl/filesystems)

## Stories

| Story | Title | Priority | Effort | Status |
|-------|-------|----------|--------|--------|
| [XPLAT-1](story-xplat-1-version-divergence-fix.md) | Fix False Version Divergence Warning | Medium | Trivial | Pending |
| [XPLAT-2](story-xplat-2-hook-environment-detection.md) | Cross-Platform Hook Environment Detection | Medium | Small | Pending |
| [XPLAT-3](story-xplat-3-python3-wsl-alias.md) | Python3 Alias in WSL Agent Environments | Low | Trivial | Pending |

## Implementation Order

1. **XPLAT-1** (Medium) — Simplest fix, eliminates most common false warning.
2. **XPLAT-2** (Medium) — Stops hook failures that occur every session.
3. **XPLAT-3** (Low) — Prevents occasional agent failures.

## Acceptance Criteria (Epic-level)

- [ ] Identical WSL and Windows versions do not trigger a divergence warning
- [ ] SessionStart hook works in both WSL and native Windows environments
- [ ] Agent tool calls use `python3` in WSL environments
- [ ] All fixes have BATS tests

## Out of Scope

- macOS compatibility (Ralph primarily targets WSL + Linux)
- Windows native bash support (Git Bash, MSYS2)
- `wslpath` integration for path translation
