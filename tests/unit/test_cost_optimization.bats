#!/usr/bin/env bats

# Tests for COSTROUTE-3 (prompt cache optimization) and COSTROUTE-4 (cost dashboard)

setup() {
    export RALPH_DIR="$BATS_TEST_TMPDIR/.ralph"
    export RALPH_VERBOSE="false"
    mkdir -p "$RALPH_DIR"
}

teardown() {
    rm -rf "$BATS_TEST_TMPDIR/.ralph"
}

# =============================================================================
# COSTROUTE-3: Prompt Cache Optimization
# =============================================================================

@test "COSTROUTE-3: ralph_build_cacheable_prompt returns 1 when disabled" {
    export RALPH_PROMPT_CACHE_ENABLED="false"
    source "$BATS_TEST_DIRNAME/../../lib/complexity.sh"
    run ralph_build_cacheable_prompt
    [[ "$status" -eq 1 ]]
}

@test "COSTROUTE-3: ralph_build_cacheable_prompt returns 1 when PROMPT.md missing" {
    export RALPH_PROMPT_CACHE_ENABLED="true"
    source "$BATS_TEST_DIRNAME/../../lib/complexity.sh"
    run ralph_build_cacheable_prompt
    [[ "$status" -eq 1 ]]
}

@test "COSTROUTE-3: ralph_build_cacheable_prompt includes PROMPT.md content" {
    export RALPH_PROMPT_CACHE_ENABLED="true"
    echo "# My Project Prompt" > "$RALPH_DIR/PROMPT.md"
    source "$BATS_TEST_DIRNAME/../../lib/complexity.sh"
    result=$(ralph_build_cacheable_prompt)
    [[ "$result" == *"# My Project Prompt"* ]]
}

@test "COSTROUTE-3: ralph_build_cacheable_prompt includes AGENT.md when present" {
    export RALPH_PROMPT_CACHE_ENABLED="true"
    echo "# Prompt" > "$RALPH_DIR/PROMPT.md"
    echo "# Build instructions" > "$RALPH_DIR/AGENT.md"
    source "$BATS_TEST_DIRNAME/../../lib/complexity.sh"
    result=$(ralph_build_cacheable_prompt)
    [[ "$result" == *"Build & Run Instructions"* ]]
    [[ "$result" == *"# Build instructions"* ]]
}

@test "COSTROUTE-3: ralph_build_cacheable_prompt includes cache boundary marker" {
    export RALPH_PROMPT_CACHE_ENABLED="true"
    echo "# Prompt" > "$RALPH_DIR/PROMPT.md"
    source "$BATS_TEST_DIRNAME/../../lib/complexity.sh"
    result=$(ralph_build_cacheable_prompt)
    [[ "$result" == *"Current Iteration Context"* ]]
}

@test "COSTROUTE-3: ralph_build_cacheable_prompt includes loop iteration" {
    export RALPH_PROMPT_CACHE_ENABLED="true"
    echo "# Prompt" > "$RALPH_DIR/PROMPT.md"
    echo '{"loop_count": 5}' > "$RALPH_DIR/status.json"
    source "$BATS_TEST_DIRNAME/../../lib/complexity.sh"
    result=$(ralph_build_cacheable_prompt)
    [[ "$result" == *"Loop iteration: 5"* ]]
}

@test "COSTROUTE-3: ralph_build_cacheable_prompt includes task progress" {
    export RALPH_PROMPT_CACHE_ENABLED="true"
    echo "# Prompt" > "$RALPH_DIR/PROMPT.md"
    cat > "$RALPH_DIR/fix_plan.md" <<'PLAN'
## Tasks
- [x] Task 1
- [x] Task 2
- [ ] Task 3
- [ ] Task 4
PLAN
    source "$BATS_TEST_DIRNAME/../../lib/complexity.sh"
    result=$(ralph_build_cacheable_prompt)
    [[ "$result" == *"Tasks: 2/4 complete, 2 remaining"* ]]
}

@test "COSTROUTE-3: stable prefix hash is consistent" {
    source "$BATS_TEST_DIRNAME/../../lib/complexity.sh"
    echo "# Test Prompt" > "$RALPH_DIR/PROMPT.md"
    echo "# Build instructions" > "$RALPH_DIR/AGENT.md"

    hash1=$(ralph_get_stable_prefix_hash)
    hash2=$(ralph_get_stable_prefix_hash)
    [[ "$hash1" == "$hash2" ]]
}

