#!/usr/bin/env bats
# TAP-1876: the interpreter -c | -e denial in templates/hooks/validate-command.sh
# must carry a one-line remediation pointing at file-based execution
# (`python3 /tmp/snippet.py` instead of `python3 -c "…"`). Without it, every
# loop that tries the blocked shape burns a tool call AND the next loop
# repeats the same shape because the denial message gives no out.

bats_require_minimum_version 1.5.0

PROJECT_ROOT="${BATS_TEST_DIRNAME}/../.."

setup() {
    export TEST_DIR="$(mktemp -d "${BATS_TEST_TMPDIR:-/tmp}/validate_cmd.XXXXXX")"
    mkdir -p "$TEST_DIR/.ralph"
    export CLAUDE_PROJECT_DIR="$TEST_DIR"
}

teardown() {
    rm -rf "$TEST_DIR" 2>/dev/null || true
}

# Run validate-command.sh with the given shell command in the tool_input JSON.
run_hook() {
    local cmd="$1"
    local payload
    payload=$(jq -cn --arg c "$cmd" '{tool_input:{command:$c}}')
    run bash -c 'echo "$1" | CLAUDE_PROJECT_DIR="$2" bash "$3/templates/hooks/validate-command.sh"' \
        bash "$payload" "$CLAUDE_PROJECT_DIR" "$PROJECT_ROOT"
}

# ---- BLOCK + remediation for each interpreter --------------------------------

@test "TAP-1876: python3 -c BLOCKS with file-based remediation" {
    run_hook 'python3 -c "import opentelemetry.sdk"'
    [[ "$status" -eq 2 ]] || fail "expected exit 2, got $status: $output"
    [[ "$output" == *"BLOCKED: python3 -c script-execution not allowed"* ]] \
        || fail "expected BLOCKED prefix, got: $output"
    [[ "$output" == *"/tmp/snippet.py"* ]] \
        || fail "remediation should suggest /tmp/snippet.py for python3: $output"
    [[ "$output" == *'"python3 /tmp/snippet.py"'* ]] \
        || fail "remediation should quote the file-based command for python3: $output"
}

@test "TAP-1876: python -c BLOCKS with file-based remediation" {
    run_hook 'python -c "import sys"'
    [[ "$status" -eq 2 ]] || fail "expected exit 2, got $status: $output"
    [[ "$output" == *"BLOCKED: python -c"* ]] \
        || fail "expected BLOCKED line for python, got: $output"
    [[ "$output" == *"/tmp/snippet.py"* ]] \
        || fail "remediation should suggest /tmp/snippet.py for python: $output"
}

@test "TAP-1876: node -e BLOCKS with file-based remediation" {
    run_hook 'node -e "console.log(process.version)"'
    [[ "$status" -eq 2 ]] || fail "expected exit 2, got $status: $output"
    [[ "$output" == *"BLOCKED: node -e"* ]] \
        || fail "expected BLOCKED line for node, got: $output"
    [[ "$output" == *"/tmp/snippet.js"* ]] \
        || fail "remediation should suggest /tmp/snippet.js for node: $output"
    [[ "$output" == *'"node /tmp/snippet.js"'* ]] \
        || fail "remediation should quote the file-based command for node: $output"
}

@test "TAP-1876: bash -c BLOCKS with file-based remediation" {
    run_hook 'bash -c "echo hi"'
    [[ "$status" -eq 2 ]] || fail "expected exit 2, got $status: $output"
    [[ "$output" == *"BLOCKED: bash -c"* ]] \
        || fail "expected BLOCKED line for bash, got: $output"
    [[ "$output" == *"/tmp/snippet.sh"* ]] \
        || fail "remediation should suggest /tmp/snippet.sh for bash: $output"
}

@test "TAP-1876: sh -c BLOCKS with file-based remediation" {
    run_hook 'sh -c "echo hi"'
    [[ "$status" -eq 2 ]] || fail "expected exit 2, got $status: $output"
    [[ "$output" == *"BLOCKED: sh -c"* ]] \
        || fail "expected BLOCKED line for sh, got: $output"
    [[ "$output" == *"/tmp/snippet.sh"* ]] \
        || fail "remediation should suggest /tmp/snippet.sh for sh: $output"
}

