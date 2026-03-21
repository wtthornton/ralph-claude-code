# Story RALPH-LOOP-3: Handle Compound Bash Command Permissions

**Epic:** [Loop Stability & Analysis Resilience](epic-loop-stability.md)
**Priority:** High
**Status:** Done
**Effort:** Trivial
**Component:** `templates/ralphrc.template`, `ralph_loop.sh` (default ALLOWED_TOOLS), `templates/PROMPT.md`

---

## Problem

Claude frequently constructs compound bash commands using `&&` and `|`:

```bash
# Denied — starts with "cd", but && makes it a compound command
cd /mnt/c/cursor/TheStudio && git add .ralph/fix_plan.md && git commit -m "..."

# Denied — starts with "find", but | xargs makes it compound
find /src -path "*dashboard*" -name "*.py" | xargs ls -la
```

RALPH-MULTI-3 added individual patterns (`Bash(find *)`, `Bash(cd *)`, etc.) but Claude
Code's `--allowedTools` permission matching may evaluate compound commands as whole strings
or split on `&&`/`|` and check each sub-command. Either way, compounds with sub-commands
not in ALLOWED_TOOLS (like `xargs`, `ls -la` standalone) are denied.

**Observed denials (TheStudio 2026-03-21):**
1. `find ... | xargs ls -la` — `xargs` not in ALLOWED_TOOLS
2. `cd /path && git add ... && git commit -m "$(cat <<'EOF'...)"` — heredoc syntax in
   `git commit` may confuse the matcher

## Solution

Two-pronged approach:

1. **Add missing utility patterns** to ALLOWED_TOOLS template for commonly piped commands
2. **Add PROMPT.md guidance** telling Claude to avoid compound commands and use separate
   tool calls instead (more reliable and produces cleaner permission audit trails)

## Implementation

### Change 1: ALLOWED_TOOLS template updates

In `templates/ralphrc.template` and `ralph_loop.sh` (default ALLOWED_TOOLS), add:

```
Bash(xargs *),Bash(sort *),Bash(tee *),Bash(rm *),Bash(touch *),Bash(sed *),Bash(awk *),Bash(tr *),Bash(cut *),Bash(dirname *),Bash(basename *),Bash(realpath *),Bash(test *),Bash(true),Bash(false),Bash(sleep *)
```

These cover common pipeline utilities that Claude uses in compound commands.

### Change 2: PROMPT.md guidance

Add to the "Key Principles" or "Execution Contract" section of `templates/PROMPT.md`:

```markdown
## Bash Command Guidelines
- Use separate Bash tool calls instead of compound commands (`&&`, `||`, `|`)
- Instead of: `cd /path && git add file && git commit -m "msg"`
- Use three separate Bash calls: `cd /path`, then `git add file`, then `git commit -m "msg"`
- This avoids permission denial issues with compound command matching
```

### Change 3: `ralph_enable.sh` / `ralph_enable_ci.sh`

Update the ALLOWED_TOOLS in the enable scripts to include the new patterns, matching
the template.

## Design Notes

- **Why not just use `Bash(*)`?** The granular approach prevents destructive commands
  (`git clean`, `git reset --hard`, `rm -rf /`). Adding specific utilities is safer
  than wildcarding all bash.
- **Why add PROMPT guidance?** Even with all patterns added, Claude may combine commands
  in ways that are hard to predict. Separate tool calls are more reliable and produce
  cleaner audit trails for permission tracking.
- **`rm *` safety:** Claude's `--allowedTools` already constrains scope. The `Bash(rm *)`
  pattern is needed for cleanup operations (temp files, build artifacts). Destructive
  `rm -rf /` is blocked by the sandbox environment and Claude's safety training.

## Acceptance Criteria

- [ ] `templates/ralphrc.template` includes `xargs`, `sort`, `tee`, `rm`, `touch` patterns
- [ ] `ralph_loop.sh` default ALLOWED_TOOLS includes the new patterns
- [ ] `templates/PROMPT.md` advises against compound commands
- [ ] `ralph_enable.sh` and `ralph_enable_ci.sh` include updated patterns
- [ ] Common compound commands (`cd && git`, `find | xargs`) no longer produce denials

## Test Plan

```bash
@test "default ALLOWED_TOOLS includes xargs pattern" {
    source "$SCRIPT_DIR/ralph_loop.sh"
    assert_regex "$CLAUDE_ALLOWED_TOOLS" "Bash\(xargs \*\)"
}

@test "default ALLOWED_TOOLS includes sort pattern" {
    source "$SCRIPT_DIR/ralph_loop.sh"
    assert_regex "$CLAUDE_ALLOWED_TOOLS" "Bash\(sort \*\)"
}
```
