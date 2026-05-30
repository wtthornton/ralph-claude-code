# Operator Edits

`templates/hooks/protect-ralph-files.sh` (installed into every Ralph-managed
project as `.claude/hooks/protect-ralph-files.sh`) is a PreToolUse hook that
hard-blocks all `Edit`/`Write` tool calls and most `Bash` redirects that
target `.claude/`, `.ralph/`, or `.ralphrc`. The block fires for **every**
Claude Code session — autonomous Ralph loops and interactive sessions alike.
The hook cannot tell them apart, and that's the design: an agent must not be
able to rewrite its own configuration.

The trade-off is that a small set of legitimate operations — model bumps,
project-hook tweaks, opt-in flags — require breaking out of Claude Code
entirely. This doc is the copy-paste playbook for the common cases.

> **Rule of thumb:** if Claude Code (interactive or autonomous) refuses with
> `BLOCKED: Cannot modify Claude Code agent/hook config`, the change belongs
> in this doc. Open a plain terminal in the project root and run the command
> below.

---

## 1. Bumping agent models (single source of truth)

`agent-models.json` (repo root) is the single source of truth for every
`.claude/agents/<name>.md` `model:` field. The drift guard at
`tests/unit/test_agent_models_lockstep.bats` fails CI if the manifest and
the agent files diverge in either direction (manifest entry without a file,
or file without a manifest entry, or values that don't match).

### Bump a model

1. Edit `agent-models.json` from your terminal. Example — moving the
   coordinator from Sonnet to Haiku:

   ```bash
   sed -i 's/"ralph-coordinator":  "sonnet"/"ralph-coordinator":  "haiku"/' \
     /path/to/ralph-claude-code/agent-models.json
   ```

2. Propagate to the agent files:

   ```bash
   bash scripts/apply-agent-models.sh
   ```

   The script reads the manifest, computes the diff against each
   `.claude/agents/<name>.md`, and rewrites only the `model:` line. Use
   `--dry-run` first if you want to preview:

   ```bash
   bash scripts/apply-agent-models.sh --dry-run
   ```

3. Confirm the diff is what you expect:

   ```bash
   git diff agent-models.json .claude/agents/
   ```

4. Hand off to Claude Code (or commit + open the PR manually). Commit both
   `agent-models.json` and the affected `.claude/agents/*.md` files in the
   same commit so the manifest and the files always move together.

### Add a new agent

1. Create `.claude/agents/<new-name>.md` (in your terminal — `.claude/` is
   protect-blocked).
2. Add the new entry to `agent-models.json`'s `lineup` object.
3. Run `bash scripts/apply-agent-models.sh` to verify the `model:` line
   matches the manifest.

The drift-guard test will fail until the manifest knows about the new file.

### Remove an agent

1. Delete `.claude/agents/<old-name>.md`.
2. Remove the matching key from `agent-models.json`.
3. CI will pass once both deletions are in the same commit.

---

## 2. Toggling `RALPH_ALLOW_PUSH_MAIN` for a direct-to-main repo

`.ralphrc.local` is the operator-only override surface — gitignored,
protect-blocked from agent edits, but sourced by the harness. For
direct-to-main workflows:

```bash
cat > /path/to/your-project/.ralphrc.local <<'EOF'
RALPH_ALLOW_PUSH_MAIN=1
EOF
```

The `validate-command.sh` hook will then allow `git push origin main`. The
agent inside the harness cannot unset this (the file is protect-blocked).

---

## 3. Editing a project's `.claude/hooks/*.sh`

Project hooks are protect-blocked. Two paths:

- **Sync from template (recommended):** edit `templates/hooks/<hook>.sh` in
  the Ralph repo, ship a new Ralph release, then run `ralph-upgrade-project`
  in the consumer repo. The template is the source of truth; per-project
  hook drift is what `ralph-doctor` warns about.
- **Direct edit (one-off):**

  ```bash
  sed -i 's|OLD_PATTERN|NEW_PATTERN|' /path/to/project/.claude/hooks/<hook>.sh
  ```

  Run from your shell, not from Claude Code.

---

## 4. Editing `.ralphrc` (committed) vs `.ralphrc.local` (operator-only)

`.ralphrc` is checked in and read by every session. The protect hook blocks
the agent from editing it, but a human can. For per-repo overrides that the
agent must not be able to self-unlock (the `RALPH_ALLOW_PUSH_MAIN` case
above), use `.ralphrc.local` — same syntax, sourced after `.ralphrc`,
never committed.

---

## Why the hook blocks Claude Code itself

`protect-ralph-files.sh` runs as a PreToolUse hook on every tool invocation
that could touch a protected path. The hook has no signal to distinguish
"the autonomous Ralph loop is running" from "the operator is debugging
interactively in Claude Code" — both go through the same Edit/Write/Bash
interface, with the same environment. Hard-blocking every session is the
safe default: an agent cannot trick its own session into bypassing the
protection.

The operator workflow tax — having to break out of the session for the
edits in this doc — is the price of that guarantee. The workflow is real
and stable; this playbook is here to make it cheap.
