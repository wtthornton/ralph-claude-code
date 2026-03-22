# Story RALPH-SDK-V2-5: Bump Version to 2.0.0

**Epic:** [Release, Integration Testing & v2.0.0](epic-sdk-v2-release.md)
**Priority:** Critical
**Status:** Done
**Effort:** Trivial
**Component:** `package.json`, `ralph_loop.sh`

---

## Problem

After all v2.0.0 features are implemented and tested, the version must be bumped from
the current v1.x to v2.0.0. The version exists in two files that must stay in sync:
`package.json` and `ralph_loop.sh` `RALPH_VERSION`. A mismatch causes `ralph --version`
to report a different version than `npm version` / `package.json`.

## Solution

Update the version string in both files to `"2.0.0"`. This is the last code change
before the final regression test (Story 7).

## Implementation

**File 1:** `package.json`

```json
{
  "version": "2.0.0"
}
```

**File 2:** `ralph_loop.sh` (near top of file)

```bash
RALPH_VERSION="2.0.0"
```

### Key Notes

- Both files must contain exactly `2.0.0` — no prefix, no suffix, no `-beta` tag.
- This is a semver major version bump because of the async API breaking change.
- Per CLAUDE.md and the memory file (`feedback_version_sync.md`), version must be updated in both files on every bump.
- This story should be the last code change before Story 7 (regression test).

## Acceptance Criteria

- [ ] `package.json` contains `"version": "2.0.0"`
- [ ] `ralph_loop.sh` contains `RALPH_VERSION="2.0.0"`
- [ ] Both files have exactly the same version string
- [ ] `ralph --version` outputs `2.0.0`
- [ ] `node -e "console.log(require('./package.json').version)"` outputs `2.0.0`
- [ ] No other files modified in this story

## Test Plan

```bash
# Verify package.json version
node -e "const v = require('./package.json').version; console.assert(v === '2.0.0', 'Expected 2.0.0, got ' + v); console.log('OK:', v)"

# Verify ralph_loop.sh version
grep -q 'RALPH_VERSION="2.0.0"' ralph_loop.sh && echo "OK: ralph_loop.sh" || echo "FAIL: ralph_loop.sh"

# Verify ralph --version (requires installation)
ralph --version | grep -q "2.0.0" && echo "OK: ralph --version" || echo "FAIL: ralph --version"

# Verify both match
PKG_VERSION=$(node -e "console.log(require('./package.json').version)")
LOOP_VERSION=$(grep 'RALPH_VERSION=' ralph_loop.sh | head -1 | sed 's/.*"\(.*\)"/\1/')
[ "$PKG_VERSION" = "$LOOP_VERSION" ] && echo "OK: versions match ($PKG_VERSION)" || echo "FAIL: $PKG_VERSION != $LOOP_VERSION"
```
