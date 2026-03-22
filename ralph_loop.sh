#!/bin/bash

# Claude Code Ralph Loop with Rate Limiting and Documentation
# Adaptation of the Ralph technique for Claude Code with usage management

# Note: CLAUDE_CODE_ENABLE_DANGEROUS_PERMISSIONS_IN_SANDBOX and IS_SANDBOX
# environment variables are NOT exported here. Tool restrictions are handled
# via --allowedTools flag in CLAUDE_CMD_ARGS, which is the proper approach.
# Exporting sandbox variables without a verified sandbox would be misleading.

# Source library components
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
source "$SCRIPT_DIR/lib/date_utils.sh" || { echo "FATAL: Failed to source lib/date_utils.sh" >&2; exit 1; }
source "$SCRIPT_DIR/lib/timeout_utils.sh" || { echo "FATAL: Failed to source lib/timeout_utils.sh" >&2; exit 1; }
# response_analyzer.sh removed — response analysis handled by on-stop.sh hook → status.json
source "$SCRIPT_DIR/lib/circuit_breaker.sh" || { echo "FATAL: Failed to source lib/circuit_breaker.sh" >&2; exit 1; }
# file_protection.sh removed — file protection handled by PreToolUse hooks (protect-ralph-files.sh, validate-command.sh)

# Optional library modules (Phase 8+) — fail-open if not present
[[ -f "$SCRIPT_DIR/lib/metrics.sh" ]] && source "$SCRIPT_DIR/lib/metrics.sh"
[[ -f "$SCRIPT_DIR/lib/notifications.sh" ]] && source "$SCRIPT_DIR/lib/notifications.sh"
[[ -f "$SCRIPT_DIR/lib/backup.sh" ]] && source "$SCRIPT_DIR/lib/backup.sh"

# Version
RALPH_VERSION="1.8.2"

# Configuration
# Ralph-specific files live in .ralph/ subfolder
RALPH_DIR=".ralph"
PROMPT_FILE="$RALPH_DIR/PROMPT.md"
LOG_DIR="$RALPH_DIR/logs"
DOCS_DIR="$RALPH_DIR/docs/generated"
STATUS_FILE="$RALPH_DIR/status.json"
PROGRESS_FILE="$RALPH_DIR/progress.json"
CLAUDE_CODE_CMD="claude"
SLEEP_DURATION=3600     # 1 hour in seconds
LIVE_OUTPUT=false       # Show Claude Code output in real-time (streaming)
LIVE_LOG_FILE="$RALPH_DIR/live.log"  # Fixed file for live output monitoring
CALL_COUNT_FILE="$RALPH_DIR/.call_count"
TIMESTAMP_FILE="$RALPH_DIR/.last_reset"
USE_TMUX=false

# Save environment variable state BEFORE setting defaults
# These are used by load_ralphrc() to determine which values came from environment
_env_MAX_CALLS_PER_HOUR="${MAX_CALLS_PER_HOUR:-}"
_env_CLAUDE_TIMEOUT_MINUTES="${CLAUDE_TIMEOUT_MINUTES:-}"
_env_CLAUDE_OUTPUT_FORMAT="${CLAUDE_OUTPUT_FORMAT:-}"
_env_CLAUDE_ALLOWED_TOOLS="${CLAUDE_ALLOWED_TOOLS:-}"
_env_CLAUDE_USE_CONTINUE="${CLAUDE_USE_CONTINUE:-}"
_env_CLAUDE_SESSION_EXPIRY_HOURS="${CLAUDE_SESSION_EXPIRY_HOURS:-}"
_env_VERBOSE_PROGRESS="${VERBOSE_PROGRESS:-}"
_env_CB_COOLDOWN_MINUTES="${CB_COOLDOWN_MINUTES:-}"
_env_CB_AUTO_RESET="${CB_AUTO_RESET:-}"
_env_CLAUDE_CODE_CMD="${CLAUDE_CODE_CMD:-}"
_env_CLAUDE_AUTO_UPDATE="${CLAUDE_AUTO_UPDATE:-}"
_env_DRY_RUN="${DRY_RUN:-}"
_env_LOG_MAX_SIZE_MB="${LOG_MAX_SIZE_MB:-}"
_env_LOG_MAX_FILES="${LOG_MAX_FILES:-}"
_env_LOG_MAX_OUTPUT_FILES="${LOG_MAX_OUTPUT_FILES:-}"

# Now set defaults (only if not already set by environment)
MAX_CALLS_PER_HOUR="${MAX_CALLS_PER_HOUR:-100}"
VERBOSE_PROGRESS="${VERBOSE_PROGRESS:-false}"
CLAUDE_TIMEOUT_MINUTES="${CLAUDE_TIMEOUT_MINUTES:-15}"

# Modern Claude CLI configuration (Phase 1.1)
CLAUDE_OUTPUT_FORMAT="${CLAUDE_OUTPUT_FORMAT:-json}"
# Safe git subcommands only - broad Bash(git *) allows destructive commands like git clean/git rm (Issue #149)
CLAUDE_ALLOWED_TOOLS="${CLAUDE_ALLOWED_TOOLS:-Write,Read,Edit,Bash(git add *),Bash(git commit *),Bash(git diff *),Bash(git log *),Bash(git status),Bash(git status *),Bash(git push *),Bash(git pull *),Bash(git fetch *),Bash(git checkout *),Bash(git branch *),Bash(git stash *),Bash(git merge *),Bash(git tag *),Bash(git -C *),Bash(grep *),Bash(find *),Bash(npm *),Bash(pytest),Bash(xargs *),Bash(sort *),Bash(tee *),Bash(rm *),Bash(touch *),Bash(sed *),Bash(awk *),Bash(tr *),Bash(cut *),Bash(dirname *),Bash(basename *),Bash(realpath *),Bash(test *),Bash(true),Bash(false),Bash(sleep *),Bash(ls *),Bash(cat *),Bash(wc *),Bash(head *),Bash(tail *),Bash(mkdir *),Bash(cp *),Bash(mv *)}"
CLAUDE_USE_CONTINUE="${CLAUDE_USE_CONTINUE:-true}"
CLAUDE_SESSION_FILE="$RALPH_DIR/.claude_session_id" # Session ID persistence file
CLAUDE_MIN_VERSION="2.0.76"              # Minimum required Claude CLI version
CLAUDE_AUTO_UPDATE="${CLAUDE_AUTO_UPDATE:-true}"  # Auto-update Claude CLI at startup

# Session management configuration (Phase 1.2)
SESSION_EXPIRATION_SECONDS=86400  # 24 hours
SESSION_FILE="$RALPH_DIR/.claude_session_id"
RALPH_SESSION_FILE="$RALPH_DIR/.ralph_session"              # Ralph-specific session tracking (lifecycle)
RALPH_SESSION_HISTORY_FILE="$RALPH_DIR/.ralph_session_history"  # Session transition history
# Session expiration: 24 hours default balances project continuity with fresh context
# Too short = frequent context loss; Too long = stale context causes unpredictable behavior
CLAUDE_SESSION_EXPIRY_HOURS=${CLAUDE_SESSION_EXPIRY_HOURS:-24}

# Valid tool patterns for --allowed-tools validation
# Tools can be exact matches or pattern matches with wildcards in parentheses
VALID_TOOL_PATTERNS=(
    "Write"
    "Read"
    "Edit"
    "MultiEdit"
    "Glob"
    "Grep"
    "Task"
    "TodoWrite"
    "WebFetch"
    "WebSearch"
    "Bash"
    "Bash(git *)"
    "Bash(npm *)"
    "Bash(bats *)"
    "Bash(python *)"
    "Bash(node *)"
    "NotebookEdit"
)

# Exit detection configuration
EXIT_SIGNALS_FILE="$RALPH_DIR/.exit_signals"
# Response analysis now handled by on-stop.sh hook → status.json (SKILLS-3)
MAX_CONSECUTIVE_TEST_LOOPS=3
MAX_CONSECUTIVE_DONE_SIGNALS=2
TEST_PERCENTAGE_THRESHOLD=30  # If more than 30% of recent loops are test-only, flag it

# Configuration files
RALPHRC_FILE=".ralphrc"
RALPHRC_LOADED=false
JSON_CONFIG_FILE="ralph.config.json"
JSON_CONFIG_LOADED=false

# load_ralphrc - Load project-specific configuration from .ralphrc
#
# This function sources .ralphrc if it exists, applying project-specific
# settings. Environment variables take precedence over .ralphrc values.
#
# Configuration values that can be overridden:
#   - MAX_CALLS_PER_HOUR
#   - CLAUDE_TIMEOUT_MINUTES
#   - CLAUDE_OUTPUT_FORMAT
#   - ALLOWED_TOOLS (mapped to CLAUDE_ALLOWED_TOOLS)
#   - SESSION_CONTINUITY (mapped to CLAUDE_USE_CONTINUE)
#   - SESSION_EXPIRY_HOURS (mapped to CLAUDE_SESSION_EXPIRY_HOURS)
#   - CB_NO_PROGRESS_THRESHOLD
#   - CB_SAME_ERROR_THRESHOLD
#   - CB_OUTPUT_DECLINE_THRESHOLD
#   - RALPH_VERBOSE
#   - CLAUDE_CODE_CMD (path or command for Claude Code CLI)
#   - CLAUDE_AUTO_UPDATE (auto-update Claude CLI at startup)
#
load_ralphrc() {
    if [[ ! -f "$RALPHRC_FILE" ]]; then
        return 0
    fi

    # Source .ralphrc (this may override default values)
    # shellcheck source=/dev/null
    source "$RALPHRC_FILE"

    # Map .ralphrc variable names to internal names
    if [[ -n "${ALLOWED_TOOLS:-}" ]]; then
        CLAUDE_ALLOWED_TOOLS="$ALLOWED_TOOLS"
    fi
    if [[ -n "${SESSION_CONTINUITY:-}" ]]; then
        CLAUDE_USE_CONTINUE="$SESSION_CONTINUITY"
    fi
    if [[ -n "${SESSION_EXPIRY_HOURS:-}" ]]; then
        CLAUDE_SESSION_EXPIRY_HOURS="$SESSION_EXPIRY_HOURS"
    fi
    if [[ -n "${RALPH_VERBOSE:-}" ]]; then
        VERBOSE_PROGRESS="$RALPH_VERBOSE"
    fi

    # Restore ONLY values that were explicitly set via environment variables
    # (not script defaults). The _env_* variables were captured BEFORE defaults were set.
    # If _env_* is non-empty, the user explicitly set it in their environment.
    [[ -n "$_env_MAX_CALLS_PER_HOUR" ]] && MAX_CALLS_PER_HOUR="$_env_MAX_CALLS_PER_HOUR"
    [[ -n "$_env_CLAUDE_TIMEOUT_MINUTES" ]] && CLAUDE_TIMEOUT_MINUTES="$_env_CLAUDE_TIMEOUT_MINUTES"
    [[ -n "$_env_CLAUDE_OUTPUT_FORMAT" ]] && CLAUDE_OUTPUT_FORMAT="$_env_CLAUDE_OUTPUT_FORMAT"
    [[ -n "$_env_CLAUDE_ALLOWED_TOOLS" ]] && CLAUDE_ALLOWED_TOOLS="$_env_CLAUDE_ALLOWED_TOOLS"
    [[ -n "$_env_CLAUDE_USE_CONTINUE" ]] && CLAUDE_USE_CONTINUE="$_env_CLAUDE_USE_CONTINUE"
    [[ -n "$_env_CLAUDE_SESSION_EXPIRY_HOURS" ]] && CLAUDE_SESSION_EXPIRY_HOURS="$_env_CLAUDE_SESSION_EXPIRY_HOURS"
    [[ -n "$_env_VERBOSE_PROGRESS" ]] && VERBOSE_PROGRESS="$_env_VERBOSE_PROGRESS"
    [[ -n "$_env_CB_COOLDOWN_MINUTES" ]] && CB_COOLDOWN_MINUTES="$_env_CB_COOLDOWN_MINUTES"
    [[ -n "$_env_CB_AUTO_RESET" ]] && CB_AUTO_RESET="$_env_CB_AUTO_RESET"
    [[ -n "$_env_CLAUDE_CODE_CMD" ]] && CLAUDE_CODE_CMD="$_env_CLAUDE_CODE_CMD"
    [[ -n "$_env_CLAUDE_AUTO_UPDATE" ]] && CLAUDE_AUTO_UPDATE="$_env_CLAUDE_AUTO_UPDATE"
    [[ -n "$_env_DRY_RUN" ]] && DRY_RUN="$_env_DRY_RUN"
    [[ -n "$_env_LOG_MAX_SIZE_MB" ]] && LOG_MAX_SIZE_MB="$_env_LOG_MAX_SIZE_MB"
    [[ -n "$_env_LOG_MAX_FILES" ]] && LOG_MAX_FILES="$_env_LOG_MAX_FILES"
    [[ -n "$_env_LOG_MAX_OUTPUT_FILES" ]] && LOG_MAX_OUTPUT_FILES="$_env_LOG_MAX_OUTPUT_FILES"

    RALPHRC_LOADED=true
    return 0
}

# load_json_config - Load JSON configuration from ralph.config.json
#
# JSON config takes precedence over .ralphrc when both exist.
# Environment variables still override JSON config.
# Requires jq for parsing.
#
load_json_config() {
    if [[ ! -f "$JSON_CONFIG_FILE" ]]; then
        return 0
    fi

    # Check jq availability
    if ! command -v jq &>/dev/null; then
        log_status "WARN" "ralph.config.json found but jq not installed — skipping JSON config"
        return 0
    fi

    # Validate JSON
    if ! jq empty "$JSON_CONFIG_FILE" 2>/dev/null; then
        log_status "WARN" "ralph.config.json is invalid JSON — skipping"
        return 0
    fi

    # Read values (JSON overrides .ralphrc)
    local val

    val=$(jq -r '.projectName // empty' "$JSON_CONFIG_FILE" 2>/dev/null)
    [[ -n "$val" ]] && PROJECT_NAME="$val"

    val=$(jq -r '.projectType // empty' "$JSON_CONFIG_FILE" 2>/dev/null)
    [[ -n "$val" ]] && PROJECT_TYPE="$val"

    val=$(jq -r '.maxCallsPerHour // empty' "$JSON_CONFIG_FILE" 2>/dev/null)
    [[ -n "$val" ]] && MAX_CALLS_PER_HOUR="$val"

    val=$(jq -r '.timeoutMinutes // empty' "$JSON_CONFIG_FILE" 2>/dev/null)
    [[ -n "$val" ]] && CLAUDE_TIMEOUT_MINUTES="$val"

    val=$(jq -r '.outputFormat // empty' "$JSON_CONFIG_FILE" 2>/dev/null)
    [[ -n "$val" ]] && CLAUDE_OUTPUT_FORMAT="$val"

    val=$(jq -r 'if .allowedTools then (.allowedTools | join(",")) else empty end' "$JSON_CONFIG_FILE" 2>/dev/null)
    [[ -n "$val" ]] && CLAUDE_ALLOWED_TOOLS="$val"

    val=$(jq -r '.sessionContinuity // empty' "$JSON_CONFIG_FILE" 2>/dev/null)
    [[ -n "$val" ]] && CLAUDE_USE_CONTINUE="$val"

    val=$(jq -r '.sessionExpiryHours // empty' "$JSON_CONFIG_FILE" 2>/dev/null)
    [[ -n "$val" ]] && CLAUDE_SESSION_EXPIRY_HOURS="$val"

    val=$(jq -r '.cbNoProgressThreshold // empty' "$JSON_CONFIG_FILE" 2>/dev/null)
    [[ -n "$val" ]] && CB_NO_PROGRESS_THRESHOLD="$val"

    val=$(jq -r '.cbCooldownMinutes // empty' "$JSON_CONFIG_FILE" 2>/dev/null)
    [[ -n "$val" ]] && CB_COOLDOWN_MINUTES="$val"

    val=$(jq -r '.cbAutoReset // empty' "$JSON_CONFIG_FILE" 2>/dev/null)
    [[ -n "$val" ]] && CB_AUTO_RESET="$val"

    val=$(jq -r '.logMaxSizeMb // empty' "$JSON_CONFIG_FILE" 2>/dev/null)
    [[ -n "$val" ]] && LOG_MAX_SIZE_MB="$val"

    val=$(jq -r '.logMaxFiles // empty' "$JSON_CONFIG_FILE" 2>/dev/null)
    [[ -n "$val" ]] && LOG_MAX_FILES="$val"

    val=$(jq -r '.logMaxOutputFiles // empty' "$JSON_CONFIG_FILE" 2>/dev/null)
    [[ -n "$val" ]] && LOG_MAX_OUTPUT_FILES="$val"

    val=$(jq -r '.dryRun // empty' "$JSON_CONFIG_FILE" 2>/dev/null)
    [[ -n "$val" ]] && DRY_RUN="$val"

    val=$(jq -r '.claudeAutoUpdate // empty' "$JSON_CONFIG_FILE" 2>/dev/null)
    [[ -n "$val" ]] && CLAUDE_AUTO_UPDATE="$val"

    val=$(jq -r '.verbose // empty' "$JSON_CONFIG_FILE" 2>/dev/null)
    [[ -n "$val" ]] && VERBOSE_PROGRESS="$val"

    val=$(jq -r '.agentName // empty' "$JSON_CONFIG_FILE" 2>/dev/null)
    [[ -n "$val" ]] && RALPH_AGENT_NAME="$val"

    val=$(jq -r '.useAgent // empty' "$JSON_CONFIG_FILE" 2>/dev/null)
    [[ -n "$val" ]] && RALPH_USE_AGENT="$val"

    val=$(jq -r '.enableTeams // empty' "$JSON_CONFIG_FILE" 2>/dev/null)
    [[ -n "$val" ]] && RALPH_ENABLE_TEAMS="$val"

    val=$(jq -r '.maxTeammates // empty' "$JSON_CONFIG_FILE" 2>/dev/null)
    [[ -n "$val" ]] && RALPH_MAX_TEAMMATES="$val"

    # Notification settings (Phase 8)
    val=$(jq -r '.notifications.webhookUrl // empty' "$JSON_CONFIG_FILE" 2>/dev/null)
    [[ -n "$val" ]] && RALPH_WEBHOOK_URL="$val"

    val=$(jq -r '.notifications.sound // empty' "$JSON_CONFIG_FILE" 2>/dev/null)
    [[ -n "$val" ]] && RALPH_NOTIFY_SOUND="$val"

    # GitHub settings (Phase 10)
    val=$(jq -r '.github.autoCloseIssues // empty' "$JSON_CONFIG_FILE" 2>/dev/null)
    [[ -n "$val" ]] && RALPH_AUTO_CLOSE_ISSUES="$val"

    val=$(jq -r '.github.taskLabel // empty' "$JSON_CONFIG_FILE" 2>/dev/null)
    [[ -n "$val" ]] && GITHUB_TASK_LABEL="$val"

    # Sandbox settings (Phase 11)
    val=$(jq -r '.sandbox.required // empty' "$JSON_CONFIG_FILE" 2>/dev/null)
    [[ -n "$val" ]] && RALPH_SANDBOX_REQUIRED="$val"

    val=$(jq -r '.sandbox.cpuLimit // empty' "$JSON_CONFIG_FILE" 2>/dev/null)
    [[ -n "$val" ]] && RALPH_SANDBOX_CPU_LIMIT="$val"

    val=$(jq -r '.sandbox.memoryLimit // empty' "$JSON_CONFIG_FILE" 2>/dev/null)
    [[ -n "$val" ]] && RALPH_SANDBOX_MEMORY_LIMIT="$val"

    # Backup settings (Phase 8)
    val=$(jq -r '.backup.maxBackups // empty' "$JSON_CONFIG_FILE" 2>/dev/null)
    [[ -n "$val" ]] && RALPH_MAX_BACKUPS="$val"

    # Restore env overrides (same pattern as load_ralphrc)
    [[ -n "$_env_MAX_CALLS_PER_HOUR" ]] && MAX_CALLS_PER_HOUR="$_env_MAX_CALLS_PER_HOUR"
    [[ -n "$_env_CLAUDE_TIMEOUT_MINUTES" ]] && CLAUDE_TIMEOUT_MINUTES="$_env_CLAUDE_TIMEOUT_MINUTES"
    [[ -n "$_env_CLAUDE_OUTPUT_FORMAT" ]] && CLAUDE_OUTPUT_FORMAT="$_env_CLAUDE_OUTPUT_FORMAT"
    [[ -n "$_env_CLAUDE_ALLOWED_TOOLS" ]] && CLAUDE_ALLOWED_TOOLS="$_env_CLAUDE_ALLOWED_TOOLS"
    [[ -n "$_env_CLAUDE_USE_CONTINUE" ]] && CLAUDE_USE_CONTINUE="$_env_CLAUDE_USE_CONTINUE"
    [[ -n "$_env_CLAUDE_SESSION_EXPIRY_HOURS" ]] && CLAUDE_SESSION_EXPIRY_HOURS="$_env_CLAUDE_SESSION_EXPIRY_HOURS"
    [[ -n "$_env_VERBOSE_PROGRESS" ]] && VERBOSE_PROGRESS="$_env_VERBOSE_PROGRESS"
    [[ -n "$_env_CB_COOLDOWN_MINUTES" ]] && CB_COOLDOWN_MINUTES="$_env_CB_COOLDOWN_MINUTES"
    [[ -n "$_env_CB_AUTO_RESET" ]] && CB_AUTO_RESET="$_env_CB_AUTO_RESET"
    [[ -n "$_env_CLAUDE_CODE_CMD" ]] && CLAUDE_CODE_CMD="$_env_CLAUDE_CODE_CMD"
    [[ -n "$_env_CLAUDE_AUTO_UPDATE" ]] && CLAUDE_AUTO_UPDATE="$_env_CLAUDE_AUTO_UPDATE"
    [[ -n "$_env_DRY_RUN" ]] && DRY_RUN="$_env_DRY_RUN"
    [[ -n "$_env_LOG_MAX_SIZE_MB" ]] && LOG_MAX_SIZE_MB="$_env_LOG_MAX_SIZE_MB"
    [[ -n "$_env_LOG_MAX_FILES" ]] && LOG_MAX_FILES="$_env_LOG_MAX_FILES"
    [[ -n "$_env_LOG_MAX_OUTPUT_FILES" ]] && LOG_MAX_OUTPUT_FILES="$_env_LOG_MAX_OUTPUT_FILES"

    JSON_CONFIG_LOADED=true
    return 0
}

