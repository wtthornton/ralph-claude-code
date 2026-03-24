#!/usr/bin/env bats
# Unit tests for plan_optimizer.sh (PLANOPT-2: Plan Analysis and Reordering Engine)
#
# Tests cover: explicit dependency metadata, module grouping, phase ordering,
# checked-task immutability, section boundaries, equivalence validation,
# backup durability, tsort cycle handling, single-task no-op, resolved metadata,
# and size field population.

load '../helpers/test_helper'
load '../helpers/fixtures'

# Paths to library modules under test
PLAN_OPTIMIZER="${BATS_TEST_DIRNAME}/../../lib/plan_optimizer.sh"
IMPORT_GRAPH_LIB="${BATS_TEST_DIRNAME}/../../lib/import_graph.sh"

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR" || return 1

    export RALPH_DIR=".ralph"
    mkdir -p "$RALPH_DIR"

    # Disable explorer resolution in all tests (no claude CLI needed)
    export RALPH_NO_EXPLORER_RESOLVE=true

    # Source the library under test
    source "$PLAN_OPTIMIZER"
}

teardown() {
    if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
        cd /
        rm -rf "$TEST_DIR"
    fi
}

# =============================================================================
# TEST 1: Respects explicit dependency metadata (<!-- id: --> / <!-- depends: -->)
# =============================================================================

@test "PLANOPT-2: respects explicit dependency metadata" {
    local plan="$TEST_DIR/fix_plan.md"
    # Both tasks in the same module (src/db/) so module grouping doesn't interfere
    cat > "$plan" <<'EOF'
## Tasks
- [ ] Add endpoint (`src/db/users.py`) <!-- depends: schema -->
- [ ] Create schema (`src/db/schema.py`) <!-- id: schema -->
EOF

    run plan_optimize_section "$plan" "$TEST_DIR" "/dev/null"
    assert_success

    # Schema (id: schema) must come before endpoint (depends: schema)
    local schema_line endpoint_line
    schema_line=$(grep -n "Create schema" "$plan" | cut -d: -f1)
    endpoint_line=$(grep -n "Add endpoint" "$plan" | cut -d: -f1)
    [[ -n "$schema_line" ]]
    [[ -n "$endpoint_line" ]]
    [[ $schema_line -lt $endpoint_line ]]
}

# =============================================================================
# TEST 2: Groups tasks by module
# =============================================================================

@test "PLANOPT-2: groups tasks by module" {
    local plan="$TEST_DIR/fix_plan.md"
    cat > "$plan" <<'EOF'
## Tasks
- [ ] Fix API routes (`src/api/routes.py`)
- [ ] Update DB schema (`src/db/schema.py`)
- [ ] Add API middleware (`src/api/middleware.py`)
EOF

    run plan_optimize_section "$plan" "$TEST_DIR" "/dev/null"
    assert_success

    # Both src/api/ tasks should be adjacent (not split by the src/db/ task)
    local routes_line middleware_line schema_line
    routes_line=$(grep -n "API routes" "$plan" | cut -d: -f1)
    middleware_line=$(grep -n "API middleware" "$plan" | cut -d: -f1)
    schema_line=$(grep -n "DB schema" "$plan" | cut -d: -f1)

    [[ -n "$routes_line" ]]
    [[ -n "$middleware_line" ]]
    [[ -n "$schema_line" ]]

    # The two API tasks should be adjacent (difference of 1 line)
    local diff=$(( middleware_line - routes_line ))
    if [[ $diff -lt 0 ]]; then
        diff=$(( -diff ))
    fi
    [[ $diff -eq 1 ]]
}

# =============================================================================
# TEST 3: Applies phase ordering within module (create -> add -> test)
# =============================================================================

