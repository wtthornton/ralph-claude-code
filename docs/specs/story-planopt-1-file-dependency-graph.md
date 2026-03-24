# Story RALPH-PLANOPT-1: File Dependency Graph

**Epic:** [Plan Optimization on Startup](epic-plan-optimization.md)
**Priority:** Critical
**Status:** Not Started
**Effort:** Medium
**Component:** `lib/import_graph.sh`
**Research basis:** Nx/Turborepo affected analysis, Python `ast` module, `madge`/`dependency-cruiser`

---

## Problem

The original design used NLP heuristics in bash (regex matching "create", "use", "depends on")
to guess task dependencies from task text. This is the single biggest quality risk — wrong
dependency detection makes task ordering **worse** than the human's original order.

Real dependency information exists in the codebase's import graph. If file A imports file B,
then any task touching A implicitly depends on tasks that create or modify B. This is exactly
how Nx computes its "affected" analysis and how Bazel resolves build dependencies.

## Solution

Create `lib/import_graph.sh` that builds a file-level dependency graph via AST parsing,
caches it, and provides lookup functions for the reordering engine.

### Language support

| Language | Tool | Command |
|----------|------|---------|
| Python | `ast` (stdlib) | `python3 -c "import ast; ..."` |
| JavaScript/TypeScript | `madge` (if available) | `npx madge --json src/` |
| JS/TS fallback | `grep` for import/require | `grep -rn "^import\|require(" src/` |
| Other | File-path heuristic only | No import graph, fall back to directory proximity |

### Architecture

```
lib/import_graph.sh
├── import_graph_build()            # Build graph, write to cache
├── import_graph_build_async()      # Build graph in background subprocess (non-blocking)
├── import_graph_load()             # Load cached graph
├── import_graph_is_stale()         # Check if rebuild needed (mtime or stale flag)
├── import_graph_invalidate_file()  # Mark specific file entry stale (for hooks)
├── import_graph_lookup()           # Query: does file A depend on file B?
└── import_graph_dependents()       # Query: what files depend on file A?
```

### Background build (non-blocking)

For large projects (1000+ files), synchronous graph building can take 1-3 seconds,
blocking the SessionStart hook. Following the pattern from `ralph-bg-tester` (background
agent), the graph build runs as an async subprocess:

```bash
import_graph_build_async() {
    local project_root="$1"
    local cache_file="$2"
    local pid_file="${cache_file}.build.pid"

    # Don't start if already building
    if [[ -f "$pid_file" ]] && kill -0 "$(cat "$pid_file")" 2>/dev/null; then
        return 0  # Build already in progress
    fi

    # Launch background build
    (
        import_graph_build "$project_root" "${cache_file}.tmp"
        mv "${cache_file}.tmp" "$cache_file"
        rm -f "$pid_file"
    ) &
    echo $! > "$pid_file"
}
```

When the graph is stale and a background build is launched, the optimizer uses the
**previous cached graph** for the current loop. The fresh graph will be available
for the next loop. This trades one loop of slightly stale data for zero blocking.

### Incremental invalidation (for hooks)

The `TaskCompleted` and `Stop` hooks track which files were modified. Instead of
rebuilding the entire graph, they can invalidate specific entries:

```bash
import_graph_invalidate_file() {
    local file_path="$1"
    local cache_file="${2:-$IMPORT_GRAPH_CACHE}"

    if [[ -f "$cache_file" ]]; then
        # Remove the file's entry (its imports may have changed)
        jq --arg f "$file_path" 'del(.[$f])' "$cache_file" > "${cache_file}.tmp" && \
            mv "${cache_file}.tmp" "$cache_file"
        # Touch a stale flag so next session knows to rebuild
        touch "${cache_file}.stale"
    fi
}
```

## Implementation

### Graph builder (Python projects)

```bash
import_graph_build_python() {
    local project_root="$1"
    local cache_file="$2"  # .ralph/.import_graph.json

    python3 -c "
import ast, json, pathlib, sys

graph = {}
root = pathlib.Path('${project_root}')
for f in root.rglob('*.py'):
    if 'node_modules' in str(f) or '.venv' in str(f) or '__pycache__' in str(f):
        continue
    try:
        tree = ast.parse(f.read_text(encoding='utf-8', errors='ignore'))
        deps = []
        for node in ast.walk(tree):
            if isinstance(node, ast.ImportFrom) and node.module:
                # Convert module path to file path
                mod_path = node.module.replace('.', '/')
                for ext in ['.py', '/__init__.py']:
                    candidate = root / (mod_path + ext)
                    if candidate.exists():
                        deps.append(str(candidate.relative_to(root)))
                        break
            elif isinstance(node, ast.Import):
                for alias in node.names:
                    mod_path = alias.name.replace('.', '/')
                    for ext in ['.py', '/__init__.py']:
                        candidate = root / (mod_path + ext)
                        if candidate.exists():
                            deps.append(str(candidate.relative_to(root)))
                            break
        rel = str(f.relative_to(root))
        graph[rel] = sorted(set(deps))
    except (SyntaxError, UnicodeDecodeError):
        pass

json.dump(graph, sys.stdout, indent=2)
" > "$cache_file"
}
```

