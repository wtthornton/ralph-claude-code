---
title: Ralph documentation index
description: Top-level map of all Ralph documentation, organized by audience and Diataxis quadrant.
audience: [user, operator, contributor]
diataxis: reference
last_reviewed: 2026-04-23
---

# Ralph documentation

Every doc in this project is classified by **audience** (who reads it) and **Diataxis quadrant** (what kind of help it gives). If you can't find what you need here, file an issue.

## By audience

### I'm a new user
Start with these in order:

1. **[Main README](../README.md)** — install, quick start, feature matrix
2. **[User guide](user-guide/)** — hands-on tutorial, file reference, requirements writing
3. **[CLI reference](cli-reference.md)** — every flag and env var
4. **[Troubleshooting](TROUBLESHOOTING.md)** — when things go wrong

### I'm running Ralph in production
5. **[Operations runbook](OPERATIONS.md)** — install, upgrade, monitor, Linear backend
6. **[Architecture](ARCHITECTURE.md)** — how the loop actually works
7. **[Glossary](GLOSSARY.md)** — Ralph-specific vocabulary (epic-boundary, RALPH_STATUS, CB states)
8. **[Failure protocol](../FAILURE.md)** — every known failure mode and response
9. **[Failsafe defaults](../FAILSAFE.md)** — degradation hierarchy
10. **[Killswitch protocol](../KILLSWITCH.md)** — emergency stop
11. **[Linear workflow](LINEAR-WORKFLOW.md)** — state transitions, review rules
12. **[GitHub setup](GITHUB_SETUP_GUIDE.md)** — Issues import, CI, dependabot
13. **[Ralph stack guide](RALPH-STACK-GUIDE.md)** — Claude Code + tapps-mcp + tapps-brain integration

### I'm embedding Ralph in another app
14. **[SDK guide](sdk-guide.md)** — Python API, configuration, state backends
15. **[SDK migration strategy](sdk-migration-strategy.md)** — bash → SDK upgrade paths
16. **[API reference](api-reference.md)** — full Pydantic model docs

### I'm contributing
17. **[Contributing guide](../CONTRIBUTING.md)** — setup, workflow, commit format
18. **[Testing guide](../TESTING.md)** — BATS, evals, coverage policy
19. **[Release checklist](../RELEASE.md)** — version sync and smoke tests
20. **[Architecture decisions](decisions/)** — ADRs for major design choices
21. **[Epic/story index](specs/EPIC-STORY-INDEX.md)** — completed design specs

### I'm an AI assistant reading this repo
- **[`../AGENTS.md`](../AGENTS.md)** — TappsMCP tool guidance (auto-generated)
- **[`../CLAUDE.md`](../CLAUDE.md)** — Ralph project context for Claude Code
- **[`../llms.txt`](../llms.txt)** — machine-readable project summary
- **[`../.github/copilot-instructions.md`](../.github/copilot-instructions.md)** — GitHub Copilot guidance

## By Diataxis quadrant

Diataxis ([diataxis.fr](https://diataxis.fr/)) says every doc should do exactly one of four things: teach, solve, describe, or explain. Ralph maps them like this:

| Quadrant | Purpose | Ralph docs |
|---|---|---|
| **Tutorial** (learning) | Take a new user by the hand | [User guide](user-guide/) |
| **How-to** (task) | Solve a specific problem | [Troubleshooting](TROUBLESHOOTING.md) • [Operations](OPERATIONS.md) • [GitHub setup](GITHUB_SETUP_GUIDE.md) |
| **Reference** (information) | Describe something exactly | [CLI reference](cli-reference.md) • [API reference](api-reference.md) • [Glossary](GLOSSARY.md) • [FAILURE.md](../FAILURE.md) • [FAILSAFE.md](../FAILSAFE.md) • [KILLSWITCH.md](../KILLSWITCH.md) |
| **Explanation** (understanding) | Illuminate a topic | [Architecture](ARCHITECTURE.md) • [Ralph stack guide](RALPH-STACK-GUIDE.md) • [ADRs](decisions/) |

## By lifecycle status

| Status | Contents |
|---|---|
| **Live** | Everything above — kept current, reviewed quarterly |
| **Historical** | [`specs/`](specs/) — 240+ completed epic/story design docs. Frozen by design; they document *why* decisions were made. Do not rewrite. |
| **Archived** | [`archive/`](archive/) — milestone reports from the 2025-10 release push. Preserved for provenance. |
| **Code review artifacts** | [`code-review/`](code-review/) — dated PR review notes. Preserved for provenance. |

## Conventions

- **Frontmatter.** Every live doc carries YAML frontmatter with `title`, `description`, `audience`, `diataxis`, and `last_reviewed`. Historical/archived docs retain whatever they shipped with.
- **Cross-links.** Internal links use relative paths. Anchor links work; external `https://` links are for citations only.
- **Code fences.** Shell snippets are copy-paste safe; paths are relative to project root unless noted.
- **Frozen areas.** `docs/specs/`, `docs/archive/`, `docs/code-review/`. Do not rewrite these — they're provenance, not reference material.

## Finding a doc by keyword

| Looking for... | Read |
|---|---|
| Exit gate behavior | [ADR-0001](decisions/0001-dual-condition-exit-gate.md), [ARCHITECTURE.md](ARCHITECTURE.md#exit-gate) |
| Circuit breaker states | [GLOSSARY.md](GLOSSARY.md#circuit-breaker), [FAILURE.md](../FAILURE.md#fm-002-circuit-breaker-trip) |
| Hook pipeline | [ADR-0002](decisions/0002-hook-based-response-analysis.md), [ARCHITECTURE.md](ARCHITECTURE.md#hooks) |
| RALPH_STATUS block | [GLOSSARY.md](GLOSSARY.md#ralph_status), [ARCHITECTURE.md](ARCHITECTURE.md#ralph_status) |
| Epic-boundary deferral | [ADR-0004](decisions/0004-epic-boundary-qa-deferral.md), [GLOSSARY.md](GLOSSARY.md#epic-boundary) |
| Linear workflow | [LINEAR-WORKFLOW.md](LINEAR-WORKFLOW.md), [ADR-0003](decisions/0003-linear-task-backend.md) |
| Bash vs SDK | [ADR-0005](decisions/0005-bash-sdk-duality.md), [sdk-migration-strategy.md](sdk-migration-strategy.md) |
| tapps-mcp / tapps-brain stack | [RALPH-STACK-GUIDE.md](RALPH-STACK-GUIDE.md) |

## Maintaining these docs

Use the **docs-mcp** MCP server (runs in the Claude Code harness):

```
docs_check_completeness         # overall health score
docs_check_freshness            # flag docs older than 30 days
docs_check_links --broken_only  # find broken internal links
docs_check_diataxis             # quadrant balance
docs_check_drift                # code changes not in docs
```

When rewriting, run `docs_check_style` last — heading-case noise dominates and is a stylistic preference, not a quality signal.
