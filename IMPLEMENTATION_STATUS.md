# Implementation Status Summary

**Last Updated**: 2026-03-23
**Version**: v2.3.0
**Overall Status**: 148/148 stories complete across 40 epics (Phases 0-17). SDK v2.1.0 + bash v2.3.0. All phases complete. Phase 14 done (CTXMGMT-3, SANDBOXV2, EVALS complete). Phase 15 ENABLE epic 7/7 done. Phase 17 SDK enhancements 16/16 done (SAFETY, CONTEXT, COST, OUTPUT, LIFECYCLE).

> **Note:** Detailed test counts in older tables below may lag the repo. Run `npm test` for the authoritative count.

---

## Completed: Stream & loop resilience (March 2026)

Delivered in `lib/response_analyzer.sh`, `ralph_loop.sh`, templates, and `docs/specs/`:

- [x] JSONL / `stream-json` normalization and validated `parse_json_response` exit status
- [x] Live mode: WSL2/NTFS output file visibility retry; emergency multi-value JSON collapse before analysis
- [x] Pre-analysis permission denial logging; MCP failure logging from `system` init line
- [x] Circuit breaker per-session counter reset on new Ralph startup
- [x] Default `ALLOWED_TOOLS`: `Bash(git -C *)`, `Bash(grep *)`, `Bash(find *)`
- [x] PROMPT template: explicit STOP after status block; scenario wording for one-task-per-loop
- [x] Optional `.claude/settings.json` (bash `SessionStart`); optional Docker preflight for `label=ralph.mcp=true`
- [x] Epics/stories: `docs/specs/epic-jsonl-stream-resilience.md`, `epic-multi-task-cascading-failures.md`, related stories

Follow-up: add/extend BATS coverage for JSONL and pre-analysis paths (tracked in epic acceptance).

---

## Completed: Loop stability regression fix (March 2026)

**Epic:** [RALPH-LOOP: Loop Stability & Analysis Resilience](docs/specs/epic-loop-stability.md) (Phase 0.5) — **Done**

- [x] **LOOP-1:** Replaced `jq -s 'length'` with streaming `grep -c '"type"'` — eliminates OOM crash on large JSONL streams
- [x] **LOOP-2:** Aggregated permission denials across ALL result objects (not just `tail -1`)
- [x] **LOOP-3:** Added 21 utility patterns to ALLOWED_TOOLS (`xargs`, `sort`, `ls`, `sed`, `awk`, etc.) + PROMPT guidance
- [x] **LOOP-4:** Guarded `update_exit_signals`/`log_analysis_summary` with fail-open error handling; added JSON validation to circuit breaker state writes
- [x] **LOOP-5:** Added EXIT trap, crash code recording (`.last_crash_code`), stale status detection, persistent loop counter

---

## Completed: Hooks + Agent Definition (March 2026)

**Epic:** [RALPH-HOOKS: Hooks + Agent Definition](docs/specs/epic-hooks-agent-definition.md) (Phase 1) — **Done**

- [x] **HOOKS-1:** Created `.claude/agents/ralph.md` agent definition (opus, maxTurns 50, acceptEdits, disallowedTools)
- [x] **HOOKS-2:** Full `.claude/settings.json` with 8 hook events (SessionStart, Stop, PreToolUse x2, PostToolUse x2, SubagentStop, StopFailure)
- [x] **HOOKS-3:** `on-session-start.sh` — injects loop count, task progress, circuit breaker state
- [x] **HOOKS-4:** `on-stop.sh` — parses RALPH_STATUS, atomic status.json writes, circuit breaker updates
- [x] **HOOKS-5:** `validate-command.sh` + `protect-ralph-files.sh` — blocks destructive commands and .ralph/ modifications
- [x] **HOOKS-6:** `build_claude_command()` supports `--agent ralph` with legacy fallback

---

## Completed: Agent Teams + Parallelism (March 2026)

**Epic:** [RALPH-TEAMS: Agent Teams + Parallelism](docs/specs/epic-agent-teams-parallelism.md) (Phase 4) — **Done**

