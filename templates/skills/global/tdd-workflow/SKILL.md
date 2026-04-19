---
name: tdd-workflow
description: >
  Test-first discipline for the Ralph loop. Write a failing test that
  reproduces the target behavior before implementing, then make it pass
  with the smallest change. Stack-agnostic (BATS for shell, pytest for
  the SDK, jest where present). Integrates with the ralph-tester
  sub-agent at epic boundaries.
version: 1.0.0
ralph: true
ralph_version_min: "1.9.0"
attribution: "Authored for Ralph runtime, drawing on Kent Beck's Test-Driven Development"
user-invocable: true
disable-model-invocation: false
allowed-tools:
  - Read
  - Write
  - Edit
  - Grep
  - Glob
  - Bash
---

# tdd-workflow — Test-First for Ralph (stack-agnostic)

Ralph's exit gate rewards tangible, verifiable progress. A failing test
that turns green is the cleanest signal of progress the loop can emit,
and the easiest for `ralph-tester` and `ralph-reviewer` to rubber-stamp.

## When to invoke

Trigger this skill when any of these hold in a loop:

- The task is a **bug fix**: a specific behavior is wrong and you can
  describe the expected output in one sentence.
- The task adds a **pure function, parser, classifier, or transformer**
  (anything with input → output but no side effects on the filesystem or
  an external API).
- You touch a module in `lib/` or `sdk/ralph_sdk/` that has an existing
  `tests/unit/test_*.bats` or `sdk/tests/test_*.py` next to it.
- A previous loop's diff was rejected by `ralph-reviewer` with "no test
  coverage for the change".

Skip this skill (or apply it lightly) when:

- The task is pure **refactor** with no behavior change — tests don't
  need to be added, only kept green.
- The task edits only docs, templates, or non-executable configuration.
- The change is a one-line shell guard that would need a 30-line fixture
  to test meaningfully.

## Ralph-specific guidance

The Ralph loop has a specific testing topology — respect it:

1. **BATS for shell** (`tests/unit/`, `tests/integration/`).
   Use `tests/helpers/test_helper.bash` for `assert_success`, fixtures,
   and tempdir setup. Never run `bats` from Bash directly — use
   `./node_modules/.bin/bats` or `npm test`. **Integration tests are a
   hard CI gate** (TAP-537) — don't bypass with `|| true`.
2. **pytest for the SDK** (`sdk/tests/`). The agent loop is async —
   prefer `@pytest.mark.asyncio` over `asyncio.run()` in tests. Dev deps
   live in `sdk/pyproject.toml` (pytest-asyncio, pytest-timeout).
3. **jest** if the current project has a `package.json` with `jest` or
   `vitest` in `devDependencies`.

Red → Green → Refactor, adapted for a loop:

- **Red** (this loop, 20% of time): write ONE failing test that nails the
  specific behavior. Don't write a whole test file.
- **Green** (this loop, 60%): smallest change in the implementation that
  flips the test. Resist adding "while I'm here" improvements.
- **Refactor** (epic boundary, 20%): invoke `simplify` skill.

**Do not write speculative tests** — tests for "what if the user passes
null" when the type system or call sites rule that out waste loop
budget. Write tests for behavior, not for exhaustive input spaces.

Always run the **targeted** test before committing, not the full suite:

- BATS: `./node_modules/.bin/bats tests/unit/test_<module>.bats`
- pytest: `cd sdk && .venv/bin/pytest tests/test_<module>.py`

Full suite runs at epic boundaries, via `ralph-tester`.

## Integration with sub-agents

- **ralph-tester** (Sonnet, worktree-isolated) — **mandatory** at epic
  boundaries and before any loop that sets `EXIT_SIGNAL: true`. Set
  `TESTS_STATUS: DEFERRED` mid-epic; set `TESTS_STATUS: PASSING` only
  after ralph-tester returns green.
- **ralph-reviewer** (Sonnet, read-only) — at epic boundaries, the
  reviewer will reject a diff with new behavior but no new test. Avoid
  that round-trip by writing the test in the same loop as the code.
- **ralph-explorer** (Haiku) — when you're unsure which tests cover the
  module you're touching, ask explorer for a map first. Cheaper than
  grepping manually.

## Exit criteria

You're done with this skill when **all** of:

1. A new test exists that would have failed before your change.
2. That test passes now.
3. The targeted test file is green (not just the new test).
4. You've decided whether to defer the full suite (mid-epic) or run
   ralph-tester (epic boundary / pre-exit).

## Anti-patterns

- **Testing after** — writing tests after the implementation often leads
  to "tests that pass". The point of Red → Green is to prove your test
  actually catches the bug.
- **Mocking the database in integration tests** — we've been burned.
  Integration tests hit real files, real processes, real sockets.
- **Snapshot tests for JSON payloads** — fragile; prefer specific
  `jq` assertions on the fields that actually matter.
- **One giant test** — `@test "everything works end-to-end"` hides
  which invariant is broken when it fails. One behavior per test.