### Graph builder (JS/TS projects)

```bash
import_graph_build_js() {
    local project_root="$1"
    local cache_file="$2"

    # Prefer madge if available (accurate, handles aliases)
    if command -v npx &>/dev/null && [[ -f "$project_root/package.json" ]]; then
        npx --yes madge --json "$project_root/src" 2>/dev/null > "$cache_file" && return 0
    fi

    # Fallback: grep-based extraction (less accurate but zero dependencies)
    python3 -c "
import json, re, pathlib, sys

graph = {}
root = pathlib.Path('${project_root}')
for ext in ['*.js', '*.jsx', '*.ts', '*.tsx']:
    for f in root.rglob(ext):
        if 'node_modules' in str(f):
            continue
        try:
            content = f.read_text(encoding='utf-8', errors='ignore')
            imports = re.findall(r'''(?:import\s+.*?from\s+['\"](.+?)['\"]|require\(['\"](.+?)['\"]\))''', content)
            deps = [m[0] or m[1] for m in imports if not (m[0] or m[1]).startswith('.') == False]
            # Resolve relative imports
            resolved = []
            for dep in deps:
                if dep.startswith('.'):
                    candidate = (f.parent / dep).resolve()
                    for try_ext in ['', '.ts', '.tsx', '.js', '.jsx', '/index.ts', '/index.js']:
                        full = pathlib.Path(str(candidate) + try_ext)
                        if full.exists():
                            resolved.append(str(full.relative_to(root)))
                            break
            graph[str(f.relative_to(root))] = sorted(set(resolved))
        except (UnicodeDecodeError, OSError):
            pass

json.dump(graph, sys.stdout, indent=2)
" > "$cache_file"
}
```

### Staleness detection and caching

```bash
IMPORT_GRAPH_CACHE="${RALPH_DIR:-.ralph}/.import_graph.json"

import_graph_is_stale() {
    local project_root="$1"
    local cache_file="$2"

    # No cache = stale
    [[ ! -f "$cache_file" ]] && return 0

    # Stale flag set by incremental invalidation (from hooks)
    [[ -f "${cache_file}.stale" ]] && rm -f "${cache_file}.stale" && return 0

    # Find any source file newer than the cache
    local src_dirs=("src" "lib" "app" "pkg" ".")
    for dir in "${src_dirs[@]}"; do
        [[ -d "$project_root/$dir" ]] || continue
        local newer=$(find "$project_root/$dir" \
            \( -name '*.py' -o -name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.jsx' \) \
            -newer "$cache_file" \
            ! -path '*/node_modules/*' ! -path '*/.venv/*' ! -path '*/__pycache__/*' \
            -print -quit 2>/dev/null)
        [[ -n "$newer" ]] && return 0  # Stale
    done

    return 1  # Fresh
}

import_graph_ensure() {
    local project_root="$1"
    local cache_file="${2:-$IMPORT_GRAPH_CACHE}"

    if import_graph_is_stale "$project_root" "$cache_file"; then
        local project_type="${PROJECT_TYPE:-}"

        # Auto-detect if not set
        if [[ -z "$project_type" ]]; then
            if [[ -f "$project_root/pyproject.toml" || -f "$project_root/setup.py" ]]; then
                project_type="python"
            elif [[ -f "$project_root/package.json" ]]; then
                project_type="javascript"
            fi
        fi

        case "$project_type" in
            python)  import_graph_build_python "$project_root" "$cache_file" ;;
            javascript|typescript) import_graph_build_js "$project_root" "$cache_file" ;;
            *)
                # No graph available — write empty graph
                echo '{}' > "$cache_file"
                ;;
        esac
    fi
}

import_graph_lookup() {
    # Does file $1 depend on file $2?
    local file_a="$1"
    local file_b="$2"
    local cache_file="${3:-$IMPORT_GRAPH_CACHE}"

    jq -e --arg a "$file_a" --arg b "$file_b" \
        '.[$a] // [] | index($b) != null' "$cache_file" 2>/dev/null
}

import_graph_dependents() {
    # What files depend on file $1?
    local target="$1"
    local cache_file="${2:-$IMPORT_GRAPH_CACHE}"

    jq -r --arg t "$target" \
        'to_entries[] | select(.value | index($t) != null) | .key' "$cache_file" 2>/dev/null
}
```

