# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

---

## [Unreleased]

---

## [2.7.1] — 2026-04-20

Hardening release. 14 fix commits on top of 2.7.0 — no new features, all security/reliability/CI fixes surfaced by the internal code-review sweep.

### Security
- **TAP-622**: Stop splicing `fix_plan.md` content into an awk-driven shell command in `plan_section_hashes` — fixes shell injection via crafted task titles
- **TAP-623**: `protect-ralph-files.sh` now guards `.claude/` (agents, hooks, settings) in addition to `.ralph/`, so the loop cannot edit its own control plane
- **TAP-624**: Close multiple destructive-command bypasses in `validate-command.sh` whitelist
- **TAP-633**: Stop interpolating unquoted `project_root` into the `python3 -c` body in `lib/import_graph.sh` — fixes Python heredoc command injection
- **TAP-641**: `ralph.ps1` now passes arguments via argv splat instead of `bash -c` interpolation — fixes command injection via whitespace-containing args
- **TAP-643**: Replace in-place `sed` with a jq-based patch + backup when adjusting `.claude/settings.json` — prevents silent JSON corruption

### Fixed
- **TAP-621**: SDK token usage is now read from `obj["usage"]` (correct JSON level), re-enabling `CostTracker` and `TokenRateLimiter`
- **TAP-625**: `FileStateBackend` text writers all go through atomic write — SIGTERM races no longer corrupt rate-limit/counter state
- **TAP-628**: `plan_optimizer._validate_equivalence` actually checks the invariant (previously compared `sorted(same objects)` against itself)
- **TAP-630**: `CircuitBreaker` cooldown uses tz-aware datetime — fixes `time.mktime` / `tm_gmtoff` mis-parse on macOS/BSD
- **TAP-636**: `install.sh` enables `pipefail` on the sed|tr pipeline — prevents silent truncation of `ralph_loop.sh` on failure
- **TAP-638**: `uninstall.sh` lists stay in sync with `install.sh` — removes the dangling `ralph-upgrade-project` wrapper
- **TAP-646**: `ralph-tester` model matches docs (sonnet, not haiku); `ralph` / `ralph-architect` use valid `Agent(...)` tool schema
- **TAP-649**: `update-badges.yml` surfaces test failures instead of masking with `|| true`, and sanitizes `grep -c` output
- **TAP-651**: `lib/metrics.sh` and `lib/github_issues.sh` now build JSON/JSONL with `jq -n` instead of manual concat — no more JSON injection / corruption via field content
- Close missing `fi` branch introduced by the TAP-643 jq-patch refactor

---

## [2.7.0] — 2026-04-19

### Added
- **TAP-575**: Ralph-owned canonical skill library — `templates/skills/global/` now ships 5 Tier S skills (`search-first`, `tdd-workflow`, `simplify`, `context-audit`, `agentic-engineering`), each with Ralph-hardened `SKILL.md` + concrete loop examples under `examples/`. Every skill carries the Ralph frontmatter standard (name/description/version/ralph/ralph_version_min/attribution/user-invocable/disable-model-invocation/allowed-tools) and the four-section contract (When to invoke, Ralph-specific guidance, sub-agent integration, Exit criteria). 13 BATS cases in `tests/unit/test_skill_frontmatter.bats` + `test_skill_content.bats` enforce the schema so the retro/auto-tune loop (TAP-578/579) can rely on a stable shape. Combined with TAP-574, running `install.sh` now seeds `~/.claude/skills/` with the full Ralph baseline.
- **TAP-574**: Global Claude skill baseline via `install.sh` — new `lib/skills_install.sh` syncs `templates/skills/global/<name>/` into `~/.claude/skills/<name>/` with `.ralph-managed` sidecar for idempotency. Three install cases: fresh copy + sidecar; re-install refreshes only files whose hash still matches Ralph's baseline (WARN on user-modified); user-authored dirs without a sidecar are skipped. `uninstall.sh` and `install.sh uninstall` remove only Ralph-owned files, preserving user edits. `ralph-upgrade` picks up new baselines automatically. 13 BATS cases in `tests/unit/test_skills_install.bats`.

