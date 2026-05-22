#!/usr/bin/env bats
# TAP-1103: CLI flag > env var > .ralphrc > defaults precedence
#
# Before this fix, `ralph --dry-run` ran a real Claude API call when .ralphrc
# had DRY_RUN=false, because load_ralphrc() ran AFTER arg parsing and
# clobbered the CLI value. Tests verify the parallel _cli_* capture restores
# CLI values after .ralphrc is sourced.
#
# Tests run in subshells (`bash -c '...'`) instead of sourcing ralph_loop.sh
# directly into the BATS process — sourcing installs EXIT traps that fire
# cleanup against missing log files and break BATS test gathering.

RALPH_SCRIPT="${BATS_TEST_DIRNAME}/../../ralph_loop.sh"

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR" || return 1
    export RALPH_DIR=".ralph"
    mkdir -p "$RALPH_DIR"
}

teardown() {
    if [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]]; then
        cd /
        rm -rf "$TEST_DIR"
    fi
}

# _run_in_isolated_shell — execute a snippet against a freshly-sourced
# ralph_loop.sh in a subshell, returning the value of one variable.
# Args: $1 = setup snippet (sets _cli_*, _env_*), $2 = variable to echo.
_run_in_isolated_shell() {
    local setup_snippet="$1"
    local var_to_check="$2"
    bash -c "
        set +e
        # Suppress stderr from the script's startup chatter
        source '$RALPH_SCRIPT' >/dev/null 2>&1
        trap - EXIT SIGINT SIGTERM
        $setup_snippet
        load_ralphrc >/dev/null 2>&1
        printf '%s' \"\${$var_to_check}\"
    " 2>/dev/null
}

# =============================================================================
# TEST 1: --dry-run overrides .ralphrc DRY_RUN=false (the canonical bug)
# =============================================================================

@test "TAP-1103: _cli_DRY_RUN=true beats .ralphrc DRY_RUN=false" {
    cat > .ralphrc <<'EOF'
DRY_RUN=false
EOF
    local result
    result=$(_run_in_isolated_shell '_cli_DRY_RUN=true; DRY_RUN=true' 'DRY_RUN')
    [[ "$result" == "true" ]]
}

# =============================================================================
# TEST 2: env DRY_RUN=true beats .ralphrc DRY_RUN=false (regression guard)
# =============================================================================

@test "TAP-1103: env DRY_RUN=true still beats .ralphrc DRY_RUN=false" {
    cat > .ralphrc <<'EOF'
DRY_RUN=false
EOF
    local result
    result=$(_run_in_isolated_shell '_env_DRY_RUN=true; DRY_RUN=true' 'DRY_RUN')
    [[ "$result" == "true" ]]
}

# =============================================================================
# TEST 3: .ralphrc applies when neither CLI flag nor env var is set
# =============================================================================

@test "TAP-1103: .ralphrc DRY_RUN=true applies when no CLI flag and no env var" {
    cat > .ralphrc <<'EOF'
DRY_RUN=true
EOF
    local result
    result=$(_run_in_isolated_shell '_cli_DRY_RUN=""; _env_DRY_RUN=""; DRY_RUN=""' 'DRY_RUN')
    [[ "$result" == "true" ]]
}

# =============================================================================
# TEST 4: --no-continue overrides .ralphrc CLAUDE_USE_CONTINUE=true
# =============================================================================

@test "TAP-1103: _cli_CLAUDE_USE_CONTINUE=false beats .ralphrc CLAUDE_USE_CONTINUE=true" {
    cat > .ralphrc <<'EOF'
CLAUDE_USE_CONTINUE=true
EOF
    local result
    result=$(_run_in_isolated_shell '_cli_CLAUDE_USE_CONTINUE=false; CLAUDE_USE_CONTINUE=false' 'CLAUDE_USE_CONTINUE')
    [[ "$result" == "false" ]]
}

# =============================================================================
# TEST 5: --session-expiry overrides .ralphrc value
# =============================================================================

@test "TAP-1103: _cli_CLAUDE_SESSION_EXPIRY_HOURS=48 beats .ralphrc value" {
    cat > .ralphrc <<'EOF'
CLAUDE_SESSION_EXPIRY_HOURS=24
EOF
    local result
    result=$(_run_in_isolated_shell '_cli_CLAUDE_SESSION_EXPIRY_HOURS=48; CLAUDE_SESSION_EXPIRY_HOURS=48' 'CLAUDE_SESSION_EXPIRY_HOURS')
    [[ "$result" == "48" ]]
}

# =============================================================================
# TEST 6: --output-format text overrides .ralphrc CLAUDE_OUTPUT_FORMAT=json
# =============================================================================

@test "TAP-1103: _cli_CLAUDE_OUTPUT_FORMAT=text beats .ralphrc CLAUDE_OUTPUT_FORMAT=json" {
    cat > .ralphrc <<'EOF'
CLAUDE_OUTPUT_FORMAT=json
EOF
    local result
    result=$(_run_in_isolated_shell '_cli_CLAUDE_OUTPUT_FORMAT=text; CLAUDE_OUTPUT_FORMAT=text' 'CLAUDE_OUTPUT_FORMAT')
    [[ "$result" == "text" ]]
}

