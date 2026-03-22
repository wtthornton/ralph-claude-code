# Epic: Validation Testing (Phase 9)

**Epic ID:** RALPH-TEST
**Priority:** Medium
**Affects:** Test coverage, CI/CD reliability, regression detection
**Components:** `tests/unit/`, `tests/integration/`, `tests/e2e/`
**Related specs:** `IMPLEMENTATION_PLAN.md` (§Phase 4), `TESTING.md`
**Target Version:** v1.6.0
**Depends on:** RALPH-SDK (Phase 6) for SDK integration tests, RALPH-CONFIG (Phase 7) for CLI enhancement tests

---

## Problem Statement

Ralph has strong unit test coverage (736+ tests, 100% pass rate) for core functionality, but lacks validation testing for:

1. **tmux integration** — Dashboard layout, pane management, live updates
2. **Monitor dashboard** — Real-time display accuracy, refresh behavior
3. **Status updates** — status.json accuracy and staleness detection
4. **CLI modern features** — Flags added in v1.0+ (--live, --dry-run, --output-format)
5. **SDK integration** — Hybrid CLI/SDK execution paths
6. **Backward compatibility** — Regression detection across version upgrades
7. **End-to-end** — Full loop completion on real projects

## Stories

| Story | Title | Priority | Effort | Status |
|-------|-------|----------|--------|--------|
| [TEST-1](story-test-1-tmux-integration.md) | Implement tmux Integration Tests | Medium | Medium | **Open** |
| [TEST-2](story-test-2-monitor-dashboard.md) | Implement Monitor Dashboard Tests | Medium | Medium | **Open** |
| [TEST-3](story-test-3-status-update.md) | Implement Status Update Tests | Medium | Small | **Open** |
| [TEST-4](story-test-4-cli-enhancements.md) | Implement CLI Enhancement Tests | Medium | Medium | **Open** |
| [TEST-5](story-test-5-sdk-integration.md) | Implement SDK Integration Tests | Medium | Large | **Open** |
| [TEST-6](story-test-6-backward-compatibility.md) | Implement Backward Compatibility Tests | Medium | Medium | **Open** |
| [TEST-7](story-test-7-e2e-full-loop.md) | Implement E2E Full Loop Tests | Medium | Large | **Open** |

## Implementation Order

1. **TEST-3 (Medium)** — Status update tests are smallest scope and validate a critical data contract
2. **TEST-1 (Medium)** — tmux tests require tmux availability but are self-contained
3. **TEST-2 (Medium)** — Monitor tests can share tmux test infrastructure
4. **TEST-4 (Medium)** — CLI tests after SDK stories are defined (need to know final flag set)
5. **TEST-6 (Medium)** — Backward compat tests lock in current behavior before SDK changes
6. **TEST-5 (Medium)** — SDK integration tests after RALPH-SDK is complete
7. **TEST-7 (Medium)** — E2E tests last, as they depend on all other components being stable

## Verification Criteria

- [ ] tmux dashboard renders correctly in automated test environment
- [ ] Monitor display updates accurately reflect loop state
- [ ] status.json schema validated on every write
- [ ] All CLI flags tested with expected behavior
- [ ] SDK entry point produces equivalent results to CLI entry point
- [ ] Version upgrade from v1.2.0 to latest preserves all existing behavior
- [ ] E2E test completes a real fix_plan.md task list from start to finish
- [ ] CI pipeline runs all new test suites

## Rollback

Tests are additive — no rollback needed. Failing tests indicate regressions in the code under test, not in the tests themselves.
