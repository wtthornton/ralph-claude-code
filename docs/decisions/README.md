---
title: Architecture decision records
description: Index of ADRs capturing the reasoning behind Ralph's major design choices.
audience: [contributor, operator, integrator]
diataxis: explanation
last_reviewed: 2026-04-23
---

# Architecture decision records

An ADR captures **one decision**, the context that motivated it, the consequences, and (when relevant) alternatives considered. Format follows [MADR](https://adr.github.io/madr/).

We write ADRs for decisions that:

- Cost real incident experience to arrive at
- Would be tempting to "fix" by someone who doesn't know the history
- Shape a load-bearing invariant in the code

Small reversible choices go in pull-request descriptions, not here.

## Records

| # | Title | Status |
|---|---|---|
| [0001](0001-dual-condition-exit-gate.md) | Dual-condition exit gate | Accepted |
| [0002](0002-hook-based-response-analysis.md) | Hook-based response analysis | Accepted |
| [0003](0003-linear-task-backend.md) | Linear task backend with fail-loud abstention | Accepted |
| [0004](0004-epic-boundary-qa-deferral.md) | Epic-boundary QA deferral | Accepted |
| [0005](0005-bash-sdk-duality.md) | Bash + Python SDK duality | Accepted |

## Writing a new ADR

Use `docs_generate_adr` from docs-mcp, or copy an existing file and edit. Number sequentially. Do not renumber — history matters.

Required sections:

- **Context and problem statement** — what forced this decision?
- **Decision drivers** — the criteria used to choose
- **Considered options** — what else was on the table
- **Decision outcome** — what we chose, and why
- **Consequences** — positive, negative, and neutral
- **Related records** — links to other ADRs this touches

Superseded records stay in place with `status: superseded by ADR-NNNN`. Don't delete them.
