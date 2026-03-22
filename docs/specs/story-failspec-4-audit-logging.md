# Story FAILSPEC-4: Structured Audit Log for Compliance

**Epic:** [Failure Protocol Compliance](epic-failure-protocol.md)
**Priority:** High
**Status:** Open
**Effort:** Medium
**Component:** `ralph_loop.sh`, new `lib/audit.sh`

---

## Problem

The EU AI Act enters broad enforcement on **August 2, 2026**. Requirements include documented error handling, predictable behavior, and retained logs of decisions made by autonomous systems. Ralph's current logging (`ralph.log`) is unstructured text — not suitable for compliance review.

## Solution

Add a structured audit log that captures all safety-relevant decisions in a machine-readable JSONL format with fields aligned to ISO 42001 and NIST AI RMF requirements.

## Implementation

### Step 1: Create `lib/audit.sh`

```bash
RALPH_AUDIT_LOG_ENABLED=${RALPH_AUDIT_LOG_ENABLED:-true}
RALPH_AUDIT_LOG="${RALPH_DIR}/.audit.jsonl"
RALPH_AUDIT_MAX_SIZE_MB=${RALPH_AUDIT_MAX_SIZE_MB:-50}

ralph_audit() {
    [[ "$RALPH_AUDIT_LOG_ENABLED" != "true" ]] && return 0

    local event_type="$1" actor="$2" decision="$3" reason="$4"
    local outcome="${5:-pending}"

    jq -n -c \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg event "$event_type" \
        --arg actor "$actor" \
        --arg decision "$decision" \
        --arg reason "$reason" \
        --arg outcome "$outcome" \
        --arg trace_id "${RALPH_TRACE_ID:-none}" \
        --arg ralph_version "$RALPH_VERSION" \
        --arg session_id "$(cat "${RALPH_DIR}/.claude_session_id" 2>/dev/null || echo "none")" \
        '{
            timestamp: $ts,
            event_type: $event,
            actor: $actor,
            decision: $decision,
            reason: $reason,
            outcome: $outcome,
            trace_id: $trace_id,
            session_id: $session_id,
            ralph_version: $ralph_version
        }' >> "$RALPH_AUDIT_LOG"
}
```

### Step 2: Instrument key decision points

```bash
# Loop start
ralph_audit "loop_start" "ralph_loop" "begin_iteration" "loop_count=$LOOP_COUNT" "started"

# Model routing decision
ralph_audit "model_selection" "complexity_classifier" "selected_$model" \
    "complexity=$complexity, task=$task_text" "applied"

# Circuit breaker state change
ralph_audit "circuit_breaker" "circuit_breaker" "state_change_to_$new_state" \
    "failures=$failure_count, window=${CB_FAILURE_DECAY_MINUTES}m" "$new_state"

# Killswitch activation
ralph_audit "killswitch" "operator" "emergency_halt" "$reason" "halted"

# Exit decision
ralph_audit "exit_decision" "exit_gate" "$decision" \
    "completion_indicators=$count, exit_signal=$signal" "$outcome"

# Token budget exceedance
ralph_audit "budget_warning" "cost_tracker" "budget_exceeded" \
    "actual=$tokens, budget=$budget, task=$task" "continued"
```

### Step 3: Audit log rotation

```bash
ralph_rotate_audit_log() {
    [[ ! -f "$RALPH_AUDIT_LOG" ]] && return 0
    local size_mb
    size_mb=$(du -m "$RALPH_AUDIT_LOG" 2>/dev/null | cut -f1)
    if [[ "$size_mb" -ge "$RALPH_AUDIT_MAX_SIZE_MB" ]]; then
        mv "$RALPH_AUDIT_LOG" "${RALPH_AUDIT_LOG}.$(date +%Y%m%d%H%M%S)"
        # Keep last 3 rotated files
        ls -1t "${RALPH_AUDIT_LOG}."* 2>/dev/null | tail -n +4 | xargs rm -f 2>/dev/null
    fi
}
```

## Design Notes

- **JSONL format**: Machine-readable, appendable, grep-friendly. Each line is a self-contained JSON object.
- **ISO 42001 aligned fields**: `timestamp`, `event_type`, `actor`, `decision`, `reason`, `outcome` map to AI management system audit requirements.
- **Trace ID linkage**: Audit events reference `RALPH_TRACE_ID` for cross-reference with OTel traces.
- **50MB default**: Generous retention. At ~200 bytes per event and 100 events per loop hour, this covers ~250K events (~2500 loop hours).
- **No PII**: Audit log contains operational decisions, not user data or file contents.

## Acceptance Criteria

- [ ] Structured JSONL audit log captures all safety-relevant decisions
- [ ] Fields include: timestamp, event_type, actor, decision, reason, outcome, trace_id
- [ ] Key decision points instrumented: loop start, model selection, CB state change, exit decision
- [ ] Audit log rotation prevents unbounded growth
- [ ] `RALPH_AUDIT_LOG_ENABLED=false` disables audit logging
- [ ] Audit log does not contain API keys, file contents, or PII

## Test Plan

```bash
@test "ralph_audit writes structured JSONL" {
    source "$RALPH_DIR/lib/audit.sh"
    RALPH_DIR="$TEST_DIR"
    RALPH_AUDIT_LOG="$TEST_DIR/.audit.jsonl"
    RALPH_AUDIT_LOG_ENABLED="true"
    RALPH_VERSION="2.0.0"

    ralph_audit "test_event" "test_actor" "test_decision" "test_reason" "success"

    assert [ -f "$RALPH_AUDIT_LOG" ]
    jq -e '.event_type == "test_event"' "$RALPH_AUDIT_LOG"
    jq -e '.actor == "test_actor"' "$RALPH_AUDIT_LOG"
}

@test "ralph_audit is no-op when disabled" {
    source "$RALPH_DIR/lib/audit.sh"
    RALPH_DIR="$TEST_DIR"
    RALPH_AUDIT_LOG="$TEST_DIR/.audit.jsonl"
    RALPH_AUDIT_LOG_ENABLED="false"

    ralph_audit "test" "test" "test" "test"
    assert [ ! -f "$RALPH_AUDIT_LOG" ]
}
```

## References

- [EU AI Act — Technical Documentation](https://artificialintelligenceact.eu/)
- [ISO 42001 — AI Management System](https://www.iso.org/standard/81230.html)
- [NIST AI Risk Management Framework](https://www.nist.gov/artificial-intelligence/risk-management-framework)
