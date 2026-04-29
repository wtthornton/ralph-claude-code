---
title: Ralph stack guide — Claude Code × tapps-mcp × tapps-brain
description: Cost-optimization playbook for running Ralph with the full tool stack. Sub-agent routing, brain recall, MCP integration, per-loop templates.
audience: [operator]
diataxis: how-to
last_reviewed: 2026-04-23
---

# Ralph stack guide — Claude Code × tapps-mcp × tapps-brain

Practical reference for running Ralph with the full tool stack to **maximise work shipped per dollar**. Written after a 26-loop observed session where 4 force-multipliers (named sub-agents, tapps-brain, docs-mcp, context7) produced **zero calls** and the session still cost $52.98 on pure Opus-4-7 main-agent work.

**Audience:** Anyone running Ralph against projects that have tapps-mcp + tapps-brain installed.

## TL;DR

1. **Route by complexity, not by habit.** Default the main Ralph agent to Sonnet-4-6. Use Opus-4-7 only for `ralph-architect` on LARGE tasks. This alone is ~4× cheaper.
2. **Delegate before drafting.** Any read-only investigation → `ralph-explorer` (Haiku). Any test run → `ralph-tester`. Any code review → `ralph-reviewer`. The main agent writes code, it doesn't search and test and review inline.
3. **Recall before re-reading.** Call `brain_recall(topic)` at task start. Call `tapps_lookup_docs(lib, topic)` before using any external API. Call `brain_remember(fact, tier)` when a non-obvious rule is learned. Stop making Claude re-grep the same file every loop.
4. **Batch at epic boundaries, not per-task.** Skip `ralph-tester` and `ralph-reviewer` mid-epic (explicit deferral). Fire them at the last unchecked item of a section or before `EXIT_SIGNAL: true`.
5. **Measure.** `ralph-cost-report` is now installed. Run it every 20 loops or before tuning anything.

Expected outcome on a 40-ticket backlog like NLTlabsPE: **$15 instead of $85**, with equal or better quality (QA actually runs at boundaries; no longer skipped).

## Part 1 — The three systems

### 1.1 Claude Code (me)

**Tools available to the main ralph agent** (per [.claude/agents/ralph.md](../.claude/agents/ralph.md)):
- `Read, Write, Edit` — file IO
- `Glob, Grep` — local search (cheap, should be the first choice over `Bash(find …)` / `Bash(grep …)`)
- `Bash` — shell with the ALLOWED_TOOLS whitelist
- `Task` — spawn sub-agents
- `TodoWrite, WebFetch` — ancillary

**Sub-agents** (4 named + 1 generic):

| Agent | Model | Tools | When to use | Cost profile |
|-------|-------|-------|-------------|--------------|
| `ralph-explorer` | Haiku-4.5 | Read, Glob, Grep, Bash(read-only) | Codebase search, "where is X defined?", "what calls this function?" | **~$0.02–0.10 per call.** 5-20× cheaper than doing the same work inline on Opus. |
| `ralph-tester` | Sonnet-4-6 (worktree-isolated) | Read, Bash | Run `npm test`, `pytest`, `playwright` — any test command | Medium. Isolation prevents test artifacts polluting main branch. |
| `ralph-reviewer` | Sonnet-4-6 (read-only) | Read, Glob, Grep | Review before commit / before Done | Medium. Catches regressions before the diff ships. |
| `ralph-architect` | Opus-4-7 | Full toolbelt + Task | LARGE tasks only (cross-module, architectural, new feature) | **Expensive — the ONE legitimate Opus call-site.** Mandatory code review follows. |
| `general-purpose` | Sonnet-4-6 | Everything | Fallback when none of the above fit | Medium. Don't default to this — the named agents exist for a reason. |

**Models cost per 1M tokens** (Anthropic pricing as of April 2026):

| Model | Input | Output | Cache read | Cache creation |
|-------|-------|--------|-----------|----------------|
| Opus-4-7 (1M ctx) | $15 | $75 | $1.50 | $18.75 |
| Sonnet-4-6 | $3 | $15 | $0.30 | $3.75 |
| Haiku-4.5 | $0.80 | $4 | $0.08 | $1 |

