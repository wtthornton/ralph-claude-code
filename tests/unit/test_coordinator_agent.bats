#!/usr/bin/env bats
# TAP-913: ralph-coordinator agent definition contract.
# Asserts the frontmatter and body of .claude/agents/ralph-coordinator.md
# meet the spec — Sonnet model, narrow tool surface, no shell/edit/Task,
# brain_* tools wired, body references .ralph/brief.json.

bats_require_minimum_version 1.5.0
load '../helpers/test_helper'

AGENT_FILE="${BATS_TEST_DIRNAME}/../../.claude/agents/ralph-coordinator.md"

# Extract YAML frontmatter (between first two `---` lines) into stdout.
extract_frontmatter() {
    local file="$1"
    awk '
        BEGIN { in_fm = 0; started = 0 }
        /^---[[:space:]]*$/ {
            if (!started) { started = 1; in_fm = 1; next }
            else if (in_fm) { exit }
        }
        in_fm { print }
    ' "$file"
}

# Extract a top-level YAML block (e.g. `tools:` or `disallowedTools:`) —
# everything from the matching key line up to the next non-indented line.
extract_yaml_block() {
    local file="$1" key="$2"
    awk -v k="$key" '
        BEGIN { in_block = 0 }
        $0 ~ "^"k":" { in_block = 1; print; next }
        in_block && /^[^[:space:]-]/ { exit }
        in_block { print }
    ' "$file"
}

setup() {
    # No tmpdir setup needed — this test only reads a checked-in file.
    :
}

@test "TAP-913: agent file exists" {
    [[ -f "$AGENT_FILE" ]] || fail "missing $AGENT_FILE"
}

@test "TAP-913: frontmatter parses (has open and close ---)" {
    local count
    count=$(grep -c '^---$' "$AGENT_FILE")
    [[ "$count" -ge 2 ]] || fail "expected >=2 '---' lines, got $count"
}

@test "TAP-913: name is ralph-coordinator" {
    local fm
    fm=$(extract_frontmatter "$AGENT_FILE")
    echo "$fm" | grep -qE '^name:[[:space:]]+ralph-coordinator[[:space:]]*$' \
        || fail "expected 'name: ralph-coordinator' in frontmatter"
}

@test "TAP-913: model is sonnet" {
    local fm
    fm=$(extract_frontmatter "$AGENT_FILE")
    echo "$fm" | grep -qE '^model:[[:space:]]+sonnet[[:space:]]*$' \
        || fail "expected 'model: sonnet' in frontmatter"
}

@test "TAP-913: tools list contains all 4 brain_* tools" {
    local block
    block=$(extract_yaml_block "$AGENT_FILE" "tools")
    for t in brain_recall brain_remember brain_learn_success brain_learn_failure; do
        echo "$block" | grep -qE "mcp__tapps-brain__${t}\\b" \
            || fail "tools list missing mcp__tapps-brain__${t}"
    done
}

@test "TAP-913: tools list has exactly 4 mcp__tapps-brain__ entries" {
    local block count
    block=$(extract_yaml_block "$AGENT_FILE" "tools")
    count=$(echo "$block" | grep -cE 'mcp__tapps-brain__' || true)
    [[ "$count" -eq 4 ]] || fail "expected exactly 4 brain tools in tools list, got $count"
}

@test "TAP-913: tools list does NOT include Bash/Edit/Task/WebFetch" {
    local block
    block=$(extract_yaml_block "$AGENT_FILE" "tools")
    for forbidden in Bash Edit Task WebFetch; do
        # Match standalone tool entry: '- Bash' (with optional whitespace),
        # not 'Bash(...)' patterns inside disallowedTools.
        if echo "$block" | grep -qE "^[[:space:]]*-[[:space:]]+${forbidden}[[:space:]]*$"; then
            fail "tools list contains forbidden entry: $forbidden"
        fi
    done
}

@test "TAP-913: disallowedTools is present and non-empty" {
    local block entries
    block=$(extract_yaml_block "$AGENT_FILE" "disallowedTools")
    [[ -n "$block" ]] || fail "missing disallowedTools section"
    entries=$(echo "$block" | grep -cE '^[[:space:]]*-[[:space:]]' || true)
    [[ "$entries" -ge 1 ]] || fail "disallowedTools must have >=1 entry, got $entries"
}

@test "TAP-913: body mentions .ralph/brief.json as write target" {
    grep -q '\.ralph/brief\.json' "$AGENT_FILE" \
        || fail "body must reference .ralph/brief.json"
}

@test "TAP-913: body has execution contract section" {
    grep -qE '^##[[:space:]]+Execution[[:space:]]+Contract' "$AGENT_FILE" \
        || fail "body must have '## Execution Contract' heading"
}

@test "TAP-913: body documents both MODE=brief and MODE=debrief" {
    grep -q 'MODE=brief' "$AGENT_FILE" || fail "body must reference MODE=brief"
    grep -q 'MODE=debrief' "$AGENT_FILE" || fail "body must reference MODE=debrief"
}

# Coordinator-driven Linear locality hint — the OAuth-via-MCP equivalent of
# the bash-side linear_optimizer (which is a no-op when LINEAR_API_KEY is
# unset). The coordinator's MODE=brief step 4 fills the same role.
@test "coordinator-locality: tools list includes Linear MCP list_issues" {
    local block
    block=$(extract_yaml_block "$AGENT_FILE" "tools")
    echo "$block" | grep -qE 'mcp__plugin_linear_linear__list_issues\b' \
        || fail "tools list must include mcp__plugin_linear_linear__list_issues for locality scoring"
}

@test "coordinator-locality: body documents the .linear_next_issue write" {
    grep -q '\.ralph/\.linear_next_issue\|\.linear_next_issue' "$AGENT_FILE" \
        || fail "body must reference .ralph/.linear_next_issue as the locality hint target"
}

@test "coordinator-locality: body references .last_completed_files as set A source" {
    grep -q '\.last_completed_files' "$AGENT_FILE" \
        || fail "body must reference .ralph/.last_completed_files as the locality-scoring input"
}

@test "coordinator-locality: locality step gated on task_source=linear" {
    # Step 4 must declare the linear gate so a file-mode project's
    # coordinator does not waste an MCP call. Match the explicit gate
    # phrasing, not the unrelated `"task_source": "linear"` JSON snippet
    # that appears in the brief.json schema example.
    grep -qE 'task_source[[:space:]]*!=[[:space:]]*"?linear|Linear mode only' "$AGENT_FILE" \
        || fail "locality step must declare the task_source=linear gate"
}

@test "coordinator-locality: locality step explicitly best-effort (does not trip brief regression)" {
    # Defense against future drift that would make the locality write a
    # hard requirement — only brief.json is required, per the existing
    # 'coordinator: brief missing or invalid' detector contract.
    grep -qiE 'best-effort|valid skip conditions' "$AGENT_FILE" \
        || fail "locality step must be marked best-effort so its failure does not trip the brief detector"
}