@test "TAP-1876: perl -e BLOCKS with file-based remediation" {
    run_hook 'perl -e "print 1"'
    [[ "$status" -eq 2 ]] || fail "expected exit 2, got $status: $output"
    [[ "$output" == *"BLOCKED: perl -e"* ]] \
        || fail "expected BLOCKED line for perl, got: $output"
    [[ "$output" == *"/tmp/snippet.pl"* ]] \
        || fail "remediation should suggest /tmp/snippet.pl for perl: $output"
}

@test "TAP-1876: ruby -e BLOCKS with file-based remediation" {
    run_hook 'ruby -e "puts 1"'
    [[ "$status" -eq 2 ]] || fail "expected exit 2, got $status: $output"
    [[ "$output" == *"BLOCKED: ruby -e"* ]] \
        || fail "expected BLOCKED line for ruby, got: $output"
    [[ "$output" == *"/tmp/snippet.rb"* ]] \
        || fail "remediation should suggest /tmp/snippet.rb for ruby: $output"
}

# ---- File-based execution must STILL be allowed (the remediation shape) ------

@test "TAP-1876: python3 /tmp/snippet.py is allowed (the remediation works)" {
    run_hook 'python3 /tmp/snippet.py'
    [[ "$status" -eq 0 ]] \
        || fail "file-based python3 must be allowed (or remediation is a lie), got $status: $output"
}

@test "TAP-1876: node /tmp/snippet.js is allowed (the remediation works)" {
    run_hook 'node /tmp/snippet.js'
    [[ "$status" -eq 0 ]] \
        || fail "file-based node must be allowed, got $status: $output"
}

# ---- TAP-2336: extended coverage (absolute path, versioned, wrappers) --------
# Loops #2-3 of the AgentForge 2026-05-21 campaign showed the original block
# was bypassable via /usr/bin/python3, python3.12, and uv run python — all
# now covered.

@test "TAP-2336: /usr/bin/python3 -c BLOCKS (basename normalization)" {
    run_hook '/usr/bin/python3 -c "import sys"'
    [[ "$status" -eq 2 ]] \
        || fail "absolute-path python3 -c must be blocked, got $status: $output"
    [[ "$output" == *"BLOCKED"* ]] \
        || fail "output must say BLOCKED: $output"
}

@test "TAP-2336: python3.12 -c BLOCKS (versioned interpreter)" {
    run_hook 'python3.12 -c "import sys"'
    [[ "$status" -eq 2 ]] \
        || fail "versioned python3.12 -c must be blocked, got $status: $output"
    [[ "$output" == *'/tmp/snippet.py'* ]] \
        || fail "remediation must point at /tmp/snippet.py: $output"
}

@test "TAP-2336: uv run python -c BLOCKS (uv wrapper)" {
    run_hook 'uv run python -c "import sys"'
    [[ "$status" -eq 2 ]] \
        || fail "uv run python -c must be blocked, got $status: $output"
    [[ "$output" == *'/tmp/snippet.py'* ]] \
        || fail "remediation must point at /tmp/snippet.py: $output"
}

@test "TAP-2336: poetry run python3 -c BLOCKS (poetry wrapper)" {
    run_hook 'poetry run python3 -c "print(1)"'
    [[ "$status" -eq 2 ]] \
        || fail "poetry run python3 -c must be blocked, got $status: $output"
}

@test "TAP-2336: uv run pytest is allowed (not -c / -e)" {
    run_hook 'uv run pytest tests/'
    [[ "$status" -eq 0 ]] \
        || fail "uv run pytest must be allowed, got $status: $output"
}

@test "TAP-2336: uv run python /tmp/snippet.py is allowed (file-based path)" {
    run_hook 'uv run python /tmp/snippet.py'
    [[ "$status" -eq 0 ]] \
        || fail "uv run with file-based python must be allowed, got $status: $output"
}

# ---- R0-harness: refuse direct push to main / master ------------------------
# AgentForge 2026-05-21 had 13/20 commits push direct to main. The skill's R0
# rule (prose) was added in the prior PR; this is the harness-side enforcement
# that catches the case Claude's prose discipline misses.