- [x] **TEAMS-1:** Teams config in `.ralphrc` (`RALPH_ENABLE_TEAMS`, `RALPH_MAX_TEAMMATES`, `RALPH_TEAMMATE_MODE`)
- [x] **TEAMS-2:** Team spawning strategy in `ralph.md` (file ownership scopes, sequential fallback)
- [x] **TEAMS-3:** `ralph-bg-tester.md` background agent (sonnet, maxTurns 10, report-only)
- [x] **TEAMS-4:** `TeammateIdle` + `TaskCompleted` hooks with live.log logging
- [x] **TEAMS-5:** `.gitignore` exclusions for worktrees, settings.local.json, agent-memory

---

## Completed: Sub-agents (March 2026)

**Epic:** [RALPH-SUBAGENTS: Sub-agents](docs/specs/epic-subagents.md) (Phase 2) — **Done**

- [x] **SUBAGENTS-1:** Created `.claude/agents/ralph-explorer.md` (haiku, read-only, maxTurns 20)
- [x] **SUBAGENTS-2:** Created `.claude/agents/ralph-tester.md` (sonnet, worktree isolation, maxTurns 15)
- [x] **SUBAGENTS-3:** Created `.claude/agents/ralph-reviewer.md` (sonnet, read-only, maxTurns 10)
- [x] **SUBAGENTS-4:** Updated ralph.md with sub-agent workflow and `Agent(ralph-explorer, ralph-tester, ralph-reviewer)` allowlist
- [x] **SUBAGENTS-5:** Enhanced `on-subagent-done.sh` hook with duration tracking, error logging, and failure handling instructions

---

## Completed: Skills + Bash Reduction (March 2026)

**Epic:** [RALPH-SKILLS: Skills + Bash Reduction](docs/specs/epic-skills-bash-reduction.md) (Phase 3) — **Done**

- [x] **SKILLS-1:** Created `.claude/skills/ralph-loop/SKILL.md` (user-invocable, dynamic context injection)
- [x] **SKILLS-2:** Created `.claude/skills/ralph-research/SKILL.md` (model-invocable, delegates to ralph-explorer)
- [x] **SKILLS-4:** Removed `lib/file_protection.sh` (-58 lines) — superseded by PreToolUse hooks
- [x] **SKILLS-5:** Simplified `lib/circuit_breaker.sh` (~485 → ~200 lines) — progress detection moved to on-stop.sh hook
- [x] **SKILLS-3:** Removed `lib/response_analyzer.sh` (-1042 lines) — response analysis handled by on-stop.sh hook → status.json

---

## Completed: Docker Sandbox (March 2026)

**Epic:** [RALPH-SANDBOX: Docker Sandbox Execution](docs/specs/EPIC-STORY-INDEX.md) (Phase 11) — **Done**

- [x] **SANDBOX-1:** Created `lib/sandbox.sh` module with sandbox_create/status/logs/stop/cleanup/available functions
- [x] **SANDBOX-2:** `ralph --sandbox` runs loop inside Docker container with signal forwarding, host streaming, graceful fallback
- [x] Created `Dockerfile.sandbox` (Ubuntu 24.04, Node.js, Python 3, Claude CLI, non-root user)

---

## Completed: GitHub Issue Integration (March 2026)

**Epic:** [RALPH-GHISSUE: GitHub Issue Integration](docs/specs/EPIC-STORY-INDEX.md) (Phase 10) — **Done**

- [x] **GHISSUE-1:** `ralph --issue 42` imports GitHub issue into fix_plan.md (gh CLI or GITHUB_TOKEN)
- [x] **GHISSUE-2:** Issue completeness assessment on 4 dimensions (problem clarity, repro steps, expected behavior, scope)
- [x] **GHISSUE-3:** `ralph --issues` with --issue-label and --issue-assignee filters
- [x] **GHISSUE-4:** `ralph --batch` processes multiple issues sequentially with per-issue results
- [x] **GHISSUE-5:** Lifecycle management: completion comments, agent:completed/agent:failed labels, optional auto-close

---

## Completed: Validation Testing (March 2026)

**Epic:** [RALPH-TEST: Validation Testing](docs/specs/EPIC-STORY-INDEX.md) (Phase 9) — **Done**

