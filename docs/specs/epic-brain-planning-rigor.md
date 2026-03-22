# Epic: tapps-brain Integration — Planning Rigor

**Epic ID:** RALPH-BRAINPLAN
**Priority:** High
**Status:** Done
**Target Version:** N/A (documentation and planning changes)
**Dependencies:** None
**Source:** [TAPPS_BRAIN_INTEGRATION_RECOMMENDATIONS.md](../../../../TappMCP/docs/planning/TAPPS_BRAIN_INTEGRATION_RECOMMENDATIONS.md) — Review feedback (2026-03-21)

---

## Problem Statement

The tapps-brain integration recommendations document has 18 well-researched recommendations but lacks operational rigor in four areas that would cause problems during implementation:

1. **Priority/roadmap mismatch:** R08 (Hive) is labeled P1 but placed in Phase 3. R13 (Memory-Informed Scoring) is P2 but in Phase 4. The resequencing is never explained, confusing implementers about what to work on.

2. **R04 misprioritized:** Trust-scored retrieval is labeled P0 (security-critical) but is actually a retrieval ranking refinement — it doesn't prevent or detect attacks. Grouping it with R01-R03 (which actively block attacks) inflates the P0 scope and dilutes urgency.

3. **No performance budget:** R01, R02, R03, R04, and R10 all add computation to every read or write. Compounding five new hot-path operations without latency targets risks noticeable regression that only surfaces after all phases ship.

4. **No migration or rollback strategy:** R02 requires a schema migration. R01 could cause false positive storms on existing data. There's no plan for how existing users upgrade or recover if something breaks.

### Impact

- Implementers will be confused about sequencing and may work on the wrong things
- P0 scope creep delays genuinely critical security work (R01-R03)
- Performance regression discovered late is expensive to fix
- Users with existing databases hit breakage on upgrade with no documented recovery path

## Stories

| # | ID | Story | Priority | Effort | Status |
|---|-----|-------|----------|--------|--------|
| 1 | BRAINPLAN-1 | Align Priority Tiers with Roadmap Phases | High | Trivial | **Done** |
| 2 | BRAINPLAN-2 | Demote R04 from P0 to P1 | High | Trivial | **Done** |
| 3 | BRAINPLAN-3 | Add Performance Budget Section | High | Small | **Done** |
| 4 | BRAINPLAN-4 | Add Migration and Rollback Strategy | High | Small | **Done** |

## Acceptance Criteria (Epic Level)

- [ ] Every recommendation's priority tier matches its roadmap phase, or the mismatch is explicitly justified
- [ ] P0 contains only recommendations that actively prevent or detect attacks
- [ ] Document includes latency targets for hot-path operations (save, recall, search)
- [ ] Document includes migration guidance for schema changes and rollback procedures for safety enforcement
- [ ] Effort estimates include a calibration note accounting for testing, review, and release overhead

---

### BRAINPLAN-1 — Align Priority Tiers with Roadmap Phases

**Epic:** [epic-brain-planning-rigor.md](epic-brain-planning-rigor.md)
**Priority:** High
**Status:** Done
**Effort:** Trivial
**Component:** `TappMCP/docs/planning/TAPPS_BRAIN_INTEGRATION_RECOMMENDATIONS.md` (Roadmap section)

#### Problem

R08 (Hive for Agent Teams) is labeled P1 but appears in Phase 3 of the implementation roadmap. R13 (Memory-Informed Scoring) is P2 but in Phase 4. An implementer reading the priority tiers would expect P1 items before P2 items, but the roadmap contradicts this without explanation.

#### Solution

Either:
- **Option A:** Move R08 to Phase 2 (with the other P1 items) and R13 to Phase 3, aligning tiers and phases
- **Option B:** Keep the current roadmap order but add explicit justification at the top of the Implementation Roadmap section:

> "Note: R08 is deferred from Phase 2 to Phase 3 because HiveStore lifecycle management requires stable profile management (R05-R06) as a prerequisite. R13 is deferred from Phase 3 to Phase 4 because it has the highest implementation risk and benefits from lessons learned in earlier phases."

#### Implementation

- [ ] Choose Option A or B
- [ ] Update the roadmap tables and/or add justification text
- [ ] Verify no other priority/phase mismatches exist

---

### BRAINPLAN-2 — Demote R04 from P0 to P1

**Epic:** [epic-brain-planning-rigor.md](epic-brain-planning-rigor.md)
**Priority:** High
**Status:** Done
**Effort:** Trivial
**Component:** `TappMCP/docs/planning/TAPPS_BRAIN_INTEGRATION_RECOMMENDATIONS.md` (R04 + Quick Reference)

#### Problem

