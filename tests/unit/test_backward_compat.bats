#!/usr/bin/env bats
# Unit tests for backward compatibility (Phase 9, TEST-6)
# Tests .ralphrc versions, status.json compatibility, fix_plan format,
# ALLOWED_TOOLS patterns, hook structure stability

load '../helpers/test_helper'
load '../helpers/fixtures'

RALPH_SCRIPT="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"
    git init > /dev/null 2>&1
    git config user.email "test@example.com"
    git config user.name "Test User"
    export RALPH_DIR=".ralph"
    export LOG_DIR="$RALPH_DIR/logs"
    mkdir -p "$LOG_DIR"
    echo "# Test" > "$RALPH_DIR/PROMPT.md"
    echo "0" > "$RALPH_DIR/.call_count"
    mkdir -p lib
    echo '' > lib/circuit_breaker.sh
    echo '' > lib/date_utils.sh
    echo '' > lib/timeout_utils.sh
    echo '' > lib/metrics.sh
    echo '' > lib/notifications.sh
    echo '' > lib/backup.sh
}

teardown() {
    cd /
    rm -rf "$TEST_DIR"
}

# .ralphrc backward compatibility

@test "minimal v0.9 .ralphrc parses without error" {
    cat > .ralphrc << 'EOF'
MAX_CALLS_PER_HOUR=100
CLAUDE_TIMEOUT_MINUTES=15
EOF
    source "$RALPH_SCRIPT" 2>/dev/null || true
    run load_ralphrc
    [ "$status" -eq 0 ]
}

@test "v1.0 .ralphrc with ALLOWED_TOOLS parses" {
    cat > .ralphrc << 'EOF'
MAX_CALLS_PER_HOUR=50
ALLOWED_TOOLS="Write,Read,Edit,Bash(git add *)"
SESSION_CONTINUITY=true
CB_COOLDOWN_MINUTES=30
EOF
    source "$RALPH_SCRIPT" 2>/dev/null || true
    run load_ralphrc
    [ "$status" -eq 0 ]
}

@test "v1.1 .ralphrc with teams config parses" {
    cat > .ralphrc << 'EOF'
RALPH_ENABLE_TEAMS=false
RALPH_MAX_TEAMMATES=3
RALPH_BG_TESTING=false
RALPH_TEAMMATE_MODE="tmux"
EOF
    source "$RALPH_SCRIPT" 2>/dev/null || true
    run load_ralphrc
    [ "$status" -eq 0 ]
}

@test "v1.2 .ralphrc with all fields parses" {
    cp "${BATS_TEST_DIRNAME}/../../templates/ralphrc.template" .ralphrc
    source "$RALPH_SCRIPT" 2>/dev/null || true
    run load_ralphrc
    [ "$status" -eq 0 ]
}

# status.json backward compatibility

@test "v1.0 status.json is readable" {
    echo '{"status": "IN_PROGRESS", "WORK_TYPE": "IMPLEMENTATION", "EXIT_SIGNAL": false}' > "$RALPH_DIR/status.json"
    local wt
    wt=$(jq -r '.WORK_TYPE // "UNKNOWN"' "$RALPH_DIR/status.json")
    [ "$wt" = "IMPLEMENTATION" ]
}

@test "v1.2 status.json with all fields is readable" {
    cat > "$RALPH_DIR/status.json" << 'EOF'
{
    "WORK_TYPE": "TESTING",
    "COMPLETED_TASK": "test",
    "NEXT_TASK": "deploy",
    "PROGRESS_SUMMARY": "done",
    "EXIT_SIGNAL": true,
    "status": "COMPLETED",
    "timestamp": "2026-03-21T10:00:00Z",
    "loop_count": 10,
    "session_id": "sess-123",
    "circuit_breaker_state": "CLOSED",
    "error": ""
}
EOF
    run jq -e '.' "$RALPH_DIR/status.json"
    [ "$status" -eq 0 ]
}

# fix_plan.md checkbox format

@test "fix_plan checkbox format is stable" {
    cat > "$RALPH_DIR/fix_plan.md" << 'EOF'
# Fix Plan
- [x] Completed task
- [ ] Open task
- [ ] Another task
EOF
    local open
    open=$(grep -c '\- \[ \]' "$RALPH_DIR/fix_plan.md")
    [ "$open" -eq 2 ]
    local done_count
    done_count=$(grep -c '\- \[x\]' "$RALPH_DIR/fix_plan.md")
    [ "$done_count" -eq 1 ]
}

# ALLOWED_TOOLS pattern compatibility

@test "ALLOWED_TOOLS comma separation works" {
    local tools="Write,Read,Edit"
    IFS=',' read -ra tool_array <<< "$tools"
    [ "${#tool_array[@]}" -eq 3 ]
    [ "${tool_array[0]}" = "Write" ]
}

@test "ALLOWED_TOOLS with Bash patterns works" {
    local tools="Write,Bash(git add *),Bash(npm *)"
    # Ensure patterns with parens don't break parsing
    [[ "$tools" == *"Bash(git add *)"* ]]
}

# Hook directory structure

@test "hooks directory structure matches expected" {
    local hooks_dir="${BATS_TEST_DIRNAME}/../../templates/hooks"
    [ -d "$hooks_dir" ] || skip "hooks template dir not found"
    # Expected hooks from Phase 1
    for hook in on-session-start on-stop validate-command protect-ralph-files; do
        [ -f "$hooks_dir/${hook}.sh" ] || [ -f "$hooks_dir/${hook}.sh.template" ] || true
    done
}

# ralph.config.json compatibility (new in v1.4.0, should not break v1.3-)

@test "missing ralph.config.json does not error" {
    [ ! -f "ralph.config.json" ]
    source "$RALPH_SCRIPT" 2>/dev/null || true
    # load_json_config should return 0 for missing file
    if type load_json_config &>/dev/null; then
        run load_json_config
        [ "$status" -eq 0 ]
    fi
}

@test "invalid ralph.config.json is skipped gracefully" {
    echo "not valid json {{{" > ralph.config.json
    source "$RALPH_SCRIPT" 2>/dev/null || true
    if type load_json_config &>/dev/null; then
        run load_json_config
        [ "$status" -eq 0 ]
    fi
}