- [x] **TEST-1:** tmux integration tests (session creation, graceful degradation)
- [x] **TEST-2:** Monitor dashboard tests (loop count, API calls, CB state display)
- [x] **TEST-3:** Status update tests (field validation, JSON output, staleness, atomic writes)
- [x] **TEST-4:** CLI enhancement tests (all modern flags: --sdk, --stats, --issue, --sandbox)
- [x] **TEST-5:** SDK integration tests (Python pytest suite for agent, config, tools, status)
- [x] **TEST-6:** Backward compatibility tests (.ralphrc versions, status.json, fix_plan format, hooks)
- [x] **TEST-7:** E2E full loop tests (dry-run, mock CLI, state round-trips)

---

## Completed: Observability (March 2026)

**Epic:** [RALPH-OBSERVE: Metrics, Notifications & Recovery](docs/specs/EPIC-STORY-INDEX.md) (Phase 8) — **Done**

- [x] **OBSERVE-1:** Lightweight metrics — monthly JSONL in `.ralph/metrics/`, `ralph --stats` summary, `--stats-json` for machine-readable
- [x] **OBSERVE-2:** Notification system — terminal, OS native (notify-send/osascript), webhook POST, terminal bell sound
- [x] **OBSERVE-3:** State backup/rollback — auto-snapshots before each loop, `ralph --rollback`, max 10 backups

---

## Completed: Configuration & Infrastructure (March 2026)

**Epic:** [RALPH-CONFIG: Configuration & Infrastructure](docs/specs/EPIC-STORY-INDEX.md) (Phase 7) — **Done**

- [x] **CONFIG-1:** `ralph.config.json` support — JSON alternative to .ralphrc, jq parsing in bash, native in SDK, `ralph_export_config()`
- [x] **CONFIG-2:** SDK installation in `install.sh` — Python 3.12+ detection, venv creation, `ralph-sdk` and `ralph-doctor` commands
- [x] **CONFIG-3:** CLI reference (`docs/cli-reference.md`) and SDK guide (`docs/sdk-guide.md`)

---

## Completed: Agent SDK Integration (March 2026)

**Epic:** [RALPH-SDK: Agent SDK Integration](docs/specs/EPIC-STORY-INDEX.md) (Phase 6) — **Done**

- [x] **SDK-1:** Python SDK agent replicating core loop (sdk/ralph_sdk/agent.py) — read PROMPT.md → invoke Claude → parse response → check exit → repeat
- [x] **SDK-2:** Custom tools: ralph_status, ralph_rate_check, ralph_circuit_state, ralph_task_update (sdk/ralph_sdk/tools.py)
- [x] **SDK-3:** Hybrid architecture — RalphAgentInterface protocol, TaskInput union type, TaskResult/Signal output, `ralph --sdk` dispatch, TheStudio adapter
- [x] **SDK-4:** Migration strategy document (`docs/sdk-migration-strategy.md`) — CLI/SDK/TheStudio modes, decision matrix, migration paths

---

## Completed: Stream Parser v2 & WSL Polish (March 2026)

**Epic:** [RALPH-STREAM: Stream Parser v2](docs/specs/epic-stream-parser-v2.md) (Phase 5) — **Done**

- [x] **STREAM-1:** Renamed `ralph_emergency_jsonl_normalize` → `ralph_extract_result_from_stream`; WARN→INFO for normal extraction
- [x] **STREAM-2:** Multi-result count now filters subagent results (no false "multi-task violation" warnings)
- [x] **STREAM-3:** Auto-unescapes JSON-encoded `\n` in on-stop.sh before RALPH_STATUS field extraction; fallback WORK_TYPE inference

**Epic:** [RALPH-WSL: WSL Reliability Polish](docs/specs/epic-wsl-reliability-polish.md) (Phase 5) — **Done**

- [x] **WSL-1:** Added `rm -f` after atomic `mv` calls, `.gitignore` patterns for orphans, stale temp cleanup on startup
- [x] **WSL-2:** Pipeline PID tracking + kill in `cleanup()` trap handler; clean SIGINT exit without child process noise

---

## Current State

### Test Coverage

| Metric | Current |
|--------|---------|
| **Total Tests** | 736+ |
| **Pass Rate** | 100% |
| **Test Files** | 17 unit + integration |

### Code Quality