R04 (Trust-Scored Retrieval) adds a `source_trust` signal to composite scoring. This is a defense-in-depth retrieval ranking improvement — it makes poisoned entries rank lower, but it does not prevent them from being saved or detect that they exist. R01-R03 actively block or flag attacks. Grouping R04 with them as P0 inflates the critical path and signals that all four must ship before anything else.

#### Solution

- Move R04 from P0 to P1
- Move R04 from Phase 1 (Security Hardening) to Phase 2 (Feature Enablement) in the roadmap
- Add a note to R04: "Trust-scored retrieval is complementary to R01-R03. It reduces the impact of poisoned entries that bypass safety checks but does not replace active prevention."
- Update the Appendix Quick Reference table

#### Implementation

- [ ] Change R04 priority from P0 to P1 in all locations (section header, roadmap, appendix)
- [ ] Move R04 row from Phase 1 table to Phase 2 table
- [ ] Add complementary-defense note to R04 motivation
- [ ] Recalculate Phase 1 effort estimate (now 4-7 days instead of 6-10 days)

---

### BRAINPLAN-3 — Add Performance Budget Section

**Epic:** [epic-brain-planning-rigor.md](epic-brain-planning-rigor.md)
**Priority:** High
**Status:** Done
**Effort:** Small
**Component:** `TappMCP/docs/planning/TAPPS_BRAIN_INTEGRATION_RECOMMENDATIONS.md` (new section)

#### Problem

Five recommendations add computation to hot paths (save and recall/search):

| Hot Path | Added By |
|----------|----------|
| `save()` | R01 (safety check), R02 (HMAC hash), R03 (rate limiter) |
| `recall()`/`search()` | R02 (hash verify), R04 (trust scoring), R10 (graph boost) |

Each individually is "low overhead" but compounding all five without benchmarks risks noticeable latency regression. This is only discovered after Phase 2 ships, when the fix is expensive.

#### Solution

Add a "Performance Constraints" section after "Architecture Decision: Gateway Model":

```markdown
### Performance Constraints

Several recommendations add overhead to hot paths (save, recall, search). Targets:
- `save()` latency: < 5ms additional overhead from safety + integrity + rate limiting combined
- `recall()` latency: < 10ms additional overhead from trust scoring + graph boost combined
- Benchmark before/after each phase with the standard 1000-entry test store
- If any phase exceeds budget, defer lower-priority additions until optimization
```

#### Implementation

- [ ] Draft performance budget section with latency targets
- [ ] Add budget section to the document after the Architecture Decision section
- [ ] Reference specific recommendations that touch each hot path
- [ ] Add "measure before/after" as an acceptance criterion for Phase 1 and Phase 2

---

### BRAINPLAN-4 — Add Migration and Rollback Strategy

**Epic:** [epic-brain-planning-rigor.md](epic-brain-planning-rigor.md)
**Priority:** High
**Status:** Done
**Effort:** Small
**Component:** `TappMCP/docs/planning/TAPPS_BRAIN_INTEGRATION_RECOMMENDATIONS.md` (new section in Roadmap)

#### Problem

R02 adds an `integrity_hash` column to the `memories` table, requiring a schema migration. R01 adds mandatory safety checks that could reject writes that previously succeeded (false positives on existing content). Neither addresses how existing users upgrade safely or roll back if things break.

#### Solution

Add a "Migration Strategy" subsection to the Implementation Roadmap:

```markdown
### Migration Strategy

- **R02 (schema migration):** Add `integrity_hash` as a nullable column. Populate
  hashes lazily on next write/reinforce, not via a bulk migration. Entries without
  hashes skip verification until written. This avoids a blocking migration on large
  stores.
- **R01 (safety enforcement):** Ship with a 1-week "warn-only" mode that logs
  blocked writes but does not reject them. Monitor false positive rate across pilot
  users before switching to enforcement mode. Add a profile-level toggle:
  `safety.enforcement: warn | block` (default: `warn` for first release, `block`
  thereafter).
- **Global rollback:** Each recommendation should be feature-flagged via profile
  YAML so any individual feature can be disabled without code changes or rollback
  deploys.

### Effort Calibration

Estimates cover implementation only, not integration testing, code review,
documentation, or release coordination. Apply a 1.5-2x multiplier for total
delivery time. The 6-10 week estimate becomes 9-15 weeks with full delivery
overhead.
```

#### Implementation

- [ ] Draft migration strategy section covering R01 and R02 upgrade paths
- [ ] Add warn-only mode specification to R01
- [ ] Add lazy hash population specification to R02
- [ ] Add feature-flag-via-profile guidance as a general principle
- [ ] Add effort calibration note to the roadmap header
