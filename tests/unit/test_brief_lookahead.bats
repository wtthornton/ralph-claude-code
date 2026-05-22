#!/usr/bin/env bats
# T4 / 2.15.9: brief lookahead — brief-next.json consume + on-stop extract +
# prewarm guards.

bats_require_minimum_version 1.5.0

REPO_ROOT_FIXED="${BATS_TEST_DIRNAME}/../.."

setup() {
    export TEST_TEMP_DIR="$(mktemp -d "${BATS_TEST_TMPDIR:-/tmp}/t4_lookahead.XXXXXX")"
    cd "$TEST_TEMP_DIR"
    mkdir -p .ralph/logs
    export RALPH_DIR="$TEST_TEMP_DIR/.ralph"
    export LOG_DIR="$RALPH_DIR/logs"
    export DRY_RUN=false
    set --
    # shellcheck disable=SC1090
    source "$REPO_ROOT_FIXED/ralph_loop.sh"
    export RALPH_TASK_SOURCE=linear
    export RALPH_LINEAR_PROJECT="test-project"
    # Stub Linear helpers — OAuth-via-MCP mode returns empty.
    linear_get_in_progress_task() { return 1; }
    linear_get_next_task() { return 1; }
    linear_get_open_count() { echo 5; return 0; }
    export -f linear_get_in_progress_task linear_get_next_task linear_get_open_count
    # Disable the coordinator spawn — we only test the consume path.
    export RALPH_COORDINATOR_DISABLED=true
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR" 2>/dev/null || true
}

write_brief_next() {
    local task_id="$1"
    cat > "$RALPH_DIR/brief-next.json" <<EOF
{
  "schema_version": 1,
  "task_id": "$task_id",
  "task_source": "linear",
  "task_summary": "Lookahead-prewarmed task for $task_id.",
  "risk_level": "LOW",
  "affected_modules": ["lib/foo.sh"],
  "acceptance_criteria": ["does the thing"],
  "prior_learnings": [],
  "qa_required": true,
  "delegate_to": "ralph",
  "coordinator_confidence": 0.9,
  "created_at": "2026-05-22T16:00:00Z"
}
EOF
}

@test "T4: consume promotes brief-next.json when task_id matches .next_intended_issue" {
    write_brief_next "TAP-2001"
    echo "TAP-2001" > "$RALPH_DIR/.next_intended_issue"
    [[ ! -e "$RALPH_DIR/brief.json" ]]

    # RALPH_COORDINATOR_DISABLED=true makes ralph_spawn_coordinator return 0
    # after the T4 consume block — so we need to disable that guard for this
    # test and rely on the consume + cache miss + (now-stubbed) spawn-failure
    # path. Simpler: invoke the consume by removing the disable guard but
    # stub out _coordinator_invoke_claude.
    unset RALPH_COORDINATOR_DISABLED
    _coordinator_invoke_claude() { return 1; }
    export -f _coordinator_invoke_claude

    run ralph_spawn_coordinator 1
    [[ "$status" -eq 0 ]] || fail "spawn returned $status"
    [[ -s "$RALPH_DIR/brief.json" ]] || fail "brief.json was not created"
    local promoted_id
    promoted_id=$(jq -r '.task_id' "$RALPH_DIR/brief.json")
    [[ "$promoted_id" == "TAP-2001" ]] || fail "wrong task_id: $promoted_id"
    [[ ! -e "$RALPH_DIR/brief-next.json" ]] || fail "brief-next.json should have been consumed"
    [[ ! -e "$RALPH_DIR/.next_intended_issue" ]] || fail ".next_intended_issue should have been cleared"
}

@test "T4: consume rejects mismatched task_id, drops the stale brief-next" {
    write_brief_next "TAP-2001"
    echo "TAP-9999" > "$RALPH_DIR/.next_intended_issue"
    unset RALPH_COORDINATOR_DISABLED
    _coordinator_invoke_claude() { return 1; }
    export -f _coordinator_invoke_claude

    run ralph_spawn_coordinator 1
    [[ "$status" -eq 0 ]] || fail "spawn returned $status"
    [[ ! -e "$RALPH_DIR/brief.json" ]] || fail "brief.json should NOT have been written from mismatched brief-next"
    [[ ! -e "$RALPH_DIR/brief-next.json" ]] || fail "stale brief-next.json should have been dropped"
}

@test "T4: consume rejects malformed brief-next.json" {
    echo "not-json" > "$RALPH_DIR/brief-next.json"
    echo "TAP-2001" > "$RALPH_DIR/.next_intended_issue"
    unset RALPH_COORDINATOR_DISABLED
    _coordinator_invoke_claude() { return 1; }
    export -f _coordinator_invoke_claude

    run ralph_spawn_coordinator 1
    [[ "$status" -eq 0 ]] || fail "spawn returned $status"
    [[ ! -e "$RALPH_DIR/brief.json" ]] || fail "should NOT promote malformed brief"
}

