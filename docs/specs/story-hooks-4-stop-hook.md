# Story RALPH-HOOKS-4: Implement on-stop.sh Hook (Replace response_analyzer)

**Epic:** [Hooks + Agent Definition](epic-hooks-agent-definition.md)
**Priority:** Critical
**Status:** Done
**Effort:** Medium
**Component:** `.ralph/hooks/on-stop.sh`

---

## Problem

Ralph v0.11.x relies on `lib/response_analyzer.sh` (935 lines) to parse Claude's
response after each loop. This involves regex extraction of RALPH_STATUS blocks, jq
parsing of JSON output, multi-format detection (JSON/text/JSONL), and bash arithmetic
on extracted fields. The parser is the most fragile component in Ralph — responsible
for the JSONL crash bug (RALPH-JSONL epic) and multiple false exit detections.

Claude Code's `Stop` hook fires after every Claude response with the full response
data on stdin. This replaces the entire post-hoc parsing pipeline with a deterministic
hook that runs inside the Claude Code lifecycle.

## Solution

Implement `.ralph/hooks/on-stop.sh` to:
1. Parse RALPH_STATUS from the response text
2. Update `status.json` with loop state
3. Update circuit breaker state (progress detection)
4. Log to `live.log` for monitoring

### Hook Protocol (Stop)

- **stdin:** JSON with response data including `result`, `content`, session info
- **stdout:** Ignored
- **stderr:** Messages shown to user (if blocking)
- **Exit 0:** Allow stop (normal)
- **Exit 2:** Block stop — keep Claude working (useful for forcing continuation)

## Implementation

```bash
#!/bin/bash
# .ralph/hooks/on-stop.sh
# Replaces: analyze_response() in lib/response_analyzer.sh (lines 1-935)
#
# Stop hook. Runs after every Claude response. Reads response from stdin (JSON).
# Updates .ralph state files deterministically.
# Exit 0 = allow stop.

set -euo pipefail

RALPH_DIR="${CLAUDE_PROJECT_DIR:-.}/.ralph"

# Guard: only run in Ralph-managed projects
if [[ ! -d "$RALPH_DIR" ]]; then
  exit 0
fi

# Read response from stdin
INPUT=$(cat)

# Extract response text — try multiple JSON paths for compatibility
response_text=""
for path in '.result' '.content' '.result.text' '.message.content'; do
  response_text=$(echo "$INPUT" | jq -r "$path // empty" 2>/dev/null || true)
  [[ -n "$response_text" ]] && break
done

# Parse RALPH_STATUS block fields
exit_signal=$(echo "$response_text" | grep -oP 'EXIT_SIGNAL:\s*\K(true|false)' | tail -1 || echo "false")
status=$(echo "$response_text" | grep -oP 'STATUS:\s*\K\w+' | tail -1 || echo "UNKNOWN")
tasks_done=$(echo "$response_text" | grep -oP 'TASKS_COMPLETED_THIS_LOOP:\s*\K\d+' | tail -1 || echo "0")
files_modified_reported=$(echo "$response_text" | grep -oP 'FILES_MODIFIED:\s*\K\d+' | tail -1 || echo "0")
work_type=$(echo "$response_text" | grep -oP 'WORK_TYPE:\s*\K\w+' | tail -1 || echo "UNKNOWN")
recommendation=$(echo "$response_text" | grep -oP 'RECOMMENDATION:\s*\K.+' | tail -1 || echo "")

# Count actual files modified (from PostToolUse tracking)
actual_files_modified=0
if [[ -f "$RALPH_DIR/.files_modified_this_loop" ]]; then
  actual_files_modified=$(sort -u "$RALPH_DIR/.files_modified_this_loop" | wc -l | tr -d '[:space:]')
fi

# Use the higher of reported vs actual (defense-in-depth)
files_modified=$((files_modified_reported > actual_files_modified ? files_modified_reported : actual_files_modified))

# Update loop count
loop_count=0
if [[ -f "$RALPH_DIR/status.json" ]]; then
  loop_count=$(jq -r '.loop_count // 0' "$RALPH_DIR/status.json" 2>/dev/null || echo "0")
fi
loop_count=$((loop_count + 1))

# Write status.json (atomic write via temp file)
local_tmp=$(mktemp "$RALPH_DIR/status.json.XXXXXX")
cat > "$local_tmp" <<EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "loop_count": $loop_count,
  "status": "${status}",
  "exit_signal": "${exit_signal}",
  "tasks_completed": ${tasks_done},
  "files_modified": ${files_modified},
  "work_type": "${work_type}",
  "recommendation": $(echo "${recommendation}" | jq -Rs .)
}
EOF
mv "$local_tmp" "$RALPH_DIR/status.json"

# Update circuit breaker — check for progress
if [[ "$files_modified" -gt 0 || "$tasks_done" -gt 0 ]]; then
  # Progress detected — reset no-progress counter
  if [[ -f "$RALPH_DIR/.circuit_breaker_state" ]]; then
    local_tmp=$(mktemp "$RALPH_DIR/.circuit_breaker_state.XXXXXX")
    jq '.no_progress_count = 0 | .state = "CLOSED"' \
      "$RALPH_DIR/.circuit_breaker_state" > "$local_tmp" \
      && mv "$local_tmp" "$RALPH_DIR/.circuit_breaker_state"
  fi
else
  # No progress — increment counter
  if [[ -f "$RALPH_DIR/.circuit_breaker_state" ]]; then
    current=$(jq -r '.no_progress_count // 0' "$RALPH_DIR/.circuit_breaker_state" 2>/dev/null || echo "0")
    threshold=$(jq -r '.threshold // 3' "$RALPH_DIR/.circuit_breaker_state" 2>/dev/null || echo "3")
    new_count=$((current + 1))

    local_tmp=$(mktemp "$RALPH_DIR/.circuit_breaker_state.XXXXXX")
    if [[ $new_count -ge $threshold ]]; then
      echo "Circuit breaker OPEN: $new_count loops with no progress" >&2
      jq ".no_progress_count = $new_count | .state = \"OPEN\"" \
        "$RALPH_DIR/.circuit_breaker_state" > "$local_tmp" \
        && mv "$local_tmp" "$RALPH_DIR/.circuit_breaker_state"
    else
      jq ".no_progress_count = $new_count" \
        "$RALPH_DIR/.circuit_breaker_state" > "$local_tmp" \
        && mv "$local_tmp" "$RALPH_DIR/.circuit_breaker_state"
    fi
  fi
fi

# Log for monitoring
echo "[$(date '+%H:%M:%S')] Loop $loop_count: status=$status exit=$exit_signal tasks=$tasks_done files=$files_modified type=$work_type" \
  >> "$RALPH_DIR/live.log"

exit 0
```

