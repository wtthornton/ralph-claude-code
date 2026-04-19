---
name: search-first
description: >
  Research-before-coding workflow. Before writing a new utility, helper, or
  abstraction in the Ralph loop, search the repo, installed libraries, and
  public registries for an existing solution. Delegates deep search to the
  ralph-explorer sub-agent (Haiku). Use whenever a fix_plan task says
  "add/implement/build/wrap/integrate" something that sounds generic.
version: 1.0.0
ralph: true
ralph_version_min: "1.9.0"
attribution: "Forked from the ECC search-first pattern and hardened for Ralph's autonomous loop"
user-invocable: true
disable-model-invocation: false
allowed-tools:
  - Read
  - Grep
  - Glob
  - Bash
  - WebFetch
  - WebSearch
---

# search-first — Research Before You Code (Ralph-hardened)

Ralph loops are optimized for throughput, so the cheapest task is the one
already written. Before emitting a new module, run a short discovery pass.
Net cost: seconds. Net savings: hours of author-review-revise churn on code
that duplicates an existing library.

## When to invoke

Trigger this skill when any of these signals fire in a loop:

- The next `- [ ]` task in `fix_plan.md` (or the next Linear issue) uses verbs
  like "add", "implement", "build", "wrap", "integrate", "create a utility
  for ...", "write a helper to ...".
- The task touches a generic capability: HTTP client, retry logic, JSON
  schema validation, cache, rate limiter, CLI parser, date math.
- You're about to create a new file under `lib/`, `sdk/`, or a new `utils/`
  directory that did not exist an hour ago.
- A prior loop emitted "built custom X" and the reviewer flagged it.
- User prompt contains "add X" without specifying that X must be custom.

Skip this skill when the task is narrow and project-specific
(e.g. "update `on-stop.sh` to emit `skill_retro.json`") — no general-purpose
library exists for that.

## Ralph-specific guidance

Inside the Ralph loop, prefer short, targeted searches over exhaustive
research. The loop's budget rewards shipping, not analysis.

1. **Repo first** — `Grep`/`Glob` for the capability name across `lib/`,
   `sdk/ralph_sdk/`, `tests/`, and `templates/hooks/`. Ralph's own library
   is the most common hit.
2. **Installed deps second** — check `package.json`, `sdk/pyproject.toml`,
   and `node_modules/`/`.venv/` for a dependency that already covers it.
3. **Registries third** — for Python: PyPI via `pip index versions`; for
   JS/TS: `npm search` or `npm view`. Cap at the top 3 hits.
4. **MCP/skills fourth** — `~/.claude/skills/` and configured MCP servers
   may already expose the capability as a tool (e.g. Linear, docs-mcp).
5. **Stop as soon as a credible option appears** — Ralph loops should not
   spend a full iteration researching. If the first two layers produce
   nothing, spend at most one more minute on registries before deciding.

Ranking for the decision:

| Signal                                  | Action                      |
| --------------------------------------- | --------------------------- |
| Exact match already in `lib/`/`sdk/`    | **Reuse** — import it       |
| Installed dep covers it                 | **Adopt** — import + wrap   |
| Popular, maintained registry hit        | **Adopt** — add dep + wrap  |
| Partial match, needs significant glue   | **Extend** — fork thin shim |
| Nothing within reach                    | **Build** — but informed    |

## Integration with sub-agents

- **ralph-explorer** (Haiku, read-only) — delegate a `search-first` pass
  with a concrete query. Prefer `explorer.run("how is retry logic
  currently handled in lib/")` to running 20 greps yourself. Explorer is
  cheap and keeps the main loop's context clean.
- **ralph-architect** (Opus) — only invoke when the research reveals that
  adopting the external option requires a non-trivial architectural change
  (breaking the trust boundary, introducing async where there was none,
  etc.). Architect gets mandatory review afterward.
- **ralph-reviewer** (Sonnet) — if you decide to **Build**, attach the
  search findings to the PR/commit so the reviewer can confirm the
  decision was informed, not defaulted.

## Exit criteria

You're done with this skill when **one** of:

1. You found and imported an existing project-local helper.
2. You installed/configured an existing dependency and removed any
   inline duplication of its behavior.
3. You documented (in the commit message or a short `Why:` line in the
   code) the three credible candidates you evaluated and why Build won.

Do **not** proceed to implementation until one of those three holds.

## Anti-patterns

- **Jumping to code** — writing a new utility without a two-minute grep of
  `lib/` first. Ralph has ~30 lib modules; at least half of any candidate
  task overlaps with one.
- **Research paralysis** — a Ralph loop is not a literature review. Cap
  registry search at 3 candidates and move on.
- **Over-wrapping** — importing a library and hiding 90% of its API
  behind a thin shim defeats the purpose. Expose the library directly
  unless the wrapper earns its keep.
- **Ignoring MCP** — skills and MCP servers already in `~/.claude/` are
  zero-cost; check them before npm/PyPI.
