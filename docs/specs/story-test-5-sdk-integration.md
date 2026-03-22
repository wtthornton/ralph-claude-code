# Story TEST-5: Implement SDK Integration Tests

**Epic:** [RALPH-TEST](epic-validation-testing.md)
**Priority:** Medium
**Status:** Open
**Effort:** Large
**Component:** `tests/integration/test_sdk.bats`, `sdk/tests/`

---

## Problem

Once RALPH-SDK is implemented, the SDK execution path needs integration testing to verify:
- SDK runner produces equivalent results to CLI runner
- Custom tools work correctly in SDK context
- TheStudio adapter correctly translates TaskPackets
- Circuit breaker and rate limiting behave identically in both modes

## Solution

Create integration tests that run both CLI and SDK on reference projects and compare outputs. Also create Python-native tests for SDK components.

## Implementation

### BATS Integration Tests
```bash
@test "SDK and CLI produce equivalent status.json" {
  ralph --project "$REF_PROJECT" --dry-run --output-format json > /tmp/cli_result.json
  ralph --sdk --project "$REF_PROJECT" --dry-run --output-format json > /tmp/sdk_result.json
  # Compare key fields (timestamps will differ)
  cli_type=$(jq -r '.WORK_TYPE' /tmp/cli_result.json)
  sdk_type=$(jq -r '.WORK_TYPE' /tmp/sdk_result.json)
  [ "$cli_type" = "$sdk_type" ]
}

@test "SDK respects .ralphrc configuration" {
  echo "MAX_CALLS_PER_HOUR=25" > "$REF_PROJECT/.ralphrc"
  run ralph --sdk --project "$REF_PROJECT" --dry-run
  [[ "$output" == *"25"* ]]
}

@test "SDK reads ralph.config.json" {
  echo '{"max_calls_per_hour": 30}' > "$REF_PROJECT/ralph.config.json"
  run ralph --sdk --project "$REF_PROJECT" --dry-run
  [[ "$output" == *"30"* ]]
}
```

### Python Unit Tests (sdk/tests/)
```python
def test_task_input_from_fix_plan():
    input = TaskInput.from_fix_plan("tests/fixtures/fix_plan.md")
    assert input.source == "fix_plan"
    assert len(input.tasks) > 0

def test_task_input_from_task_packet():
    packet = {"intent": {"goal": "fix bug"}, "tasks": [{"title": "t1"}]}
    input = TaskInput.from_task_packet(packet)
    assert input.source == "task_packet"

def test_ralph_status_tool():
    result = ralph_status("IMPLEMENTATION", "t1", "t2", "progress", False)
    assert result["acknowledged"] is True
    assert result["exit"] is False

def test_thestudio_adapter():
    adapter = TheStudioAdapter()
    packet = {"intent": {"goal": "fix"}, "correlation_id": "abc123"}
    input = adapter.to_task_input(packet)
    assert input.source == "task_packet"
```

## Acceptance Criteria

- [ ] CLI and SDK produce equivalent outputs on reference projects
- [ ] SDK reads both `.ralphrc` and `ralph.config.json`
- [ ] Custom tools (ralph_status, ralph_rate_check, etc.) tested in SDK context
- [ ] TheStudio adapter tested with sample TaskPackets
- [ ] Circuit breaker behavior identical in CLI and SDK modes
- [ ] Rate limiting behavior identical in CLI and SDK modes
- [ ] Python test suite passes with pytest
- [ ] BATS integration suite passes
