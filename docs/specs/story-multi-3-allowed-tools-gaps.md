# Story RALPH-MULTI-3: Fix ALLOWED_TOOLS Template Patterns

**Epic:** [Multi-Task Loop Violation and Cascading Failures](epic-multi-task-cascading-failures.md)
**Priority:** High
**Status:** Done
**Effort:** Trivial
**Component:** `templates/ralphrc.template`

---

## Problem

The ALLOWED_TOOLS configuration in `ralphrc.template` uses granular `git` subcommand
patterns (e.g., `Bash(git add *)`) to prevent destructive git operations. However,
this creates gaps for:

1. **`git -C`**: Claude frequently uses `git -C /path add ...` to operate on repos
   from a different working directory. `Bash(git add *)` does not match `git -C ...`
   because the command starts with `git -C`, not `git add`.

2. **`grep`**: Not in ALLOWED_TOOLS at all. Claude's subagents use `Bash(grep ...)`
   when the Grep tool is unavailable or when they need specific grep flags.

3. **`find`**: Not in ALLOWED_TOOLS. Claude uses `find` for file discovery when Glob
   is insufficient (e.g., complex `-exec` operations).

**Impact in March 21 incident:** 5 permission denials across the session:
- 3x `git -C /path add ...` (retried until workaround found, ~$0.10 wasted)
- 1x `grep -r "pattern" /path`
- 1x `find /path -type f -name "*.tsx"`

**Research finding (2026):** Claude Code's `Bash(git *)` pattern matches ANY command
starting with `git ` (space after), including `git -C`. Shell operators are handled
securely -- `Bash(git *)` will NOT match `git status && rm -rf /`.

## Solution

Add the missing patterns to `ralphrc.template`. Keep the granular git approach (to
prevent destructive commands) but add `git -C` specifically:

```bash
ALLOWED_TOOLS="Write,Read,Edit,\
Bash(git add *),Bash(git commit *),Bash(git diff *),Bash(git log *),\
Bash(git status),Bash(git status *),Bash(git push *),Bash(git pull *),\
Bash(git fetch *),Bash(git checkout *),Bash(git branch *),\
Bash(git stash *),Bash(git merge *),Bash(git tag *),\
Bash(git -C *),\
Bash(grep *),Bash(find *),\
Bash(npm *),Bash(pytest)"
```

### Alternative: Broad git access

If the project accepts broad git access, replace all git subcommand patterns with:
```bash
Bash(git *)
```

This is simpler and covers all git flag combinations, but also allows `git clean -fd`,
`git reset --hard`, `git rm`, etc. The PROMPT.md file protection instructions and
`validate_ralph_integrity()` provide defense-in-depth against destructive operations.

**Recommendation:** Add `Bash(git -C *)` specifically (not broad `Bash(git *)`), since
the granular approach was chosen intentionally for safety.

## Design Notes

- **`Bash(git -C *)`** matches `git -C /any/path add`, `git -C /any/path status`, etc.
  The `*` after `-C ` covers the path and any subsequent subcommand + arguments.
- **`Bash(grep *)` and `Bash(find *)`** are safe to add broadly. These are read-only
  commands. Claude uses them for code search and file discovery.
- **No `Bash(cd *)` needed.** The spec mentions `cd` denials, but Claude worked around
  them using relative paths. Adding `cd` is unnecessary since `git -C` solves the root
  cause.
- **Existing projects** will need their `.ralphrc` updated manually or via
  `ralph-migrate`. Template changes only affect new projects.

## Acceptance Criteria

- [ ] `ralphrc.template` includes `Bash(git -C *)`
- [ ] `ralphrc.template` includes `Bash(grep *)`
- [ ] `ralphrc.template` includes `Bash(find *)`
- [ ] Existing `Bash(git add *)` etc. patterns preserved (not replaced with `Bash(git *)`)
- [ ] Documentation/comments explain why granular git patterns are used

## Test Plan

```bash
@test "ralphrc template includes git -C pattern" {
    run grep "git -C" templates/ralphrc.template
    assert_success
}

@test "ralphrc template includes grep pattern" {
    run grep 'Bash(grep' templates/ralphrc.template
    assert_success
}

@test "ralphrc template includes find pattern" {
    run grep 'Bash(find' templates/ralphrc.template
    assert_success
}
```

## References

- Claude Code permissions documentation: [code.claude.com/docs/en/permissions](https://code.claude.com/docs/en/permissions)
- Pattern matching: `Bash(git *)` matches commands starting with `git ` (space required)
- Shell operator security: `Bash(safe-cmd *)` does NOT match `safe-cmd && malicious-cmd`
- Bash permission pattern limitations: [Issue #20254](https://github.com/anthropics/claude-code/issues/20254)
