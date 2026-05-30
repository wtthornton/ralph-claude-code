# Operator Notes — Opus 4.8 Cost/Quality Review

Identified during the model cost/quality review on branch
`claude/model-costs-quality-review-7ayHt`.

The agent-file model bumps have been **applied** (quality-max): `ralph-architect`
→ Opus 4.8, `ralph-reviewer` → Opus 4.8 / `effort: high`, `ralph-tester` → Opus
4.8 / `effort: low`. Opus 4.8 is the same price as 4.7 with better coding (88.6%
vs 80.8% SWE-bench Verified) and ~57% fewer tool-prompt tokens.

The main loop intentionally stays on Sonnet: it runs every iteration, so moving
it to Opus would be roughly +67% on the bill for ~1 SWE-bench point on routine
work — the worst quality-per-dollar trade in the system. Opus is spent only where
SWE-bench *Pro* separates the models (the architect + QA-escalation lane, the
reviewer gate, and the tester gate).

## Other deferred items (not code changes)

- **Prompt caching observability:** check the live TAP-1685 cache panel in
  `ralph-monitor`; if the rolling-session hit rate sits below
  `RALPH_CACHE_HIT_RATE_WARN` (default 30%) across a real campaign, the most
  likely causes are session-resume failures, mid-session edits to CLAUDE.md /
  agent files / skills, or the per-loop locality/USYNC content injected into the
  user message by `build_loop_context()`. Data-gated; do not speculatively
  refactor without field data. (The earlier `RALPH_PROMPT_CACHE_ENABLED` flag
  gated a function with no production caller and was removed.)
- **Coordinator cost lever (deferred for quality):** `ralph-coordinator` could
  trial Haiku (cheaper + faster, helps the coordinator-timeout pain) since its
  brief synthesis is structured/low-difficulty.
- **Pin-strategy hygiene:** `ralph-*` agents use auto-upgrading aliases;
  `tapps-*` agents and `.claude/skills/` pin dated IDs that silently miss future
  model bumps. Pick one strategy and document it.
