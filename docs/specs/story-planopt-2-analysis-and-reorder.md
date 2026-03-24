# Story RALPH-PLANOPT-2: Plan Analysis and Reordering Engine

**Epic:** [Plan Optimization on Startup](epic-plan-optimization.md)
**Priority:** Critical
**Status:** Not Started
**Effort:** Medium
**Component:** `lib/plan_optimizer.sh`
**Research basis:** Unix `tsort`, SWE-Agent phase ordering, Bazel hermetic validation, Turborepo `dependsOn`

---

## Problem

Ralph needs to reorder unchecked tasks within each `##` section of fix_plan.md for
optimal execution. The original design attempted NLP-style dependency detection in bash
(regex matching "create", "use") and a custom topological sort in jq — both fragile and
error-prone.

This story replaces both with:
1. **Real dependency detection** via the import graph (PLANOPT-1) + file-path extraction
2. **Unix `tsort`** for topological ordering (POSIX coreutil, zero custom sort code)
3. **Phase ordering** within module groups (proven by SWE-bench research)
4. **Semantic equivalence validation** before writing (Bazel-inspired hermetic check)

## Solution

### Three-layer dependency detection

**Layer 1: Import graph (highest confidence)**
When two tasks reference files where one imports the other, this is a real dependency.
Uses `import_graph_lookup` from PLANOPT-1.

**Layer 2: Explicit metadata (human override)**
Optional HTML comments in task text, inspired by Turborepo's `dependsOn`:
```markdown
- [ ] Create user database schema <!-- id: user-schema -->
- [ ] Add user API endpoint <!-- depends: user-schema -->
```
These override all heuristics. Strictly opt-in — plans without comments work identically.

**Layer 3: Phase convention (lowest priority, tiebreaker)**
Within a module group, tasks are ordered by lifecycle phase:
```
create/setup/init/define/schema  → rank 0
implement/add/build              → rank 1
modify/refactor/update/fix       → rank 2
test/spec/verify                 → rank 3
document/readme/comment          → rank 4
```
This mirrors the pattern all top SWE-bench agents converge on (SWE-Agent, Agentless,
AutoCodeRover).

### Layer 4: ralph-explorer resolution (for vague tasks)

Many real tasks don't mention file paths explicitly:
```markdown
- [ ] Fix the authentication flow          ← no file path
- [ ] Add rate limiting to the API          ← no file path
- [ ] Update the dashboard layout           ← no file path
```

These get `module: "zzz_unknown"` and can't be grouped or dependency-checked. When the
optimizer encounters tasks with no file references after regex extraction, it spawns
**ralph-explorer** (Haiku, fast, ~500 tokens per task) to resolve them:

```
Agent(ralph-explorer, "Which source files implement: Fix the authentication flow?
Return only file paths, one per line. Max 3 files.")
```

Explorer results are cached back into fix_plan.md as `<!-- resolved: path -->` metadata
so the explorer isn't re-called for the same task on subsequent loops:

```markdown
- [ ] Fix the authentication flow <!-- resolved: src/auth/middleware.py -->
```

**When to skip explorer:** If the task already has file references (regex found paths),
or if `RALPH_NO_EXPLORER_RESOLVE=true`, or if all tasks in the section have files.

