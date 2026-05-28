# Campaign prompt — TAP-2493 (Idle-runaway fix + harness hardening)

**For:** Ralph (autonomous agent loop) — paste this into the operator brief when launching the campaign via the `ralph-runner` skill, or use it verbatim as the working context for any agent picking up this epic.

**Epic:** [TAP-2493](https://linear.app/tappscodingagents/issue/TAP-2493)
**Spec:** `docs/specs/epic-idle-runaway-fix.md`
**Total scope:** 9 stories, ~18 points, ~8 dev-days

---

## Mission

Close the AgentForge 2026-05-23 runaway pattern (108 idle ticks burning $22 against an empty backlog) AND move Ralph's exit-signal handling toward the 2026 industry-best pattern (structured signals, deterministic guardrails, cost-aware idle ticks).

This is not a refactor or a feature — it's a **bug-class fix**. Every story should land with a regression test that locks the specific failure mode out of the codebase forever.

---

## Priority bands & ordering contract

The 9 stories are bucketed by Linear priority. **Honor the bands in this order**: finish all Urgent before starting High, finish all High before starting Medium. Within a band, follow the dependency notes.

### URGENT — Wave 1, ship atomically (do not merge any one in isolation)

These three close the runaway loop. Each in isolation leaves a known-bad state, so they MUST land in the same release (`2.18.0`).

1. [TAP-2494](https://linear.app/tappscodingagents/issue/TAP-2494) — `fix(hooks): parse single-line RALPH_STATUS blocks` (2 pts)
   - **Start here.** Unblocks every other story.
   - Concrete `sed` block-normalize + word-boundary fallback grep in [templates/hooks/on-stop.sh:100-160](templates/hooks/on-stop.sh#L100).
   - 7 BATS fixtures cover the parse-shape matrix.

2. [TAP-2495](https://linear.app/tappscodingagents/issue/TAP-2495) — `feat(harness): EXIT_SIGNAL quorum wins over CB_AUTO_RESET` (1 pt)
   - **Depends on TAP-2494.** Without it, `completion_indicators` is always 0 and quorum never fires.
   - Insert quorum check BEFORE the auto-reset branch at [lib/circuit_breaker.sh:76-91](lib/circuit_breaker.sh#L76). Wires into existing `.harness_halt_reason` at [ralph_loop.sh:5425](ralph_loop.sh#L5425).

3. [TAP-2496](https://linear.app/tappscodingagents/issue/TAP-2496) — `feat(harness): thin idle tick — skip Claude on empty backlog` (3 pts)
   - **Depends on TAP-2494.** Synthetic on-stop call writes `EXIT_SIGNAL: true` through the same parser path.
   - Pipes a `{result: "...---RALPH_STATUS---..."}` JSON payload to `templates/hooks/on-stop.sh` via stdin — zero new write sites.

**Wave 1 exit gate:** All three merged AND `npm run test:unit` passes AND a smoke run against an empty Linear backlog halts within 3 loops with `exit_reason=exit_signal_quorum` at total cost < $0.10. Cut release `2.18.0`. Tag `ralph-upgrade-project` to surface the new hook template to AgentForge and other consumer projects.

### HIGH — Wave 2, ship as they land (no atomicity requirement)

4. [TAP-2497](https://linear.app/tappscodingagents/issue/TAP-2497) — `feat(harness): inject MCP health into the prompt` (3 pts)
   - **Independent.** Can start in parallel with TAP-2498.
   - Add `MCP_HEALTH: linear=ok|degraded|down` line to `build_loop_context()` at [ralph_loop.sh:2186](ralph_loop.sh#L2186). Mid-loop reprobe every `RALPH_MCP_REPROBE_INTERVAL` loops (default 10). New `mcp_unreachable_quorum` halt path.

5. [TAP-2498](https://linear.app/tappscodingagents/issue/TAP-2498) — `feat(coordinator): add acceptance_action enum to brief schema` (1 pt)
   - **Depends on TAP-2494** (the enum-driven action requires reliably captured EXIT_SIGNAL).
   - **Additive** schema change: new `acceptance_action` field alongside existing `acceptance_criteria` array. Backward compat: existing briefs in `.brief_cache/` continue to work.
   - Touch [.claude/agents/ralph-coordinator.md:80-105](.claude/agents/ralph-coordinator.md#L80) + extend `brief_validate` at [lib/brief.sh:65-100](lib/brief.sh#L65).

**Wave 2 exit gate:** Both merged + smoke run with simulated MCP outage halts with `exit_reason=mcp_unreachable_quorum`. Cut release `2.19.0`.

### MEDIUM — Wave 3, last and steady

6. [TAP-2499](https://linear.app/tappscodingagents/issue/TAP-2499) — `feat(harness): recommendation-repetition halt` (1 pt)
   - **Independent.** Pure orchestrator-level defense-in-depth. Ship anytime.
   - sha256-hashed normalized RECOMMENDATION strings; halt on 5 collisions within 30 min. Catches future parser regressions at the orchestrator layer.

7. [TAP-2500](https://linear.app/tappscodingagents/issue/TAP-2500) — `feat(harness): per-session cost hard-cap kill switch` (1 pt)
   - **Independent.** Opt-in env var `RALPH_SESSION_COST_HARD_CAP_USD`. Default off.
   - Document in `docs/UPGRADE-PROMPT.md` only — do NOT add to `.ralphrc` template.

8. [TAP-2501](https://linear.app/tappscodingagents/issue/TAP-2501) — `fix(cache): idle ticks do not bust prompt cache` (1 pt)
   - **Depends on TAP-2496.** The `WORK_TYPE: IDLE_TICK` branch must exist first.
   - On idle ticks, skip writes to `.last_completed_files`, `.linear_next_issue`, and divert brief cache to a sidecar.

9. [TAP-2502](https://linear.app/tappscodingagents/issue/TAP-2502) — `feat(harness): structured exit-signal via Write-tool sentinel` (5 pts)
   - **Depends on TAP-2494** (text-path must work first for backward-compat). Biggest story of the epic — the durable industry-best replacement for the text-regex path.
   - Agent writes `.ralph/.exit_signal_intent`; PostToolUse extension to [templates/hooks/on-file-change.sh](templates/hooks/on-file-change.sh) captures the call structurally. Backward compat: text path stays as fallback indefinitely.

**Wave 3 exit gate:** All four merged + integration re-run on AgentForge confirms the four epic-level acceptance criteria from TAP-2493. Cut release `2.20.0`.

---

## Done-when (campaign exit conditions)

The campaign halts cleanly when ALL of the following are true:

- [ ] All 9 stories in TAP-2493's child list are status `Done` with merged PRs on `main`
- [ ] `npm run test:unit` + `npm run test:integration` + `npm run test:evals:deterministic` are green on `main`
- [ ] An empty-backlog AgentForge run halts ≤ 3 loops, ≤ $0.10, `exit_reason=exit_signal_quorum`
- [ ] An MCP-disconnect simulation on AgentForge halts with `exit_reason=mcp_unreachable_quorum`
- [ ] `docs/specs/epic-idle-runaway-fix.md` "Validation plan" all-green checklist marked

When the gate is met, post a release update on TAP-2493 via the `linear-release-update` skill, close the epic, and emit `EXIT_SIGNAL: true` with `acceptance_action: EMIT_EXIT_SIGNAL`.

---

## Operating rules for the campaign

1. **One PR per story.** Conventional-commit titles already match the story titles. Each PR closes its corresponding Linear issue via `Closes TAP-####`.

2. **Test before declare.** Every story has an Acceptance checkbox section. Mark each `- [x]` only when verified — typically by running the listed BATS test file. No "I think it works" check-offs.

3. **No scope creep.** Each story is intentionally small. If you find a related bug while implementing TAP-2494, file a new Linear story; do not bundle.

4. **Respect dependency notes.** TAP-2495 and TAP-2496 cannot land before TAP-2494. TAP-2498 cannot land before TAP-2494. TAP-2501 cannot land before TAP-2496. TAP-2502 cannot land before TAP-2494. The harness will catch some of this via test failures, but check the dep graph before opening a PR.

5. **Drift discipline.** When touching `templates/hooks/on-stop.sh`, also update `.ralph/hooks/on-stop.sh` in the same commit — CLAUDE.md drift-detection invariant. The unit test will fail if they diverge.

6. **Version bumps.** Wave 1 → `2.18.0`, Wave 2 → `2.19.0`, Wave 3 → `2.20.0`. Update BOTH [ralph_loop.sh `RALPH_VERSION`](ralph_loop.sh) AND [package.json `version`](package.json) per CLAUDE.md sync rule.

7. **Coordinator + locality.** When picking the next story, prefer one in the same module as the last completed work (touch-set Jaccard). Don't randomly bounce between `templates/hooks/` and `lib/circuit_breaker.sh` if you can chain locality-coherent stories.

8. **Halt sooner, not later.** If you encounter ambiguity in any spec section, STOP and emit `STATUS: BLOCKED + acceptance_action: BLOCK` with a Linear comment on the story describing what's unclear. Do not improvise around design gaps — the parser bug we're fixing was itself caused by an "unspecified single-line emission shape" gap nobody caught.

---

## Anti-patterns to avoid

- ❌ Shipping TAP-2495 or TAP-2496 ahead of TAP-2494 to "get a head start." They are no-ops without the parser fix.
- ❌ Replacing the text RALPH_STATUS path entirely in TAP-2502. The text path is the backward-compat fallback indefinitely.
- ❌ Making the `acceptance_action` enum (TAP-2498) required in `brief_validate`. It must accept ABSENT field for legacy briefs.
- ❌ Adding new env vars to the `.ralphrc` template. Document in `docs/UPGRADE-PROMPT.md` only.
- ❌ Bumping `RALPH_COORDINATOR_TEMPLATE_VERSION`. Confirmed via grep: that constant does not exist in the codebase. CLAUDE.md mentions the rule but the enforcement is just `ralph-upgrade-project --dry-run` diff.

---

## Quick-start: launch the campaign

```bash
# From an operator shell (NOT inside the Ralph harness):
cd /home/wtthornton/code/ralph-claude-code

# Verify environment
ralph-doctor   # all checks green
git status     # clean tree

# Kick off via ralph-runner skill (Linear mode picks up TAP-2493 automatically
# because every child story is parented to it and assigned to the agent user).
# The coordinator's locality optimizer will start with TAP-2494 because
# it has the most files touching the same module as recent work.
ralph
```

Tail progress: `tail -f .ralph/logs/ralph.log` or `ralph-monitor` for the dashboard.

Halt manually if needed: `Ctrl-C` or `ralph --halt`. Resume by re-running `ralph`.
