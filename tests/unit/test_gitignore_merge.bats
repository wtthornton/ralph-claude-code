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

# -----------------------------------------------------------------------------
# Dry-run mode (TAP-1883 — used by ralph_upgrade_project.sh to log diff
# without writing when DRY_RUN=true)
# -----------------------------------------------------------------------------

@test "merge_gitignore_block: dry_run=true does not modify target but counts missing" {
    _make_template
    cat > .gitignore <<'EOF'
node_modules/
EOF
    local before_hash
    before_hash=$(sha256sum .gitignore | awk '{print $1}')

    # Call directly (not via `run`) so GITIGNORE_MERGE_APPENDED propagates
    merge_gitignore_block .gitignore template-gitignore "true"

    local after_hash
    after_hash=$(sha256sum .gitignore | awk '{print $1}')
    [ "$before_hash" = "$after_hash" ]

    [ "$GITIGNORE_MERGE_APPENDED" -gt 0 ]
}

@test "merge_gitignore_block: dry_run=true publishes 0 when target already current" {
    _make_template
    merge_gitignore_block .gitignore template-gitignore "false"

    GITIGNORE_MERGE_APPENDED=999
    merge_gitignore_block .gitignore template-gitignore "true"
    [ "$GITIGNORE_MERGE_APPENDED" -eq 0 ]
}

