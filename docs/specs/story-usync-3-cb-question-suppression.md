# Story: USYNC-3 — Circuit Breaker: Question-Detection Suppression

> **Epic:** RALPH-USYNC (Upstream Sync) | **Priority:** High | **Size:** S | **Status:** Done
> **Upstream ref:** Issue #190 Bug 2, `lib/circuit_breaker.sh` lines 210-215

## Problem

When Claude asks questions in a headless loop, no files are modified and no tasks are completed — but this is NOT the same as "no progress due to being stuck." The upstream circuit breaker explicitly suppresses the `consecutive_no_progress` counter when questions are detected:

```bash
# Claude is asking questions -- not progress, but not stagnation either.
# Suppress no-progress counter; corrective context will redirect next loop.
```

The fork's circuit breaker state updates happen in `on-stop.sh`, which currently increments the no-progress counter whenever `files_modified == 0` regardless of whether Claude was asking questions. This causes the circuit breaker to falsely open after 3 question-asking loops.

## Solution

Update the `on-stop.sh` hook to skip no-progress counter increment when `asking_questions` is true. The corrective guidance (USYNC-2) will redirect Claude in the next loop, so questions are a transient state, not a failure.

## Implementation

### 1. Update circuit breaker state logic in `on-stop.sh`

In the section that updates `.circuit_breaker_state`, add a guard:

```bash
# Read question detection result
asking_questions=$(echo "$status_json" | jq -r '.asking_questions // false')

# Update circuit breaker -- suppress no-progress on question loops
if [[ "$asking_questions" == "true" ]]; then
    # Questions detected: don't increment no-progress, don't record as failure
    # Corrective guidance (USYNC-2) will redirect next loop
    : # no-op for circuit breaker
elif [[ "$files_modified" -eq 0 && "$has_completion" != "true" ]]; then
    # Genuine no-progress: increment counter
    cb_record_failure
fi
```

### 2. Update CBDECAY sliding window

The fork's `cb_record_failure()` / `cb_record_success()` (CBDECAY-1 sliding window) should also respect question suppression. A question loop should be recorded as neither success nor failure — it's a no-op for the window.

## Acceptance Criteria

- [ ] `on-stop.sh` reads `asking_questions` before updating circuit breaker state
- [ ] No-progress counter is NOT incremented when `asking_questions == true`
- [ ] `cb_record_failure()` is NOT called on question-asking loops
- [ ] `cb_record_success()` is NOT called on question-asking loops (questions are neutral)
- [ ] After 3 consecutive question loops, circuit breaker remains CLOSED (not OPEN)
- [ ] After corrective guidance redirects Claude and files are modified, normal progress tracking resumes
- [ ] BATS test: simulate 5 consecutive question loops, assert CB state == CLOSED
- [ ] BATS test: simulate question loop followed by productive loop, assert normal CB flow

## Dependencies

- **USYNC-1** (question detection must populate `asking_questions` in status.json)

## Files to Modify

- `templates/hooks/on-stop.sh` — add question-detection guard to CB update logic
- `tests/unit/test_circuit_breaker_recovery.bats` — add question suppression tests
