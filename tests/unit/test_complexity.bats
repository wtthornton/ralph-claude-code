#!/usr/bin/env bats

# Tests for lib/complexity.sh — Task complexity classifier (COSTROUTE-1)

setup() {
    export RALPH_DIR="$BATS_TEST_TMPDIR/.ralph"
    export RALPH_MODEL_ROUTING_ENABLED="false"
    export RALPH_VERBOSE="false"
    mkdir -p "$RALPH_DIR"
    source "$BATS_TEST_DIRNAME/../../lib/complexity.sh"
}

teardown() {
    rm -rf "$BATS_TEST_TMPDIR/.ralph"
}

# Note: ralph_classify_task_complexity echoes AND returns the score as exit code.
# Use `run` to avoid set -e failures on non-zero exit codes.

@test "default task classified as ROUTINE (3)" {
    run ralph_classify_task_complexity "Fix a small bug in auth module"
    [[ "$output" -eq 3 ]]
}

@test "[TRIVIAL] annotation returns 1" {
    run ralph_classify_task_complexity "[TRIVIAL] Fix typo in README"
    [[ "$output" -eq 1 ]]
}

@test "[SMALL] annotation returns 2" {
    run ralph_classify_task_complexity "[SMALL] Add missing import"
    [[ "$output" -eq 2 ]]
}

@test "[MEDIUM] annotation returns 3" {
    run ralph_classify_task_complexity "[MEDIUM] Implement new endpoint"
    [[ "$output" -eq 3 ]]
}

@test "[LARGE] annotation returns 4" {
    run ralph_classify_task_complexity "[LARGE] Refactor entire auth system"
    [[ "$output" -eq 4 ]]
}

@test "[ARCHITECTURAL] annotation returns 5" {
    run ralph_classify_task_complexity "[ARCHITECTURAL] Redesign database schema"
    [[ "$output" -eq 5 ]]
}

@test "architectural keywords increase score" {
    run ralph_classify_task_complexity "Architect the new microservice platform for deployment"
    [[ "$output" -ge 4 ]]
}

@test "trivial keywords decrease score" {
    run ralph_classify_task_complexity "Fix a typo in the comment"
    [[ "$output" -le 3 ]]
}

@test "5+ file references increase score" {
    run ralph_classify_task_complexity "Update auth.py, login.py, register.py, profile.py, settings.py, middleware.py"
    [[ "$output" -ge 4 ]]
}

@test "retry escalation: 3+ retries adds +2" {
    run ralph_classify_task_complexity "Simple bug fix" 3
    [[ "$output" -ge 4 ]]
}

@test "retry escalation: 1 retry adds +1" {
    run ralph_classify_task_complexity "Simple bug fix" 1
    [[ "$output" -ge 3 ]]
}

@test "score clamped to 1-5 range" {
    run ralph_classify_task_complexity "[TRIVIAL] typo fix"
    [[ "$output" -ge 1 ]] && [[ "$output" -le 5 ]]
}

@test "TAP-677: annotation vs heuristic mismatch warns on stderr but keeps annotation" {
    local task="[TRIVIAL] Update auth.py login.py register.py profile.py settings.py middleware.py api.py routes.py models.py views.py"
    local errf="$BATS_TEST_TMPDIR/stderr.log"
    # Do not use run — trivial score returns exit code 1 (same as bash return 1 quirk)
    local stdout
    stdout=$(ralph_classify_task_complexity "$task" 2>"$errf") || true
    [[ "${stdout//$'\n'/}" -eq 1 ]]
    grep -q 'annotated \[TRIVIAL\]' "$errf"
    grep -q 'heuristic suggests' "$errf"
}

@test "ralph_complexity_name maps numbers to names" {
    [[ "$(ralph_complexity_name 1)" == "TRIVIAL" ]]
    [[ "$(ralph_complexity_name 2)" == "SIMPLE" ]]
    [[ "$(ralph_complexity_name 3)" == "ROUTINE" ]]
    [[ "$(ralph_complexity_name 4)" == "COMPLEX" ]]
    [[ "$(ralph_complexity_name 5)" == "ARCHITECTURAL" ]]
}

@test "ralph_select_model returns default when routing disabled" {
    export RALPH_MODEL_ROUTING_ENABLED="false"
    local model
    model=$(ralph_select_model "any task")
    [[ "$model" == "sonnet" ]]
}

@test "ralph_select_model routes trivial to haiku" {
    export RALPH_MODEL_ROUTING_ENABLED="true"
    local model
    model=$(ralph_select_model "[TRIVIAL] Fix typo")
    [[ "$model" == "haiku" ]]
}

@test "ralph_select_model routes architectural to opus" {
    export RALPH_MODEL_ROUTING_ENABLED="true"
    local model
    model=$(ralph_select_model "[ARCHITECTURAL] Redesign platform")
    [[ "$model" == "opus" ]]
}
