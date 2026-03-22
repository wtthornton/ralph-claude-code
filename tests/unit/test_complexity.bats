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

@test "default task classified as ROUTINE (3)" {
    local result
    result=$(ralph_classify_task_complexity "Fix a small bug in auth module")
    [[ "$result" -eq 3 ]]
}

@test "[TRIVIAL] annotation returns 1" {
    local result
    result=$(ralph_classify_task_complexity "[TRIVIAL] Fix typo in README")
    [[ "$result" -eq 1 ]]
}

@test "[SMALL] annotation returns 2" {
    local result
    result=$(ralph_classify_task_complexity "[SMALL] Add missing import")
    [[ "$result" -eq 2 ]]
}

@test "[MEDIUM] annotation returns 3" {
    local result
    result=$(ralph_classify_task_complexity "[MEDIUM] Implement new endpoint")
    [[ "$result" -eq 3 ]]
}

@test "[LARGE] annotation returns 4" {
    local result
    result=$(ralph_classify_task_complexity "[LARGE] Refactor entire auth system")
    [[ "$result" -eq 4 ]]
}

@test "[ARCHITECTURAL] annotation returns 5" {
    local result
    result=$(ralph_classify_task_complexity "[ARCHITECTURAL] Redesign database schema")
    [[ "$result" -eq 5 ]]
}

@test "architectural keywords increase score" {
    local result
    result=$(ralph_classify_task_complexity "Architect the new microservice platform for deployment")
    [[ "$result" -ge 4 ]]
}

@test "trivial keywords decrease score" {
    local result
    result=$(ralph_classify_task_complexity "Fix a typo in the comment")
    [[ "$result" -le 3 ]]
}

@test "5+ file references increase score" {
    local result
    result=$(ralph_classify_task_complexity "Update auth.py, login.py, register.py, profile.py, settings.py, middleware.py")
    [[ "$result" -ge 4 ]]
}

@test "retry escalation: 3+ retries adds +2" {
    local result
    result=$(ralph_classify_task_complexity "Simple bug fix" 3)
    [[ "$result" -ge 4 ]]
}

@test "retry escalation: 1 retry adds +1" {
    local result
    result=$(ralph_classify_task_complexity "Simple bug fix" 1)
    [[ "$result" -ge 3 ]]
}

@test "score clamped to 1-5 range" {
    # Very simple task with low keywords
    local result
    result=$(ralph_classify_task_complexity "[TRIVIAL] typo fix")
    [[ "$result" -ge 1 ]] && [[ "$result" -le 5 ]]
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
