# Operator Notes — Opus 4.8 Cost/Quality Review

These changes were identified during the model cost/quality review on branch
`claude/model-costs-quality-review-7ayHt`. The harness-editable changes (pricing
tables, SDK routing/maps/tests, docs, skills) are already committed.

The edits below could **not** be applied automatically: `protect-ralph-files.sh`
blocks modifications to `.claude/agents/` from inside the Ralph harness (by
design — the autonomous agent must not be able to rewrite its own config). Apply
them as the operator, outside the harness.

## Pending agent-file edits

### 1. `.claude/agents/ralph-architect.md` — required (high value)

Opus 4.8 is the same price as 4.7 with better coding (88.6% vs 80.8% SWE-bench
Verified) and ~57% fewer tool-prompt tokens. Free upgrade.

```diff
- model: claude-opus-4-7
+ model: claude-opus-4-8
```

### 2. `.claude/agents/ralph-reviewer.md` — recommended (quality-max gate)

Bug/security catch-rate is reasoning-bound, and the reviewer fires at epic
boundaries (not every loop), so the ~1.67x cost lands on an occasional
operation while buying the +8–9 SWE-bench-point catch-rate right before commit.

```diff
- model: sonnet
- effort: medium
+ model: claude-opus-4-8
+ effort: high
```

### 3. `.claude/agents/ralph-tester.md` — optional (marginal)

The tester mostly runs tests and reports pass/fail counts (deterministic,
`effort: low`); only its "recommended fixes" sliver is reasoning-bound.
Quality-per-dollar is weak. **Recommendation: leave on Sonnet.** Apply only if
you want true quality-max across both gates:

```diff
- model: sonnet
+ model: claude-opus-4-8
  maxTurns: 15
  isolation: worktree
  effort: low          # keep low — test execution is mechanical
```

## Why the main loop stays on Sonnet

On standard-difficulty work Sonnet (79.6%) is within ~1.2 points of Opus, at 3/5
the cost. The main loop runs every iteration, so moving it to Opus would be
roughly +67% on the bill for ~1 SWE-bench point on routine work — the worst
quality-per-dollar trade in the system. Opus money is spent only where SWE-bench
*Pro* separates the models (hard/architectural): the architect + QA-escalation
lane, and optionally the reviewer gate.

## Other deferred items (not code changes)

- **Prompt caching:** `RALPH_PROMPT_CACHE_ENABLED=false`. Check the live TAP-1685
  cache panel in `ralph-monitor`; if session hit-rate < 30%, the prepended
  locality/USYNC directives in `build_loop_context()` are the likely cause and
  should move below the stable prompt prefix.
- **Coordinator cost lever (deferred for quality):** `ralph-coordinator` could
  trial Haiku (cheaper + faster, helps the coordinator-timeout pain) since its
  brief synthesis is structured/low-difficulty.
- **Pin-strategy hygiene:** `ralph-*` agents use auto-upgrading aliases;
  `tapps-*` agents and `.claude/skills/` pin dated IDs that silently miss future
  model bumps. Pick one strategy and document it.
