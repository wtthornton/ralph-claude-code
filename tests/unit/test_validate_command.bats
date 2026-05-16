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

# ---- byte parity guard (TAP-1876 amendment to the TAP-624 parity rule) -------

@test "TAP-1876: .ralph/hooks/validate-command.sh is byte-identical to template" {
    # Defense in depth — TAP-624 already enforces this for the original
    # template, but the TAP-1876 edit touched both files; this test
    # documents the parity expectation specifically for this change.
    diff "$PROJECT_ROOT/templates/hooks/validate-command.sh" \
         "$PROJECT_ROOT/.ralph/hooks/validate-command.sh"
}
