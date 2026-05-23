#!/usr/bin/env bats
# TAP-2344: protect-ralph-files.sh anchors .ralph/ to the project root so
# the global `~/.ralph/` install doesn't get blocked when an agent is
# legitimately hotfixing the library. Also covers .ralphrc anchoring and
# the .claude/* subdir block (kept globally blocked by design).

bats_require_minimum_version 1.5.0

PROJECT_ROOT="${BATS_TEST_DIRNAME}/../.."
HOOK="${PROJECT_ROOT}/templates/hooks/protect-ralph-files.sh"

setup() {
    export TEST_DIR="$(mktemp -d "${BATS_TEST_TMPDIR:-/tmp}/protect_files.XXXXXX")"
    mkdir -p "$TEST_DIR/.ralph"
    export CLAUDE_PROJECT_DIR="$TEST_DIR"
}

teardown() {
    rm -rf "$TEST_DIR" 2>/dev/null || true
}

# Run protect-ralph-files.sh with the given file_path.
run_hook() {
    local path="$1"
    local payload
    payload=$(jq -cn --arg p "$path" '{tool_input:{file_path:$p}}')
    run bash -c '
        echo "$1" | CLAUDE_PROJECT_DIR="$2" bash "$3"
    ' bash "$payload" "$CLAUDE_PROJECT_DIR" "$HOOK"
}

# ---- project .ralph/ — STILL BLOCKED -------------------------------------

@test "TAP-2344: edit to project .ralph/PROMPT.md is BLOCKED" {
    run_hook "$TEST_DIR/.ralph/PROMPT.md"
    [[ "$status" -eq 2 ]] \
        || fail "expected BLOCK on project .ralph/PROMPT.md, got $status: $output"
    [[ "$output" == *"BLOCKED"* ]] || fail "expected BLOCKED prefix: $output"
}

@test "TAP-2344: edit to project .ralph/hooks/on-stop.sh is BLOCKED" {
    run_hook "$TEST_DIR/.ralph/hooks/on-stop.sh"
    [[ "$status" -eq 2 ]] \
        || fail "expected BLOCK on project .ralph/hooks/*, got $status: $output"
}

@test "TAP-2344: edit to relative .ralph/PROMPT.md (no project prefix) is BLOCKED" {
    run_hook ".ralph/PROMPT.md"
    [[ "$status" -eq 2 ]] \
        || fail "expected BLOCK on relative .ralph/PROMPT.md, got $status: $output"
}

@test "TAP-2344: fix_plan.md is still allowed (project)" {
    run_hook "$TEST_DIR/.ralph/fix_plan.md"
    [[ "$status" -eq 0 ]] \
        || fail "fix_plan.md must be allowed, got $status: $output"
}

@test "TAP-2344: fix_plan.md is still allowed (relative)" {
    run_hook ".ralph/fix_plan.md"
    [[ "$status" -eq 0 ]] \
        || fail "relative .ralph/fix_plan.md must be allowed, got $status: $output"
}

@test "TAP-2344: status.json is still allowed (project)" {
    run_hook "$TEST_DIR/.ralph/status.json"
    [[ "$status" -eq 0 ]] \
        || fail "status.json must be allowed, got $status: $output"
}

# ---- global ~/.ralph/ — NOW ALLOWED (the F3 fix) -------------------------

@test "TAP-2344: edit to ~/.ralph/lib/ralph_loop.sh is ALLOWED from inside a project" {
    # Use an absolute path that is OUTSIDE the project root — simulates
    # /home/user/.ralph/... while CLAUDE_PROJECT_DIR points at the consumer.
    mkdir -p "$TEST_DIR/global_home/.ralph/lib"
    run_hook "$TEST_DIR/global_home/.ralph/lib/ralph_loop.sh"
    [[ "$status" -eq 0 ]] \
        || fail "global ~/.ralph/lib/* outside project root must be allowed, got $status: $output"
}

@test "TAP-2344: edit to ~/.ralph/templates/foo.md is ALLOWED from inside a project" {
    mkdir -p "$TEST_DIR/global_home/.ralph/templates"
    run_hook "$TEST_DIR/global_home/.ralph/templates/foo.md"
    [[ "$status" -eq 0 ]] \
        || fail "global ~/.ralph/templates/* outside project root must be allowed, got $status: $output"
}

