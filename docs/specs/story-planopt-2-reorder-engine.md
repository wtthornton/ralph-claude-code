# Story RALPH-PLANOPT-2: Task Reordering Engine

**Epic:** [Plan Optimization on Startup](epic-plan-optimization.md)
**Priority:** Critical
**Status:** Not Started
**Effort:** Medium
**Component:** `lib/plan_optimizer.sh`

---

## Problem

Even with perfect analysis data (PLANOPT-1), Ralph still needs a reordering algorithm
that produces an optimal task sequence. The reorder must respect constraints (dependencies,
section boundaries, checked tasks) while optimizing for module locality, size clustering,
and minimal context switching.

## Solution

Add a reordering function to `lib/plan_optimizer.sh` that takes the analyzed task JSON
from PLANOPT-1 and produces an optimized ordering. The algorithm:

1. **Topological sort** — Respect dependencies (tasks with prerequisites come after them)
2. **Module grouping** — Within dependency-valid orderings, cluster tasks by module
3. **Size clustering** — Group SMALL tasks together (enables batching 8 at a time),
   keep LARGE tasks isolated
4. **Write back** — Rewrite only the unchecked task lines within each section,
   preserving everything else (headers, checked tasks, blank lines, comments)

### Ordering priority (highest to lowest):

1. **Hard dependencies** — A task that depends on another must come after it. Violating
   this wastes an entire loop.
2. **Module locality** — Tasks in the same module should be adjacent. Reduces explorer
   calls and file re-reads.
3. **Size clustering** — Adjacent SMALL tasks enable batching (up to 8 per loop).
   Adjacent MEDIUM tasks batch up to 5. LARGE tasks stay isolated.
4. **Original order** — When all else is equal, preserve the human's ordering as a
   tiebreaker (stable sort).

## Implementation

```bash
plan_reorder_tasks() {
    local tasks_json="$1"
    # Input: JSON array from plan_analyze_tasks + plan_detect_dependencies
    # Output: JSON array with reordered tasks (same objects, new order)

    # Step 1: Topological sort respecting depends_on
    # Step 2: Within topo-valid order, group by module
    # Step 3: Within module groups, cluster by size (SMALL together, etc.)
    # Step 4: Stable sort — preserve original order as tiebreaker

    # Implementation: single jq script that:
    # - Assigns composite sort key: (topo_rank * 10000) + (module_hash * 100) + (size_rank * 10) + original_index
    # - Sorts by composite key
    echo "$tasks_json" | jq '
        # Topological rank: tasks with no deps = 0, tasks depending on rank-0 = 1, etc.
        # Module hash: group tasks sharing the same module prefix
        # Size rank: SMALL=0, MEDIUM=1, LARGE=2 (clusters SMALLs first within module)
        # Original index preserves human intent as tiebreaker

        def topo_rank:
            # Iterative topological sort
            # Returns array of {task, rank} objects
            ...;

        def module_key:
            .module // .files[0] // "zzz_unknown"
            | split("/")[0:2] | join("/");

        def size_rank:
            if .size == "SMALL" then 0
            elif .size == "MEDIUM" then 1
            else 2 end;

        [.[] | select(.checked == false)]
        | topo_rank
        | sort_by(.topo_rank, module_key, size_rank, .line_num)
    '
}

plan_write_optimized() {
    local fix_plan="$1"
    local reordered_json="$2"

    # Strategy: rebuild fix_plan.md preserving structure
    # 1. Read original file
    # 2. For each ## section:
    #    a. Keep the header line
    #    b. Keep all checked [x] tasks in original position
    #    c. Replace unchecked [ ] tasks with reordered sequence for that section
    #    d. Keep blank lines and comments
    # 3. Write to temp file, then atomic mv

    local tmp="${fix_plan}.optimized.tmp"

    # Backup original
    cp "$fix_plan" "${fix_plan}.pre-optimize.bak"

    # Rebuild using awk + jq
    # ... (awk reads line by line, jq provides reordered tasks per section)

    mv "$tmp" "$fix_plan"
    rm -f "${fix_plan}.pre-optimize.bak"  # Only after successful write
}
```

### Example transformation

**Before optimization:**
```markdown
## Phase 1: Core Setup
- [ ] Add error handling to API routes (src/api/routes.py)           # MEDIUM, module: src/api
- [ ] Create user database schema (src/db/schema.py)                  # MEDIUM, module: src/db
- [ ] Fix typo in config (config.json)                                # SMALL, module: config
- [ ] Add user API endpoint (src/api/users.py, depends on schema)     # MEDIUM, module: src/api
- [ ] Rename old constant (src/db/constants.py)                       # SMALL, module: src/db
- [ ] Add rate limiting to API (src/api/middleware.py)                 # MEDIUM, module: src/api
- [x] Project initialization                                          # checked, don't move
```

**After optimization:**
```markdown
## Phase 1: Core Setup
- [x] Project initialization                                          # checked, stays in place
- [ ] Create user database schema (src/db/schema.py)                  # MEDIUM, src/db — moved up (creates dependency)
- [ ] Rename old constant (src/db/constants.py)                       # SMALL, src/db — grouped with schema
- [ ] Add user API endpoint (src/api/users.py, depends on schema)     # MEDIUM, src/api — after its dependency
- [ ] Add error handling to API routes (src/api/routes.py)            # MEDIUM, src/api — grouped with API
- [ ] Add rate limiting to API (src/api/middleware.py)                 # MEDIUM, src/api — grouped with API
- [ ] Fix typo in config (config.json)                                # SMALL, config — last (isolated module)
```

