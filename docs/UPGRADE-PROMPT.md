# Generic Ralph upgrade prompt

Paste the block below into a Claude Code session running **inside the target project** (e.g. `tapps-mcp`, `agentforge`, `nltlabs-platform`). It assumes:

- The Ralph source checkout lives at `~/code/ralph-claude-code` (adjust the `SOURCE` path if not).
- The target project is already Ralph-managed (`.ralph/` and `.ralphrc` exist).
- You want to refresh templates, hooks, `.gitignore` patterns, and the global Tier S skills — but **not** touch project-owned content (`PROMPT.md`, `AGENT.md`, anything outside `templates/.gitignore`'s allowlist).

The prompt is intentionally a single, self-contained block. Claude does the work; you review the diff before committing.

---

## Paste this

> **Task: upgrade this project to the latest Ralph.**
>
> Source of truth: `/home/wtthornton/code/ralph-claude-code` (adjust if elsewhere on this machine). Do **not** modify any file in that directory — read-only.
>
> Steps:
>
> 1. **Pre-flight.** Confirm we are in a Ralph-managed project: `.ralph/` directory exists, `.ralphrc` exists. If either is missing, stop and report — this prompt is for upgrades, not first-time enable. Print the current Ralph version: `ralph --version`.
>
> 2. **Pull the source.** `git -C /home/wtthornton/code/ralph-claude-code pull --ff-only`. If the pull is non-fast-forward or has local changes, stop and surface the error; do not try to resolve it.
>
> 3. **Refresh `~/.ralph/templates/`.** Run `ralph-upgrade --source /home/wtthornton/code/ralph-claude-code`. This rebuilds the host-wide template cache and reinstalls global Tier S skills (`search-first`, `tdd-workflow`, `simplify`, `context-audit`, `agentic-engineering`, `ralph-runner`) via the `.ralph-managed` sidecar mechanism — user-authored skills under `~/.claude/skills/` are left alone.
>
> 4. **Preview the per-project upgrade.** From this project's root, run `ralph-upgrade-project --dry-run`. Read the dry-run output carefully and surface any of:
>
>    - Hook drift (`.ralph/hooks/*.sh` diverging from `~/.ralph/templates/hooks/*.sh`).
>    - `.ralphrc` merges that would change defaults you explicitly set (e.g. a project-pinned `CLAUDE_MODEL` or `RALPH_COORDINATOR_TIMEOUT_SECONDS`).
>    - `.gitignore` patterns that will be backfilled (the `.ralph/*` allowlist from TAP-1882/1883).
>    - Agent file (`.claude/agents/ralph.md`) or `PROMPT.md` rewrites (these only happen with `--resync-templates`; the dry-run should normally not propose them).
>
>    Do not proceed if the dry-run reports anything destructive. Ask before applying.
>
> 5. **Apply.** Run `ralph-upgrade-project --yes`. This:
>    - Syncs `.ralph/hooks/*.sh` from the template.
>    - Merges new defaults into `.ralphrc` (additive — does not overwrite values already set in-file).
>    - Backfills missing `.gitignore` allowlist entries via `merge_gitignore_block` (idempotent; preserves user-added lines byte-for-byte).
>    - Re-syncs `.claude/settings.json` hook registrations.
>
> 6. **Verify.** Run `ralph-doctor` and surface any `[FAIL]` or `[WARN]` lines. In particular, confirm that `.ralph/hooks/on-stop.sh` contains the `RALPH_LOOP_ACTIVE` guard (TAP-1531) — `ralph-doctor` checks this automatically.
>
> 7. **Show the diff.** Run `git status` and `git diff --stat` (no `-uall`). Walk me through every changed file in one paragraph each — what changed, why the upgrade brought it in, whether I should be cautious about it. Pay special attention to:
>
>    - Any `.ralph/hooks/` change (these run on every Claude response — silent breakage is high-impact).
>    - Any `.ralphrc` line you added (especially anything that changes model selection, coordinator timeouts, or push behavior).
>    - Any `.gitignore` line — confirm it's allowlist-style, not ignoring something the project actually tracks.
>
> 8. **Do NOT commit.** Stop after step 7. I will review the diff and commit manually with a `chore(ralph): upgrade to vX.Y.Z` message. If you spot anything that needs a code change beyond the upgrade itself (e.g. project-specific `.ralphrc` value drifted), surface it as a follow-up rather than fixing it inline.
>
> Hard rules for this task:
>
> - Do **not** edit `PROMPT.md`, `AGENT.md`, `fix_plan.md`, or anything inside `.claude/agents/` unless the dry-run explicitly proposed it AND I approved it in step 4.
> - Do **not** touch the Ralph source repo at `/home/wtthornton/code/ralph-claude-code`. Read-only.
> - Do **not** create or update any Linear issue as part of this upgrade. If the upgrade surfaces a bug worth filing, mention it at the end — don't file it yourself.
> - Do **not** push, force-push, or run `git reset --hard` / `git clean`. The upgrade is local until I commit and push.
> - If any step fails, **stop and report**. Do not improvise around a broken hook or a corrupt template.

---

## Customizing the prompt

- **Different source path.** If Ralph isn't at `/home/wtthornton/code/ralph-claude-code` (e.g. you're on a different machine or have a checkout under `~/dev/`), replace every occurrence of that absolute path in the prompt above. Don't use `~` — the protect-ralph-files hook and the upgrade scripts both fail-soft on tilde expansion in odd contexts; absolute paths are safer.
- **Linear-managed project.** If the project uses `RALPH_TASK_SOURCE=linear` (every user-managed Ralph project does, per [feedback_no_fix_plan.md](../../.claude/projects/-home-wtthornton-code-ralph-claude-code/memory/feedback_no_fix_plan.md)), step 7's diff should NOT touch `fix_plan.md`. If it does, the upgrade is misbehaving — surface it.
- **Want the upgrade auto-committed.** Remove the "Do NOT commit" line from step 8 and add: `Commit the changes with message "chore(ralph): upgrade to v$(ralph --version | awk '{print $NF}')" and push.` This is fine for projects with a CI-protected `main` and trivial expected diffs; not recommended for first runs against a new project.
- **Want a fully-autonomous upgrade.** Wrap the prompt in a `ralph-runner` campaign — but only after the first manual run has established what a clean upgrade diff looks like for this project. Don't autonomy-ize step 1.

---

## What this does NOT do

- It does **not** run `ralph` (the autonomous loop) — only the upgrade tooling. After the upgrade you can resume your normal Ralph workflow with whatever knobs you already had.
- It does **not** migrate from file mode to Linear mode, or vice versa. That's a one-time decision change, not an upgrade.
- It does **not** rotate or revoke any credentials (Linear OAuth, Anthropic API keys). The upgrade is filesystem-only.
- It does **not** re-import tasks from beads/GitHub/PRD. Use `ralph-enable-ci --from <source>` for that.
