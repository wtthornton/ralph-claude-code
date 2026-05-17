#!/usr/bin/env bats
# Unit tests for merge_gitignore_block in lib/enable_core.sh
# Covers fresh install, missing-line backfill, no-op on current, and
# preservation of user content above and below the Ralph block.

load '../helpers/test_helper'

ENABLE_CORE="${BATS_TEST_DIRNAME}/../../lib/enable_core.sh"
TEMPLATE_GITIGNORE="${BATS_TEST_DIRNAME}/../../templates/.gitignore"
ORIGINAL_HOME="$HOME"

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR"

    export HOME="$TEST_DIR/home"
    mkdir -p "$HOME"

    set +e
    source "$ENABLE_CORE"
    set -e
}

teardown() {
    export HOME="$ORIGINAL_HOME"
    if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
        cd /
        rm -rf "$TEST_DIR"
    fi
}

# Helper: emit a known template fixture into $TEST_DIR/template-gitignore
_make_template() {
    cat > template-gitignore <<'EOF'
# Ralph state — allowlist pattern; ignore .ralph/* except committed files below
.ralph/*
!.ralph/PROMPT.md
!.ralph/AGENT.md
!.ralph/fix_plan.md
!.ralph/hooks/
!.ralph/hooks/**
!.ralph/.gitkeep

# General logs
*.log
EOF
}

# -----------------------------------------------------------------------------
# Fresh-install paths
# -----------------------------------------------------------------------------

@test "merge_gitignore_block: empty target file gets every pattern from template" {
    _make_template
    : > .gitignore

    run merge_gitignore_block .gitignore template-gitignore
    [ "$status" -eq 0 ]

    grep -qxF '.ralph/*' .gitignore
    grep -qxF '!.ralph/PROMPT.md' .gitignore
    grep -qxF '!.ralph/AGENT.md' .gitignore
    grep -qxF '!.ralph/fix_plan.md' .gitignore
    grep -qxF '!.ralph/hooks/' .gitignore
    grep -qxF '!.ralph/hooks/**' .gitignore
    grep -qxF '!.ralph/.gitkeep' .gitignore
    grep -qxF '*.log' .gitignore
}

@test "merge_gitignore_block: missing target file is created" {
    _make_template
    [ ! -f .gitignore ]

    run merge_gitignore_block .gitignore template-gitignore
    [ "$status" -eq 0 ]
    [ -f .gitignore ]

    grep -qxF '.ralph/*' .gitignore
}

@test "merge_gitignore_block: comment-only and blank source lines are not appended" {
    _make_template
    : > .gitignore

    run merge_gitignore_block .gitignore template-gitignore
    [ "$status" -eq 0 ]

    # The header comment line is in the source but must not appear as a "pattern".
    # It might still appear via the helper's own "# Ralph managed entries" header,
    # but never as a verbatim copy of the source header comment.
    ! grep -qxF '# Ralph state — allowlist pattern; ignore .ralph/* except committed files below' .gitignore
    ! grep -qxF '# General logs' .gitignore
}

# -----------------------------------------------------------------------------
# Upgrade / backfill paths
# -----------------------------------------------------------------------------

@test "merge_gitignore_block: old denylist target gets new allowlist patterns appended" {
    _make_template
    # Simulate an old consumer repo with the per-file denylist
    cat > .gitignore <<'EOF'
.ralph/.call_count
.ralph/.last_reset
.ralph/status.json
EOF

    run merge_gitignore_block .gitignore template-gitignore
    [ "$status" -eq 0 ]

    # Old denylist lines are preserved verbatim
    grep -qxF '.ralph/.call_count' .gitignore
    grep -qxF '.ralph/.last_reset' .gitignore
    grep -qxF '.ralph/status.json' .gitignore

    # New allowlist lines are appended
    grep -qxF '.ralph/*' .gitignore
    grep -qxF '!.ralph/PROMPT.md' .gitignore
}

@test "merge_gitignore_block: re-running on an up-to-date target is a no-op" {
    _make_template
    : > .gitignore

    run merge_gitignore_block .gitignore template-gitignore
    [ "$status" -eq 0 ]
    local first_hash
    first_hash=$(sha256sum .gitignore | awk '{print $1}')

    run merge_gitignore_block .gitignore template-gitignore
    [ "$status" -eq 0 ]
    local second_hash
    second_hash=$(sha256sum .gitignore | awk '{print $1}')

    [ "$first_hash" = "$second_hash" ]
}

@test "merge_gitignore_block: each pattern line appears at most once after merge" {
    _make_template
    cat > .gitignore <<'EOF'
.ralph/*
*.log
EOF

    run merge_gitignore_block .gitignore template-gitignore
    [ "$status" -eq 0 ]

    [ "$(grep -cxF '.ralph/*' .gitignore)" -eq 1 ]
    [ "$(grep -cxF '*.log' .gitignore)" -eq 1 ]
}

# -----------------------------------------------------------------------------
# User-content preservation
# -----------------------------------------------------------------------------

@test "merge_gitignore_block: preserves user entries above the Ralph block byte-for-byte" {
    _make_template
    cat > .gitignore <<'EOF'
# My custom rules
secrets.env
build-artifacts/
EOF

    run merge_gitignore_block .gitignore template-gitignore
    [ "$status" -eq 0 ]

    # First three lines (user content) must be byte-identical
    head -3 .gitignore > head.txt
    cat > expected-head.txt <<'EOF'
# My custom rules
secrets.env
build-artifacts/
EOF
    diff head.txt expected-head.txt
}

@test "merge_gitignore_block: preserves user entries below an old Ralph block" {
    _make_template
    cat > .gitignore <<'EOF'
.ralph/.call_count
.ralph/status.json

# my downstream rules
local-secrets/
EOF

    run merge_gitignore_block .gitignore template-gitignore
    [ "$status" -eq 0 ]

    grep -qxF 'local-secrets/' .gitignore
    grep -qxF '# my downstream rules' .gitignore
    # Order check: 'local-secrets/' precedes any newly appended Ralph pattern
    local user_line ralph_line
    user_line=$(grep -nxF 'local-secrets/' .gitignore | cut -d: -f1)
    ralph_line=$(grep -nxF '!.ralph/PROMPT.md' .gitignore | cut -d: -f1)
    [ "$user_line" -lt "$ralph_line" ]
}

# -----------------------------------------------------------------------------
# Defaults / error paths
# -----------------------------------------------------------------------------

@test "merge_gitignore_block: missing source template returns non-zero" {
    : > .gitignore
    run merge_gitignore_block .gitignore /no/such/template
    [ "$status" -ne 0 ]
}

@test "merge_gitignore_block: defaults source to get_templates_dir result" {
    # Stage a templates dir that get_templates_dir will resolve
    mkdir -p "$HOME/.ralph/templates"
    cp "$TEMPLATE_GITIGNORE" "$HOME/.ralph/templates/.gitignore"

    : > .gitignore
    run merge_gitignore_block .gitignore
    [ "$status" -eq 0 ]
    grep -qxF '.ralph/*' .gitignore
}

# -----------------------------------------------------------------------------
# Allowlist contract: shipped template must contain the canonical exceptions
# -----------------------------------------------------------------------------

@test "templates/.gitignore: contains the canonical allowlist pattern" {
    grep -qxF '.ralph/*' "$TEMPLATE_GITIGNORE"
    grep -qxF '!.ralph/PROMPT.md' "$TEMPLATE_GITIGNORE"
    grep -qxF '!.ralph/AGENT.md' "$TEMPLATE_GITIGNORE"
    grep -qxF '!.ralph/fix_plan.md' "$TEMPLATE_GITIGNORE"
    grep -qxF '!.ralph/hooks/' "$TEMPLATE_GITIGNORE"
    grep -qxF '!.ralph/hooks/**' "$TEMPLATE_GITIGNORE"
    grep -qxF '!.ralph/.gitkeep' "$TEMPLATE_GITIGNORE"
}

@test "templates/.gitignore: no per-file Ralph state denylist entries remain" {
    ! grep -qxF '.ralph/.call_count' "$TEMPLATE_GITIGNORE"
    ! grep -qxF '.ralph/.last_reset' "$TEMPLATE_GITIGNORE"
    ! grep -qxF '.ralph/.exit_signals' "$TEMPLATE_GITIGNORE"
    ! grep -qxF '.ralph/.circuit_breaker_state' "$TEMPLATE_GITIGNORE"
    ! grep -qxF '.ralph/status.json' "$TEMPLATE_GITIGNORE"
}