@test "COSTROUTE-3: stable prefix hash changes when PROMPT.md changes" {
    source "$BATS_TEST_DIRNAME/../../lib/complexity.sh"
    echo "# Version 1" > "$RALPH_DIR/PROMPT.md"
    hash1=$(ralph_get_stable_prefix_hash)

    echo "# Version 2 - changed" > "$RALPH_DIR/PROMPT.md"
    hash2=$(ralph_get_stable_prefix_hash)
    [[ "$hash1" != "$hash2" ]]
}

@test "COSTROUTE-3: stable prefix hash is non-empty" {
    source "$BATS_TEST_DIRNAME/../../lib/complexity.sh"
    echo "# Prompt" > "$RALPH_DIR/PROMPT.md"
    hash=$(ralph_get_stable_prefix_hash)
    [[ -n "$hash" ]]
}

# =============================================================================
# COSTROUTE-4: Cost Dashboard
# =============================================================================

@test "COSTROUTE-4: cost dashboard outputs valid JSON" {
    source "$BATS_TEST_DIRNAME/../../lib/tracing.sh" 2>/dev/null || true
    source "$BATS_TEST_DIRNAME/../../lib/metrics.sh"
    export TRACE_DIR="$RALPH_DIR/traces"
    mkdir -p "$RALPH_DIR/traces" "$RALPH_DIR/metrics"

    # Create sample cost data
    echo '{"timestamp":"2026-03-23","model":"sonnet","input_tokens":5000,"output_tokens":2000,"cost_usd":0.045,"trace_id":"abc","loop_count":1}' > "$RALPH_DIR/traces/costs.jsonl"

    result=$(ralph_show_cost_dashboard --json)
    echo "$result" | jq . >/dev/null 2>&1
    [[ "$(echo "$result" | jq -r '.total_iterations')" -ge 0 ]]
}

@test "COSTROUTE-4: cost dashboard JSON includes all required fields" {
    source "$BATS_TEST_DIRNAME/../../lib/tracing.sh" 2>/dev/null || true
    source "$BATS_TEST_DIRNAME/../../lib/metrics.sh"
    mkdir -p "$RALPH_DIR/traces" "$RALPH_DIR/metrics"

    echo '{"timestamp":"2026-03-23","model":"sonnet","input_tokens":5000,"output_tokens":2000,"cost_usd":0.045,"trace_id":"abc","loop_count":1}' > "$RALPH_DIR/traces/costs.jsonl"

    result=$(ralph_show_cost_dashboard --json)
    [[ "$(echo "$result" | jq 'has("total_cost_usd")')" == "true" ]]
    [[ "$(echo "$result" | jq 'has("total_input_tokens")')" == "true" ]]
    [[ "$(echo "$result" | jq 'has("total_output_tokens")')" == "true" ]]
    [[ "$(echo "$result" | jq 'has("total_iterations")')" == "true" ]]
    [[ "$(echo "$result" | jq 'has("cost_per_iteration")')" == "true" ]]
    [[ "$(echo "$result" | jq 'has("budget_usd")')" == "true" ]]
    [[ "$(echo "$result" | jq 'has("budget_used_pct")')" == "true" ]]
    [[ "$(echo "$result" | jq 'has("by_model")')" == "true" ]]
}

@test "COSTROUTE-4: cost dashboard computes correct totals" {
    source "$BATS_TEST_DIRNAME/../../lib/tracing.sh" 2>/dev/null || true
    source "$BATS_TEST_DIRNAME/../../lib/metrics.sh"
    mkdir -p "$RALPH_DIR/traces" "$RALPH_DIR/metrics"

    cat > "$RALPH_DIR/traces/costs.jsonl" <<'EOF'
{"timestamp":"2026-03-23","model":"sonnet","input_tokens":5000,"output_tokens":2000,"cost_usd":0.045,"trace_id":"abc","loop_count":1}
{"timestamp":"2026-03-23","model":"sonnet","input_tokens":3000,"output_tokens":1000,"cost_usd":0.025,"trace_id":"def","loop_count":2}
EOF

    result=$(ralph_show_cost_dashboard --json)
    total_cost=$(echo "$result" | jq -r '.total_cost_usd')
    total_input=$(echo "$result" | jq -r '.total_input_tokens')
    total_output=$(echo "$result" | jq -r '.total_output_tokens')

    # 0.045 + 0.025 = 0.07
    [[ "$total_cost" == "0.07" ]]
    [[ "$total_input" == "8000" ]]
    [[ "$total_output" == "3000" ]]
}