@test "R0-harness: git push origin main BLOCKS" {
    run_hook 'git push origin main'
    [[ "$status" -eq 2 ]] \
        || fail "git push origin main must be blocked, got $status: $output"
    [[ "$output" == *"direct push to main forbidden"* ]] \
        || fail "expected R0 BLOCKED line, got: $output"
    [[ "$output" == *"feature branch"* ]] \
        || fail "remediation must mention feature branch: $output"
}

@test "R0-harness: git push origin master BLOCKS" {
    run_hook 'git push origin master'
    [[ "$status" -eq 2 ]] \
        || fail "git push origin master must be blocked, got $status: $output"
}

@test "R0-harness: git push origin HEAD:main BLOCKS" {
    run_hook 'git push origin HEAD:main'
    [[ "$status" -eq 2 ]] \
        || fail "HEAD:main refspec must be blocked, got $status: $output"
}

@test "R0-harness: git push origin <branch>:main BLOCKS" {
    run_hook 'git push origin fix/foo:main'
    [[ "$status" -eq 2 ]] \
        || fail "branch:main refspec must be blocked, got $status: $output"
}

@test "R0-harness: git push --tags origin main BLOCKS" {
    run_hook 'git push --tags origin main'
    [[ "$status" -eq 2 ]] \
        || fail "push with flags before main must still be blocked, got $status: $output"
}

@test "R0-harness: git push -u origin <feature-branch> is allowed" {
    run_hook 'git push -u origin fix/feature-x'
    [[ "$status" -eq 0 ]] \
        || fail "feature-branch push must be allowed, got $status: $output"
}

@test "R0-harness: git push origin --delete <branch> is allowed" {
    run_hook 'git push origin --delete fix/old-branch'
    [[ "$status" -eq 0 ]] \
        || fail "branch delete must be allowed, got $status: $output"
}

@test "R0-harness: git push origin <branch>:<branch> (same name) is allowed" {
    run_hook 'git push origin fix/foo:fix/foo'
    [[ "$status" -eq 0 ]] \
        || fail "same-name refspec must be allowed, got $status: $output"
}

@test "R0-harness: git push with no args is allowed" {
    run_hook 'git push'
    [[ "$status" -eq 0 ]] \
        || fail "bare git push must be allowed, got $status: $output"
}

@test "R0-harness: git fetch / pull main is NOT blocked (read-only)" {
    run_hook 'git fetch origin main'
    [[ "$status" -eq 0 ]] \
        || fail "git fetch must be allowed, got $status: $output"
    run_hook 'git pull origin main'
    [[ "$status" -eq 0 ]] \
        || fail "git pull must be allowed, got $status: $output"
}

@test "R0-harness: RALPH_ALLOW_PUSH_MAIN=1 bypasses the block" {
    # Re-invoke the hook with the env var set (run_hook doesn't propagate
    # arbitrary env vars, so we use bash -c directly).
    local payload
    payload=$(jq -cn '{tool_input:{command:"git push origin main"}}')
    run bash -c '
        echo "$1" | RALPH_ALLOW_PUSH_MAIN=1 CLAUDE_PROJECT_DIR="$2" \
            bash "$3/templates/hooks/validate-command.sh"
    ' bash "$payload" "$CLAUDE_PROJECT_DIR" "$PROJECT_ROOT"
    [[ "$status" -eq 0 ]] \
        || fail "RALPH_ALLOW_PUSH_MAIN=1 should bypass, got $status: $output"
}

# ---- python-introspection skill ships with the templates ---------------------

@test "TAP-1876: python-introspection SKILL.md exists in templates/skills/global/" {
    [[ -f "$PROJECT_ROOT/templates/skills/global/python-introspection/SKILL.md" ]] \
        || fail "python-introspection skill not shipped"
}

@test "TAP-1876: python-introspection SKILL.md describes file-based remediation" {
    local p="$PROJECT_ROOT/templates/skills/global/python-introspection/SKILL.md"
    grep -q '/tmp/snippet.py' "$p" \
        || fail "SKILL.md should reference /tmp/snippet.py"
    grep -qE 'python3? */tmp/' "$p" \
        || fail "SKILL.md should show the file-based python invocation"
}

