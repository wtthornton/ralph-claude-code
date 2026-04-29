---
title: "ADR-0005: Bash + Python SDK duality"
status: accepted
date: 2025-11-20
deciders: Ralph maintainers
tags: [sdk, runtime, architecture]
audience: [contributor, integrator]
diataxis: explanation
last_reviewed: 2026-04-23
---

# ADR-0005: Bash + Python SDK duality

## Context

Ralph started as a single bash loop. That matched the operator use case (install, run in a terminal, watch it go) and had zero runtime dependencies beyond what projects already needed (bash, jq, git).

Three forcing functions pushed us toward a second runtime:

1. **TheStudio integration.** TheStudio is a parent orchestrator that spawns sub-task Ralph agents. Spawning a bash subprocess, managing its lifecycle, and parsing its outputs was awkward. TheStudio needed to call Ralph as an async Python function, not as a CLI.
2. **Testability ceiling.** BATS is excellent for bash testing but its subprocess isolation makes it hard to test integrated async flows. A Pydantic-modeled Python implementation lets us write clean unit tests for things like the circuit breaker state machine and the parser chain.
3. **Embeddability.** Other Python apps wanted to run Ralph inline — for parallel fleet execution, for eval harnesses, for CI integration — without the bash CLI overhead.

A straightforward answer was "deprecate bash, go Python." That would have broken the operator use case that made Ralph popular in the first place.

## Decision

Ship **both** runtimes, kept in lockstep on a shared state-file schema and the `RALPH_STATUS` contract.

- **Bash CLI** (`ralph_loop.sh` + `lib/`) remains the default. Fast to install, portable, matches operator mental models.
- **Python SDK** (`sdk/ralph_sdk/`) is an async, Pydantic-v2 reimplementation selectable at runtime via `ralph --sdk` or by embedding.

Explicit parity rules:

1. **State files are the contract.** Both runtimes read and write the same `status.json`, `.circuit_breaker_state`, `.call_count`, etc. Either runtime can pick up where the other left off.
2. **The `RALPH_STATUS` block is the contract.** Both runtimes parse the same fields with the same semantics.
3. **Module correspondence.** Each Python module in `sdk/ralph_sdk/` has a bash counterpart it mirrors 1:1 (`circuit_breaker.py` ↔ `lib/circuit_breaker.sh`, `complexity.py` ↔ `lib/complexity.sh`, etc.).
4. **Behavior parity tests.** A subset of tests runs against both runtimes. Either passing and the other failing is a P0 bug.
5. **Pluggable state backend.** The SDK's `RalphStateBackend` Protocol has a `FileStateBackend` for disk (default, interop with bash) and a `NullStateBackend` for testing/embedding.

## Consequences

### Positive

- **Operators get a bash CLI.** No Python dependency surprise. Single-binary mental model.
- **Integrators get a clean async Python API.** Pydantic models, type hints, pluggable backends.
- **Testing gains a cleaner layer.** SDK tests use pytest + mypy; bash tests keep BATS.
- **Migration is a runtime flag**, not a rewrite. A project can try `ralph --sdk` and switch back if something surprises them.
- **Two implementations catch latent bugs.** Porting a feature across runtimes has repeatedly surfaced edge cases one side was quietly mishandling.

### Negative

- **Two implementations to maintain.** Every feature that touches both runtimes takes ~2x the effort. We accept this because the alternative (one runtime, losing either operator UX or embeddability) is worse.
- **Drift risk.** Without discipline, the runtimes could diverge. Mitigations:
  - Module correspondence is documented in [CLAUDE.md](../../CLAUDE.md).
  - Shared state-file schema means drift causes test failures fast.
  - Behavior-parity tests catch silent divergence.
  - Version manifest (`version.json`) exposes both runtimes' versions so operators can diagnose mismatch.
- **Higher contributor onboarding cost.** A change might need bash *and* Python. Mitigation: PR template reminds contributors to update both; reviewer flags it.

### Neutral

- The SDK version and bash CLI version are independent. SDK can be at v2.1.x while the CLI is at v2.8.x. Both are documented in [README.md](../../README.md) and the [CHANGELOG](../../CHANGELOG.md).

## Considered alternatives

- **Python only (deprecate bash).** Rejected — breaks the operator UX that made Ralph popular.
- **Bash only (no SDK).** Rejected — blocks TheStudio integration, testing improvements, and embedding.
- **Compiled binary (Rust/Go).** Rejected — high initial investment, steep learning curve for contributors, no clear win over bash + Python given our existing codebase.
- **Shim Python around bash** (Python wrapper shells out to `ralph_loop.sh`). Rejected — inherits every bash-side concurrency/state issue and doesn't enable embedding.

## Related

- [ARCHITECTURE.md](../ARCHITECTURE.md#bash--sdk-parity) — parity implementation
- [sdk-guide.md](../sdk-guide.md) — SDK module reference
- [sdk-migration-strategy.md](../sdk-migration-strategy.md) — how to migrate an integration from bash to SDK
- [CLAUDE.md](../../CLAUDE.md) — SDK module table with bash counterparts
