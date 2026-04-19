#!/bin/bash

# lib/import_graph.sh — File dependency graph via AST parsing (PLANOPT-1)
#
# Builds a file-level import graph, caches it in .ralph/.import_graph.json,
# and provides lookup functions for the plan reordering engine.
#
# Language support:
#   Python      — ast.parse() via python3 (zero external deps)
#   JS/TS       — npx madge --json (preferred), grep-based fallback
#   Other       — Empty graph {}, fall back to directory proximity
#
# Staleness: mtime-based + .stale flag from hooks (TaskCompleted/Stop).
# Async build: background subshell, pid file prevents duplicates, .tmp+mv atomic update.
# All functions are defensive (2>/dev/null, || true where appropriate).

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

RALPH_DIR="${RALPH_DIR:-.ralph}"
IMPORT_GRAPH_CACHE="${RALPH_DIR}/.import_graph.json"

# Directories to skip during graph building and staleness checks
_IG_SKIP_DIRS=("node_modules" ".venv" "__pycache__" ".git" ".ralph")

# ---------------------------------------------------------------------------
# import_graph_build_python — AST-based Python import graph builder
#
# Usage: import_graph_build_python <project_root> <cache_file>
#
# Walks all *.py files under project_root (skipping node_modules, .venv,
# __pycache__, .git), parses each with ast.parse(), resolves import/from-import
# statements to relative file paths, and writes { "file": ["dep", ...] } JSON
# to cache_file. Syntax errors and encoding issues are silently skipped.
# ---------------------------------------------------------------------------
import_graph_build_python() {
    local project_root="${1:-.}"
    local cache_file="${2:-$IMPORT_GRAPH_CACHE}"

    mkdir -p "$(dirname "$cache_file")" 2>/dev/null || true

    # TAP-633: pass project_root via env, not heredoc interpolation — a path
    # containing triple quotes (''' …) would otherwise escape the Python
    # string literal and execute arbitrary code during session-start.
    PROJECT_ROOT="$project_root" python3 -c '
import ast, json, os, pathlib, sys

graph = {}
root = pathlib.Path(os.environ["PROJECT_ROOT"]).resolve()
skip = {"node_modules", ".venv", "__pycache__", ".git", ".ralph"}

for f in root.rglob("*.py"):
    # Skip excluded directories
    if any(part in skip for part in f.parts):
        continue
    try:
        tree = ast.parse(f.read_text(encoding="utf-8", errors="ignore"))
        deps = []
        for node in ast.walk(tree):
            if isinstance(node, ast.ImportFrom) and node.module:
                mod_path = node.module.replace(".", "/")
                for ext in [".py", "/__init__.py"]:
                    candidate = root / (mod_path + ext)
                    if candidate.exists():
                        deps.append(str(candidate.relative_to(root)))
                        break
            elif isinstance(node, ast.Import):
                for alias in node.names:
                    mod_path = alias.name.replace(".", "/")
                    for ext in [".py", "/__init__.py"]:
                        candidate = root / (mod_path + ext)
                        if candidate.exists():
                            deps.append(str(candidate.relative_to(root)))
                            break
        rel = str(f.relative_to(root))
        graph[rel] = sorted(set(deps))
    except (SyntaxError, UnicodeDecodeError, OSError):
        pass

json.dump(graph, sys.stdout, indent=2)
' > "$cache_file" 2>/dev/null || echo '{}' > "$cache_file"
}