@test "TAP-1876: python-introspection ships at least one example" {
    local ex_dir="$PROJECT_ROOT/templates/skills/global/python-introspection/examples"
    [[ -d "$ex_dir" ]] || fail "examples/ dir missing"
    local count
    count=$(find "$ex_dir" -maxdepth 1 -name '*.md' -type f | wc -l | tr -d '[:space:]')
    [[ "$count" -ge 1 ]] || fail "expected ≥1 example, got $count"
}

# ---- skill_retro.sh registers python-introspection as a recommendation -------

@test "TAP-1876: skill_retro_detect_friction recommends python-introspection on ≥3 interpreter denials" {
    # Build a minimal ralph.log with 3 BLOCKED denial lines + a status.json.
    mkdir -p "$TEST_DIR/.ralph/logs"
    cat > "$TEST_DIR/.ralph/logs/ralph.log" <<'EOF'
[2026-05-16T00:00:00Z] BLOCKED: python3 -c script-execution not allowed. Write the snippet to /tmp/snippet.py
[2026-05-16T00:00:01Z] BLOCKED: python3 -c script-execution not allowed. Write the snippet to /tmp/snippet.py
[2026-05-16T00:00:02Z] BLOCKED: python3 -c script-execution not allowed. Write the snippet to /tmp/snippet.py
EOF
    cat > "$TEST_DIR/.ralph/status.json" <<'EOF'
{"loop_count": 5, "tasks_completed": 0, "files_modified": 0, "work_type": "IMPLEMENTATION"}
EOF
    export RALPH_DIR="$TEST_DIR/.ralph"

    # shellcheck disable=SC1090
    source "$PROJECT_ROOT/lib/skill_retro.sh"
    run skill_retro_detect_friction
    [[ "$status" -eq 0 ]] || fail "friction detector exited non-zero: $output"
    echo "$output" | jq -e '.recommended_skills | index("python-introspection")' >/dev/null \
        || fail "expected python-introspection in recommended_skills, got: $output"
    echo "$output" | jq -e '.friction_signals[] | select(.type=="interpreter_dash_c_denials")' >/dev/null \
        || fail "expected interpreter_dash_c_denials signal, got: $output"
}

@test "TAP-1876: skill_retro_detect_friction does NOT recommend python-introspection with <3 denials" {
    mkdir -p "$TEST_DIR/.ralph/logs"
    cat > "$TEST_DIR/.ralph/logs/ralph.log" <<'EOF'
[2026-05-16T00:00:00Z] BLOCKED: python3 -c script-execution not allowed.
[2026-05-16T00:00:01Z] BLOCKED: python3 -c script-execution not allowed.
EOF
    cat > "$TEST_DIR/.ralph/status.json" <<'EOF'
{"loop_count": 5, "tasks_completed": 1, "files_modified": 1, "work_type": "IMPLEMENTATION"}
EOF
    export RALPH_DIR="$TEST_DIR/.ralph"

    # shellcheck disable=SC1090
    source "$PROJECT_ROOT/lib/skill_retro.sh"
    run skill_retro_detect_friction
    [[ "$status" -eq 0 ]] || fail "friction detector exited non-zero: $output"
    if echo "$output" | jq -e '.recommended_skills | index("python-introspection")' >/dev/null 2>&1; then
        fail "python-introspection should NOT trigger at 2 denials (threshold is 3): $output"
    fi
}

# ---- TAP-2344: global ~/.ralph/ is no longer blocked (Bash redirect side) ---
# F3 of the AgentForge 2026-05-22 campaign: the unanchored `*/.ralph/*` glob
# blocked global hotfix workflows. _is_protected_path now anchors .ralph/ to
# $RALPH_DIR. .claude/ stays globally blocked by design (its global state
# affects every Claude Code session).

@test "TAP-2344: redirect to project .ralph/foo BLOCKS" {
    run_hook "echo x > $CLAUDE_PROJECT_DIR/.ralph/foo.md"
    [[ "$status" -eq 2 ]] \
        || fail "project .ralph/foo redirect must be blocked, got $status: $output"
}

