---
name: agentic-engineering
description: >
  Eval-first principles and cost-aware model routing for the Ralph loop.
  Before writing code, articulate the behavior you want to verify. Route
  work by complexity: TRIVIAL/SMALL to Haiku, MEDIUM to Sonnet,
  LARGE/ARCHITECTURAL to Opus via ralph-architect. Integrates with
  sdk/ralph_sdk/cost.py::select_model and lib/complexity.sh.
version: 1.0.0
ralph: true
ralph_version_min: "1.9.0"
attribution: "Authored for Ralph runtime, drawing on Karpathy's agentic engineering guidance and Anthropic's model routing patterns"
user-invocable: true
disable-model-invocation: false
allowed-tools:
  - Read
  - Grep
  - Glob
  - Bash
---

# agentic-engineering — Evals First, Cost-Aware Routing

Ralph is a loop of agents with an explicit budget — token cost, wall
clock, and the Claude API's hourly cap. Two disciplines make the loop
reliably cheap: **eval-first execution** (define "done" before you
start) and **cost-aware routing** (match model tier to task tier).

## When to invoke

Trigger this skill when **any** of these hold:

- You're about to invoke a sub-agent and you haven't decided which one.
- The task in `fix_plan.md` is marked with `<!-- complexity: LARGE -->`
  or `<!-- complexity: ARCHITECTURAL -->` annotation.
- You just saw the cost tracker in `.ralph/metrics/*.jsonl` flag a
  budget warning.
- The task description is vague ("improve X", "make Y better") — needs
  eval definition before any model picks it up.

Skip this skill for unambiguous SMALL tasks: "fix typo in README",
"bump version to 1.10.0". The routing choice is obvious and the eval
is "the diff looks right".

## Ralph-specific guidance

### Eval-first (before any implementation)

For any MEDIUM+ task, write the answer to three questions in one
sentence each, and put them in the commit message (or a short Why
comment) when you land:

1. **Input** — what does the loop receive that distinguishes this task
   from "general improvement"? (A failing test, an error log line, a
   user report, a deterministic scenario.)
2. **Success signal** — what specific check flips from red to green?
   (A BATS test, a CI job, an error no longer appearing in
   `ralph.log`, a metric's 7-day average dropping below a threshold.)
3. **Failure signal** — what would tell the next loop "this attempt
   didn't land, try a different approach"? If the answer is "I don't
   know," stop and ask for more context before writing code.

If you can't answer all three, you don't have an eval — you have a
vibe. Don't commit budget to a vibe.

### Cost-aware model routing

Ralph routes by complexity via `sdk/ralph_sdk/cost.py::select_model`.
Mirror that reasoning when you decide which sub-agent to invoke:

| Complexity       | Agent               | Model  | When                                   |
| ---------------- | ------------------- | ------ | -------------------------------------- |
| TRIVIAL / SMALL  | ralph-explorer      | Haiku  | search, scan, file discovery           |
| SMALL / MEDIUM   | main loop (Sonnet)  | Sonnet | batched edits, routine implementation  |
| MEDIUM           | ralph-tester        | Sonnet | run tests, report failures             |
| MEDIUM           | ralph-reviewer      | Sonnet | read-only code review                  |
| LARGE / ARCH.    | ralph-architect     | Opus   | cross-module refactors, design         |

Rules of thumb:

- **Never use Opus for file discovery.** That's Haiku's lane.
- **Never invoke ralph-architect without a clear design question.**
  Architect's mandatory post-review costs are real — don't pay them
  for a task ralph-reviewer could confirm on its own.
- **Batch SMALL tasks.** Up to 8 SMALL / 5 MEDIUM in one loop — the
  Sonnet main loop carries per-loop overhead that dominates small tasks
  if each gets its own iteration.
- **Retry escalation is allowed.** A MEDIUM task that fails twice on
  Sonnet can escalate to Opus via architect on the third attempt; beyond
  that, it's a human decision.

## Integration with sub-agents

- **ralph-explorer** (Haiku) — default delegate for search-first. If
  you're reading more than 3 files to find something, stop and send
  explorer.
- **ralph-architect** (Opus) — only for LARGE / ARCHITECTURAL tasks with
  an explicit design question ("should X live in lib/ or sdk/?").
  Architect's review step is mandatory; budget accordingly.
- **ralph-tester** (Sonnet, worktree-isolated) — **required** at epic
  boundaries and before any `EXIT_SIGNAL: true`. Never ship green
  without a tester pass on the boundary.
- **ralph-reviewer** (Sonnet, read-only) — required after any architect
  task, recommended after simplify, optional for clean SMALL tasks.

## Exit criteria

You're done with this skill when **all** of:

1. The task has a written eval (Input / Success / Failure), at least in
   commit-message form.
2. The sub-agent routing choice is made and justified in one line
   (e.g. "LARGE cross-module rename → architect; mandatory reviewer
   after").
3. If the task is ambiguous, you've asked for more context rather than
   guessing with an expensive model.

## Anti-patterns

- **"Let's just run Opus to be safe"** — routing to the most expensive
  model as a default wastes budget on tasks Sonnet or Haiku would nail.
  Match tier to task.
- **Skipping evals for MEDIUM tasks** — Ralph's loop will gladly
  re-attempt a poorly-scoped task 5 times before tripping the circuit
  breaker. A one-sentence eval up front usually prevents all five.
- **Architect without a design question** — architect is for
  *decisions*, not for running tests or refactoring within a module.
- **Ignoring `lib/complexity.sh`** — the shell classifier is cheap and
  already deployed. Use its output to confirm your mental routing.
