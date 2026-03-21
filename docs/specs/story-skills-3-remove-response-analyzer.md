# Story RALPH-SKILLS-3: Remove response_analyzer.sh (Hooks Handle It)

**Epic:** [Skills + Bash Reduction](epic-skills-bash-reduction.md)
**Priority:** Important
**Status:** Open
**Effort:** Medium
**Component:** `lib/response_analyzer.sh`, `ralph_loop.sh`
**Depends on:** RALPH-HOOKS-4 (on-stop.sh validated in production)

---

## Problem

After Phase 1, the `on-stop.sh` hook handles all response analysis that
`response_analyzer.sh` (935 lines) previously performed. The bash module is now
redundant — but it was retained as a fallback during Phase 1. Once the hook has been
validated in production across multiple fix plans, the bash module can be removed.

This is the single largest code reduction in the v1.0 migration: **-935 lines**.

## Solution

Remove `lib/response_analyzer.sh` and update all callers in `ralph_loop.sh` to rely
on the `on-stop.sh` hook's output in `.ralph/status.json`.

## Implementation

### Step 1: Identify all callers of response_analyzer.sh

Functions to remove/replace in `ralph_loop.sh`:
- `analyze_response()` — reads raw CLI output, calls `parse_json_response`
- `parse_json_response()` — jq extraction of response fields
- `ralph_prepare_claude_output_for_analysis()` — JSONL normalization
- Any `source lib/response_analyzer.sh` lines

### Step 2: Replace with status.json reads

After the hook-based flow, `ralph_loop.sh` reads state from `.ralph/status.json`
instead of parsing raw CLI output:

```bash
# Before (v0.11.x): Parse raw CLI output
analyze_response "$output_file"
local exit_signal="${RESPONSE_EXIT_SIGNAL:-false}"
local status="${RESPONSE_STATUS:-UNKNOWN}"
local tasks_done="${RESPONSE_TASKS_DONE:-0}"

# After (v1.0): Read hook-written state
local exit_signal=$(jq -r '.exit_signal // "false"' .ralph/status.json)
local status=$(jq -r '.status // "UNKNOWN"' .ralph/status.json)
local tasks_done=$(jq -r '.tasks_completed // 0' .ralph/status.json)
```

### Step 3: Remove the file

```bash
rm lib/response_analyzer.sh
```

### Step 4: Adapt existing tests

BATS tests that test `response_analyzer.sh` functions should be:
1. **Retained** as regression tests for `on-stop.sh` (same output format)
2. **Redirected** to test the hook script instead of the bash functions
3. **Removed** if they test internal parsing details no longer relevant

### Key Design Decisions

1. **Production validation required:** This story should NOT be started until the
   `on-stop.sh` hook has been validated across at least 3 full fix plan completions.

2. **status.json as the interface:** All loop control decisions now read from
   `.ralph/status.json` (written by the hook). This is a cleaner, more testable
   interface than parsing raw CLI output.

3. **Test adaptation over deletion:** Prefer adapting tests to test the hook output
   rather than deleting them. The test cases remain valid — only the implementation
   under test changes.

4. **No fallback after removal:** Once removed, there's no `response_analyzer.sh`
   fallback. `RALPH_USE_AGENT=false` mode would need a minimal inline parser or
   the hook must work in both modes.

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Hook misses edge case that bash caught | Medium | High | Validate with 3+ fix plans before removing |
| Tests break on removal | High | Medium | Adapt tests in advance, not during removal |
| Legacy mode (`RALPH_USE_AGENT=false`) breaks | Medium | Medium | Keep minimal inline parser for legacy |

## Testing

```bash
@test "response_analyzer.sh is removed" {
  [[ ! -f "lib/response_analyzer.sh" ]]
}

@test "ralph_loop.sh does not source response_analyzer" {
  ! grep -q "response_analyzer" ralph_loop.sh
}

@test "ralph_loop.sh reads status from status.json" {
  grep -q "status.json" ralph_loop.sh
}

@test "all existing exit detection scenarios still work" {
  # Retained regression tests adapted for hook output
  # ... (specific tests from existing test_response_analyzer.bats)
}
```

## Acceptance Criteria

- [ ] `lib/response_analyzer.sh` deleted (-935 lines)
- [ ] All callers in `ralph_loop.sh` updated to read `.ralph/status.json`
- [ ] No remaining `source lib/response_analyzer.sh` references
- [ ] Existing exit detection test scenarios pass (adapted for hooks)
- [ ] `on-stop.sh` hook validated across 3+ fix plan completions before this story starts
- [ ] Legacy mode has minimal inline parser (if `RALPH_USE_AGENT=false` is supported)
