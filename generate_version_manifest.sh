#!/bin/bash
# generate_version_manifest.sh — Build-time version manifest generator
#
# Reads versions from their canonical sources and writes a single
# version.json file that all components can query at runtime.
#
# Usage:
#   ./generate_version_manifest.sh [--output PATH]
#
# Sources:
#   - ralph_loop.sh   → RALPH_VERSION (loop version)
#   - sdk/pyproject.toml → version (SDK version)
#   - package.json    → version (npm/CLI version, should match loop)
#
# The output file is designed to be:
#   1. Baked into Docker images at build time
#   2. Read by the SDK via ralph_sdk.versions.get_versions()
#   3. Served by TheStudio health/version endpoints
#   4. Checked by smoke tests for consistency

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT="${1:-${SCRIPT_DIR}/version.json}"

# Parse --output flag
if [[ "${1:-}" == "--output" ]]; then
    OUTPUT="${2:?--output requires a path}"
fi

# --- Extract versions from canonical sources ---

# Ralph loop version (from ralph_loop.sh RALPH_VERSION="X.Y.Z")
ralph_loop_version=""
if [[ -f "$SCRIPT_DIR/ralph_loop.sh" ]]; then
    ralph_loop_version=$(grep -m1 '^RALPH_VERSION=' "$SCRIPT_DIR/ralph_loop.sh" \
        | sed 's/RALPH_VERSION="\{0,1\}\([^"]*\)"\{0,1\}/\1/' \
        | tr -d '\r\n[:space:]')
fi

# SDK version (from pyproject.toml version = "X.Y.Z")
sdk_version=""
if [[ -f "$SCRIPT_DIR/sdk/pyproject.toml" ]]; then
    sdk_version=$(grep -m1 '^version' "$SCRIPT_DIR/sdk/pyproject.toml" \
        | sed 's/version *= *"\([^"]*\)"/\1/' \
        | tr -d '\r\n[:space:]')
fi

# npm/CLI version (from package.json — should match loop version)
cli_version=""
if [[ -f "$SCRIPT_DIR/package.json" ]] && command -v jq &>/dev/null; then
    cli_version=$(jq -r '.version' "$SCRIPT_DIR/package.json" 2>/dev/null)
elif [[ -f "$SCRIPT_DIR/package.json" ]]; then
    cli_version=$(grep -m1 '"version"' "$SCRIPT_DIR/package.json" \
        | sed 's/.*"version": *"\([^"]*\)".*/\1/' \
        | tr -d '\r\n[:space:]')
fi

# Git SHA (short, if available)
git_sha=""
if command -v git &>/dev/null && git -C "$SCRIPT_DIR" rev-parse --git-dir &>/dev/null 2>&1; then
    git_sha=$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || echo "")
fi

# Build timestamp (UTC ISO 8601)
build_time=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "unknown")

# --- Warn on version mismatch ---
if [[ -n "$ralph_loop_version" && -n "$cli_version" && "$ralph_loop_version" != "$cli_version" ]]; then
    echo "WARNING: Version mismatch — ralph_loop.sh=$ralph_loop_version, package.json=$cli_version" >&2
fi

# --- Write manifest ---
if command -v jq &>/dev/null; then
    jq -n \
        --arg ralph "$ralph_loop_version" \
        --arg sdk "$sdk_version" \
        --arg cli "$cli_version" \
        --arg sha "$git_sha" \
        --arg build "$build_time" \
        '{
            ralph_loop: $ralph,
            ralph_sdk: $sdk,
            ralph_cli: $cli,
            git_sha: $sha,
            build_time: $build
        }' > "$OUTPUT"
else
    # Fallback: manual JSON construction (no jq dependency)
    cat > "$OUTPUT" << EOF
{
  "ralph_loop": "${ralph_loop_version}",
  "ralph_sdk": "${sdk_version}",
  "ralph_cli": "${cli_version}",
  "git_sha": "${git_sha}",
  "build_time": "${build_time}"
}
EOF
fi

echo "Version manifest written to $OUTPUT"