@test "PLANOPT-2: applies phase ordering within module (create -> add -> test)" {
    local plan="$TEST_DIR/fix_plan.md"
    # Use an import graph to establish dependency chain that aligns with phase ordering.
    # Without dependency pairs, tsort preserves original order and phase is only a tiebreaker.
    # Import chain: test_users.py -> users.py -> models.py
    mkdir -p "$TEST_DIR/.ralph"
    cat > "$TEST_DIR/.ralph/.import_graph.json" <<'GRAPH'
{
    "src/api/test_users.py": ["src/api/users.py"],
    "src/api/users.py": ["src/api/models.py"]
}
GRAPH

    cat > "$plan" <<'EOF'
## Tasks
- [ ] Test user endpoint (`src/api/test_users.py`)
- [ ] Add user endpoint (`src/api/users.py`)
- [ ] Create user model (`src/api/models.py`)
EOF

    run plan_optimize_section "$plan" "$TEST_DIR" "$TEST_DIR/.ralph/.import_graph.json"
    assert_success

    # Order should be: create (phase 0) -> add (phase 1) -> test (phase 3)
    local create_line add_line test_line
    create_line=$(grep -n "Create user model" "$plan" | cut -d: -f1)
    add_line=$(grep -n "Add user endpoint" "$plan" | cut -d: -f1)
    test_line=$(grep -n "Test user endpoint" "$plan" | cut -d: -f1)

    [[ -n "$create_line" ]]
    [[ -n "$add_line" ]]
    [[ -n "$test_line" ]]
    [[ $create_line -lt $add_line ]]
    [[ $add_line -lt $test_line ]]
}

# =============================================================================
# TEST 4: Never moves checked tasks
# =============================================================================

@test "PLANOPT-2: never moves checked tasks" {
    # Test plan_write_optimized directly to verify checked tasks are preserved
    # in their original positions regardless of reorder.
    local plan="$TEST_DIR/fix_plan.md"
    cat > "$plan" <<'EOF'
## Tasks
- [x] Done task one
- [x] Done task two
- [ ] Todo B (`src/api/b.py`)
- [ ] Todo A (`src/api/a.py`)
EOF

    # Manually construct reordered JSON (swapping the two unchecked tasks)
    local reordered='[{"idx":3,"line_num":5,"section":"## Tasks","text":"Todo A (`src/api/a.py`)","checked":false,"files":["src/api/a.py"],"task_id":"","depends":"","size":1},{"idx":2,"line_num":4,"section":"## Tasks","text":"Todo B (`src/api/b.py`)","checked":false,"files":["src/api/b.py"],"task_id":"","depends":"","size":1}]'
    plan_write_optimized "$plan" "$reordered"

    # Checked tasks must still be on lines 2 and 3 (right after the ## header)
    local line2 line3
    line2=$(sed -n '2p' "$plan")
    line3=$(sed -n '3p' "$plan")
    [[ "$line2" == *"[x] Done task one"* ]]
    [[ "$line3" == *"[x] Done task two"* ]]

    # Unchecked tasks should follow in the reordered sequence
    local line4 line5
    line4=$(sed -n '4p' "$plan")
    line5=$(sed -n '5p' "$plan")
    [[ "$line4" == *"Todo A"* ]]
    [[ "$line5" == *"Todo B"* ]]
}

# =============================================================================
# TEST 5: Preserves section boundaries
# =============================================================================

@test "PLANOPT-2: preserves section boundaries" {
    local plan="$TEST_DIR/fix_plan.md"
    cat > "$plan" <<'EOF'
## Phase 1
- [ ] Task A (`src/api/a.py`)
- [ ] Task B (`src/api/b.py`)
## Phase 2
- [ ] Task C (`src/db/c.py`)
- [ ] Task D (`src/db/d.py`)
EOF

    run plan_optimize_section "$plan" "$TEST_DIR" "/dev/null"
    assert_success

    # Tasks must remain within their own sections
    local phase1_line phase2_line taskA_line taskB_line taskC_line taskD_line
    phase1_line=$(grep -n "^## Phase 1" "$plan" | cut -d: -f1)
    phase2_line=$(grep -n "^## Phase 2" "$plan" | cut -d: -f1)
    taskA_line=$(grep -n "Task A" "$plan" | cut -d: -f1)
    taskB_line=$(grep -n "Task B" "$plan" | cut -d: -f1)
    taskC_line=$(grep -n "Task C" "$plan" | cut -d: -f1)
    taskD_line=$(grep -n "Task D" "$plan" | cut -d: -f1)

    # Phase 1 tasks between Phase 1 header and Phase 2 header
    [[ $taskA_line -gt $phase1_line && $taskA_line -lt $phase2_line ]]
    [[ $taskB_line -gt $phase1_line && $taskB_line -lt $phase2_line ]]

    # Phase 2 tasks after Phase 2 header
    [[ $taskC_line -gt $phase2_line ]]
    [[ $taskD_line -gt $phase2_line ]]
}

# =============================================================================
# TEST 6: Equivalence check catches dropped task
# =============================================================================

@test "PLANOPT-2: equivalence check catches dropped task" {
    local before='["Task A","Task B","Task C"]'
    local after='["Task A","Task B"]'

    run plan_validate_equivalence "$before" "$after"
    assert_failure
}

