#!/usr/bin/env bats
# T1: RALPH_CURRENT_TASK_TEXT is populated from coordinator brief.json so the
# task-type classifier (lib/complexity.sh) actually sees task-shaped text in
# OAuth-via-MCP Linear mode. Without this, every routing decision logged
# task_type=none / reason=no_task_fallback (verified against AgentForge
# 2026-05-22 campaign: 31/31 decisions). With this, docs-related briefs
# classify as 'docs' and route to Haiku.

bats_require_minimum_version 1.5.0

REPO_ROOT_FIXED="${BATS_TEST_DIRNAME}/../.."

setup() {
    export TEST_TEMP_DIR="$(mktemp -d "${BATS_TEST_TMPDIR:-/tmp}/routing_wire.XXXXXX")"
    cd "$TEST_TEMP_DIR"
    mkdir -p .ralph .ralph/logs
    export RALPH_DIR="$TEST_TEMP_DIR/.ralph"
    export LOG_DIR="$RALPH_DIR/logs"
    export DRY_RUN=false

    # Prevent the loop's argv parser from tripping on bats's test-name.
    set --
    # shellcheck disable=SC1090
    source "$REPO_ROOT_FIXED/ralph_loop.sh"

    # ralph_loop.sh:186 hard-resets RALPH_TASK_SOURCE="file" — override AFTER source
    # to mimic what .ralphrc does in real projects.
    export RALPH_TASK_SOURCE=linear
    export RALPH_LINEAR_PROJECT="test-project"

    # Stub linear helpers — OAuth-via-MCP mode returns empty for both.
    linear_get_in_progress_task() { return 1; }
    linear_get_next_task() { return 1; }
    linear_get_open_count() { echo 5; return 0; }
    export -f linear_get_in_progress_task linear_get_next_task linear_get_open_count
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR" 2>/dev/null || true
}

write_docs_brief() {
    cat > "$RALPH_DIR/brief.json" <<'EOF'
{
  "schema_version": 1,
  "task_id": "TAP-9001",
  "task_source": "linear",
  "task_summary": "Update README.md and CHANGELOG with the v2.16 release notes.",
  "risk_level": "LOW",
  "affected_modules": ["README.md", "CHANGELOG.md"],
  "acceptance_criteria": ["docs reflect new flags"],
  "prior_learnings": [],
  "qa_required": false,
  "delegate_to": "ralph",
  "coordinator_confidence": 0.9,
  "created_at": "2026-05-22T15:00:00Z"
}
EOF
}

write_code_brief() {
    cat > "$RALPH_DIR/brief.json" <<'EOF'
{
  "schema_version": 1,
  "task_id": "TAP-9002",
  "task_source": "linear",
  "task_summary": "Fix the off-by-one error in the rate-limit window calculation.",
  "risk_level": "MEDIUM",
  "affected_modules": ["lib/rate_limit.sh"],
  "acceptance_criteria": ["window respects boundary"],
  "prior_learnings": [],
  "qa_required": true,
  "delegate_to": "ralph",
  "coordinator_confidence": 0.85,
  "created_at": "2026-05-22T15:00:00Z"
}
EOF
}

@test "T1: docs-flavored brief.json populates RALPH_CURRENT_TASK_TEXT" {
    write_docs_brief
    RALPH_CURRENT_TASK_TEXT=""
    build_loop_context 1 >/dev/null 2>&1 || true
    [[ -n "$RALPH_CURRENT_TASK_TEXT" ]] \
        || fail "RALPH_CURRENT_TASK_TEXT empty after brief.json present (got '$RALPH_CURRENT_TASK_TEXT')"
    [[ "$RALPH_CURRENT_TASK_TEXT" =~ README ]] \
        || fail "expected README in task text, got '$RALPH_CURRENT_TASK_TEXT'"
}

@test "T1: docs brief routes to haiku via ralph_select_model" {
    write_docs_brief
    RALPH_CURRENT_TASK_TEXT=""
    build_loop_context 1 >/dev/null 2>&1 || true
    source "$REPO_ROOT_FIXED/lib/complexity.sh"
    export RALPH_MODEL_ROUTING_ENABLED=true
    local model
    model=$(ralph_select_model "$RALPH_CURRENT_TASK_TEXT" 0)
    [[ "$model" == "haiku" ]] || fail "expected haiku, got '$model' for text '$RALPH_CURRENT_TASK_TEXT'"
}

@test "T1: code brief routes to sonnet (floor) — no regression" {
    write_code_brief
    RALPH_CURRENT_TASK_TEXT=""
    build_loop_context 1 >/dev/null 2>&1 || true
    source "$REPO_ROOT_FIXED/lib/complexity.sh"
    export RALPH_MODEL_ROUTING_ENABLED=true
    local model
    model=$(ralph_select_model "$RALPH_CURRENT_TASK_TEXT" 0)
    [[ "$model" == "sonnet" ]] || fail "expected sonnet, got '$model'"
}

@test "T1: absent brief.json falls through to legacy chain (no crash)" {
    [[ ! -e "$RALPH_DIR/brief.json" ]]
    RALPH_CURRENT_TASK_TEXT=""
    build_loop_context 1 >/dev/null 2>&1 || true
    # In OAuth-via-MCP mode with no brief and no status.json carryover,
    # RALPH_CURRENT_TASK_TEXT is expected to remain empty — but the call
    # must not crash. The router treats empty as no_task_fallback.
    :
}

@test "T1: malformed brief.json does not crash build_loop_context" {
    echo 'not-json' > "$RALPH_DIR/brief.json"
    RALPH_CURRENT_TASK_TEXT=""
    run build_loop_context 1
    [[ "$status" -eq 0 ]] || fail "build_loop_context exited $status on malformed brief"
}
