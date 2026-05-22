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

# ---- byte parity guard ---------------------------------------------------

@test "TAP-2344: .ralph/hooks/protect-ralph-files.sh is byte-identical to template" {
    diff "$PROJECT_ROOT/templates/hooks/protect-ralph-files.sh" \
         "$PROJECT_ROOT/.ralph/hooks/protect-ralph-files.sh"
}
