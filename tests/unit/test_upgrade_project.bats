#!/usr/bin/env bats
# Unit tests for ralph_upgrade_project.sh
#
# Regression: read-only destination hook files caused silent half-upgrades —
# `tr -d < src > dst` fails with "Permission denied" when dst is mode 555,
# and because the loop continues the rest of the project upgrade runs to
# completion without any error on stdout/stderr.

load '../helpers/test_helper'

PROJECT_ROOT="${BATS_TEST_DIRNAME}/../.."
UPGRADE_SCRIPT="${PROJECT_ROOT}/ralph_upgrade_project.sh"

setup() {
    TEST_DIR="$(mktemp -d)"
    # ralph_upgrade_project.sh reads $HOME/.ralph, so fake HOME to isolate.
    export HOME="$TEST_DIR/home"
    FAKE_RALPH="$HOME/.ralph"
    mkdir -p "$FAKE_RALPH/templates/hooks"
    mkdir -p "$FAKE_RALPH/templates/agents"
    cat > "$FAKE_RALPH/templates/hooks/validate-command.sh" <<'EOF'
#!/bin/bash
# NEW template content
exit 0
EOF
    chmod +x "$FAKE_RALPH/templates/hooks/validate-command.sh"

    # Fake project with a 555 stale hook (the real-world bug trigger).
    # is_ralph_project() requires .ralph/ + (fix_plan.md | .ralphrc | PROMPT.md).
    PROJ_DIR="$TEST_DIR/proj"
    mkdir -p "$PROJ_DIR/.ralph/hooks"
    touch "$PROJ_DIR/.ralph/fix_plan.md"
    cat > "$PROJ_DIR/.ralph/hooks/validate-command.sh" <<'EOF'
#!/bin/bash
# OLD stale content
exit 0
EOF
    chmod 555 "$PROJ_DIR/.ralph/hooks/validate-command.sh"
}

teardown() {
    if [[ -n "${TEST_DIR:-}" && -d "$TEST_DIR" ]]; then
        chmod -R u+w "$TEST_DIR" 2>/dev/null || true
        rm -rf "$TEST_DIR"
    fi
}

@test "upgrade-project: overwrites read-only (555) hook files" {
    run bash "$UPGRADE_SCRIPT" --yes "$PROJ_DIR"
    [[ "$status" -eq 0 ]]

    grep -q "NEW template content" "$PROJ_DIR/.ralph/hooks/validate-command.sh"
    ! grep -q "OLD stale content" "$PROJ_DIR/.ralph/hooks/validate-command.sh"
}

@test "upgrade-project: preserves executable bit after overwrite" {
    run bash "$UPGRADE_SCRIPT" --yes "$PROJ_DIR"
    [[ "$status" -eq 0 ]]
    [[ -x "$PROJ_DIR/.ralph/hooks/validate-command.sh" ]]
}
