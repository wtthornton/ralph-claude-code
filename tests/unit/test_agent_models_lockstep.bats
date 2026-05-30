#!/usr/bin/env bats
# Master drift guard: agent-models.json IS the single source of truth for
# .claude/agents/*.md model: fields. Replaces the per-agent hard-coded model
# strings that previously lived in test_agent_contract_tap646.bats (TAP-646 A)
# and test_subagent_brief_consumption.bats (TAP-916 test 14). Those two tests
# still exist but now delegate to the manifest so a model bump touches exactly
# one file (agent-models.json) plus the agent files via apply-agent-models.sh.
#
# Three contracts:
#   1. agent-models.json is valid JSON with a .lineup object.
#   2. Every manifest entry has a matching .claude/agents/<name>.md whose
#      `model:` line equals the manifest value (catches "I edited the
#      manifest but forgot to run apply-agent-models.sh").
#   3. Every .claude/agents/<name>.md is declared in the manifest (catches
#      "I added a new agent file but forgot to register it in the manifest").

bats_require_minimum_version 1.5.0
load '../helpers/test_helper'

ROOT="${BATS_TEST_DIRNAME}/../.."
MANIFEST="$ROOT/agent-models.json"
AGENTS_DIR="$ROOT/.claude/agents"

@test "agent-models: manifest is valid JSON with a .lineup object" {
    jq -e '.lineup | type == "object"' "$MANIFEST" >/dev/null \
        || fail "agent-models.json must be valid JSON with a .lineup object"
}

@test "agent-models: every manifest entry matches its agent file model: line" {
    local agent expected actual expected_t actual_t
    local missing=0 mismatch=0
    while IFS=$'\t' read -r agent expected; do
        [[ -z "$agent" ]] && continue
        local file="$AGENTS_DIR/${agent}.md"
        if [[ ! -f "$file" ]]; then
            echo "MISSING: manifest entry '$agent' has no $file" >&2
            missing=1
            continue
        fi
        actual=$(grep -E '^model:' "$file" | head -1 | sed -E 's/^model:[[:space:]]*//')
        actual_t=$(echo "$actual" | tr -d '[:space:]')
        expected_t=$(echo "$expected" | tr -d '[:space:]')
        if [[ "$actual_t" != "$expected_t" ]]; then
            echo "MISMATCH: $agent  manifest='$expected'  file='$actual'" >&2
            mismatch=1
        fi
    done < <(jq -r '.lineup | to_entries[] | "\(.key)\t\(.value)"' "$MANIFEST")
    [[ "$missing" -eq 0 && "$mismatch" -eq 0 ]] \
        || fail "manifest ↔ agent files drift — run scripts/apply-agent-models.sh"
}

@test "agent-models: every .claude/agents/<name>.md is declared in the manifest" {
    local file basename in_manifest orphan=0
    for file in "$AGENTS_DIR"/*.md; do
        [[ -f "$file" ]] || continue
        basename=$(basename "$file" .md)
        in_manifest=$(jq -r --arg k "$basename" '.lineup | has($k)' "$MANIFEST")
        if [[ "$in_manifest" != "true" ]]; then
            echo "ORPHAN: $file has no manifest entry" >&2
            orphan=1
        fi
    done
    [[ "$orphan" -eq 0 ]] \
        || fail "agent files exist without manifest entries — add them to agent-models.json"
}

@test "agent-models: apply-agent-models.sh exists, is executable, and dry-runs cleanly" {
    local script="$ROOT/scripts/apply-agent-models.sh"
    [[ -x "$script" ]] || fail "$script must exist and be executable"
    run bash "$script" --dry-run
    [[ "$status" -eq 0 ]] \
        || fail "apply-agent-models.sh --dry-run failed (exit $status): $output"
    # If the manifest is in sync with the files, the dry-run reports "0 agents would change".
    [[ "$output" == *"0 agents would change"* ]] \
        || fail "apply-agent-models.sh dry-run reported drift — run the script to fix: $output"
}
