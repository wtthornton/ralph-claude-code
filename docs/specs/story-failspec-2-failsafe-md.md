# Story FAILSPEC-2: Implement FAILSAFE.md Safe Fallback Behaviors

**Epic:** [Failure Protocol Compliance](epic-failure-protocol.md)
**Priority:** Critical
**Status:** Open
**Effort:** Small
**Component:** new `FAILSAFE.md` (project root)

---

## Problem

FAILURE.md (FAILSPEC-1) documents what happens when things go wrong. FAILSAFE.md documents the **safe default behaviors** — what Ralph does when it can't determine the correct action, when components are missing, or when it's operating in a degraded state.

## Solution

Create a `FAILSAFE.md` that documents Ralph's safe defaults, degradation hierarchy, and minimum viable operation mode.

## Implementation

### FAILSAFE.md Content

```markdown
---
schema: failsafe-protocol/v1
agent: ralph
version: 2.0.0
---

# Ralph Safe Fallback Behaviors

## Degradation Hierarchy

When components fail, Ralph degrades gracefully in this order:

1. **Full operation** — All systems nominal
2. **No sub-agents** — Main agent handles all work (skip explorer/tester/reviewer)
3. **No hooks** — Loop continues without response analysis hooks (use last status)
4. **No session continuity** — Each iteration starts fresh (no --resume)
5. **No metrics/tracing** — Loop continues without observability
6. **No file protection** — Loop continues with warning (operator assumes risk)
7. **HALT** — Cannot safely continue

## Safe Defaults

| Condition | Safe Default | Rationale |
|-----------|-------------|-----------|
| Unknown task complexity | ROUTINE (Sonnet) | Over-provisioning is safer than under |
| Missing status.json | Assume no completion | Prevents false exits |
| Missing .ralphrc | Use hardcoded defaults | Ralph should work out-of-the-box |
| Unknown exit code | Treat as failure | Prevents masking real errors |
| Git not available | Halt loop | Progress detection requires git |
| Docker not available | Run on host with warning | Sandbox is opt-in |
| Missing fix_plan.md | Halt loop | No tasks = nothing to do |
| API key invalid | Halt immediately | Cannot recover without valid key |
| Circuit breaker state corrupt | Reset to CLOSED | Fresh start is safer than stuck OPEN |
| Hook returns garbage | Ignore hook output | Loop should not depend on hook correctness |

## Minimum Viable Operation

Ralph can operate with ONLY:
- `ralph_loop.sh` + `lib/circuit_breaker.sh`
- A valid Claude CLI (`claude` command)
- A `.ralph/` directory with `fix_plan.md` and `PROMPT.md`
- A git repository

Everything else (hooks, agents, skills, metrics, sandbox) is optional enhancement.
```

## Acceptance Criteria

- [ ] FAILSAFE.md created in Ralph project root
- [ ] Degradation hierarchy documented (7 levels)
- [ ] Safe default for every ambiguous condition
- [ ] Minimum viable operation requirements listed
- [ ] All documented defaults match actual Ralph behavior

## References

- [FAILSAFE.md Specification](https://failsafe.md/)
