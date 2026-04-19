# Example: Epic-boundary prune in lib/plan_optimizer.sh

## Loop snapshot

- Epic just closed: PLANOPT — `fix_plan.md` task reordering
- 6 loops over the last 2 hours; diff is ~400 lines across
  `lib/plan_optimizer.sh` and `sdk/ralph_sdk/plan_optimizer.py`.
- Time to invoke **simplify** before marking `EXIT_SIGNAL: true`.

## Pass over the shell module

Walking the diff with the five questions:

1. Comment-paraphrase: found 3 `# Sort the tasks` / `# Read the file`
   lines above the function call that does exactly that. **Delete** 3.
2. Defensive catches: one `|| echo "0"` on a jq call where an upstream
   change already makes jq always succeed on our schema. **Delete** the
   `|| echo "0"` branch (TAP-538 sanitize pattern already guards the
   downstream math).
3. One-shot helpers: found `_normalize_task_text()` called exactly once
   from `_parse_fix_plan()`. Two lines. **Inline** it.
4. Unused imports: no new `source` lines were added in this epic. Skip.
5. Unreachable conditions: none. Skip.

Diff shrinks from +412 to +391 lines.

## Run tests

```
./node_modules/.bin/bats tests/unit/test_plan_optimizer.bats
# -> 38/38 green
```

## Reviewer pass

Invoke `ralph-reviewer` on the consolidated epic diff. Reviewer reports:
"no load-bearing deletion; inlining of `_normalize_task_text` is fine,
call site is the only user."

## Commit + proceed to EXIT_SIGNAL

`TESTS_STATUS: PASSING`, `EXIT_SIGNAL: true` — epic closes cleanly.
The loop that set EXIT_SIGNAL was 5 minutes shorter than it would have
been without simplify, because the reviewer didn't have to ask for the
post-hoc cleanup pass.