Opus on a typical Ralph loop (500k cache read + 10k output) = $0.75 + $0.75 = **$1.50 just for cache reads + output**. Same loop on Sonnet = **$0.30**. Same loop on Haiku = **$0.08**. The model choice dominates everything else.

**Prompt caching:** Sessions reuse a stable prefix across loops. Observed 82% cache hit rate at ~500M cumulative cache read. Cache TTL is 5m (ephemeral) or 1h (explicit). The **continue-as-new** pattern ([CLAUDE.md](../CLAUDE.md) "Continue-As-New") resets at iteration 20 or 120 min to keep the cache-creation overhead from ballooning.

### 1.2 tapps-mcp (26 tools)

Full tool catalog, annotated by typical per-call cost:

**Pipeline orchestration:**
- `tapps_session_start` — medium, **call once per session**. Returns server info + memory status + workflow hints. `quick=True` for <1s response.
- `tapps_pipeline` — expensive. One-call orchestrator (session_start → quick_check → validate → checklist). Use for review task_type only.
- `tapps_checklist` — medium. Final gate before "done." `task_type` in (feature / bugfix / refactor / security / review / epic).
- `tapps_decompose` — cheap. Breaks a task into ~15min units with model-tier recommendations. Purely deterministic (no LLM). Underused.

**Quality & security (static analysis, no LLM calls):**
- `tapps_quick_check` — medium. `score + gate + security` on one file. Call after each Python edit.
- `tapps_score_file` — expensive when `quick=False`. Python/TS/JS/Go/Rust. 7-category scoring.
- `tapps_quality_gate` — cheap. Pass/fail against preset (standard/strict/framework). Security floor 50/100 is hard.
- `tapps_security_scan` — medium. Python only. bandit + secret detection. Auto-detect domain (auth/payments/uploads/api/data).
- `tapps_validate_changed` — expensive. Batch-validate files. **Always pass explicit `file_paths=`** — auto-detect is pathologically slow.
- `tapps_validate_config` — cheap. Dockerfile, docker-compose, WebSocket/MQTT/InfluxDB.

**Knowledge & lookup:**
- `tapps_lookup_docs` — **context7-wrapped**. `library` required, `topic` optional. Provider chain: Context7 (if key) → LlmsTxt → stale cache. TTL 24h default, 12h for React/Vue/Next, 48h for Python/Django/Flask. Cache path: `.tapps-mcp-cache/<library>/<topic>.md + .meta.json`. Call **before** using any external library API — prevents hallucinated method names.
- `tapps_impact_analysis` — medium. AST blast-radius before refactor/delete.
- `tapps_dependency_scan` — expensive. pip-audit CVE scan.
- `tapps_dependency_graph` — medium. Import graph ASCII/JSON.
- `tapps_dead_code` — medium. Vulture-based.

**Memory** (`tapps_memory`, 33 actions — wraps tapps-brain via `BrainBridge`):
- CRUD: `save, save_bulk, get, list, delete, search, reinforce, gc, contradictions, reseed, import, export`
- Consolidation: `consolidate, unconsolidate`
- Federation: `federate_register, federate_publish, federate_subscribe, federate_sync, federate_search, federate_status`
- Safety: `safety_check, verify_integrity`
- Profiles: `profile_info, profile_list, profile_switch`
- Health/Hive: `health, hive_status, hive_search, hive_propagate, agent_register, index_session, validate, maintain`

**Note:** `tapps_memory` and `brain_*` tools hit the **same storage** (SQLite + pgvector-on-Postgres for tapps-brain HTTP deployments). `tapps_memory` is the MCP wrapper; `brain_*` is direct. Pick the one that's connected in your deployment — don't call both for the same fact.

**Meta / diagnostics (cheap, call on demand):**
- `tapps_server_info, tapps_stats, tapps_dashboard, tapps_doctor, tapps_set_engagement_level, tapps_feedback, tapps_report, tapps_session_notes`

**Install / lifecycle:**
- `tapps_init, tapps_upgrade` — expensive one-offs.

