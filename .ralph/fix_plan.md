# Ralph SDK — Fix Plan

<!-- CRITICAL: Ralph must work identically without TheStudio. All changes are additive. -->

## Completed

v2.0.0 shipped (9 epics, 3 phases, 56 tasks). RFC-001 fully implemented:
Pydantic v2 models, pluggable state backend, structured parsing, async SDK,
active circuit breaker, correlation ID, TaskPacket conversion, EvidenceBundle output.

---

## v2.0.2 Integration Polish

> Triggered by: TheStudio Epic 43 gap analysis (2026-03-22)
> These are quick fixes that save bridge-layer workarounds in TheStudio's `ralph_bridge.py`.
> Total effort: ~2 hours. All additive, no breaking changes.

- [x] POLISH-1: Export `ComplexityBand`, `TrustTier`, `RiskFlag`, `IntentSpecInput`, `TaskPacketInput` from `__init__.py` — users shouldn't need internal module paths
- [x] POLISH-2: Add `created_at: datetime = Field(default_factory=lambda: datetime.now(UTC))` to `EvidenceBundle` in `evidence.py` — every consumer needs this timestamp
- [x] POLISH-3: Make `NullStateBackend` and `FileStateBackend` explicitly inherit from `RalphStateBackend` Protocol — prevents silent breakage if Protocol methods change
- [x] POLISH-4: Fix version: sync `__version__` in `__init__.py` with pyproject.toml (both → `"2.0.2"`)
- [x] POLISH-5: Add `system_prompt: str | None = None` parameter to `run_iteration()` in `agent.py` — pass through to Claude CLI via `--system-prompt` flag. RFC §9 Q4 recommended this; TheStudio needs it for `DeveloperRoleConfig.build_system_prompt()` injection
- [x] POLISH-6: Add public `cancel()` method to `RalphAgent` — wraps `self._running = False`. Epic 43 Temporal timeout needs this; using a private attribute directly is fragile
- [x] POLISH-7: Add `tokens_in: int = 0` and `tokens_out: int = 0` fields to `TaskResult` and `EvidenceBundle`. Extract from Claude CLI JSONL output (`input_tokens`/`output_tokens` in `result` messages) when available. TheStudio needs accurate token counts for `ModelCallAudit` — without this, cost estimation falls back to chars//4 heuristic

## Discovered
<!-- Ralph will add discovered tasks here during implementation -->

---

## Urgent & High Bug Fixes (TAP-656–662)

> Linear project: Ralph Continuous Coding
> Triggered by: 2026-04-20 backlog review
> Order: security/urgent first, independent shell bugs, SDK fix, then EPIC feature last.

### Urgent

- [x] TAP-656: Delete two malformed duplicate hook entries from `.claude/settings.json` (lines 47-56 and 80-89 — matcher/command fields swapped). Add `tests/unit/test_settings_json.bats` validating that every `matcher` is a valid regex, every `command` starts with `bash ` or a resolvable binary, and no `statusMessage` contains a `|` separator.

### High — Shell Fixes

- [ ] TAP-657: Bump `actions/checkout@v3` → `@v4` and `actions/setup-node@v3` → `@v4` in all four locations in `.github/workflows/test.yml` (lines 25, 28, 66, 69). Add `cache: npm` to the `setup-node` step in the coverage job.

- [ ] TAP-659: Replace sed-based JSON escape in `lib/notifications.sh:_notify_webhook()` with `jq -n --arg` construction for all five fields (`event`, `title`, `message`, `timestamp`, `project`). Remove `|| true` from the `curl` call — failed webhook should log a WARN to stderr instead of silently dropping.

- [ ] TAP-660: Rewrite `ralph_trace_record` in `lib/tracing.sh` to build each JSONL span via `jq -n --arg k v ... '{...}'` instead of shell interpolation. Replace `echo "$record"` with `printf '%s\n' "$record"`. Add a pre-append validation gate: `jq -e . <<<"$record" >/dev/null || { warn "invalid trace record dropped"; return 1; }`. Add unit test asserting a span with literal `$'\n'` and `\\` in an attribute produces valid JSONL.

- [ ] TAP-658: Cap `_cb_log_transition()` in `lib/circuit_breaker.sh` at 200 entries using `jq --argjson t "$transition" '. + [$t] | .[-200:]'`. Use `atomic_write` helper (from TAP-535) instead of `>` redirect. Replace `|| true` with a WARN log on failure.

- [ ] TAP-661: In `ralph_upgrade_project.sh` `upgrade_hooks()`, add per-hook validation before and after copy: (1) `[[ -s "$src" ]] && bash -n "$src"` — skip+WARN on failure; (2) copy to a `.tmp` path, `bash -n` the copy, then atomic `mv` into place; (3) on any failure restore from backup and return non-zero. Add `--verify` flag that audits project hooks against templates without writing.

### High — SDK Fix

- [ ] TAP-662: In `sdk/ralph_sdk/agent.py:_extract_session_id()`, track a `tokens_found` boolean. If false after the loop, log `WARN: no token counts in CLI output; cost for this iteration not recorded` and pass `None` to `record_iteration`. Update `CostTracker.record_iteration` in `cost.py` to treat `None` as "unknown, abstain" — emit `iteration_cost_unknown` metric, skip cost math. Add test asserting the warning fires on a stream without a `usage` block.

### High — EPIC Feature

- [ ] TAP-573 SKILLS-INJECT-1: Seed `~/.claude/skills/` from `templates/skills/global/` in `install.sh` — idempotent, checksum-guarded, `.ralph-managed` sidecar, snapshots via `lib/backup.sh`. (Global baseline — prerequisite for all other SKILLS-INJECT stories.)

- [ ] TAP-573 SKILLS-INJECT-2: Create Ralph-owned Tier S skill library in `templates/skills/` with `ralph: true` frontmatter, version, attribution. Skills: `search-first`, `tdd-workflow`, `simplify`, `context-audit`, `agentic-engineering`. Add unit tests for frontmatter and content.

- [ ] TAP-573 SKILLS-INJECT-3: Add Tier A project detection + install to `ralph_enable`. Detect project type (pyproject.toml → `python-patterns`; anthropic import → `claude-api`; package.json+Express → `backend-patterns`; `RALPH_TASK_SOURCE=linear` → `linear`; `tests/evals/` → `eval-harness`). Install matching skills into target `.claude/skills/` with `.ralph-managed` sidecar guard.

- [ ] TAP-573 SKILLS-INJECT-4: Inject skill hints into `PROMPT.md` at enable time — one-line per installed skill describing when to trigger it.

- [ ] TAP-573 SKILLS-INJECT-5: Implement `lib/skill_retro.sh` friction detection — read `status.json` + stream log after each loop, identify friction signals (repeated tool failures, long stalls, missing patterns), emit JSON friction report.

- [ ] TAP-573 SKILLS-INJECT-6: Implement retro apply in `lib/skill_retro.sh` — advisory mode by default (`RALPH_SKILL_AUTO_TUNE=false`); when enabled, add 1 skill / remove 1 skill per loop based on friction report. Checksum-guard prevents overwriting user-modified skills.

- [ ] TAP-573 SKILLS-INJECT-7: Periodic re-detection — re-run Tier A detection every N loops (default 10) and reconcile installed skills against current project state.

- [ ] TAP-573 SKILLS-INJECT-8: Telemetry + metrics — surface skill hit rate in `ralph --stats`; emit `skill_triggered`, `skill_added`, `skill_removed` metric events to JSONL.