**Why this is better:**
- Schema created before endpoint that needs it (dependency respected)
- All `src/db` tasks adjacent → one explorer call, files stay in context
- All `src/api` tasks adjacent → one explorer call, can batch if sizes allow
- Isolated config fix at end → doesn't interrupt module flow

## Test Plan

```bash
# tests/unit/test_plan_reorder.bats

@test "PLANOPT-2: respects dependency ordering" {
    local tasks='[
        {"line_num":1, "text":"Add endpoint", "depends_on":[2], "module":"src/api", "size":"MEDIUM", "checked":false},
        {"line_num":2, "text":"Create schema", "depends_on":[], "module":"src/db", "size":"MEDIUM", "checked":false}
    ]'
    local result=$(echo "$tasks" | plan_reorder_tasks)
    # Schema (line 2) must come before endpoint (line 1)
    local first=$(echo "$result" | jq '.[0].line_num')
    [[ "$first" == "2" ]]
}

@test "PLANOPT-2: groups tasks by module" {
    local tasks='[
        {"line_num":1, "text":"Fix api", "depends_on":[], "module":"src/api", "size":"MEDIUM", "checked":false},
        {"line_num":2, "text":"Fix db", "depends_on":[], "module":"src/db", "size":"MEDIUM", "checked":false},
        {"line_num":3, "text":"Add api", "depends_on":[], "module":"src/api", "size":"MEDIUM", "checked":false}
    ]'
    local result=$(echo "$tasks" | plan_reorder_tasks)
    # Both api tasks should be adjacent
    local m0=$(echo "$result" | jq -r '.[0].module')
    local m1=$(echo "$result" | jq -r '.[1].module')
    [[ "$m0" == "$m1" ]] || {
        local m2=$(echo "$result" | jq -r '.[2].module')
        [[ "$m1" == "$m2" ]]
    }
}

@test "PLANOPT-2: clusters SMALL tasks together" {
    local tasks='[
        {"line_num":1, "text":"Big feature", "depends_on":[], "module":"src", "size":"LARGE", "checked":false},
        {"line_num":2, "text":"Fix typo", "depends_on":[], "module":"src", "size":"SMALL", "checked":false},
        {"line_num":3, "text":"Rename var", "depends_on":[], "module":"src", "size":"SMALL", "checked":false}
    ]'
    local result=$(echo "$tasks" | plan_reorder_tasks)
    # Two SMALL tasks should be adjacent
    local s1=$(echo "$result" | jq -r '.[0].size')
    local s2=$(echo "$result" | jq -r '.[1].size')
    [[ "$s1" == "SMALL" && "$s2" == "SMALL" ]] || \
    [[ "$(echo "$result" | jq -r '.[1].size')" == "SMALL" && "$(echo "$result" | jq -r '.[2].size')" == "SMALL" ]]
}

@test "PLANOPT-2: never moves checked tasks" {
    local tasks='[
        {"line_num":1, "text":"Done task", "depends_on":[], "module":"src", "size":"SMALL", "checked":true},
        {"line_num":2, "text":"Todo task", "depends_on":[], "module":"src", "size":"SMALL", "checked":false}
    ]'
    local result=$(echo "$tasks" | plan_reorder_tasks)
    # Only unchecked tasks in output
    local count=$(echo "$result" | jq 'length')
    [[ "$count" == "1" ]]
}

@test "PLANOPT-2: preserves section boundaries" {
    # Tasks from different sections should never be mixed
    local tasks='[
        {"line_num":1, "section":"## Phase 1", "text":"A", "depends_on":[], "module":"src/api", "size":"SMALL", "checked":false},
        {"line_num":5, "section":"## Phase 2", "text":"B", "depends_on":[], "module":"src/api", "size":"SMALL", "checked":false}
    ]'
    local result=$(echo "$tasks" | plan_reorder_tasks)
    # Sections preserved — Phase 1 task still before Phase 2 task
    local s0=$(echo "$result" | jq -r '.[0].section')
    [[ "$s0" == "## Phase 1" ]]
}

@test "PLANOPT-2: write_optimized creates backup" {
    local tmpdir=$(mktemp -d)
    echo -e "## Tasks\n- [ ] Task A\n- [ ] Task B" > "$tmpdir/fix_plan.md"
    plan_write_optimized "$tmpdir/fix_plan.md" '[{"line_num":2,"text":"Task B"},{"line_num":1,"text":"Task A"}]'
    # Backup should exist during write (cleaned up after)
    [[ -f "$tmpdir/fix_plan.md" ]]
    rm -rf "$tmpdir"
}
```

## Acceptance Criteria

- [ ] Topological sort respects all detected dependencies
- [ ] Tasks are grouped by module within dependency constraints
- [ ] SMALL tasks are clustered to enable batching
- [ ] Checked `[x]` tasks are never moved
- [ ] Tasks never cross `##` section boundaries
- [ ] Original order is preserved as tiebreaker (stable sort)
- [ ] Atomic write with backup (no data loss on failure)
- [ ] Empty sections and sections with only checked tasks are untouched