- **CI/CD**: ✅ GitHub Actions operational
- **Hook-based analysis**: ✅ on-stop.sh → status.json (replaces removed response_analyzer.sh)
- **Circuit Breaker**: ✅ lib/circuit_breaker.sh (simplified three-state pattern)
- **Date Utilities**: ✅ lib/date_utils.sh (cross-platform)
- **Sub-agents**: ✅ ralph-explorer, ralph-tester, ralph-reviewer, ralph-bg-tester
- **Skills**: ✅ ralph-loop, ralph-research

---

## Phase Status

### Phase 1: CLI Modernization (100% Complete)

**Completed**:
- [x] #28 - Update CLI commands with modern options
- [x] #29 - Enhance response parsing for JSON output
- [x] #30 - Add session management for continuity
- [x] #31 - Update ralph-import with CLI enhancements
- [x] #48 - Shell escaping security fix
- [x] #50 - Input validation for --allowed-tools
- [x] #10 - CLI parsing tests (27 tests)
- [x] #11 - Installation tests (14 tests)
- [x] #12 - Project setup tests (36 tests)
- [x] #13 - PRD import tests (33 tests)
- [x] #25 - Create CONTRIBUTING.md guide (P3)
- [x] #24 - Create TESTING.md documentation (P3)
- [x] #26 - Update README with testing instructions (P3)
- [x] #27 - Add badges to README (P3)

**Remaining**: None — Phase 1 complete.

Note: #51 (session expiration) was implemented as part of the session management work.
Session expiration is fully functional via `CLAUDE_SESSION_EXPIRY_HOURS` (default 24h),
`get_session_file_age_hours()`, and `init_claude_session()` in ralph_loop.sh.

### Phase 2: Agent SDK Integration (100% Complete)

- [x] #32 - Create Agent SDK proof of concept (P2) — sdk/ralph_sdk/agent.py
- [x] #33 - Define custom tools for Agent SDK (P2) — sdk/ralph_sdk/tools.py
- [x] #34 - Implement hybrid CLI/SDK architecture (P2) — RalphAgentInterface, TaskInput/TaskResult, --sdk flag
- [x] #35 - Document SDK migration strategy (P2) — docs/sdk-migration-strategy.md

### Phase 3: Configuration & Infrastructure (100% Complete)

- [x] #36 - Add JSON configuration file support (P2) — ralph.config.json, load_json_config(), ralph_export_config()
- [x] #37 - Update installation for SDK support (P2) — install.sh SDK detection, ralph-sdk and ralph-doctor commands
- [x] #18 - Implement log rotation feature (P2) — rotate_ralph_log(), cleanup_old_output_logs(), --log-max-size/--log-max-files flags
- [x] #19 - Implement dry-run mode feature (P2) — --dry-run flag, DRY_RUN .ralphrc config, dry_run_simulate()
- [x] #20 - Implement config file support (.ralphrc) (P2) — .ralphrc sourced at startup, env overrides, load_ralphrc()
- [x] #38 - Create CLI and SDK documentation (P3) — docs/cli-reference.md, docs/sdk-guide.md
- [x] #21 - Implement metrics and analytics (P3) — lib/metrics.sh, --stats, monthly JSONL
- [x] #22 - Implement notification system (P3) — lib/notifications.sh, terminal/OS/webhook/sound
- [x] #23 - Implement backup and rollback system (P3) — lib/backup.sh, --rollback, auto-snapshots

### Phase 4: Validation Testing (100% Complete)

- [x] #14 - Implement tmux integration tests (P2) — tests/unit/test_tmux_integration.bats
- [x] #15 - Implement monitor dashboard tests (P2) — tests/unit/test_monitor_dashboard.bats
- [x] #16 - Implement status update tests (P2) — tests/unit/test_status_update.bats
- [x] #39 - Implement CLI enhancement tests (P3) — tests/unit/test_cli_modern_flags.bats
- [x] #40 - Implement SDK integration tests (P3) — sdk/tests/test_agent.py, test_config.py, test_tools.py, test_status.py
- [x] #41 - Implement backward compatibility tests (P3) — tests/unit/test_backward_compat.bats
- [x] #17 - Implement E2E full loop tests (P3) — tests/integration/test_e2e_loop.bats

### Phase 5: GitHub Issue Integration (100% Complete)