### Fixed
- **TAP-538**: Sync `.ralph/hooks/` with templates and harden circuit breaker self-healing — corrupt `.circuit_breaker_state` is now auto-reinitialized to `CLOSED` instead of crashing the loop; `ralph-doctor` warns on hook drift vs templates
- **TAP-537**: Unmask integration tests — `npm run test:integration` is now a hard-failing CI gate; deterministic eval suite added to required CI; stale version assertion, missing mock exec bit, and missing fixture repaired
- **TAP-535**: Atomic state writes and `pipefail` — all counter/state-file writes go through `atomic_write()` helper (write→fsync→mv); `set -o pipefail` enabled after library sourcing; Bash < 4 rejected at startup
- **TAP-534/533/536**: Security — sed/eval injection fixes in `ralph_loop.sh`; Linear API backend now fail-loud (returns non-zero + stderr on any error, never silently defaults to "complete")

---

## [2.6.0] — 2026-04

### Added
- **Linear task backend** (`RALPH_TASK_SOURCE=linear`) — replaces `fix_plan.md` reads with Linear GraphQL API; requires `LINEAR_API_KEY` and `RALPH_LINEAR_PROJECT`; fail-loud on API errors (TAP-536 pattern)
- **`ralph-upgrade-project`** — propagate runtime files (hooks, templates) to existing managed projects without re-running full setup

### Changed
- Resolved 14 open issues; fixed 24 pre-existing test failures from integration gate

---

## [2.5.0] — 2026-03

### Added
- **Structured hook logging** — `on-stop.sh`, `on-session-start.sh`, `on-task-completed.sh` emit structured JSON lines for observability
- **Import graph + plan optimizer** (`lib/import_graph.sh`, `lib/plan_optimizer.sh`) — auto-reorder `fix_plan.md` tasks by dependency; Python SDK counterparts in `sdk/ralph_sdk/import_graph.py` and `sdk/ralph_sdk/plan_optimizer.py`
- **Episodic memory** (`sdk/ralph_sdk/memory.py`) — cross-session keyword-indexed failure/success recall with age decay
- **Task complexity classifier** (`sdk/ralph_sdk/complexity.py`, `lib/complexity.sh`) — 5-level TRIVIAL→ARCHITECTURAL classifier feeds dynamic model routing

### Changed
- Version bumped to 2.5.0; documentation updated

---

## [2.4.0] — 2026-02

### Added
- **Plan optimization epic** — automatic `fix_plan.md` task reordering at session start (`RALPH_NO_OPTIMIZE` disables); vague task file resolution via `ralph-explorer` (Haiku)
- **`RALPH_NO_OPTIMIZE`**, **`RALPH_NO_EXPLORER_RESOLVE`**, **`RALPH_MAX_EXPLORER_RESOLVE`** config variables

### Fixed
- `CLAUDE_CODE_CMD` from `.ralphrc` now respected in agent mode
- `ALLOWED_TOOLS` works correctly in agent mode

### Changed
- Default `MAX_CALLS_PER_HOUR` raised from 100 to 200 (v2.4.1 patch)

---

## [2.3.0] — 2026-01

### Added
- **Phase 14-17 features**: OpenTelemetry tracing (`lib/tracing.sh`), Docker sandbox v2 with rootless + gVisor support (`lib/sandbox.sh`), cross-session memory (`lib/memory.sh`), cost-aware routing with token rate limiting (`sdk/ralph_sdk/cost.py`), adaptive timeout with percentile tracking (`sdk/ralph_sdk/circuit_breaker.py`)
- **Continue-As-New** (`CTXMGMT-3`) — Temporal-inspired session reset after `RALPH_MAX_SESSION_ITERATIONS` (default 20) or `RALPH_MAX_SESSION_AGE_MINUTES` (default 120)
- **Completion indicator decay** (SDK-SAFETY-3) — stale "done" signals reset when productive work occurs without `EXIT_SIGNAL: true`
- **MCP server process cleanup** (`ralph_cleanup_orphaned_mcp`) — kills orphaned MCP grandchild processes after each CLI invocation; Windows uses PowerShell CIM; Linux/macOS uses pgrep/kill
- **Upstream sync epic** (USYNC) — question detection, stuck-loop detection, CB permission denial, heuristic exit suppression, tmux sub-agent progress

### Fixed
- `jq` bootstrap in install path
- `ralph-doctor` PATH resolution
- WSL PowerShell auto-patching — bare `powershell` hooks auto-patched to `powershell.exe`

---

