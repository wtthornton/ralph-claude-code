# Story: USYNC-1 — Question Pattern Detection in on-stop.sh

> **Epic:** RALPH-USYNC (Upstream Sync) | **Priority:** Critical | **Size:** M | **Status:** Done
> **Upstream ref:** Issue #190, `lib/response_analyzer.sh` lines 25-51

## Problem

When Claude asks questions instead of acting (e.g., "Should I refactor this?", "Which approach do you prefer?"), headless Ralph loops have no way to detect this. The upstream `response_analyzer.sh` has a `detect_questions()` function with 17 patterns, but the fork removed that module (story SKILLS-3) without porting question detection into the `on-stop.sh` hook.

The fork's test files (`test_json_parsing.bats`, `test_exit_detection.bats`) still contain tests for `detect_questions()` but the function no longer exists — these are dead tests.

## Solution

Add question detection to the `on-stop.sh` hook and surface the result in `status.json`.

## Implementation

### 1. Add question patterns to `templates/hooks/on-stop.sh`

Port the 17 upstream patterns as a grep-based check on the extracted result text:

```bash
QUESTION_PATTERNS=(
    "should I"
    "would you"
    "do you want"
    "which approach"
    "which option"
    "how should"
    "what should"
    "shall I"
    "do you prefer"
    "can you clarify"
    "could you"
    "what do you think"
    "please confirm"
    "need clarification"
    "awaiting.*input"
    "waiting.*response"
    "your preference"
)
```

Count matches across all patterns using `grep -ciE` on the result text. Store the count and a boolean `asking_questions` flag.

### 2. Update `status.json` schema

Add two fields to the JSON written by on-stop.sh:

```json
{
  "asking_questions": true,
  "question_count": 3
}
```

### 3. Update `log_status_summary()` in `ralph_loop.sh`

Read and display the `asking_questions` field when true (e.g., "Questions detected: 3 patterns matched").

### 4. Fix dead tests

Update `test_json_parsing.bats` and `test_exit_detection.bats` to test question detection via the on-stop.sh hook output (status.json) rather than the removed `detect_questions()` function.

## Acceptance Criteria

- [ ] All 17 upstream question patterns are detected in on-stop.sh
- [ ] `status.json` includes `asking_questions` (boolean) and `question_count` (integer)
- [ ] Detection works on both JSON-extracted `.result` text and raw text output
- [ ] `grep -ciE` is used (case-insensitive) matching upstream behavior
- [ ] Dead tests in `test_json_parsing.bats` and `test_exit_detection.bats` are updated or removed
- [ ] New BATS tests cover: all 17 patterns, zero-match case, multi-match counting
- [ ] No performance regression — detection runs in the existing on-stop.sh pipeline without additional subprocesses

## Dependencies

- None (this is the foundation for USYNC-2 and USYNC-3)

## Files to Modify

- `templates/hooks/on-stop.sh` — add detection logic
- `ralph_loop.sh` — update `log_status_summary()` to show question state
- `tests/unit/test_exit_detection.bats` — fix dead tests
- `tests/unit/test_json_parsing.bats` — fix dead tests
