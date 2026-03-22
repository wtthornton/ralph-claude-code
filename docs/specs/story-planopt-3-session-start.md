# Story RALPH-PLANOPT-3: Session-Start Integration

**Epic:** [Plan Optimization on Startup](epic-plan-optimization.md)
**Priority:** Critical
**Status:** Not Started
**Effort:** Small
**Component:** `templates/hooks/on-session-start.sh`, `lib/plan_optimizer.sh`

---

## Problem

Even with analysis (PLANOPT-1) and reordering (PLANOPT-2) implemented, there is no
trigger to run optimization. It must execute automatically on every loop startup where
the fix_plan.md has changed, with zero human intervention.

## Solution

Integrate plan optimization into the `on-session-start.sh` hook. This hook already runs
at the start of every Ralph loop and injects context into Claude's system prompt. Add:

1. **Change detection** — Hash fix_plan.md and compare against last optimization hash
2. **Conditional optimization** — Only run if hash differs (plan changed since last opt)
3. **Context injection** — Tell Claude the plan was optimized (so it doesn't re-read stale mental model)

### Why on-session-start (not ralph_loop.sh)?

- Hook runs before Claude sees anything — optimization happens before task selection
- No changes to ralph_loop.sh needed (hook-native approach)
- Consistent with existing architecture (hooks handle pre-loop setup)
- `CLAUDE_PROJECT_DIR` environment variable is available in hooks

## Implementation

### Changes to `on-session-start.sh`

```bash
# Add after line 15 (guard check), before loop count read

# --- Plan optimization ---
PLAN_OPTIMIZER="${CLAUDE_PROJECT_DIR:-.}/lib/plan_optimizer.sh"
FIX_PLAN="$RALPH_DIR/fix_plan.md"
PLAN_HASH_FILE="$RALPH_DIR/.plan_optimize_hash"
NO_OPTIMIZE="${RALPH_NO_OPTIMIZE:-false}"

if [[ -f "$FIX_PLAN" && -f "$PLAN_OPTIMIZER" && "$NO_OPTIMIZE" != "true" ]]; then
    current_hash=$(md5sum "$FIX_PLAN" 2>/dev/null | cut -d' ' -f1 || shasum "$FIX_PLAN" 2>/dev/null | cut -d' ' -f1)
    last_hash=""
    if [[ -f "$PLAN_HASH_FILE" ]]; then
        last_hash=$(cat "$PLAN_HASH_FILE" 2>/dev/null)
    fi

    if [[ "$current_hash" != "$last_hash" ]]; then
        # Source optimizer and run
        source "$PLAN_OPTIMIZER"

        if plan_optimize "$FIX_PLAN" "$CLAUDE_PROJECT_DIR"; then
            # Store new hash (of the optimized plan)
            md5sum "$FIX_PLAN" 2>/dev/null | cut -d' ' -f1 > "$PLAN_HASH_FILE" || \
            shasum "$FIX_PLAN" 2>/dev/null | cut -d' ' -f1 > "$PLAN_HASH_FILE"
            plan_optimized=true
        else
            plan_optimized=false
        fi
    else
        plan_optimized=false  # No changes, skipped
    fi
fi
```

### Context injection update

```bash
# Modify the stderr output to include optimization status
if [[ "${plan_optimized:-false}" == "true" ]]; then
    echo "Fix plan was re-optimized this loop (tasks reordered for module locality and dependency order)." >&2
fi
```

### Hash strategy

- Use `md5sum` (Linux) with `shasum` fallback (macOS)
- Hash the raw fix_plan.md content before optimization
- Store the **post-optimization** hash so the same plan isn't re-optimized
- Hash file lives at `.ralph/.plan_optimize_hash` (alongside other state files)
- When optimization writes new fix_plan.md, the new hash reflects the optimized version
- Next loop: if human hasn't changed the plan, hash matches → skip optimization

### Edge cases

1. **First run (no hash file)** — Always optimize
2. **Human edits plan between loops** — Hash changes → re-optimize
3. **Ralph checks off tasks** — Hash changes → re-optimize (checkboxes change content).
   This is cheap since checked tasks are skipped by the reorder engine.
4. **`RALPH_NO_OPTIMIZE=true`** — Skip optimization entirely (escape hatch)
5. **Optimizer fails** — Log warning to stderr, continue without optimization. Never
   block the loop.
6. **Empty fix_plan.md** — Skip optimization (nothing to reorder)
7. **All tasks checked** — Skip optimization (nothing unchecked to reorder)

### Performance budget

The optimizer must complete in **< 2 seconds**. It's bash + jq operating on a text file
that is typically < 200 lines. If it exceeds this budget, it's a bug.

If the plan has only 1 unchecked task in each section, optimization is a no-op (nothing
to reorder). The hash check + early exit should take < 50ms.

## Test Plan

```bash
# tests/unit/test_plan_optimizer_integration.bats

@test "PLANOPT-3: optimization runs on first loop (no hash file)" {
    setup_ralph_project  # Creates .ralph/ with fix_plan.md
    rm -f .ralph/.plan_optimize_hash

    run bash templates/hooks/on-session-start.sh
    [[ "$status" -eq 0 ]]
    [[ -f .ralph/.plan_optimize_hash ]]
}

@test "PLANOPT-3: optimization skips when plan unchanged" {
    setup_ralph_project
    # Run once to create hash
    bash templates/hooks/on-session-start.sh 2>/dev/null
    local hash1=$(cat .ralph/.plan_optimize_hash)

    # Run again without changes
    bash templates/hooks/on-session-start.sh 2>/dev/null
    local hash2=$(cat .ralph/.plan_optimize_hash)

    [[ "$hash1" == "$hash2" ]]
}

@test "PLANOPT-3: optimization re-runs when plan changes" {
    setup_ralph_project
    bash templates/hooks/on-session-start.sh 2>/dev/null
    local hash1=$(cat .ralph/.plan_optimize_hash)

    # Modify plan
    echo "- [ ] New task added by human" >> .ralph/fix_plan.md
    bash templates/hooks/on-session-start.sh 2>/dev/null
    local hash2=$(cat .ralph/.plan_optimize_hash)

    [[ "$hash1" != "$hash2" ]]
}

@test "PLANOPT-3: RALPH_NO_OPTIMIZE=true skips optimization" {
    setup_ralph_project
    rm -f .ralph/.plan_optimize_hash

    RALPH_NO_OPTIMIZE=true run bash templates/hooks/on-session-start.sh
    [[ "$status" -eq 0 ]]
    [[ ! -f .ralph/.plan_optimize_hash ]]
}

@test "PLANOPT-3: optimizer failure does not block session start" {
    setup_ralph_project
    # Corrupt the optimizer
    echo "exit 1" > lib/plan_optimizer.sh

    run bash templates/hooks/on-session-start.sh
    [[ "$status" -eq 0 ]]  # Hook still succeeds
}

@test "PLANOPT-3: context injection mentions optimization" {
    setup_ralph_project
    rm -f .ralph/.plan_optimize_hash

    output=$(bash templates/hooks/on-session-start.sh 2>&1)
    echo "$output" | grep -q "re-optimized"
}
```

## Acceptance Criteria

- [ ] Optimization runs automatically when fix_plan.md changes between loops
- [ ] Hash comparison prevents redundant re-optimization
- [ ] `RALPH_NO_OPTIMIZE=true` disables optimization
- [ ] Optimizer failure is non-fatal (warning logged, session continues)
- [ ] Claude is informed when plan was re-optimized (context injection via stderr)
- [ ] Completes in < 2 seconds for plans with up to 100 tasks
- [ ] Works on both Linux and macOS (md5sum/shasum portability)
- [ ] Cross-platform hash (WSL, native Linux, macOS)