# =============================================================================
# TEST 7: --log-max-size overrides .ralphrc LOG_MAX_SIZE_MB
# =============================================================================

@test "TAP-1103: _cli_LOG_MAX_SIZE_MB=50 beats .ralphrc LOG_MAX_SIZE_MB=10" {
    cat > .ralphrc <<'EOF'
LOG_MAX_SIZE_MB=10
EOF
    local result
    result=$(_run_in_isolated_shell '_cli_LOG_MAX_SIZE_MB=50; LOG_MAX_SIZE_MB=50' 'LOG_MAX_SIZE_MB')
    [[ "$result" == "50" ]]
}

# =============================================================================
# .ralphrc.local — operator-only override surface
# =============================================================================
# Primary motivator: per-repo bypasses like RALPH_ALLOW_PUSH_MAIN=1 that the
# agent must not be able to self-unlock. .ralphrc.local is sourced AFTER
# .ralphrc but BEFORE env / CLI restoration, with `set -a` so values auto-
# export to the Claude CLI invocation and downstream hook subprocesses.

@test ".ralphrc.local value overrides .ralphrc value (no env, no CLI)" {
    cat > .ralphrc <<'EOF'
CLAUDE_TIMEOUT_MINUTES=30
EOF
    cat > .ralphrc.local <<'EOF'
CLAUDE_TIMEOUT_MINUTES=120
EOF
    local result
    result=$(_run_in_isolated_shell '_cli_CLAUDE_TIMEOUT_MINUTES=""; _env_CLAUDE_TIMEOUT_MINUTES=""' 'CLAUDE_TIMEOUT_MINUTES')
    [[ "$result" == "120" ]] \
        || { echo "expected 120 (.ralphrc.local), got '$result'"; return 1; }
}

@test "env var still beats .ralphrc.local (precedence integrity)" {
    cat > .ralphrc <<'EOF'
CLAUDE_TIMEOUT_MINUTES=30
EOF
    cat > .ralphrc.local <<'EOF'
CLAUDE_TIMEOUT_MINUTES=120
EOF
    local result
    result=$(_run_in_isolated_shell '_env_CLAUDE_TIMEOUT_MINUTES=999; CLAUDE_TIMEOUT_MINUTES=999' 'CLAUDE_TIMEOUT_MINUTES')
    [[ "$result" == "999" ]] \
        || { echo "expected 999 (env), got '$result'"; return 1; }
}

@test ".ralphrc.local absent is a no-op (falls back to .ralphrc)" {
    cat > .ralphrc <<'EOF'
CLAUDE_TIMEOUT_MINUTES=42
EOF
    [[ ! -e .ralphrc.local ]] || rm .ralphrc.local
    local result
    result=$(_run_in_isolated_shell '_cli_CLAUDE_TIMEOUT_MINUTES=""; _env_CLAUDE_TIMEOUT_MINUTES=""' 'CLAUDE_TIMEOUT_MINUTES')
    [[ "$result" == "42" ]] \
        || { echo "expected 42 (.ralphrc), got '$result'"; return 1; }
}

@test ".ralphrc.local-only (no .ralphrc) still applies" {
    [[ ! -e .ralphrc ]] || rm .ralphrc
    cat > .ralphrc.local <<'EOF'
CLAUDE_TIMEOUT_MINUTES=77
EOF
    # load_ralphrc returns early when .ralphrc is missing — that's correct
    # behavior, but it also means .ralphrc.local needs to be sourced from
    # the path we wired into load_ralphrc(). This test asserts the early-
    # return shape: with no .ralphrc, .ralphrc.local is NOT sourced.
    # Operators who only want overrides MUST also create an empty .ralphrc.
    local result
    result=$(_run_in_isolated_shell '_cli_CLAUDE_TIMEOUT_MINUTES=""; _env_CLAUDE_TIMEOUT_MINUTES=""' 'CLAUDE_TIMEOUT_MINUTES')
    # No .ralphrc → load_ralphrc returns before sourcing anything → falls
    # through to script default (CLAUDE_TIMEOUT_MINUTES=15 at ralph_loop.sh:239).
    [[ "$result" == "15" ]] \
        || { echo "expected 15 (script default — load_ralphrc returns early), got '$result'"; return 1; }
}

@test ".ralphrc.local variables auto-export to child processes" {
    cat > .ralphrc <<'EOF'
# (.ralphrc base values, no MY_PROBE_VAR)
EOF
    cat > .ralphrc.local <<'EOF'
MY_PROBE_VAR=propagated
EOF
    # The whole point of `set -a` around the .ralphrc.local source is that
    # vars like RALPH_ALLOW_PUSH_MAIN reach the hook subprocess. Verify by
    # checking that a probe variable appears in the *exported* environment
    # after load_ralphrc, not just in the shell-variable namespace.
    local result
    result=$(bash -c "
        set +e
        source '$RALPH_SCRIPT' >/dev/null 2>&1
        trap - EXIT SIGINT SIGTERM
        load_ralphrc >/dev/null 2>&1
        # If exported, it shows up in 'env'. If only a shell var, it does not.
        env | grep '^MY_PROBE_VAR=' || true
    " 2>/dev/null)
    [[ "$result" == "MY_PROBE_VAR=propagated" ]] \
        || { echo "expected exported var, got '$result'"; return 1; }
}
