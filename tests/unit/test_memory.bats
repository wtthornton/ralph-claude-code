#!/usr/bin/env bats

# Tests for lib/memory.sh — Cross-session agent memory (AGENTMEM-1/2/3)

setup() {
    export RALPH_DIR="$BATS_TEST_TMPDIR/.ralph"
    export RALPH_MAX_EPISODES=10
    export RALPH_MEMORY_DECAY_DAYS=14
    export RALPH_INDEX_MAX_AGE_HOURS=24
    export LOOP_COUNT=1
    mkdir -p "$RALPH_DIR"
    source "$BATS_TEST_DIRNAME/../../lib/memory.sh"
}

teardown() {
    rm -rf "$BATS_TEST_TMPDIR/.ralph"
}

# AGENTMEM-1: Episodic Memory

@test "ralph_record_episode creates episodes.jsonl" {
    ralph_record_episode "success" "IMPLEMENTATION" "Built feature" "" "src/main.py"
    [[ -f "$RALPH_DIR/memory/episodes.jsonl" ]]
}

@test "ralph_record_episode writes valid JSON" {
    ralph_record_episode "success" "TESTING" "Ran tests" "" ""
    local line
    line=$(head -1 "$RALPH_DIR/memory/episodes.jsonl")
    echo "$line" | jq . > /dev/null 2>&1
}

@test "ralph_record_episode captures outcome" {
    ralph_record_episode "failure" "DEBUGGING" "Debug session" "TypeError at line 42" ""
    grep -q '"outcome":"failure"' "$RALPH_DIR/memory/episodes.jsonl"
    grep -q '"error_summary":"TypeError at line 42"' "$RALPH_DIR/memory/episodes.jsonl"
}

@test "episodes bounded to max" {
    for i in $(seq 1 15); do
        ralph_record_episode "success" "IMPL" "Task $i" "" ""
    done
    local count
    count=$(wc -l < "$RALPH_DIR/memory/episodes.jsonl")
    [[ "$count" -le 10 ]]
}

# AGENTMEM-2: Semantic Memory

@test "ralph_generate_project_index creates project_index.json" {
    ralph_generate_project_index
    [[ -f "$RALPH_DIR/memory/project_index.json" ]]
}

@test "ralph_generate_project_index produces valid JSON" {
    ralph_generate_project_index
    jq . "$RALPH_DIR/memory/project_index.json" > /dev/null 2>&1
}

@test "ralph_is_index_stale returns 0 for missing index" {
    ralph_is_index_stale
    [[ $? -eq 0 ]]
}

@test "ralph_is_index_stale returns 1 for fresh index" {
    ralph_generate_project_index
    ralph_is_index_stale
    # Fresh index should return 1 (not stale)
    [[ $? -eq 1 ]]
}

# AGENTMEM-3: Memory Decay

@test "ralph_prune_stale_memories handles missing file" {
    ralph_prune_stale_memories
    # Should not error
    [[ $? -eq 0 ]]
}