# ralph_export_config - Export current config as JSON
#
# Usage: ralph config --format json
#
ralph_export_config() {
    local format="${1:-json}"
    if [[ "$format" != "json" ]]; then
        echo "Error: Only JSON format supported for config export"
        return 1
    fi

    if ! command -v jq &>/dev/null; then
        # Fallback without jq
        cat << JSONEOF
{
  "projectName": "${PROJECT_NAME:-my-project}",
  "maxCallsPerHour": ${MAX_CALLS_PER_HOUR:-100},
  "timeoutMinutes": ${CLAUDE_TIMEOUT_MINUTES:-15},
  "outputFormat": "${CLAUDE_OUTPUT_FORMAT:-json}",
  "sessionContinuity": ${CLAUDE_USE_CONTINUE:-true},
  "cbCooldownMinutes": ${CB_COOLDOWN_MINUTES:-30},
  "cbAutoReset": ${CB_AUTO_RESET:-false},
  "dryRun": ${DRY_RUN:-false},
  "verbose": ${VERBOSE_PROGRESS:-false}
}
JSONEOF
        return 0
    fi

    jq -n \
        --arg pn "${PROJECT_NAME:-my-project}" \
        --arg pt "${PROJECT_TYPE:-unknown}" \
        --argjson mc "${MAX_CALLS_PER_HOUR:-100}" \
        --argjson tm "${CLAUDE_TIMEOUT_MINUTES:-15}" \
        --arg of "${CLAUDE_OUTPUT_FORMAT:-json}" \
        --argjson sc "${CLAUDE_USE_CONTINUE:-true}" \
        --argjson seh "${CLAUDE_SESSION_EXPIRY_HOURS:-24}" \
        --argjson cbcm "${CB_COOLDOWN_MINUTES:-30}" \
        --argjson cbar "${CB_AUTO_RESET:-false}" \
        --argjson lms "${LOG_MAX_SIZE_MB:-10}" \
        --argjson lmf "${LOG_MAX_FILES:-5}" \
        --argjson dr "${DRY_RUN:-false}" \
        --argjson v "${VERBOSE_PROGRESS:-false}" \
        '{
            projectName: $pn,
            projectType: $pt,
            maxCallsPerHour: $mc,
            timeoutMinutes: $tm,
            outputFormat: $of,
            sessionContinuity: $sc,
            sessionExpiryHours: $seh,
            cbCooldownMinutes: $cbcm,
            cbAutoReset: $cbar,
            logMaxSizeMb: $lms,
            logMaxFiles: $lmf,
            dryRun: $dr,
            verbose: $v
        }'
}

# validate_claude_command - Verify the Claude Code CLI is available
#
# Checks that CLAUDE_CODE_CMD resolves to an executable command.
# For npx-based commands, validates that npx is available.
# Returns 0 if valid, 1 if not found (with helpful error message).
#
validate_claude_command() {
    local cmd="$CLAUDE_CODE_CMD"

    # For npx-based commands, check that npx itself is available
    if [[ "$cmd" == npx\ * ]] || [[ "$cmd" == "npx" ]]; then
        if ! command -v npx &>/dev/null; then
            echo ""
            echo -e "${RED}╔════════════════════════════════════════════════════════════╗${NC}"
            echo -e "${RED}║  NPX NOT FOUND                                            ║${NC}"
            echo -e "${RED}╚════════════════════════════════════════════════════════════╝${NC}"
            echo ""
            echo -e "${YELLOW}CLAUDE_CODE_CMD is set to use npx, but npx is not installed.${NC}"
            echo ""
            echo -e "${YELLOW}To fix this:${NC}"
            echo "  1. Install Node.js (includes npx): https://nodejs.org"
            echo "  2. Or install Claude Code globally:"
            echo "     npm install -g @anthropic-ai/claude-code"
            echo "     Then set in .ralphrc: CLAUDE_CODE_CMD=\"claude\""
            echo ""
            return 1
        fi
        return 0
    fi

    # For direct commands, check that the command exists
    if ! command -v "$cmd" &>/dev/null; then
        echo ""
        echo -e "${RED}╔════════════════════════════════════════════════════════════╗${NC}"
        echo -e "${RED}║  CLAUDE CODE CLI NOT FOUND                                ║${NC}"
        echo -e "${RED}╚════════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "${YELLOW}The Claude Code CLI command '${cmd}' is not available.${NC}"
        echo ""
        echo -e "${YELLOW}Installation options:${NC}"
        echo "  1. Install globally (recommended):"
        echo "     npm install -g @anthropic-ai/claude-code"
        echo ""
        echo "  2. Use npx (no global install needed):"
        echo "     Add to .ralphrc: CLAUDE_CODE_CMD=\"npx @anthropic-ai/claude-code\""
        echo ""
        echo -e "${YELLOW}Current configuration:${NC} CLAUDE_CODE_CMD=\"${cmd}\""
        echo ""
        echo -e "${YELLOW}After installation or configuration:${NC}"
        echo "  ralph --monitor  # Restart Ralph"
        echo ""
        return 1
    fi

    return 0
}

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m' # No Color

# Initialize directories
mkdir -p "$LOG_DIR" "$DOCS_DIR"

# Check if tmux is available
check_tmux_available() {
    if ! command -v tmux &> /dev/null; then
        log_status "ERROR" "tmux is not installed. Please install tmux or run without --monitor flag."
        echo "Install tmux:"
        echo "  Ubuntu/Debian: sudo apt-get install tmux"
        echo "  macOS: brew install tmux"
        echo "  CentOS/RHEL: sudo yum install tmux"
        exit 1
    fi
}

# Get the tmux base-index for windows (handles custom tmux configurations)
# Returns: the base window index (typically 0 or 1)
get_tmux_base_index() {
    local base_index
    base_index=$(tmux show-options -gv base-index 2>/dev/null)
    # Default to 0 if not set or tmux command fails
    echo "${base_index:-0}"
}

# Setup tmux session with monitor
setup_tmux_session() {
    local session_name="ralph-$(date +%s)"
    local ralph_home="${RALPH_HOME:-$HOME/.ralph}"
    local project_dir="$(pwd)"

    # Get the tmux base-index to handle custom configurations (e.g., base-index 1)
    local base_win
    base_win=$(get_tmux_base_index)

    log_status "INFO" "Setting up tmux session: $session_name"

    # Initialize live.log file
    echo "=== Ralph Live Output - Waiting for first loop... ===" > "$LIVE_LOG_FILE"

    # Create new tmux session detached (left pane - Ralph loop)
    tmux new-session -d -s "$session_name" -c "$project_dir"

    # Split window vertically (right side)
    tmux split-window -h -t "$session_name" -c "$project_dir"

    # Split right pane horizontally (top: Claude output, bottom: status)
    tmux split-window -v -t "$session_name:${base_win}.1" -c "$project_dir"

    # Right-top pane (pane 1): Live Claude Code output
    tmux send-keys -t "$session_name:${base_win}.1" "tail -f '$project_dir/$LIVE_LOG_FILE'" Enter

    # Right-bottom pane (pane 2): Ralph status monitor
    if command -v ralph-monitor &> /dev/null; then
        tmux send-keys -t "$session_name:${base_win}.2" "ralph-monitor" Enter
    else
        tmux send-keys -t "$session_name:${base_win}.2" "'$ralph_home/ralph_monitor.sh'" Enter
    fi

    # Start ralph loop in the left pane (exclude tmux flag to avoid recursion)
    # Forward all CLI parameters that were set by the user
    local ralph_cmd
    if command -v ralph &> /dev/null; then
        ralph_cmd="ralph"
    else
        ralph_cmd="'$ralph_home/ralph_loop.sh'"
    fi

    # Always use --live mode in tmux for real-time streaming
    ralph_cmd="$ralph_cmd --live"

    # Forward --calls if non-default
    if [[ "$MAX_CALLS_PER_HOUR" != "100" ]]; then
        ralph_cmd="$ralph_cmd --calls $MAX_CALLS_PER_HOUR"
    fi
    # Forward --prompt if non-default
    if [[ "$PROMPT_FILE" != "$RALPH_DIR/PROMPT.md" ]]; then
        ralph_cmd="$ralph_cmd --prompt '$PROMPT_FILE'"
    fi
    # Forward --output-format if non-default (default is json)
    if [[ "$CLAUDE_OUTPUT_FORMAT" != "json" ]]; then
        ralph_cmd="$ralph_cmd --output-format $CLAUDE_OUTPUT_FORMAT"
    fi
    # Forward --verbose if enabled
    if [[ "$VERBOSE_PROGRESS" == "true" ]]; then
        ralph_cmd="$ralph_cmd --verbose"
    fi
    # Forward --timeout if non-default (default is 15)
    if [[ "$CLAUDE_TIMEOUT_MINUTES" != "15" ]]; then
        ralph_cmd="$ralph_cmd --timeout $CLAUDE_TIMEOUT_MINUTES"
    fi
    # Forward --allowed-tools if non-default
    # Safe git subcommands only - broad Bash(git *) allows destructive commands like git clean/git rm (Issue #149)
    if [[ "$CLAUDE_ALLOWED_TOOLS" != "Write,Read,Edit,Bash(git add *),Bash(git commit *),Bash(git diff *),Bash(git log *),Bash(git status),Bash(git status *),Bash(git push *),Bash(git pull *),Bash(git fetch *),Bash(git checkout *),Bash(git branch *),Bash(git stash *),Bash(git merge *),Bash(git tag *),Bash(git -C *),Bash(grep *),Bash(find *),Bash(npm *),Bash(pytest)" ]]; then
        ralph_cmd="$ralph_cmd --allowed-tools '$CLAUDE_ALLOWED_TOOLS'"
    fi
    # Forward --no-continue if session continuity disabled
    if [[ "$CLAUDE_USE_CONTINUE" == "false" ]]; then
        ralph_cmd="$ralph_cmd --no-continue"
    fi
    # Forward --session-expiry if non-default (default is 24)
    if [[ "$CLAUDE_SESSION_EXPIRY_HOURS" != "24" ]]; then
        ralph_cmd="$ralph_cmd --session-expiry $CLAUDE_SESSION_EXPIRY_HOURS"
    fi
    # Forward --auto-reset-circuit if enabled
    if [[ "$CB_AUTO_RESET" == "true" ]]; then
        ralph_cmd="$ralph_cmd --auto-reset-circuit"
    fi

    # Chain tmux kill-session after the loop command so the entire tmux
    # session is torn down when the Ralph loop exits (graceful completion,
    # circuit breaker, error, or manual interrupt). Without this, the
    # tail -f and ralph_monitor.sh panes keep the session alive forever.
    # Issue: https://github.com/frankbria/ralph-claude-code/issues/176
    tmux send-keys -t "$session_name:${base_win}.0" "$ralph_cmd; tmux kill-session -t $session_name 2>/dev/null" Enter

    # Focus on left pane (main ralph loop)
    tmux select-pane -t "$session_name:${base_win}.0"

    # Set pane titles (requires tmux 2.6+)
    tmux select-pane -t "$session_name:${base_win}.0" -T "Ralph Loop"
    tmux select-pane -t "$session_name:${base_win}.1" -T "Claude Output"
    tmux select-pane -t "$session_name:${base_win}.2" -T "Status"

    # Set window title
    tmux rename-window -t "$session_name:${base_win}" "Ralph: Loop | Output | Status"

    log_status "SUCCESS" "Tmux session created with 3 panes:"
    log_status "INFO" "  Left:         Ralph loop"
    log_status "INFO" "  Right-top:    Claude Code live output"
    log_status "INFO" "  Right-bottom: Status monitor"
    log_status "INFO" ""
    log_status "INFO" "Use Ctrl+B then D to detach from session"
    log_status "INFO" "Use 'tmux attach -t $session_name' to reattach"

    # Attach to session (this will block until session ends)
    tmux attach-session -t "$session_name"

    exit 0
}

# Initialize call tracking
init_call_tracking() {
    # Debug logging removed for cleaner output
    local current_hour=$(date +%Y%m%d%H)
    local last_reset_hour=""

    if [[ -f "$TIMESTAMP_FILE" ]]; then
        last_reset_hour=$(cat "$TIMESTAMP_FILE")
    fi

    # Reset counter if it's a new hour
    if [[ "$current_hour" != "$last_reset_hour" ]]; then
        echo "0" > "$CALL_COUNT_FILE"
        echo "$current_hour" > "$TIMESTAMP_FILE"
        log_status "INFO" "Call counter reset for new hour: $current_hour"
    fi

    # Initialize exit signals tracking if it doesn't exist
    if [[ ! -f "$EXIT_SIGNALS_FILE" ]]; then
        echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": []}' > "$EXIT_SIGNALS_FILE"
    fi

    # Initialize circuit breaker
    init_circuit_breaker

}

# Log function with timestamps and colors
log_status() {
    local level=$1
    local message=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local color=""
    
    case $level in
        "INFO")  color=$BLUE ;;
        "WARN")  color=$YELLOW ;;
        "ERROR") color=$RED ;;
        "SUCCESS") color=$GREEN ;;
        "LOOP") color=$PURPLE ;;
    esac
    
    # Write to stderr so log messages don't interfere with function return values
    # 2>/dev/null suppresses "Input/output error" when tmux pty is broken (Issue #188)
    echo -e "${color}[$timestamp] [$level] $message${NC}" >&2 2>/dev/null
    echo "[$timestamp] [$level] $message" >> "$LOG_DIR/ralph.log" 2>/dev/null
}

