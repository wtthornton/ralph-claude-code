# Story EVALS-1: Golden-File Test Infrastructure

**Epic:** [Agent Evaluation Framework](epic-agent-evals.md)
**Priority:** Medium
**Status:** Open
**Effort:** Medium
**Component:** new `tests/evals/`, new `tests/evals/golden/`

---

## Problem

No baseline exists for "correct" agent behavior. When Ralph's agent definition, hooks, or prompt structure change, there's no way to verify that agent behavior hasn't regressed.

## Solution

Create infrastructure for recording successful agent runs as golden files and comparing new runs against them.

## Implementation

### Golden file format

```json
{
    "id": "eval-001-simple-fix",
    "description": "Fix a typo in a single file",
    "recorded_at": "2026-03-22T14:00:00Z",
    "ralph_version": "2.0.0",
    "input": {
        "fix_plan_task": "Fix typo 'recieve' -> 'receive' in lib/utils.sh",
        "project_type": "bash",
        "file_count": 1
    },
    "expected": {
        "exit_signal": true,
        "work_type": "IMPLEMENTATION",
        "files_modified": ["lib/utils.sh"],
        "tool_sequence_contains": ["Read", "Edit"],
        "tool_sequence_excludes": ["Agent"],
        "max_iterations": 1,
        "max_tokens": 15000
    }
}
```

### Recording script

```bash
#!/usr/bin/env bash
# tests/evals/record_golden.sh — Record a golden file from a successful run

ralph_record_golden() {
    local eval_id="$1" description="$2"
    local output_dir="tests/evals/golden"
    mkdir -p "$output_dir"

    # Extract from last completed run
    local status_file="${RALPH_DIR}/status.json"
    local trace_file="${RALPH_DIR}/.traces/traces-$(date +%Y-%m).jsonl"

    jq -n \
        --arg id "$eval_id" \
        --arg desc "$description" \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg version "$RALPH_VERSION" \
        --slurpfile status "$status_file" \
        '{
            id: $id,
            description: $desc,
            recorded_at: $ts,
            ralph_version: $version,
            result: $status[0]
        }' > "$output_dir/${eval_id}.json"

    echo "Golden file saved: $output_dir/${eval_id}.json"
}
```

### Comparison tool

```bash
ralph_compare_golden() {
    local golden_file="$1" actual_status="$2"

    local expected_exit actual_exit
    expected_exit=$(jq -r '.expected.exit_signal' "$golden_file")
    actual_exit=$(jq -r '.exit_signal // false' "$actual_status")

    local result="PASS"
    if [[ "$expected_exit" != "$actual_exit" ]]; then
        result="FAIL"
        echo "FAIL: exit_signal expected=$expected_exit actual=$actual_exit"
    fi

    # Check file modifications
    local expected_files actual_files
    expected_files=$(jq -r '.expected.files_modified[]' "$golden_file" | sort)
    actual_files=$(jq -r '.files_changed[]?' "$actual_status" | sort)

    if [[ "$expected_files" != "$actual_files" ]]; then
        result="INCONCLUSIVE"
        echo "INCONCLUSIVE: file list differs (may be acceptable)"
    fi

    echo "$result"
}
```

## Acceptance Criteria

- [ ] Golden file JSON format defined with input, expected output, and metadata
- [ ] Recording script captures golden files from successful runs
- [ ] Comparison tool produces Pass/Fail/Inconclusive for each field
- [ ] Golden files stored in `tests/evals/golden/` (gitignored for sensitive content)
- [ ] At least 5 golden files recorded covering: simple fix, multi-file change, test addition, refactor, documentation

## References

- [Shaped — Golden Tests in AI](https://www.shaped.ai/blog/golden-tests-in-ai)
- [Anthropic — Demystifying Evals for AI Agents](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents)
