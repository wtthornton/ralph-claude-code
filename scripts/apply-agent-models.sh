#!/usr/bin/env bash
# apply-agent-models.sh — Propagate agent-models.json to .claude/agents/*.md
#
# Reads the canonical model lineup from <repo>/agent-models.json and patches
# the `model:` field of each declared .claude/agents/<name>.md to match.
#
# Run from an OPERATOR terminal OUTSIDE Claude Code. The repo's
# protect-ralph-files.sh PreToolUse hook hard-blocks all .claude/ writes from
# any Claude Code session (interactive or autonomous) — by design, so the
# agent cannot rewrite its own configuration. See docs/OPERATOR-EDITS.md.
#
# Exit codes:
#   0  all manifest entries applied (or already in sync)
#   1  manifest missing / invalid / jq missing
#   2  one or more manifest entries reference an agent file that does not exist
#
# Usage:
#   bash scripts/apply-agent-models.sh [--dry-run]
#
# --dry-run prints what would change without modifying any file.

set -euo pipefail

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
fi

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$ROOT/agent-models.json"
AGENTS_DIR="$ROOT/.claude/agents"

if [[ ! -f "$MANIFEST" ]]; then
    echo "FATAL: $MANIFEST not found" >&2
    exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "FATAL: jq required (install: apt-get install jq | brew install jq)" >&2
    exit 1
fi
if ! jq -e '.lineup | type == "object"' "$MANIFEST" >/dev/null 2>&1; then
    echo "FATAL: $MANIFEST is missing a .lineup object" >&2
    exit 1
fi

declare -i changed=0 unchanged=0 missing=0
while IFS=$'\t' read -r agent expected; do
    [[ -z "$agent" ]] && continue
    file="$AGENTS_DIR/${agent}.md"
    if [[ ! -f "$file" ]]; then
        printf 'WARN: %s declared in manifest but %s missing\n' "$agent" "$file" >&2
        missing+=1
        continue
    fi
    current=$(grep -E '^model:' "$file" | head -1 | sed -E 's/^model:[[:space:]]*//')
    if [[ "$current" == "$expected" ]]; then
        unchanged+=1
        continue
    fi
    if [[ "$DRY_RUN" == "true" ]]; then
        printf '[dry-run] would update %s: %s -> %s\n' "$file" "$current" "$expected"
    else
        # Portable in-place rewrite via awk + atomic mv. macOS/BSD sed differs
        # from GNU sed on -i; awk avoids the divergence.
        tmp="${file}.tmp.$$"
        awk -v line="model: $expected" '
            !done && /^model:/ { print line; done=1; next }
            { print }
        ' "$file" > "$tmp" && mv "$tmp" "$file"
        printf 'updated: %s  %s -> %s\n' "$file" "$current" "$expected"
    fi
    changed+=1
done < <(jq -r '.lineup | to_entries[] | "\(.key)\t\(.value)"' "$MANIFEST")

if [[ "$DRY_RUN" == "true" ]]; then
    printf 'dry-run summary: %d agents would change, %d already in sync, %d missing\n' \
        "$changed" "$unchanged" "$missing"
else
    printf 'done: %d agents updated, %d already in sync, %d missing\n' \
        "$changed" "$unchanged" "$missing"
fi

[[ "$missing" -eq 0 ]] || exit 2
exit 0
