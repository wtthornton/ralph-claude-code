#!/bin/bash
# .ralph/hooks/on-subagent-done.sh
# SubagentStop hook. Logs sub-agent completion.

set -euo pipefail

RALPH_DIR="${CLAUDE_PROJECT_DIR:-.}/.ralph"
[[ -d "$RALPH_DIR" ]] || exit 0

INPUT=$(cat)
agent_name=$(echo "$INPUT" | jq -r '.agent_name // "unknown"' 2>/dev/null || echo "unknown")

echo "[$(date '+%H:%M:%S')] SUBAGENT DONE: $agent_name" >> "$RALPH_DIR/live.log"

exit 0