**Performance guard:** Explorer resolution resolves at most **5 vague tasks per
optimization run** (matching the ContextManager's visible window). Tasks beyond the
visible window are resolved on subsequent loops as earlier tasks complete and the
window advances. This caps the worst-case to ~2500 tokens of Haiku calls (~10 seconds).

Explorer resolution runs **only when the plan has changed** (section hash mismatch).
On typical loops where Ralph just checks off tasks, no explorer calls are made.

**Cost:** ~500 tokens per vague task on Haiku. Capped at 5 per optimization run.
Cached after first resolution via `<!-- resolved: path -->` annotation.

### Ordering pipeline

```
1. Parse tasks → extract file refs, explicit metadata, phase, size
     ↓
1b. For tasks with no file refs → spawn ralph-explorer to resolve (Haiku, cached)
     ↓
2. Build dependency pairs from all 3 layers + explorer results
     ↓
3. Feed pairs to `tsort` → topological order
     ↓
4. Secondary sort (stable): module group → phase rank → size rank → original index
     ↓
5. Validate equivalence (abort if task set changed)
     ↓
6. Write back (atomic, backup kept 1 loop)
```

### "Lost in the Middle" awareness

Liu et al. (Stanford, 2023) proved LLMs perform worst on information in the middle of
context. Since the ContextManager shows ~5 unchecked tasks, the optimizer places the
**highest-dependency task first** (most other tasks depend on it) and avoids placing
critical tasks in positions 3-4 of the visible window.

## Implementation

### Task parsing

```bash
# lib/plan_optimizer.sh

plan_parse_tasks() {
    local fix_plan="$1"
    # Parse fix_plan.md into JSON array of task objects
    # Uses awk for line parsing + jq for JSON construction

    awk '
    BEGIN { section=""; task_idx=0; print "[" }
    /^## / { section=$0; next }
    /^- \[[ x]\]/ {
        if (task_idx > 0) print ","
        checked = ($0 ~ /\[x\]/) ? "true" : "false"

        # Extract text (strip checkbox)
        text = $0
        sub(/^- \[[ x]\] */, "", text)

        # Extract file paths (backtick-wrapped or bare with extensions)
        files = ""
        n = split(text, words, /[`]/)
        for (i=2; i<=n; i+=2) {
            if (words[i] ~ /\.[a-z]+$/) {
                files = files (files ? "," : "") "\"" words[i] "\""
            }
        }
        # Also try bare paths
        tmp = text
        while (match(tmp, /[a-zA-Z0-9_\/-]+\.(py|ts|tsx|js|jsx|sh|json|yaml|yml|toml|md)/, m)) {
            bare = substr(tmp, RSTART, RLENGTH)
            files = files (files ? "," : "") "\"" bare "\""
            tmp = substr(tmp, RSTART + RLENGTH)
        }

        # Extract explicit metadata: <!-- id: foo -->, <!-- depends: bar -->, <!-- resolved: path -->
        task_id = ""
        depends = ""
        resolved = ""
        if (match(text, /<!-- *id: *([a-zA-Z0-9_-]+) *-->/, m)) task_id = m[1]
        if (match(text, /<!-- *depends: *([a-zA-Z0-9_-]+) *-->/, m)) depends = m[1]
        if (match(text, /<!-- *resolved: *([a-zA-Z0-9_./-]+) *-->/, m)) {
            resolved = m[1]
            # Add resolved file to files array if not already present
            if (index(files, "\"" resolved "\"") == 0) {
                files = files (files ? "," : "") "\"" resolved "\""
            }
        }

        # Remove ALL metadata comments (including resolved: with path chars)
        gsub(/<!-- *[a-zA-Z]+: *[a-zA-Z0-9_./-]+ *-->/, "", text)
        gsub(/ +$/, "", text)

        # Count files for size estimation
        file_count = 0
        if (files != "") {
            file_count = split(files, _fc, ",")
        }

        # Inline size estimation (SMALL=0, MEDIUM=1, LARGE=2)
        size = 1  # default MEDIUM
        lower_text = tolower(text)
        if (file_count <= 1 && lower_text ~ /(rename|typo|config|comment|remove unused|fix.*import)/) size = 0
        else if (file_count >= 3 || lower_text ~ /(redesign|architect|cross.?module|new feature|security|integrate|migrate)/) size = 2

        printf "{\"idx\":%d,\"line_num\":%d,\"section\":\"%s\",\"text\":\"%s\",\"checked\":%s,\"files\":[%s],\"task_id\":\"%s\",\"depends\":\"%s\",\"size\":%d}", \
            task_idx, NR, section, text, checked, files, task_id, depends, size
        task_idx++
    }
    END { print "]" }
    ' "$fix_plan" | jq '.'  # Validate JSON
}
```

### Explorer-based file resolution (for vague tasks)

```bash
plan_resolve_vague_tasks() {
    local tasks_json="$1"
    local fix_plan="$2"
    local project_root="$3"
    local max_resolve="${4:-5}"  # Cap: only resolve first N vague tasks (ContextManager window)

    # Skip if explorer resolution is disabled
    [[ "${RALPH_NO_EXPLORER_RESOLVE:-false}" == "true" ]] && return 0

    # Skip if claude CLI is not available (e.g., running in CI without Claude)
    command -v claude &>/dev/null || return 0

    # Find tasks with zero file references and no <!-- resolved: --> annotation
    local vague_tasks
    vague_tasks=$(echo "$tasks_json" | jq -r '
        .[] | select(.checked == false and (.files | length) == 0) |
        "\(.idx)\t\(.text)"
    ' | head -"$max_resolve")

    [[ -z "$vague_tasks" ]] && return 0

    local resolved_count=0
    while IFS=$'\t' read -r idx text; do
        # Skip if already resolved in a previous run
        echo "$text" | grep -q '<!-- resolved:' && continue

        # Spawn ralph-explorer (Haiku — fast, cheap, ~500 tokens)
        # Uses Claude Code sub-agent protocol
        local explorer_result
        explorer_result=$(claude --agent ralph-explorer \
            --prompt "Which source files in $project_root implement this task: $text
Return ONLY file paths relative to project root, one per line. Max 3 files. No explanation." \
            --max-turns 5 \
            --output-format json 2>/dev/null | jq -r '.result // ""') || continue

        if [[ -n "$explorer_result" ]]; then
            # Take first valid file path
            local resolved_file
            resolved_file=$(echo "$explorer_result" | head -1 | grep -oE '[a-zA-Z0-9_/./-]+\.[a-z]+' | head -1)

            if [[ -n "$resolved_file" && -f "$project_root/$resolved_file" ]]; then
                # Annotate the task in fix_plan.md with resolved file
                local escaped_text
                escaped_text=$(printf '%s\n' "$text" | sed 's/[&/\]/\\&/g')
                sed -i "s|${escaped_text}|${text} <!-- resolved: ${resolved_file} -->|" "$fix_plan"
                resolved_count=$((resolved_count + 1))
            fi
        fi
    done <<< "$vague_tasks"

    if [[ $resolved_count -gt 0 ]]; then
        # Guard: plan_opt_log may not be defined yet (PLANOPT-5)
        declare -f plan_opt_log &>/dev/null && \
            plan_opt_log "Explorer resolved $resolved_count vague tasks to file paths"
    fi
}
```

### File-path to module mapping

```bash
plan_extract_module() {
    # Extract primary module from file paths (first 2 path components)
    local files_json="$1"
    echo "$files_json" | jq -r '
        if length == 0 then "zzz_unknown"
        else .[0] | split("/")[0:2] | join("/")
        end
    '
}
```

### Phase rank assignment

```bash
plan_phase_rank() {
    local text="$1"
    text=$(echo "$text" | tr '[:upper:]' '[:lower:]')
    case "$text" in
        *create*|*setup*|*init*|*define*|*schema*|*scaffold*|*bootstrap*)  echo 0 ;;
        *implement*|*add*|*build*|*write*|*develop*)                       echo 1 ;;
        *modify*|*refactor*|*update*|*fix*|*change*|*rename*|*move*)       echo 2 ;;
        *test*|*spec*|*verify*|*validate*|*assert*)                        echo 3 ;;
        *doc*|*readme*|*comment*|*changelog*|*release*)                    echo 4 ;;
        *)                                                                  echo 2 ;; # default: middle
    esac
}
```

### Size estimation

Size is now computed inline in the awk parser (output as `.size` field: 0=SMALL, 1=MEDIUM,
2=LARGE). The standalone function is kept for batch annotation and secondary sort:

```bash
# NOTE: Size heuristics here MUST match the inline estimation in plan_parse_tasks().
# If lib/complexity.sh (Phase 14) is available, prefer its classifier for consistency.
# The inline version exists because plan_parse_tasks runs in awk where sourcing
# bash functions isn't possible.

