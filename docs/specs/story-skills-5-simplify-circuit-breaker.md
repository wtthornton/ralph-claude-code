# Story RALPH-SKILLS-5: Simplify circuit_breaker.sh (Hooks Provide State)

**Epic:** [Skills + Bash Reduction](epic-skills-bash-reduction.md)
**Priority:** Important
**Status:** Done
**Effort:** Medium
**Component:** `lib/circuit_breaker.sh`, `ralph_loop.sh`
**Depends on:** RALPH-HOOKS-4 (on-stop.sh manages circuit breaker state)

---

## Problem

`lib/circuit_breaker.sh` (475 lines) implements a three-state circuit breaker pattern
(CLOSED → OPEN → HALF_OPEN → CLOSED) with jq-based state management, cooldown timers,
auto-recovery, and progress detection. After Phase 1, the `on-stop.sh` hook handles
progress detection and state updates. Much of the bash module is now redundant.

## Solution

Simplify `circuit_breaker.sh` to a thin reader of `.ralph/.circuit_breaker_state`
(written by the hook). Remove all progress detection logic (hook handles it), simplify
state transitions, and reduce the module to ~100 lines.

## Implementation

### What the hook now handles (remove from bash)

- Progress detection (files modified, tasks completed)
- No-progress counter increment
- OPEN state transition (threshold reached)
- CLOSED state reset (progress detected)

### What stays in bash

- **State reading:** Read `.circuit_breaker_state` to determine if loop should continue
- **HALF_OPEN transition:** After cooldown, transition OPEN → HALF_OPEN
- **Cooldown timer:** Check if enough time has passed since OPEN state
- **Auto-reset:** `CB_AUTO_RESET=true` behavior
- **Loop control decision:** Should the loop continue, pause, or stop?

### Simplified interface

```bash
# Simplified circuit_breaker.sh (~100 lines)

# Read circuit breaker state (written by on-stop.sh hook)
cb_read_state() {
  local state_file="${RALPH_DIR:-.ralph}/.circuit_breaker_state"
  if [[ ! -f "$state_file" ]]; then
    echo "CLOSED"
    return
  fi
  jq -r '.state // "CLOSED"' "$state_file" 2>/dev/null || echo "CLOSED"
}

# Check if loop should continue based on circuit breaker state
cb_should_continue() {
  local state
  state=$(cb_read_state)

  case "$state" in
    CLOSED)
      return 0  # Continue
      ;;
    HALF_OPEN)
      return 0  # Continue (testing recovery)
      ;;
    OPEN)
      # Check cooldown
      if cb_cooldown_elapsed; then
        cb_transition_to "HALF_OPEN"
        return 0  # Continue (entering recovery)
      fi
      return 1  # Pause — cooldown not elapsed
      ;;
  esac
}

# Check if cooldown period has elapsed
cb_cooldown_elapsed() {
  local state_file="${RALPH_DIR:-.ralph}/.circuit_breaker_state"
  local opened_at
  opened_at=$(jq -r '.opened_at // ""' "$state_file" 2>/dev/null || echo "")

  if [[ -z "$opened_at" ]]; then
    return 0  # No timestamp, assume elapsed
  fi

  local now
  now=$(date +%s)
  local opened_epoch
  opened_epoch=$(date -d "$opened_at" +%s 2>/dev/null || echo "0")
  local cooldown_seconds=$(( ${CB_COOLDOWN_MINUTES:-30} * 60 ))

  if [[ $((now - opened_epoch)) -ge $cooldown_seconds ]]; then
    return 0  # Cooldown elapsed
  fi

  return 1  # Still cooling down
}

# Transition to a new state
cb_transition_to() {
  local new_state="$1"
  local state_file="${RALPH_DIR:-.ralph}/.circuit_breaker_state"
  local tmp
  tmp=$(mktemp "${state_file}.XXXXXX")

  jq --arg state "$new_state" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '.state = $state | if $state == "OPEN" then .opened_at = $ts else . end' \
    "$state_file" > "$tmp" && mv "$tmp" "$state_file"
}

# Auto-reset if configured
cb_auto_reset() {
  if [[ "${CB_AUTO_RESET:-false}" == "true" ]]; then
    local state
    state=$(cb_read_state)
    if [[ "$state" == "OPEN" ]]; then
      log_info "Circuit breaker auto-reset: OPEN → HALF_OPEN"
      cb_transition_to "HALF_OPEN"
    fi
  fi
}
```

### Key Design Decisions

1. **Hook writes, bash reads:** Clear separation of concerns. The `on-stop.sh` hook
   detects progress and updates state. The bash module reads state and makes loop
   control decisions.

2. **~375 lines removed:** Progress detection, jq state parsing, and redundant
   state management logic are all removed.

3. **Same interface to callers:** `cb_should_continue()` returns 0/1 as before.
   `ralph_loop.sh` doesn't need changes beyond removing the old function calls.

4. **Atomic writes preserved:** `mktemp` + `mv` pattern for state transitions.

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Hook and bash disagree on state | Low | Medium | Both read/write same file, hook writes first |
| Race condition during transition | Low | Low | Atomic writes prevent corruption |
| Cooldown timer drift | Low | Low | Timer is approximate, not critical |

## Testing

```bash
@test "cb_read_state returns CLOSED for missing file" {
  RALPH_DIR=$(mktemp -d)
  result=$(cb_read_state)
  [[ "$result" == "CLOSED" ]]
}

@test "cb_should_continue allows CLOSED state" {
  RALPH_DIR=$(mktemp -d)
  echo '{"state": "CLOSED"}' > "$RALPH_DIR/.circuit_breaker_state"
  cb_should_continue
}

@test "cb_should_continue blocks OPEN within cooldown" {
  RALPH_DIR=$(mktemp -d)
  echo "{\"state\": \"OPEN\", \"opened_at\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" \
    > "$RALPH_DIR/.circuit_breaker_state"
  CB_COOLDOWN_MINUTES=30
  ! cb_should_continue
}

@test "cb_auto_reset transitions OPEN to HALF_OPEN" {
  RALPH_DIR=$(mktemp -d)
  echo '{"state": "OPEN"}' > "$RALPH_DIR/.circuit_breaker_state"
  CB_AUTO_RESET=true
  cb_auto_reset
  [[ "$(cb_read_state)" == "HALF_OPEN" ]]
}
```

## Acceptance Criteria

- [ ] `circuit_breaker.sh` reduced from ~475 lines to ~100 lines
- [ ] All progress detection logic removed (hook handles it)
- [ ] State reading, cooldown, and auto-reset preserved
- [ ] `cb_should_continue()` interface unchanged for callers
- [ ] Atomic file writes maintained
- [ ] Existing circuit breaker BATS tests adapted and passing
- [ ] No race conditions between hook writes and bash reads
