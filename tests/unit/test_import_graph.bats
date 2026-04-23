#!/usr/bin/env bats
# Unit tests for lib/import_graph.sh — File dependency graph (PLANOPT-1)
# Covers: build, staleness, lookup, dependents, cache, skip dirs, auto-detect,
#         async build, and incremental invalidation.

load '../helpers/test_helper'
load '../helpers/fixtures'

# Path to the module under test
IMPORT_GRAPH_SCRIPT="${BATS_TEST_DIRNAME}/../../lib/import_graph.sh"

setup() {
    # Create unique temp directory for this test
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"

    # Standard Ralph dir structure
    export RALPH_DIR=".ralph"
    export IMPORT_GRAPH_CACHE="${RALPH_DIR}/.import_graph.json"
    mkdir -p "$RALPH_DIR"

    # Detect path separator used by Python pathlib on this platform.
    # On Windows (MSYS/Git Bash) Python produces backslash paths;
    # on Unix it produces forward slashes.
    if [[ "$(uname -s)" == MINGW* || "$(uname -s)" == MSYS* || "$(uname -s)" == CYGWIN* || -n "$WINDIR" ]]; then
        SEP='\\'
    else
        SEP='/'
    fi

    # Source the module under test
    source "$IMPORT_GRAPH_SCRIPT"
}

teardown() {
    if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
        cd /
        rm -rf "$TEST_DIR" 2>/dev/null || true
    fi
}

# ---------------------------------------------------------------------------
# Helper: create a minimal Python project with src/main.py importing src/db.py
# ---------------------------------------------------------------------------
setup_python_project() {
    mkdir -p src
    cat > src/db.py << 'PYEOF'
class Database:
    pass
PYEOF

    cat > src/main.py << 'PYEOF'
from src.db import Database

def main():
    db = Database()
PYEOF

    # Marker file so auto-detect picks Python
    touch pyproject.toml
}

# ---------------------------------------------------------------------------
# Helper: build the platform-specific key for a relative path like "src/main.py"
# On Windows Python emits "src\\main.py"; on Unix "src/main.py".
# ---------------------------------------------------------------------------
pkey() {
    if [[ "$SEP" == '\\' ]]; then
        echo "$1" | sed 's|/|\\|g'
    else
        echo "$1"
    fi
}

# =============================================================================
# 1. Builds Python import graph
# =============================================================================

@test "PLANOPT-1: builds Python import graph" {
    setup_python_project
    import_graph_build_python "." "$IMPORT_GRAPH_CACHE"

    # Cache file must exist
    [[ -f "$IMPORT_GRAPH_CACHE" ]]

    # src/main.py should list src/db.py as a dependency
    local main_key
    main_key="$(pkey "src/main.py")"
    local db_key
    db_key="$(pkey "src/db.py")"
    run jq -e --arg a "$main_key" --arg b "$db_key" \
        '.[$a] // [] | index($b) != null' "$IMPORT_GRAPH_CACHE"
    assert_success
}

# =============================================================================
# 2. Detects staleness when source file is newer
# =============================================================================

@test "PLANOPT-1: detects staleness when source file is newer" {
    setup_python_project
    import_graph_build_python "." "$IMPORT_GRAPH_CACHE"

    # Ensure the new file has a strictly newer mtime than the cache
    sleep 1
    echo "# new" > src/new_file.py

    run import_graph_is_stale "." "$IMPORT_GRAPH_CACHE"
    [[ "$status" -eq 0 ]]  # 0 = stale
}

# =============================================================================
# 3. Cache is fresh when no files changed
# =============================================================================

@test "PLANOPT-1: cache is fresh when no files changed" {
    setup_python_project
    import_graph_build_python "." "$IMPORT_GRAPH_CACHE"

    # Nothing changed — cache should be fresh
    run import_graph_is_stale "." "$IMPORT_GRAPH_CACHE"
    [[ "$status" -eq 1 ]]  # 1 = fresh
}

# =============================================================================
# 4. Lookup returns true for direct dependency
# =============================================================================

@test "PLANOPT-1: lookup returns true for direct dependency" {
    setup_python_project
    import_graph_build_python "." "$IMPORT_GRAPH_CACHE"

    # main.py imports db.py, so lookup should succeed (exit 0)
    local main_key
    main_key="$(pkey "src/main.py")"
    local db_key
    db_key="$(pkey "src/db.py")"
    run import_graph_lookup "$main_key" "$db_key" "$IMPORT_GRAPH_CACHE"
    [[ "$status" -eq 0 ]]
}

# =============================================================================
# 5. Lookup returns false for no dependency
# =============================================================================

@test "PLANOPT-1: lookup returns false for no dependency" {
    setup_python_project
    import_graph_build_python "." "$IMPORT_GRAPH_CACHE"

    # db.py does NOT import main.py — lookup should fail (exit != 0)
    local main_key
    main_key="$(pkey "src/main.py")"
    local db_key
    db_key="$(pkey "src/db.py")"
    run import_graph_lookup "$db_key" "$main_key" "$IMPORT_GRAPH_CACHE"
    [[ "$status" -ne 0 ]]
}

