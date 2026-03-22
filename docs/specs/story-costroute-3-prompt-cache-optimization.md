# Story COSTROUTE-3: Prompt Structure Optimization for Cache Hits

**Epic:** [Cost-Aware Model Routing](epic-cost-aware-routing.md)
**Priority:** High
**Status:** Open
**Effort:** Small
**Component:** `.claude/agents/ralph.md`, `ralph_loop.sh`, `.claude/hooks/on-session-start.sh`

---

## Problem

Anthropic's automatic prompt caching provides up to **90% cost reduction** and **85% latency reduction** for repeated prompt prefixes. However, Ralph's prompt construction interleaves stable content (agent definition, tool config) with variable content (current task, loop count), potentially invalidating the cache on every iteration.

## Solution

Restructure Ralph's prompt to maximize the stable prefix length. Cache hits require the prompt prefix to be identical across invocations.

## Implementation

### Step 1: Audit current prompt structure

Current prompt assembly order in `build_claude_command()`:
```
1. System prompt (--append-system-prompt): PROMPT.md + loop context (variable ❌)
2. Agent definition (--agent ralph): ralph.md (stable ✅)
3. User prompt (-p): Task description (variable ❌)
```

The system prompt includes loop count, recent status, and task-specific context — all variable. This invalidates cache for the entire prompt.

### Step 2: Restructure for cache optimization

New prompt assembly strategy:
```
[STABLE PREFIX — cached]
├── Agent definition (ralph.md)          ~2000 tokens — rarely changes
├── AGENT.md (build/run instructions)    ~500 tokens — per-project stable
├── PROMPT.md (static sections)          ~1000 tokens — per-project stable
└── Tool definitions                     ~3000 tokens — stable

[SEMI-STABLE MIDDLE]
├── fix_plan.md (full plan)              ~2000 tokens — changes on task completion
└── Recent file context                  ~1000 tokens — changes per module

[VARIABLE SUFFIX — never cached]
├── Loop iteration number                ~10 tokens
├── Current task description             ~100 tokens
├── Recent status/errors                 ~200 tokens
└── Rate limit state                     ~50 tokens
```

### Step 3: Split PROMPT.md into stable and dynamic sections

```bash
# In on-session-start.sh:
# Generate the dynamic prompt suffix separately
ralph_generate_dynamic_context() {
    local loop_count="$1"
    local current_task="$2"

    cat <<EOF
---
## Current Iteration Context
Loop: ${loop_count}
Task: ${current_task}
Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)
$(ralph_get_rate_limit_status)
$(ralph_get_recent_errors)
---
EOF
}
```

### Step 4: Move stable content to agent definition

Move content that currently lives in the system prompt (via `--append-system-prompt`) into the agent definition file (`ralph.md`), which is loaded as part of the stable prefix:

- Build/run instructions → agent definition preamble
- File protection rules → already in PreToolUse hooks (stable)
- Tool restrictions → already in `disallowedTools` (stable)

### Step 5: Add cache hit tracking

```bash
# Track cache efficiency in metrics
ralph_track_cache_metrics() {
    local input_tokens="$1" cache_read_tokens="$2"
    if [[ "$cache_read_tokens" -gt 0 ]]; then
        local cache_rate
        cache_rate=$(awk "BEGIN {printf \"%.1f\", ($cache_read_tokens / ($input_tokens + $cache_read_tokens)) * 100}")
        log "DEBUG" "Prompt cache hit rate: ${cache_rate}% ($cache_read_tokens cached / $input_tokens new)"
    fi
}
```

## Design Notes

- **Anthropic automatic caching**: As of 2026, Anthropic automatically caches prompt prefixes. No explicit `cache_control` blocks needed — just ensure the prefix is identical.
- **Agent definition is the most stable**: ralph.md changes only on Ralph version updates. This should be the outermost prefix layer.
- **fix_plan.md is semi-stable**: Changes only when a task is completed (checkbox toggled). Between iterations within the same task, it's identical.
- **Minimal code changes**: This is primarily a restructuring of how the prompt is assembled, not new functionality.
- **Cache metrics**: Claude API returns `cache_creation_input_tokens` and `cache_read_input_tokens` in usage data. Track these to verify cache effectiveness.

## Acceptance Criteria

- [ ] Prompt structured with stable prefix → semi-stable middle → variable suffix
- [ ] Stable content moved from `--append-system-prompt` to agent definition where possible
- [ ] Dynamic context (loop count, rate state) isolated to variable suffix
- [ ] Cache hit rate tracked in metrics (when available from API response)
- [ ] No change to Ralph's functional behavior — only prompt ordering

## Test Plan

```bash
@test "dynamic context is generated correctly" {
    source "$RALPH_DIR/ralph_loop.sh"
    local context
    context=$(ralph_generate_dynamic_context 5 "Fix typo in README")
    assert_output --partial "Loop: 5"
    assert_output --partial "Fix typo in README"
}

@test "stable sections do not include loop-specific data" {
    # Verify ralph.md doesn't contain dynamic content
    run grep -c "Loop:" "$RALPH_DIR/.claude/agents/ralph.md"
    assert_output "0"
}
```

## References

- [Claude API — Prompt Caching](https://platform.claude.com/docs/en/build-with-claude/prompt-caching)
- [Anthropic Fixed the Biggest Hidden Cost in AI Agents](https://medium.com/ai-software-engineer/anthropic-just-fixed-the-biggest-hidden-cost-in-ai-agents-using-automatic-prompt-caching-9d47c95903c5)
- [oFox — How to Reduce AI API Costs](https://ofox.ai/blog/how-to-reduce-ai-api-costs-2026/)
