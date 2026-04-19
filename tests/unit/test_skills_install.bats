#!/usr/bin/env bats
# TAP-574: Unit tests for lib/skills_install.sh — global Claude skill sync
# with sidecar-based idempotency.
#
# Covers the four install cases and the two uninstall cases:
#   install:  fresh / idempotent re-install / user-modified file / user-authored dir / nested files
#   uninstall: Ralph-owned files removed + user files preserved / no-op without sidecar

bats_require_minimum_version 1.5.0
load '../helpers/test_helper'

LIB="${BATS_TEST_DIRNAME}/../../lib/skills_install.sh"

setup() {
    export TEST_TEMP_DIR="$(mktemp -d)"
    cd "$TEST_TEMP_DIR"
    mkdir -p src dest

    # Unset the double-source guard so every test gets a clean load.
    unset SKILLS_INSTALL_SOURCED
    # shellcheck disable=SC1090
    source "$LIB"
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR"
}

# ---------- helpers ----------

make_source_skill() {
    local name="$1"
    local content="${2:-hello}"
    mkdir -p "src/$name"
    printf '%s\n' "$content" > "src/$name/SKILL.md"
}

# ---------- install: case 1 (fresh) ----------

@test "TAP-574: fresh install copies tree and writes sidecar" {
    make_source_skill "search-first" "body"
    run skills_install_one "src/search-first" "dest/search-first" "1.9.0"
    assert_success
    [[ -f "dest/search-first/SKILL.md" ]] || fail "SKILL.md not copied"
    [[ -f "dest/search-first/.ralph-managed" ]] || fail "sidecar missing"
    run jq -r '.ralph_version' "dest/search-first/.ralph-managed"
    [[ "$output" == "1.9.0" ]] || fail "ralph_version wrong: $output"
    run jq -r '.files["SKILL.md"]' "dest/search-first/.ralph-managed"
    [[ "$output" == sha256:* ]] || fail "hash not recorded: $output"
}

# ---------- install: case 2 (idempotent re-install) ----------

@test "TAP-574: re-install is idempotent when source unchanged" {
    make_source_skill "tdd-workflow" "body"
    skills_install_one "src/tdd-workflow" "dest/tdd-workflow" "1.9.0"
    local first_hash
    first_hash=$(jq -r '.files["SKILL.md"]' "dest/tdd-workflow/.ralph-managed")

    run skills_install_one "src/tdd-workflow" "dest/tdd-workflow" "1.9.0"
    assert_success
    local second_hash
    second_hash=$(jq -r '.files["SKILL.md"]' "dest/tdd-workflow/.ralph-managed")
    [[ "$first_hash" == "$second_hash" ]] || fail "hash drifted across idempotent re-installs"
    [[ "$(cat dest/tdd-workflow/SKILL.md)" == "body" ]] || fail "content mutated"
}

@test "TAP-574: Ralph-owned file gets updated when source advances" {
    make_source_skill "claude-api" "v1-body"
    skills_install_one "src/claude-api" "dest/claude-api" "1.9.0"
    # Source advances without user touching the destination.
    printf 'v2-body\n' > "src/claude-api/SKILL.md"
    run skills_install_one "src/claude-api" "dest/claude-api" "1.10.0"
    assert_success
    [[ "$(cat dest/claude-api/SKILL.md)" == "v2-body" ]] || fail "Ralph-owned file not refreshed"
    run jq -r '.ralph_version' "dest/claude-api/.ralph-managed"
    [[ "$output" == "1.10.0" ]] || fail "sidecar version not refreshed: $output"
}

# ---------- install: user-modified file preserved ----------

@test "TAP-574: user-modified file preserved + WARN emitted" {
    make_source_skill "backend-patterns" "v1-body"
    skills_install_one "src/backend-patterns" "dest/backend-patterns" "1.9.0"
    printf 'USER EDITS\n' > "dest/backend-patterns/SKILL.md"
    printf 'v2-body\n' > "src/backend-patterns/SKILL.md"

    run skills_install_one "src/backend-patterns" "dest/backend-patterns" "1.10.0"
    assert_success
    [[ "$(cat dest/backend-patterns/SKILL.md)" == "USER EDITS" ]] \
        || fail "user edits were overwritten"
    [[ "$output" == *"user-modified skill file, skipping"* ]] \
        || fail "expected WARN not emitted. output=$output"
}

# ---------- install: case 3 (user-authored dir, no sidecar) ----------