@test "COSTROUTE-4: cost dashboard human output contains header" {
    source "$BATS_TEST_DIRNAME/../../lib/tracing.sh" 2>/dev/null || true
    source "$BATS_TEST_DIRNAME/../../lib/metrics.sh"
    mkdir -p "$RALPH_DIR/traces" "$RALPH_DIR/metrics"

    result=$(ralph_show_cost_dashboard)
    [[ "$result" == *"Ralph Cost Dashboard"* ]]
    [[ "$result" == *"===================="* ]]
}

@test "COSTROUTE-4: cost dashboard shows budget info when set" {
    export RALPH_COST_BUDGET_USD="10"
    source "$BATS_TEST_DIRNAME/../../lib/tracing.sh" 2>/dev/null || true
    source "$BATS_TEST_DIRNAME/../../lib/metrics.sh"
    mkdir -p "$RALPH_DIR/traces" "$RALPH_DIR/metrics"

    echo '{"timestamp":"2026-03-23","model":"sonnet","input_tokens":5000,"output_tokens":2000,"cost_usd":1.00,"trace_id":"abc","loop_count":1}' > "$RALPH_DIR/traces/costs.jsonl"

    result=$(ralph_show_cost_dashboard)
    [[ "$result" == *"Budget:"* ]]
    [[ "$result" == *"10"* ]]
}

@test "COSTROUTE-4: cost dashboard JSON includes budget percentage" {
    export RALPH_COST_BUDGET_USD="10"
    source "$BATS_TEST_DIRNAME/../../lib/tracing.sh" 2>/dev/null || true
    source "$BATS_TEST_DIRNAME/../../lib/metrics.sh"
    mkdir -p "$RALPH_DIR/traces" "$RALPH_DIR/metrics"

    echo '{"timestamp":"2026-03-23","model":"sonnet","input_tokens":5000,"output_tokens":2000,"cost_usd":5.00,"trace_id":"abc","loop_count":1}' > "$RALPH_DIR/traces/costs.jsonl"

    result=$(ralph_show_cost_dashboard --json)
    pct=$(echo "$result" | jq -r '.budget_used_pct')
    [[ "$pct" == "50" ]]
}

@test "COSTROUTE-4: cost dashboard handles no data gracefully" {
    source "$BATS_TEST_DIRNAME/../../lib/tracing.sh" 2>/dev/null || true
    source "$BATS_TEST_DIRNAME/../../lib/metrics.sh"
    mkdir -p "$RALPH_DIR/traces" "$RALPH_DIR/metrics"

    result=$(ralph_show_cost_dashboard --json)
    echo "$result" | jq . >/dev/null 2>&1
    [[ "$(echo "$result" | jq -r '.total_cost_usd')" == "0" ]]
    [[ "$(echo "$result" | jq -r '.total_iterations')" == "0" ]]
}

@test "COSTROUTE-4: cost dashboard model breakdown groups by model" {
    source "$BATS_TEST_DIRNAME/../../lib/tracing.sh" 2>/dev/null || true
    source "$BATS_TEST_DIRNAME/../../lib/metrics.sh"
    mkdir -p "$RALPH_DIR/traces" "$RALPH_DIR/metrics"

    cat > "$RALPH_DIR/traces/costs.jsonl" <<'EOF'
{"timestamp":"2026-03-23","model":"sonnet","input_tokens":5000,"output_tokens":2000,"cost_usd":0.045,"trace_id":"abc","loop_count":1}
{"timestamp":"2026-03-23","model":"haiku","input_tokens":1000,"output_tokens":500,"cost_usd":0.005,"trace_id":"def","loop_count":2}
{"timestamp":"2026-03-23","model":"sonnet","input_tokens":3000,"output_tokens":1000,"cost_usd":0.025,"trace_id":"ghi","loop_count":3}
EOF

    result=$(ralph_show_cost_dashboard --json)
    model_count=$(echo "$result" | jq '.by_model | length')
    [[ "$model_count" -eq 2 ]]

    # sonnet should have 2 entries
    sonnet_iters=$(echo "$result" | jq '[.by_model[] | select(.model == "sonnet")] | .[0].iterations')
    [[ "$sonnet_iters" == "2" ]]
}