@test "merge_gitignore_block: GITIGNORE_MERGE_APPENDED matches actual append count" {
    _make_template
    # Pre-populate with two patterns from the template so the next merge
    # appends only the remaining ones.
    cat > .gitignore <<'EOF'
.ralph/*
!.ralph/PROMPT.md
EOF
    merge_gitignore_block .gitignore template-gitignore "false"
    local expected="$GITIGNORE_MERGE_APPENDED"

    # Re-set and measure via dry-run on a fresh target with the same prefill
    cat > .gitignore-dryrun <<'EOF'
.ralph/*
!.ralph/PROMPT.md
EOF
    merge_gitignore_block .gitignore-dryrun template-gitignore "true"
    [ "$GITIGNORE_MERGE_APPENDED" -eq "$expected" ]
}

# -----------------------------------------------------------------------------
# upgrade_gitignore (ralph_upgrade_project.sh entry-point)
# -----------------------------------------------------------------------------

_load_upgrade_helpers() {
    # Source ralph_upgrade_project.sh's helpers without running its main.
    # We mock out the bits the helper needs but ship the real ones we test.
    export RALPH_TEMPLATES="$TEST_DIR/templates"
    mkdir -p "$RALPH_TEMPLATES"
    cp "$TEMPLATE_GITIGNORE" "$RALPH_TEMPLATES/.gitignore"

    # Logging shims (no color, deterministic)
    log() { echo "[$1] ${*:2}"; }
    audit() { :; }
    create_backup() { :; }

    # Counters that upgrade_gitignore mutates
    PROJ_UPDATED=0
    PROJ_CREATED=0
    PROJ_SKIPPED=0

    # Re-export so the sourced enable_core.sh sees them in its grep paths
    export DRY_RUN="${DRY_RUN:-false}"

    # Define upgrade_gitignore in this shell. Easiest reproduction is to
    # source the real script after setting a guard that prevents main()
    # execution. ralph_upgrade_project.sh has no `main` autorun (CLI parse
    # lives in the bottom block guarded by BASH_SOURCE checks), so direct
    # source is safe.
    set +e
    # Source enable_core.sh first so merge_gitignore_block is available.
    source "${BATS_TEST_DIRNAME}/../../lib/enable_core.sh"
    # Define the wrapper inline mirroring ralph_upgrade_project.sh's body —
    # we don't source the whole upgrade script because it has set -euo at
    # the top and CLI-arg parsing assumptions that conflict with BATS.
    upgrade_gitignore() {
        local project="$1"
        local template_gitignore="$RALPH_TEMPLATES/.gitignore"
        local project_gitignore="$project/.gitignore"

        [[ ! -f "$template_gitignore" ]] && return 0

        if [[ ! -f "$project_gitignore" ]]; then
            if [[ "$DRY_RUN" == "true" ]]; then
                log DRY "Would create .gitignore from $template_gitignore"
                PROJ_CREATED=$((PROJ_CREATED + 1))
                return 0
            fi
            cp "$template_gitignore" "$project_gitignore"
            log SUCCESS "Created .gitignore from template"
            PROJ_CREATED=$((PROJ_CREATED + 1))
            return 0
        fi

        GITIGNORE_MERGE_APPENDED=0
        merge_gitignore_block "$project_gitignore" "$template_gitignore" "true" >/dev/null 2>&1
        local missing="$GITIGNORE_MERGE_APPENDED"

        if [[ "$missing" -eq 0 ]]; then
            log SKIP ".gitignore already current"
            PROJ_SKIPPED=$((PROJ_SKIPPED + 1))
            return 0
        fi

        if [[ "$DRY_RUN" == "true" ]]; then
            log DRY "Would merge $missing missing Ralph entries into .gitignore"
            PROJ_UPDATED=$((PROJ_UPDATED + 1))
            return 0
        fi

        create_backup "$project" ".gitignore"
        merge_gitignore_block "$project_gitignore" "$template_gitignore" "false" >/dev/null 2>&1
        log SUCCESS "Merged $missing missing Ralph entries into .gitignore"
        PROJ_UPDATED=$((PROJ_UPDATED + 1))
    }
    set -e
}

@test "upgrade_gitignore: stale repo backfills missing allowlist patterns" {
    _load_upgrade_helpers
    mkdir -p project
    cat > project/.gitignore <<'EOF'
.ralph/.call_count
.ralph/.last_reset
EOF

    upgrade_gitignore project

    grep -qxF '.ralph/.call_count' project/.gitignore
    grep -qxF '.ralph/.last_reset' project/.gitignore
    grep -qxF '.ralph/*' project/.gitignore
    grep -qxF '!.ralph/PROMPT.md' project/.gitignore
    [ "$PROJ_UPDATED" -eq 1 ]
}

@test "upgrade_gitignore: second invocation is a no-op" {
    _load_upgrade_helpers
    mkdir -p project
    cp "$RALPH_TEMPLATES/.gitignore" project/.gitignore

    upgrade_gitignore project
    local first_hash
    first_hash=$(sha256sum project/.gitignore | awk '{print $1}')

    PROJ_SKIPPED=0
    upgrade_gitignore project
    local second_hash
    second_hash=$(sha256sum project/.gitignore | awk '{print $1}')

    [ "$first_hash" = "$second_hash" ]
    [ "$PROJ_SKIPPED" -eq 1 ]
}

@test "upgrade_gitignore: preserves user entries above and below across upgrade" {
    _load_upgrade_helpers
    mkdir -p project
    cat > project/.gitignore <<'EOF'
# my prefix rules
secrets.env
.ralph/.call_count

# my suffix rules
local-secrets/
EOF
    cp project/.gitignore expected-user-content.txt

    run upgrade_gitignore project
    [ "$status" -eq 0 ]

    # User entries still present byte-for-byte (head + tail)
    head -3 project/.gitignore > head.txt
    head -3 expected-user-content.txt > expected-head.txt
    diff head.txt expected-head.txt

    grep -qxF 'local-secrets/' project/.gitignore
    grep -qxF '# my suffix rules' project/.gitignore
}

@test "upgrade_gitignore: missing project .gitignore is created from template" {
    _load_upgrade_helpers
    mkdir -p project
    [ ! -f project/.gitignore ]

    upgrade_gitignore project
    [ -f project/.gitignore ]

    grep -qxF '.ralph/*' project/.gitignore
    [ "$PROJ_CREATED" -eq 1 ]
}

@test "upgrade_gitignore: DRY_RUN=true does not write or copy" {
    _load_upgrade_helpers
    mkdir -p project
    cat > project/.gitignore <<'EOF'
.ralph/.call_count
EOF
    local before_hash
    before_hash=$(sha256sum project/.gitignore | awk '{print $1}')

    DRY_RUN=true run upgrade_gitignore project
    [ "$status" -eq 0 ]

    local after_hash
    after_hash=$(sha256sum project/.gitignore | awk '{print $1}')
    [ "$before_hash" = "$after_hash" ]
}

@test "upgrade_gitignore: DRY_RUN=true with missing target reports would-create" {
    _load_upgrade_helpers
    mkdir -p project
    [ ! -f project/.gitignore ]

    DRY_RUN=true run upgrade_gitignore project
    [ "$status" -eq 0 ]
    [ ! -f project/.gitignore ]
    [[ "$output" == *"Would create"* ]]
}