@test "TAP-574: user-authored skill dir without sidecar is left alone" {
    mkdir -p "dest/python-patterns"
    printf 'user content\n' > "dest/python-patterns/SKILL.md"
    mkdir -p "src/python-patterns"
    printf 'ralph content\n' > "src/python-patterns/SKILL.md"

    run skills_install_one "src/python-patterns" "dest/python-patterns" "1.9.0"
    assert_success
    [[ "$(cat dest/python-patterns/SKILL.md)" == "user content" ]] \
        || fail "user-authored file was replaced"
    [[ ! -f "dest/python-patterns/.ralph-managed" ]] \
        || fail "sidecar was planted on user-authored dir"
    [[ "$output" == *"user-authored skill already present, skipping"* ]] \
        || fail "expected INFO not emitted. output=$output"
}

# ---------- install: nested files ----------

@test "TAP-574: nested files in skill are installed and tracked" {
    mkdir -p "src/knowledge-ops/examples"
    printf '# skill\n' > "src/knowledge-ops/SKILL.md"
    printf '# example\n' > "src/knowledge-ops/examples/foo.md"

    run skills_install_one "src/knowledge-ops" "dest/knowledge-ops" "1.9.0"
    assert_success
    [[ -f "dest/knowledge-ops/examples/foo.md" ]] || fail "nested file not copied"
    run jq -r '.files["examples/foo.md"]' "dest/knowledge-ops/.ralph-managed"
    [[ "$output" == sha256:* ]] || fail "nested file not tracked: $output"
}

# ---------- install: global iteration ----------

@test "TAP-574: skills_install_global iterates every child skill dir" {
    make_source_skill "search-first"
    make_source_skill "tdd-workflow"
    run skills_install_global "src" "dest" "1.9.0"
    assert_success
    [[ -f "dest/search-first/.ralph-managed" ]] || fail "search-first not installed"
    [[ -f "dest/tdd-workflow/.ralph-managed" ]] || fail "tdd-workflow not installed"
}

@test "TAP-574: skills_install_global is a no-op when source dir is missing" {
    run skills_install_global "/nonexistent/ralph/skills" "dest" "1.9.0"
    assert_success
}

@test "TAP-574: skills_install_global is a no-op on empty source dir" {
    mkdir -p src_empty
    run skills_install_global "src_empty" "dest" "1.9.0"
    assert_success
    [[ -d "dest" ]] || fail "dest not created"
    # Nothing should be under dest
    [[ -z "$(find dest -mindepth 1 -print -quit 2>/dev/null)" ]] \
        || fail "unexpected files under dest"
}

# ---------- uninstall ----------

@test "TAP-574: uninstall removes only Ralph-owned files" {
    make_source_skill "security-review" "body"
    skills_install_one "src/security-review" "dest/security-review" "1.9.0"
    # User adds an unmanaged side file they care about.
    printf 'user notes\n' > "dest/security-review/USER_NOTES.md"

    run skills_uninstall_one "dest/security-review"
    assert_success
    [[ ! -f "dest/security-review/SKILL.md" ]] || fail "Ralph file not removed"
    [[ ! -f "dest/security-review/.ralph-managed" ]] || fail "sidecar not removed"
    [[ -f "dest/security-review/USER_NOTES.md" ]] || fail "user side file was destroyed"
}

@test "TAP-574: uninstall preserves user-modified Ralph file" {
    make_source_skill "benchmark" "body"
    skills_install_one "src/benchmark" "dest/benchmark" "1.9.0"
    printf 'USER EDITS\n' > "dest/benchmark/SKILL.md"

    run skills_uninstall_one "dest/benchmark"
    assert_success
    [[ -f "dest/benchmark/SKILL.md" ]] || fail "user-modified file was deleted"
    [[ "$(cat dest/benchmark/SKILL.md)" == "USER EDITS" ]] \
        || fail "user edits were clobbered on uninstall"
    [[ ! -f "dest/benchmark/.ralph-managed" ]] || fail "sidecar was left behind"
}

@test "TAP-574: uninstall is a no-op on skill dir without sidecar" {
    mkdir -p "dest/user-skill"
    printf 'user\n' > "dest/user-skill/SKILL.md"

    run skills_uninstall_one "dest/user-skill"
    assert_success
    [[ -f "dest/user-skill/SKILL.md" ]] || fail "user-authored file was removed"
}

@test "TAP-574: uninstall_global only touches dirs with sidecar" {
    make_source_skill "linear" "body"
    skills_install_one "src/linear" "dest/linear" "1.9.0"
    mkdir -p "dest/user-skill"
    printf 'user content\n' > "dest/user-skill/SKILL.md"

    run skills_uninstall_global "dest"
    assert_success
    [[ -f "dest/user-skill/SKILL.md" ]] || fail "user-authored skill was destroyed"
    # Ralph skill dir should be gone (all files removed, then empty dir pruned).
    [[ ! -d "dest/linear" ]] || fail "Ralph skill dir not fully cleaned"
}