# ---------------------------------------------------------------------------
# import_graph_build_js — JS/TS graph via madge or grep-based fallback
#
# Usage: import_graph_build_js <project_root> <cache_file>
#
# Prefers `npx madge --json` for accurate resolution (handles aliases, path
# mapping, barrel exports). Falls back to a grep-based Python extractor that
# finds import/require statements and resolves relative paths.
# Skips node_modules in both modes.
# ---------------------------------------------------------------------------
import_graph_build_js() {
    local project_root="${1:-.}"
    local cache_file="${2:-$IMPORT_GRAPH_CACHE}"

    mkdir -p "$(dirname "$cache_file")" 2>/dev/null || true

    # Prefer madge if available (accurate, handles aliases)
    if command -v npx &>/dev/null && [[ -f "$project_root/package.json" ]]; then
        # Determine source directory — prefer src/ if it exists
        local src_dir="$project_root"
        [[ -d "$project_root/src" ]] && src_dir="$project_root/src"

        if npx --yes madge --json "$src_dir" 2>/dev/null > "${cache_file}.madge.tmp"; then
            # Validate JSON output before accepting
            if jq '.' "${cache_file}.madge.tmp" >/dev/null 2>&1; then
                mv "${cache_file}.madge.tmp" "$cache_file"
                return 0
            fi
            rm -f "${cache_file}.madge.tmp" 2>/dev/null
        fi
        rm -f "${cache_file}.madge.tmp" 2>/dev/null
    fi

    # Fallback: grep-based extraction via python3 (less accurate but zero dependencies)
    # TAP-633: pass project_root via env to avoid heredoc injection.
    PROJECT_ROOT="$project_root" python3 -c '
import json, os, re, pathlib, sys

graph = {}
root = pathlib.Path(os.environ["PROJECT_ROOT"]).resolve()
skip = {"node_modules", ".venv", "__pycache__", ".git", ".ralph"}

for ext in ["*.js", "*.jsx", "*.ts", "*.tsx"]:
    for f in root.rglob(ext):
        if any(part in skip for part in f.parts):
            continue
        try:
            content = f.read_text(encoding="utf-8", errors="ignore")
            imports = re.findall(
                r"(?:import\s+.*?from\s+[\x27\x22](.+?)[\x27\x22]|require\([\x27\x22](.+?)[\x27\x22]\))",
                content
            )
            resolved = []
            for m in imports:
                dep = m[0] or m[1]
                if not dep.startswith("."):
                    continue
                candidate = (f.parent / dep).resolve()
                for try_ext in ["", ".ts", ".tsx", ".js", ".jsx", "/index.ts", "/index.js"]:
                    full = pathlib.Path(str(candidate) + try_ext)
                    if full.exists():
                        try:
                            resolved.append(str(full.relative_to(root)))
                        except ValueError:
                            pass
                        break
            graph[str(f.relative_to(root))] = sorted(set(resolved))
        except (UnicodeDecodeError, OSError):
            pass

json.dump(graph, sys.stdout, indent=2)
' > "$cache_file" 2>/dev/null || echo '{}' > "$cache_file"
}

# ---------------------------------------------------------------------------
# import_graph_build — Dispatcher that auto-detects project type
#
# Usage: import_graph_build <project_root> [cache_file]
#
# Detection order:
#   1. If PROJECT_TYPE env var is set, use that directly
#   2. pyproject.toml or setup.py present → python
#   3. package.json present → javascript
#   4. Otherwise → empty graph {}
# ---------------------------------------------------------------------------
import_graph_build() {
    local project_root="${1:-.}"
    local cache_file="${2:-$IMPORT_GRAPH_CACHE}"
    local project_type="${PROJECT_TYPE:-}"

    mkdir -p "$(dirname "$cache_file")" 2>/dev/null || true

    # Auto-detect if not set
    if [[ -z "$project_type" ]]; then
        if [[ -f "$project_root/pyproject.toml" || -f "$project_root/setup.py" || -f "$project_root/setup.cfg" ]]; then
            project_type="python"
        elif [[ -f "$project_root/package.json" || -f "$project_root/tsconfig.json" ]]; then
            project_type="javascript"
        fi
    fi

    case "$project_type" in
        python)
            import_graph_build_python "$project_root" "$cache_file"
            ;;
        javascript|typescript|js|ts)
            import_graph_build_js "$project_root" "$cache_file"
            ;;
        *)
            # Unsupported language — write empty graph
            echo '{}' > "$cache_file"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# import_graph_build_async — Background subprocess build (non-blocking)
#
# Usage: import_graph_build_async <project_root> [cache_file]
#
# Launches import_graph_build in a background subshell. Uses a pid file to
# prevent duplicate concurrent builds. The build writes to a .tmp file and
# atomically moves it into place (no partial reads by consumers).
# The previous cached graph remains available during the build.
# ---------------------------------------------------------------------------
import_graph_build_async() {
    local project_root="${1:-.}"
    local cache_file="${2:-$IMPORT_GRAPH_CACHE}"
    local pid_file="${cache_file}.build.pid"

    mkdir -p "$(dirname "$cache_file")" 2>/dev/null || true

    # Don't start if already building
    if [[ -f "$pid_file" ]]; then
        local existing_pid
        existing_pid=$(cat "$pid_file" 2>/dev/null)
        if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
            return 0  # Build already in progress
        fi
        # Stale pid file — clean up
        rm -f "$pid_file" 2>/dev/null
    fi

    # Launch background build
    (
        import_graph_build "$project_root" "${cache_file}.tmp"
        # Atomic update: only move if the build produced valid JSON
        if [[ -f "${cache_file}.tmp" ]] && jq '.' "${cache_file}.tmp" >/dev/null 2>&1; then
            mv "${cache_file}.tmp" "$cache_file"
        else
            rm -f "${cache_file}.tmp" 2>/dev/null
        fi
        rm -f "$pid_file" 2>/dev/null
    ) &
    echo $! > "$pid_file"
}

