# Epic: Idle-Runaway Fix + "Best-in-Industry" Harness Hardening

**Origin:** AgentForge 2026-05-23 campaign — 108 idle ticks, $23.31, 111 loops against an empty Linear backlog.

**Root cause:** [templates/hooks/on-stop.sh:137](../../templates/hooks/on-stop.sh#L137) parser is line-anchored (`grep -E "^[[:space:]]*EXIT_SIGNAL:"`) but Claude emits the entire RALPH_STATUS block on a single line with no `---END_RALPH_STATUS---` terminator. Every field silently defaults → `exit_signal=false`, `files_modified=0`, `work_type=UNKNOWN` → recorded as no-progress → CB OPENs → ralph-runner relaunches → `CB_AUTO_RESET=true` blesses the restart at [lib/circuit_breaker.sh:77-91](../../lib/circuit_breaker.sh#L77-L91) → cycle.

Evidence: `/home/wtthornton/code/AgentForge/.ralph/.exit_signals` is `{done_signals: [], completion_indicators: []}` after 108 idle ticks; `/tmp/ralph-live-AgentForge.log` shows the agent emitted `EXIT_SIGNAL: true` 100+ times inline.

This epic is the bundle of fixes that close the runaway loop AND move Ralph toward the 2026 industry-best harness pattern (structured signals, deterministic guardrails, cost-aware idle ticks).

## Open questions (resolve before filing Linear stories)

1. **PR-9 surface — MCP server vs. Write-tool sentinel?** A new Ralph-shipped MCP server is the canonical 2026 pattern but adds an infra surface (new package, install path, `.mcp.json` registration in every consumer project). A Write-tool sentinel (`Write(.ralph/.exit_signal_intent, "EMPTY_BACKLOG\n<reason>")` watched by an extension to [templates/hooks/on-file-change.sh](../../templates/hooks/on-file-change.sh)) achieves the same structural-capture semantics with zero new infra. **Default below is the Write-tool sentinel — flag if you want the MCP server.**

2. **PR-5 schema migration — additive or replacement?** Brief schema (verified at [.claude/agents/ralph-coordinator.md:88-99](../../.claude/agents/ralph-coordinator.md#L88)) currently has `acceptance_criteria: ["one or more criteria"]` (array of strings). **Default below is additive**: introduce a new field `acceptance_action: "EMIT_EXIT_SIGNAL | CONTINUE_AND_RETRY | BLOCK | IMPLEMENT"` alongside the existing array. Agent reads `acceptance_action` when present, falls back to text. Cleaner migration; existing briefs in `.brief_cache/` keep working.

3. **PR-3 thin-tick aggressiveness — `coordinator_confidence ≥ 0.9` or 0.7?** Looser threshold (0.7) saves more money but risks skipping when coordinator is uncertain. **Default below is 0.9** (conservative; aligns with the 90/10 Pareto split observed in the AgentForge log — coordinator was 0.9+ on 90 of 108 idle ticks).

4. **`EXIT_SIGNAL_HALT_THRESHOLD` documentation surface.** CLAUDE.md says new env vars need a deprecation note in `docs/UPGRADE-PROMPT.md`. **Default below**: document in `UPGRADE-PROMPT.md` only, don't add to the `.ralphrc` template (avoids cluttering the file consumers actually read; opt-in only matters for operators tuning it).

5. **brief.json "empty backlog" signal source.** Verified: brief.json schema has NO `task_input` field (only `task_id`, `task_summary`, etc. — see [lib/brief.sh:83-98](../../lib/brief.sh#L83)). The thin-tick eligibility check in PR-3 cannot read brief.json for emptiness. **Refined to use existing TAP-741 signal**: read `.ralph/status.json:linear_open_count` written by on-stop.sh from the agent's previous-loop emission. Already in place; no new path.

## Goal

After this epic ships, an empty-backlog campaign on AgentForge (or any consumer project) should:

1. Halt within **3 loops** of the agent first emitting `EXIT_SIGNAL: true`, with `exit_reason=exit_signal_quorum`.
2. Cost **< $0.10 total** for those 3 idle ticks (vs. $5+ today).
3. Survive a ralph-runner-induced relaunch — auto-reset must NOT override a fresh exit-signal quorum.
4. Surface MCP-degraded loops as `STATUS: BLOCKED + exit_reason=mcp_unreachable` rather than improvised EXIT_SIGNAL emissions.

## Non-goals

- Removing `CB_AUTO_RESET=true` from `.ralphrc` defaults (backward compat — many consumers rely on it).
- Replacing the text RALPH_STATUS block entirely (P0-B introduces a structured tool but keeps text as fallback).
- Per-loop cost cap (CLAUDE.md memory says this was deliberately removed; we add a *per-session hard cap* opt-in instead).

## Sequencing

Three waves. Wave 1 must ship together — each fix in isolation leaves a known-bad state.

```
Wave 1 (immediate halt safety + cost stop)         Wave 2 (correctness)              Wave 3 (durability)
─────────────────────────────────────────         ─────────────────────              ────────────────────
PR-1 parser hardening    ──────────────┐
PR-2 exit-signal quorum  ─── depends ──┤
PR-3 thin idle tick      ─── depends ──┤
                                       ▼
                          PR-4 MCP health injection   ──────┐
                          PR-5 brief acceptance enum  ──────┤
                          PR-6 repetition detector    ──────┤
                                                            ▼
                                                  PR-7 session cost-cap kill switch
                                                  PR-8 idle-tick cache hygiene
                                                  PR-9 structured exit tool (mcp__ralph__exit_signal)
```

Inter-wave dependencies:
- PR-2 and PR-3 both require PR-1 — without the parser fix they have no exit signals to act on.
- PR-4 is independent of Wave 1 but valuable to ship in the same release window so the agent has fewer reasons to improvise.
- PR-9 is the durable replacement for the entire text-regex path. Ship it last so the team can validate the text-path fixes work, then migrate.

---

## Wave 1 — Stop the bleeding

### PR-1 — `fix(hooks): parse single-line RALPH_STATUS blocks`

**Problem:** [templates/hooks/on-stop.sh:137-148](../../templates/hooks/on-stop.sh#L137-L148) anchors every field grep to column 0 (`^[[:space:]]*FIELDNAME:`). When Claude emits the whole block on one line (`---RALPH_STATUS--- STATUS: COMPLETE … EXIT_SIGNAL: true …`), no field matches and every value silently defaults.

**Change:**

1. **Block-normalize step** — after extracting `_status_block` at [on-stop.sh:100](../../templates/hooks/on-stop.sh#L100) and BEFORE the existing awk uppercase pass at line 121, insert a `sed` line-splitter that injects a newline before any mid-line known-field token. Closed enum of 15 tokens (verified against [on-stop.sh:138-159](../../templates/hooks/on-stop.sh#L138)):

   ```bash
   # Concrete implementation — drop in between line 102 and line 120:
   if [[ -n "$_status_block" ]]; then
     _status_block=$(printf '%s' "$_status_block" | sed -E '
       s/[[:space:]]+(STATUS|TASKS_COMPLETED_THIS_LOOP|FILES_MODIFIED|WORK_TYPE|EXIT_SIGNAL|RECOMMENDATION|TESTS_STATUS|LINEAR_ISSUE|LINEAR_URL|LINEAR_EPIC|LINEAR_EPIC_DONE|LINEAR_EPIC_TOTAL|LINEAR_OPEN_COUNT|LINEAR_DONE_COUNT|NEXT_INTENDED_ISSUE):/\n\1:/g
     ')
   fi
   ```

   The `[[:space:]]+` before the capture group is the key — it only fires when the token is preceded by whitespace (i.e. mid-line). The first token in a single-line block (`---RALPH_STATUS--- STATUS: ...`) IS preceded by whitespace after `---RALPH_STATUS---`, so it gets split. Idempotent: on already-multi-line input, tokens are at column 0 with no preceding whitespace on their own line → no match → no-op.

2. **Fallback parser** — after the existing line-anchored greps at lines 137-148, if `exit_signal` is still empty/false AND `_status_block` is non-empty (i.e. block-normalize couldn't find a match the anchored grep would catch), run a value-restricted second pass:

   ```bash
   if [[ -z "$exit_signal" || "$exit_signal" == "false" ]] && [[ -n "$_status_block" ]]; then
     # Word-boundary, value-enum-restricted — no anchor required, no prose false-positives
     _fallback_es=$(printf '%s' "$_status_block" | grep -oE '\bEXIT_SIGNAL:[[:space:]]*(true|false)\b' | tail -1 | sed -E 's/.*:[[:space:]]*//' | tr -d '[:space:]')
     if [[ -n "$_fallback_es" ]]; then
       exit_signal="$_fallback_es"
       log_msg "INFO: on-stop fallback parser hit EXIT_SIGNAL=$_fallback_es (single-line block detected)"
     fi
   fi
   ```

   Word-boundary protects against prose hits (`… does NOT emit EXIT_SIGNAL: false …` — the value enum `(true|false)` locks down the surface; `false` IS the parsed value but it's still the agent's declared intent in the block, which is what we want). Apply the same pattern to `STATUS` (enum `COMPLETE|BLOCKED|IN_PROGRESS|UNKNOWN`) and numeric fields `\b(TASKS_COMPLETED_THIS_LOOP|FILES_MODIFIED):[[:space:]]*([0-9]+)\b`.

3. **Sentinel logging** — already shown above; the `INFO: on-stop fallback parser hit ...` log line lets us count single-line-block occurrences in production via `grep -c "fallback parser hit" .ralph/logs/ralph.log`.

**Tests** (new file `tests/unit/test_on_stop_single_line_status.bats`, 7 fixtures):

| Fixture | Shape | Expected `exit_signal` | Expected `tasks_done` | Expected `files_modified` |
|---|---|---|---|---|
| `multi_line_ideal.txt` | documented multi-line with END marker | `true` | `0` | `0` |
| `single_line_no_end.txt` | the AgentForge shape — all one line, no END | `true` | `0` | `0` |
| `single_line_with_end.txt` | one line but END marker present | `true` | `1` | `2` |
| `multi_line_with_stray_whitespace.txt` | indented fields | `true` | `0` | `0` |
| `field_in_prose.txt` | RECOMMENDATION line contains "did NOT emit EXIT_SIGNAL: false" | `true` (legit emission wins) | `0` | `0` |
| `jsonl_escaped.txt` | `\n` literals from JSONL stream | `true` | `0` | `0` |
| `exit_false_explicit.txt` | single-line block with `EXIT_SIGNAL: false` | `false` | `0` | `0` |

Acceptance: all 7 pass, `INFO: ... fallback parser` line emitted ONLY for fixtures 2, 5, 6.

**Files touched:**
- `templates/hooks/on-stop.sh` (+~40 LoC for block-normalize + fallback)
- `.ralph/hooks/on-stop.sh` (in this repo — kept byte-identical to template per CLAUDE.md drift-detection rule)
- `tests/unit/test_on_stop_single_line_status.bats` (new, +~150 LoC)
- `tests/fixtures/on_stop/` (new dir, 7 fixture files)

**Estimate:** S (1 day). Tight, well-scoped, fully testable in BATS.

**Backout:** delete the block-normalize + fallback paragraph. Anchored greps return to today's behavior.

**Observability after deploy:** grep `.ralph/logs/ralph.log` for `fallback parser` count over 7 days. If non-zero (and it WILL be on AgentForge-shaped projects), confirms the bug was real. Migrate consumer projects with `ralph-upgrade-project`.

---

### PR-2 — `feat(harness): EXIT_SIGNAL quorum wins over CB_AUTO_RESET`

**Depends on:** PR-1 (without it, quorum count is always 0).

**Problem:** [lib/circuit_breaker.sh:77-91](../../lib/circuit_breaker.sh#L77-L91) — at startup, if state is OPEN and `CB_AUTO_RESET=true`, the breaker is forced to CLOSED with no consideration of *why* it was open. A genuine exit-signal quorum from the previous run is lost.

**Change:**

1. Define new env var `EXIT_SIGNAL_HALT_THRESHOLD` (default `3`, documented in `.ralphrc` template comment; do NOT add a new line to `.ralphrc` itself — reuse default in `lib/circuit_breaker.sh` to avoid the deprecation-note requirement in CLAUDE.md).

2. In [lib/circuit_breaker.sh:76](../../lib/circuit_breaker.sh#L76), BEFORE the `if [[ "$CB_AUTO_RESET" == "true" ]]; then` branch, read `$RALPH_DIR/.exit_signals`:

```bash
if [[ -f "$RALPH_DIR/.exit_signals" ]]; then
    local _completion_count
    _completion_count=$(jq -r '.completion_indicators | length' "$RALPH_DIR/.exit_signals" 2>/dev/null || echo 0)
    [[ "$_completion_count" =~ ^[0-9]+$ ]] || _completion_count=0
    if [[ "$_completion_count" -ge "${EXIT_SIGNAL_HALT_THRESHOLD:-3}" ]]; then
        _cb_log_transition "$CB_STATE_OPEN" "$CB_STATE_OPEN" \
            "Exit-signal quorum (${_completion_count} >= ${EXIT_SIGNAL_HALT_THRESHOLD:-3}); refusing auto-reset"
        # Mark halt reason for ralph_loop.sh exit code
        echo "exit_signal_quorum" > "$RALPH_DIR/.harness_halt_reason"
        return 0  # leave CB OPEN
    fi
fi
```

3. **Read site already exists**: [ralph_loop.sh:5425-5431](../../ralph_loop.sh#L5425) already reads `.harness_halt_reason` at the top of the main loop and logs it. No new read site needed — just ensure the write at PR-2 step 2 happens BEFORE the main loop ticks (it does, because `init_circuit_breaker` runs in startup before `main()`). Verify the halt-reason surfacing path: when `.harness_halt_reason` is set, the loop logs "Halt reason: $halt_reason" and exits. Add an explicit branch to set `exit_reason=exit_signal_quorum` (vs. the current default `unknown`) in `update_status` call.

4. **Graceful-exit integration**: extend [ralph_loop.sh `should_exit_gracefully` (line 5451)](../../ralph_loop.sh#L5451) — currently handles `permission_denied`. Add `exit_signal_quorum` as a recognized return value when the file is present AND its content is `exit_signal_quorum`. This shifts the halt path from "CB-open termination" (today: looks like a failure in monitoring) to "graceful exit" (looks like success — same semantics as plan-complete).

**Tests** (extend `tests/unit/test_circuit_breaker.bats` + new `tests/unit/test_exit_signal_quorum.bats`):

- 3 mocked `EXIT_SIGNAL: true` loops → `.exit_signals.completion_indicators` length = 3 → `init_circuit_breaker` writes `.harness_halt_reason=exit_signal_quorum` + auto-reset path NOT taken (state remains OPEN).
- Same setup but `EXIT_SIGNAL_HALT_THRESHOLD=5` → 3 emissions are below threshold → auto-reset DOES run, halt-reason file NOT written.
- Existing CB_AUTO_RESET tests still pass (no `.exit_signals` file present → original behavior).
- `should_exit_gracefully` returns `exit_signal_quorum` string when `.harness_halt_reason` content matches → main loop logs SUCCESS, not WARN, and status.json shows `exit_reason: "exit_signal_quorum"`.

**Estimate:** S (half-day).

**Backout:** delete the new conditional block; auto-reset goes back to unconditional.

**Observability:** new log line every time the quorum fires. Add to `ralph-monitor` "Circuit Breaker" panel: `Halt reason: exit_signal_quorum` in green when present.

---

### PR-3 — `feat(harness): thin idle tick — skip Claude on confirmed-empty backlog`

**Depends on:** PR-1 (need accurate exit-signal recording for the counter to advance).

**Problem:** Every loop pays for a full Claude invocation even when `linear_open_count` is freshly 0 and the coordinator's brief confidence is high. AgentForge median idle-tick cost $0.21, peak $2.10 (cache reads + tool round-trips for "check Linear again" sequences).

**Change:**

1. In [ralph_loop.sh main loop](../../ralph_loop.sh#L5008) — between `ralph_spawn_coordinator` (line 5524) and `execute_claude_code` (line 4625, called from main), insert a thin-tick check guarded by `RALPH_TASK_SOURCE=linear` (file-mode projects need a different empty signal which is out of scope for this PR):

```bash
if _thin_idle_tick_eligible "$loop_count"; then
    _emit_synthetic_idle_status "$loop_count"
    cb_record_success
    log_status "INFO" "Thin idle tick — Claude invocation skipped (loop $loop_count)"
    sleep "${INTER_LOOP_PAUSE:-2}"
    continue  # next iteration
fi
```

2. **Empty-detection signal** — brief.json has NO `task_input` field (verified at [.claude/agents/ralph-coordinator.md:88-99](../../.claude/agents/ralph-coordinator.md#L88)). Use existing TAP-741 signal instead. `_thin_idle_tick_eligible` returns 0 (eligible) when ALL of:
   - `RALPH_TASK_SOURCE == "linear"` (file mode out of scope).
   - `RALPH_THIN_IDLE_TICK != "false"` (default on; operator override via `.ralphrc.local`).
   - `linear_get_open_count` (from `lib/linear_backend.sh`) returns 0 AND `linear_counts_at` age < `RALPH_LINEAR_COUNTS_MAX_AGE_SECONDS` (existing TTL, default 900). Fail-loud abstain on unknown counts (TAP-536 path) — abstain means "fall through, do a real Claude call."
   - `.ralph/brief.json` exists AND `coordinator_confidence >= 0.9` (configurable via `RALPH_THIN_TICK_CONFIDENCE_FLOOR`, default 0.9 — see Open Question #3).
   - Previous loop's `WORK_TYPE != "IDLE_TICK"` is NOT required — consecutive thin ticks are the whole point; the quorum from PR-2 handles termination after 3.

3. **Synthetic on-stop invocation** — concrete implementation, reuses the EXISTING stdin pipe at [on-stop.sh:50](../../templates/hooks/on-stop.sh#L46-L50) (`INPUT=$(cat)`):

   ```bash
   _emit_synthetic_idle_status() {
     local loop=$1 ts
     ts=$(get_iso_timestamp)
     local synthetic_response
     synthetic_response=$(jq -n --arg ts "$ts" --argjson loop "$loop" '{
       result: ("Harness-synthesized idle tick at " + $ts + " — backlog confirmed empty via fresh Linear counts, no Claude invocation.\n\n---RALPH_STATUS---\nSTATUS: COMPLETE\nTASKS_COMPLETED_THIS_LOOP: 0\nFILES_MODIFIED: 0\nWORK_TYPE: IDLE_TICK\nEXIT_SIGNAL: true\nRECOMMENDATION: harness-emitted idle tick (loop " + ($loop | tostring) + ") — backlog empty, no Claude call needed\n---END_RALPH_STATUS---")
     }')
     printf '%s' "$synthetic_response" | RALPH_LOOP_ACTIVE=1 CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$RALPH_DIR/hooks/on-stop.sh"
   }
   ```

   Reuses the existing on-stop.sh code path *exactly* — same JSON-stdin parse, same exit-signal accumulator at [ralph_loop.sh:1253-1302](../../ralph_loop.sh#L1253). No new schema, no new write site, no drift risk. Cost: ~50 ms of bash + jq, vs. ~$0.21–$2.10 for a real Claude call.

4. **`WORK_TYPE: IDLE_TICK` recognition** — add to [on-stop.sh:215-218](../../templates/hooks/on-stop.sh#L215). Treat as productive for `completion_indicators` (already gets that for free because `exit_signal=true`) but do NOT reset `consecutive_no_progress` (this is the key: we WANT the no-progress counter to grow so the CB-quorum branch from PR-2 fires after 3 ticks, NOT the auto-reset fallback). Add explicit branch in the [on-stop.sh:737+](../../templates/hooks/on-stop.sh#L737) EXIT-CLEAN switch.

**Tests** (new `tests/unit/test_thin_idle_tick.bats`):

- Mock empty Linear + high confidence brief + fresh count → loop body skips Claude (assert `CLAUDE_CMD_ARGS` not constructed, `.last_claude_invoked_at` not updated), `.exit_signals.completion_indicators` grows by 1.
- Three thin ticks in a row → CB quorum from PR-2 fires.
- Stale count (age > TTL) → thin tick declines, falls through to real Claude call.

**Estimate:** M (1.5 days). The synthetic on-stop hook call is the tricky part — need to feed it via the same env path the real Claude invocation uses.

**Backout:** `RALPH_THIN_IDLE_TICK=false` in `.ralphrc.local` disables instantly; no code rollback needed.

**Observability:** new metric line in `.ralph/metrics/loop_YYYY-MM.jsonl`: `{"event":"thin_idle_tick","loop":N,"cost_saved_estimate_usd":X}`. Cost-saved estimate = median full-loop cost over the last 10 loops. Surface in `ralph-monitor` as `Thin ticks: N/N this session ($X saved)`.

**Acceptance with PR-1+PR-2:** AgentForge-shaped empty backlog → 3 thin ticks total cost < $0.05 (essentially `jq` + `bash` overhead), then quorum halt at loop 3.

---

## Wave 2 — Correctness

### PR-4 — `feat(harness): inject MCP health into the prompt`

**Independent of Wave 1, but ship same release.**

**Problem:** MCP probes happen at startup ([ralph_loop.sh `ralph_probe_mcp_servers`](../../ralph_loop.sh)) but the agent never sees the result. When MCP disconnects mid-loop, the agent improvises — sometimes emits EXIT_SIGNAL from a stale brief, sometimes asks "should I retry?" The AgentForge log shows the agent diagnosing this state correctly in prose but the harness has no way to act on it.

**Change:**

1. Extend `RALPH_MCP_*_AVAILABLE` from boolean to `(ok|degraded|down)` — add a *mid-loop* refresh path: every N loops (default 10, env `RALPH_MCP_REPROBE_INTERVAL`), re-probe. Cache result for the interval.

2. In `build_loop_context`, after the existing per-server "when to use" injection, append one line: `MCP_HEALTH: linear=<state>, tapps=<state>, brain=<state>` followed by guidance: `When MCP_HEALTH shows down for the tool a task depends on, emit STATUS: BLOCKED + RECOMMENDATION: mcp_unreachable rather than improvising EXIT_SIGNAL.`

3. Add `mcp_unreachable` as a recognized `exit_reason` in on-stop.sh — when `STATUS: BLOCKED` + RECOMMENDATION contains `mcp_unreachable`, set CB `consecutive_no_progress` to 0 (NOT a no-progress event — it's blocked on infrastructure) and increment a new `.mcp_blocked_count` counter. After 3 consecutive mcp_unreachable, halt the loop with `exit_reason=mcp_unreachable_quorum`.

4. Extend the inter-loop sleep: when last loop was `mcp_unreachable`, sleep `RALPH_MCP_BACKOFF_SECONDS` (default 60) instead of the normal 2s pause. Exponential — doubles on each consecutive mcp_unreachable up to 10 minutes.

**Tests** (new `tests/unit/test_mcp_health_signal.bats`):

- MCP probe returns `down` for linear → prompt context includes `linear=down` line.
- Agent emits BLOCKED + mcp_unreachable → on-stop hook does NOT increment consecutive_no_progress.
- 3 consecutive mcp_unreachable → halt with `exit_reason=mcp_unreachable_quorum`.
- Inter-loop sleep grows exponentially (mock `sleep` via shim, assert call durations).

**Estimate:** M (1.5 days). The mid-loop reprobe + backoff schedule is the moving part.

**Files:** `ralph_loop.sh` (`build_loop_context`, mid-loop reprobe trigger, sleep schedule), `templates/hooks/on-stop.sh` (mcp_unreachable handling), `.claude/agents/ralph.md` (one paragraph on MCP_HEALTH semantics).

**Backout:** `RALPH_MCP_REPROBE_INTERVAL=0` disables mid-loop reprobe; injected line becomes static "MCP_HEALTH: unknown".

**Observability:** new line in metrics JSONL per loop: `{"event":"mcp_state","linear":"ok","tapps":"degraded",...}`. Aggregate over a session in `ralph-monitor` as a row of colored dots.

---

### PR-5 — `feat(coordinator): pin brief acceptance criteria to an enum`

**Depends on:** PR-1 (so the enum value the agent honors is reliably captured).

**Problem:** [.claude/agents/ralph-coordinator.md](../../.claude/agents/ralph-coordinator.md) MODE=brief produces `acceptance_criteria` as a free-text string. The AgentForge log shows this drifting across loops ("Emit EXIT_SIGNAL: true" → "loop continues cleanly" → "harness will halt"). The agent followed each variant differently — loops 106-109 emitted BLOCKED instead of EXIT_SIGNAL despite identical input.

**Change (Open Question #2 — additive default):**

1. Add a NEW field `acceptance_action` alongside the existing `acceptance_criteria` array. Canonical template: [.claude/agents/ralph-coordinator.md](../../.claude/agents/ralph-coordinator.md). Verified: there is no separate `templates/agents/` directory — `ralph_upgrade_project.sh` at [line 482](../../ralph_upgrade_project.sh#L482) syncs this single file to consumer projects.

   Revised schema (additive — backward compatible):

   ```json
   {
     "schema_version": 1,
     "task_id": "TAP-### or fix_plan slug",
     ...
     "acceptance_criteria": ["one or more criteria"],
     "acceptance_action": "EMIT_EXIT_SIGNAL | CONTINUE_AND_RETRY | BLOCK | IMPLEMENT",
     "acceptance_action_rationale": "<free text — informative for the agent, harness ignores>",
     ...
   }
   ```

   Existing briefs in consumer `.ralph/.brief_cache/` keep working — agent reads `acceptance_action` when present, falls back to `acceptance_criteria` text when absent. No cache eviction needed.

2. Update [.claude/agents/ralph-coordinator.md MODE=brief instructions](../../.claude/agents/ralph-coordinator.md#L80) (the schema block at ~line 88-99 + the surrounding prose) — add `acceptance_action` to the schema AND prose-instruct the coordinator to set it deterministically based on task state: empty backlog → `EMIT_EXIT_SIGNAL`, fully-blocked task → `BLOCK`, fresh task → `IMPLEMENT`, error/needs-retry → `CONTINUE_AND_RETRY`.

3. **Do NOT** bump `RALPH_COORDINATOR_TEMPLATE_VERSION` — `grep -rn` returns zero hits in the codebase. CLAUDE.md mentions the rule but the enforcement mechanism is just `ralph-upgrade-project --dry-run` surfacing the diff (which it will automatically for any file change). The additive change is safe under that diff.

4. Update [templates/skills/global/ralph-workflow/SKILL.md](../../templates/skills/global/ralph-workflow/SKILL.md) — teach the agent: "Read `brief.acceptance_action`. `EMIT_EXIT_SIGNAL` → set `STATUS: COMPLETE` + `EXIT_SIGNAL: true`. `CONTINUE_AND_RETRY` → set `EXIT_SIGNAL: false`. `BLOCK` → set `STATUS: BLOCKED`. `IMPLEMENT` → proceed normally. If absent, interpret `acceptance_criteria` (legacy)."

5. Extend `brief_validate` at [lib/brief.sh:65-100](../../lib/brief.sh#L65) — when `acceptance_action` is present AND not in the enum {`EMIT_EXIT_SIGNAL`, `CONTINUE_AND_RETRY`, `BLOCK`, `IMPLEMENT`}, emit `brief_validate: acceptance_action must be one of EMIT_EXIT_SIGNAL|CONTINUE_AND_RETRY|BLOCK|IMPLEMENT` on stderr and return 1 — this trips the existing TAP-1875 retry path. When `acceptance_action` is ABSENT, accept (backward compat).

**Tests** (new `tests/unit/test_brief_acceptance_action.bats`):

- `brief_validate` on fixture with `acceptance_action: "EMIT_EXIT_SIGNAL"` → accept.
- `brief_validate` on fixture with `acceptance_action: "make it work"` → reject with the enum error line, exit 1.
- `brief_validate` on fixture with NO `acceptance_action` field → accept (legacy path).
- Stub coordinator generates 5 briefs for the same empty-backlog fixture → all 5 have `acceptance_action: "EMIT_EXIT_SIGNAL"`.

**Estimate:** S (half-day). Smaller than the original "M" estimate because additive (no migration path, no cache eviction).

**Migration:** no cache eviction needed — old briefs without `acceptance_action` still validate. Six-month soak before `acceptance_action` becomes required (separate future PR).

**Backout:** revert the template + skill + brief.sh changes. Consumer briefs missing `acceptance_action` already work today; this PR just adds the new validation surface, which is opt-in by virtue of "only fails when present-but-invalid."

---

### PR-6 — `feat(harness): recommendation-repetition halt`

**Independent.**

**Problem:** If the parser bug ever returns in another form (and parser bugs always do), Ralph has no orchestrator-level catch. OpenHands and SWE-agent both ship a deterministic repetition detector as last-line defense.

**Change:**

1. In `ralph_loop.sh` after each successful loop, append `sha256(RECOMMENDATION)` to `.ralph/.recent_recommendations` (ring buffer, last 10 entries with timestamps).

2. Before next loop, read the buffer. If ≥ `RALPH_RECOMMENDATION_REPETITION_THRESHOLD` (default 5) entries within the last `RALPH_RECOMMENDATION_REPETITION_WINDOW_MIN` (default 30) minutes share the same hash, halt with `exit_reason=recommendation_repetition`.

3. Hash normalization: lowercase, strip whitespace, strip loop-number prefixes (`Loop N — `, `Loop #N`), strip numeric file/issue counts (`backlog confirmed empty (4 live probes)` → `backlog confirmed empty (X live probes)`). This catches the AgentForge pattern where the recommendation was nearly-but-not-quite identical across loops.

**Tests** (new `tests/unit/test_recommendation_repetition.bats`):

- 5 identical recommendations within 30 min → halt fires.
- 5 recommendations differing only in loop number → normalization collapses to one hash → halt fires.
- 5 recommendations spread over 60 min → first one falls out of window, only 4 in window → halt does NOT fire.
- Recommendation diversity (5 different strings) → halt does NOT fire.

**Estimate:** S (half-day). Pure orchestrator logic, no agent contract changes.

**Backout:** `RALPH_RECOMMENDATION_REPETITION_THRESHOLD=0` disables. Or delete the new file `lib/recommendation_repetition.sh`.

**Observability:** new line in monitor: `Recommendation diversity: N unique / 10 recent`.

---

## Wave 3 — Durability & cost

### PR-7 — `feat(harness): per-session cost hard-cap kill switch`

**Independent.**

**Problem:** The AgentForge runaway spent $23.31 before stagnation_detected fired. Even with Wave 1 fixes (which would have caught it at loop ~6), a future class of bug (e.g., a coordinator regression that produces non-empty briefs from an empty backlog) could trigger a similar runaway. Memory note correctly removed the per-loop cap because Anthropic's monthly cap is the real backstop, but *single-campaign blast radius* still needs a circuit breaker.

**Change:**

1. New env var `RALPH_SESSION_COST_HARD_CAP_USD` (default unset = off).

2. After each loop's `on-stop.sh` writes `session_cost_usd` to `status.json`, `ralph_loop.sh` checks: `if session_cost_usd >= RALPH_SESSION_COST_HARD_CAP_USD: halt with exit_reason=session_cost_cap_hit`.

3. Write `.ralph/.cost_cap_hit` sentinel so ralph-runner skill knows NOT to relaunch.

4. ralph-runner skill update: read `.ralph/.cost_cap_hit` before relaunch; if present, surface to operator (Linear comment or stderr depending on mode) and stop the campaign.

**Tests** (new `tests/unit/test_session_cost_cap.bats`):

- Mock session_cost_usd=5, cap=10 → loop continues.
- Mock session_cost_usd=12, cap=10 → halt with cost_cap_hit + sentinel file present.
- Cap unset → no halt regardless of cost.

**Estimate:** S (half-day).

**Docs:** add to [docs/UPGRADE-PROMPT.md](../UPGRADE-PROMPT.md) since this is a new opt-in safety knob.

**Backout:** unset the env var; trivial.

---

### PR-8 — `fix(cache): idle ticks do not bust prompt cache or locality state`

**Depends on:** PR-3.

**Problem:** AgentForge accumulated 2.05B cache_read_tokens over 111 loops because every idle tick wrote `.last_completed_files` (empty), `.linear_next_issue` (cleared), and updated `.brief_cache/*.json` (new acceptance_criteria text per coordinator run). Each write subtly perturbs the next loop's prompt prefix → cache miss.

**Change:**

1. When `WORK_TYPE: IDLE_TICK` (introduced in PR-3), the on-stop hook MUST NOT:
   - Mutate `.last_completed_files` (skip the JSONL transcript walk entirely).
   - Mutate `.linear_next_issue` (no read, no write).
   - Mutate `.brief_cache/<id>.json` (the coordinator runs but writes to a `.brief_cache_idle/` sidecar that doesn't feed the agent prompt).

2. When the next non-idle loop starts, restore from the sidecar if main cache is stale.

3. Add a cache-hit-rate observability check: if 5+ consecutive thin ticks produce session cache hit rate < 90%, log `WARN: thin idle tick cache regression — investigate idle-tick state writes`.

**Tests** (new `tests/unit/test_idle_tick_cache_hygiene.bats`):

- Capture pre-tick file mtimes for `.last_completed_files`, `.linear_next_issue`, `.brief_cache/*.json`.
- Run a thin idle tick.
- Assert all mtimes unchanged.

**Estimate:** S (half-day).

**Backout:** revert the WORK_TYPE: IDLE_TICK guards in on-stop.sh.

---

### PR-9 — `feat(harness): structured exit-signal via Write-tool sentinel`

**Depends on:** PR-1 (text-path fallback must work first so we have backward compat during migration).

**Problem:** Text regex on Claude's freeform output is the wrong long-term primitive. The 2026 industry pattern (Anthropic Claude Agent SDK, OpenHands `user_response`, Codex `/goal`) is a structured signal captured by the runtime via tool-call hook — zero parsing, zero ambiguity.

**Change (Open Question #1 — Write-tool sentinel default; flag if you want a new MCP server instead):**

Confirmed via `grep -rn "claude mcp add" lib/ templates/` returning zero hits: Ralph today ships **no custom MCP server**. Adding one is a meaningful infra lift — new sub-package, build pipeline, install path, version-pin in every consumer `.mcp.json`, refresh on `ralph-upgrade-project`. The cheaper equivalent reuses an existing primitive: a **Write-tool sentinel file** captured by an existing PostToolUse hook.

1. Define the sentinel contract: agent calls `Write(.ralph/.exit_signal_intent, "<ACTION>\n<reason>")` where `ACTION` is the enum from PR-5 (`EMIT_EXIT_SIGNAL` | `CONTINUE_AND_RETRY` | `BLOCK`).

2. Extend [templates/hooks/on-file-change.sh](../../templates/hooks/on-file-change.sh) — when the modified path is `.ralph/.exit_signal_intent`, parse the file (line 1 = action, line 2+ = reason), append to `.ralph/.exit_signal_calls.jsonl` (`{loop, ts, action, reason}`), and update `.exit_signals.completion_indicators` directly with the same `jq` template used by [ralph_loop.sh:1290-1300](../../ralph_loop.sh#L1290). The agent file (`.exit_signal_intent`) is then deleted by the hook so the next write is unambiguous.

3. Lock down the file: extend [templates/hooks/protect-ralph-files.sh](../../templates/hooks/protect-ralph-files.sh) to allow writes to `.ralph/.exit_signal_intent` even though `.ralph/` is otherwise protected. The agent gets a single, narrow write surface.

4. Update [.claude/agents/ralph.md](../../.claude/agents/ralph.md) and [templates/skills/global/ralph-workflow/SKILL.md](../../templates/skills/global/ralph-workflow/SKILL.md): "**Preferred signal path**: write `.ralph/.exit_signal_intent` with the action on line 1 and a reason on line 2. The harness captures this structurally — no parser ambiguity. Continue emitting RALPH_STATUS in the response as the human-readable + backward-compat path. When both signals fire in the same loop, the file-sentinel wins."

5. Backward compat: text-path parser from PR-1 continues to work. Collision resolution: on-stop.sh reads `.exit_signal_calls.jsonl` AFTER the text parse; the JSONL entry overrides whatever the text path computed (write the result back into `status.json:exit_signal`).

6. Migration: 90-day soak with both paths active. After that, `ralph-doctor` warns on text-only emissions ("agent did not call .exit_signal_intent — please upgrade ralph-workflow skill"). After 180 days, ralph-monitor flags red. No hard deprecation date — text path stays as the fallback indefinitely.

**Tests** (new `tests/unit/test_exit_signal_sentinel.bats`):

- Agent writes `.ralph/.exit_signal_intent` with `EMIT_EXIT_SIGNAL\nbacklog empty` → on-file-change hook captures it, `.exit_signal_calls.jsonl` grows by 1 entry, `.exit_signals.completion_indicators` grows by 1, file is deleted.
- Same loop emits BOTH text `EXIT_SIGNAL: false` AND sentinel file `EMIT_EXIT_SIGNAL` → final `status.json:exit_signal == "true"` (sentinel wins).
- No sentinel, text path emits `EXIT_SIGNAL: true` → backward-compat path still works.
- Sentinel with invalid action (`MAKE_IT_WORK`) → hook rejects (logs WARN), no state mutation.
- `protect-ralph-files.sh` allows write to `.exit_signal_intent` but still blocks write to `.ralph/status.json` (defense intact).

**Estimate:** M (2 dev-days) — significantly cheaper than the original L (1 week) MCP-server estimate. The hook + protect-files extension + agent contract update are all small surgical edits to existing files.

**Files touched:**
- `templates/hooks/on-file-change.sh` (+~60 LoC for sentinel parsing)
- `templates/hooks/protect-ralph-files.sh` (+~5 LoC for the allowlist)
- `.claude/agents/ralph.md` (one paragraph)
- `templates/skills/global/ralph-workflow/SKILL.md` (one paragraph)
- `tests/unit/test_exit_signal_sentinel.bats` (new)
- `tests/fixtures/exit_signal_sentinel/` (4 fixtures)

**Backout:** delete the sentinel branch in on-file-change.sh. Text path continues to be the only signal path. Zero blast radius — no MCP unregistration, no consumer `.mcp.json` churn.

**Future:** once this lands, the text RALPH_STATUS block can shrink — `STATUS`, `WORK_TYPE`, `RECOMMENDATION` become observability fields only, *decisions* route through file-sentinels (`.exit_signal_intent`, future `.task_complete_intent`, `.blocked_intent`). All the upside of structured signals; none of the MCP-server infra cost.

**If you'd rather ship a real MCP server**: the design is similar — replace the file sentinel with a `mcp__ralph__exit_signal(action, reason)` tool, with a PostToolUse hook capturing the call instead of the file write. Add `ralph-signals` as a new package under `mcp/` in this repo, ship in npm + Python wheel, register via `ralph-upgrade-project` writing to `.mcp.json`. Estimate jumps from M (2 days) to L (1 week). Flag this preference and I'll re-spec.

---

## Cross-cutting

### Documentation

- [CLAUDE.md](../../CLAUDE.md) — update the "Dual-condition exit gate" section to mention the quorum-vs-auto-reset interaction (PR-2) and the thin-tick path (PR-3).
- [docs/UPGRADE-PROMPT.md](../UPGRADE-PROMPT.md) — list new env vars: `EXIT_SIGNAL_HALT_THRESHOLD`, `RALPH_THIN_IDLE_TICK`, `RALPH_MCP_REPROBE_INTERVAL`, `RALPH_MCP_BACKOFF_SECONDS`, `RALPH_RECOMMENDATION_REPETITION_THRESHOLD`, `RALPH_SESSION_COST_HARD_CAP_USD`.
- [docs/OPERATIONS.md](../OPERATIONS.md) — new troubleshooting entry: "Loop runs forever on empty backlog → check `.ralph/.exit_signals` is accumulating; if empty after agent emits EXIT_SIGNAL, your hook is old — run `ralph-upgrade-project`."

### Versioning

Each Wave bumps `RALPH_VERSION` in both [ralph_loop.sh](../../ralph_loop.sh) and [package.json](../../package.json) per CLAUDE.md sync rule:

- Wave 1 → 2.18.0 (parser hardening is a behavior change downstream of consumer projects, minor bump)
- Wave 2 → 2.19.0
- Wave 3 → 2.20.0 (PR-9 may justify 3.0.0 if MCP signal is positioned as the new default — open question for the release call)

### Linear bundling

This is the suggested issue layout for filing in TAP:

| Linear issue | Wave | PRs | Notes |
|---|---|---|---|
| TAP-XXXX **Epic: Idle-runaway fix (AgentForge 2026-05-23)** | — | — | This document |
| TAP-XXXX+1 fix(hooks): parse single-line RALPH_STATUS | 1 | PR-1 | Must ship first |
| TAP-XXXX+2 feat(harness): exit-signal quorum > auto-reset | 1 | PR-2 | Depends on +1 |
| TAP-XXXX+3 feat(harness): thin idle tick | 1 | PR-3 | Depends on +1, recommended with +2 |
| TAP-XXXX+4 feat(harness): MCP health prompt injection | 2 | PR-4 | Independent |
| TAP-XXXX+5 feat(coordinator): add acceptance_action enum to brief | 2 | PR-5 | Additive — no breaking schema change |
| TAP-XXXX+6 feat(harness): recommendation-repetition halt | 2 | PR-6 | Independent |
| TAP-XXXX+7 feat(harness): per-session cost hard-cap kill switch | 3 | PR-7 | Independent |
| TAP-XXXX+8 fix(cache): idle tick prompt-cache hygiene | 3 | PR-8 | Depends on +3 |
| TAP-XXXX+9 feat(mcp): structured exit-signal tool | 3 | PR-9 | Largest; backward-compat with +1 |

### Validation plan

1. **Per-PR**: BATS test suite in this repo (`npm run test:unit` + `npm run test:integration`).
2. **Wave 1 staging**: re-run AgentForge against an empty backlog after Wave 1 ships. Assert: ≤ 3 loops, ≤ $0.10 total, `exit_reason=exit_signal_quorum`, `.exit_signals.completion_indicators` shows 3 entries. If any assertion fails, halt the rollout.
3. **Wave 2 staging**: simulate MCP outage on AgentForge (block port to linear MCP) → assert MCP_HEALTH degrades, agent emits BLOCKED + mcp_unreachable, harness backs off, no improvised EXIT_SIGNAL.
4. **Wave 3 staging**: parallel-track the MCP signal tool against the text path in a hybrid project — both must work, tool must win on collision.

### Rollout

- Wave 1 ships as one release (`2.18.0`) — atomic, the three PRs depend on each other for correctness. Each PR is its own commit; the release ties them together.
- Wave 2 can stagger (PR-4, PR-5, PR-6 ship as they land in `2.19.x`).
- Wave 3 is the durable rewrite — PR-9 ships behind a feature flag (`RALPH_USE_STRUCTURED_EXIT_SIGNAL=true`, default `false` in 2.20.0, default `true` in 2.21.0 after a 30-day soak).

### Risk inventory

| Risk | Mitigation |
|---|---|
| Parser block-normalize is too aggressive, splits legitimate prose | Token list is closed enum (16 known field names); word-boundary anchor; multi-line idempotency |
| Thin idle tick masks a real coordinator-side bug (e.g., wrong empty-detection) | Quorum from PR-2 still requires 3 consecutive ticks; recommendation-repetition (PR-6) is independent backstop |
| MCP backoff stalls the loop on transient flakes | Probe is cached for 10 loops by default, not on every loop; exponential cap at 10 min |
| Cost-cap halts a near-finishing campaign | Opt-in (default off); operator sets it deliberately |
| Structured signal tool drifts from text path | 90-day backward-compat window with both signals supported; observability flags divergence |
| Consumer projects with `CB_AUTO_RESET=true` see unexpected halts | Quorum threshold is configurable (`EXIT_SIGNAL_HALT_THRESHOLD`); default 3 is the smallest sensible value |

### Effort summary

| Wave | PRs | Estimate (refined) |
|---|---|---|
| 1 | PR-1 (S), PR-2 (S), PR-3 (M) | ~2.5 dev-days |
| 2 | PR-4 (M), PR-5 (S, was M), PR-6 (S) | ~2.5 dev-days |
| 3 | PR-7 (S), PR-8 (S), PR-9 (M, was L) | ~3 dev-days |
| **Total** | **9 PRs** | **~8 dev-days** |

PR-5 dropped from M→S (additive change, no migration). PR-9 dropped from L→M (Write-tool sentinel vs. MCP server) — these are the two refinements that cut ~4 dev-days off the original estimate.

For a single autonomous Ralph campaign against this epic (post-fix), expected wall-clock is ~3-4 days assuming Sonnet on the main loop, opus escalation on PR-9 only if you go with the MCP-server variant, and standard QA fan-out at epic boundaries.
