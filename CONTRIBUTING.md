---
title: Contributing to Ralph
description: How to set up a development environment, write changes that pass CI, and get a pull request reviewed.
audience: [contributor]
diataxis: how-to
last_reviewed: 2026-04-23
---

# Contributing to Ralph

Thank you for considering a contribution. Ralph is a safety-critical piece of infrastructure — it runs autonomous loops against real Anthropic API quota and real project code — so we maintain a high bar on tests and behavior preservation. The guide below is shaped around that.

> **TL;DR.** Fork → branch → write code + tests → `npm test` (1117+ tests must pass) → conventional commit → PR against `main`.

## Table of contents

- [Prerequisites](#prerequisites)
- [Environment setup](#environment-setup)
- [Repository map](#repository-map)
- [Development workflow](#development-workflow)
- [Code style](#code-style)
- [Testing requirements](#testing-requirements)
- [Commit and PR conventions](#commit-and-pr-conventions)
- [Documentation requirements](#documentation-requirements)
- [What NOT to change without discussion](#what-not-to-change-without-discussion)
- [Code of conduct](#code-of-conduct)
- [Getting help](#getting-help)

## Prerequisites

| Dependency | Why |
|---|---|
| **Bash 4.0+** | Ralph rejects older versions at startup |
| **Node.js 18+** | Required by the BATS test harness |
| **`jq`** | JSON parsing; almost every state file uses it |
| **`git`** | Required — progress detection uses `git diff` |
| **`tmux`** | Needed for monitor tests and manual validation |
| **`gawk`** | mawk lacks `match(s, re, arr)` array capture used by the plan optimizer |
| **GNU coreutils** (macOS) | `brew install coreutils` to get `gtimeout` |

## Environment setup

```bash
# 1. Fork on GitHub, then clone your fork
git clone https://github.com/YOUR_USERNAME/ralph-claude-code.git
cd ralph-claude-code

# 2. Install test tooling (BATS, bats-assert, bats-support)
npm install

# 3. Run the full suite to confirm your environment works
npm test

# 4. (Optional) Install Ralph globally for manual end-to-end testing
./install.sh

# 5. (Optional) Install the Python SDK for dev
cd sdk
pip install -e '.[dev]'
cd ..
```

Expected: 1117+ tests pass, 0 failures. If you see failures on a clean clone, file an issue before submitting a PR — something's wrong with your environment or the main branch.

## Repository map

```
ralph-claude-code/
├── ralph_loop.sh              # Core autonomous loop (~2,500 lines)
├── ralph_monitor.sh           # Live tmux monitoring dashboard
├── ralph_enable.sh            # Interactive project enablement wizard
├── ralph_enable_ci.sh         # Non-interactive enablement (CI/automation)
├── ralph_import.sh            # PRD → Ralph task conversion
├── ralph_upgrade_project.sh   # Propagate template updates to managed projects
├── install.sh / uninstall.sh  # Global installation
├── lib/                       # 20 library modules (see docs/ARCHITECTURE.md)
├── sdk/ralph_sdk/             # Python SDK (17 modules, Pydantic v2, async)
├── templates/                 # Project scaffolding (hooks, PROMPT.md, skills/global/)
├── tests/
│   ├── unit/                  # Isolated function tests (BATS)
│   ├── integration/           # Component interaction tests (BATS)
│   ├── e2e/                   # End-to-end with mock Claude CLI
│   ├── evals/deterministic/   # 64 BATS tests pinning loop invariants
│   ├── evals/stochastic/      # Live-LLM golden-file comparisons (nightly)
│   └── helpers/               # test_helper.bash, mocks.bash, fixtures.bash
├── docs/                      # User, operator, contributor docs
├── .claude/                   # Claude Code agents, hooks, skills, settings
├── .github/                   # CI, issue templates, CODEOWNERS
└── CLAUDE.md                  # Invariants for AI agents working in this repo
```

Full architecture: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Development workflow

### 1. Branch

```bash
git switch -c <type>/<short-name>
```

| Type | Example |
|---|---|
| `feature/` | `feature/token-budget-guardrail` |
| `fix/` | `fix/circuit-breaker-race` |
| `docs/` | `docs/glossary-cleanup` |
| `test/` | `test/session-continuity-edge` |
| `refactor/` | `refactor/metrics-extract-helper` |
| `chore/` | `chore/bump-bats-assert` |

### 2. Write

Follow the [code style](#code-style) below. Prefer editing existing files over creating new ones. If you're touching a module, re-read the module's comment header first — Ralph has a lot of hard-won invariants documented inline.

### 3. Test

```bash
# Full suite — must pass before PR
npm test

# Narrow to a specific area while iterating
npm run test:unit
npm run test:integration
bats tests/unit/test_rate_limiting.bats
bats --filter "can_make_call" tests/unit/test_rate_limiting.bats
```

### 4. Commit

Use [conventional commits](#commit-and-pr-conventions).

### 5. Push and open a PR

Target `main`. Use the [PR template](.github/PULL_REQUEST_TEMPLATE.md). Fill in:

- **Summary** — 1-3 bullets describing what changed and why.
- **Test plan** — exactly how a reviewer should verify it.
- **Breaking changes** — explicit, even if "none."
- **Related issues** — `Fixes #123`, `Related to #456`.

## Code style

### Bash

```bash
#!/bin/bash
# Purpose: one-line description
# Invariants: what must not break

set -o pipefail  # always

source "$(dirname "${BASH_SOURCE[0]}")/lib/date_utils.sh"

# UPPER_SNAKE_CASE for constants
MAX_CALLS_PER_HOUR=200
STATUS_FILE="status.json"

# snake_case for functions and local variables
get_circuit_state() {
    local state_file="${1:?state_file required}"
    if [[ ! -f "$state_file" ]]; then
        echo "CLOSED"
        return
    fi
    jq -r '.state' "$state_file" 2>/dev/null || echo "CLOSED"
}
```

Invariants Ralph scripts must uphold:

- **`pipefail`** after library sourcing. Silent pipeline failures are the top source of historical bugs.
- **`atomic_write`** for every counter or state-file write. Never `>` directly into `.ralph/`.
- **`tr -cd '0-9'`** on any `grep -c` or `wc -l` output before arithmetic (the `grep -c | echo "0"` pitfall).
- **`set -u` compatibility** — always `${var:-default}` any variable that may be unset.
- **Cross-platform** — `gdate`/`date`, `gtimeout`/`timeout`, `PPID==1` orphan detection on Linux vs Windows CIM queries.
- **Reentrant signal handlers** — cleanup traps must handle being called twice.

### Python (SDK)

- **Pydantic v2** for all data models, frozen where semantics allow (e.g. `TaskInput`).
- **Fully async** agent loop. Sync wrappers via `run_sync()` only.
- **Protocols over inheritance** — `RalphStateBackend`, `MemoryBackend`, `MetricsCollector` are Protocols.
- **Type hints everywhere.** Pass `mypy --strict` or equivalent.
- **Tests** mirror bash test counterparts 1:1 for features that exist in both runtimes.

### Hooks (`templates/hooks/*.sh`)

- `templates/hooks/` is the source of truth. The repo's own `.ralph/hooks/` is kept byte-identical; a unit test enforces this.
- Hooks must self-heal corrupt state files (e.g. `.circuit_breaker_state`) with a WARN, never crash the loop.
- Hooks are advisory for loop correctness — the loop must tolerate a hook returning garbage.

## Testing requirements

| Requirement | Status | Notes |
|---|---|---|
| Unit tests pass | **Blocking** | `npm run test:unit` |
| Integration tests pass | **Blocking** (TAP-537) | `npm run test:integration` — no more `\|\| true` masking |
| Deterministic evals pass | **Blocking** | `npm run test:evals:deterministic` — 64 cases pinning loop invariants |
| Stochastic evals pass | Informational | Nightly/manual; live LLM calls; Wilson score CI |
| kcov coverage | Informational | Subprocess tracing is structurally incomplete in BATS |
| New feature has tests | **Required** | PR reviewer will ask |

See [TESTING.md](TESTING.md) for the hands-on guide, including mock/fixture conventions.

### Test writing contract

- **One behavior per `@test`.** Prefer 5 focused tests over 1 combined test.
- **Isolate** — each test sets up its own temp dir, restores state in teardown.
- **Descriptive names** — read as documentation: `@test "can_make_call returns failure when at limit"`.
- **No external dependencies** — mock Claude CLI, tmux, git where reasonable; use real git only in integration tests.

## Commit and PR conventions

### Conventional commit format

```
<type>(<scope>): <summary>

<body — what changed and why>

<footer — refs, breaking changes>
```

Types: `feat`, `fix`, `docs`, `test`, `refactor`, `chore`, `perf`, `ci`.

Good commits explain the **why**, not the **what**:

```
fix(linear): retry In Progress tickets before picking new backlog work

Root cause of branch pile-up in Linear-backed projects: self-merge blocked
by CI / branch protection → ticket left In Progress → Ralph picks a fresh
backlog ticket next loop → repeat until the project has dozens of
unmerged branches and no commits on main.

Add linear_get_in_progress_task() (queries state.type == "started") and
inject the highest-priority result into build_loop_context as
"RESUME IN PROGRESS (do this FIRST)"...
```

### PR checklist

Before requesting review:

- [ ] `npm test` passes locally (all 1117+ tests)
- [ ] New code has tests (unit + integration if applicable)
- [ ] Commit messages follow conventional format
- [ ] No debug prints, commented-out code, or TODO-style cruft
- [ ] No secrets, credentials, or machine-specific paths
- [ ] `CHANGELOG.md` updated under `[Unreleased]` for user-visible changes
- [ ] `CLAUDE.md` updated if you introduced a new pattern or invariant
- [ ] Version-sync invariant preserved if bumping (`package.json` + `RALPH_VERSION` in `ralph_loop.sh`)

### Responding to review

- Make requested changes promptly.
- Ask questions when requirements are unclear. Don't guess.
- Rebase on `main` if conflicts arise (not merge).
- Explain your reasoning when you disagree — reviewers are human, and "because I said so" PRs waste everyone's time.

## Documentation requirements

Docs are checked into the repo. When you change behavior, update docs in the same PR. The mapping:

| Change type | Update |
|---|---|
| New CLI flag | [README.md](README.md) + [docs/cli-reference.md](docs/cli-reference.md) |
| New config var | [README.md](README.md) + [templates/ralphrc.template](templates/ralphrc.template) + [CLAUDE.md](CLAUDE.md) config section |
| New module (`lib/` or `sdk/`) | [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) + [CLAUDE.md](CLAUDE.md) module table |
| New failure mode | [FAILURE.md](FAILURE.md) + matrix table |
| New safe default | [FAILSAFE.md](FAILSAFE.md) + degradation hierarchy |
| New design decision | [docs/decisions/](docs/decisions/) — add an ADR |
| User-visible release | [CHANGELOG.md](CHANGELOG.md) |
| New term worth defining | [docs/GLOSSARY.md](docs/GLOSSARY.md) |

When in doubt: grep the codebase for the thing you're changing, and update every doc that mentions it.

## What NOT to change without discussion

Ralph has a few load-bearing invariants that cost real incidents to arrive at. Don't alter them without a design review:

1. **The dual-condition exit gate.** Not one condition, not three. See [ADR-0001](docs/decisions/0001-dual-condition-exit-gate.md).
2. **Hook-based response analysis.** Don't move parsing back into the loop. See [ADR-0002](docs/decisions/0002-hook-based-response-analysis.md).
3. **Fail-loud on Linear API errors.** API failure must **abstain**, never default to "plan complete" (TAP-536).
4. **Atomic state writes + `pipefail`.** Every counter write goes through `atomic_write` (TAP-535).
5. **Epic-boundary QA deferral.** QA runs at epic boundaries, not every loop. See [ADR-0004](docs/decisions/0004-epic-boundary-qa-deferral.md).
6. **`templates/hooks/` is canonical.** The repo's `.ralph/hooks/` must be byte-identical; a unit test enforces this.
7. **Version sync.** `package.json` and `RALPH_VERSION` in `ralph_loop.sh` must match. A test enforces this.

Opening a design-discussion issue for any of these is fine — changing them without one is not.

## Code of conduct

- Be respectful and professional.
- Assume good intentions.
- Welcome newcomers and help them succeed.
- Focus criticism on the code, not the person.
- Celebrate diverse perspectives.

## Getting help

- **Architecture questions** → [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- **Terminology** → [docs/GLOSSARY.md](docs/GLOSSARY.md)
- **Design decisions** → [docs/decisions/](docs/decisions/)
- **Runtime issues** → [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)
- **Ralph-for-AI guidance** → [CLAUDE.md](CLAUDE.md)
- **Bugs + features** → [GitHub Issues](https://github.com/wtthornton/ralph-claude-code/issues)

Thank you for contributing.
