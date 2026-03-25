# Story: USYNC-4 — Circuit Breaker: Permission Denial Tracking

> **Epic:** RALPH-USYNC (Upstream Sync) | **Priority:** High | **Size:** M | **Status:** Done
> **Upstream ref:** Issue #101, `lib/circuit_breaker.sh` lines 202-208

## Problem

When Claude repeatedly requests tools that are denied by `ALLOWED_TOOLS` or PreToolUse hooks, the loop makes no progress but the circuit breaker doesn't distinguish this from other no-progress scenarios. The upstream circuit breaker tracks `consecutive_permission_denials` with a dedicated threshold (`CB_PERMISSION_DENIAL_THRESHOLD`, default 2) and opens the circuit faster for permission issues — because permission denials are deterministic (they'll fail every time) and don't benefit from retries.

The fork already extracts permission denial information:
- `ralph_log_permission_denials_from_raw_output()` logs denials
- `story-loop-2-aggregate-permission-denials.md` was completed
- The SDK's `parsing.py` has `detect_permission_denials()`

But the circuit breaker does not use this information for faster trip decisions.

## Solution

Add permission denial tracking to the circuit breaker evaluation in `on-stop.sh`, with a dedicated counter and lower threshold than generic no-progress.

## Implementation

### 1. Extract permission denial count in `on-stop.sh`

The on-stop.sh hook already has access to the raw response. Add permission denial counting:

```bash
# Count permission denials in the response
permission_denials=$(echo "$result_text" | grep -ciE '(permission denied|tool not allowed|not in allowed|disallowed tool)' || echo "0")
```

### 2. Add fields to `status.json`

```json
{
  "has_permission_denials": true,
  "permission_denial_count": 3
}
```

### 3. Add to circuit breaker state schema

Update `init_circuit_breaker()` default state to include:

```json
{
  "consecutive_permission_denials": 0
}
```

### 4. Add permission denial tracking to `on-stop.sh` CB update

```bash
CB_PERMISSION_DENIAL_THRESHOLD=${CB_PERMISSION_DENIAL_THRESHOLD:-2}

if [[ "$permission_denials" -gt 0 ]]; then
    # Increment consecutive permission denials
    consecutive_pd=$(($(jq -r '.consecutive_permission_denials // 0' "$CB_STATE_FILE") + 1))

    if [[ "$consecutive_pd" -ge "$CB_PERMISSION_DENIAL_THRESHOLD" ]]; then
        # Trip circuit breaker — permission denials are deterministic, won't self-resolve
        # Reason includes denied tool names for operator diagnosis
        cb_trip_reason="Permission denied ${consecutive_pd} consecutive times"
    fi
else
    # Reset counter on no denials
    consecutive_pd=0
fi
```

### 5. Add `CB_PERMISSION_DENIAL_THRESHOLD` to `.ralphrc` template

Add to `templates/ralphrc.template` in the circuit breaker section:

```bash
# Permission denial threshold (denials are deterministic -- trip fast)
# CB_PERMISSION_DENIAL_THRESHOLD=2
```

## Acceptance Criteria

- [ ] Permission denial count extracted from response in on-stop.sh
- [ ] `status.json` includes `has_permission_denials` and `permission_denial_count`
- [ ] `consecutive_permission_denials` tracked in circuit breaker state
- [ ] Counter resets to 0 when a loop has no permission denials
- [ ] Circuit breaker trips to OPEN after `CB_PERMISSION_DENIAL_THRESHOLD` (default 2) consecutive denial loops
- [ ] Trip reason includes "permission denied" for operator diagnosis
- [ ] `CB_PERMISSION_DENIAL_THRESHOLD` is configurable via `.ralphrc`
- [ ] BATS test: 2 consecutive denial loops trips breaker
- [ ] BATS test: denial followed by clean loop resets counter
- [ ] BATS test: custom threshold of 5 requires 5 consecutive denials

## Dependencies

- None (independent of USYNC-1/2/3)

## Files to Modify

- `templates/hooks/on-stop.sh` — add denial extraction and CB update logic
- `lib/circuit_breaker.sh` — update `init_circuit_breaker()` default state, add threshold var
- `templates/ralphrc.template` — add `CB_PERMISSION_DENIAL_THRESHOLD` config
- `ralph_loop.sh` — update `log_status_summary()` to show denial state
- `tests/unit/test_circuit_breaker_recovery.bats` — add permission denial tests