# Pre-analysis: log permission denials from raw output
ralph_log_permission_denials_from_raw_output() {
    local output_file=$1
    [[ -f "$output_file" ]] || return 0

    # Aggregate permission_denials from ALL result objects (not just last)
    local _denial_count=0
    local _denied_cmds=""

    while IFS= read -r _result_line; do
        local _line_denials
        _line_denials=$(echo "$_result_line" | jq '.permission_denials | if . then length else 0 end' 2>/dev/null || echo "0")
        _line_denials=$((_line_denials + 0))
        _denial_count=$((_denial_count + _line_denials))

        if [[ $_line_denials -gt 0 ]]; then
            local _line_cmds
            _line_cmds=$(echo "$_result_line" | jq -r \
                '[.permission_denials[] |
                  if .tool_name == "Bash"
                  then "Bash(\(.tool_input.command // "?" | split("\n")[0] | .[0:60]))"
                  else .tool_name // "unknown"
                  end
                ] | join(", ")' 2>/dev/null || echo "unknown")
            if [[ -n "$_denied_cmds" ]]; then
                _denied_cmds="$_denied_cmds, $_line_cmds"
            else
                _denied_cmds="$_line_cmds"
            fi
        fi
    done < <(grep -E '"type"[[:space:]]*:[[:space:]]*"result"' "$output_file" 2>/dev/null)

    [[ $_denial_count -gt 0 ]] || return 0

    log_status "WARN" "Permission denied for $_denial_count command(s): $_denied_cmds"
    log_status "WARN" "Update ALLOWED_TOOLS in .ralphrc to include the required tools"
}

# Pre-analysis: if stream is still multi-value JSONL, collapse to last result object
# STREAM-1: Renamed from ralph_emergency_jsonl_normalize — JSONL is the primary path since CLI v2.1+
ralph_extract_result_from_stream() {
    local output_file=$1
    [[ -f "$output_file" ]] || return 0
    local _tl_count
    # Count top-level JSON objects by counting "type" keys (streaming — no memory load)
    # Avoids jq -s which loads entire file into memory and crashes on large JSONL streams
    _tl_count=$(grep -c -E '"type"[[:space:]]*:' "$output_file" 2>/dev/null || echo "1")
    _tl_count=$(echo "$_tl_count" | tr -d '[:space:]')
    _tl_count=$((_tl_count + 0))
    [[ "$_tl_count" -gt 1 ]] || return 0

    # STREAM-2: Count only top-level result objects — subagent results contain a
    # subagent or parent_tool_use_id field and should not trigger multi-task warnings
    local _result_count _toplevel_count
    _result_count=$(grep -c -E '"type"[[:space:]]*:[[:space:]]*"result"' "$output_file" 2>/dev/null || echo "0")
    _result_count=$(echo "$_result_count" | tr -d '[:space:]')
    _result_count=$((_result_count + 0))
    _toplevel_count=$(jq -c 'select(.type == "result") | select(.subagent == null and .parent_tool_use_id == null)' "$output_file" 2>/dev/null | wc -l || echo "$_result_count")
    _toplevel_count=$(echo "$_toplevel_count" | tr -d '[:space:]')
    _toplevel_count=$((_toplevel_count + 0))

    if [[ "$_toplevel_count" -gt 1 ]]; then
        log_status "WARN" "Stream contains $_toplevel_count top-level result objects (expected 1). Multi-task loop violation detected."
    elif [[ "$_result_count" -gt 1 ]]; then
        log_status "INFO" "Stream contains $_result_count result objects ($_toplevel_count top-level, $((_result_count - _toplevel_count)) subagent)"
    fi

    local _extracted_result
    _extracted_result=$(jq -c 'select(.type == "result")' "$output_file" 2>/dev/null | tail -1)

    if [[ -n "$_extracted_result" ]] && echo "$_extracted_result" | jq -e . >/dev/null 2>&1; then
        local _backup="${output_file%.log}_stream.log"
        if [[ ! -f "$_backup" ]]; then
            cp "$output_file" "$_backup"
            log_status "INFO" "Created stream backup: $_backup"
        fi
        echo "$_extracted_result" > "$output_file"
        log_status "INFO" "Stream extraction: isolated result object from JSONL stream (extraction_method=stream)"
    else
        log_status "ERROR" "Stream extraction failed: no valid result object in stream"
    fi
}

# Post-run: log MCP servers that failed to connect (from system init line in stream-json)
ralph_log_failed_mcp_servers_from_output() {
    local output_file=$1
    [[ -f "$output_file" ]] || return 0
    local sys_line
    sys_line=$(grep -E '"type"[[:space:]]*:[[:space:]]*"system"' "$output_file" 2>/dev/null | head -1)
    [[ -n "$sys_line" ]] || return 0
    local failed_mcps
    failed_mcps=$(echo "$sys_line" | jq -r '[.mcp_servers[]? | select(.status == "failed") | .name] | join(", ")' 2>/dev/null)
    [[ -n "$failed_mcps" && "$failed_mcps" != "null" ]] || return 0
    log_status "WARN" "MCP servers failed to connect: $failed_mcps"
}

# Run all lightweight pre-analyze steps on Claude output
ralph_prepare_claude_output_for_analysis() {
    local output_file=$1
    # Log from full stream before extraction removes system / multi-line context
    ralph_log_permission_denials_from_raw_output "$output_file"
    ralph_log_failed_mcp_servers_from_output "$output_file"
    ralph_extract_result_from_stream "$output_file"
}

# =============================================================================
# SESSION PERSISTENCE FUNCTIONS (moved from lib/response_analyzer.sh)
# =============================================================================

# Store session ID to file with timestamp
store_session_id() {
    local session_id=$1
    [[ -z "$session_id" ]] && return 1
    jq -n \
        --arg session_id "$session_id" \
        --arg timestamp "$(get_iso_timestamp)" \
        '{ session_id: $session_id, timestamp: $timestamp }' > "$SESSION_FILE"
    return 0
}

# Get the last stored session ID
get_last_session_id() {
    if [[ ! -f "$SESSION_FILE" ]]; then
        echo ""
        return 0
    fi
    jq -r '.session_id // ""' "$SESSION_FILE" 2>/dev/null
    return 0
}

# Check if the stored session should be resumed
should_resume_session() {
    if [[ ! -f "$SESSION_FILE" ]]; then
        echo "false"
        return 1
    fi

    local timestamp
    timestamp=$(jq -r '.timestamp // ""' "$SESSION_FILE" 2>/dev/null)
    if [[ -z "$timestamp" ]]; then
        echo "false"
        return 1
    fi

    local now session_time clean_timestamp
    now=$(get_epoch_seconds)
    clean_timestamp="${timestamp}"
    if [[ "$timestamp" =~ \.[0-9]+[+-Z] ]]; then
        clean_timestamp=$(echo "$timestamp" | sed 's/\.[0-9]*\([+-Z]\)/\1/')
    fi

    if command -v gdate &>/dev/null; then
        session_time=$(gdate -d "$clean_timestamp" +%s 2>/dev/null)
    elif date --version 2>&1 | grep -q GNU; then
        session_time=$(date -d "$clean_timestamp" +%s 2>/dev/null)
    else
        local date_only="${clean_timestamp%[+-Z]*}"
        session_time=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$date_only" +%s 2>/dev/null)
    fi

    if [[ -z "$session_time" || ! "$session_time" =~ ^[0-9]+$ ]]; then
        echo "false"
        return 1
    fi

    local age=$((now - session_time))
    if [[ $age -lt $SESSION_EXPIRATION_SECONDS ]]; then
        echo "true"
        return 0
    else
        echo "false"
        return 1
    fi
}

# =============================================================================
# STATUS.JSON-BASED ANALYSIS FUNCTIONS (replaces analyze_response + friends)
# =============================================================================