### Performance budget

- **Graph build (Python, ~500 files):** < 1 second (AST parsing is fast)
- **Graph build (JS/TS with madge, ~1000 files):** < 3 seconds (one-time cost)
- **Staleness check:** < 50ms (single `find -newer -quit`)
- **Lookup query:** < 10ms (jq on cached JSON)
- **Typical loop (cache fresh):** < 50ms total (staleness check only)

## Test Plan

```bash
# tests/unit/test_import_graph.bats

@test "PLANOPT-1: builds Python import graph" {
    setup_python_project  # Creates src/main.py importing src/db.py
    import_graph_build_python "." ".ralph/.import_graph.json"
    [[ -f .ralph/.import_graph.json ]]
    jq -e '."src/main.py" | index("src/db.py") != null' .ralph/.import_graph.json
}

@test "PLANOPT-1: detects staleness when source file is newer" {
    setup_python_project
    import_graph_build_python "." ".ralph/.import_graph.json"
    sleep 1
    touch src/new_file.py
    run import_graph_is_stale "." ".ralph/.import_graph.json"
    [[ "$status" -eq 0 ]]  # Stale
}

@test "PLANOPT-1: cache is fresh when no files changed" {
    setup_python_project
    import_graph_build_python "." ".ralph/.import_graph.json"
    run import_graph_is_stale "." ".ralph/.import_graph.json"
    [[ "$status" -eq 1 ]]  # Fresh
}

@test "PLANOPT-1: lookup returns true for direct dependency" {
    setup_python_project  # main.py imports db.py
    import_graph_build_python "." ".ralph/.import_graph.json"
    run import_graph_lookup "src/main.py" "src/db.py" ".ralph/.import_graph.json"
    [[ "$status" -eq 0 ]]
}

@test "PLANOPT-1: lookup returns false for no dependency" {
    setup_python_project
    import_graph_build_python "." ".ralph/.import_graph.json"
    run import_graph_lookup "src/db.py" "src/main.py" ".ralph/.import_graph.json"
    [[ "$status" -ne 0 ]]
}

@test "PLANOPT-1: dependents query finds reverse dependencies" {
    setup_python_project  # main.py imports db.py
    import_graph_build_python "." ".ralph/.import_graph.json"
    run import_graph_dependents "src/db.py" ".ralph/.import_graph.json"
    echo "$output" | grep -q "src/main.py"
}

@test "PLANOPT-1: handles empty project gracefully" {
    mkdir -p empty_project
    import_graph_build_python "empty_project" ".ralph/.import_graph.json"
    jq -e '. == {}' .ralph/.import_graph.json
}

@test "PLANOPT-1: skips venv and node_modules" {
    setup_python_project
    mkdir -p .venv/lib
    echo "import os" > .venv/lib/something.py
    import_graph_build_python "." ".ralph/.import_graph.json"
    run jq -e 'has(".venv/lib/something.py")' .ralph/.import_graph.json
    [[ "$status" -ne 0 ]]  # Not in graph
}

@test "PLANOPT-1: auto-detects project type" {
    setup_python_project  # Has pyproject.toml
    import_graph_ensure "."
    [[ -f .ralph/.import_graph.json ]]
    jq -e 'length > 0' .ralph/.import_graph.json
}
```

## Acceptance Criteria

- [ ] Import graph built for Python projects via `ast.parse()` (zero external dependencies)
- [ ] Import graph built for JS/TS projects via `madge` (preferred) or grep fallback
- [ ] Graph cached in `.ralph/.import_graph.json`
- [ ] Staleness detection via file mtime (rebuild only when source files change)
- [ ] `import_graph_lookup` answers "does A depend on B?" in < 10ms
- [ ] `import_graph_dependents` answers "what depends on A?" in < 10ms
- [ ] Graceful fallback to empty graph for unsupported languages
- [ ] Skips `node_modules/`, `.venv/`, `__pycache__/`, and other generated directories
- [ ] Handles syntax errors in source files without crashing (skip and continue)
- [ ] Graph build completes in < 3 seconds for projects with up to 1000 source files
- [ ] `import_graph_build_async` runs graph build in background subprocess (non-blocking)
- [ ] `import_graph_invalidate_file` removes a single entry and touches `.stale` flag
- [ ] Stale flag detected by `import_graph_is_stale` (for hook-driven invalidation)
- [ ] Background build uses `.tmp` + `mv` pattern (atomic update, no partial reads)