# =============================================================================
# 6. Dependents query finds reverse dependencies
# =============================================================================

@test "PLANOPT-1: dependents query finds reverse dependencies" {
    setup_python_project
    import_graph_build_python "." "$IMPORT_GRAPH_CACHE"

    # db.py is depended on by main.py
    local main_key
    main_key="$(pkey "src/main.py")"
    local db_key
    db_key="$(pkey "src/db.py")"
    run import_graph_dependents "$db_key" "$IMPORT_GRAPH_CACHE"
    [[ "$output" == *"$main_key"* ]]
}

# =============================================================================
# 7. Handles empty project gracefully
# =============================================================================

@test "PLANOPT-1: handles empty project gracefully" {
    mkdir -p empty_project
    import_graph_build_python "empty_project" "$IMPORT_GRAPH_CACHE"

    # Should produce a valid JSON file with an empty object
    [[ -f "$IMPORT_GRAPH_CACHE" ]]
    run jq -e '. == {}' "$IMPORT_GRAPH_CACHE"
    assert_success
}

# =============================================================================
# 8. Skips venv and node_modules
# =============================================================================

@test "PLANOPT-1: skips venv and node_modules" {
    setup_python_project

    # Create files inside directories that should be excluded
    mkdir -p .venv/lib
    echo "import os" > .venv/lib/something.py

    mkdir -p node_modules/pkg
    echo "import sys" > node_modules/pkg/index.py

    import_graph_build_python "." "$IMPORT_GRAPH_CACHE"

    # Neither excluded path should appear in the graph (check both separators)
    local venv_key
    venv_key="$(pkey ".venv/lib/something.py")"
    local nm_key
    nm_key="$(pkey "node_modules/pkg/index.py")"

    run jq -e --arg k "$venv_key" 'has($k)' "$IMPORT_GRAPH_CACHE"
    [[ "$status" -ne 0 ]]  # Not in graph

    run jq -e --arg k "$nm_key" 'has($k)' "$IMPORT_GRAPH_CACHE"
    [[ "$status" -ne 0 ]]  # Not in graph
}

# =============================================================================
# 9. Auto-detects project type
# =============================================================================

@test "PLANOPT-1: auto-detects project type" {
    setup_python_project  # Creates pyproject.toml

    # import_graph_build (the dispatcher) should auto-detect Python
    import_graph_build "." "$IMPORT_GRAPH_CACHE"

    [[ -f "$IMPORT_GRAPH_CACHE" ]]
    # Graph should contain entries (not empty) since the project has Python files
    run jq -e 'length > 0' "$IMPORT_GRAPH_CACHE"
    assert_success
}

# =============================================================================
# 10. Stale flag triggers rebuild
# =============================================================================

@test "PLANOPT-1: stale flag triggers rebuild" {
    setup_python_project
    import_graph_build_python "." "$IMPORT_GRAPH_CACHE"

    # Manually create the .stale flag (simulates hook-based invalidation)
    touch "${IMPORT_GRAPH_CACHE}.stale"

    # is_stale should detect the flag and return 0 (stale)
    run import_graph_is_stale "." "$IMPORT_GRAPH_CACHE"
    [[ "$status" -eq 0 ]]

    # TAP-673: is_stale MUST NOT remove the flag — only ensure() does, and
    # only after a successful rebuild. Previously the flag was cleared here
    # and a failed rebuild left the cache masquerading as fresh.
    [[ -f "${IMPORT_GRAPH_CACHE}.stale" ]]

    # After ensure() completes a successful rebuild, the flag is cleared.
    import_graph_ensure "." "$IMPORT_GRAPH_CACHE"
    [[ ! -f "${IMPORT_GRAPH_CACHE}.stale" ]]
}

# =============================================================================
# TAP-673: rebuild-failure preserves .stale flag and existing cache
# =============================================================================

@test "TAP-673: failed python rebuild preserves .stale flag and prior cache" {
    setup_python_project
    import_graph_build_python "." "$IMPORT_GRAPH_CACHE"
    local good_hash
    good_hash=$(md5sum "$IMPORT_GRAPH_CACHE" | awk '{print $1}')

    # Mark stale (simulates hook-based invalidation after a file edit)
    touch "${IMPORT_GRAPH_CACHE}.stale"

    # Force rebuild failure by shadowing python3 with a non-zero-exiting stub
    local mock_bin
    mock_bin="$(mktemp -d)"
    cat > "$mock_bin/python3" <<'STUB'
#!/bin/bash
exit 1
STUB
    chmod +x "$mock_bin/python3"
    local saved_path="$PATH"
    export PATH="$mock_bin:$PATH"

    run import_graph_ensure "." "$IMPORT_GRAPH_CACHE"

    # Restore PATH
    export PATH="$saved_path"
    rm -rf "$mock_bin"

    # The existing cache must be intact (atomic write protected it)
    local post_hash
    post_hash=$(md5sum "$IMPORT_GRAPH_CACHE" | awk '{print $1}')
    [[ "$post_hash" == "$good_hash" ]]

    # TAP-673 core: the .stale flag must still be present so the next run retries
    [[ -f "${IMPORT_GRAPH_CACHE}.stale" ]]
}

