#!/usr/bin/env bats
# TAP-1879 — Branch-cleanup prompt instructions must live in both surfaces
# in lockstep: the loop context string in ralph_loop.sh AND the
# ralph-workflow skill's R1 rule. Both must instruct Claude to delete the
# source branch (locally and on origin) after a successful squash-merge,
# with the deletion verbs adjacent to the squash-merge instruction so the
# LLM ties them together as one atomic operation.

REPO_ROOT="${BATS_TEST_DIRNAME}/../.."
LOOP_SH="${REPO_ROOT}/ralph_loop.sh"
SKILL_MD="${REPO_ROOT}/templates/skills-local/ralph-workflow/SKILL.md"

# Helper: minimum byte distance between any occurrence of $haystack_needle
# and any occurrence of $target_needle in $file. Each phrase may legitimately
# appear multiple times in the prompt (the merge instruction is repeated for
# rhetorical emphasis); the deletion only needs to be adjacent to ONE of
# them. 99999 if either needle is missing.
_min_distance() {
    local file="$1" left="$2" right="$3"
    local lefts rights
    lefts=$(grep -o --byte-offset -F "$left"  "$file" 2>/dev/null | cut -d: -f1)
    rights=$(grep -o --byte-offset -F "$right" "$file" 2>/dev/null | cut -d: -f1)
    if [[ -z "$lefts" || -z "$rights" ]]; then
        echo 99999
        return
    fi
    local min=99999
    local a b dist
    while IFS= read -r a; do
        while IFS= read -r b; do
            if [[ "$a" -gt "$b" ]]; then dist=$((a - b)); else dist=$((b - a)); fi
            (( dist < min )) && min="$dist"
        done <<< "$rights"
    done <<< "$lefts"
    echo "$min"
}

# -----------------------------------------------------------------------------
# Both files contain BOTH deletion verbs
# -----------------------------------------------------------------------------

@test "TAP-1879: ralph_loop.sh prompt names 'git branch -D <branch>'" {
    grep -qF 'git branch -D <branch>' "$LOOP_SH"
}

@test "TAP-1879: ralph_loop.sh prompt names 'git push origin --delete <branch>'" {
    grep -qF 'git push origin --delete <branch>' "$LOOP_SH"
}

@test "TAP-1879: SKILL.md R1 names 'git branch -D <branch>'" {
    grep -qF 'git branch -D <branch>' "$SKILL_MD"
}

@test "TAP-1879: SKILL.md R1 names 'git push origin --delete <branch>'" {
    grep -qF 'git push origin --delete <branch>' "$SKILL_MD"
}

# -----------------------------------------------------------------------------
# Deletion is adjacent to the squash-merge instruction (lockstep + atomic)
# -----------------------------------------------------------------------------

@test "TAP-1879: ralph_loop.sh — 'git branch -D' is within 200 chars of squash-merge instruction" {
    local dist
    dist=$(_min_distance "$LOOP_SH" 'gh pr merge --squash --auto' 'git branch -D <branch>')
    [ "$dist" -le 200 ]
}

@test "TAP-1879: SKILL.md — 'git branch -D' is within 200 chars of squash-merge instruction" {
    local dist
    dist=$(_min_distance "$SKILL_MD" 'gh pr merge --squash --auto' 'git branch -D <branch>')
    [ "$dist" -le 200 ]
}

# -----------------------------------------------------------------------------
# Best-effort framing — deletion failures must NOT be framed as blockers
# (the loop continues, no CB trip, no exit-signal change)
# -----------------------------------------------------------------------------

@test "TAP-1879: ralph_loop.sh frames origin-delete failures as best-effort" {
    # The exact framing words to look for. Either phrase tells Claude to
    # ignore errors and proceed.
    grep -qE 'best-effort|ignore.*errors' "$LOOP_SH"
}

@test "TAP-1879: SKILL.md frames origin-delete failures as best-effort" {
    grep -qE 'best-effort|ignore.*errors' "$SKILL_MD"
}

# -----------------------------------------------------------------------------
# Lockstep: both surfaces are kept in sync per the feedback_default_doc_lockstep
# memory — neither should reference branch deletion without the other.
# -----------------------------------------------------------------------------

@test "TAP-1879: deletion instruction is present in BOTH surfaces (lockstep)" {
    local loop_has skill_has
    grep -qF 'git branch -D <branch>' "$LOOP_SH" && loop_has=1 || loop_has=0
    grep -qF 'git branch -D <branch>' "$SKILL_MD" && skill_has=1 || skill_has=0
    [ "$loop_has" = "$skill_has" ]
    [ "$loop_has" = 1 ]
}
