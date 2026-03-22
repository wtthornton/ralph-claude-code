# Epic: tapps-brain Integration — Security Design Hardening

**Epic ID:** RALPH-BRAINSEC
**Priority:** Critical
**Status:** Done
**Target Version:** N/A (tapps-brain / TappsMCP changes, tracked here for planning)
**Dependencies:** None
**Source:** [TAPPS_BRAIN_INTEGRATION_RECOMMENDATIONS.md](../../../../TappMCP/docs/planning/TAPPS_BRAIN_INTEGRATION_RECOMMENDATIONS.md) — Review feedback (2026-03-21)

---

## Problem Statement

The tapps-brain integration recommendations document (R01, R02) contains two security design flaws that would undermine the stated OWASP ASI06 compliance goals if implemented as written:

1. **R02 (Cryptographic Integrity)** specifies SHA-256 hashing per memory entry to detect tampering. However, an attacker with direct SQLite access can recompute SHA-256 hashes after modifying data. Plain SHA-256 only detects accidental corruption, not adversarial tampering. The OWASP Agent Memory Guard it references actually implies keyed hashing.

2. **R01 (Safety Checks)** introduces a `safety_bypass=True` escape hatch for trusted internal writes. But nothing prevents an agent — including a compromised or prompt-injected agent — from passing `safety_bypass=True` on its own writes. This makes the entire safety enforcement trivially bypassable by the exact attack vector it aims to prevent (memory poisoning via injected instructions).

### Impact

- R02 as designed gives false confidence — entries pass integrity checks even after adversarial modification
- R01 as designed allows a poisoned agent to bypass safety checks, defeating the purpose of mandatory enforcement
- Both flaws would be shipped to production if the recommendations are implemented without correction

## Stories

| # | ID | Story | Priority | Effort | Status |
|---|-----|-------|----------|--------|--------|
| 1 | BRAINSEC-1 | Upgrade R02 from SHA-256 to HMAC-SHA256 | Critical | Small | **Done** |
| 2 | BRAINSEC-2 | Add Access Control to R01 Safety Bypass | Critical | Small | **Done** |

## Acceptance Criteria (Epic Level)

- [ ] R02 specifies HMAC-SHA256 with a key stored outside the database
- [ ] R01 specifies that `safety_bypass` is restricted by source type and config flag
- [ ] Both changes are reflected in the recommendations document and any implementation tickets downstream
- [ ] No other R01-R04 security recommendations contain similar bypass or crypto weaknesses

---

### BRAINSEC-1 — Upgrade R02 from SHA-256 to HMAC-SHA256

**Epic:** [epic-brain-security-design.md](epic-brain-security-design.md)
**Priority:** Critical
**Status:** Done
**Effort:** Small
**Component:** `TappMCP/docs/planning/TAPPS_BRAIN_INTEGRATION_RECOMMENDATIONS.md` (R02 section)

#### Problem

SHA-256 hashing without a secret key does not detect adversarial tampering. An attacker who gains SQLite file access can modify entries and recompute valid SHA-256 hashes. The recommendation claims to "detect tampering" but the proposed mechanism only detects accidental corruption.

#### Solution

Update R02 to specify HMAC-SHA256 with a user-held secret key stored outside the database:

- Replace `SHA-256` with `HMAC-SHA256` throughout R02
- Add key storage location: `~/.tapps-brain/integrity.key` (auto-generated on first use, 256-bit random)
- Hash formula: `HMAC-SHA256(key, key + value + tier + source_agent + created_at)`
- Add note: "The key must be stored outside the SQLite database. If the key file is missing, generate a new one and re-baseline all entries on next `verify_integrity()` call."
- Update the "Where to change" section to include key management in `tapps-brain`

#### Implementation

- [ ] Update R02 "What to do" section with HMAC-SHA256 specification
- [ ] Add key storage and lifecycle guidance
- [ ] Update effort estimate if HMAC changes the complexity (likely still Medium)
- [ ] Verify the OWASP Agent Memory Guard reference actually specifies keyed hashing

---

### BRAINSEC-2 — Add Access Control to R01 Safety Bypass

**Epic:** [epic-brain-security-design.md](epic-brain-security-design.md)
**Priority:** Critical
**Status:** Done
**Effort:** Small
**Component:** `TappMCP/docs/planning/TAPPS_BRAIN_INTEGRATION_RECOMMENDATIONS.md` (R01 section)

#### Problem

R01 adds mandatory `check_content()` on every `MemoryStore.save()` call, which is correct. But it also adds `safety_bypass=True` as a parameter any caller can pass. In a prompt injection scenario, a poisoned agent is instructed to save malicious content — and that same injected instruction can tell the agent to pass `safety_bypass=True`. The bypass defeats the enforcement it was designed to provide.

#### Solution

Update R01 to restrict when `safety_bypass` is honored:

- `safety_bypass` is only honored for writes where `source` is `"system"` (not `"agent"` or `"inferred"`)
- Alternatively, `safety_bypass` requires an explicit project-level config flag: `memory.safety.allow_bypass: true` in `.tapps-mcp.yaml`, set by the project owner (not by the agent at runtime)
- Agent-sourced writes must never self-bypass, regardless of parameters passed
- Add guidance: "The bypass exists for system seeding and migration scripts, not for runtime agent use. If an agent needs to save content that triggers safety checks, the content should be reviewed, not the safety check bypassed."

#### Implementation

- [ ] Update R01 "What to do" section with bypass access control rules
- [ ] Add source-type restriction (`system` only, or config-gated)
- [ ] Add explicit anti-pattern note: agent self-bypass is prohibited
- [ ] Review R03 (rate limiting) for similar bypass vectors