# Update exit signals file based on status.json (replaces update_exit_signals from response_analyzer.sh)
update_exit_signals_from_status() {
    local status_file="${RALPH_DIR}/status.json"
    local exit_signals_file="${EXIT_SIGNALS_FILE}"

    if [[ ! -f "$status_file" ]]; then
        return 1
    fi

    # Read status.json fields (written by on-stop.sh hook)
    local exit_signal status tasks_completed files_modified work_type loop_number
    exit_signal=$(jq -r '.exit_signal // "false"' "$status_file" 2>/dev/null || echo "false")
    status=$(jq -r '.status // "UNKNOWN"' "$status_file" 2>/dev/null || echo "UNKNOWN")
    tasks_completed=$(jq -r '.tasks_completed // 0' "$status_file" 2>/dev/null || echo "0")
    files_modified=$(jq -r '.files_modified // 0' "$status_file" 2>/dev/null || echo "0")
    work_type=$(jq -r '.work_type // "UNKNOWN"' "$status_file" 2>/dev/null || echo "UNKNOWN")
    loop_number=$(jq -r '.loop_count // 0' "$status_file" 2>/dev/null || echo "0")

    # Determine derived flags
    local is_test_only="false"
    [[ "$work_type" == "TESTING" ]] && is_test_only="true"

    local has_completion_signal="false"
    [[ "$status" == "COMPLETE" ]] && has_completion_signal="true"

    local has_progress="false"
    [[ "$files_modified" -gt 0 || "$tasks_completed" -gt 0 ]] && has_progress="true"

    # Read current exit signals
    local signals
    signals=$(cat "$exit_signals_file" 2>/dev/null || echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": []}')

    # Update test_only_loops
    if [[ "$is_test_only" == "true" ]]; then
        signals=$(echo "$signals" | jq ".test_only_loops += [$loop_number]")
    elif [[ "$has_progress" == "true" ]]; then
        signals=$(echo "$signals" | jq '.test_only_loops = []')
    fi

    # Update done_signals
    if [[ "$has_completion_signal" == "true" ]]; then
        signals=$(echo "$signals" | jq ".done_signals += [$loop_number]")
    fi

    # Update completion_indicators (only when Claude explicitly signals exit)
    if [[ "$exit_signal" == "true" ]]; then
        signals=$(echo "$signals" | jq ".completion_indicators += [$loop_number]")
    fi

    # Keep only last 5 signals (rolling window)
    signals=$(echo "$signals" | jq '.test_only_loops = .test_only_loops[-5:] | .done_signals = .done_signals[-5:] | .completion_indicators = .completion_indicators[-5:]')

    echo "$signals" > "$exit_signals_file"
    return 0
}

# Log analysis summary from status.json (replaces log_analysis_summary from response_analyzer.sh)
log_status_summary() {
    local status_file="${RALPH_DIR}/status.json"
    [[ -f "$status_file" ]] || return 1

    local loop exit_sig files_modified work_type recommendation
    loop=$(jq -r '.loop_count' "$status_file" 2>/dev/null || echo "?")
    exit_sig=$(jq -r '.exit_signal' "$status_file" 2>/dev/null || echo "false")
    files_modified=$(jq -r '.files_modified' "$status_file" 2>/dev/null || echo "0")
    work_type=$(jq -r '.work_type' "$status_file" 2>/dev/null || echo "UNKNOWN")
    recommendation=$(jq -r '.recommendation' "$status_file" 2>/dev/null || echo "")

    echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║           Response Analysis - Loop #$loop                 ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
    echo -e "${YELLOW}Exit Signal:${NC}      $exit_sig"
    echo -e "${YELLOW}Files Changed:${NC}    $files_modified"
    echo -e "${YELLOW}Work Type:${NC}        $work_type"
    echo -e "${YELLOW}Summary:${NC}          $recommendation"
    echo ""
}

# Update status JSON for external monitoring
update_status() {
    local loop_count=$1
    local calls_made=$2
    local last_action=$3
    local status=$4
    local exit_reason=${5:-""}
    
    cat > "$STATUS_FILE" << STATUSEOF
{
    "timestamp": "$(get_iso_timestamp)",
    "loop_count": $loop_count,
    "calls_made_this_hour": $calls_made,
    "max_calls_per_hour": $MAX_CALLS_PER_HOUR,
    "last_action": "$last_action",
    "status": "$status",
    "exit_reason": "$exit_reason",
    "next_reset": "$(get_next_hour_time)"
}
STATUSEOF
}

# Check if we can make another call
can_make_call() {
    local calls_made=0
    if [[ -f "$CALL_COUNT_FILE" ]]; then
        calls_made=$(cat "$CALL_COUNT_FILE")
    fi
    
    if [[ $calls_made -ge $MAX_CALLS_PER_HOUR ]]; then
        return 1  # Cannot make call
    else
        return 0  # Can make call
    fi
}

# Increment call counter
increment_call_counter() {
    local calls_made=0
    if [[ -f "$CALL_COUNT_FILE" ]]; then
        calls_made=$(cat "$CALL_COUNT_FILE")
    fi
    
    ((calls_made++))
    echo "$calls_made" > "$CALL_COUNT_FILE"
    echo "$calls_made"
}

# Wait for rate limit reset with countdown
wait_for_reset() {
    local calls_made=$(cat "$CALL_COUNT_FILE" 2>/dev/null || echo "0")
    log_status "WARN" "Rate limit reached ($calls_made/$MAX_CALLS_PER_HOUR). Waiting for reset..."
    
    # Calculate time until next hour
    local current_minute=$(date +%M)
    local current_second=$(date +%S)
    local wait_time=$(((60 - current_minute - 1) * 60 + (60 - current_second)))
    
    log_status "INFO" "Sleeping for $wait_time seconds until next hour..."
    
    # Countdown display
    while [[ $wait_time -gt 0 ]]; do
        local hours=$((wait_time / 3600))
        local minutes=$(((wait_time % 3600) / 60))
        local seconds=$((wait_time % 60))
        
        printf "\r${YELLOW}Time until reset: %02d:%02d:%02d${NC}" $hours $minutes $seconds
        sleep 1
        ((wait_time--))
    done
    printf "\n"
    
    # Reset counter
    echo "0" > "$CALL_COUNT_FILE"
    echo "$(date +%Y%m%d%H)" > "$TIMESTAMP_FILE"
    log_status "SUCCESS" "Rate limit reset! Ready for new calls."
}

# Check if we should gracefully exit
should_exit_gracefully() {
    
    if [[ ! -f "$EXIT_SIGNALS_FILE" ]]; then
        return 1  # Don't exit, file doesn't exist
    fi
    
    local signals=$(cat "$EXIT_SIGNALS_FILE")
    
    # Count recent signals (last 5 loops) - with error handling
    local recent_test_loops
    local recent_done_signals  
    local recent_completion_indicators
    
    recent_test_loops=$(echo "$signals" | jq '.test_only_loops | length' 2>/dev/null || echo "0")
    recent_done_signals=$(echo "$signals" | jq '.done_signals | length' 2>/dev/null || echo "0")
    recent_completion_indicators=$(echo "$signals" | jq '.completion_indicators | length' 2>/dev/null || echo "0")

    # Diagnostic logging for exit signal check (Issue #194)
    [[ "${VERBOSE_PROGRESS:-}" == "true" ]] && log_status "DEBUG" "Exit check: test_loops=$recent_test_loops done_signals=$recent_done_signals completion_indicators=$recent_completion_indicators"

    # Check for exit conditions

    # 0. Permission denials (highest priority - Issue #101)
    # Check circuit breaker state for permission denial tracking (set by on-stop.sh hook)
    if [[ -f "$RALPH_DIR/.circuit_breaker_state" ]]; then
        local perm_denials
        perm_denials=$(jq -r '.consecutive_permission_denials // 0' "$RALPH_DIR/.circuit_breaker_state" 2>/dev/null || echo "0")
        if [[ "$perm_denials" -ge "${CB_PERMISSION_DENIAL_THRESHOLD:-2}" ]]; then
            log_status "WARN" "🚫 Permission denied in $perm_denials consecutive loops"
            log_status "WARN" "Update ALLOWED_TOOLS in .ralphrc to include the required tools"
            echo "permission_denied"
            return 0
        fi
    fi

    # 1. Too many consecutive test-only loops
    if [[ $recent_test_loops -ge $MAX_CONSECUTIVE_TEST_LOOPS ]]; then
        log_status "WARN" "Exit condition: Too many test-focused loops ($recent_test_loops >= $MAX_CONSECUTIVE_TEST_LOOPS)"
        echo "test_saturation"
        return 0
    fi
    
    # 2. Multiple "done" signals
    if [[ $recent_done_signals -ge $MAX_CONSECUTIVE_DONE_SIGNALS ]]; then
        log_status "WARN" "Exit condition: Multiple completion signals ($recent_done_signals >= $MAX_CONSECUTIVE_DONE_SIGNALS)"
        echo "completion_signals"
        return 0
    fi
    
    # 3. Safety circuit breaker - force exit after 5 consecutive EXIT_SIGNAL=true responses
    # Note: completion_indicators only accumulates when Claude explicitly sets EXIT_SIGNAL=true
    # (not based on confidence score). This safety breaker catches cases where Claude signals
    # completion 5+ times but the normal exit path (completion_indicators >= 2 + EXIT_SIGNAL=true)
    # didn't trigger for some reason. Threshold of 5 prevents API waste while being higher than
    # the normal threshold (2) to avoid false positives.
    if [[ $recent_completion_indicators -ge 5 ]]; then
        log_status "WARN" "🚨 SAFETY CIRCUIT BREAKER: Force exit after 5 consecutive EXIT_SIGNAL=true responses ($recent_completion_indicators)" >&2
        echo "safety_circuit_breaker"
        return 0
    fi

    # 4. Strong completion indicators (only if Claude's EXIT_SIGNAL is true)
    # This prevents premature exits when heuristics detect completion patterns
    # but Claude explicitly indicates work is still in progress via RALPH_STATUS block.
    # The exit_signal in status.json represents Claude's explicit intent (written by on-stop.sh hook).
    local claude_exit_signal="false"
    if [[ -f "$RALPH_DIR/status.json" ]]; then
        claude_exit_signal=$(jq -r '.exit_signal // "false"' "$RALPH_DIR/status.json" 2>/dev/null || echo "false")
    fi

    if [[ $recent_completion_indicators -ge 2 ]] && [[ "$claude_exit_signal" == "true" ]]; then
        log_status "WARN" "Exit condition: Strong completion indicators ($recent_completion_indicators) with EXIT_SIGNAL=true" >&2
        echo "project_complete"
        return 0
    fi
    
    # 5. Check fix_plan.md for completion
    # Fix #144: Only match valid markdown checkboxes, not date entries like [2026-01-29]
    # Valid patterns: "- [ ]" (uncompleted) and "- [x]" or "- [X]" (completed)
    if [[ -f "$RALPH_DIR/fix_plan.md" ]]; then
        local uncompleted_items=$(grep -cE "^[[:space:]]*- \[ \]" "$RALPH_DIR/fix_plan.md" 2>/dev/null || echo "0")
        local completed_items=$(grep -cE "^[[:space:]]*- \[[xX]\]" "$RALPH_DIR/fix_plan.md" 2>/dev/null || echo "0")
        local total_items=$((uncompleted_items + completed_items))

        if [[ $total_items -gt 0 ]] && [[ $completed_items -eq $total_items ]]; then
            log_status "WARN" "Exit condition: All fix_plan.md items completed ($completed_items/$total_items)" >&2
            echo "plan_complete"
            return 0
        fi
    fi

    echo ""  # Return empty string instead of using return code
}

# =============================================================================
# MODERN CLI HELPER FUNCTIONS (Phase 1.1)
# =============================================================================

# Compare two semver strings: returns 0 if ver1 >= ver2, 1 if ver1 < ver2
# Uses sequential major→minor→patch comparison (safe for any patch number)
compare_semver() {
    local ver1="$1" ver2="$2"
    local v1_major v1_minor v1_patch
    local v2_major v2_minor v2_patch

    IFS='.' read -r v1_major v1_minor v1_patch <<< "$ver1"
    IFS='.' read -r v2_major v2_minor v2_patch <<< "$ver2"

    v1_major=${v1_major:-0}; v1_minor=${v1_minor:-0}; v1_patch=${v1_patch:-0}
    v2_major=${v2_major:-0}; v2_minor=${v2_minor:-0}; v2_patch=${v2_patch:-0}

    if [[ $v1_major -gt $v2_major ]]; then return 0; fi
    if [[ $v1_major -lt $v2_major ]]; then return 1; fi
    if [[ $v1_minor -gt $v2_minor ]]; then return 0; fi
    if [[ $v1_minor -lt $v2_minor ]]; then return 1; fi
    if [[ $v1_patch -lt $v2_patch ]]; then return 1; fi
    return 0
}

# Check Claude CLI version for compatibility with modern flags
check_claude_version() {
    local version
    version=$($CLAUDE_CODE_CMD --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)

    if [[ -z "$version" ]]; then
        log_status "WARN" "Cannot detect Claude CLI version, assuming compatible"
        return 0
    fi

    if ! compare_semver "$version" "$CLAUDE_MIN_VERSION"; then
        log_status "WARN" "Claude CLI version $version < $CLAUDE_MIN_VERSION. Some modern features may not work."
        log_status "WARN" "Consider upgrading: npm update -g @anthropic-ai/claude-code"
        return 1
    fi

    log_status "INFO" "Claude CLI version $version (>= $CLAUDE_MIN_VERSION) - modern features enabled"
    return 0
}

# Check for Claude CLI updates and attempt auto-update (Issue #190)
check_claude_updates() {
    if [[ "${CLAUDE_AUTO_UPDATE:-true}" != "true" ]]; then
        return 0
    fi

    local installed_version
    installed_version=$($CLAUDE_CODE_CMD --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    if [[ -z "$installed_version" ]]; then
        return 0
    fi

    # Query latest version from npm registry (with timeout to avoid hanging on flaky networks)
    local latest_version
    latest_version=$(portable_timeout 5s npm view @anthropic-ai/claude-code version 2>/dev/null)
    if [[ -z "$latest_version" ]]; then
        log_status "INFO" "Could not check for Claude CLI updates (npm registry unreachable)"
        return 0
    fi

    if [[ "$installed_version" == "$latest_version" ]]; then
        log_status "INFO" "Claude CLI is up to date ($installed_version)"
        return 0
    fi

    if compare_semver "$installed_version" "$latest_version"; then
        return 0
    fi

    # Auto-update attempt
    log_status "INFO" "Claude CLI update available: $installed_version → $latest_version. Attempting auto-update..."
    local update_output
    if update_output=$(npm update -g @anthropic-ai/claude-code 2>&1); then
        local new_version
        new_version=$($CLAUDE_CODE_CMD --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        log_status "SUCCESS" "Claude CLI updated: $installed_version → ${new_version:-$latest_version}"
        return 0
    fi

    # Auto-update failed — warn with environment-specific guidance
    log_status "WARN" "Claude CLI auto-update failed ($installed_version → $latest_version)"
    [[ -n "$update_output" ]] && log_status "DEBUG" "npm output: $update_output"
    log_status "WARN" "Update manually: npm update -g @anthropic-ai/claude-code"
    log_status "WARN" "In Docker: rebuild your image to include the latest version"
    return 1
}

# Check if the installed Claude CLI supports agent teams (requires v2.1.32+)
check_teams_support() {
    local version
    version=$($CLAUDE_CODE_CMD --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)

    if [[ -z "$version" ]]; then
        return 1
    fi

    # Teams require v2.1.32+
    compare_semver "$version" "2.1.32"
}

# Setup agent teams if enabled via RALPH_ENABLE_TEAMS
setup_teams() {
    if [[ "${RALPH_ENABLE_TEAMS:-false}" != "true" ]]; then
        return 0
    fi

    # Check CLI version supports teams
    if ! check_teams_support; then
        log_status "WARN" "Agent teams require Claude Code v2.1.32+. Falling back to sequential."
        RALPH_ENABLE_TEAMS=false
        return 0
    fi

    # Create local settings with teams env var
    local settings_local=".claude/settings.local.json"
    mkdir -p .claude
    cat > "$settings_local" <<EOF
{
  "env": {
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"
  },
  "teammateMode": "${RALPH_TEAMMATE_MODE:-tmux}"
}
EOF

    log_status "INFO" "Agent teams enabled (max ${RALPH_MAX_TEAMMATES:-3} teammates, mode=${RALPH_TEAMMATE_MODE:-tmux})"
}

# Check for WSL/Windows version divergence
# Detects when Ralph is installed in both WSL and Windows and versions differ.
# This prevents silent loop crashes caused by one copy using removed APIs (e.g. response_analyzer.sh).
check_version_divergence() {
    # Only relevant in WSL environments
    if [[ ! -d "/mnt/c" ]] || [[ "$(uname -r)" != *icrosoft* && "$(uname -r)" != *WSL* ]]; then
        return 0
    fi

    # Find Windows user home directory
    local win_home=""
    for user_dir in /mnt/c/Users/*/; do
        if [[ -f "${user_dir}.ralph/ralph_loop.sh" ]]; then
            win_home="$user_dir"
            break
        fi
    done

    [[ -z "$win_home" ]] && return 0

    local win_script="${win_home}.ralph/ralph_loop.sh"
    local win_version
    win_version=$(grep -m1 'RALPH_VERSION=' "$win_script" 2>/dev/null | sed 's/.*RALPH_VERSION="\{0,1\}\([^"]*\)"\{0,1\}/\1/')

    if [[ -z "$win_version" ]]; then
        return 0
    fi

    if [[ "$win_version" != "$RALPH_VERSION" ]]; then
        log_status "WARN" "VERSION DIVERGENCE: WSL=$RALPH_VERSION, Windows=$win_version"
        log_status "WARN" "This can cause silent loop crashes. Sync with:"
        log_status "WARN" "  cp '${win_script}' ~/.ralph/ralph_loop.sh && sed -i 's/\\r\$//' ~/.ralph/ralph_loop.sh"
    fi

    # Also check for stale response_analyzer.sh (removed in v1.0.0)
    if [[ -f "$SCRIPT_DIR/lib/response_analyzer.sh" ]]; then
        log_status "WARN" "STALE FILE: lib/response_analyzer.sh exists but was removed in v1.0.0"
        log_status "WARN" "This Ralph install may be outdated. Response analysis is now handled by on-stop.sh hook."
    fi
}

# =============================================================================
# LOG ROTATION (Issue #18)
# =============================================================================

# Configuration for log rotation
LOG_MAX_SIZE_MB="${LOG_MAX_SIZE_MB:-10}"         # Rotate when ralph.log exceeds this size (MB)
LOG_MAX_FILES="${LOG_MAX_FILES:-5}"               # Keep this many rotated log files
LOG_MAX_OUTPUT_FILES="${LOG_MAX_OUTPUT_FILES:-20}" # Keep this many claude_output_*.log files

# Rotate ralph.log when it exceeds LOG_MAX_SIZE_MB
rotate_ralph_log() {
    local log_file="$LOG_DIR/ralph.log"
    [[ -f "$log_file" ]] || return 0

    local file_size_bytes
    # Cross-platform file size detection
    if file_size_bytes=$(stat -c %s "$log_file" 2>/dev/null); then
        : # GNU stat
    elif file_size_bytes=$(stat -f %z "$log_file" 2>/dev/null); then
        : # BSD stat
    else
        return 0  # Can't determine size, skip rotation
    fi

    local max_bytes=$((LOG_MAX_SIZE_MB * 1024 * 1024))
    if [[ $file_size_bytes -lt $max_bytes ]]; then
        return 0
    fi

    log_status "INFO" "Rotating ralph.log (${file_size_bytes} bytes > ${max_bytes} byte limit)"

    # Shift existing rotated logs: .4 -> .5, .3 -> .4, etc.
    local i=$LOG_MAX_FILES
    while [[ $i -gt 1 ]]; do
        local prev=$((i - 1))
        [[ -f "${log_file}.${prev}" ]] && mv "${log_file}.${prev}" "${log_file}.${i}"
        i=$((i - 1))
    done

    # Move current to .1
    mv "$log_file" "${log_file}.1"

    # Start a fresh log
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Log rotated (previous log: ralph.log.1)" > "$log_file"
}

# Clean up old claude_output_*.log files, keeping only the most recent LOG_MAX_OUTPUT_FILES
cleanup_old_output_logs() {
    local count
    count=$(find "$LOG_DIR" -maxdepth 1 -name 'claude_output_*.log' 2>/dev/null | wc -l)
    count=$((count + 0))

    if [[ $count -le $LOG_MAX_OUTPUT_FILES ]]; then
        return 0
    fi

    local to_remove=$((count - LOG_MAX_OUTPUT_FILES))
    log_status "INFO" "Cleaning up $to_remove old output log(s) (keeping newest $LOG_MAX_OUTPUT_FILES)"

    # Remove oldest files (sorted by name which includes timestamp)
    find "$LOG_DIR" -maxdepth 1 -name 'claude_output_*.log' -print0 2>/dev/null \
        | sort -z \
        | head -z -n "$to_remove" \
        | xargs -0 rm -f 2>/dev/null
}

# =============================================================================
# DRY-RUN MODE (Issue #19)
# =============================================================================

DRY_RUN="${DRY_RUN:-false}"

# Simulate a Claude Code execution for dry-run mode
dry_run_simulate() {
    local prompt_content="$1"
    local loop_num="$2"

    log_status "INFO" "[DRY-RUN] Would execute Claude Code with:"
    log_status "INFO" "[DRY-RUN]   Command: $CLAUDE_CODE_CMD"
    log_status "INFO" "[DRY-RUN]   Output format: $CLAUDE_OUTPUT_FORMAT"
    log_status "INFO" "[DRY-RUN]   Timeout: ${CLAUDE_TIMEOUT_MINUTES}m"
    log_status "INFO" "[DRY-RUN]   Session continuity: $CLAUDE_USE_CONTINUE"
    log_status "INFO" "[DRY-RUN]   Allowed tools: $(echo "$CLAUDE_ALLOWED_TOOLS" | tr ',' '\n' | wc -l | tr -d ' ') tools"

    if [[ -f "$RALPH_DIR/fix_plan.md" ]]; then
        local task_count
        task_count=$(grep -c '^\- \[ \]' "$RALPH_DIR/fix_plan.md" 2>/dev/null || echo "0")
        local done_count
        done_count=$(grep -c '^\- \[x\]' "$RALPH_DIR/fix_plan.md" 2>/dev/null || echo "0")
        log_status "INFO" "[DRY-RUN]   Tasks: $task_count open, $done_count done"
    fi

    # Write a simulated status.json
    cat > "$STATUS_FILE" <<EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "loop_count": $loop_num,
  "status": "DRY_RUN",
  "exit_signal": "false",
  "tasks_completed": 0,
  "files_modified": 0,
  "work_type": "dry_run",
  "recommendation": "Dry-run mode — no changes made"
}
EOF

    log_status "SUCCESS" "[DRY-RUN] Simulation complete (no API call made)"
    return 0
}

# Validate allowed tools against whitelist
# Returns 0 if valid, 1 if invalid with error message
validate_allowed_tools() {
    local tools_input=$1

    if [[ -z "$tools_input" ]]; then
        return 0  # Empty is valid (uses defaults)
    fi

    # Split by comma
    local IFS=','
    read -ra tools <<< "$tools_input"

    for tool in "${tools[@]}"; do
        # Trim whitespace
        tool=$(echo "$tool" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

        if [[ -z "$tool" ]]; then
            continue
        fi

        local valid=false

        # Check against valid patterns
        for pattern in "${VALID_TOOL_PATTERNS[@]}"; do
            if [[ "$tool" == "$pattern" ]]; then
                valid=true
                break
            fi

            # Check for Bash(*) pattern - any Bash with parentheses is allowed
            if [[ "$tool" =~ ^Bash\(.+\)$ ]]; then
                valid=true
                break
            fi
        done

        if [[ "$valid" == "false" ]]; then
            echo "Error: Invalid tool in --allowed-tools: '$tool'"
            echo "Valid tools: ${VALID_TOOL_PATTERNS[*]}"
            echo "Note: Bash(...) patterns with any content are allowed (e.g., 'Bash(git *)')"
            return 1
        fi
    done

    return 0
}

# Build loop context for Claude Code session
# Provides loop-specific context via --append-system-prompt
build_loop_context() {
    local loop_count=$1
    local context=""

    # Add loop number
    context="Loop #${loop_count}. "

    # Extract incomplete tasks from fix_plan.md
    # Bug #3 Fix: Support indented markdown checkboxes with [[:space:]]* pattern
    if [[ -f "$RALPH_DIR/fix_plan.md" ]]; then
        local incomplete_tasks=$(grep -cE "^[[:space:]]*- \[ \]" "$RALPH_DIR/fix_plan.md" 2>/dev/null || echo "0")
        context+="Remaining tasks: ${incomplete_tasks}. "
    fi

    # Add circuit breaker state
    if [[ -f "$RALPH_DIR/.circuit_breaker_state" ]]; then
        local cb_state=$(jq -r '.state // "UNKNOWN"' "$RALPH_DIR/.circuit_breaker_state" 2>/dev/null)
        if [[ "$cb_state" != "CLOSED" && "$cb_state" != "null" && -n "$cb_state" ]]; then
            context+="Circuit breaker: ${cb_state}. "
        fi
    fi

    # Add previous loop summary from status.json (written by on-stop.sh hook)
    if [[ -f "$RALPH_DIR/status.json" ]]; then
        local prev_summary
        prev_summary=$(jq -r '.recommendation // ""' "$RALPH_DIR/status.json" 2>/dev/null | head -c 200)
        if [[ -n "$prev_summary" && "$prev_summary" != "null" ]]; then
            context+="Previous: ${prev_summary} "
        fi
    fi

    # Limit total length to ~500 chars
    echo "${context:0:500}"
}

# Get session file age in hours (cross-platform)
# Returns: age in hours on stdout, or -1 if stat fails
# Note: Returns 0 for files less than 1 hour old
get_session_file_age_hours() {
    local file=$1

    if [[ ! -f "$file" ]]; then
        echo "0"
        return
    fi

    # Get file modification time using capability detection
    # Handles macOS with Homebrew coreutils where stat flags differ
    local file_mtime

    # Try GNU stat first (Linux, macOS with Homebrew coreutils)
    if file_mtime=$(stat -c %Y "$file" 2>/dev/null) && [[ -n "$file_mtime" && "$file_mtime" =~ ^[0-9]+$ ]]; then
        : # success
    # Try BSD stat (native macOS)
    elif file_mtime=$(stat -f %m "$file" 2>/dev/null) && [[ -n "$file_mtime" && "$file_mtime" =~ ^[0-9]+$ ]]; then
        : # success
    # Fallback to date -r (most portable)
    elif file_mtime=$(date -r "$file" +%s 2>/dev/null) && [[ -n "$file_mtime" && "$file_mtime" =~ ^[0-9]+$ ]]; then
        : # success
    else
        file_mtime=""
    fi

    # Handle stat failure - return -1 to indicate error
    # This prevents false expiration when stat fails
    if [[ -z "$file_mtime" || "$file_mtime" == "0" ]]; then
        echo "-1"
        return
    fi

    local current_time
    current_time=$(date +%s)

    local age_seconds=$((current_time - file_mtime))
    local age_hours=$((age_seconds / 3600))

    echo "$age_hours"
}

# Initialize or resume Claude session (with expiration check)
#
# Session Expiration Strategy:
# - Default expiration: 24 hours (configurable via CLAUDE_SESSION_EXPIRY_HOURS)
# - 24 hours chosen because: long enough for multi-day projects, short enough
#   to prevent stale context from causing unpredictable behavior
# - Sessions auto-expire to ensure Claude starts fresh periodically
#
# Returns (stdout):
#   - Session ID string: when resuming a valid, non-expired session
#   - Empty string: when starting new session (no file, expired, or stat error)
#
# Return codes:
#   - 0: Always returns success (caller should check stdout for session ID)
#
init_claude_session() {
    if [[ -f "$CLAUDE_SESSION_FILE" ]]; then
        # Check session age
        local age_hours
        age_hours=$(get_session_file_age_hours "$CLAUDE_SESSION_FILE")

        # Handle stat failure (-1) - treat as needing new session
        # Don't expire sessions when we can't determine age
        if [[ $age_hours -eq -1 ]]; then
            log_status "WARN" "Could not determine session age, starting new session"
            rm -f "$CLAUDE_SESSION_FILE"
            echo ""
            return 0
        fi

        # Check if session has expired
        if [[ $age_hours -ge $CLAUDE_SESSION_EXPIRY_HOURS ]]; then
            log_status "INFO" "Session expired (${age_hours}h old, max ${CLAUDE_SESSION_EXPIRY_HOURS}h), starting new session"
            rm -f "$CLAUDE_SESSION_FILE"
            echo ""
            return 0
        fi

        # Session is valid, try to read it
        local session_id=$(cat "$CLAUDE_SESSION_FILE" 2>/dev/null)
        if [[ -n "$session_id" ]]; then
            log_status "INFO" "Resuming Claude session: ${session_id:0:20}... (${age_hours}h old)"
            echo "$session_id"
            return 0
        fi
    fi

    log_status "INFO" "Starting new Claude session"
    echo ""
}

# Save session ID after successful execution
save_claude_session() {
    local output_file=$1

    # Guard: never persist a session from a response where is_error is true (Issue #134, #199)
    if [[ -f "$output_file" ]]; then
        local is_error
        is_error=$(jq -r '.is_error // false' "$output_file" 2>/dev/null || echo "false")
        if [[ "$is_error" == "true" ]]; then
            log_status "WARN" "Skipping session save — response has is_error:true"
            return 0
        fi
    fi

    # Try to extract session ID from JSON output
    if [[ -f "$output_file" ]]; then
        local session_id=$(jq -r '.metadata.session_id // .session_id // empty' "$output_file" 2>/dev/null)
        if [[ -n "$session_id" && "$session_id" != "null" ]]; then
            echo "$session_id" > "$CLAUDE_SESSION_FILE"
            log_status "INFO" "Saved Claude session: ${session_id:0:20}..."
        fi
    fi
}

# =============================================================================
# SESSION LIFECYCLE MANAGEMENT FUNCTIONS (Phase 1.2)
# =============================================================================

# Get current session ID from Ralph session file
# Returns: session ID string or empty if not found
get_session_id() {
    if [[ ! -f "$RALPH_SESSION_FILE" ]]; then
        echo ""
        return 0
    fi

    # Extract session_id from JSON file (SC2155: separate declare from assign)
    local session_id
    session_id=$(jq -r '.session_id // ""' "$RALPH_SESSION_FILE" 2>/dev/null)
    local jq_status=$?

    # Handle jq failure or null/empty results
    if [[ $jq_status -ne 0 || -z "$session_id" || "$session_id" == "null" ]]; then
        session_id=""
    fi
    echo "$session_id"
    return 0
}

# Reset session with reason logging
# Usage: reset_session "reason_for_reset"
reset_session() {
    local reason=${1:-"manual_reset"}

    # Get current timestamp
    local reset_timestamp
    reset_timestamp=$(get_iso_timestamp)

    # Always create/overwrite the session file using jq for safe JSON escaping
    jq -n \
        --arg session_id "" \
        --arg created_at "" \
        --arg last_used "" \
        --arg reset_at "$reset_timestamp" \
        --arg reset_reason "$reason" \
        '{
            session_id: $session_id,
            created_at: $created_at,
            last_used: $last_used,
            reset_at: $reset_at,
            reset_reason: $reset_reason
        }' > "$RALPH_SESSION_FILE"

    # Also clear the Claude session file for consistency
    rm -f "$CLAUDE_SESSION_FILE" 2>/dev/null

    # Clear exit signals to prevent stale completion indicators from causing premature exit (issue #91)
    # This ensures a fresh start without leftover state from previous sessions
    if [[ -f "$EXIT_SIGNALS_FILE" ]]; then
        echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": []}' > "$EXIT_SIGNALS_FILE"
        [[ "${VERBOSE_PROGRESS:-}" == "true" ]] && log_status "INFO" "Cleared exit signals file"
    fi

    # Log the session transition
    log_session_transition "active" "reset" "$reason" "${loop_count:-0}"

    log_status "INFO" "Session reset: $reason"
}

# Log session state transitions to history file
# Usage: log_session_transition from_state to_state reason loop_number
log_session_transition() {
    local from_state=$1
    local to_state=$2
    local reason=$3
    local loop_number=${4:-0}

    # Get timestamp once (SC2155: separate declare from assign)
    local ts
    ts=$(get_iso_timestamp)

    # Create transition entry using jq for safe JSON (SC2155: separate declare from assign)
    local transition
    transition=$(jq -n -c \
        --arg timestamp "$ts" \
        --arg from_state "$from_state" \
        --arg to_state "$to_state" \
        --arg reason "$reason" \
        --argjson loop_number "$loop_number" \
        '{
            timestamp: $timestamp,
            from_state: $from_state,
            to_state: $to_state,
            reason: $reason,
            loop_number: $loop_number
        }')

    # Read history file defensively - fallback to empty array on any failure
    local history
    if [[ -f "$RALPH_SESSION_HISTORY_FILE" ]]; then
        history=$(cat "$RALPH_SESSION_HISTORY_FILE" 2>/dev/null)
        # Validate JSON, fallback to empty array if corrupted
        if ! echo "$history" | jq empty 2>/dev/null; then
            history='[]'
        fi
    else
        history='[]'
    fi

    # Append transition and keep only last 50 entries
    local updated_history
    updated_history=$(echo "$history" | jq ". += [$transition] | .[-50:]" 2>/dev/null)
    local jq_status=$?

    # Only write if jq succeeded
    if [[ $jq_status -eq 0 && -n "$updated_history" ]]; then
        echo "$updated_history" > "$RALPH_SESSION_HISTORY_FILE"
    else
        # Fallback: start fresh with just this transition
        echo "[$transition]" > "$RALPH_SESSION_HISTORY_FILE"
    fi
}

# Generate a unique session ID using timestamp and random component
generate_session_id() {
    local ts
    ts=$(date +%s)
    local rand
    rand=$RANDOM
    echo "ralph-${ts}-${rand}"
}

# Initialize session tracking (called at loop start)
init_session_tracking() {
    local ts
    ts=$(get_iso_timestamp)

    # Create session file if it doesn't exist
    if [[ ! -f "$RALPH_SESSION_FILE" ]]; then
        local new_session_id
        new_session_id=$(generate_session_id)

        jq -n \
            --arg session_id "$new_session_id" \
            --arg created_at "$ts" \
            --arg last_used "$ts" \
            --arg reset_at "" \
            --arg reset_reason "" \
            '{
                session_id: $session_id,
                created_at: $created_at,
                last_used: $last_used,
                reset_at: $reset_at,
                reset_reason: $reset_reason
            }' > "$RALPH_SESSION_FILE"

        log_status "INFO" "Initialized session tracking (session: $new_session_id)"
        return 0
    fi

    # Validate existing session file
    if ! jq empty "$RALPH_SESSION_FILE" 2>/dev/null; then
        log_status "WARN" "Corrupted session file detected, recreating..."
        local new_session_id
        new_session_id=$(generate_session_id)

        jq -n \
            --arg session_id "$new_session_id" \
            --arg created_at "$ts" \
            --arg last_used "$ts" \
            --arg reset_at "$ts" \
            --arg reset_reason "corrupted_file_recovery" \
            '{
                session_id: $session_id,
                created_at: $created_at,
                last_used: $last_used,
                reset_at: $reset_at,
                reset_reason: $reset_reason
            }' > "$RALPH_SESSION_FILE"
    fi
}

# Update last_used timestamp in session file (called on each loop iteration)
update_session_last_used() {
    if [[ ! -f "$RALPH_SESSION_FILE" ]]; then
        return 0
    fi

    local ts
    ts=$(get_iso_timestamp)

    # Update last_used in existing session file
    local updated
    updated=$(jq --arg last_used "$ts" '.last_used = $last_used' "$RALPH_SESSION_FILE" 2>/dev/null)
    local jq_status=$?

    if [[ $jq_status -eq 0 && -n "$updated" ]]; then
        echo "$updated" > "$RALPH_SESSION_FILE"
    fi
}

# Global array for Claude command arguments (avoids shell injection)
declare -a CLAUDE_CMD_ARGS=()

# Build Claude CLI command with modern flags using array (shell-injection safe)
# Populates global CLAUDE_CMD_ARGS array for direct execution
# Check if Claude Code CLI supports --agent flag (requires v2.1+)
check_agent_support() {
    local version
    version=$($CLAUDE_CODE_CMD --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)

    if [[ -z "$version" ]]; then
        return 1
    fi

    local major minor
    major=$(echo "$version" | cut -d. -f1)
    minor=$(echo "$version" | cut -d. -f2)

    if [[ "$major" -gt 2 ]] || [[ "$major" -eq 2 && "$minor" -ge 1 ]]; then
        return 0
    fi

    return 1
}

# Uses -p flag with prompt content (Claude CLI does not have --prompt-file)
# When RALPH_USE_AGENT=true and CLI supports it, uses --agent ralph instead
build_claude_command() {
    local prompt_file=$1
    local loop_context=$2
    local session_id=$3

    # Reset global array
    CLAUDE_CMD_ARGS=("$CLAUDE_CODE_CMD")

    # Agent mode (HOOKS-6): use --agent ralph when supported
    if [[ "${RALPH_USE_AGENT:-false}" == "true" ]] && check_agent_support; then
        CLAUDE_CMD_ARGS+=("--agent" "${RALPH_AGENT_NAME:-ralph}")

        # Add output format flag
        if [[ "$CLAUDE_OUTPUT_FORMAT" == "json" ]]; then
            CLAUDE_CMD_ARGS+=("--output-format" "json")
        fi

        # In agent mode: no --allowedTools (agent definition handles it),
        # no --resume (agent memory replaces session continuity).
        # Still need -p with prompt content — --output-format json implies
        # --print mode which requires explicit input.
        if [[ -f "$prompt_file" ]]; then
            local prompt_content
            prompt_content=$(cat "$prompt_file")
            CLAUDE_CMD_ARGS+=("-p" "$prompt_content")
        fi
        log_status "INFO" "Using agent mode: --agent ${RALPH_AGENT_NAME:-ralph}"
        return 0
    fi

    # Legacy mode (v0.11.x compatible) — fallback when agent mode unavailable
    if [[ "${RALPH_USE_AGENT:-false}" == "true" ]]; then
        log_status "WARN" "Agent mode requested but CLI does not support --agent. Falling back to legacy mode."
    fi

    # Check if prompt file exists
    if [[ ! -f "$prompt_file" ]]; then
        log_status "ERROR" "Prompt file not found: $prompt_file"
        return 1
    fi

    # Add output format flag
    if [[ "$CLAUDE_OUTPUT_FORMAT" == "json" ]]; then
        CLAUDE_CMD_ARGS+=("--output-format" "json")
    fi

    # Add allowed tools (each tool as separate array element)
    if [[ -n "$CLAUDE_ALLOWED_TOOLS" ]]; then
        CLAUDE_CMD_ARGS+=("--allowedTools")
        # Split by comma and add each tool
        local IFS=','
        read -ra tools_array <<< "$CLAUDE_ALLOWED_TOOLS"
        for tool in "${tools_array[@]}"; do
            # Trim whitespace
            tool=$(echo "$tool" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            if [[ -n "$tool" ]]; then
                CLAUDE_CMD_ARGS+=("$tool")
            fi
        done
    fi

    # Add session continuity flag
    # IMPORTANT: Use --resume with explicit session ID instead of --continue
    # --continue resumes the "most recent session in current directory" which
    # can hijack active Claude Code sessions. --resume with a specific session ID
    # ensures we only resume Ralph's own sessions. (Issue #151)
    if [[ "$CLAUDE_USE_CONTINUE" == "true" && -n "$session_id" ]]; then
        CLAUDE_CMD_ARGS+=("--resume" "$session_id")
    fi

    # Add loop context as system prompt (no escaping needed - array handles it)
    if [[ -n "$loop_context" ]]; then
        CLAUDE_CMD_ARGS+=("--append-system-prompt" "$loop_context")
    fi

    # Read prompt file content and use -p flag
    local prompt_content
    prompt_content=$(cat "$prompt_file")
    CLAUDE_CMD_ARGS+=("-p" "$prompt_content")
}

# Main execution function
execute_claude_code() {
    local timestamp=$(date '+%Y-%m-%d_%H-%M-%S')
    local output_file="$LOG_DIR/claude_output_${timestamp}.log"
    local loop_count=$1
    local calls_made
    calls_made=$(increment_call_counter)

    # Fix #141: Capture git HEAD SHA at loop start to detect commits as progress
    # Store in file for access by progress detection after Claude execution
    local loop_start_sha=""
    if command -v git &>/dev/null && git rev-parse --git-dir &>/dev/null 2>&1; then
        loop_start_sha=$(git rev-parse HEAD 2>/dev/null || echo "")
    fi
    echo "$loop_start_sha" > "$RALPH_DIR/.loop_start_sha"

    log_status "LOOP" "Executing Claude Code (Call $calls_made/$MAX_CALLS_PER_HOUR)"
    local timeout_seconds=$((CLAUDE_TIMEOUT_MINUTES * 60))
    log_status "INFO" "⏳ Starting Claude Code execution... (timeout: ${CLAUDE_TIMEOUT_MINUTES}m)"

    # Build loop context (always, regardless of session mode)
    local loop_context=""
    loop_context=$(build_loop_context "$loop_count")
    if [[ -n "$loop_context" && "$VERBOSE_PROGRESS" == "true" ]]; then
        log_status "INFO" "Loop context: $loop_context"
    fi

    # Initialize or resume session
    local session_id=""
    if [[ "$CLAUDE_USE_CONTINUE" == "true" ]]; then
        session_id=$(init_claude_session)
    fi

    # Live mode requires JSON output (stream-json) — override text format
    if [[ "$LIVE_OUTPUT" == "true" && "$CLAUDE_OUTPUT_FORMAT" == "text" ]]; then
        log_status "WARN" "Live mode requires JSON output format. Overriding text → json for this session."
        CLAUDE_OUTPUT_FORMAT="json"
    fi

    # Build the Claude CLI command with modern flags
    local use_modern_cli=false

    if build_claude_command "$PROMPT_FILE" "$loop_context" "$session_id"; then
        use_modern_cli=true
        log_status "INFO" "Using modern CLI mode (${CLAUDE_OUTPUT_FORMAT} output)"
    else
        log_status "WARN" "Failed to build modern CLI command, falling back to legacy mode"
        if [[ "$LIVE_OUTPUT" == "true" ]]; then
            log_status "ERROR" "Live mode requires a built Claude command. Falling back to background mode."
            LIVE_OUTPUT=false
        fi
    fi

    # Execute Claude Code
    local exit_code=0

    # Initialize live.log for this execution
    echo -e "\n\n=== Loop #$loop_count - $(date '+%Y-%m-%d %H:%M:%S') ===" > "$LIVE_LOG_FILE"

    if [[ "$LIVE_OUTPUT" == "true" ]]; then
        # LIVE MODE: Show streaming output in real-time using stream-json + jq
        # Based on: https://www.ytyng.com/en/blog/claude-stream-json-jq/
        #
        # Uses CLAUDE_CMD_ARGS from build_claude_command() to preserve:
        # - --allowedTools (tool permissions)
        # - --append-system-prompt (loop context)
        # - --continue (session continuity)
        # - -p (prompt content)

        # Check dependencies for live mode
        if ! command -v awk &> /dev/null; then
            log_status "ERROR" "Live mode requires 'awk' but it's not installed. Falling back to background mode."
            LIVE_OUTPUT=false
        elif ! command -v stdbuf &> /dev/null; then
            log_status "ERROR" "Live mode requires 'stdbuf' (from coreutils) but it's not installed. Falling back to background mode."
            LIVE_OUTPUT=false
        fi
    fi

    if [[ "$LIVE_OUTPUT" == "true" ]]; then
        # Safety check: live mode requires a successfully built modern command
        if [[ "$use_modern_cli" != "true" || ${#CLAUDE_CMD_ARGS[@]} -eq 0 ]]; then
            log_status "ERROR" "Live mode requires a built Claude command. Falling back to background mode."
            LIVE_OUTPUT=false
        fi
    fi

    if [[ "$LIVE_OUTPUT" == "true" ]]; then
        log_status "INFO" "📺 Live output mode enabled - showing Claude Code streaming..."
        echo -e "${PURPLE}━━━━━━━━━━━━━━━━ Claude Code Output ━━━━━━━━━━━━━━━━${NC}"

        # Modify CLAUDE_CMD_ARGS: replace --output-format value with stream-json
        # and add streaming-specific flags
        local -a LIVE_CMD_ARGS=()
        local skip_next=false
        for arg in "${CLAUDE_CMD_ARGS[@]}"; do
            if [[ "$skip_next" == "true" ]]; then
                # Replace "json" with "stream-json" for output format
                LIVE_CMD_ARGS+=("stream-json")
                skip_next=false
            elif [[ "$arg" == "--output-format" ]]; then
                LIVE_CMD_ARGS+=("$arg")
                skip_next=true
            else
                LIVE_CMD_ARGS+=("$arg")
            fi
        done

        # Add streaming-specific flags (--verbose and --include-partial-messages)
        # These are required for stream-json to work properly
        LIVE_CMD_ARGS+=("--verbose" "--include-partial-messages")

        # awk stream filter: compact display with tool context, timing, and progress
        # Replaces the old jq filter with stateful processing that shows:
        # - Tool names with key parameters (file paths, commands, patterns)
        # - Per-tool elapsed time from execution start
        # - Sub-agent events with numbering
        # - Error indicators for failed tool results
        # - Summary stats line at the end
        local start_epoch
        start_epoch=$(date +%s)
        local stream_filter='
{
    line = $0

    # --- Text delta: extract and print Claude text output ---
    if (line ~ /"text_delta"/) {
        txt = line
        sub(/.*"text":"/, "", txt)
        sub(/"[}]*$/, "", txt)
        gsub(/\\n/, "\n", txt)
        gsub(/\\t/, "\t", txt)
        gsub(/\\"/, "\"", txt)
        gsub(/\\\\/, "\\", txt)
        printf "%s", txt
        fflush()
        next
    }

    # --- Tool use start: capture name, reset input accumulator ---
    if (line ~ /"tool_use"/ && line ~ /"content_block_start"/) {
        tc++
        it = 1
        ti = ""
        ct = line
        sub(/.*"name":"/, "", ct)
        sub(/".*/, "", ct)
        next
    }

    # --- Input JSON delta: accumulate tool parameters ---
    if (it && line ~ /"input_json_delta"/) {
        pj = line
        sub(/.*"partial_json":"/, "", pj)
        sub(/"[}]*$/, "", pj)
        gsub(/\\"/, "\"", pj)
        gsub(/\\\\/, "\\", pj)
        ti = ti pj
        next
    }

    # --- Content block stop: emit compact tool summary ---
    if (line ~ /"content_block_stop"/) {
        if (it && ct != "") {
            cmd = "date +%s"
            cmd | getline now
            close(cmd)
            el = now - st
            mn = int(el / 60)
            sc = el % 60

            # Extract key parameter from accumulated tool input
            param = ""
            if (ct == "Read" || ct == "Write" || ct == "Edit") {
                if (ti ~ /"file_path"/) {
                    param = ti
                    sub(/.*"file_path"[[:space:]]*:[[:space:]]*"/, "", param)
                    sub(/".*/, "", param)
                    # Shorten: show last 2-3 path components
                    n = split(param, parts, /[\/\\]/)
                    if (n > 3) param = ".../" parts[n-2] "/" parts[n-1] "/" parts[n]
                    else if (n > 2) param = ".../" parts[n-1] "/" parts[n]
                }
            } else if (ct == "Bash") {
                if (ti ~ /"command"/) {
                    param = ti
                    sub(/.*"command"[[:space:]]*:[[:space:]]*"/, "", param)
                    sub(/".*/, "", param)
                    gsub(/\\n/, " ", param)
                    if (length(param) > 60) param = substr(param, 1, 57) "..."
                }
            } else if (ct == "Glob" || ct == "Grep") {
                if (ti ~ /"pattern"/) {
                    param = ti
                    sub(/.*"pattern"[[:space:]]*:[[:space:]]*"/, "", param)
                    sub(/".*/, "", param)
                }
            } else if (ct == "Agent") {
                if (ti ~ /"description"/) {
                    param = ti
                    sub(/.*"description"[[:space:]]*:[[:space:]]*"/, "", param)
                    sub(/".*/, "", param)
                }
            } else if (ct == "TodoWrite") {
                if (ti ~ /"task"/) {
                    param = ti
                    sub(/.*"task"[[:space:]]*:[[:space:]]*"/, "", param)
                    sub(/".*/, "", param)
                    if (length(param) > 50) param = substr(param, 1, 47) "..."
                }
            }

            # Compact single-line: tool count, name, parameter, elapsed time
            if (param != "")
                printf "  [%d] %s(%s) [%dm%02ds]\n", tc, ct, param, mn, sc
            else
                printf "  [%d] %s [%dm%02ds]\n", tc, ct, mn, sc
            fflush()

            it = 0; ct = ""; ti = ""
        } else {
            it = 0
        }
        next
    }

    # --- Sub-agent started ---
    if (line ~ /"task_started"/) {
        ac++
        desc = line
        if (desc ~ /"description"/) {
            sub(/.*"description"[[:space:]]*:[[:space:]]*"/, "", desc)
            sub(/".*/, "", desc)
        } else {
            desc = "started"
        }
        printf "\n>> Agent #%d: %s\n", ac, desc
        fflush()
        next
    }

    # --- Sub-agent progress ---
    if (line ~ /"task_progress"/) {
        desc = line
        if (desc ~ /"description"/) {
            sub(/.*"description"[[:space:]]*:[[:space:]]*"/, "", desc)
            sub(/".*/, "", desc)
        } else {
            desc = "working..."
        }
        printf "   ...%s\n", desc
        fflush()
        next
    }

    # --- Error in result ---
    if (line ~ /"is_error"[[:space:]]*:[[:space:]]*true/) {
        ec++
        printf "  ❌ Error detected in response\n"
        fflush()
        next
    }

    # --- Suppress all other JSONL events (prevent raw JSON leaking to terminal) ---
    next
}
END {
    cmd = "date +%s"
    cmd | getline now
    close(cmd)
    el = now - st
    mn = int(el / 60)
    sc = el % 60
    printf "\n─── %d tools | %d agents | %d errors | %dm%02ds total ───\n", tc, ac, ec, mn, sc
    fflush()
}'

        # Execute with streaming, preserving all flags from build_claude_command()
        # Use stdbuf to disable buffering for real-time output
        # Use portable_timeout for consistent timeout protection (Issue: missing timeout)
        # Capture all pipeline exit codes for proper error handling
        # stdin must be redirected from /dev/null because newer Claude CLI versions
        # read from stdin even in -p (print) mode, causing the process to hang
        # Redirect stderr to separate file to prevent Node.js warnings (e.g., UNDICI)
        # from corrupting the stream parser pipeline (Issue #190)
        local stderr_file="${LOG_DIR}/claude_stderr_$(date '+%Y%m%d_%H%M%S').log"
        portable_timeout ${timeout_seconds}s stdbuf -oL "${LIVE_CMD_ARGS[@]}" \
            < /dev/null 2>"$stderr_file" | stdbuf -oL tee "$output_file" | stdbuf -oL awk -v st="$start_epoch" -v tc=0 -v ac=0 -v ec=0 -v it=0 -v ct="" -v ti="" "$stream_filter" 2>/dev/null | tee "$LIVE_LOG_FILE"

        # Capture exit codes from pipeline
        local -a pipe_status=("${PIPESTATUS[@]}")

        # Primary exit code is from Claude/timeout (first command in pipeline)
        exit_code=${pipe_status[0]}

        # Log timeout events explicitly (exit code 124 from portable_timeout)
        if [[ $exit_code -eq 124 ]]; then
            log_status "WARN" "Claude Code execution timed out after ${CLAUDE_TIMEOUT_MINUTES} minutes"
        fi

        # Log stderr if non-empty, clean up empty stderr files
        if [[ -s "$stderr_file" ]]; then
            log_status "WARN" "Claude CLI wrote to stderr (see: $stderr_file)"
        else
            rm -f "$stderr_file" 2>/dev/null
        fi

        # Check for tee failures (second command) - could break logging/session
        if [[ ${pipe_status[1]} -ne 0 ]]; then
            log_status "WARN" "Failed to write stream output to log file (exit code ${pipe_status[1]})"
        fi

        # Check for awk stream filter issues (third command) - warn but don't fail
        if [[ ${pipe_status[2]} -ne 0 ]]; then
            log_status "WARN" "Stream filter had issues parsing some events (exit code ${pipe_status[2]})"
        fi

        echo ""
        echo -e "${PURPLE}━━━━━━━━━━━━━━━━ End of Output ━━━━━━━━━━━━━━━━━━━${NC}"

        # Post-execution stats from stream output (logged for monitoring/ralph.log)
        local _tool_count=$(grep -c '"type":"tool_use"' "$output_file" 2>/dev/null || echo 0)
        local _agent_count=$(grep -c '"subtype":"task_started"' "$output_file" 2>/dev/null || echo 0)
        local _error_count=$(grep -c '"is_error":true' "$output_file" 2>/dev/null || echo 0)
        if [[ $_error_count -gt 0 ]]; then
            log_status "WARN" "Execution stats: Tools=$_tool_count Agents=$_agent_count Errors=$_error_count"
        else
            log_status "INFO" "Execution stats: Tools=$_tool_count Agents=$_agent_count Errors=$_error_count"
        fi

        # Extract session ID from stream-json output for session continuity
        # Stream-json format has session_id in the final "result" type message
        # Keep full stream output in _stream.log, extract session data separately
        # WSL2/NTFS 9P: metadata for -f can lag; retry with backoff before skipping extraction
        local _stream_file_visible=false
        if [[ "$CLAUDE_USE_CONTINUE" == "true" ]]; then
            for _wait in 0 0.1 0.2 0.5 1.0; do
                [[ "$_wait" != "0" ]] && sleep "$_wait"
                if [[ -f "$output_file" ]]; then
                    _stream_file_visible=true
                    break
                fi
            done
            if [[ "$_stream_file_visible" != "true" ]]; then
                log_status "WARN" "Output file not visible after 1.8s wait (WSL2/9P race?): $output_file"
            fi
        fi

        if [[ "$CLAUDE_USE_CONTINUE" == "true" && "$_stream_file_visible" == "true" ]]; then
            # Preserve full stream output for analysis (don't overwrite output_file)
            local stream_output_file="${output_file%.log}_stream.log"
            cp "$output_file" "$stream_output_file"

            # Extract the result message and convert to standard JSON format
            # Use flexible regex to match various JSON formatting styles
            # Matches: "type":"result", "type": "result", "type" : "result"
            local result_line=$(grep -E '"type"[[:space:]]*:[[:space:]]*"result"' "$output_file" 2>/dev/null | tail -1)

            if [[ -n "$result_line" ]]; then
                # Validate that extracted line is valid JSON before using it
                if echo "$result_line" | jq -e . >/dev/null 2>&1; then
                    # Write validated result as the output_file for downstream processing
                    # (save_claude_session expects JSON format)
                    echo "$result_line" > "$output_file"
                    log_status "INFO" "Extracted and validated session data from stream output"
                else
                    log_status "WARN" "Extracted result line is not valid JSON, keeping stream output"
                    # Restore original stream output
                    cp "$stream_output_file" "$output_file"
                fi
            else
                log_status "WARN" "Could not find result message in stream output"
                # Fallback: extract session ID from "type":"system" message (Issue #198)
                # The system message is always written first and survives truncation
                local system_line
                system_line=$(grep -E '"type"[[:space:]]*:[[:space:]]*"system"' "$output_file" 2>/dev/null | tail -1)
                if [[ -n "$system_line" ]] && echo "$system_line" | jq -e . >/dev/null 2>&1; then
                    local fallback_session_id
                    fallback_session_id=$(echo "$system_line" | jq -r '.session_id // empty' 2>/dev/null)
                    if [[ -n "$fallback_session_id" ]]; then
                        echo "$fallback_session_id" > "$CLAUDE_SESSION_FILE"
                        log_status "INFO" "Extracted session ID from system message (timeout fallback)"
                    fi
                fi
                # Keep stream output as-is for debugging
            fi
        fi
    else
        # BACKGROUND MODE: Original behavior with progress monitoring
        if [[ "$use_modern_cli" == "true" ]]; then
            # Modern execution with command array (shell-injection safe)
            # Execute array directly without bash -c to prevent shell metacharacter interpretation
            # stdin must be redirected from /dev/null because newer Claude CLI versions
            # read from stdin even in -p (print) mode, causing SIGTTIN suspension
            # when the process is backgrounded
            if portable_timeout ${timeout_seconds}s "${CLAUDE_CMD_ARGS[@]}" < /dev/null > "$output_file" 2>&1 &
            then
                :  # Continue to wait loop
            else
                log_status "ERROR" "❌ Failed to start Claude Code process (modern mode)"
                # Fall back to legacy mode
                log_status "INFO" "Falling back to legacy mode..."
                use_modern_cli=false
            fi
        fi

        # Fall back to legacy stdin piping if modern mode failed or not enabled
        # Note: Legacy mode doesn't use --allowedTools, so tool permissions
        # will be handled by Claude Code's default permission system
        if [[ "$use_modern_cli" == "false" ]]; then
            if portable_timeout ${timeout_seconds}s $CLAUDE_CODE_CMD < "$PROMPT_FILE" > "$output_file" 2>&1 &
            then
                :  # Continue to wait loop
            else
                log_status "ERROR" "❌ Failed to start Claude Code process"
                return 1
            fi
        fi

        # Get PID and monitor progress
        local claude_pid=$!
        RALPH_PIPELINE_PID=$claude_pid  # WSL-2: Track for cleanup handler
        local progress_counter=0

        # Early failure detection: if the command doesn't exist or fails immediately,
        # the backgrounded process dies before the monitoring loop starts (Issue #97)
        sleep 1
        if ! kill -0 $claude_pid 2>/dev/null; then
            wait $claude_pid 2>/dev/null
            local early_exit=$?
            local early_output=""
            if [[ -f "$output_file" && -s "$output_file" ]]; then
                early_output=$(tail -5 "$output_file" 2>/dev/null)
            fi
            log_status "ERROR" "❌ Claude Code process exited immediately (exit code: $early_exit)"
            if [[ -n "$early_output" ]]; then
                log_status "ERROR" "Output: $early_output"
            fi
            echo ""
            echo -e "${RED}Claude Code failed to start.${NC}"
            echo ""
            echo -e "${YELLOW}Possible causes:${NC}"
            echo "  - '${CLAUDE_CODE_CMD}' command not found or not executable"
            echo "  - Claude Code CLI not installed"
            echo "  - Authentication or configuration issue"
            echo ""
            echo -e "${YELLOW}To fix:${NC}"
            echo "  1. Verify Claude Code works: ${CLAUDE_CODE_CMD} --version"
            echo "  2. Or set a different command in .ralphrc: CLAUDE_CODE_CMD=\"npx @anthropic-ai/claude-code\""
            echo ""
            return 1
        fi

        # Show progress while Claude Code is running
        while kill -0 $claude_pid 2>/dev/null; do
            progress_counter=$((progress_counter + 1))
            case $((progress_counter % 4)) in
                1) progress_indicator="⠋" ;;
                2) progress_indicator="⠙" ;;
                3) progress_indicator="⠹" ;;
                0) progress_indicator="⠸" ;;
            esac

            # Get last line from output if available
            local last_line=""
            if [[ -f "$output_file" && -s "$output_file" ]]; then
                last_line=$(tail -1 "$output_file" 2>/dev/null | head -c 80)
                # Copy to live.log for tmux monitoring
                cp "$output_file" "$LIVE_LOG_FILE" 2>/dev/null
            fi

            # Update progress file for monitor
            cat > "$PROGRESS_FILE" << EOF
{
    "status": "executing",
    "indicator": "$progress_indicator",
    "elapsed_seconds": $((progress_counter * 10)),
    "last_output": "$last_line",
    "timestamp": "$(date '+%Y-%m-%d %H:%M:%S')"
}
EOF

            # Only log if verbose mode is enabled
            if [[ "$VERBOSE_PROGRESS" == "true" ]]; then
                if [[ -n "$last_line" ]]; then
                    log_status "INFO" "$progress_indicator Claude Code: $last_line... (${progress_counter}0s)"
                else
                    log_status "INFO" "$progress_indicator Claude Code working... (${progress_counter}0s elapsed)"
                fi
            fi

            sleep 10
        done

        # Wait for the process to finish and get exit code
        wait $claude_pid
        exit_code=$?
    fi

    if [ $exit_code -eq 0 ]; then
        # Check for is_error:true — API error despite exit code 0 (Issue #134, #199)
        # Claude CLI can return exit code 0 with is_error:true for API 400 errors,
        # OAuth token expiry, and tool use concurrency issues.
        # This check MUST happen before progress file write and save_claude_session.
        if [[ -f "$output_file" ]]; then
            local json_is_error
            json_is_error=$(jq -r '.is_error // false' "$output_file" 2>/dev/null || echo "false")
            if [[ "$json_is_error" == "true" ]]; then
                local error_msg
                error_msg=$(jq -r '.result // "unknown API error"' "$output_file" 2>/dev/null || echo "unknown API error")
                log_status "ERROR" "❌ Claude CLI returned is_error:true despite exit code 0: $error_msg"
                echo '{"status": "failed", "error": "is_error:true", "timestamp": "'$(date '+%Y-%m-%d %H:%M:%S')'"}' > "$PROGRESS_FILE"

                # Reset session to prevent infinite retry with bad session ID
                if echo "$error_msg" | grep -qi "tool.use.concurrency\|concurrency"; then
                    reset_session "tool_use_concurrency_error"
                    log_status "WARN" "Session reset due to tool use concurrency error. Retrying with fresh session."
                else
                    reset_session "api_error_is_error_true"
                    log_status "WARN" "Session reset due to API error (is_error:true). Retrying with fresh session."
                fi
                return 1
            fi
        fi

        # Clear progress file (only after is_error check passes)
        echo '{"status": "completed", "timestamp": "'$(date '+%Y-%m-%d %H:%M:%S')'"}' > "$PROGRESS_FILE"

        log_status "SUCCESS" "✅ Claude Code execution completed successfully"

        ralph_prepare_claude_output_for_analysis "$output_file"

        # Save session ID from JSON output (Phase 1.1)
        if [[ "$CLAUDE_USE_CONTINUE" == "true" ]]; then
            save_claude_session "$output_file"
        fi

        # Update exit signals from status.json (written by on-stop.sh hook)
        log_status "INFO" "🔍 Reading response analysis from status.json..."
        if ! update_exit_signals_from_status; then
            log_status "WARN" "Exit signal update failed; continuing with stale signals"
        fi

        # Log analysis summary (non-critical)
        if ! log_status_summary; then
            log_status "WARN" "Analysis summary logging failed; non-critical, continuing"
        fi

        # Get file change count for circuit breaker
        # Fix #141: Detect both uncommitted changes AND committed changes
        local files_changed=0
        local loop_start_sha=""
        local current_sha=""

        if [[ -f "$RALPH_DIR/.loop_start_sha" ]]; then
            loop_start_sha=$(cat "$RALPH_DIR/.loop_start_sha" 2>/dev/null || echo "")
        fi

        if command -v git &>/dev/null && git rev-parse --git-dir &>/dev/null 2>&1; then
            current_sha=$(git rev-parse HEAD 2>/dev/null || echo "")

            # Check if commits were made (HEAD changed)
            if [[ -n "$loop_start_sha" && -n "$current_sha" && "$loop_start_sha" != "$current_sha" ]]; then
                # Commits were made - count union of committed files AND working tree changes
                # This catches cases where Claude commits some files but still has other modified files
                files_changed=$(
                    {
                        git diff --name-only "$loop_start_sha" "$current_sha" 2>/dev/null
                        git diff --name-only HEAD 2>/dev/null           # unstaged changes
                        git diff --name-only --cached 2>/dev/null       # staged changes
                    } | sort -u | wc -l
                )
                [[ "$VERBOSE_PROGRESS" == "true" ]] && log_status "DEBUG" "Detected $files_changed unique files changed (commits + working tree) since loop start"
            else
                # No commits - check for uncommitted changes (staged + unstaged)
                files_changed=$(
                    {
                        git diff --name-only 2>/dev/null                # unstaged changes
                        git diff --name-only --cached 2>/dev/null       # staged changes
                    } | sort -u | wc -l
                )
            fi
        fi

        local has_errors="false"

        # Two-stage error detection to avoid JSON field false positives
        # Stage 1: Filter out JSON field patterns like "is_error": false
        # Stage 2: Look for actual error messages in specific contexts
        # Avoid type annotations like "error: Error" by requiring lowercase after ": error"
        if grep -v '"[^"]*error[^"]*":' "$output_file" 2>/dev/null | \
           grep -qE '(^Error:|^ERROR:|^error:|\]: error|Link: error|Error occurred|failed with error|[Ee]xception|Fatal|FATAL)'; then
            has_errors="true"

            # Debug logging: show what triggered error detection
            if [[ "$VERBOSE_PROGRESS" == "true" ]]; then
                log_status "DEBUG" "Error patterns found:"
                grep -v '"[^"]*error[^"]*":' "$output_file" 2>/dev/null | \
                    grep -nE '(^Error:|^ERROR:|^error:|\]: error|Link: error|Error occurred|failed with error|[Ee]xception|Fatal|FATAL)' | \
                    head -3 | while IFS= read -r line; do
                    log_status "DEBUG" "  $line"
                done
            fi

            log_status "WARN" "Errors detected in output, check: $output_file"
        fi
        local output_length=$(wc -c < "$output_file" 2>/dev/null || echo 0)

        # Check if on-stop.sh hook transitioned circuit breaker to OPEN
        if cb_is_open; then
            log_status "WARN" "Circuit breaker opened - halting execution"
            return 3  # Special code for circuit breaker trip
        fi

        return 0
    else
        # Clear progress file on failure
        echo '{"status": "failed", "timestamp": "'$(date '+%Y-%m-%d %H:%M:%S')'"}' > "$PROGRESS_FILE"

        # Layer 1: Timeout guard — exit code 124 is a timeout, not an API limit
        # Issue #198: Check for productive work before treating as failure
        if [[ $exit_code -eq 124 ]]; then
            log_status "WARN" "⏱️ Claude Code execution timed out (not an API limit)"

            # Check git for actual changes made during the timed-out execution
            local timeout_loop_start_sha=""
            local timeout_current_sha=""
            local timeout_files_changed=0

            if [[ -f "$RALPH_DIR/.loop_start_sha" ]]; then
                timeout_loop_start_sha=$(cat "$RALPH_DIR/.loop_start_sha" 2>/dev/null || echo "")
            fi

            if command -v git &>/dev/null && git rev-parse --git-dir &>/dev/null 2>&1; then
                timeout_current_sha=$(git rev-parse HEAD 2>/dev/null || echo "")

                if [[ -n "$timeout_loop_start_sha" && -n "$timeout_current_sha" && "$timeout_loop_start_sha" != "$timeout_current_sha" ]]; then
                    timeout_files_changed=$(
                        {
                            git diff --name-only "$timeout_loop_start_sha" "$timeout_current_sha" 2>/dev/null
                            git diff --name-only HEAD 2>/dev/null
                            git diff --name-only --cached 2>/dev/null
                        } | sort -u | wc -l
                    )
                else
                    timeout_files_changed=$(
                        {
                            git diff --name-only 2>/dev/null
                            git diff --name-only --cached 2>/dev/null
                        } | sort -u | wc -l
                    )
                fi
            fi

            if [[ $timeout_files_changed -gt 0 ]]; then
                # Productive timeout — work was done despite the timeout
                log_status "INFO" "⏱️ Timeout but $timeout_files_changed file(s) changed — treating iteration as productive"
                echo '{"status": "timed_out_productive", "files_changed": '$timeout_files_changed', "timestamp": "'$(date '+%Y-%m-%d %H:%M:%S')'"}' > "$PROGRESS_FILE"

                ralph_prepare_claude_output_for_analysis "$output_file"

                # Save session ID (fallback already populated by Step 1 if stream was truncated)
                if [[ "$CLAUDE_USE_CONTINUE" == "true" ]]; then
                    save_claude_session "$output_file"
                fi

                # Update exit signals from status.json (written by on-stop.sh hook)
                log_status "INFO" "🔍 Reading response analysis from status.json..."
                if ! update_exit_signals_from_status; then
                    log_status "WARN" "Exit signal update failed; continuing with stale signals"
                fi
                if ! log_status_summary; then
                    log_status "WARN" "Analysis summary logging failed; non-critical, continuing"
                fi

                # Check if on-stop.sh hook transitioned circuit breaker to OPEN
                if cb_is_open; then
                    log_status "WARN" "Circuit breaker opened - halting execution"
                    return 3
                fi

                return 0
            else
                # Idle timeout — no work detected
                log_status "WARN" "⏱️ Timeout with no detectable progress"
                return 1
            fi
        fi  # end timeout

        # Layer 2: Structural JSON detection — check rate_limit_event for status:"rejected"
        # This is the definitive signal from the Claude CLI
        if grep -q '"rate_limit_event"' "$output_file" 2>/dev/null; then
            local last_rate_event
            last_rate_event=$(grep '"rate_limit_event"' "$output_file" | tail -1)
            if echo "$last_rate_event" | grep -qE '"status"\s*:\s*"rejected"'; then
                log_status "ERROR" "🚫 Claude API 5-hour usage limit reached"
                return 2  # Real API limit
            fi
        fi

        # Layer 3: Filtered text fallback — only check tail, excluding tool result lines
        # Filters out type:user, tool_result, and tool_use_id lines which contain echoed file content
        if tail -30 "$output_file" 2>/dev/null | grep -vE '"type"\s*:\s*"user"' | grep -v '"tool_result"' | grep -v '"tool_use_id"' | grep -qi "5.*hour.*limit\|limit.*reached.*try.*back\|usage.*limit.*reached"; then
            log_status "ERROR" "🚫 Claude API 5-hour usage limit reached"
            return 2  # API limit detected via text fallback
        fi

        # Layer 4: Extra Usage quota detection (Issue #100)
        # Claude Code "Extra Usage" mode uses a different error message:
        # "You're out of extra usage · resets 9pm"
        if tail -30 "$output_file" 2>/dev/null | grep -vE '"type"\s*:\s*"user"' | grep -v '"tool_result"' | grep -v '"tool_use_id"' | grep -qi "out of extra usage"; then
            log_status "ERROR" "🚫 Claude Extra Usage quota exhausted"
            return 2  # Extra Usage limit detected
        fi

        log_status "ERROR" "❌ Claude Code execution failed, check: $output_file"
        return 1
    fi
}

# Cleanup function — fires on SIGINT, SIGTERM, and EXIT
cleanup() {
    local trap_exit_code=$?

    # Reentrancy guard — prevent double execution from EXIT + signal combination
    if [[ "$_CLEANUP_DONE" == "true" ]]; then return; fi
    _CLEANUP_DONE=true

    # WSL-2: Kill pipeline children to prevent spurious exit-code-130 log spam
    if [[ -n "${RALPH_PIPELINE_PID:-}" ]]; then
        kill -- -"$RALPH_PIPELINE_PID" 2>/dev/null || kill "$RALPH_PIPELINE_PID" 2>/dev/null || true
        wait "$RALPH_PIPELINE_PID" 2>/dev/null || true
    fi

    if [[ $loop_count -gt 0 ]]; then
        if [[ $trap_exit_code -ne 0 ]]; then
            log_status "ERROR" "Ralph loop crashed (exit code: $trap_exit_code)"
            update_status "$loop_count" "$(cat "$CALL_COUNT_FILE" 2>/dev/null || echo "0")" "crashed" "error" "exit_code_$trap_exit_code"
            # Record crash for startup detection
            echo "$trap_exit_code" > "$RALPH_DIR/.last_crash_code"
        else
            # Normal exit (code 0) — check if status was properly updated
            local current_status
            current_status=$(jq -r '.status' "$STATUS_FILE" 2>/dev/null || echo "unknown")
            if [[ "$current_status" == "running" ]]; then
                log_status "WARN" "Ralph exited normally but status still 'running' — possible silent crash"
                update_status "$loop_count" "$(cat "$CALL_COUNT_FILE" 2>/dev/null || echo "0")" "unexpected_exit" "stopped"
            fi
        fi
    fi
}

# Set up signal handlers (EXIT fires on ANY exit — normal, crash, or signal)
trap cleanup SIGINT SIGTERM EXIT

# Global variable for loop count (needed by cleanup function)
loop_count=0

# Main loop
main() {
    # Load project-specific configuration from .ralphrc
    if load_ralphrc; then
        if [[ "$RALPHRC_LOADED" == "true" ]]; then
            log_status "INFO" "Loaded configuration from .ralphrc"
        fi
    fi

    # Load JSON configuration (takes precedence over .ralphrc)
    if load_json_config; then
        if [[ "$JSON_CONFIG_LOADED" == "true" ]]; then
            log_status "INFO" "Loaded configuration from ralph.config.json"
        fi
    fi

    # Validate Claude Code CLI is available before starting
    if ! validate_claude_command; then
        log_status "ERROR" "Claude Code CLI not found: $CLAUDE_CODE_CMD"
        exit 1
    fi

    # Check CLI version compatibility and auto-update (Issue #190)
    check_claude_version
    check_claude_updates

    # Check for WSL/Windows version divergence
    check_version_divergence

    # Setup agent teams if enabled (Phase 4 — Experimental)
    setup_teams

    log_status "SUCCESS" "🚀 Ralph loop starting with Claude Code"
    log_status "INFO" "Max calls per hour: $MAX_CALLS_PER_HOUR"
    log_status "INFO" "Logs: $LOG_DIR/ | Docs: $DOCS_DIR/ | Status: $STATUS_FILE"

    # Check if project uses old flat structure and needs migration
    if [[ -f "PROMPT.md" ]] && [[ ! -d ".ralph" ]]; then
        log_status "ERROR" "This project uses the old flat structure."
        echo ""
        echo "Ralph v0.10.0+ uses a .ralph/ subfolder to keep your project root clean."
        echo ""
        echo "To upgrade your project, run:"
        echo "  ralph-migrate"
        echo ""
        echo "This will move Ralph-specific files to .ralph/ while preserving src/ at root."
        echo "A backup will be created before migration."
        exit 1
    fi

    # Check if this is a Ralph project directory
    if [[ ! -f "$PROMPT_FILE" ]]; then
        log_status "ERROR" "Prompt file '$PROMPT_FILE' not found!"
        echo ""
        
        # Check if this looks like a partial Ralph project
        if [[ -f "$RALPH_DIR/fix_plan.md" ]] || [[ -d "$RALPH_DIR/specs" ]] || [[ -f "$RALPH_DIR/AGENT.md" ]]; then
            echo "This appears to be a Ralph project but is missing .ralph/PROMPT.md."
            echo "You may need to create or restore the PROMPT.md file."
        else
            echo "This directory is not a Ralph project."
        fi

        echo ""
        echo "To fix this:"
        echo "  1. Enable Ralph in existing project: ralph-enable"
        echo "  2. Create a new project: ralph-setup my-project"
        echo "  3. Import existing requirements: ralph-import requirements.md"
        echo "  4. Navigate to an existing Ralph project directory"
        echo "  5. Or create .ralph/PROMPT.md manually in this directory"
        echo ""
        echo "Ralph projects should contain: .ralph/PROMPT.md, .ralph/fix_plan.md, .ralph/specs/, src/, etc."
        exit 1
    fi

    # File integrity validation removed — PreToolUse hooks handle file protection
    # (protect-ralph-files.sh blocks edits to .ralph/, validate-command.sh blocks destructive commands)

    # Initialize session tracking before entering the loop
    init_session_tracking

    # Detect previous crash (LOOP-5)
    if [[ -f "$RALPH_DIR/.last_crash_code" ]]; then
        local last_crash_code
        last_crash_code=$(cat "$RALPH_DIR/.last_crash_code" 2>/dev/null || echo "unknown")
        log_status "WARN" "Previous Ralph invocation crashed (exit code: $last_crash_code)"
        rm -f "$RALPH_DIR/.last_crash_code"
    fi

    # Detect stale "running" status from a crashed run
    if [[ -f "$STATUS_FILE" ]]; then
        local stale_status
        stale_status=$(jq -r '.status' "$STATUS_FILE" 2>/dev/null || echo "unknown")
        if [[ "$stale_status" == "running" ]]; then
            log_status "WARN" "Previous run left status as 'running' — likely crashed during execution"
        fi
    fi

    # Reset exit signals to prevent stale state from prior run causing premature exit (Issue #194)
    # This is unconditional: regardless of how the previous run ended (crash, SIGKILL, API limit exit),
    # every new ralph invocation starts with a clean exit-signal slate.
    echo '{"test_only_loops": [], "done_signals": [], "completion_indicators": []}' > "$EXIT_SIGNALS_FILE"
    log_status "INFO" "Reset exit signals for fresh start"

    # Reset per-session circuit breaker counters (preserve OPEN/CLOSED state and thresholds)
    if [[ -f "$RALPH_DIR/.circuit_breaker_state" ]]; then
        if jq '.consecutive_no_progress = 0 |
            .consecutive_same_error = 0 |
            .consecutive_permission_denials = 0 |
            .current_loop = 0 |
            .last_progress_loop = 0' \
            "$RALPH_DIR/.circuit_breaker_state" > "${RALPH_DIR}/.circuit_breaker_state.tmp" 2>/dev/null && \
            mv "${RALPH_DIR}/.circuit_breaker_state.tmp" "$RALPH_DIR/.circuit_breaker_state"
        then
            log_status "INFO" "Reset circuit breaker counters for new session"
        fi
    fi

    # Optional: warn if Docker MCP containers (label ralph.mcp=true) are not running
    if command -v docker >/dev/null 2>&1; then
        local mcp_containers_down=()
        while IFS= read -r container; do
            [[ -z "$container" ]] && continue
            if ! docker inspect --format='{{.State.Running}}' "$container" 2>/dev/null | grep -q "true"; then
                mcp_containers_down+=("$container")
            fi
        done < <(docker ps -a --filter "label=ralph.mcp=true" --format '{{.Names}}' 2>/dev/null)

        if [[ ${#mcp_containers_down[@]} -gt 0 ]]; then
            log_status "WARN" "MCP containers not running: ${mcp_containers_down[*]}"
            log_status "INFO" "Start with: docker compose up -d (or check docker-compose.yml)"
        fi
    fi

    # Persistent loop counter — tracks total loops across restarts (LOOP-5)
    local persistent_loop_file="$RALPH_DIR/.total_loop_count"
    local persistent_loops=0
    if [[ -f "$persistent_loop_file" ]]; then
        persistent_loops=$(cat "$persistent_loop_file" 2>/dev/null || echo "0")
        persistent_loops=$((persistent_loops + 0))
    fi

    # Perform initial log rotation at startup
    rotate_ralph_log
    cleanup_old_output_logs

    # WSL-1: Clean stale temp files from previous runs (cross-fs orphans)
    find "$RALPH_DIR" -name "status.json.*" -mmin +60 -delete 2>/dev/null || true
    find "$RALPH_DIR" -name ".circuit_breaker_state.*" -mmin +60 -delete 2>/dev/null || true

    if [[ "$DRY_RUN" == "true" ]]; then
        log_status "INFO" "DRY-RUN MODE: No API calls will be made"
    fi

    log_status "INFO" "Starting main loop..."

    while true; do
        loop_count=$((loop_count + 1))
        persistent_loops=$((persistent_loops + 1))
        echo "$persistent_loops" > "$persistent_loop_file"

        # Update session last_used timestamp
        update_session_last_used

        log_status "INFO" "Loop #$loop_count (total: #$persistent_loops) - calling init_call_tracking..."
        init_call_tracking

        log_status "LOOP" "=== Starting Loop #$loop_count (total: #$persistent_loops) ==="
        
        # File integrity validation removed — PreToolUse hooks handle file protection in real-time

        # Check circuit breaker before attempting execution
        if should_halt_execution; then
            reset_session "circuit_breaker_open"
            update_status "$loop_count" "$(cat "$CALL_COUNT_FILE")" "circuit_breaker_open" "halted" "stagnation_detected"
            log_status "ERROR" "🛑 Circuit breaker has opened - execution halted"
            break
        fi

        # Check rate limits
        if ! can_make_call; then
            wait_for_reset
            continue
        fi

        # Check for graceful exit conditions
        local exit_reason=$(should_exit_gracefully)
        if [[ "$exit_reason" != "" ]]; then
            # Handle permission_denied specially (Issue #101)
            if [[ "$exit_reason" == "permission_denied" ]]; then
                log_status "ERROR" "🚫 Permission denied - halting loop"
                reset_session "permission_denied"
                update_status "$loop_count" "$(cat "$CALL_COUNT_FILE")" "permission_denied" "halted" "permission_denied"

                # Display helpful guidance for resolving permission issues
                echo ""
                echo -e "${RED}╔════════════════════════════════════════════════════════════╗${NC}"
                echo -e "${RED}║  PERMISSION DENIED - Loop Halted                          ║${NC}"
                echo -e "${RED}╚════════════════════════════════════════════════════════════╝${NC}"
                echo ""
                echo -e "${YELLOW}Claude Code was denied permission to execute commands.${NC}"
                echo ""
                echo -e "${YELLOW}To fix this:${NC}"
                echo "  1. Edit .ralphrc and update ALLOWED_TOOLS to include the required tools"
                echo "  2. Common patterns:"
                echo "     - Bash(npm *)     - All npm commands"
                echo "     - Bash(npm install) - Only npm install"
                echo "     - Bash(pnpm *)    - All pnpm commands"
                echo "     - Bash(yarn *)    - All yarn commands"
                echo ""
                echo -e "${YELLOW}After updating .ralphrc:${NC}"
                echo "  ralph --reset-session  # Clear stale session state"
                echo "  ralph --monitor        # Restart the loop"
                echo ""

                # Show current ALLOWED_TOOLS if .ralphrc exists
                if [[ -f ".ralphrc" ]]; then
                    local current_tools=$(grep "^ALLOWED_TOOLS=" ".ralphrc" 2>/dev/null | cut -d= -f2- | tr -d '"')
                    if [[ -n "$current_tools" ]]; then
                        echo -e "${BLUE}Current ALLOWED_TOOLS:${NC} $current_tools"
                        echo ""
                    fi
                fi

                break
            fi

            log_status "SUCCESS" "🏁 Graceful exit triggered: $exit_reason"
            reset_session "project_complete"
            update_status "$loop_count" "$(cat "$CALL_COUNT_FILE")" "graceful_exit" "completed" "$exit_reason"

            log_status "SUCCESS" "🎉 Ralph has completed the project! Final stats:"
            log_status "INFO" "  - Total loops: $loop_count"
            log_status "INFO" "  - API calls used: $(cat "$CALL_COUNT_FILE")"
            log_status "INFO" "  - Exit reason: $exit_reason"

            break
        fi
        
        # Rotate logs periodically (every loop iteration)
        rotate_ralph_log

        # Update status
        local calls_made=$(cat "$CALL_COUNT_FILE" 2>/dev/null || echo "0")
        update_status "$loop_count" "$calls_made" "executing" "running"

        # Dry-run mode: simulate execution without calling Claude Code
        if [[ "$DRY_RUN" == "true" ]]; then
            dry_run_simulate "" "$loop_count"
            log_status "INFO" "[DRY-RUN] Loop #$loop_count complete. Exiting after single dry-run iteration."
            break
        fi

        # Execute Claude Code
        execute_claude_code "$loop_count"
        local exec_result=$?
        
        if [ $exec_result -eq 0 ]; then
            update_status "$loop_count" "$(cat "$CALL_COUNT_FILE")" "completed" "success"

            # Brief pause between successful executions
            sleep 5
        elif [ $exec_result -eq 3 ]; then
            # Circuit breaker opened
            reset_session "circuit_breaker_trip"
            update_status "$loop_count" "$(cat "$CALL_COUNT_FILE")" "circuit_breaker_open" "halted" "stagnation_detected"
            log_status "ERROR" "🛑 Circuit breaker has opened - halting loop"
            log_status "INFO" "Run 'ralph --reset-circuit' to reset the circuit breaker after addressing issues"
            break
        elif [ $exec_result -eq 2 ]; then
            # API 5-hour limit reached - handle specially
            update_status "$loop_count" "$(cat "$CALL_COUNT_FILE")" "api_limit" "paused"
            log_status "WARN" "🛑 Claude API 5-hour limit reached!"
            
            # Ask user whether to wait or exit
            echo -e "\n${YELLOW}A Claude API usage limit has been reached (5-hour plan limit or Extra Usage quota).${NC}"
            echo -e "${YELLOW}You can either:${NC}"
            echo -e "  ${GREEN}1)${NC} Wait for the limit to reset (usually within an hour)"
            echo -e "  ${GREEN}2)${NC} Exit the loop and try again later"
            echo -e "\n${BLUE}Choose an option (1 or 2):${NC} "
            
            # Read user input with timeout
            read -t 30 -n 1 user_choice || true
            echo  # New line after input
            
            if [[ "$user_choice" == "2" ]]; then
                log_status "INFO" "User chose to exit. Exiting loop..."
                reset_session "api_limit_exit"
                update_status "$loop_count" "$(cat "$CALL_COUNT_FILE")" "api_limit_exit" "stopped" "api_5hour_limit"
                break
            else
                # Auto-wait on timeout (empty choice) or explicit "1" — supports unattended operation
                log_status "INFO" "Waiting for API limit reset (auto-wait for unattended mode)..."
                # Wait for longer period when API limit is hit
                local wait_minutes=60
                log_status "INFO" "Waiting $wait_minutes minutes before retrying..."
                
                # Countdown display
                local wait_seconds=$((wait_minutes * 60))
                while [[ $wait_seconds -gt 0 ]]; do
                    local minutes=$((wait_seconds / 60))
                    local seconds=$((wait_seconds % 60))
                    printf "\r${YELLOW}Time until retry: %02d:%02d${NC}" $minutes $seconds
                    sleep 1
                    ((wait_seconds--))
                done
                printf "\n"
            fi
        else
            update_status "$loop_count" "$(cat "$CALL_COUNT_FILE")" "failed" "error"
            log_status "WARN" "Execution failed, waiting 30 seconds before retry..."
            sleep 30
        fi
        
        log_status "LOOP" "=== Completed Loop #$loop_count ==="
    done
}

# Help function
show_help() {
    cat << HELPEOF
Ralph Loop for Claude Code

Usage: $0 [OPTIONS]

IMPORTANT: This command must be run from a Ralph project directory.
           Use 'ralph-setup project-name' to create a new project first.

Options:
    -V, --version           Show version and exit
    -h, --help              Show this help message
    -c, --calls NUM         Set max calls per hour (default: $MAX_CALLS_PER_HOUR)
    -p, --prompt FILE       Set prompt file (default: $PROMPT_FILE)
    -s, --status            Show current status and exit
    -m, --monitor           Start with tmux session and live monitor (requires tmux)
    -v, --verbose           Show detailed progress updates during execution
    -l, --live              Show Claude Code output in real-time (auto-switches to JSON output)
    -t, --timeout MIN       Set Claude Code execution timeout in minutes (default: $CLAUDE_TIMEOUT_MINUTES)
    --reset-circuit         Reset circuit breaker to CLOSED state
    --circuit-status        Show circuit breaker status and exit
    --auto-reset-circuit    Auto-reset circuit breaker on startup (bypasses cooldown)
    --reset-session         Reset session state and exit (clears session continuity)

Modern CLI Options (Phase 1.1):
    --output-format FORMAT  Set Claude output format: json or text (default: $CLAUDE_OUTPUT_FORMAT)
                            Note: --live mode requires JSON and will auto-switch
    --allowed-tools TOOLS   Comma-separated list of allowed tools (default: $CLAUDE_ALLOWED_TOOLS)
    --no-continue           Disable session continuity across loops
    --session-expiry HOURS  Set session expiration time in hours (default: $CLAUDE_SESSION_EXPIRY_HOURS)
    --dry-run               Preview loop execution without calling Claude Code API
    --log-max-size MB       Set max ralph.log size before rotation (default: $LOG_MAX_SIZE_MB)
    --log-max-files NUM     Set max rotated log files to keep (default: $LOG_MAX_FILES)

SDK Mode (Phase 6 — v1.3.0):
    --sdk                   Run in SDK mode (Python Agent SDK instead of bash loop)
    --sdk-model MODEL       Set Claude model for SDK mode (default: claude-sonnet-4-20250514)
    --sdk-max-turns NUM     Set max turns per iteration in SDK mode (default: 50)

Observability (Phase 8 — v1.5.0):
    --stats                 Show metrics summary and exit
    --stats-json            Show metrics as JSON and exit
    --stats-last PERIOD     Filter metrics by period (e.g., 7d, 30d, 24h)
    --rollback              Restore latest backup with confirmation
    --rollback-list         Show available backups

GitHub Issues (Phase 10 — v1.7.0):
    --issue NUM             Import GitHub issue into fix_plan.md
    --issues                List open GitHub issues
    --issue-label LABEL     Filter issues by label
    --issue-assignee USER   Filter issues by assignee
    --assess-only           Show issue assessment without importing
    --batch                 Process multiple issues sequentially
    --batch-issues NUMS     Comma-separated issue numbers for batch
    --stop-on-failure       Stop batch processing on first failure

Sandbox (Phase 11 — v1.8.0):
    --sandbox               Run loop inside Docker container
    --sandbox-required      Fail if Docker not available (instead of fallback)

Files created:
    - $LOG_DIR/: All execution logs
    - $DOCS_DIR/: Generated documentation
    - $STATUS_FILE: Current status (JSON)
    - .ralph/.ralph_session: Session lifecycle tracking
    - .ralph/.ralph_session_history: Session transition history (last 50)
    - .ralph/.call_count: API call counter for rate limiting
    - .ralph/.last_reset: Timestamp of last rate limit reset

Behavior notes (v1.2.0+):
    - --live uses stream-json output: full stream preserved (*_stream.log), result line
      extracted when possible; WSL2/NTFS mounts retry file visibility before extraction.
    - Before each loop iteration: JSONL stream extraction isolates the result object;
      permission denials and failed MCP servers logged from raw output.
    - Analysis via on-stop.sh hook → status.json (RALPH_STATUS fields auto-unescaped).
    - Subagent result objects are filtered from multi-result count (no false violations).
    - New ralph invocation resets circuit breaker *counters* (not OPEN/CLOSED state).
    - Stale temp files (status.json.*, .circuit_breaker_state.*) cleaned on startup.
    - Pipeline children are killed cleanly on SIGINT (no spurious exit-130 warnings).

Example workflow:
    ralph-setup my-project     # Create project
    cd my-project             # Enter project directory
    $0 --monitor             # Start Ralph with monitoring

Examples:
    $0 --calls 50 --prompt my_prompt.md
    $0 --monitor             # Start with integrated tmux monitoring
    $0 --live                # Show Claude Code output in real-time (streaming)
    $0 --live --verbose      # Live streaming + verbose logging
    $0 --monitor --timeout 30   # 30-minute timeout for complex tasks
    $0 --verbose --timeout 5    # 5-minute timeout with detailed progress
    $0 --output-format text     # Use legacy text output format
    $0 --no-continue            # Disable session continuity
    $0 --session-expiry 48      # 48-hour session expiration
    $0 --dry-run                # Preview execution without API calls
    $0 --log-max-size 20        # Rotate ralph.log at 20 MB

HELPEOF
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -V|--version)
            echo "ralph $RALPH_VERSION"
            exit 0
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        -c|--calls)
            MAX_CALLS_PER_HOUR="$2"
            shift 2
            ;;
        -p|--prompt)
            PROMPT_FILE="$2"
            shift 2
            ;;
        -s|--status)
            if [[ -f "$STATUS_FILE" ]]; then
                echo "Current Status:"
                cat "$STATUS_FILE" | jq . 2>/dev/null || cat "$STATUS_FILE"
            else
                echo "No status file found. Ralph may not be running."
            fi
            exit 0
            ;;
        -m|--monitor)
            USE_TMUX=true
            shift
            ;;
        -v|--verbose)
            VERBOSE_PROGRESS=true
            shift
            ;;
        -l|--live)
            LIVE_OUTPUT=true
            shift
            ;;
        -t|--timeout)
            if [[ "$2" =~ ^[1-9][0-9]*$ ]] && [[ "$2" -le 120 ]]; then
                CLAUDE_TIMEOUT_MINUTES="$2"
            else
                echo "Error: Timeout must be a positive integer between 1 and 120 minutes"
                exit 1
            fi
            shift 2
            ;;
        --reset-circuit)
            # Source the circuit breaker library
            SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
            source "$SCRIPT_DIR/lib/circuit_breaker.sh"
            source "$SCRIPT_DIR/lib/date_utils.sh"
            reset_circuit_breaker "Manual reset via command line"
            reset_session "manual_circuit_reset"
            exit 0
            ;;
        --reset-session)
            # Reset session state only
            SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
            source "$SCRIPT_DIR/lib/date_utils.sh"
            reset_session "manual_reset_flag"
            echo -e "\033[0;32m✅ Session state reset successfully\033[0m"
            exit 0
            ;;
        --circuit-status)
            # Source the circuit breaker library
            SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
            source "$SCRIPT_DIR/lib/circuit_breaker.sh"
            show_circuit_status
            exit 0
            ;;
        --output-format)
            if [[ "$2" == "json" || "$2" == "text" ]]; then
                CLAUDE_OUTPUT_FORMAT="$2"
            else
                echo "Error: --output-format must be 'json' or 'text'"
                exit 1
            fi
            shift 2
            ;;
        --allowed-tools)
            if ! validate_allowed_tools "$2"; then
                exit 1
            fi
            CLAUDE_ALLOWED_TOOLS="$2"
            shift 2
            ;;
        --no-continue)
            CLAUDE_USE_CONTINUE=false
            shift
            ;;
        --session-expiry)
            if [[ -z "$2" || ! "$2" =~ ^[1-9][0-9]*$ ]]; then
                echo "Error: --session-expiry requires a positive integer (hours)"
                exit 1
            fi
            CLAUDE_SESSION_EXPIRY_HOURS="$2"
            shift 2
            ;;
        --auto-reset-circuit)
            CB_AUTO_RESET=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --log-max-size)
            if [[ -z "$2" || ! "$2" =~ ^[1-9][0-9]*$ ]]; then
                echo "Error: --log-max-size requires a positive integer (MB)"
                exit 1
            fi
            LOG_MAX_SIZE_MB="$2"
            shift 2
            ;;
        --log-max-files)
            if [[ -z "$2" || ! "$2" =~ ^[1-9][0-9]*$ ]]; then
                echo "Error: --log-max-files requires a positive integer"
                exit 1
            fi
            LOG_MAX_FILES="$2"
            shift 2
            ;;
        --sdk)
            RALPH_SDK_MODE=true
            shift
            ;;
        --sdk-model)
            RALPH_SDK_MODEL="$2"
            shift 2
            ;;
        --sdk-max-turns)
            RALPH_SDK_MAX_TURNS="$2"
            shift 2
            ;;
        --stats)
            ralph_show_stats
            exit 0
            ;;
        --stats-json)
            ralph_show_stats --json
            exit 0
            ;;
        --stats-last)
            ralph_show_stats --last "$2"
            shift 2
            exit 0
            ;;
        --rollback)
            ralph_rollback
            exit $?
            ;;
        --rollback-list)
            ralph_rollback --list
            exit 0
            ;;
        --issue)
            RALPH_GITHUB_ISSUE="$2"
            shift 2
            ;;
        --issues)
            ralph_list_issues
            exit 0
            ;;
        --issue-label)
            RALPH_ISSUE_LABEL="$2"
            shift 2
            ;;
        --issue-assignee)
            RALPH_ISSUE_ASSIGNEE="$2"
            shift 2
            ;;
        --assess-only)
            RALPH_ASSESS_ONLY=true
            shift
            ;;
        --batch)
            RALPH_BATCH_MODE=true
            shift
            ;;
        --batch-issues)
            RALPH_BATCH_ISSUES="$2"
            shift 2
            ;;
        --stop-on-failure)
            RALPH_STOP_ON_FAILURE=true
            shift
            ;;
        --sandbox)
            RALPH_SANDBOX_MODE=true
            shift
            ;;
        --sandbox-required)
            RALPH_SANDBOX_REQUIRED=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Only execute when run directly, not when sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    # SDK mode dispatch (Phase 6 — v1.3.0)
    if [[ "${RALPH_SDK_MODE:-false}" == "true" ]]; then
        SDK_CMD="python -m ralph_sdk"
        SDK_ARGS=("--project-dir" ".")

        # Forward relevant flags
        [[ "${DRY_RUN:-false}" == "true" ]] && SDK_ARGS+=("--dry-run")
        [[ -n "${RALPH_SDK_MODEL:-}" ]] && SDK_ARGS+=("--model" "$RALPH_SDK_MODEL")
        [[ -n "${RALPH_SDK_MAX_TURNS:-}" ]] && SDK_ARGS+=("--max-turns" "$RALPH_SDK_MAX_TURNS")
        [[ "${VERBOSE_PROGRESS:-false}" == "true" ]] && SDK_ARGS+=("--verbose")
        SDK_ARGS+=("--calls" "$MAX_CALLS_PER_HOUR")
        SDK_ARGS+=("--timeout" "$CLAUDE_TIMEOUT_MINUTES")

        # Check SDK availability
        RALPH_SDK_DIR="$SCRIPT_DIR/sdk"
        if [[ -d "$RALPH_SDK_DIR/.venv" ]]; then
            # Use venv Python
            if [[ -f "$RALPH_SDK_DIR/.venv/bin/python" ]]; then
                SDK_CMD="$RALPH_SDK_DIR/.venv/bin/python -m ralph_sdk"
            elif [[ -f "$RALPH_SDK_DIR/.venv/Scripts/python.exe" ]]; then
                SDK_CMD="$RALPH_SDK_DIR/.venv/Scripts/python.exe -m ralph_sdk"
            fi
        fi

        # Add SDK to PYTHONPATH
        export PYTHONPATH="$RALPH_SDK_DIR:${PYTHONPATH:-}"

        echo -e "${GREEN}╔══════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║  Ralph SDK Mode (Python Agent SDK)   ║${NC}"
        echo -e "${GREEN}╚══════════════════════════════════════╝${NC}"

        exec $SDK_CMD "${SDK_ARGS[@]}"
    fi

    # GitHub issue import (Phase 10 — v1.7.0)
    if [[ -n "${RALPH_GITHUB_ISSUE:-}" ]]; then
        source "$SCRIPT_DIR/lib/github_issues.sh" 2>/dev/null || {
            echo "Error: GitHub issue integration not available. Install Ralph v1.7.0+"
            exit 1
        }
        ralph_import_issue "$RALPH_GITHUB_ISSUE"
        [[ "${RALPH_ASSESS_ONLY:-false}" == "true" ]] && exit 0
    fi

    # Batch mode (Phase 10 — v1.7.0)
    if [[ "${RALPH_BATCH_MODE:-false}" == "true" ]]; then
        source "$SCRIPT_DIR/lib/github_issues.sh" 2>/dev/null || {
            echo "Error: GitHub issue integration not available. Install Ralph v1.7.0+"
            exit 1
        }
        ralph_batch_process
        exit $?
    fi

    # Sandbox mode (Phase 11 — v1.8.0)
    if [[ "${RALPH_SANDBOX_MODE:-false}" == "true" ]]; then
        source "$SCRIPT_DIR/lib/sandbox.sh" 2>/dev/null || {
            echo "Error: Sandbox module not available. Install Ralph v1.8.0+"
            exit 1
        }
        ralph_sandbox_run "$@"
        exit $?
    fi

    # If tmux mode requested, set it up
    if [[ "$USE_TMUX" == "true" ]]; then
        check_tmux_available
        setup_tmux_session
    fi

    # Start the main loop
    main
fi