### Key Design Decisions

1. **Multiple JSON path fallback:** Tries `.result`, `.content`, `.result.text`,
   `.message.content` to handle different Claude Code output formats.

2. **Actual vs reported files:** Cross-references RALPH_STATUS `FILES_MODIFIED` with
   the PostToolUse-tracked `.files_modified_this_loop`. Uses the higher value for
   progress detection (defense-in-depth).

3. **Atomic writes:** Uses `mktemp` + `mv` pattern for status.json and circuit breaker
   state. Prevents corruption from concurrent reads.

4. **`recommendation` JSON escaping:** Uses `jq -Rs` to safely escape the recommendation
   string for JSON output.

5. **Exit 0 always:** The stop hook should never block Claude from stopping. The bash
   orchestrator handles loop continuation decisions based on `status.json`.

## Testing

```bash
@test "on-stop.sh parses RALPH_STATUS and writes status.json" {
  mkdir -p .ralph
  echo '{"loop_count": 0}' > .ralph/status.json
  echo '{"state": "CLOSED", "no_progress_count": 0, "threshold": 3}' > .ralph/.circuit_breaker_state

  local input='{"result": "Done.\n---RALPH_STATUS---\nSTATUS: IN_PROGRESS\nTASKS_COMPLETED_THIS_LOOP: 1\nFILES_MODIFIED: 3\nTESTS_STATUS: PASSING\nWORK_TYPE: IMPLEMENTATION\nEXIT_SIGNAL: false\nRECOMMENDATION: Implemented auth module\n---END_RALPH_STATUS---"}'

  echo "$input" | bash .ralph/hooks/on-stop.sh

  [[ "$(jq -r '.status' .ralph/status.json)" == "IN_PROGRESS" ]]
  [[ "$(jq -r '.loop_count' .ralph/status.json)" == "1" ]]
  [[ "$(jq -r '.tasks_completed' .ralph/status.json)" == "1" ]]
}

@test "on-stop.sh increments no-progress counter on zero changes" {
  mkdir -p .ralph
  echo '{"loop_count": 2}' > .ralph/status.json
  echo '{"state": "CLOSED", "no_progress_count": 1, "threshold": 3}' > .ralph/.circuit_breaker_state

  echo '{"result": "---RALPH_STATUS---\nSTATUS: IN_PROGRESS\nTASKS_COMPLETED_THIS_LOOP: 0\nFILES_MODIFIED: 0\nEXIT_SIGNAL: false\n---END_RALPH_STATUS---"}' \
    | bash .ralph/hooks/on-stop.sh

  [[ "$(jq -r '.no_progress_count' .ralph/.circuit_breaker_state)" == "2" ]]
}

@test "on-stop.sh opens circuit breaker at threshold" {
  mkdir -p .ralph
  echo '{"loop_count": 4}' > .ralph/status.json
  echo '{"state": "CLOSED", "no_progress_count": 2, "threshold": 3}' > .ralph/.circuit_breaker_state

  echo '{"result": "---RALPH_STATUS---\nSTATUS: IN_PROGRESS\nTASKS_COMPLETED_THIS_LOOP: 0\nFILES_MODIFIED: 0\nEXIT_SIGNAL: false\n---END_RALPH_STATUS---"}' \
    | bash .ralph/hooks/on-stop.sh 2>/dev/null

  [[ "$(jq -r '.state' .ralph/.circuit_breaker_state)" == "OPEN" ]]
}
```

## Acceptance Criteria

- [ ] Hook parses all RALPH_STATUS fields correctly
- [ ] Hook writes atomic `status.json` updates
- [ ] Hook updates circuit breaker state (progress resets, no-progress increments)
- [ ] Hook opens circuit breaker when threshold reached
- [ ] Hook logs to `live.log` for monitoring
- [ ] Hook exits 0 in non-Ralph projects
- [ ] Hook handles missing/malformed RALPH_STATUS gracefully
- [ ] Actual file count cross-referenced with PostToolUse tracking