@test "T4: prewarm helper exits cleanly when no .next_intended_issue file" {
    [[ ! -e "$RALPH_DIR/.next_intended_issue" ]]
    run ralph_prewarm_next_brief
    [[ "$status" -eq 0 ]] || fail "prewarm returned $status"
    [[ ! -e "$RALPH_DIR/brief-next.json" ]] || fail "prewarm wrote brief-next.json without a target"
}

@test "T4: prewarm helper skips when current task matches intended (cache will hit)" {
    echo "TAP-2001" > "$RALPH_DIR/.next_intended_issue"
    echo '{"linear_issue":"TAP-2001"}' > "$RALPH_DIR/status.json"
    run ralph_prewarm_next_brief
    [[ "$status" -eq 0 ]] || fail "prewarm returned $status"
    [[ ! -e "$RALPH_DIR/brief-next.json" ]] || fail "prewarm should skip same-ticket case"
}

@test "T4: prewarm helper honors RALPH_PREWARM_NEXT_BRIEF=false" {
    echo "TAP-2001" > "$RALPH_DIR/.next_intended_issue"
    RALPH_PREWARM_NEXT_BRIEF=false run ralph_prewarm_next_brief
    [[ "$status" -eq 0 ]] || fail "prewarm returned $status with opt-out"
    [[ ! -e "$RALPH_DIR/brief-next.json" ]] || fail "prewarm ran despite opt-out"
}

@test "T4: prewarm helper rejects invalid issue id shape" {
    echo "garbage-id-not-tap" > "$RALPH_DIR/.next_intended_issue"
    run ralph_prewarm_next_brief
    [[ "$status" -eq 0 ]]
    [[ ! -e "$RALPH_DIR/brief-next.json" ]] || fail "prewarm ran on invalid id"
}

@test "T4: on-stop extracts NEXT_INTENDED_ISSUE to .next_intended_issue" {
    # Simulate a Stop hook invocation with a RALPH_STATUS block containing
    # NEXT_INTENDED_ISSUE. The hook reads stdin JSON; build a minimal one.
    cat > "$TEST_TEMP_DIR/transcript.jsonl" <<'EOF'
{"type":"assistant","message":{"content":[{"type":"text","text":"---RALPH_STATUS---\nSTATUS: PROGRESS\nTASKS_COMPLETED_THIS_LOOP: 1\nFILES_MODIFIED: 3\nWORK_TYPE: IMPLEMENTATION\nRECOMMENDATION: continue\nLINEAR_ISSUE: TAP-2000\nNEXT_INTENDED_ISSUE: TAP-2042\nEXIT_SIGNAL: false\n---END_RALPH_STATUS---"}]}}
EOF
    export RALPH_LOOP_ACTIVE=1
    export CLAUDE_PROJECT_DIR="$TEST_TEMP_DIR"
    local hook_input
    hook_input=$(jq -nc --arg t "$TEST_TEMP_DIR/transcript.jsonl" \
        '{transcript_path:$t, session_id:"test-sess", tool_input:{}}')

    run bash -c "echo '$hook_input' | bash $REPO_ROOT_FIXED/templates/hooks/on-stop.sh"
    [[ "$status" -eq 0 ]] || fail "on-stop exited $status: $output"
    [[ -s "$RALPH_DIR/.next_intended_issue" ]] || fail ".next_intended_issue not created"
    local got
    got=$(cat "$RALPH_DIR/.next_intended_issue" | tr -d '[:space:]')
    [[ "$got" == "TAP-2042" ]] || fail "expected TAP-2042 got '$got'"
}

@test "T4: on-stop clears .next_intended_issue when NEXT_INTENDED_ISSUE absent" {
    echo "TAP-9999" > "$RALPH_DIR/.next_intended_issue"
    cat > "$TEST_TEMP_DIR/transcript.jsonl" <<'EOF'
{"type":"assistant","message":{"content":[{"type":"text","text":"---RALPH_STATUS---\nSTATUS: PROGRESS\nTASKS_COMPLETED_THIS_LOOP: 1\nFILES_MODIFIED: 1\nWORK_TYPE: IMPLEMENTATION\nLINEAR_ISSUE: TAP-1000\nEXIT_SIGNAL: false\n---END_RALPH_STATUS---"}]}}
EOF
    export RALPH_LOOP_ACTIVE=1
    export CLAUDE_PROJECT_DIR="$TEST_TEMP_DIR"
    local hook_input
    hook_input=$(jq -nc --arg t "$TEST_TEMP_DIR/transcript.jsonl" \
        '{transcript_path:$t, session_id:"test-sess", tool_input:{}}')

    run bash -c "echo '$hook_input' | bash $REPO_ROOT_FIXED/templates/hooks/on-stop.sh"
    [[ "$status" -eq 0 ]] || fail "on-stop exited $status: $output"
    [[ ! -e "$RALPH_DIR/.next_intended_issue" ]] || fail ".next_intended_issue should have been cleared (no NEXT_INTENDED_ISSUE in status block)"
}
