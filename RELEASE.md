---
title: Release checklist
description: Step-by-step procedure for cutting a Ralph release, including version sync, smoke tests, and changelog promotion.
audience: [maintainer]
diataxis: how-to
last_reviewed: 2026-04-23
---

# Release checklist

Use this before tagging or publishing a release. Skipping steps has caused real incidents — follow them in order.

## 0. Prerequisites

- You are a maintainer with push access to `main`.
- Your working tree is clean: `git status` shows nothing to commit.
- You're on the latest `main`: `git fetch origin && git checkout main && git reset --hard origin/main`.

## 1. Decide the version

Follow [SemVer](https://semver.org/):

- **Patch** (`2.8.3 → 2.8.4`) — bug fixes, hardening, doc-only changes.
- **Minor** (`2.8.x → 2.9.0`) — new features, new config vars, new CLI flags.
- **Major** (`2.x.x → 3.0.0`) — breaking changes to the state-file schema, CLI contract, or hook API.

Write the version down. You'll type it several times.

## 2. Synchronize version strings

**Both files must match.** A unit test enforces this.

| File | Field | Command |
|---|---|---|
| `package.json` | `"version"` | `npm version --no-git-tag-version <new>` or hand-edit |
| `ralph_loop.sh` | `RALPH_VERSION="…"` near top | hand-edit |

The SDK versions independently:

| File | Field |
|---|---|
| `sdk/pyproject.toml` | `version = "…"` |
| `sdk/ralph_sdk/__init__.py` | `__version__ = "…"` |

SDK versions don't need to match the CLI version — but SDK `pyproject.toml` and `__init__.py` must match each other. Document both in [README.md](README.md) and [CHANGELOG.md](CHANGELOG.md) if they differ.

Sanity check:

```bash
grep '"version"' package.json
grep '^RALPH_VERSION=' ralph_loop.sh
grep '^version' sdk/pyproject.toml
grep '^__version__' sdk/ralph_sdk/__init__.py
```

## 3. Promote the changelog

Open [`CHANGELOG.md`](CHANGELOG.md). Everything under `## [Unreleased]` becomes the new version:

```markdown
## [Unreleased]

---

## [2.8.4] — 2026-04-23

### Added
- …
```

Rules:

- Keep-a-Changelog format: `Added` / `Changed` / `Fixed` / `Security` / `Removed`.
- Link Linear tickets (`**TAP-XXX**: …`).
- Keep bullets user-facing; don't copy commit messages verbatim.
- Date is release date, not branch date.

## 4. Run the test suite

```bash
npm install
npm test                               # unit + integration; must be 100%
npm run test:evals:deterministic       # 64 invariant checks
```

If anything fails, stop. Fix it. Do not release with red tests.

## 5. Smoke test the installer

In a fresh shell (not your dev shell — it may have stale `$PATH`):

```bash
cd /tmp
git clone https://github.com/wtthornton/ralph-claude-code.git ralph-smoke
cd ralph-smoke
bash install.sh
ralph --version                        # must print the new version
ralph-doctor
```

Upgrade path too:

```bash
cd ralph-smoke
git pull
bash install.sh upgrade
ralph --version                        # still prints the new version
```

## 6. Platform-specific smoke tests

Pick at least two:

| Platform | Command |
|---|---|
| Linux native | `bash install.sh && ralph --version` |
| WSL (Ubuntu) | `wsl bash install.sh && wsl ralph --version` |
| macOS | `brew install jq coreutils && bash install.sh && ralph --version` |
| Nix | `nix shell github:wtthornton/ralph-claude-code && ralph --version` |
| Docker sandbox | `ralph --sandbox --dry-run` in a test project |

## 7. jq bootstrap behavior

Verify both paths:

```bash
# Bootstrap enabled (default): jq downloads when missing
PATH="/tmp/fake" bash install.sh    # jq should be fetched to ~/.local/bin/jq

# Bootstrap disabled: must fail with a clear message
RALPH_SKIP_JQ_BOOTSTRAP=1 bash install.sh
```

## 8. Commit the release

```bash
git add -A
git commit -m "$(cat <<'EOF'
chore(v2.8.4): release — <one-line summary>

<body — what's in this release at a glance>

Co-Authored-By: <if applicable>
EOF
)"
```

## 9. Tag

```bash
git tag -a v2.8.4 -m "Ralph v2.8.4"
git push origin main
git push origin v2.8.4
```

## 10. GitHub release

Create a release from the tag at `https://github.com/wtthornton/ralph-claude-code/releases/new`:

- **Tag:** `v2.8.4` (existing)
- **Title:** `v2.8.4 — <short summary>`
- **Body:** Paste the corresponding `CHANGELOG.md` section.
- **Latest release:** ✅ if it's the newest. Pre-release for RCs only.

## 11. Update README badges (if applicable)

The version badge in `README.md` should reflect the new version. Ideally this is automated by the badge-update GitHub Action; verify the commit lands before the next release.

## 12. Update external references

- [ ] [Awesome Claude Code](https://github.com/hesreallyhim/awesome-claude-code) listing (if Ralph is featured there)
- [ ] Any downstream projects you know of that pin a Ralph version
- [ ] Nix flake derivation (self-updating via the flake, but double-check)

## 13. Announce (optional but nice)

- Twitter / X / Mastodon post with the one-line summary and the release link
- Any relevant Discord / Slack community channels

## Post-release

- Open a follow-up issue for anything that had to be left out of the release.
- Move the `## [Unreleased]` header back to the top of `CHANGELOG.md`.
- Celebrate.

## Rollback procedure

If a critical bug ships:

1. Open an incident issue describing the blast radius.
2. Decide: patch release (preferred) or revert to previous tag.
3. If reverting: `git revert <release-commit>`, not `git reset --hard` on `main`.
4. Tag the revert as the next patch version (e.g. `v2.8.5`, not reuse `v2.8.4`).
5. Publish a GitHub advisory if it's a security issue; coordinate via [SECURITY.md](SECURITY.md).

## Related

- [CHANGELOG.md](CHANGELOG.md) — version history
- [CONTRIBUTING.md](CONTRIBUTING.md) — code and commit conventions
- [TESTING.md](TESTING.md) — test suite details
- [SECURITY.md](SECURITY.md) — vulnerability reporting