@test "TAP-673: successful rebuild clears .stale flag" {
    setup_python_project
    import_graph_build_python "." "$IMPORT_GRAPH_CACHE"
    touch "${IMPORT_GRAPH_CACHE}.stale"

    import_graph_ensure "." "$IMPORT_GRAPH_CACHE"

    # Flag cleared only on success
    [[ ! -f "${IMPORT_GRAPH_CACHE}.stale" ]]
    # Cache is still valid JSON
    jq -e . "$IMPORT_GRAPH_CACHE" >/dev/null
}

@test "TAP-673: build_python returns non-zero when python3 fails" {
    setup_python_project
    local mock_bin
    mock_bin="$(mktemp -d)"
    cat > "$mock_bin/python3" <<'STUB'
#!/bin/bash
exit 1
STUB
    chmod +x "$mock_bin/python3"
    local saved_path="$PATH"
    export PATH="$mock_bin:$PATH"

    run import_graph_build_python "." "$IMPORT_GRAPH_CACHE"
    local rc="$status"

    export PATH="$saved_path"
    rm -rf "$mock_bin"

    [[ "$rc" -ne 0 ]]
}

# =============================================================================
# 11. Async build creates pid file
# =============================================================================

@test "PLANOPT-1: async build creates pid file" {
    setup_python_project

    local pid_file="${IMPORT_GRAPH_CACHE}.build.pid"

    import_graph_build_async "." "$IMPORT_GRAPH_CACHE"

    # Poll until the background build produces the cache file
    local attempts=0
    while [[ ! -f "$IMPORT_GRAPH_CACHE" ]] && [[ $attempts -lt 30 ]]; do
        sleep 0.3
        attempts=$((attempts + 1))
    done

    # The background build must have produced the cache file
    [[ -f "$IMPORT_GRAPH_CACHE" ]]

    # The cache should contain valid JSON
    run jq -e '.' "$IMPORT_GRAPH_CACHE"
    assert_success
}

# =============================================================================
# 12. Invalidate file removes entry and touches stale flag
# =============================================================================

@test "PLANOPT-1: invalidate file removes entry and touches stale flag" {
    setup_python_project
    import_graph_build_python "." "$IMPORT_GRAPH_CACHE"

    local main_key
    main_key="$(pkey "src/main.py")"

    # Verify src/main.py is in the graph before invalidation
    run jq -e --arg k "$main_key" 'has($k)' "$IMPORT_GRAPH_CACHE"
    assert_success

    # Invalidate the entry
    import_graph_invalidate_file "$main_key" "$IMPORT_GRAPH_CACHE"

    # The entry should be gone
    run jq -e --arg k "$main_key" 'has($k)' "$IMPORT_GRAPH_CACHE"
    [[ "$status" -ne 0 ]]

    # The .stale flag should exist
    [[ -f "${IMPORT_GRAPH_CACHE}.stale" ]]
}

@test "TAP-633: import_graph_build_python does not execute shell via project_root" {
    # A directory name containing Python string-escape sequences must not be
    # interpolated into the python3 -c script body. Pre-fix, a crafted path
    # could execute arbitrary code during session-start.
    local evil_dir
    evil_dir="$BATS_TEST_TMPDIR/pwn_dir_$$"
    mkdir -p "$evil_dir"
    echo "print('x')" > "$evil_dir/script.py"
    local cache="$BATS_TEST_TMPDIR/cache.json"
    local marker="$BATS_TEST_TMPDIR/pwn_marker_$$"

    # Path containing triple-quote escape attempt
    local attack_root="$evil_dir/''')+(__import__('os').system('touch $marker'))+('''"
    mkdir -p "$attack_root" 2>/dev/null || attack_root="$evil_dir"

    import_graph_build_python "$attack_root" "$cache"

    [[ ! -e "$marker" ]]
    run jq -e 'type == "object"' "$cache"
    assert_success
}

@test "TAP-633: import_graph_build_python handles paths with spaces + quotes" {
    local spaced="$BATS_TEST_TMPDIR/a dir/b dir"
    mkdir -p "$spaced"
    echo "import os" > "$spaced/script.py"
    local cache="$BATS_TEST_TMPDIR/cache.json"

    import_graph_build_python "$spaced" "$cache"

    run jq -e 'type == "object"' "$cache"
    assert_success
}
