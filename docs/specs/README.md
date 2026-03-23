# Ralph design specifications

This folder holds **specifications for the Ralph harness** (the bash loop, parsers, and Claude Code integration). It is **not** where application requirements live—those belong in **`.ralph/specs/`** inside each managed project.

**Backlog rollup:** [EPIC-STORY-INDEX.md](EPIC-STORY-INDEX.md) is the canonical place for epic/story completion counts. When you close a phase, update that index and the **Stories** table in the matching epic file so they stay aligned.

## Epics (per-file detail; see index for status rollup)

| Document | Topic |
|----------|--------|
| [epic-jsonl-stream-resilience.md](epic-jsonl-stream-resilience.md) | Stream-json / JSONL parsing, live mode, WSL filesystem races |
| [epic-multi-task-cascading-failures.md](epic-multi-task-cascading-failures.md) | One-task-per-loop, permissions, ALLOWED_TOOLS, circuit breaker, MCP visibility |

## RFC / roadmap

| Document | Topic |
|----------|--------|
| [claude-code-2026-enhancements.md](claude-code-2026-enhancements.md) | Draft: agents, hooks, skills, thinner bash orchestration (v1.0 direction) |

## Archived references

Legacy long-form notes live in **[`old/`](old/)** (retained for history).

## Implementation

Stories reference files such as `lib/response_analyzer.sh`, `ralph_loop.sh`, and `templates/`. When behavior changes, update the matching story/epic **Status**, refresh [EPIC-STORY-INDEX.md](EPIC-STORY-INDEX.md) if the phase completion changed, and keep [README.md](../../README.md), [CLAUDE.md](../../CLAUDE.md), and [docs/user-guide/](../user-guide/) in sync.
