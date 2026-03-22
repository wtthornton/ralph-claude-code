# Story XPLAT-1: Fix False Version Divergence Warning

**Epic:** [Cross-Platform Compatibility](epic-cross-platform-compatibility.md)
**Priority:** Medium
**Status:** Pending
**Effort:** Trivial
**Component:** `ralph_loop.sh` (`check_version_divergence`)

---

## Problem

The version divergence check compares WSL and Windows `RALPH_VERSION` values but triggers false positives when versions are identical:

```
[WARN] VERSION DIVERGENCE: WSL=1.8.1, Windows=1.8.1
```

The root cause is likely a trailing `\r` (carriage return) or whitespace in the version string extracted from the Windows filesystem (`/mnt/c/...`), because files on the Windows NTFS filesystem often have `\r\n` line endings.

**Root cause confirmed by:** tapps-brain logs 2026-03-21, line 2288.

## Solution

Strip whitespace and carriage returns from both version strings before comparison.

## Implementation

```bash
# In check_version_divergence():

# Current (broken):
local wsl_version="$RALPH_VERSION"
local win_version
win_version=$(grep -m1 'RALPH_VERSION=' "$win_ralph_loop" | cut -d'"' -f2)
if [[ "$wsl_version" != "$win_version" ]]; then
    log "WARN" "VERSION DIVERGENCE: WSL=$wsl_version, Windows=$win_version"
fi

# Fixed — strip \r, whitespace, and quotes:
local wsl_version win_version
wsl_version=$(echo "$RALPH_VERSION" | tr -d '\r\n[:space:]')
win_version=$(grep -m1 'RALPH_VERSION=' "$win_ralph_loop" 2>/dev/null \
    | cut -d'"' -f2 \
    | tr -d '\r\n[:space:]')

if [[ -z "$win_version" ]]; then
    log "DEBUG" "Could not extract Windows Ralph version — skipping divergence check"
    return 0
fi

if [[ "$wsl_version" != "$win_version" ]]; then
    log "WARN" "VERSION DIVERGENCE: WSL=$wsl_version, Windows=$win_version"
    log "WARN" "This can cause silent loop crashes. Update both installations."
else
    log "DEBUG" "Version check OK: WSL=$wsl_version, Windows=$win_version"
fi
```

## Design Notes

- **`tr -d '\r\n[:space:]'`**: Removes carriage returns, newlines, and any leading/trailing whitespace. Version strings like `1.8.1` should never contain spaces.
- **Empty check**: If the Windows version can't be extracted (e.g., file not found, different format), skip the check rather than logging a false divergence.
- **DEBUG on match**: Confirming versions match at DEBUG level aids troubleshooting without adding log noise.

## Acceptance Criteria

- [ ] Identical versions with `\r` suffix do not trigger a warning
- [ ] Identical versions without `\r` do not trigger a warning
- [ ] Truly different versions still trigger a warning
- [ ] Missing Windows installation gracefully skips the check

## Test Plan

```bash
@test "version comparison ignores carriage return" {
    source "$RALPH_DIR/ralph_loop.sh"
    local v1="1.8.1"
    local v2=$'1.8.1\r'

    v1_clean=$(echo "$v1" | tr -d '\r\n[:space:]')
    v2_clean=$(echo "$v2" | tr -d '\r\n[:space:]')

    assert_equal "$v1_clean" "$v2_clean"
}

@test "version comparison detects real divergence" {
    local v1="1.8.1"
    local v2="1.8.3"

    v1_clean=$(echo "$v1" | tr -d '\r\n[:space:]')
    v2_clean=$(echo "$v2" | tr -d '\r\n[:space:]')

    refute [ "$v1_clean" = "$v2_clean" ]
}
```

## References

- [Microsoft — Working Across Windows and Linux File Systems](https://learn.microsoft.com/en-us/windows/wsl/filesystems)
- [Stack Overflow — Windows \r\n in WSL](https://stackoverflow.com/questions/45836650)
