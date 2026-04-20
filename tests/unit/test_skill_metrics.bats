#!/usr/bin/env bats
# SKILLS-INJECT-8: Tests for skill telemetry — record_skill_metric and ralph_show_skill_stats.

bats_require_minimum_version 1.5.0
load '../helpers/test_helper'

METRICS_LIB="$BATS_TEST_DIRNAME/../../lib/metrics.sh"

setup() {
    export RALPH_DIR="$BATS_TEST_TMPDIR/.ralph"
    mkdir -p "$RALPH_DIR/metrics"
    export LOOP_COUNT=42
    export RALPH_OTEL_ENABLED="false"
    # shellcheck disable=SC1090
    source "$METRICS_LIB"
}

teardown() {
    rm -rf "$BATS_TEST_TMPDIR/.ralph"
}

# ---------------------------------------------------------------------------
# record_skill_metric
# ---------------------------------------------------------------------------

@test "SKILLS-INJECT-8: record_skill_metric writes to skills.jsonl" {
    record_skill_metric "skill_added" "python-patterns" "/tmp/myproject"
    [[ -f "$RALPH_DIR/metrics/skills.jsonl" ]]
}

@test "SKILLS-INJECT-8: record_skill_metric produces valid JSONL" {
    record_skill_metric "skill_added" "tdd-workflow" "/tmp/proj"
    local line
    line=$(cat "$RALPH_DIR/metrics/skills.jsonl")
    echo "$line" | jq -e . >/dev/null
}

@test "SKILLS-INJECT-8: record_skill_metric captures event type" {
    record_skill_metric "skill_triggered" "search-first" "/tmp/proj"
    jq -e '.event == "skill_triggered"' "$RALPH_DIR/metrics/skills.jsonl" >/dev/null
}

@test "SKILLS-INJECT-8: record_skill_metric captures skill name" {
    record_skill_metric "skill_added" "eval-harness" "/tmp/proj"
    jq -e '.skill == "eval-harness"' "$RALPH_DIR/metrics/skills.jsonl" >/dev/null
}

@test "SKILLS-INJECT-8: record_skill_metric captures loop_count" {
    export LOOP_COUNT=99
    record_skill_metric "skill_added" "linear" "/tmp/proj"
    jq -e '.loop_count == 99' "$RALPH_DIR/metrics/skills.jsonl" >/dev/null
}

@test "SKILLS-INJECT-8: record_skill_metric appends multiple events" {
    record_skill_metric "skill_added" "skill-a" "/tmp/proj"
    record_skill_metric "skill_added" "skill-b" "/tmp/proj"
    record_skill_metric "skill_triggered" "skill-a" "/tmp/proj"
    local count
    count=$(wc -l < "$RALPH_DIR/metrics/skills.jsonl")
    [[ "$count" -eq 3 ]]
}

@test "SKILLS-INJECT-8: record_skill_metric handles skill names with hyphens" {
    record_skill_metric "skill_added" "agentic-engineering" "/tmp/proj"
    jq -e '.skill == "agentic-engineering"' "$RALPH_DIR/metrics/skills.jsonl" >/dev/null
}

# ---------------------------------------------------------------------------
# ralph_show_skill_stats
# ---------------------------------------------------------------------------

@test "SKILLS-INJECT-8: ralph_show_skill_stats: no-op when no skills.jsonl" {
    run ralph_show_skill_stats "human"
    [[ "$status" -eq 0 ]]
    [[ -z "$output" ]]
}

@test "SKILLS-INJECT-8: ralph_show_skill_stats: shows event counts" {
    record_skill_metric "skill_added" "search-first" "/tmp/proj"
    record_skill_metric "skill_added" "tdd-workflow" "/tmp/proj"
    record_skill_metric "skill_triggered" "search-first" "/tmp/proj"

    run ralph_show_skill_stats "human"
    [[ "$status" -eq 0 ]]
    echo "$output" | grep -q "skill_added"
    echo "$output" | grep -q "skill_triggered"
}

@test "SKILLS-INJECT-8: ralph_show_skill_stats: JSON mode emits valid JSON" {
    record_skill_metric "skill_added" "simplify" "/tmp/proj"
    run ralph_show_skill_stats "json"
    [[ "$status" -eq 0 ]]
    echo "$output" | jq -e '.total == 1' >/dev/null
}

@test "SKILLS-INJECT-8: ralph_show_skill_stats: shows top skills" {
    for i in 1 2 3; do
        record_skill_metric "skill_triggered" "search-first" "/tmp/proj"
    done
    record_skill_metric "skill_triggered" "simplify" "/tmp/proj"

    run ralph_show_skill_stats "human"
    [[ "$status" -eq 0 ]]
    echo "$output" | grep -q "search-first"
}
