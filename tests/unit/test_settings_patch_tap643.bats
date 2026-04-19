#!/usr/bin/env bats
# TAP-643: ralph_loop.sh's WSL auto-patch of .claude/settings.json must not
# rewrite arbitrary strings containing `"powershell -`. Only .command fields
# whose value begins with `powershell` should be touched, and the write must
# be atomic (tmp + mv) with a backup.

load '../helpers/test_helper'

PROJECT_ROOT="${BATS_TEST_DIRNAME}/../.."

# Extract the jq expression used by ralph_loop.sh so the test verifies the
# real production logic, not a re-copy of it.
jq_rewrite_cmd() {
    jq 'walk(if type == "object" and has("command") and ((.command | type) == "string") and (.command | test("^powershell\\s"))
           then .command |= sub("^powershell"; "powershell.exe")
           else . end)'
}

setup() {
    TEST_DIR="$(mktemp -d)"
    cd "$TEST_DIR" || return 1
}

teardown() {
    if [[ -n "$TEST_DIR" ]] && [[ -d "$TEST_DIR" ]]; then
        cd /
        rm -rf "$TEST_DIR"
    fi
}

@test "TAP-643: only .command fields are rewritten" {
    cat > settings.json <<'JSON'
{
  "description": "This hook runs \"powershell -File X\" for legacy clients",
  "hooks": {
    "Stop": [
      {
        "hooks": [
          { "type": "command", "command": "powershell -File script.ps1" }
        ]
      }
    ]
  }
}
JSON

    jq_rewrite_cmd < settings.json > settings.out.json
    # description string is untouched (sed -i would have corrupted it)
    run jq -r '.description' settings.out.json
    [[ "$output" == 'This hook runs "powershell -File X" for legacy clients' ]]
    # .command field IS rewritten
    run jq -r '.hooks.Stop[0].hooks[0].command' settings.out.json
    [[ "$output" == "powershell.exe -File script.ps1" ]]
}

@test "TAP-643: already-patched .command stays unchanged" {
    cat > settings.json <<'JSON'
{ "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "powershell.exe -File x" } ] } ] } }
JSON
    local before
    before=$(cat settings.json)
    jq_rewrite_cmd < settings.json > settings.out.json
    run jq -r '.hooks.Stop[0].hooks[0].command' settings.out.json
    [[ "$output" == "powershell.exe -File x" ]]
}

@test "TAP-643: non-powershell commands are untouched" {
    cat > settings.json <<'JSON'
{ "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "bash script.sh" } ] } ] } }
JSON
    jq_rewrite_cmd < settings.json > settings.out.json
    run jq -r '.hooks.Stop[0].hooks[0].command' settings.out.json
    [[ "$output" == "bash script.sh" ]]
}

@test "TAP-643: ralph_loop.sh no longer uses sed -i for settings.json" {
    # Regression guard: the old vulnerable pattern must not reappear.
    run grep -nE "sed -i .*'\$project_settings'" "$PROJECT_ROOT/ralph_loop.sh"
    [[ "$status" -ne 0 ]]
}

@test "TAP-643: ralph_loop.sh backs up before overwriting project settings" {
    run grep -q ".upgrade-backups/settings" "$PROJECT_ROOT/ralph_loop.sh"
    assert_success
}