- [x] #69 - Allow plan import from GitHub Issue (P4) — ralph --issue NUM, lib/github_issues.sh
- [x] #70 - Assess issue completeness and generate implementation plan (P4) — ralph_assess_issue(), 4-dimension scoring
- [x] #71 - Filter and select GitHub issues by metadata (P4) — ralph --issues, --issue-label, --issue-assignee
- [x] #72 - Batch processing and issue queue management (P4) — ralph --batch, --batch-issues, --stop-on-failure
- [x] #73 - Issue lifecycle management and completion workflows (P4) — ralph_complete_issue(), labels, auto-close

### Phase 6: Sandbox Execution Environments (100% Complete — Docker only)

- [x] #49 - Sandbox execution environments (umbrella) (P4) — lib/sandbox.sh module
- [x] #74 - Local Docker Sandbox Execution (P4) — ralph --sandbox, Dockerfile.sandbox
- ~~#75~~ - E2B Cloud Sandbox Integration → TheStudio Premium
- ~~#76~~ - Sandbox File Synchronization → TheStudio Premium
- ~~#77~~ - Sandbox Security and Resource Policies → TheStudio Premium
- ~~#78~~ - Generic Sandbox Interface and Plugin Architecture → TheStudio Premium
- ~~#79~~ - Daytona Sandbox Integration → TheStudio Premium
- ~~#80~~ - Cloudflare Sandbox Integration → TheStudio Premium

---

## Recent Completions

### v2.2.0 (2026-03-23)
- **LOGFIX Epic (Phase 16) — 8/8 Done:** Production log issue fixes sourced from TheStudio, tapps-brain, TappMCP log analysis
  - **LOGFIX-1**: Fixed graceful exit logged as crash (exit code 2) — cleanup trap now checks status.json before reporting crash
  - **LOGFIX-2**: Hardened concurrent instance lock — auto-terminates stale PID instead of manual kill advice
  - **LOGFIX-3**: Stream extraction failures on timeout downgraded from ERROR to WARN — prevents misleading error logs
  - **LOGFIX-4**: Fast-trip circuit breaker — 3 consecutive instant failures (0 tools, <30s) now trips immediately
  - **LOGFIX-5**: Error count categorization — expected tool scope errors vs system errors reported separately
  - **LOGFIX-6**: Stall detection for persistent TESTS_STATUS: DEFERRED — warns at 5, trips CB at 10 consecutive loops
  - **LOGFIX-7**: Fixed permission denied warning — distinguishes built-in tool scope denials from ALLOWED_TOOLS issues
  - **LOGFIX-8**: Circuit breaker state consistency — total_opens now incremented on OPEN transition in on-stop.sh hook
- **Files Modified:** `ralph_loop.sh`, `lib/circuit_breaker.sh`, `templates/hooks/on-stop.sh`

### v2.1.0 (2026-03-23)
- 13 stories completed, 3 bugs fixed — largest single-session delivery
- **Bug Fixes:**
  - **#224**: Fixed exit confidence false-positive completions — completion_indicators now reset on productive work between exit signals
  - **#154**: Fixed ALLOWED_TOOLS wildcard glob expansion — added `noglob` protection during pattern parsing and validation
  - **#221**: Added `--no-gpg-sign` blocking to validate-command.sh + test coverage for `--no-verify` variants
- **ENABLE Epic (Phase 15) — 4/7 Done:**
  - **ENABLE-1**: `.ralphrc` added to required artifacts in `check_existing_ralph()` — projects without `.ralphrc` now correctly detected as partial
  - **ENABLE-2**: Strict validation for `--from` (must be beads/github/prd) and `--prd` (file must exist) in both wizard and CI mode
  - **ENABLE-3**: Per-source import reporting with task counts, failure reasons, and summary table
  - **ENABLE-4**: Timestamped backups before `--force` overwrites; `.gitignore` merge (append Ralph entries) instead of overwrite
- **OTEL Epic — 4/4 Done (completed):**
  - **OTEL-3**: Per-trace cost attribution with configurable rates (Haiku/Sonnet/Opus), budget alerts at threshold, costs.jsonl tracking
  - **OTEL-4**: OTLP HTTP exporter with offset tracking (no re-export), batch mode, configurable headers