# ---- .ralphrc — anchored to project ---------------------------------------

@test "TAP-2344: edit to project .ralphrc is BLOCKED" {
    run_hook "$TEST_DIR/.ralphrc"
    [[ "$status" -eq 2 ]] \
        || fail "project .ralphrc must be blocked, got $status: $output"
}

@test "TAP-2344: edit to relative .ralphrc is BLOCKED" {
    run_hook ".ralphrc"
    [[ "$status" -eq 2 ]] \
        || fail "relative .ralphrc must be blocked, got $status: $output"
}

# ---- .ralphrc.local — operator-only override surface ---------------------
# The whole point of .ralphrc.local is to give operators a per-repo opt-out
# (e.g. RALPH_ALLOW_PUSH_MAIN=1 for direct-to-main workflows) that the agent
# cannot self-unlock. If the agent could Edit/Write this file, the bypass
# would be meaningless. Mirror the .ralphrc anchoring (project root + bare).

@test "edit to project .ralphrc.local is BLOCKED" {
    run_hook "$TEST_DIR/.ralphrc.local"
    [[ "$status" -eq 2 ]] \
        || fail "project .ralphrc.local must be blocked, got $status: $output"
}

@test "edit to relative .ralphrc.local is BLOCKED" {
    run_hook ".ralphrc.local"
    [[ "$status" -eq 2 ]] \
        || fail "relative .ralphrc.local must be blocked, got $status: $output"
}

@test "sibling-repo .ralphrc.local outside project root is ALLOWED" {
    # Same anchoring as .ralphrc — protect only THIS project's overrides;
    # a different repo's .ralphrc.local must not be blocked from inside
    # this project (the cross-repo hotfix workflow).
    mkdir -p "$TEST_DIR/sibling_repo"
    run_hook "$TEST_DIR/sibling_repo/.ralphrc.local"
    [[ "$status" -eq 0 ]] \
        || fail "sibling repo .ralphrc.local must be allowed, got $status: $output"
}

# ---- .claude/ — globally blocked (separate ticket for carve-outs) --------

@test "TAP-2344: edit to .claude/agents/ralph.md is BLOCKED" {
    run_hook "$TEST_DIR/.claude/agents/ralph.md"
    [[ "$status" -eq 2 ]] \
        || fail "project .claude/agents/* must be blocked, got $status: $output"
}

@test "TAP-2344: edit to .claude/hooks/on-stop.sh is BLOCKED" {
    run_hook ".claude/hooks/on-stop.sh"
    [[ "$status" -eq 2 ]] \
        || fail ".claude/hooks/* must be blocked, got $status: $output"
}

@test "TAP-2344: edit to .claude/rules/foo.md is ALLOWED (Edit-side carve-out)" {
    # protect-ralph-files.sh's existing carve-out: only settings*.json, agents/,
    # hooks/, commands/ are blocked under .claude/. rules/ and skills/ flow.
    run_hook ".claude/rules/foo.md"
    [[ "$status" -eq 0 ]] \
        || fail ".claude/rules/* must be allowed via Edit, got $status: $output"
}

@test "TAP-2344: edit to .claude/skills/foo/SKILL.md is ALLOWED" {
    run_hook ".claude/skills/foo/SKILL.md"
    [[ "$status" -eq 0 ]] \
        || fail ".claude/skills/* must be allowed via Edit, got $status: $output"
}

# ---- TAP-2471: coordinator-owned .ralph/ paths -----------------------------
# The coordinator agent (.claude/agents/ralph-coordinator.md MODE=brief) writes
# brief.json and .linear_next_issue via the Claude Write tool, which fires this
# hook. Pre-TAP-2471 the only allowed paths were fix_plan.md + status.json, so
# every coordinator Write hit exit 2 — silently masked by the TAP-1875
# retry-once + WARN-and-clear path. Sibling evidence (2026-05-22/23): the
# tapps-mcp coordinator-brief.err captured Claude's own thinking diagnosing
# the issue ("caught in a circular dependency").

