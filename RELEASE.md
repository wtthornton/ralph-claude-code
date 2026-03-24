# Release checklist

Use this before tagging or publishing a release.

1. **Versions (must match)** — `ralph_loop.sh` (`RALPH_VERSION`), `package.json` (`version`), `sdk/pyproject.toml` + `sdk/ralph_sdk/__init__.py` (SDK can differ; document both in README / IMPLEMENTATION_STATUS).
2. **Docs** — README badge / “What’s New”, `IMPLEMENTATION_STATUS.md` if you track versions there.
3. **Tests** — `npm install && npm test` (BATS).
4. **Install smoke test** — From a clean shell: `bash install.sh` or `bash install.sh upgrade`; then `ralph --version` and `ralph-doctor`.
5. **WSL (optional)** — Confirm `jq` bootstrap or system `jq`; confirm `~/.local/bin` on `PATH`.

Optional: `RALPH_SKIP_JQ_BOOTSTRAP=1 ./install.sh` to verify failure messaging when `jq` is absent and bootstrap is disabled.
