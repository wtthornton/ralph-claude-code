# Story RALPH-PLANOPT-1: Plan Analysis and Dependency Detection

**Epic:** [Plan Optimization on Startup](epic-plan-optimization.md)
**Priority:** Critical
**Status:** Not Started
**Effort:** Medium
**Component:** `lib/plan_optimizer.sh`

---

## Problem

Ralph has no understanding of task relationships. A fix_plan.md might list "Add user API
endpoint" before "Create user database schema" — Ralph will attempt the endpoint first,
waste a loop discovering the schema doesn't exist, then either hack around it or fail.

There is also no awareness of which tasks touch which files/modules. Two tasks editing
`lib/circuit_breaker.sh` might be separated by five unrelated tasks, forcing Ralph to
re-read and re-explore the module context twice.

## Solution

Create `lib/plan_optimizer.sh` with analysis functions that parse fix_plan.md and extract:

1. **Task metadata** — For each unchecked task, extract:
   - File paths mentioned (explicit `path/to/file.sh` references)
   - Module hints (keywords like "circuit breaker", "auth", "dashboard" mapped to directories)
   - Size estimate (SMALL/MEDIUM/LARGE based on keyword heuristics)
   - Dependency signals (words like "after", "requires", "depends on", "using the X from")

2. **Dependency graph** — Build a simple dependency list:
   - Explicit: task text says "after PLANOPT-1" or "requires the schema from task above"
   - Implicit: task mentions a file/function that another task creates ("Create X" before "Use X")
   - Convention: "setup/init/create/define" tasks before "implement/add/extend" tasks

3. **Module grouping** — Cluster tasks by primary file/directory:
   - Extract file paths and directory prefixes
   - Group tasks sharing the same `lib/`, `src/component/`, `tests/unit/` prefix
   - Score proximity: same file > same directory > same top-level module

## Implementation

```bash
# lib/plan_optimizer.sh

# Parse fix_plan.md into structured task data
# Input: path to fix_plan.md
# Output: JSON array to stdout
#
# Each task object:
# {
#   "line_num": 15,
#   "section": "## High Priority",
#   "text": "Create user database schema",
#   "checked": false,
#   "files": ["src/db/schema.py"],
#   "module": "src/db",
#   "size": "MEDIUM",
#   "depends_on": [],
#   "creates": ["schema", "user model"],
#   "order_weight": 0
# }

plan_analyze_tasks() {
    local fix_plan="$1"
    # Parse sections, extract tasks, detect file references and keywords
    # Uses awk for parsing + jq for JSON output
}

plan_detect_dependencies() {
    local tasks_json="$1"
    # Cross-reference "creates" vs file/keyword mentions
    # Output: tasks_json with depends_on populated
}

plan_score_modules() {
    local tasks_json="$1"
    local project_root="$2"
    # Scan actual project directory structure
    # Map task keywords to real directories
    # Score module proximity between task pairs
}
```

### File path extraction heuristics

```bash
# Explicit paths: backtick-wrapped or bare paths with extensions
grep -oP '`[a-zA-Z0-9_./-]+\.[a-z]+`' | tr -d '`'
grep -oP '\b[a-zA-Z0-9_/-]+\.(sh|py|ts|tsx|js|jsx|json|md|yaml|yml|toml)\b'

# Module keywords → directory mapping (project-specific, built from actual tree)
# "circuit breaker" → lib/circuit_breaker.sh
# "dashboard" → frontend/src/Dashboard.tsx
# Built dynamically by scanning project files at analysis time
```

### Size estimation heuristics

```bash
# SMALL signals: "rename", "update config", "fix typo", "change X to Y",
#   "add comment", "remove unused", single file reference
# MEDIUM signals: "add", "implement", "create", "refactor", multi-file,
#   module-scoped changes
# LARGE signals: "redesign", "architect", "cross-module", "new feature",
#   "security", 3+ file references, "integrate"
```

### Dependency signals

```bash
# Explicit: "after X", "requires X", "depends on X", "once X is done"
# Creation: "create", "define", "set up", "initialize", "add schema"
# Consumption: "use", "extend", "add to", "implement X endpoint" (needs X model)
# Convention: setup → implement → test → document
```

## Test Plan

```bash
# tests/unit/test_plan_optimizer.bats

@test "PLANOPT-1: extracts file paths from task text" {
    echo '- [ ] Fix bug in `lib/circuit_breaker.sh` validation' | \
        plan_extract_files | grep -q "lib/circuit_breaker.sh"
}

@test "PLANOPT-1: detects explicit dependency" {
    echo '- [ ] After schema is created, add user API endpoint' | \
        plan_detect_dependency_signals | grep -q "schema"
}

@test "PLANOPT-1: estimates SMALL for rename tasks" {
    echo '- [ ] Rename foo to bar in config.json' | \
        plan_estimate_size | grep -q "SMALL"
}

@test "PLANOPT-1: estimates LARGE for cross-module tasks" {
    echo '- [ ] Redesign auth middleware across all API routes' | \
        plan_estimate_size | grep -q "LARGE"
}

@test "PLANOPT-1: groups tasks by shared module" {
    local tasks='[
        {"text": "Fix lib/cb.sh validation", "files": ["lib/cb.sh"]},
        {"text": "Add lib/cb.sh recovery", "files": ["lib/cb.sh"]},
        {"text": "Update frontend dashboard", "files": ["frontend/dash.tsx"]}
    ]'
    local groups=$(echo "$tasks" | plan_group_by_module)
    echo "$groups" | jq -e '."lib" | length == 2'
    echo "$groups" | jq -e '."frontend" | length == 1'
}

@test "PLANOPT-1: detects create-before-use dependency" {
    local tasks='[
        {"text": "Add user API endpoint", "creates": []},
        {"text": "Create user database schema", "creates": ["user schema"]}
    ]'
    local deps=$(echo "$tasks" | plan_detect_dependencies)
    # Task 0 should depend on task 1 (endpoint needs schema)
    echo "$deps" | jq -e '.[0].depends_on | length > 0'
}
```

## Acceptance Criteria

- [ ] `plan_analyze_tasks` parses fix_plan.md into JSON task array
- [ ] File paths are extracted from backtick-wrapped and bare path references
- [ ] Module mapping is built dynamically from actual project directory tree
- [ ] Size estimation matches expected output for SMALL/MEDIUM/LARGE keywords
- [ ] Dependency detection catches explicit ("after X") and implicit (create→use) patterns
- [ ] All functions are pure (read-only, no side effects, output to stdout)
- [ ] Works on fix_plan.md files with 0-100+ tasks