@test "TAP-2471: .ralph/brief.json is ALLOWED (project)" {
    run_hook "$TEST_DIR/.ralph/brief.json"
    [[ "$status" -eq 0 ]] \
        || fail ".ralph/brief.json must be allowed for the coordinator, got $status: $output"
}

@test "TAP-2471: .ralph/brief.json is ALLOWED (relative)" {
    run_hook ".ralph/brief.json"
    [[ "$status" -eq 0 ]] \
        || fail "relative .ralph/brief.json must be allowed, got $status: $output"
}

@test "TAP-2471: .ralph/.linear_next_issue is ALLOWED (project)" {
    run_hook "$TEST_DIR/.ralph/.linear_next_issue"
    [[ "$status" -eq 0 ]] \
        || fail ".linear_next_issue must be allowed for the coordinator, got $status: $output"
}

@test "TAP-2471: .ralph/.linear_next_issue is ALLOWED (relative)" {
    run_hook ".ralph/.linear_next_issue"
    [[ "$status" -eq 0 ]] \
        || fail "relative .linear_next_issue must be allowed, got $status: $output"
}

@test "TAP-2471: .ralph/.last_completed_files is ALLOWED" {
    run_hook ".ralph/.last_completed_files"
    [[ "$status" -eq 0 ]] \
        || fail ".last_completed_files must be allowed, got $status: $output"
}

@test "TAP-2471: .ralph/.brief_cache/TAP-1234.json is ALLOWED (project)" {
    mkdir -p "$TEST_DIR/.ralph/.brief_cache"
    run_hook "$TEST_DIR/.ralph/.brief_cache/TAP-1234.json"
    [[ "$status" -eq 0 ]] \
        || fail ".brief_cache/*.json must be allowed, got $status: $output"
}

@test "TAP-2471: .ralph/.brief_cache/TAP-1234.json is ALLOWED (relative)" {
    run_hook ".ralph/.brief_cache/TAP-1234.json"
    [[ "$status" -eq 0 ]] \
        || fail "relative .brief_cache/*.json must be allowed, got $status: $output"
}

# ---- TAP-2471: still-blocked guard -----------------------------------------
# Widening the allowlist must NOT widen the blocked set. Sample every other
# .ralph/* file the agent might be tempted to touch — they all must still
# hit exit 2 (regression guard).

@test "TAP-2471: .ralph/PROMPT.md is STILL BLOCKED" {
    run_hook "$TEST_DIR/.ralph/PROMPT.md"
    [[ "$status" -eq 2 ]] \
        || fail "PROMPT.md must remain blocked, got $status: $output"
}

@test "TAP-2471: .ralph/AGENT.md is STILL BLOCKED" {
    run_hook "$TEST_DIR/.ralph/AGENT.md"
    [[ "$status" -eq 2 ]] \
        || fail "AGENT.md must remain blocked, got $status: $output"
}

@test "TAP-2471: .ralph/hooks/on-stop.sh is STILL BLOCKED" {
    run_hook "$TEST_DIR/.ralph/hooks/on-stop.sh"
    [[ "$status" -eq 2 ]] \
        || fail ".ralph/hooks/* must remain blocked, got $status: $output"
}

@test "TAP-2471: .ralph/.circuit_breaker_state is STILL BLOCKED" {
    run_hook ".ralph/.circuit_breaker_state"
    [[ "$status" -eq 2 ]] \
        || fail ".circuit_breaker_state must remain blocked, got $status: $output"
}

@test "TAP-2471: .ralphrc is STILL BLOCKED (regression guard)" {
    run_hook ".ralphrc"
    [[ "$status" -eq 2 ]] \
        || fail ".ralphrc must remain blocked, got $status: $output"
}

@test "TAP-2471: .claude/agents/ralph.md is STILL BLOCKED (regression guard)" {
    run_hook ".claude/agents/ralph.md"
    [[ "$status" -eq 2 ]] \
        || fail ".claude/agents/* must remain blocked, got $status: $output"
}

# ---- byte parity guard ---------------------------------------------------

@test "TAP-2344: .ralph/hooks/protect-ralph-files.sh is byte-identical to template" {
    diff "$PROJECT_ROOT/templates/hooks/protect-ralph-files.sh" \
         "$PROJECT_ROOT/.ralph/hooks/protect-ralph-files.sh"
}
