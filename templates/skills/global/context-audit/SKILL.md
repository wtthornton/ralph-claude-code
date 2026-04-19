---
name: context-audit
description: >
  Token-hygiene pass for the Ralph loop. Before reading another large
  file, audit what's already in context: drop stale file reads, prefer
  targeted Grep over full-file Read, and consolidate repeated file-scan
  patterns. Prevents the 3-loop drift where each iteration re-reads the
  same file and burns cache. Works with the SDK ContextManager
  (sdk/ralph_sdk/context.py) and the Continue-As-New trigger.
version: 1.0.0
ralph: true
ralph_version_min: "1.9.0"
attribution: "Authored for Ralph runtime, drawing on prompt-cache best practices for Claude"
user-invocable: true
disable-model-invocation: false
allowed-tools:
  - Read
  - Grep
  - Glob
  - Bash
---

# context-audit — Treat Context Like a Budget

Ralph's long sessions (Continue-As-New kicks in at 20 iterations /
120 minutes) accumulate context debt: every full-file Read, every stale
directory listing, every echoed JSON payload stays in the working window
until it's flushed. This skill trims that debt *before* it becomes a
problem, not after the circuit breaker trips.

## When to invoke

Trigger this skill when **any** of these hold:

- Current loop count within this session is **≥ 10** and the task is
  non-trivial — you're in the second half of a Continue-As-New window
  and token cost is compounding.
- The next task requires reading a **large** file (> 500 lines) and that
  file (or a sibling) was already Read in this session.
- The previous loop's prompt-cache hit rate (visible in
  `.ralph/metrics/*.jsonl`) dropped below 50% — context is churning.
- You're about to invoke a sub-agent and you want to pass a **compact**
  handoff, not a firehose.

Skip this skill for the **first 3 loops of a session** — early loops
need room to explore, and audit overhead isn't paid back yet.

## Ralph-specific guidance

Four disciplines, in order of payoff:

### 1. Prefer `Grep` over `Read` for targeted questions

If the question is "does this function exist in `ralph_loop.sh`?", the
answer is one Grep invocation. Reading the whole ~2,300-line file
wastes ~60k tokens to answer a one-bit question. Use `Read` with
`offset`/`limit` when you need the exact surrounding lines.

### 2. Drop stale reads between related iterations

A file Read 8 loops ago is probably no longer the live version of that
file — it may have been edited by Claude, by a sub-agent in a worktree,
or by the PostToolUse hooks. When in doubt, Re-Read a **slice**, not the
whole file. The ContextManager in the SDK (
`sdk/ralph_sdk/context.py::ContextManager`) already trims `fix_plan.md`
progressively; lean on that signal — if it pruned a section, don't ask
for the whole thing again.

### 3. Consolidate repeated scan patterns

If you've run the same Grep across `lib/`, `sdk/`, and `tests/` three
times in a session, the search space isn't changing. Cache the result
in a local variable (for the current iteration) and pass it to the
sub-agent instead of telling the sub-agent to re-grep.

### 4. Respect cache-prefix stability

Claude's prompt cache keys off a **stable prefix**. In Ralph terms:
`templates/PROMPT.md` + the `.ralphrc` + CLAUDE.md form the stable
prefix. Do not restructure them mid-session; append-only changes (new
task under an existing section) preserve the cache. The
`PromptParts`/`PromptCacheStats` classes (Phase 17) track this.

## Integration with sub-agents

- **ralph-explorer** (Haiku) — delegate wide-scope search here. Explorer
  runs in its own context window, so its results come back as a short
  summary instead of 200 matching lines in the main window. Net cache
  gain is significant.
- **ralph-tester / ralph-reviewer / ralph-architect** — when you hand off,
  hand off a **summary** plus specific file paths, not the full
  conversation so far. A one-paragraph brief + 3 file paths outperforms
  dumping the session transcript every time.
- **Continue-As-New** — at the session boundary (iteration 20 or 120
  min), the loop auto-resets but carries forward essential state
  (current task, progress, recommendation) via
  `ContinueAsNewState`. Before the reset fires, run this skill once so
  the next session starts from a compact baseline.

## Exit criteria

You're done with this skill when **all** of:

1. The next planned action uses the minimum viable read (Grep, or Read
   with offset/limit, instead of full-file Read).
2. You've identified and skipped at least one file that was already
   freshly read earlier in the same iteration.
3. If a sub-agent is next, the handoff brief is ≤ 200 words.

## Anti-patterns

- **"Let me read the whole file to get context"** — full Reads are a
  last resort, not a first move. Grep first.
- **Re-Reading after every Edit** — the Edit tool's response already
  echoes the post-edit state of the affected lines; don't Read the
  whole file to confirm.
- **Passing the entire conversation to a sub-agent** — sub-agent prompts
  should be self-contained briefs, not transcripts. The Agent tool
  prompt is *for* the sub-agent, not a mirror of the main session.
- **Reading `ralph.log`** — that log grows unbounded mid-session; the
  structured fields you need are in `status.json` or `.exit_signals`.