plan_size_rank() {
    local text="$1"
    local file_count="$2"  # number of files referenced
    text=$(echo "$text" | tr '[:upper:]' '[:lower:]')

    # SMALL: single-file, minor changes
    if [[ $file_count -le 1 ]] && echo "$text" | grep -qiE 'rename|typo|config|comment|remove unused|update.*version|fix.*import'; then
        echo 0; return
    fi

    # LARGE: cross-module, architectural
    if [[ $file_count -ge 3 ]] || echo "$text" | grep -qiE 'redesign|architect|cross.?module|new feature|security|integrate|migrate'; then
        echo 2; return
    fi

    # MEDIUM: everything else
    echo 1

    # TODO: When lib/complexity.sh is stable, delegate to its 5-level classifier
    # and map TRIVIAL/SMALL→0, MEDIUM→1, LARGE/ARCHITECTURAL→2
}
```

### Dependency pair generation and tsort

```bash
plan_build_dependency_pairs() {
    local tasks_json="$1"
    local import_graph="$2"  # path to .ralph/.import_graph.json
    local pairs_file="$3"    # output: one "A B" pair per line (A must come before B)

    : > "$pairs_file"

    local task_count
    task_count=$(echo "$tasks_json" | jq 'length')

    for ((i=0; i<task_count; i++)); do
        for ((j=i+1; j<task_count; j++)); do
            local files_i files_j depends_i depends_j id_i id_j section_i section_j

            section_i=$(echo "$tasks_json" | jq -r ".[$i].section")
            section_j=$(echo "$tasks_json" | jq -r ".[$j].section")

            # Never create cross-section dependencies
            [[ "$section_i" != "$section_j" ]] && continue

            # Skip checked tasks
            [[ $(echo "$tasks_json" | jq -r ".[$i].checked") == "true" ]] && continue
            [[ $(echo "$tasks_json" | jq -r ".[$j].checked") == "true" ]] && continue

            # Layer 2: Explicit metadata
            id_i=$(echo "$tasks_json" | jq -r ".[$i].task_id")
            id_j=$(echo "$tasks_json" | jq -r ".[$j].task_id")
            depends_i=$(echo "$tasks_json" | jq -r ".[$i].depends")
            depends_j=$(echo "$tasks_json" | jq -r ".[$j].depends")

            if [[ -n "$depends_j" && "$depends_j" == "$id_i" ]]; then
                echo "$i $j" >> "$pairs_file"  # i before j
                continue
            fi
            if [[ -n "$depends_i" && "$depends_i" == "$id_j" ]]; then
                echo "$j $i" >> "$pairs_file"  # j before i
                continue
            fi

            # Layer 1: Import graph
            if [[ -f "$import_graph" ]]; then
                files_i=$(echo "$tasks_json" | jq -r ".[$i].files[]" 2>/dev/null)
                files_j=$(echo "$tasks_json" | jq -r ".[$j].files[]" 2>/dev/null)

                for fi in $files_i; do
                    for fj in $files_j; do
                        # If file_i imports file_j → task j should come before task i
                        if jq -e --arg a "$fi" --arg b "$fj" \
                            '.[$a] // [] | index($b) != null' "$import_graph" &>/dev/null; then
                            echo "$j $i" >> "$pairs_file"
                        fi
                        # If file_j imports file_i → task i should come before task j
                        if jq -e --arg a "$fj" --arg b "$fi" \
                            '.[$a] // [] | index($b) != null' "$import_graph" &>/dev/null; then
                            echo "$i $j" >> "$pairs_file"
                        fi
                    done
                done
            fi
        done
    done
}

