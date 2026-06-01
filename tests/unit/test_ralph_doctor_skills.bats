#!/usr/bin/env bats
# Adoption gap: ralph-doctor must detect Ralph-shipped skills installed in
# ~/.claude/skills/ WITHOUT a .ralph-managed sidecar (orphaned pre-sidecar
# installs). Those dirs are skipped by skills_install_global forever, so a
# plain `ralph-upgrade` silently leaves them drifted. The detector points the
# operator at `RALPH_SKILLS_ADOPT=1 ralph-upgrade`.

bats_require_minimum_version 1.5.0
load '../helpers/test_helper'

# Extract the ralph-doctor heredoc body out of install.sh, same technique as
# test_ralph_doctor_linear.bats.
_extract_ralph_doctor() {
    local install_sh="${BATS_TEST_DIRNAME}/../../install.sh"
    awk '
      /cat > "\$INSTALL_DIR\/ralph-doctor" << '"'"'DOCTOREOF'"'"'/ { capture=1; next }
      /^DOCTOREOF$/ { if (capture) { capture=0 } }
      capture { print }
    ' "$install_sh" > "$DOCTOR_BIN"
    chmod +x "$DOCTOR_BIN"
}

setup() {
    # Sandbox HOME so the doctor reads our fixture trees, not the real ones.
    FAKE_HOME="$(mktemp -d)"
    PROJ="$(mktemp -d)"
    DOCTOR_BIN="$(mktemp)"
    _extract_ralph_doctor
    cd "$PROJ"
    SKILLS_SRC="$FAKE_HOME/.ralph/templates/skills/global"
    SKILLS_DST="$FAKE_HOME/.claude/skills"
    mkdir -p "$SKILLS_SRC" "$SKILLS_DST"
}

teardown() {
    cd /
    rm -rf "$FAKE_HOME" "$PROJ" "$DOCTOR_BIN"
}

_ship_skill() {
    mkdir -p "$SKILLS_SRC/$1"
    printf '# %s\n' "$1" > "$SKILLS_SRC/$1/SKILL.md"
}

_install_managed() {
    mkdir -p "$SKILLS_DST/$1"
    printf '# %s\n' "$1" > "$SKILLS_DST/$1/SKILL.md"
    printf '{"ralph_version":"2.17.0","files":{}}\n' > "$SKILLS_DST/$1/.ralph-managed"
}

_install_orphaned() {
    mkdir -p "$SKILLS_DST/$1"
    printf 'old pre-sidecar body\n' > "$SKILLS_DST/$1/SKILL.md"
    # No .ralph-managed sidecar.
}

@test "doctor: WARNs on a Ralph-shipped skill installed without a sidecar" {
    _ship_skill "search-first"
    _install_orphaned "search-first"

    HOME="$FAKE_HOME" run bash "$DOCTOR_BIN"
    assert_success
    [[ "$output" == *"Global Claude skills (TAP-574 sidecar):"* ]]
    [[ "$output" == *"[WARN] search-first: installed copy has no .ralph-managed sidecar"* ]]
    [[ "$output" == *"RALPH_SKILLS_ADOPT=1 ralph-upgrade"* ]]
}

@test "doctor: OK when every installed Ralph skill carries a sidecar" {
    _ship_skill "search-first"
    _install_managed "search-first"

    HOME="$FAKE_HOME" run bash "$DOCTOR_BIN"
    assert_success
    [[ "$output" == *"[OK] all installed Ralph skills carry the .ralph-managed sidecar"* ]]
    [[ "$output" != *"[WARN] search-first"* ]]
}

@test "doctor: does NOT flag a user skill whose name Ralph does not ship" {
    # Ralph ships search-first; user has their own 'my-notes' skill, no sidecar.
    _ship_skill "search-first"
    _install_managed "search-first"
    _install_orphaned "my-notes"

    HOME="$FAKE_HOME" run bash "$DOCTOR_BIN"
    assert_success
    [[ "$output" != *"my-notes"* ]] || fail "doctor flagged a non-shipped user skill"
    [[ "$output" == *"[OK] all installed Ralph skills carry the .ralph-managed sidecar"* ]]
}

@test "doctor: SKIPs cleanly when no skills are installed yet" {
    _ship_skill "search-first"
    # Nothing under SKILLS_DST except the dir itself.

    HOME="$FAKE_HOME" run bash "$DOCTOR_BIN"
    assert_success
    [[ "$output" == *"[OK] all installed Ralph skills carry the .ralph-managed sidecar"* ]]
}
