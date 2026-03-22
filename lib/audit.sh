#!/bin/bash

# lib/audit.sh — Structured audit logging for compliance (Phase 14, FAILSPEC-4)
#
# Captures safety-relevant decisions in machine-readable JSONL format.
# Fields aligned to ISO 42001 and NIST AI RMF requirements.
# Audit log: .ralph/.audit.jsonl (rotated at RALPH_AUDIT_MAX_SIZE_MB).

RALPH_AUDIT_LOG_ENABLED=${RALPH_AUDIT_LOG_ENABLED:-true}
RALPH_AUDIT_LOG="${RALPH_DIR:-.ralph}/.audit.jsonl"
RALPH_AUDIT_MAX_SIZE_MB=${RALPH_AUDIT_MAX_SIZE_MB:-50}

# ralph_audit — Append a structured audit event
#
# Usage: ralph_audit <event_type> <actor> <decision> <reason> [outcome]
#
# Arguments:
#   event_type  — Category of event (loop_start, circuit_breaker, killswitch, exit_decision, etc.)
#   actor       — Component that made the decision (ralph_loop, circuit_breaker, operator, etc.)
#   decision    — What was decided (begin_iteration, state_change_to_OPEN, emergency_halt, etc.)
#   reason      — Why the decision was made (human-readable, no PII or secrets)
#   outcome     — Result of the decision (started, applied, halted, continued, pending)
#
ralph_audit() {
    [[ "$RALPH_AUDIT_LOG_ENABLED" != "true" ]] && return 0

    local event_type="$1" actor="$2" decision="$3" reason="$4"
    local outcome="${5:-pending}"

    # Ensure the directory exists
    local audit_dir
    audit_dir=$(dirname "$RALPH_AUDIT_LOG")
    [[ -d "$audit_dir" ]] || mkdir -p "$audit_dir"

    jq -n -c \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg event "$event_type" \
        --arg actor "$actor" \
        --arg decision "$decision" \
        --arg reason "$reason" \
        --arg outcome "$outcome" \
        --arg trace_id "${RALPH_TRACE_ID:-none}" \
        --arg ralph_version "${RALPH_VERSION:-unknown}" \
        --arg session_id "$(cat "${RALPH_DIR:-.ralph}/.claude_session_id" 2>/dev/null || echo "none")" \
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

# ralph_rotate_audit_log — Rotate audit log when it exceeds size limit
#
# Keeps last 3 rotated files. Called at loop startup and periodically.
#
ralph_rotate_audit_log() {
    [[ ! -f "$RALPH_AUDIT_LOG" ]] && return 0

    local size_mb
    size_mb=$(du -m "$RALPH_AUDIT_LOG" 2>/dev/null | cut -f1)
    [[ -z "$size_mb" ]] && return 0

    if [[ "$size_mb" -ge "$RALPH_AUDIT_MAX_SIZE_MB" ]]; then
        mv "$RALPH_AUDIT_LOG" "${RALPH_AUDIT_LOG}.$(date +%Y%m%d%H%M%S)"
        # Keep last 3 rotated files
        ls -1t "${RALPH_AUDIT_LOG}."* 2>/dev/null | tail -n +4 | xargs rm -f 2>/dev/null
    fi
}

# Export for use in other scripts
export -f ralph_audit
export -f ralph_rotate_audit_log