plan_topological_order() {
    local pairs_file="$1"
    local task_count="$2"

    if [[ ! -s "$pairs_file" ]]; then
        # No dependencies — return original order
        seq 0 $((task_count - 1))
        return
    fi

    # tsort produces a topological order; cycle warnings go to stderr
    # Add self-edges to ensure all tasks appear in output
    {
        seq 0 $((task_count - 1)) | while read -r n; do echo "$n $n"; done
        cat "$pairs_file"
    } | tsort 2>/dev/null
}
```

### Secondary sort (module + phase + size + original index)

```bash
plan_secondary_sort() {
    local tasks_json="$1"
    local topo_order="$2"  # newline-separated task indices from tsort

    # Assign composite sort key per task:
    # (topo_rank * 100000) + (module_hash * 1000) + (phase_rank * 100) + (size_rank * 10) + original_index_in_section
    # Then sort by composite key within each section

    local rank=0
    while IFS= read -r idx; do
        local section module phase size text files_json file_count

        section=$(echo "$tasks_json" | jq -r ".[$idx].section")
        text=$(echo "$tasks_json" | jq -r ".[$idx].text")
        files_json=$(echo "$tasks_json" | jq -c ".[$idx].files")
        file_count=$(echo "$files_json" | jq 'length')

        module=$(plan_extract_module "$files_json")
        phase=$(plan_phase_rank "$text")
        size=$(plan_size_rank "$text" "$file_count")

        # Module hash: consistent grouping (first 4 chars of md5)
        local mod_hash
        mod_hash=$(echo -n "$module" | md5sum 2>/dev/null | cut -c1-4 || echo -n "$module" | shasum 2>/dev/null | cut -c1-4)
        mod_num=$((16#${mod_hash}))

        local key=$(( rank * 100000 + (mod_num % 1000) * 1000 + phase * 100 + size * 10 + idx ))
        echo "$key $idx $section"
        rank=$((rank + 1))
    done <<< "$topo_order"
}
```

### Semantic equivalence validation

```bash
plan_validate_equivalence() {
    local before_tasks="$1"  # JSON array of task texts (pre-reorder)
    local after_tasks="$2"   # JSON array of task texts (post-reorder)

    local before_hash after_hash before_count after_count

    before_count=$(echo "$before_tasks" | jq 'length')
    after_count=$(echo "$after_tasks" | jq 'length')

    if [[ "$before_count" != "$after_count" ]]; then
        echo "PLAN_OPTIMIZE: ABORT — task count changed ($before_count → $after_count)" >&2
        return 1
    fi

    # Sort task texts and hash — order-independent content check
    before_hash=$(echo "$before_tasks" | jq -r '.[]' | sort | sha256sum | cut -d' ' -f1)
    after_hash=$(echo "$after_tasks" | jq -r '.[]' | sort | sha256sum | cut -d' ' -f1)

    if [[ "$before_hash" != "$after_hash" ]]; then
        echo "PLAN_OPTIMIZE: ABORT — task content changed during reorder" >&2
        return 1
    fi

    return 0
}
```

### Atomic write with durable backup

```bash
plan_write_optimized() {
    local fix_plan="$1"
    local reordered_json="$2"  # JSON array of reordered task objects per section

    local backup="${fix_plan}.pre-optimize.bak"
    local tmp="${fix_plan}.optimized.tmp"

    # Keep backup from previous optimization (if any) for 1 more loop
    # Only overwrite the backup, never delete it preemptively
    cp "$fix_plan" "$backup"

    # Rebuild fix_plan.md: preserve structure, replace unchecked task order
    # (awk reads original file, jq provides reordered tasks per section)
    awk -v reordered="$reordered_json" '
    BEGIN {
        # Load reordered tasks per section from JSON
        # ... (parse reordered_json into section→task_lines mapping)
    }
    /^## / {
        current_section = $0
        print
        next
    }
    /^- \[x\]/ {
        # Checked tasks: keep in original position
        print
        next
    }
    /^- \[ \]/ {
        # Unchecked tasks: replace with next task from reordered list for this section
        if (!section_emitted[current_section]) {
            # Emit all reordered unchecked tasks for this section
            # ... (print from reordered_json)
            section_emitted[current_section] = 1
        }
        next  # Skip original unchecked line
    }
    {
        # Everything else: headers, blank lines, comments — pass through
        print
    }
    ' "$fix_plan" > "$tmp"

    # Atomic replace
    mv "$tmp" "$fix_plan"

    # NOTE: $backup is intentionally kept for 1 full loop iteration.
    # It will be overwritten (not deleted) on the next optimization run.
}
```

### Top-level orchestrator

```bash
plan_optimize_section() {
    local fix_plan="$1"
    local project_root="$2"
    local import_graph="${3:-${RALPH_DIR:-.ralph}/.import_graph.json}"

    # Parse tasks
    local tasks_json
    tasks_json=$(plan_parse_tasks "$fix_plan")

    local unchecked_count
    unchecked_count=$(echo "$tasks_json" | jq '[.[] | select(.checked == false)] | length')

    # Early exit: nothing to reorder
    if [[ "$unchecked_count" -le 1 ]]; then
        return 0
    fi

    # Resolve vague tasks via ralph-explorer (Haiku, cached via <!-- resolved: -->)
    plan_resolve_vague_tasks "$tasks_json" "$fix_plan" "$project_root"
    # Re-parse after resolution (fix_plan may have been annotated)
    tasks_json=$(plan_parse_tasks "$fix_plan")

    # Capture pre-reorder task texts for equivalence check
    local before_texts
    before_texts=$(echo "$tasks_json" | jq '[.[] | select(.checked == false) | .text]')

    # Build dependency pairs
    local pairs_file
    pairs_file=$(mktemp)
    plan_build_dependency_pairs "$tasks_json" "$import_graph" "$pairs_file"

    # Topological sort via tsort
    local topo_order
    topo_order=$(plan_topological_order "$pairs_file" "$unchecked_count")
    rm -f "$pairs_file"

    # Secondary sort (module + phase + size)
    local sorted_keys
    sorted_keys=$(plan_secondary_sort "$tasks_json" "$topo_order" | sort -n | awk '{print $2}')

    # Build reordered task list
    local reordered_json
    reordered_json=$(echo "$sorted_keys" | while read -r idx; do
        echo "$tasks_json" | jq ".[$idx]"
    done | jq -s '.')

    # Validate semantic equivalence
    local after_texts
    after_texts=$(echo "$reordered_json" | jq '[.[] | .text]')

    if ! plan_validate_equivalence "$before_texts" "$after_texts"; then
        echo "PLAN_OPTIMIZE: Equivalence check failed, aborting" >&2
        return 1
    fi

    # Write optimized plan
    plan_write_optimized "$fix_plan" "$reordered_json"
}
```

## Example Transformation

**Before optimization:**
```markdown
## Phase 1: Core Setup
- [x] Project initialization
- [ ] Add error handling to API routes (`src/api/routes.py`)
- [ ] Create user database schema (`src/db/schema.py`)
- [ ] Fix typo in config (`config.json`)
- [ ] Add user API endpoint (`src/api/users.py`) <!-- depends: user-schema -->
- [ ] Rename old constant (`src/db/constants.py`)
- [ ] Create user database schema (`src/db/schema.py`) <!-- id: user-schema -->
- [ ] Add rate limiting to API (`src/api/middleware.py`)
```

**After optimization:**
```markdown
## Phase 1: Core Setup
- [x] Project initialization
- [ ] Create user database schema (`src/db/schema.py`) <!-- id: user-schema -->
- [ ] Rename old constant (`src/db/constants.py`)
- [ ] Add user API endpoint (`src/api/users.py`) <!-- depends: user-schema -->
- [ ] Add error handling to API routes (`src/api/routes.py`)
- [ ] Add rate limiting to API (`src/api/middleware.py`)
- [ ] Fix typo in config (`config.json`)
```

**Why this ordering:**
1. Schema created first (explicit dependency via `<!-- id/depends -->`)
2. `src/db/` tasks grouped (constants adjacent to schema)
3. API endpoint after its dependency (schema)
4. `src/api/` tasks grouped (routes, middleware together)
5. Isolated config fix last (no dependencies, different module)
6. Phase ordering respected: create(0) → implement(1) → modify(2)

## Test Plan

```bash
# tests/unit/test_plan_reorder.bats

@test "PLANOPT-2: respects explicit dependency metadata" {
    local plan=$(mktemp)
    cat > "$plan" <<'EOF'
## Tasks
- [ ] Add endpoint <!-- depends: schema -->
- [ ] Create schema <!-- id: schema -->
EOF
    plan_optimize_section "$plan" "." "/dev/null"
    # Schema must come before endpoint
    local schema_line=$(grep -n "Create schema" "$plan" | cut -d: -f1)
    local endpoint_line=$(grep -n "Add endpoint" "$plan" | cut -d: -f1)
    [[ $schema_line -lt $endpoint_line ]]
    rm -f "$plan"
}

@test "PLANOPT-2: respects import graph dependencies" {
    setup_python_project  # src/api/users.py imports src/db/schema.py
    import_graph_build_python "." ".ralph/.import_graph.json"

    local plan=$(mktemp)
    cat > "$plan" <<'EOF'
## Tasks
- [ ] Modify API endpoint (`src/api/users.py`)
- [ ] Update schema (`src/db/schema.py`)
EOF
    plan_optimize_section "$plan" "." ".ralph/.import_graph.json"
    # Schema task must come first (users.py imports schema.py)
    local schema_line=$(grep -n "schema" "$plan" | head -1 | cut -d: -f1)
    local api_line=$(grep -n "API endpoint" "$plan" | cut -d: -f1)
    [[ $schema_line -lt $api_line ]]
    rm -f "$plan"
}

@test "PLANOPT-2: groups tasks by module" {
    local plan=$(mktemp)
    cat > "$plan" <<'EOF'
## Tasks
- [ ] Fix API routes (`src/api/routes.py`)
- [ ] Update DB schema (`src/db/schema.py`)
- [ ] Add API middleware (`src/api/middleware.py`)
EOF
    plan_optimize_section "$plan" "." "/dev/null"
    # Both API tasks should be adjacent
    local routes_line=$(grep -n "API routes" "$plan" | cut -d: -f1)
    local middleware_line=$(grep -n "API middleware" "$plan" | cut -d: -f1)
    local schema_line=$(grep -n "DB schema" "$plan" | cut -d: -f1)
    # Routes and middleware should be adjacent (diff of 1)
    local diff=$(( middleware_line - routes_line ))
    [[ $diff -eq 1 || $diff -eq -1 ]]
    rm -f "$plan"
}

@test "PLANOPT-2: applies phase ordering within module" {
    local plan=$(mktemp)
    cat > "$plan" <<'EOF'
## Tasks
- [ ] Test user endpoint (`src/api/test_users.py`)
- [ ] Add user endpoint (`src/api/users.py`)
- [ ] Create user model (`src/api/models.py`)
EOF
    plan_optimize_section "$plan" "." "/dev/null"
    # Order should be: create → add → test
    local create_line=$(grep -n "Create" "$plan" | cut -d: -f1)
    local add_line=$(grep -n "Add" "$plan" | cut -d: -f1)
    local test_line=$(grep -n "Test" "$plan" | cut -d: -f1)
    [[ $create_line -lt $add_line ]]
    [[ $add_line -lt $test_line ]]
    rm -f "$plan"
}

@test "PLANOPT-2: never moves checked tasks" {
    local plan=$(mktemp)
    cat > "$plan" <<'EOF'
## Tasks
- [x] Done task
- [ ] Todo A
- [ ] Todo B
EOF
    plan_optimize_section "$plan" "." "/dev/null"
    # Checked task still first
    head -2 "$plan" | tail -1 | grep -q "\[x\]"
    rm -f "$plan"
}

@test "PLANOPT-2: preserves section boundaries" {
    local plan=$(mktemp)
    cat > "$plan" <<'EOF'
## Phase 1
- [ ] Task A (`src/api/a.py`)
## Phase 2
- [ ] Task B (`src/api/b.py`)
EOF
    plan_optimize_section "$plan" "." "/dev/null"
    # Task A still under Phase 1, Task B under Phase 2
    local phase1_line=$(grep -n "Phase 1" "$plan" | cut -d: -f1)
    local taskA_line=$(grep -n "Task A" "$plan" | cut -d: -f1)
    local phase2_line=$(grep -n "Phase 2" "$plan" | cut -d: -f1)
    local taskB_line=$(grep -n "Task B" "$plan" | cut -d: -f1)
    [[ $taskA_line -gt $phase1_line && $taskA_line -lt $phase2_line ]]
    [[ $taskB_line -gt $phase2_line ]]
    rm -f "$plan"
}

@test "PLANOPT-2: equivalence check catches dropped task" {
    local before='["Task A","Task B","Task C"]'
    local after='["Task A","Task B"]'  # Task C dropped
    run plan_validate_equivalence "$before" "$after"
    [[ "$status" -ne 0 ]]
}

@test "PLANOPT-2: equivalence check passes for reorder" {
    local before='["Task A","Task B","Task C"]'
    local after='["Task C","Task A","Task B"]'
    run plan_validate_equivalence "$before" "$after"
    [[ "$status" -eq 0 ]]
}

@test "PLANOPT-2: backup kept after write" {
    local plan=$(mktemp)
    echo -e "## Tasks\n- [ ] A\n- [ ] B" > "$plan"
    plan_optimize_section "$plan" "." "/dev/null"
    [[ -f "${plan}.pre-optimize.bak" ]]
    rm -f "$plan" "${plan}.pre-optimize.bak"
}

@test "PLANOPT-2: handles tsort cycle gracefully" {
    # Circular dependency: A depends on B, B depends on A
    local plan=$(mktemp)
    cat > "$plan" <<'EOF'
## Tasks
- [ ] Task A <!-- id: a --> <!-- depends: b -->
- [ ] Task B <!-- id: b --> <!-- depends: a -->
- [ ] Task C
EOF
    # Should not crash — tsort warns on stderr but produces best-effort order
    run plan_optimize_section "$plan" "." "/dev/null"
    [[ "$status" -eq 0 ]]
    rm -f "$plan"
}

@test "PLANOPT-2: single unchecked task is a no-op" {
    local plan=$(mktemp)
    echo -e "## Tasks\n- [x] Done\n- [ ] Only one left" > "$plan"
    local before=$(cat "$plan")
    plan_optimize_section "$plan" "." "/dev/null"
    local after=$(cat "$plan")
    [[ "$before" == "$after" ]]
    rm -f "$plan"
}
```

## Acceptance Criteria

- [ ] Three-layer dependency detection: import graph → explicit metadata → phase convention
- [ ] Topological sort via Unix `tsort` (zero custom sort code)
- [ ] Phase ordering applied within module groups (create→implement→modify→test→document)
- [ ] Module grouping clusters tasks touching the same directory
- [ ] Size estimation: SMALL/MEDIUM/LARGE based on keywords and file count
- [ ] Semantic equivalence validated before write (count + content hash)
- [ ] Checked `[x]` tasks never moved
- [ ] Tasks never cross `##` section boundaries
- [ ] Original order preserved as stable-sort tiebreaker
- [ ] Backup kept for 1 full loop (overwritten, not deleted)
- [ ] Atomic write via temp file + `mv`
- [ ] Handles `tsort` cycle detection gracefully (warns, continues)
- [ ] Single unchecked task = no-op (no write)
- [ ] Optional `<!-- id: -->` and `<!-- depends: -->` metadata parsed
- [ ] ralph-explorer (Haiku) resolves vague tasks with no file references to file paths
- [ ] Resolved files cached as `<!-- resolved: path -->` in fix_plan.md (explorer not re-called)
- [ ] `RALPH_NO_EXPLORER_RESOLVE=true` disables explorer resolution
- [ ] Explorer resolution skipped when all tasks already have file references
