#!/usr/bin/env bats
# Unit Tests for TAP-672: ralph_import.sh::parse_conversion_response must reject
# empty-but-valid JSON envelopes instead of treating them as success.

load '../helpers/test_helper'

RALPH_IMPORT="${BATS_TEST_DIRNAME}/../../ralph_import.sh"

setup() {
    export TEST_TEMP_DIR="$(mktemp -d)"
    cd "$TEST_TEMP_DIR"

    # Extract just parse_conversion_response and its top-level PARSED_* state
    # via awk brace counting. Avoids running ralph_import.sh's main.
    awk '
        /^declare PARSED_/ { print; next }
        /^parse_conversion_response\(\)/ { in_fn = 1 }
        in_fn {
            print
            for (i = 1; i <= length($0); i++) {
                c = substr($0, i, 1)
                if (c == "{") depth++
                else if (c == "}") {
                    depth--
                    if (depth == 0 && found_open) { exit }
                }
            }
            if (depth > 0) found_open = 1
        }
    ' "$RALPH_IMPORT" > /tmp/parse_fn_$$.sh

    # Stub `log` — ralph_import.sh defines it, but we haven't sourced it
    log() { :; }
    export -f log

    # shellcheck disable=SC1091
    source /tmp/parse_fn_$$.sh
    rm -f /tmp/parse_fn_$$.sh
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR"
}

@test "TAP-672: empty JSON envelope {} is rejected" {
    echo '{}' > response.json
    run parse_conversion_response response.json
    [ "$status" -eq 1 ]
}

@test "TAP-672: {\"success\":true} envelope with no work signals is rejected" {
    cat > response.json <<'EOF'
{"success": true}
EOF
    run parse_conversion_response response.json
    [ "$status" -eq 1 ]
}

@test "TAP-672: response with non-empty result is accepted" {
    cat > response.json <<'EOF'
{
    "result": "Converted PRD to Ralph tasks",
    "metadata": {
        "files_changed": 2,
        "files_created": [".ralph/PROMPT.md", ".ralph/fix_plan.md"]
    }
}
EOF
    run parse_conversion_response response.json
    [ "$status" -eq 0 ]
}

@test "TAP-672: response with files_created populated but empty result is accepted" {
    cat > response.json <<'EOF'
{
    "metadata": {
        "files_created": [".ralph/PROMPT.md"]
    }
}
EOF
    run parse_conversion_response response.json
    [ "$status" -eq 0 ]
}

@test "TAP-672: non-array files_created (malformed shape) is rejected" {
    cat > response.json <<'EOF'
{
    "result": "work done",
    "metadata": {
        "files_created": "not-an-array"
    }
}
EOF
    run parse_conversion_response response.json
    [ "$status" -eq 1 ]
}

@test "TAP-672: invalid top-level JSON still rejected (baseline)" {
    echo 'not json at all' > response.json
    run parse_conversion_response response.json
    [ "$status" -eq 1 ]
}