**Anti-patterns from the codebase:**
- **`tapps_validate_changed` without `file_paths`** — scans all git-changed files, pathologically slow on any non-trivial diff.
- **Calling security_scan on every edit** — not explicitly banned but the checklist design makes it `task_type=security` only. Don't run on doc edits.
- **Removing `.claude/hooks/tapps-session-start.sh` cleanup** — zombie MCP processes accumulate (2h cleanup window is the only bulwark).

### 1.3 tapps-brain (memory system)

**Memory tiers** (confidence decays exponentially, half-life = TTL):

| Tier | TTL (half-life) | What goes here |
|------|----------------|----------------|
| `architectural` | **180 days** | System decisions, tech-stack choices, infra contracts, "we chose X over Y because Z" |
| `pattern` | **60 days** | Coding conventions, API shapes, design patterns |
| `procedural` | **30 days** | Workflows, build/deploy steps, runbooks |
| `context` | **14 days** | Session-specific facts. Use sparingly. |
| `session` | **1 day** | Current session only |
| `ephemeral` | **1 day** | Momentary context |

**Scopes:**
- `project` — visible across project (default)
- `branch` — git-branch-scoped
- `shared` — eligible for federation across projects (opt-in)
- `session` / `ephemeral` — fast decay

**Cap:** 5000 entries per project (`TAPPS_BRAIN_MAX_ENTRIES`, auto-evicts when hit — no warning).

**Primary `brain_*` tools** (MCP handlers in [`src/tapps_brain/mcp_server/tools_brain.py`](../../tapps-brain/src/tapps_brain/mcp_server/tools_brain.py)):

| Tool | Purpose | Required args | Read/Write |
|------|---------|---------------|-----------|
| `brain_recall(query)` | Semantic memory search | `query` | Read |
| `brain_remember(fact, tier)` | Save a memory | `fact`, `tier` optional | Write |
| `brain_learn_success(task_description)` | Record what worked | `task_description` | Write (episodic) |
| `brain_learn_failure(description, error)` | Record what didn't work (+ error) | `description`, `error` | Write (episodic) |
| `brain_forget(key)` | Soft-delete a memory | `key` | Write (archive) |
| `brain_status()` | Agent identity + store stats + Hive connectivity | none | Read |

**Consolidation:** automatic on save (Jaccard + TF-IDF similarity, no LLM). Merges near-duplicate entries with an audit trail. Undoable (single-step via `undo_consolidation_merge`).

**Decay:** computed **lazily on read**. Stale entries remain until GC runs (`maintenance_gc`).

