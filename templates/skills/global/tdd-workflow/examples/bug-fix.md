# Example: Bug fix via Red → Green (shell)

## Loop snapshot

- Task: `- [ ] Fix: linear_get_open_count returns 0 on HTTP 503 instead of failing loud`
- WORK_TYPE expected: IMPLEMENTATION (bug fix)
- Complexity: SMALL

## Red — write the failing test first

Add one case to `tests/unit/test_linear_backend.bats`:

```bash
@test "linear_get_open_count: returns non-zero and prints nothing on HTTP 503" {
    LINEAR_MOCK_STATUS=503 LINEAR_MOCK_BODY='{"data":null}' \
        run linear_get_open_count
    assert_failure
    [[ -z "$output" ]] || fail "expected no stdout, got: $output"
}
```

Run it:
```
./node_modules/.bin/bats tests/unit/test_linear_backend.bats -f "HTTP 503"
# -> fails with status 0 and stdout "0" (the bug)
```

## Green — smallest fix

In `lib/linear_backend.sh::linear_get_open_count`, replace:

```bash
result=$(_linear_api "$query" "$vars" 2>/dev/null) || { echo "0"; return 0; }
```

with the fail-loud pattern already used elsewhere in the file
(TAP-536):

```bash
if ! result=$(_linear_api "$query" "$vars" 2>&1); then
    echo "linear_api_error: op=get_open_count reason=$result" >&2
    return 1
fi
```

Re-run the test — green. Run the whole `test_linear_backend.bats` file
to confirm you didn't break a neighbor — green.

## What to do NOT do

- Don't add a second test for HTTP 500, 502, 504 "while you're here" —
  one test proves the fail-loud branch works; you're burning loop
  budget if you tile the whole 5xx space.
- Don't refactor `_linear_api` into smaller helpers in the same loop.
  That's a `simplify`-skill task for the epic boundary.
- Don't upgrade `TESTS_STATUS` to `PASSING` in the status block without
  actually running the file — leave it `DEFERRED` if you only ran the
  one test, and let ralph-tester flip it at the boundary.
