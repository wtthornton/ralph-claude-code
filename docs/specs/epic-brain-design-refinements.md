# Epic: tapps-brain Integration — Technical Design Refinements

**Epic ID:** RALPH-BRAINDESIGN
**Priority:** Medium
**Status:** Done
**Target Version:** N/A (design refinements for tapps-brain integration recommendations)
**Dependencies:** RALPH-BRAINSEC (security fixes should land first)
**Source:** [TAPPS_BRAIN_INTEGRATION_RECOMMENDATIONS.md](../../../../TappMCP/docs/planning/TAPPS_BRAIN_INTEGRATION_RECOMMENDATIONS.md) — Review feedback (2026-03-21)

---

## Problem Statement

Four recommendations in the tapps-brain integration document have design gaps that would cause issues in production if implemented as specified:

1. **No success criteria (R01-R04):** The P0 security recommendations have no measurable definition of "working." Without false positive/negative rate targets, teams will ship features that are technically complete but operationally broken.

2. **Privacy gap in R08 and R14:** R08 (Hive for Agent Teams) shares memories across agents without consent or data classification checks. R14 (Auto-Save Quality Results) persists data without explicit user action. Neither discusses privacy implications or opt-out mechanisms.

3. **R10 graph boost on empty graphs:** Graph-boosted recall is enabled by default, but new projects have zero relation triples. The graph query runs on every recall/search, adding latency with zero ranking benefit until enough relations accumulate.

4. **R03 rate limiting blocks legitimate batches:** The 20 writes/minute default will block `import_markdown` (R09), initial seeding, and federation sync — all legitimate bulk operations from within the same system.

### Impact

- Security features ship without validation targets, making "done" subjective
- Hive auto-propagation could leak private context across agents without user awareness
- New projects pay a graph query cost on every recall with no benefit
- First user to run markdown import hits a rate limit warning, creating a poor first experience

## Stories

| # | ID | Story | Priority | Effort | Status |
|---|-----|-------|----------|--------|--------|
| 1 | BRAINDESIGN-1 | Add Success Criteria to P0 Security Recommendations | Medium | Small | **Done** |
| 2 | BRAINDESIGN-2 | Add Privacy Safeguards to R08 Hive and R14 Auto-Save | Medium | Small | **Done** |
| 3 | BRAINDESIGN-3 | Gate R10 Graph Boost on Relation Density | Medium | Trivial | **Done** |
| 4 | BRAINDESIGN-4 | Add Batch-Mode Exemption to R03 Rate Limiting | Medium | Trivial | **Done** |

## Acceptance Criteria (Epic Level)

- [ ] Each P0 recommendation includes measurable success criteria (false positive/negative rates, latency targets)
- [ ] R08 and R14 include privacy safeguards, consent notices, and opt-out mechanisms
- [ ] R10 specifies a relation count threshold below which graph boost is skipped
- [ ] R03 specifies a batch context mechanism that exempts legitimate bulk operations from rate limiting

---

### BRAINDESIGN-1 — Add Success Criteria to P0 Security Recommendations

**Epic:** [epic-brain-design-refinements.md](epic-brain-design-refinements.md)
**Priority:** Medium
**Status:** Done
**Effort:** Small
**Component:** `TappMCP/docs/planning/TAPPS_BRAIN_INTEGRATION_RECOMMENDATIONS.md` (R01, R02, R03, R04)

#### Problem

None of the four P0 recommendations define what "working" looks like. R01 says "make safety checks mandatory" but doesn't specify acceptable false positive rates. R02 says "verify on read" but doesn't specify what happens when verification fails at scale. Without targets, teams will debate whether the feature is done, and false positives will be treated as bugs rather than expected behavior to be tuned.

#### Solution

Add a "Success Criteria" section to each P0 recommendation:

**R01 (Safety Checks):**
```
- 0 false negatives against the MINJA test suite (6 known injection patterns)
- < 0.1% false positive rate on the existing tapps-brain test corpus (1,226 tests)
- No measurable latency regression on save operations (< 1ms additional)
```

**R02 (Cryptographic Integrity):**
```
- 100% tamper detection rate on modified entries (adversarial test: modify DB, verify catches it)
- < 2ms additional latency on read path (hash verify)
- Lazy population completes within 1 session for stores with < 10,000 entries
```

**R03 (Rate Limiting):**
```
- 0 false positives during normal agent sessions (1-5 writes/session)
- Anomaly logging fires on > 20 writes/minute synthetic test
- No impact on batch operations using batch_context exemption
```

**R04 (Trust-Scored Retrieval):**
```
- Human-sourced entries rank higher than agent-sourced entries of equal relevance in A/B test
- No ranking regression for single-source stores (all entries same trust level)
- < 1ms additional latency on composite scoring
```

#### Implementation

- [ ] Draft success criteria for R01, R02, R03, R04
- [ ] Add "Success Criteria" subsection to each recommendation (after "Effort")
- [ ] Ensure criteria are measurable (numbers, not qualitative descriptions)
- [ ] Add note that criteria should be validated in pilot before full rollout

---

### BRAINDESIGN-2 — Add Privacy Safeguards to R08 Hive and R14 Auto-Save

**Epic:** [epic-brain-design-refinements.md](epic-brain-design-refinements.md)
**Priority:** Medium
**Status:** Done
**Effort:** Small
**Component:** `TappMCP/docs/planning/TAPPS_BRAIN_INTEGRATION_RECOMMENDATIONS.md` (R08, R14)