**When to write memory** (per [tapps-brain/CLAUDE.md:135-162](../../tapps-brain/CLAUDE.md#L135-L162)):
- User **corrects** your approach or teaches a non-obvious rule → `architectural` or `pattern`
- A decision is made **with rationale** — save the rationale, not the decision
- Debugging reveals a **subtle invariant** or **surprising constraint** not obvious from code

**When NOT to write memory** (never):
- Code patterns, file paths, module layout (derivable by reading repo)
- Git history, diffs, blame (git log is authoritative)
- Ephemeral task state / current-conversation context
- Fix recipes (the fix is in the code; the commit message has the context)
- Secrets, tokens, PII (`safety.py` blocks these)

**When to read memory:**
- **At task start** — `brain_recall(topic keywords)`. If the topic was touched before, prior decisions load instead of re-deriving.
- User asks *"why is X the way it is?"* / *"what did we decide about Y?"* / *"have we seen this before?"*
- Before making a **non-trivial choice** — recall first so prior decisions inform you.

## Part 2 — Decision matrix (who does what)

For a given task, pick the right starting tool:

| Task shape | Start with | Why |
|-----------|-----------|-----|
| "Find where X is defined / who calls Y" | `ralph-explorer` (Haiku) | 5-20× cheaper than inline search on Opus/Sonnet |
| "Fix typo / rename variable / update comment" | Main agent, **Haiku** model | TRIVIAL complexity class; skip everything else |
| "Edit one file to fix one bug" | Main agent, **Sonnet** | SMALL complexity |
| "Add a feature across 2-3 files in one module" | Main agent, **Sonnet** + `tapps_quick_check` after each edit | MEDIUM complexity |
| "New integration / schema / cross-module refactor" | `ralph-architect` (Opus), then mandatory `ralph-reviewer` | LARGE complexity. The one legitimate Opus call. |
| "Use an external library API (first time this session)" | `tapps_lookup_docs(library, topic)` **first**, then edit | Prevents hallucinated method names. Cache hit on second call. |
| "What did we decide about X?" | `brain_recall('X')` first | Skip re-derivation |
| "Before Done: verify tests pass" | `ralph-tester` (worktree) | Isolation keeps main tree clean |
| "Before Done: have we shipped to main?" | `git log main --grep='TAP-XXX'` | Hard rule R1 |
| "Task is complete — do final checks" | `tapps_validate_changed(file_paths=…)` + `tapps_checklist(task_type=…)` | Both required for "done" per CLAUDE.md |

**Epic-boundary deferral (Ralph v1.8.5+):**
- `ralph-tester` + `ralph-reviewer` skipped mid-epic → set `TESTS_STATUS: DEFERRED`
- Fired at: the last `- [ ]` of an epic section **OR** before any `EXIT_SIGNAL: true` **OR** before any LARGE task's first commit
- This is intentional — not a bug. The main agent can still batch 5-8 small tasks between QA runs.

## Part 3 — The per-loop template

```
─── LOOP START ───
1. tapps_session_start(quick=true)      # MCP catalog + health, <1s
2. brain_recall(<task keywords>)        # Cross-session memory
3. (pick work — Linear, fix_plan.md, etc.)
4. If unfamiliar module:
     Task(ralph-explorer, "find …")    # Haiku, cheap search
5. If external library:
     tapps_lookup_docs(lib, topic)      # Prevent hallucination
6. IMPLEMENT (main agent — Sonnet default; Opus only via ralph-architect on LARGE)
7. After each Python edit: tapps_quick_check(file)
8. If this is the LAST task in an epic OR before EXIT_SIGNAL:
     Task(ralph-tester, "npm test …")   # Fire deferred QA
     Task(ralph-reviewer, "review diff") # Catch regressions
     tapps_validate_changed(file_paths=…)
     tapps_checklist(task_type=…)
9. Commit to main. Mark Linear Done (only if git log main --grep matches).
10. If non-obvious rule was learned:
      brain_remember(<rule>, tier='pattern' or 'architectural')
───  LOOP END  ───
```

Claude should emit the standard RALPH_STATUS block at end, as always.

## Part 4 — Configuration (apply before next restart)

### 4.1 `.ralphrc` changes

```bash
# Default model: Sonnet for main agent (not Opus)
CLAUDE_MODEL="claude-sonnet-4-6"

# Effort: low is fine for routine batching; Sonnet handles it
CLAUDE_EFFORT="low"

# ALLOWED_TOOLS must include all MCP servers so Claude can reach them.
# Note: setting ALLOWED_TOOLS disables agent-mode (Issue #154). Keep legacy
# mode + silence the warning with RALPH_USE_AGENT=false.
ALLOWED_TOOLS="Write,Read,Edit,Bash(git *),Bash(npm *),Bash(grep *),Bash(find *),Bash(gh *),...,mcp__tapps-mcp__*,mcp__tapps-brain__*,mcp__docs-mcp__*,mcp__plugin_linear_linear__*"
RALPH_USE_AGENT=false

# Context management: auto-reset at 20 iterations keeps cost flat
RALPH_CONTINUE_AS_NEW_ENABLED=true
RALPH_MAX_SESSION_ITERATIONS=20

# Rate-limit guard rails
MAX_CALLS_PER_HOUR=100
CLAUDE_AUTO_UPDATE=false  # EACCES prone; manual upgrades are cleaner
```

### 4.2 `~/.ralph/secrets.env` (or project-level env)

```bash
# Unlocks full Context7 tier in tapps-mcp (TypeScript, Astro, Playwright, etc.)
CONTEXT7_API_KEY="<get from context7.com/dashboard>"

# If tapps-brain HTTP deployment:
TAPPS_BRAIN_AUTH_TOKEN="<token>"

# Never commit. Never export via ALLOWED_TOOLS.
```

**Note on context7:** tapps-mcp already wraps it ([packages/tapps-core/src/tapps_core/knowledge/lookup.py](../../tapps-mcp/packages/tapps-core/src/tapps_core/knowledge/lookup.py)). **Do not install context7 as a separate MCP server** — you'd get double billing and split caches.

### 4.3 `PROMPT.md` patches (project-level)

Add a **"Delegate before drafting"** section telling Claude the decision matrix:

```markdown
## Delegate before drafting

Before writing code:
- **Read or search existing code** → `Task(ralph-explorer, "<question>")`. Haiku. Fast + cheap.
- **Use an external library API** → `tapps_lookup_docs(library, topic)` first. Prevents hallucinated method names.
- **Recall prior decisions** → `brain_recall(<topic>)`. If this area was touched before, prior rationale loads.

Do not do these investigations inline in the main agent — the main agent is for writing code, not searching and reading.

## Epic-boundary QA

Mid-epic: set `TESTS_STATUS: DEFERRED`, skip `ralph-tester` + `ralph-reviewer`.
At the last `- [ ]` of an epic OR before `EXIT_SIGNAL: true`:
1. `Task(ralph-tester, "run the full test command for this project")`
2. `Task(ralph-reviewer, "review the diff against main")`
3. `tapps_validate_changed(file_paths="<explicit list>")`
4. `tapps_checklist(task_type="<feature|bugfix|refactor|security|review|epic>")`

## Remember when it matters

Call `brain_remember(<fact>, tier=<tier>)` only when:
- User corrects you about a non-obvious rule
- A decision is made with rationale (save the rationale, not the decision)
- Debugging reveals a subtle invariant not obvious from the code

Tier selection:
- `architectural` (180d) — tech stack, infra contracts
- `pattern` (60d) — coding conventions, API shapes
- `procedural` (30d) — workflows, runbooks
- `context` (14d) — session-specific; use sparingly

Do NOT save: code patterns (grep can find them), git history (blame is authoritative),
current task state (that's for status.json), secrets, PII, fix recipes.
```

## Part 5 — Cost model (expected vs observed)

Session observed against NLTlabsPE (26 loops):

| Metric | Observed | With optimizations | Delta |
|--------|----------|-------------------|-------|
| Cost/loop avg | $2.04 | $0.40–0.80 | **~3-5×** |
| Cost/ticket | $1.36 | $0.25–0.40 | **~4×** |
| DOC loops | $2.12 avg | $0.10–0.15 (Haiku) | **~15×** |
| IMPL loops | $2.23 avg | $0.40–0.60 (Sonnet) | **~4×** |
| LARGE/architectural | — (none yet) | $5–10 (Opus, rare) | — |
| QA loops (epic boundary) | 0 observed | $1–2 (ralph-tester + reviewer) | adds 1-2 loops per epic |

**Arithmetic on remaining NLTlabsPE backlog** (31 non-blocked open tickets):
- Current trajectory: 31 × $1.36 = **~$42**
- Optimized trajectory: 31 × $0.35 = **~$11**
- Savings: **~$31** on this one project

The savings compound on longer backlogs. The optimizations also improve quality (QA actually runs at epic boundaries rather than being skipped silently).

## Part 6 — Measurement

**Check the per-loop data after every ~20 loops:**

```bash
cd ~/code/<project> && ralph-cost-report --summary
```

Watch these counters:

| Counter | Healthy signal |
|---------|----------------|
| `tapps_mcp` | >10 / loop (session_start + quick_check fires) |
| `tapps_brain` | >0 / 5 loops (brain_recall fires when entering a known area) |
| `docs_mcp` | >0 / docs-related loop |
| `linear` | 5-15 / loop (pick issue + move state + comment) |
| `context7` | Don't track directly — inside `tapps_lookup_docs`. Check `.tapps-mcp-cache/` growing |
| `named_ralph_explorer` | >0 / 3 loops (Haiku delegation) |
| `named_ralph_tester` | >0 / epic (boundary QA) |
| `named_ralph_reviewer` | >0 / epic (boundary QA) |
| `named_ralph_architect` | >0 / LARGE task (rare, expensive) |

**If `tapps_brain=0` for 5+ loops in a row:** the prompt isn't telling Claude to recall. Patch PROMPT.md.

**If `named_ralph_*=0` for all loops:** the prompt isn't teaching Claude the delegation pattern. Patch PROMPT.md.

**If `cost/loop` is climbing steadily:** session context is growing unbounded. Verify `RALPH_CONTINUE_AS_NEW_ENABLED=true` and `RALPH_MAX_SESSION_ITERATIONS=20` — the auto-reset should keep cost flat.

## Part 7 — Known gotchas to design around

1. **tapps-brain startup race.** If the brain container starts *after* `ralph --live`, Ralph's probe misses it, prompt omits brain guidance, Claude never calls `brain_*`. Fix: start tapps-brain FIRST, then ralph. Verify with `docker ps | grep brain` before launching.
2. **`tapps_validate_changed` without explicit paths is a time sink.** Minutes instead of seconds. Always pass `file_paths=`.
3. **Agent mode vs `ALLOWED_TOOLS`.** Setting `ALLOWED_TOOLS` auto-disables agent mode (Ralph's Issue #154). Agent mode's `disallowedTools` blocklist is cleaner but excludes MCP tools — so you need the allowlist. Accept legacy mode + `RALPH_USE_AGENT=false`.
4. **`linear_get_next_task` in push-mode without the TAP-741 fix.** Emits false `linear_api_error: reason=no_api_key` every loop. Upgrade source repo + `ralph-upgrade`.
5. **Context7 cache staleness.** 24h TTL default. If an upstream library ships a breaking change, cache serves stale info for up to a day. For security-sensitive libs, invalidate manually.
6. **tapps-brain max entries is silent.** 5000 entry cap auto-evicts without warning. Monitor via `brain_status()` and clean up with `maintenance_gc` periodically.
7. **Sub-agents cost money too.** `ralph-explorer` is cheap but not free ($0.02–0.10). `ralph-tester` is Sonnet ($1–2 per full test run). Don't delegate trivial 1-line questions — delegate searches that would take 5+ Reads.

## Part 8 — Rollout plan (practical)

**Phase 0 — Measure baseline (now):**
- `ralph-cost-report --summary` on the current project
- Note the counters (especially the zeros)

**Phase 1 — Fix the config (15 min):**
- Update `.ralphrc`: Sonnet default, `RALPH_USE_AGENT=false`, continue-as-new, ALLOWED_TOOLS with all MCPs
- Patch `PROMPT.md` with the "Delegate before drafting" + "Epic-boundary QA" + "Remember when it matters" sections
- Add `CONTEXT7_API_KEY` to `~/.ralph/secrets.env` (if you have one)

**Phase 2 — Verify infrastructure (5 min):**
- `docker ps` — tapps-brain container is up
- `curl http://localhost:8080/health` — returns ok
- `claude mcp list` — tapps-brain, tapps-mcp, docs-mcp, plugin:linear:linear all reachable

**Phase 3 — Restart + observe (20 min):**
- Ctrl-C current ralph if running
- `ralph --live`
- Watch first 3 loops: `tapps_brain` counter should go >0 on loop 1 or 2
- If after 3 loops `tapps_brain=0`: PROMPT.md isn't reaching Claude — check `[INFO] tapps-brain reachable` line at startup

**Phase 4 — Steady state (ongoing):**
- `ralph-cost-report --summary` every ~20 loops
- Expect cost to stabilize around $0.40–0.80/loop
- If it drifts up: check for context-reset failure (`grep "continue-as-new\|session_reset" .ralph/logs/ralph.log`)

---

**References:**
- [../CLAUDE.md](../CLAUDE.md) — Ralph architecture, design patterns
- [../docs/LINEAR-WORKFLOW.md](../docs/LINEAR-WORKFLOW.md) — Linear state machine
- [../../tapps-brain/CLAUDE.md](../../tapps-brain/CLAUDE.md) — tapps-brain usage + rules
- [../../tapps-mcp/CLAUDE.md](../../tapps-mcp/CLAUDE.md) — tapps-mcp pipeline contract
- [../ralph_cost_report.sh](../ralph_cost_report.sh) — metrics reporter (this repo)
