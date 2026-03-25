# Story: USYNC-2 — Question-Loop Corrective Guidance Injection

> **Epic:** RALPH-USYNC (Upstream Sync) | **Priority:** Critical | **Size:** S | **Status:** Done
> **Upstream ref:** Issue #190 Bug 2, `ralph_loop.sh` lines 771-778

## Problem

When Ralph runs headless (no human to answer), Claude sometimes asks questions instead of acting. The upstream repo injects corrective guidance into the next loop's context:

```
IMPORTANT: You asked questions in the previous loop. This is a headless automation
loop with no human to answer. Do NOT ask questions. Choose the most conservative/safe
default and proceed autonomously.
```

The fork's `build_loop_context()` (lines 1653-1703 in `ralph_loop.sh`) does NOT check for question-detection state from `status.json`. This was lost when `response_analyzer.sh` was removed.

## Solution

Add an `asking_questions` check to `build_loop_context()` that reads from `status.json` (written by on-stop.sh after USYNC-1) and appends corrective guidance to the loop context string.

## Implementation

### 1. Update `build_loop_context()` in `ralph_loop.sh`

After the existing `status.json` reads (recommendation field), add:

```bash
# If previous loop detected questions, inject corrective guidance (upstream #190)
local prev_asking_questions
prev_asking_questions=$(jq -r '.asking_questions // false' "$STATUS_FILE" 2>/dev/null || echo "false")
if [[ "$prev_asking_questions" == "true" ]]; then
    context+="IMPORTANT: You asked questions in the previous loop. This is a headless automation loop with no human to answer. Do NOT ask questions. Choose the most conservative/safe default and proceed autonomously. "
fi
```

### 2. Log the guidance injection

Add a `log_status` call when guidance is injected so operators can see it in ralph.log:

```bash
log_status "INFO" "Injecting question-corrective guidance (previous loop asked questions)"
```

## Acceptance Criteria

- [ ] `build_loop_context()` reads `asking_questions` from `status.json`
- [ ] Corrective guidance text matches upstream wording
- [ ] Guidance is appended to the context string (not prepended — existing context has priority)
- [ ] A log line is emitted when guidance is injected
- [ ] When `asking_questions` is false or missing, no guidance is added
- [ ] BATS test: mock `status.json` with `asking_questions: true`, verify context contains guidance text
- [ ] BATS test: mock `status.json` with `asking_questions: false`, verify context does NOT contain guidance

## Dependencies

- **USYNC-1** (question detection must exist in status.json first)

## Files to Modify

- `ralph_loop.sh` — update `build_loop_context()` function
- `tests/unit/test_exit_detection.bats` or new test file — add guidance injection tests