# =============================================================================
# TEST 7: Equivalence check passes for reorder
# =============================================================================

@test "PLANOPT-2: equivalence check passes for reorder" {
    local before='["Task A","Task B","Task C"]'
    local after='["Task C","Task A","Task B"]'

    run plan_validate_equivalence "$before" "$after"
    assert_success
}

# =============================================================================
# TEST 8: Backup kept after write (not deleted)
# =============================================================================

@test "PLANOPT-2: backup kept after write" {
    local plan="$TEST_DIR/fix_plan.md"
    cat > "$plan" <<'EOF'
## Tasks
- [ ] Task B (`src/api/b.py`)
- [ ] Create Task A (`src/api/a.py`)
EOF

    run plan_optimize_section "$plan" "$TEST_DIR" "/dev/null"
    assert_success

    # Backup file must exist after optimization
    [[ -f "${plan}.pre-optimize.bak" ]]
}

# =============================================================================
# TEST 9: Handles tsort cycle gracefully
# =============================================================================

@test "PLANOPT-2: handles tsort cycle gracefully" {
    local plan="$TEST_DIR/fix_plan.md"
    cat > "$plan" <<'EOF'
## Tasks
- [ ] Task A (`src/a.py`) <!-- id: a --> <!-- depends: b -->
- [ ] Task B (`src/b.py`) <!-- id: b --> <!-- depends: a -->
- [ ] Task C (`src/c.py`)
EOF

    # tsort warns on stderr for cycles but produces best-effort output
    # The function should not crash
    run plan_optimize_section "$plan" "$TEST_DIR" "/dev/null"
    assert_success

    # All three tasks must still be present in the plan
    grep -q "Task A" "$plan"
    grep -q "Task B" "$plan"
    grep -q "Task C" "$plan"
}

# =============================================================================
# TEST 10: Single unchecked task is a no-op
# =============================================================================

@test "PLANOPT-2: single unchecked task is a no-op" {
    local plan="$TEST_DIR/fix_plan.md"
    cat > "$plan" <<'EOF'
## Tasks
- [x] Done task
- [ ] Only one left
EOF

    local before
    before=$(cat "$plan")

    run plan_optimize_section "$plan" "$TEST_DIR" "/dev/null"
    assert_success

    # Plan must be unchanged (no write occurred)
    local after
    after=$(cat "$plan")
    [[ "$before" == "$after" ]]
}

# =============================================================================
# TEST 11: Parses <!-- resolved: path --> metadata into files array
# =============================================================================

@test "PLANOPT-2: parses resolved metadata into files array" {
    local plan="$TEST_DIR/fix_plan.md"
    cat > "$plan" <<'EOF'
## Tasks
- [ ] Fix the auth flow <!-- resolved: src/auth/middleware.py -->
- [ ] Update dashboard
EOF

    local tasks_json
    tasks_json=$(plan_parse_tasks "$plan")

    # The resolved file should appear in the files array of the first task
    local files_count
    files_count=$(echo "$tasks_json" | jq '.[0].files | length')
    [[ "$files_count" -ge 1 ]]

    local first_file
    first_file=$(echo "$tasks_json" | jq -r '.[0].files[0]')
    [[ "$first_file" == "src/auth/middleware.py" ]]
}

# =============================================================================
# TEST 12: Size field populated in parsed tasks (0/1/2)
# =============================================================================

@test "PLANOPT-2: size field populated in parsed tasks (0/1/2)" {
    local plan="$TEST_DIR/fix_plan.md"
    cat > "$plan" <<'EOF'
## Tasks
- [ ] Fix typo in config (`config.json`)
- [ ] Add user endpoint (`src/api/users.py`)
- [ ] Redesign authentication across all modules (`src/auth/a.py`, `src/auth/b.py`, `src/auth/c.py`)
EOF

    local tasks_json
    tasks_json=$(plan_parse_tasks "$plan")

    # Task 0: "Fix typo in config" with 1 file -> SMALL (0)
    local size0
    size0=$(echo "$tasks_json" | jq '.[0].size')
    [[ "$size0" -eq 0 ]]

    # Task 1: "Add user endpoint" with 1 file -> MEDIUM (1)
    local size1
    size1=$(echo "$tasks_json" | jq '.[1].size')
    [[ "$size1" -eq 1 ]]

    # Task 2: "Redesign authentication" with 3 files -> LARGE (2)
    local size2
    size2=$(echo "$tasks_json" | jq '.[2].size')
    [[ "$size2" -eq 2 ]]
}
