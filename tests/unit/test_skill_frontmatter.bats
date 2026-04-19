#!/usr/bin/env bats
# TAP-575: Frontmatter validation for Ralph's global skill library.
# Every skill under templates/skills/global/<name>/SKILL.md must carry the
# Ralph frontmatter standard so the install mechanism (TAP-574) and
# Claude Code's skill discovery can reason about it uniformly.

bats_require_minimum_version 1.5.0
load '../helpers/test_helper'

SKILLS_ROOT="${BATS_TEST_DIRNAME}/../../templates/skills/global"

# Extract the YAML frontmatter block (between the first two `---` lines)
# into stdout. Returns empty if no frontmatter is present.
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

# List every Tier S skill dir that must be present. Hard-coding the set
# means a future drop of a skill without updating the test is caught.
TIER_S_SKILLS=(search-first tdd-workflow simplify context-audit agentic-engineering)

setup() {
    [[ -d "$SKILLS_ROOT" ]] || skip "templates/skills/global not present"
}

@test "TAP-575: all Tier S skill directories exist" {
    for s in "${TIER_S_SKILLS[@]}"; do
        [[ -d "$SKILLS_ROOT/$s" ]] || fail "missing skill dir: $s"
        [[ -f "$SKILLS_ROOT/$s/SKILL.md" ]] || fail "missing SKILL.md for: $s"
    done
}

@test "TAP-575: every SKILL.md begins with YAML frontmatter block" {
    for s in "${TIER_S_SKILLS[@]}"; do
        local file="$SKILLS_ROOT/$s/SKILL.md"
        local fm
        fm=$(extract_frontmatter "$file")
        [[ -n "$fm" ]] || fail "no frontmatter in $file"
    done
}

@test "TAP-575: every SKILL.md carries required frontmatter keys" {
    local required_keys=(
        "name:"
        "description:"
        "version:"
        "ralph:"
        "ralph_version_min:"
        "attribution:"
        "user-invocable:"
        "disable-model-invocation:"
        "allowed-tools:"
    )

    for s in "${TIER_S_SKILLS[@]}"; do
        local file="$SKILLS_ROOT/$s/SKILL.md"
        local fm
        fm=$(extract_frontmatter "$file")
        local key
        for key in "${required_keys[@]}"; do
            echo "$fm" | grep -q "^${key}" \
                || fail "$s: missing frontmatter key '${key%:}'"
        done
    done
}

@test "TAP-575: every skill declares ralph: true" {
    for s in "${TIER_S_SKILLS[@]}"; do
        local file="$SKILLS_ROOT/$s/SKILL.md"
        local fm
        fm=$(extract_frontmatter "$file")
        local ralph_line
        ralph_line=$(echo "$fm" | awk -F':' '/^ralph:[[:space:]]/ {print $2}' | tr -d ' ')
        [[ "$ralph_line" == "true" ]] || fail "$s: ralph != true (got: '$ralph_line')"
    done
}

@test "TAP-575: every skill carries a semver version" {
    for s in "${TIER_S_SKILLS[@]}"; do
        local file="$SKILLS_ROOT/$s/SKILL.md"
        local fm
        fm=$(extract_frontmatter "$file")
        local version
        version=$(echo "$fm" | awk -F':' '/^version:[[:space:]]/ {print $2}' | tr -d ' ')
        [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
            || fail "$s: version '$version' is not X.Y.Z semver"
    done
}

@test "TAP-575: ralph_version_min is a semver string" {
    for s in "${TIER_S_SKILLS[@]}"; do
        local file="$SKILLS_ROOT/$s/SKILL.md"
        local fm
        fm=$(extract_frontmatter "$file")
        local vmin
        vmin=$(echo "$fm" | awk -F':' '/^ralph_version_min:[[:space:]]/ {print $2}' | tr -d ' "')
        [[ "$vmin" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
            || fail "$s: ralph_version_min '$vmin' is not X.Y.Z"
    done
}

@test "TAP-575: allowed-tools lists only known Claude Code tools" {
    # The whitelist mirrors the tools actually available to Ralph-driven
    # sessions. A rogue value here (e.g. "Network", "Database") is a
    # typo or a security drift and should fail CI loudly.
    local known='|Read|Write|Edit|Grep|Glob|Bash|WebFetch|WebSearch|Task|Agent|TodoWrite|NotebookEdit|'

    for s in "${TIER_S_SKILLS[@]}"; do
        local file="$SKILLS_ROOT/$s/SKILL.md"
        # Grab the indented list items under `allowed-tools:`.
        # The list continues until a non-indented line or EOF within
        # the frontmatter block.
        local list
        list=$(extract_frontmatter "$file" \
            | awk '
                /^allowed-tools:/ { in_list=1; next }
                in_list {
                    if ($0 ~ /^[^[:space:]]/) exit
                    sub(/^[[:space:]]*-[[:space:]]*/, "")
                    print
                }
            ')

        [[ -n "$list" ]] || fail "$s: allowed-tools is empty"
        local tool
        while IFS= read -r tool; do
            [[ -z "$tool" ]] && continue
            [[ "$known" == *"|${tool}|"* ]] \
                || fail "$s: unknown tool '$tool' in allowed-tools"
        done <<<"$list"
    done
}

@test "TAP-575: attribution field is non-empty" {
    for s in "${TIER_S_SKILLS[@]}"; do
        local file="$SKILLS_ROOT/$s/SKILL.md"
        local fm
        fm=$(extract_frontmatter "$file")
        local attr
        attr=$(echo "$fm" | awk -F':' '/^attribution:/ {$1=""; sub(/^ /,""); print}')
        [[ -n "$attr" ]] || fail "$s: attribution is empty"
    done
}