# ---------------------------------------------------------------------------
# import_graph_is_stale — Check mtime + .stale flag from hooks
#
# Usage: import_graph_is_stale <project_root> [cache_file]
#
# Returns 0 (true) if graph needs rebuilding:
#   1. Cache file does not exist
#   2. .stale flag file exists (set by import_graph_invalidate_file)
#   3. Any source file is newer than the cache (find -newer -quit)
# Returns 1 (false) if graph is fresh.
# ---------------------------------------------------------------------------
import_graph_is_stale() {
    local project_root="${1:-.}"
    local cache_file="${2:-$IMPORT_GRAPH_CACHE}"

    # No cache = stale
    [[ ! -f "$cache_file" ]] && return 0

    # Stale flag set by incremental invalidation (from hooks)
    if [[ -f "${cache_file}.stale" ]]; then
        rm -f "${cache_file}.stale" 2>/dev/null
        return 0
    fi

    # Find any source file newer than the cache
    local src_dirs=("src" "lib" "app" "pkg" ".")
    for dir in "${src_dirs[@]}"; do
        [[ -d "$project_root/$dir" ]] || continue
        local newer
        newer=$(find "$project_root/$dir" \
            \( -name '*.py' -o -name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.jsx' \) \
            -newer "$cache_file" \
            ! -path '*/node_modules/*' \
            ! -path '*/.venv/*' \
            ! -path '*/__pycache__/*' \
            ! -path '*/.git/*' \
            ! -path '*/.ralph/*' \
            -print -quit 2>/dev/null)
        [[ -n "$newer" ]] && return 0  # Stale
    done

    return 1  # Fresh
}

# ---------------------------------------------------------------------------
# import_graph_ensure — Build if stale, skip if fresh
#
# Usage: import_graph_ensure <project_root> [cache_file]
#
# Convenience wrapper: checks staleness and rebuilds synchronously if needed.
# For non-blocking builds, use import_graph_build_async directly.
# ---------------------------------------------------------------------------
import_graph_ensure() {
    local project_root="${1:-.}"
    local cache_file="${2:-$IMPORT_GRAPH_CACHE}"

    if import_graph_is_stale "$project_root" "$cache_file"; then
        import_graph_build "$project_root" "$cache_file"
    fi
}

# ---------------------------------------------------------------------------
# import_graph_invalidate_file — Remove single entry + touch .stale flag
#
# Usage: import_graph_invalidate_file <file_path> [cache_file]
#
# Called from TaskCompleted/Stop hooks when a file is modified. Removes
# that file's entry from the graph (its imports may have changed) and
# touches the .stale flag so the next session knows to rebuild fully.
# ---------------------------------------------------------------------------
import_graph_invalidate_file() {
    local file_path="$1"
    local cache_file="${2:-$IMPORT_GRAPH_CACHE}"

    [[ -z "$file_path" ]] && return 0

    if [[ -f "$cache_file" ]]; then
        # Remove the file's entry (its imports may have changed)
        local tmp="${cache_file}.inv.tmp"
        if jq --arg f "$file_path" 'del(.[$f])' "$cache_file" > "$tmp" 2>/dev/null; then
            mv "$tmp" "$cache_file"
        else
            rm -f "$tmp" 2>/dev/null
        fi
        # Touch a stale flag so next session knows to rebuild
        touch "${cache_file}.stale" 2>/dev/null || true
    fi
}

# ---------------------------------------------------------------------------
# import_graph_lookup — Does file A depend on file B?
#
# Usage: import_graph_lookup <file_a> <file_b> [cache_file]
#
# Returns 0 (true) if file_a's import list contains file_b.
# Returns 1 (false) otherwise or if the cache is missing/invalid.
# ---------------------------------------------------------------------------
import_graph_lookup() {
    local file_a="$1"
    local file_b="$2"
    local cache_file="${3:-$IMPORT_GRAPH_CACHE}"

    [[ -z "$file_a" || -z "$file_b" ]] && return 1
    [[ ! -f "$cache_file" ]] && return 1

    jq -e --arg a "$file_a" --arg b "$file_b" \
        '.[$a] // [] | index($b) != null' "$cache_file" 2>/dev/null
}

# ---------------------------------------------------------------------------
# import_graph_dependents — What files depend on file A?
#
# Usage: import_graph_dependents <target_file> [cache_file]
#
# Prints one file path per line for every file whose import list contains
# target_file. Returns nothing (empty output) if no dependents found.
# ---------------------------------------------------------------------------
import_graph_dependents() {
    local target="$1"
    local cache_file="${2:-$IMPORT_GRAPH_CACHE}"

    [[ -z "$target" ]] && return 0
    [[ ! -f "$cache_file" ]] && return 0

    jq -r --arg t "$target" \
        'to_entries[] | select(.value // [] | index($t) != null) | .key' \
        "$cache_file" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Exports
# ---------------------------------------------------------------------------

export -f import_graph_build_python
export -f import_graph_build_js
export -f import_graph_build
export -f import_graph_build_async
export -f import_graph_is_stale
export -f import_graph_ensure
export -f import_graph_invalidate_file
export -f import_graph_lookup
export -f import_graph_dependents