- **COSTROUTE Epic — 4/4 Done (completed):**
  - **COSTROUTE-3**: Cacheable prompt structure (stable prefix + dynamic suffix), prefix hash tracking for cache validation
  - **COSTROUTE-4**: `ralph --cost-dashboard` with per-model breakdown, budget progress bar, JSON output mode
- **CTXMGMT Epic — 2/3 Done:**
  - **CTXMGMT-1**: Progressive context loading — only loads current epic section + N items, summarizes completed sections
  - **CTXMGMT-2**: Task decomposition signals — detects oversized tasks (file count, timeout, complexity, no-progress), injects hints
- **New Files:** `lib/context_management.sh`, `tests/unit/test_context_management.bats`, `tests/unit/test_cost_optimization.bats`
- **New Tests:** 58+ new test cases across 7 test files

### v2.0.2 (2026-03-23)
- SDK integration polish: 7 fixes for TheStudio bridge-layer compatibility
- **POLISH-1**: Exported `ComplexityBand`, `TrustTier`, `RiskFlag`, `IntentSpecInput`, `TaskPacketInput` from `__init__.py`
- **POLISH-2**: Added `created_at: datetime` field to `EvidenceBundle`
- **POLISH-3**: `FileStateBackend` and `NullStateBackend` now explicitly inherit from `RalphStateBackend` Protocol
- **POLISH-4**: Synced `__version__` in `__init__.py` with `pyproject.toml` (both `"2.0.2"`)
- **POLISH-5**: Added `system_prompt: str | None` parameter to `run_iteration()` — passes through to Claude CLI via `--system-prompt`
- **POLISH-6**: Added public `cancel()` method to `RalphAgent` for graceful loop cancellation
- **POLISH-7**: Added `tokens_in`/`tokens_out` fields to `TaskResult` and `EvidenceBundle`, extracted from JSONL result messages

### v2.0.1 (2026-03-22)
- Comprehensive code review and bug fix audit: 24 fixes across 16 files
- **Python SDK**: Fixed sync-call-to-async crash in `status.py`, orphaned subprocess on timeout in `agent.py`, blocking I/O in async `state.py`, enum serialization in `tools.py`, `.ralphrc` export keyword parsing in `config.py`, session ID persistence in `agent.py`
- **Bash core**: Fixed crash-recovery dead code in `ralph_loop.sh`, `local` masking return code in `create_files.sh`, `ralph-upgrade` missing from `uninstall.sh`
- **Libraries**: Fixed dotfile restoration in `backup.sh`, `((count++))` set -e crash in `task_sources.sh`, `total_opens` reset in `circuit_breaker.sh`, osascript injection in `notifications.sh`, JSON sort in `memory.sh`
- **Hooks**: Fixed `printf '%b'` data corruption and numeric validation in `on-stop.sh`, IFS splitting in `on-subagent-done.sh`, `--force-with-lease` false positive in `validate-command.sh`, temp file leak in `on-stop-failure.sh`
- **Config**: Fixed license mismatch (ISC→MIT in `package.json` to match LICENSE file and `pyproject.toml`)

### v0.9.8 (2026-01-10)
- Modern CLI for PRD import with JSON output
- 11 new tests for modern CLI features
- Test count: 265 → 276

### v0.9.7
- Session lifecycle management with auto-reset triggers
- 26 new tests for session continuity
- Test count: 239 → 265

### v0.9.6
- JSON output and session management
- 16 new tests for Claude CLI format
- Test count: 223 → 239

### v0.9.5
- PRD import tests (22 tests)
- Test count: 201 → 223

### v0.9.4
- Project setup tests (36 tests)
- Test count: 165 → 201

### v0.9.3
- Installation tests (14 tests)
- Test count: 151 → 165

### v0.9.2
- Prompt file fix (-p flag)
- 6 new tests for build_claude_command
- Test count: 145 → 151

### v0.9.1
- Modern CLI commands (Phase 1.1)
- 70 new tests (JSON, CLI modern, CLI parsing)
- CI/CD pipeline operational

### v0.9.0
- Circuit breaker enhancements
- Two-stage error filtering
- Multi-line error matching

---

## Closed Issues

<details>
<summary>Click to expand (20 closed issues)</summary>

