# Story: USYNC-6 — Heuristic Exit Suppression in JSON Mode

> **Epic:** RALPH-USYNC (Upstream Sync) | **Priority:** Medium | **Size:** S | **Status:** Done (already satisfied by existing on-stop.sh architecture)
> **Upstream ref:** Issue #224, commit `d72edcd`

## Problem

Upstream PR #224 fixes a false-positive exit detection issue: when output is in JSON mode, heuristic (text-based) exit detection should be suppressed because the structured RALPH_STATUS block is the authoritative signal. The upstream fix:

1. Suppresses heuristic exit signal detection entirely when output format is JSON
2. Raises the text-mode heuristic threshold to reduce false positives

The fork's `on-stop.sh` hook receives JSON from the Claude CLI hook interface, so format detection is not an issue. However, the hook's text fallback path (when no RALPH_STATUS block is found) may still apply heuristic completion detection that could false-positive.

## Solution

Audit the fork's `on-stop.sh` text fallback path and ensure heuristic exit detection is appropriately gated. If the response contains structured JSON with a RALPH_STATUS block, skip all heuristic/keyword-based completion detection.

## Implementation

### 1. Audit `on-stop.sh` text fallback

Review the text fallback path in `on-stop.sh` for any keyword-based completion detection (e.g., matching "done", "complete", "finished" in response text). Ensure these only fire when NO structured RALPH_STATUS block was found.

### 2. Add format guard

```bash
if [[ "$ralph_status_found" == "true" ]]; then
    # Structured status block found — use it exclusively
    # Do NOT apply heuristic text matching
    :
else
    # Text fallback — apply heuristic detection with raised thresholds
    # Only trigger exit signal on high-confidence matches
    :
fi
```

### 3. Raise text fallback thresholds

If the fork has any confidence scoring in text fallback, ensure the threshold is high enough to avoid false positives (upstream raised theirs).

## Acceptance Criteria

- [ ] When RALPH_STATUS block is present, no heuristic exit detection runs
- [ ] Text fallback path only fires when RALPH_STATUS is absent
- [ ] No false-positive exits from JSON responses containing words like "done" in code comments
- [ ] BATS test: JSON response with "done" in a code comment does NOT trigger exit
- [ ] BATS test: text response with genuine completion keywords DOES trigger exit

## Dependencies

- None (independent)

## Files to Modify

- `templates/hooks/on-stop.sh` — audit and gate text fallback
- `tests/unit/test_exit_detection.bats` — add false-positive test cases