@test "TAP-2344: redirect to relative .ralph/foo BLOCKS" {
    run_hook "echo x > .ralph/foo.md"
    [[ "$status" -eq 2 ]] \
        || fail "relative .ralph/foo redirect must be blocked, got $status: $output"
}

@test "TAP-2344: redirect to ~/.ralph/lib/foo.sh is ALLOWED (outside project)" {
    # Use a tmpdir simulating ~/ that is OUTSIDE CLAUDE_PROJECT_DIR.
    mkdir -p "$TEST_DIR/global_home/.ralph/lib"
    run_hook "echo x > $TEST_DIR/global_home/.ralph/lib/foo.sh"
    [[ "$status" -eq 0 ]] \
        || fail "global ~/.ralph/lib redirect must be allowed, got $status: $output"
}

@test "TAP-2344: cp to project .ralph/foo BLOCKS" {
    run_hook "cp /tmp/x $CLAUDE_PROJECT_DIR/.ralph/foo"
    [[ "$status" -eq 2 ]] \
        || fail "cp into project .ralph/ must be blocked, got $status: $output"
}

@test "TAP-2344: cp to ~/.ralph/foo from inside a project is ALLOWED" {
    mkdir -p "$TEST_DIR/global_home/.ralph"
    run_hook "cp /tmp/x $TEST_DIR/global_home/.ralph/foo"
    [[ "$status" -eq 0 ]] \
        || fail "cp into global ~/.ralph must be allowed, got $status: $output"
}

@test "TAP-2344: mv into ~/.ralph/lib/ is ALLOWED from inside a project" {
    mkdir -p "$TEST_DIR/global_home/.ralph/lib"
    run_hook "mv /tmp/foo $TEST_DIR/global_home/.ralph/lib/foo"
    [[ "$status" -eq 0 ]] \
        || fail "mv into global ~/.ralph/lib must be allowed, got $status: $output"
}

@test "TAP-2344: redirect to .claude/anything (relative) is STILL blocked" {
    # .claude/ stays blocked at the relative-path layer per the F3 ticket's
    # "Why" note — mutating ~/.claude/settings.json from inside one project
    # would affect every Claude Code session. Absolute-path redirects to
    # .claude/ are a pre-existing gap NOT in F3 scope.
    run_hook "echo x > .claude/settings.json"
    [[ "$status" -eq 2 ]] \
        || fail ".claude/* relative redirect must still be blocked, got $status: $output"
}

@test "TAP-2344: project .ralphrc redirect BLOCKS" {
    run_hook "echo x > $CLAUDE_PROJECT_DIR/.ralphrc"
    [[ "$status" -eq 2 ]] \
        || fail "project .ralphrc redirect must be blocked, got $status: $output"
}

@test "TAP-2344: relative .ralphrc redirect BLOCKS" {
    run_hook "echo x > .ralphrc"
    [[ "$status" -eq 2 ]] \
        || fail "relative .ralphrc redirect must be blocked, got $status: $output"
}

# ---- TAP-2599: transient Linear cache carve-out ------------------------------
# Ralph's task selector self-manages .ralph/.linear_next_issue (the
# ralph-workflow skill tells the agent to `rm -f` it after honoring a
# locality hint). The blanket .ralph/ protection used to cancel that tool
# call every loop. The carve-out allows the transient hint to be removed
# while durable state stays protected.

@test "TAP-2599: rm of .ralph/.linear_next_issue is ALLOWED (relative)" {
    run_hook 'rm -f .ralph/.linear_next_issue'
    [[ "$status" -eq 0 ]] \
        || fail "transient hint rm must be allowed, got $status: $output"
}

@test "TAP-2599: rm of .ralph/.linear_next_issue is ALLOWED (absolute)" {
    run_hook "rm -f $TEST_DIR/.ralph/.linear_next_issue"
    [[ "$status" -eq 0 ]] \
        || fail "transient hint rm (abs path) must be allowed, got $status: $output"
}

@test "TAP-2599: mv of .ralph/.linear_next_issue is ALLOWED" {
    run_hook 'mv .ralph/.linear_next_issue /tmp/x'
    [[ "$status" -eq 0 ]] \
        || fail "transient hint mv must be allowed, got $status: $output"
}