| Issue | Title |
|-------|-------|
| #1 | Cannot find file ~/.ralph/lib/response_analyzer.sh |
| #2 | is_error: false triggers "error" circuit breaker incorrectly |
| #5 | Bug: date: illegal option -- d on macOS |
| #7 | Review codebase for updated Anthropic CLI |
| #10 | Implement CLI parsing tests |
| #11 | Implement installation tests |
| #12 | Implement project setup tests |
| #13 | Implement PRD import tests |
| #28 | Phase 1.1: Update CLI commands with modern options |
| #29 | Phase 1.2: Enhance response parsing for JSON output |
| #30 | Phase 1.3: Add session management for continuity |
| #31 | Phase 1.4: Update ralph-import with CLI enhancements |
| #42 | Windows: Git Bash windows spawn when running Ralph loop |
| #48 | MAJOR-01: Enhance shell escaping to prevent command injection |
| #50 | MAJOR-02: Add input validation for --allowed-tools flag |
| #55 | --prompt-file flag does not exist in Claude Code CLI |
| #56 | Project featured in Awesome Claude Code! |
| #63 | Fix IMPLEMENTATION_PLAN |

</details>

---

## Open GitHub Issues (Stale — Need Closing)

> **Note:** The issues below are still open on GitHub but the underlying work was completed via the epic/story system. They should be closed with "completed" or "deferred" status.

### Completed (close as done)
| Issue | Phase | Title | Completed Via |
|-------|-------|-------|---------------|
| #32 | 2.1 | Create Agent SDK proof of concept | SDK-1 |
| #33 | 2.2 | Define custom tools for Agent SDK | SDK-2 |
| #34 | 2.3 | Implement hybrid CLI/SDK architecture | SDK-3 |
| #35 | 2.4 | Document SDK migration strategy | SDK-4 |
| #36 | 3.1 | Add JSON configuration file support | CONFIG-1 |
| #37 | 3.2 | Update installation for SDK support | CONFIG-2 |
| #38 | 3.3 | Create CLI and SDK documentation | CONFIG-3 |
| #21 | 3.7 | Implement metrics and analytics | OBSERVE-1 |
| #22 | 3.8 | Implement notification system | OBSERVE-2 |
| #23 | 3.9 | Implement backup and rollback system | OBSERVE-3 |
| #14 | 4.4 | Implement tmux integration tests | TEST-1 |
| #15 | 4.5 | Implement monitor dashboard tests | TEST-2 |
| #16 | 4.6 | Implement status update tests | TEST-3 |
| #39 | 4.1 | Implement CLI enhancement tests | TEST-4 |
| #40 | 4.2 | Implement SDK integration tests | TEST-5 |
| #41 | 4.3 | Implement backward compatibility tests | TEST-6 |
| #17 | 4.7 | Implement E2E full loop tests | TEST-7 |
| #69 | 5.1 | Allow plan import from GitHub Issue | GHISSUE-1 |
| #70 | 5.2 | Assess issue completeness and generate plan | GHISSUE-2 |
| #71 | 5.3 | Filter and select GitHub issues by metadata | GHISSUE-3 |
| #72 | 5.4 | Batch processing and issue queue management | GHISSUE-4 |
| #73 | 5.5 | Issue lifecycle management | GHISSUE-5 |
| #49 | 6.0 | Sandbox execution environments (umbrella) | SANDBOX-1/2 |
| #74 | 6.1 | Local Docker Sandbox Execution | SANDBOX-2 |

### Deferred to TheStudio Premium (close as not-planned)
| Issue | Phase | Title |
|-------|-------|-------|
| #75 | 6.2 | E2B Cloud Sandbox Integration |
| #76 | 6.3 | Sandbox File Synchronization |
| #77 | 6.4 | Sandbox Security and Resource Policies |
| #78 | 6.5 | Generic Sandbox Interface |
| #79 | 6.6 | Daytona Sandbox Integration |
| #80 | 6.7 | Cloudflare Sandbox Integration |

### Fixed in v2.1.0 (close as done)
| Issue | Title | Fixed Via |
|-------|-------|-----------|
| #224 | Exit confidence threshold false-positive completions | Bug fix: completion_indicators decay on progress |
| #154 | Bash wildcard patterns in ALLOWED_TOOLS | Bug fix: noglob during pattern parsing |
| #221 | Block --no-verify for AI agents | Bug fix: expanded validate-command.sh + tests |
| #110 | Token cost tracking | COSTROUTE-4 (cost dashboard) |