#### Problem

**R08 (Hive):** When Agent Teams are detected, Hive auto-initializes and auto-propagates architectural-tier memories. But `private_tiers: ["context"]` only excludes the context tier — procedural and pattern memories may also contain sensitive information (e.g., credentials mentioned in a procedural note, personal preferences in a pattern). There's no data classification check before propagation, and no user notice that sharing is happening.

**R14 (Auto-Save Quality Results):** Expert consultation results and recurring quality findings are auto-saved to memory with `source: "agent"`. Users may not realize that quality tool outputs are being persisted across sessions. There's no opt-out beyond editing a config file, and no way to audit what was auto-saved.

#### Solution

Add privacy safeguards to both recommendations:

**R08 additions:**
- Before auto-propagating to Hive, check that the entry does not have `scope: "private"` or user-defined sensitive tags (configurable: `hive.sensitive_tags: ["credentials", "personal", "secret"]`)
- Surface a first-run notice on first Hive initialization: "Agent Teams memory sharing is enabled. Architectural-tier memories will be visible to all agents in this project."
- Add `tapps_memory(action="hive_config")` to let users view and modify propagation rules

**R14 additions:**
- Auto-saved entries should be tagged `source: "auto-quality"` (distinct from manual `agent` saves)
- Surface auto-saved entries in `memory_health()` output with a count and most recent entries
- Respect `memory.auto_save_quality: false` opt-out in `.tapps-mcp.yaml` (already mentioned but should be more prominent)
- Add `tapps_memory(action="list", source="auto-quality")` filter for auditing auto-saved content

#### Implementation

- [ ] Add sensitive-tag filtering and first-run notice to R08 "What to do"
- [ ] Add `source: "auto-quality"` tagging and audit filter to R14 "What to do"
- [ ] Add opt-out prominence guidance to R14
- [ ] Review R17 (notifications) for similar privacy considerations with change notifications

---

### BRAINDESIGN-3 — Gate R10 Graph Boost on Relation Density

**Epic:** [epic-brain-design-refinements.md](epic-brain-design-refinements.md)
**Priority:** Medium
**Status:** Done
**Effort:** Trivial
**Component:** `TappMCP/docs/planning/TAPPS_BRAIN_INTEGRATION_RECOMMENDATIONS.md` (R10)

#### Problem

R10 enables `use_graph_boost=True` by default with `graph_boost_factor=0.1`. On a new project with zero relation triples, the graph query still runs on every recall/search operation. The boost factor multiplied by zero connections produces no ranking change, but the query still costs time. This adds latency to every retrieval for new projects until enough relations accumulate to be useful.

#### Solution

Update R10 to gate activation on relation density:

```markdown
**What to do:**
- Enable `use_graph_boost=True` only when the store contains >= 10 relation
  triples. Below that threshold, skip the graph query entirely.
- Set default `graph_boost_factor=0.1` (conservative, can be tuned per profile)
- Report relation count in `memory_health()` output with activation status:
  "Graph-boosted recall: inactive (3/10 relations)" or
  "Graph-boosted recall: active (47 relations, boost=0.1)"
- When the threshold is crossed for the first time, log an info message:
  "Graph-boosted recall activated — 10+ relation triples available"
```

#### Implementation

- [ ] Update R10 "What to do" with threshold-gated activation
- [ ] Add `memory_health()` relation count and activation status to R10
- [ ] Specify the threshold is configurable per profile: `retrieval.graph_boost_min_relations: 10`

---

### BRAINDESIGN-4 — Add Batch-Mode Exemption to R03 Rate Limiting

**Epic:** [epic-brain-design-refinements.md](epic-brain-design-refinements.md)
**Priority:** Medium
**Status:** Done
**Effort:** Trivial
**Component:** `TappMCP/docs/planning/TAPPS_BRAIN_INTEGRATION_RECOMMENDATIONS.md` (R03)

#### Problem

R03 sets a default of "max 20 writes per minute." Several legitimate operations exceed this:

| Operation | Expected Write Rate |
|-----------|-------------------|
| `import_markdown` (R09) | 50-200 writes in seconds (one per heading) |
| Initial project seeding | 20-50 writes on first setup |
| Federation sync | Variable, depends on remote store size |
| Bulk `consolidate` with rewrites | 10-30 writes in a batch |

The recommendation says "warning not hard block," which is good, but even warnings during legitimate operations create noise and erode trust in the anomaly system (cry-wolf effect).

#### Solution

Add a batch-mode exemption to R03:

```markdown
**Batch operations:** Operations that legitimately produce many writes in a short
window (`import_markdown`, `seed`, `federation_sync`, `consolidate`) should acquire
a `batch_context` that:
- Suspends rate limit warnings for the duration of the batch
- Logs a single audit entry: `"batch_write": {"operation": "import_markdown", "count": 127, "duration_ms": 340}`
- Resets the sliding window after the batch completes

Batch context is acquired internally by known batch operations, not exposed as
a user-facing parameter (to prevent abuse as a rate-limit bypass).
```

#### Implementation

- [ ] Add batch-mode exemption to R03 "What to do" section
- [ ] Specify which operations qualify for batch context
- [ ] Add anti-abuse note: batch context is internal, not a user-facing parameter
- [ ] Add batch audit logging specification
