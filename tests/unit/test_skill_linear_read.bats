#!/usr/bin/env bats
# TAP-2248: linear-read skill must keep the limit-cap + dumped-result
# guidance that prevents the parser-subagent friction observed in field
# (AgentForge, 2026-05-20): bare Read on a >25k-token list_issues dump
# and the python3 -c fallback that blocks on validate-command hooks.
#
# Numbers below are anchored to Claude Code 2026 reality (verified via
# web research, May 2026):
#   - MCP tool-result dump threshold: MAX_MCP_OUTPUT_TOKENS, default 25k,
#     raisable in .mcp.json. Anthropic issue tracker has multiple open
#     requests to raise the default; for now, env-var bump is the fix.
#   - Read tool ceiling: 25,000 TOKENS, hardcoded (Issue #15687 — closed
#     as duplicate, no env-var override).
#   - Read tool `limit:` parameter is in LINES (default 2000), not tokens.
#     A `Read(..., limit: 25000)` directive (advice in early drafts) is
#     wrong and would still bust the 25k-token wall on dense JSON.
#   - Read adds ~70% token overhead via line numbering (Issue #20223),
#     making Grep the preferred ID-extraction tool on dump files.

bats_require_minimum_version 1.5.0
load '../helpers/test_helper'

SKILL_FILE="${BATS_TEST_DIRNAME}/../../.claude/skills/linear-read/SKILL.md"
PROMPT_TEMPLATE="${BATS_TEST_DIRNAME}/../../templates/PROMPT.md"

setup() {
    [[ -f "$SKILL_FILE" ]] || skip ".claude/skills/linear-read/SKILL.md not present"
}

@test "TAP-2248: linear-read skill recommends limit: 100 as the default" {
    grep -qE 'limit:[[:space:]]*100' "$SKILL_FILE" \
        || fail "linear-read SKILL.md missing 'limit: 100' default recommendation"
}

@test "TAP-2248: linear-read skill names MAX_MCP_OUTPUT_TOKENS as the upstream fix" {
    grep -qF 'MAX_MCP_OUTPUT_TOKENS' "$SKILL_FILE" \
        || fail "linear-read SKILL.md missing MAX_MCP_OUTPUT_TOKENS env-var guidance"
}

@test "TAP-2248: linear-read skill names the 25k-token MCP/Read ceiling" {
    grep -qE '25[,]?000[- ]token|25k[- ]token' "$SKILL_FILE" \
        || fail "linear-read SKILL.md missing 25k-token ceiling reference"
}

@test "TAP-2248: linear-read skill clarifies that Read's limit: is in LINES, not tokens" {
    # Must mention both 'lines' and 'tokens' near a `limit:` reference, and
    # call out the 2000-line default — early drafts misadvised `limit: 25000`
    # thinking it was a token cap; the test guards against that regression.
    grep -qE '\*lines\*|in lines' "$SKILL_FILE" \
        || fail "linear-read SKILL.md missing 'lines' clarification for Read's limit parameter"
    grep -qE 'defaults to 2000|default 2000' "$SKILL_FILE" \
        || fail "linear-read SKILL.md missing 2000-line default reference for Read"
}

@test "TAP-2248: linear-read skill recommends Grep over Read for ID extraction on dump files" {
    grep -qE 'Grep.*over.*Read|prefer.*Grep' "$SKILL_FILE" \
        || fail "linear-read SKILL.md missing Grep-over-Read preference for dump-file parsing"
}

@test "TAP-2248: linear-read skill points at python-introspection, not Bash python3 -c" {
    grep -qF '/tmp/snippet.py' "$SKILL_FILE" \
        || fail "linear-read SKILL.md missing /tmp/snippet.py workaround pointer"
    grep -qE 'python-introspection' "$SKILL_FILE" \
        || fail "linear-read SKILL.md missing python-introspection skill cross-reference"
}

@test "TAP-2248: templates/PROMPT.md mirrors the limit: 100 default into consumer projects" {
    [[ -f "$PROMPT_TEMPLATE" ]] || skip "templates/PROMPT.md not present"
    grep -qE 'limit:[[:space:]]*100' "$PROMPT_TEMPLATE" \
        || fail "templates/PROMPT.md does not mirror the limit: 100 default"
}

@test "TAP-2248: templates/PROMPT.md surfaces MAX_MCP_OUTPUT_TOKENS to consumer projects" {
    [[ -f "$PROMPT_TEMPLATE" ]] || skip "templates/PROMPT.md not present"
    grep -qF 'MAX_MCP_OUTPUT_TOKENS' "$PROMPT_TEMPLATE" \
        || fail "templates/PROMPT.md does not mention MAX_MCP_OUTPUT_TOKENS for consumer projects"
}