@test "TAP-2599: clobber of .ralph/status.json is STILL BLOCKED" {
    run_hook 'rm -f .ralph/status.json'
    [[ "$status" -eq 2 ]] \
        || fail "durable status.json must stay protected, got $status: $output"
}

@test "TAP-2599: redirect into .ralph/status.json is STILL BLOCKED" {
    run_hook 'echo x > .ralph/status.json'
    [[ "$status" -eq 2 ]] \
        || fail "redirect into status.json must stay protected, got $status: $output"
}

@test "TAP-2599: clobber of .ralph/.circuit_breaker_state is STILL BLOCKED" {
    run_hook 'cp foo .ralph/.circuit_breaker_state'
    [[ "$status" -eq 2 ]] \
        || fail "durable circuit-breaker state must stay protected, got $status: $output"
}

# ---- TAP-2345: Bash/Edit policy parity on .claude/ subdirs ------------------
# validate-command.sh (Bash side) carves out .claude/rules/, .claude/skills/,
# and .claude/commands/ so routine rule/skill/command writes stop being a
# dead-end that forces a pivot to the Write tool — matching the Edit-side
# carve-outs in protect-ralph-files.sh. settings*.json, agents/, and hooks/
# stay blocked on both sides. Source friction: AgentForge 2026-05-22, F4.

@test "TAP-2345: redirect to .claude/rules/foo.md via Bash is ALLOWED" {
    run_hook "echo x > .claude/rules/foo.md"
    [[ "$status" -eq 0 ]] \
        || fail ".claude/rules/* redirect must be allowed via Bash, got $status: $output"
}

@test "TAP-2345: redirect to .claude/skills/foo/SKILL.md via Bash is ALLOWED" {
    run_hook "echo x > .claude/skills/foo/SKILL.md"
    [[ "$status" -eq 0 ]] \
        || fail ".claude/skills/* redirect must be allowed via Bash, got $status: $output"
}

@test "TAP-2345: redirect to .claude/commands/foo.md via Bash is ALLOWED" {
    run_hook "echo x > .claude/commands/foo.md"
    [[ "$status" -eq 0 ]] \
        || fail ".claude/commands/* redirect must be allowed via Bash, got $status: $output"
}

@test "TAP-2345: cp into .claude/rules/ via Bash is ALLOWED" {
    run_hook "cp /tmp/x .claude/rules/foo.md"
    [[ "$status" -eq 0 ]] \
        || fail "cp into .claude/rules/ must be allowed via Bash, got $status: $output"
}

@test "TAP-2345: redirect to .claude/agents/ralph.md via Bash is STILL BLOCKED" {
    run_hook "echo x > .claude/agents/ralph.md"
    [[ "$status" -eq 2 ]] \
        || fail ".claude/agents/ must stay blocked via Bash, got $status: $output"
}

@test "TAP-2345: redirect to .claude/hooks/on-stop.sh via Bash is STILL BLOCKED" {
    run_hook "echo x > .claude/hooks/on-stop.sh"
    [[ "$status" -eq 2 ]] \
        || fail ".claude/hooks/ must stay blocked via Bash, got $status: $output"
}

@test "TAP-2345: redirect to .claude/settings.json via Bash is STILL BLOCKED" {
    run_hook "echo x > .claude/settings.json"
    [[ "$status" -eq 2 ]] \
        || fail ".claude/settings.json must stay blocked via Bash, got $status: $output"
}

@test "TAP-2345: cp into .claude/hooks/ via Bash is STILL BLOCKED" {
    run_hook "cp /tmp/x .claude/hooks/on-stop.sh"
    [[ "$status" -eq 2 ]] \
        || fail "cp into .claude/hooks/ must stay blocked via Bash, got $status: $output"
}

# ---- byte parity guard (TAP-1876 amendment to the TAP-624 parity rule) -------

@test "TAP-1876: .ralph/hooks/validate-command.sh is byte-identical to template" {
    # Defense in depth — TAP-624 already enforces this for the original
    # template, but the TAP-1876 edit touched both files; this test
    # documents the parity expectation specifically for this change.
    diff "$PROJECT_ROOT/templates/hooks/validate-command.sh" \
         "$PROJECT_ROOT/.ralph/hooks/validate-command.sh"
}