### Genuinely Open Issues (active backlog)
| Issue | Priority | Title |
|-------|----------|-------|
| #225 | P2 | No E2E integration tests |
| #223 | P2 | Rate limiter counts invocations only |
| #163 | P3 | Monorepo-aware features |
| #156 | P3 | Windows native support |
| #157 | P3 | Nix flake support |
| #213 | P3 | KEEP_MONITOR_AFTER_EXIT option |
| #211 | P3 | Support .zshrc loading |
| #152 | P3 | Integration tests for task import |
| #138 | P3 | Automate version/test badges |
| #123 | P4 | Session storage format consistency |
| #102 | P4 | Plan limit exhaustion handling |
| #87 | P4 | Beads integration |
| #82 | P4 | Update README with feature docs |

---

## Summary Statistics

| Category | Count |
|----------|-------|
| GitHub Issues (genuinely open) | ~13 |
| GitHub Issues (stale, need closing) | ~30 |
| Closed Issues | 32+ |
| Total Tests | 858+ |
| Test Pass Rate | 100% |
| Epic Stories | 148/148 Done |

---

**Status**: ✅ 148/148 stories complete (100%). 40 epics across 17 phases. SDK v2.1.0 + bash v2.3.0.
**v2.2.0**: 8 production bug fixes from TheStudio/tapps-brain/TappMCP log analysis. LOGFIX epic complete. Critical: graceful exit no longer logged as crash, stale instances auto-killed, stream extraction noise reduced. Medium: fast-trip CB, error categorization, deferred test stall detection, permission denial messages, CB state consistency.
**v2.1.0**: 13 stories + 3 bug fixes in single session. OTEL epic complete (cost attribution, OTLP export). COSTROUTE epic complete (cache optimization, cost dashboard). CTXMGMT 2/3 (progressive loading, decomposition signals). ENABLE 4/7 (state detection, CLI validation, import reporting, force safety). New: `lib/context_management.sh`, `ralph --cost-dashboard`. 58+ new tests.
**Removed** (cumulative): `lib/response_analyzer.sh` (-1042 lines), `lib/file_protection.sh` (-58 lines), simplified `lib/circuit_breaker.sh` (-285 lines). Total: ~1,385 lines of bash removed.
**Added** (cumulative): 4 sub-agent definitions, 2 skills, hook-based analysis, Python SDK (4 modules + tests), 4 lib modules (metrics, notifications, backup, github_issues, sandbox), Dockerfile.sandbox, 3 documentation files, JSON config template, 7 new BATS test files.
**v1.8.0**: All phases complete — SDK integration (Phase 6), JSON config + SDK install + docs (Phase 7), metrics/notifications/backup (Phase 8), comprehensive validation tests (Phase 9), GitHub issue integration (Phase 10), Docker sandbox (Phase 11).
**v2.0.0**: SDK v2 — Pydantic v2 models, async agent loop, pluggable state backend, structured response parsing, active circuit breaker, correlation ID threading, TaskPacket conversion, EvidenceBundle output.
**v2.0.2**: SDK integration polish — 7 fixes for TheStudio bridge-layer compatibility. Exported converter types, added `created_at` timestamp and `tokens_in`/`tokens_out` to EvidenceBundle/TaskResult, explicit Protocol inheritance for state backends, `system_prompt` pass-through on `run_iteration()`, public `cancel()` method, version sync.
**v2.0.1**: Comprehensive code review — 24 bug fixes across 16 files. Critical: `create_files.sh` exit gate always triggered (local masking $?), SDK sync-call-to-async crash (`status.py`), orphaned subprocess on timeout (`agent.py`). High: session ID never persisted, blocking I/O in async context (`state.py`), enum not JSON-serializable (`tools.py`), `.ralphrc` export keyword ignored (`config.py`), backup dotfile restoration (`backup.sh`), `((count++))` crash under set -e (`task_sources.sh`), crash-recovery dead code (`ralph_loop.sh`), `ralph-upgrade` missing from uninstall, `on-stop.sh` arithmetic crashes and data corruption, `on-subagent-done.sh` IFS splitting, `validate-command.sh` false positive on `--force-with-lease`. License mismatch fixed (ISC→MIT).
