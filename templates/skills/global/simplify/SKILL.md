---
name: simplify
description: >
  Pre-commit / epic-boundary quality pass. Look for dead code, duplicated
  logic, unused imports, redundant comments, and speculative error handling
  introduced during the loop's Green phase. Removes, never adds. Produces
  a smaller diff than what you started with.
version: 1.0.0
ralph: true
ralph_version_min: "1.9.0"
attribution: "Authored for Ralph runtime, inspired by Kent Beck's refactor step and the YAGNI tradition"
user-invocable: true
disable-model-invocation: false
allowed-tools:
  - Read
  - Edit
  - Grep
  - Glob
  - Bash
---

# simplify — Remove What the Green Phase Added

The Ralph loop's Green phase is deliberately cheap: make the test pass,
commit, move on. The cost of that policy is that over a few loops, the
module accumulates comments that describe what the code already says,
try/except blocks that catch nothing, and helper functions used once.
This skill runs at the **epic boundary** to prune.

## When to invoke

Trigger this skill when **any** of these hold:

- The current loop is closing an **epic boundary** (you just completed
  the last `- [ ]` under a `##` section in `fix_plan.md` / the last
  issue in a Linear milestone).
- The next task sets `EXIT_SIGNAL: true` — the final state should be
  clean.
- `ralph-reviewer` flagged "dead code" or "duplicate logic" in a prior
  review and you're about to re-submit.
- Complexity classifier marked the recently-touched module as LARGE or
  ARCHITECTURAL — those modules benefit most from pruning.

**Do not** run mid-epic. The loop's throughput gain comes from *not*
refactoring on every iteration; saving it up to the boundary means
every SMALL task doesn't pay the simplify tax.

## Ralph-specific guidance

Walk the diff of the epic (not the whole file) and ask five questions,
in order. The answer to each is either "leave it" or "delete".

1. **Is this comment a paraphrase of the identifier it sits above?**
   Delete the comment; the identifier already says it.
   ```
   # Increment the counter   <-- delete
   counter += 1
   ```
2. **Is this error-handler catching something that can't happen?**
   A defensive `try/except Exception: log` around code that calls only
   trusted internal functions is noise. Delete unless there's a
   boundary (network, subprocess, user input) involved.
3. **Is this helper called exactly once, 3 lines above?**
   Inline it. Named helpers earn their keep at 2+ call sites or when
   the name adds information the code itself doesn't carry.
4. **Is this import used?**
   `grep` for the imported symbol in the file; if no hit, delete.
   Applies equally to bash `source` statements at the top of a lib file.
5. **Is this condition unreachable?**
   Ralph's PR of "handle legacy code path X" often leaves a branch that
   the rest of the codebase no longer reaches. Trace call sites; if the
   branch is truly dead, delete it rather than leaving "just in case".

After five questions, you're done. Don't expand the scope — if you find
yourself renaming variables, extracting interfaces, or moving files,
that's a different skill (architecture) and belongs in a different
loop with `ralph-architect`.

## Integration with sub-agents

- **ralph-reviewer** (Sonnet, read-only) — immediately after your pass,
  invoke the reviewer on the epic's consolidated diff. Reviewer will
  confirm nothing load-bearing was pruned; if it was, revert that one
  chunk and re-commit.
- **ralph-tester** (Sonnet) — **mandatory** after simplify. Deleted code
  can fail tests the loop didn't realize were leaning on it. Run the
  targeted test file, then the full suite at the epic boundary.
- **ralph-explorer** (Haiku) — if you're unsure whether a helper has
  external callers outside the current module, ask explorer for a
  call-site map before deleting. Cheaper than grepping blindly.

## Exit criteria

You're done with this skill when **all** of:

1. The epic's diff is smaller (net line count) after your pass than
   before it.
2. Tests still pass (either targeted or full, depending on boundary
   context).
3. `ralph-reviewer` returns no "deleted something load-bearing" flag.

If simplify makes the diff *larger*, you're accidentally adding. Stop.

## Anti-patterns

- **Renaming during simplify** — identifier renames churn downstream
  diffs and hide real deletions. Do renames in a dedicated loop.
- **Extracting helpers** — this is the opposite of simplify. Inlining
  one-shot helpers is the point; don't reverse the direction.
- **Commenting "why I deleted this"** — the commit message carries that
  information; the code stays quiet.
- **Deleting dead templates in `templates/hooks/`** — those are
  synchronized with `.ralph/hooks/` per TAP-538. Consult CLAUDE.md's
  hook-drift rules before pruning anything under `templates/`.
