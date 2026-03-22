# Story SDK-1: Agent SDK Proof of Concept

**Epic:** [RALPH-SDK](epic-sdk-integration.md)
**Priority:** High
**Status:** Superseded by v2.0.0
**Effort:** Medium
**Component:** new `sdk/ralph_agent.py` or `sdk/ralph_agent.ts`

---

## Problem

Ralph has no Agent SDK entry point. Before committing to a full migration, we need a proof of concept that validates:
- Can Ralph's loop logic be expressed as an SDK agent?
- What is the performance overhead vs. direct CLI invocation?
- Which language (Python or TypeScript) best fits Ralph's ecosystem and TheStudio's Python stack?

## Solution

Build a minimal SDK agent that replicates Ralph's core loop: read fix_plan.md → invoke Claude → parse response → check exit conditions → repeat. The PoC does NOT need to replicate all Ralph features (hooks, circuit breaker, sub-agents) — just the inner loop.

## Implementation

1. Create `sdk/` directory in ralph-claude-code project root
2. Implement minimal agent using Claude Agent SDK:
   - Read `.ralph/PROMPT.md` and `.ralph/fix_plan.md` as system context
   - Invoke Claude with tool permissions from `.ralphrc` ALLOWED_TOOLS
   - Parse response for RALPH_STATUS block
   - Check dual-condition exit gate (completion indicators + EXIT_SIGNAL)
   - Loop or exit
3. Add basic rate limiting (calls per hour counter)
4. Compare output quality and timing against CLI invocation on a reference project

### Key Design Decisions

1. **Python preferred over TypeScript:** TheStudio is Python-native (FastAPI, Temporal). Choosing Python for the SDK PoC reduces friction for TheStudio embedding. Ralph's bash CLI remains for standalone users.
2. **Minimal scope:** The PoC validates architecture, not features. Hooks, circuit breaker, and sub-agents come in SDK-3.
3. **Side-by-side operation:** The PoC runs alongside the bash CLI, not replacing it. Both can execute the same `.ralph/` project.

## Testing

```bash
@test "SDK PoC reads fix_plan.md and produces output" {
  cd "$TEST_PROJECT"
  python sdk/ralph_agent.py --project . --dry-run
  [ -f ".ralph/status.json" ]
}

@test "SDK PoC respects rate limit" {
  cd "$TEST_PROJECT"
  python sdk/ralph_agent.py --project . --calls 1 --dry-run
  # Should exit after 1 call
}

@test "SDK PoC detects EXIT_SIGNAL" {
  # Mock Claude response with EXIT_SIGNAL: true
  cd "$TEST_PROJECT"
  run python sdk/ralph_agent.py --project . --mock-exit
  [ "$status" -eq 0 ]
}
```

## Acceptance Criteria

- [ ] SDK agent reads `.ralph/PROMPT.md` and `.ralph/fix_plan.md`
- [ ] SDK agent invokes Claude and receives structured responses
- [ ] SDK agent detects EXIT_SIGNAL and exits cleanly
- [ ] SDK agent enforces basic rate limiting
- [ ] SDK agent writes status.json compatible with existing format
- [ ] Performance comparison documented (SDK vs CLI latency and token usage)
- [ ] Decision on Python vs TypeScript documented with rationale