## [2.2.0] — 2025-12

### Added
- **SDK v2.1.0** — `ContinueAsNewState`, `plan_optimizer`, `import_graph`, `memory`, `complexity` modules; all models Pydantic v2; fully async with `run_sync()` wrapper
- **LOGFIX epic** — 8 production bug fixes from log analysis

### Fixed
- Block `git commit --trailer "Made-with: Cursor"` short `--no-verify` flag in hooks

---

## [2.0.0] — 2025-11

### Added
- **Python SDK v2.0.0** — full async agent, Pydantic v2 models, pluggable `RalphStateBackend` (File + Null), `EvidenceBundle` output, TaskPacket conversion, `CircuitBreaker` class, `ContextManager`, `CostTracker`, `MetricsCollector`, `JsonlMetricsCollector`
- **Sub-agents** — ralph-explorer (Haiku), ralph-tester (Sonnet, worktree-isolated), ralph-reviewer (Sonnet), ralph-architect (Opus)
- **Epic-boundary QA deferral** — ralph-tester and ralph-reviewer skipped mid-epic; mandatory before `EXIT_SIGNAL: true`
- **Speed optimizations** (v1.8.4+) — `bypassPermissions`, `effort: medium`, disabled PostToolUse hooks for throughput; increased batch sizes to 8 SMALL / 5 MEDIUM
- **FAILURE.md / FAILSAFE.md / KILLSWITCH.md** — failure protocol documents with audit logging
- **Hook-based response analysis** — `on-stop.sh` writes `status.json`; loop reads from it instead of parsing raw CLI output; `response_analyzer.sh` removed
- **File protection hooks** — `protect-ralph-files.sh` and `validate-command.sh` as PreToolUse hooks replace `file_protection.sh` module

### Changed
- **Phase 14 modernization** — `lib/metrics.sh`, `lib/notifications.sh`, `lib/backup.sh`, `lib/github_issues.sh`, `lib/sandbox.sh`, `lib/tracing.sh`, `lib/complexity.sh`, `lib/memory.sh` added
- `response_analyzer.sh` removed (replaced by hook)
- `file_protection.sh` removed (replaced by hooks)

---

## [1.9.0] — 2025-10

### Added
- **Cost-aware routing** — task complexity classifier, dynamic model routing, token rate limiting (Phase 8)
- **Task batching** — up to 8 SMALL / 5 MEDIUM tasks per invocation

---

## [1.8.x] — 2025-10

### Added
- **`--live` JSONL pipeline** — real-time streaming with tool names, elapsed time, sub-agent events, error extraction
- **Windows / Git Bash support** — MINGW detection, PowerShell MCP cleanup, WSL2 filesystem resilience
- **WSL version divergence detection** — compares WSL vs Windows `~/.ralph/` versions at startup
- **Log rotation** — `rotate_ralph_log()` on size threshold; `cleanup_old_output_logs()` beyond file count limit
- **Dry-run mode** (`--dry-run` / `DRY_RUN=true`) — simulates a loop without API calls
- **`ralph-enable` / `ralph-enable-ci`** — interactive and non-interactive setup wizards
- **`ralph-import`** — PRD/spec → Ralph task conversion
- **`ralph-doctor`** — dependency verification
- **`ralph-migrate`** — `.ralph/` directory migration

### Fixed
- Stream filter suppresses raw JSONL leaking to terminal in `--live` mode
- SIGTERM/SIGINT treated as clean stops, not crashes
- Compound command pattern support (`&&`, `||`, `;` in `ALLOWED_TOOLS`)

---

## [1.2.0] — 2025-10 (Phase 5)

### Added
- Stream parser v2 — JSONL primary path, multi-result filtering, unescape RALPH_STATUS
- WSL reliability polish — temp file cleanup, child process cleanup
- Circuit breaker decay — sliding window failure detection, session reinitialization

---

## [1.0.0] — 2025-09 (Initial)

### Added
- Core autonomous loop (`ralph_loop.sh`) — dual-condition exit gate, four-layer rate limit detection, session continuity
- Circuit breaker — three-state CLOSED/HALF_OPEN/OPEN with cooldown auto-recovery
- `ralph-setup` — project scaffolding with `.ralph/` directory structure
- `ralph-monitor` — live tmux dashboard
- BATS test suite — unit and integration tests via `npm test`
