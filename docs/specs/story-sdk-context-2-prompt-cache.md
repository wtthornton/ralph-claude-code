# Story SDK-CONTEXT-2: Prompt Cache Optimization

**Epic:** [SDK Context Management](epic-sdk-context-management.md)
**Priority:** P2
**Status:** Pending
**Effort:** 1 day
**Component:** `ralph_sdk/agent.py`

---

## Problem

The CLI's `ralph_build_cacheable_prompt()` separates the prompt into a stable prefix (identity, build instructions, tool permissions) and dynamic suffix (loop count, progress, current task). This maximizes Claude's prompt cache hits.

The SDK rebuilds the full prompt each iteration with no cache awareness. For multi-loop runs sending similar prompts, this misses up to 90% input token cost reduction available from prompt caching.

**Claude prompt caching (March 2026)**: Cached content is stored for 5 minutes (1.25× write cost) or 1 hour (2.0× write cost, now GA — no beta header needed). The cache is keyed on exact prefix match — identical prefixes across requests reuse the cache. Cache reads cost 0.1× the base input price (90% discount). A 5-minute cache pays for itself after just one read; a 1-hour cache after two reads. Cached tokens don't count against ITPM rate limits, increasing effective throughput. Up to **4 cache breakpoints** per prompt. Minimum cacheable sizes: **1,024 tokens** (Sonnet), **4,096 tokens** (Opus/Haiku). Caches are isolated at the workspace level (changed Feb 2026). Automatic caching is also available by adding `cache_control={"type": "ephemeral"}` at the top level of the API call.

## Solution

Add a `PromptParts` model and a `build_prompt()` function that splits the prompt into `stable_prefix` and `dynamic_suffix`. The embedder (TheStudio) controls the split point.

## Implementation

```python
# In ralph_sdk/agent.py or a new ralph_sdk/prompt.py:

from pydantic import BaseModel


class PromptParts(BaseModel):
    """Prompt split into cacheable prefix and dynamic suffix."""
    stable_prefix: str
    dynamic_suffix: str

    @property
    def full_prompt(self) -> str:
        return f"{self.stable_prefix}\n\n{self.dynamic_suffix}"

    @property
    def estimated_cache_savings_pct(self) -> float:
        """Estimated cache hit ratio: proportion of prompt that is stable."""
        total = len(self.stable_prefix) + len(self.dynamic_suffix)
        if total == 0:
            return 0.0
        return len(self.stable_prefix) / total


def build_prompt(
    task: str,
    context: str,
    config: "RalphConfig",
    system_prompt: str = "",
    build_instructions: str = "",
    tool_permissions: str = "",
    loop_count: int = 0,
    progress_summary: str = "",
) -> PromptParts:
    """Build a prompt split for cache optimization.

    The stable_prefix contains content that doesn't change between iterations:
    - System/identity prompt
    - Build/run instructions (AGENT.md content)
    - Tool permissions and allowed tools
    - Task description (same across loops for a given task)

    The dynamic_suffix contains content that changes each iteration:
    - Loop count and progress
    - Progressive context (current plan section)
    - Previous iteration results
    """
    stable_parts = []
    if system_prompt:
        stable_parts.append(system_prompt)
    if build_instructions:
        stable_parts.append(build_instructions)
    if tool_permissions:
        stable_parts.append(tool_permissions)
    stable_parts.append(f"## Task\n\n{task}")

    dynamic_parts = []
    if loop_count > 0:
        dynamic_parts.append(f"Loop iteration: {loop_count}")
    if progress_summary:
        dynamic_parts.append(f"## Progress\n\n{progress_summary}")
    if context:
        dynamic_parts.append(f"## Current Context\n\n{context}")

    return PromptParts(
        stable_prefix="\n\n".join(stable_parts),
        dynamic_suffix="\n\n".join(dynamic_parts),
    )
```

## Design Notes

- **Embedder controls split**: TheStudio decides what goes in `system_prompt`, `build_instructions`, etc. The SDK provides the structure; the embedder provides the content.
- **Cache key is prefix**: Claude's prompt cache matches on exact prefix. By putting all stable content first, subsequent iterations reuse the cache for that entire prefix.
- **Estimated savings**: The `estimated_cache_savings_pct` property helps embedders understand the cache efficiency of their prompt design.
- **Compatible with progressive context**: The `context` parameter receives output from `ContextManager.build_progressive_context()`.

## Acceptance Criteria

- [ ] `build_prompt()` returns `PromptParts` with `stable_prefix` and `dynamic_suffix`
- [ ] `stable_prefix` contains system prompt, build instructions, tool permissions, and task
- [ ] `dynamic_suffix` contains loop count, progress, and current context
- [ ] `full_prompt` property concatenates both parts
- [ ] `estimated_cache_savings_pct` returns proportion of stable content
- [ ] Empty inputs produce valid (possibly empty) prompt parts

## Test Plan

```python
import pytest
from ralph_sdk.prompt import build_prompt, PromptParts

class TestPromptCacheOptimization:
    def test_stable_prefix_contains_system_prompt(self):
        parts = build_prompt(
            task="Fix the login bug",
            context="",
            config=RalphConfig(),
            system_prompt="You are Ralph.",
        )
        assert "You are Ralph." in parts.stable_prefix
        assert "You are Ralph." not in parts.dynamic_suffix

    def test_dynamic_suffix_contains_loop_count(self):
        parts = build_prompt(
            task="Fix the login bug",
            context="Current section...",
            config=RalphConfig(),
            loop_count=5,
        )
        assert "Loop iteration: 5" in parts.dynamic_suffix
        assert "Loop iteration: 5" not in parts.stable_prefix

    def test_full_prompt_concatenates(self):
        parts = build_prompt(
            task="Task", context="Context", config=RalphConfig(),
            system_prompt="System",
        )
        assert "System" in parts.full_prompt
        assert "Context" in parts.full_prompt

    def test_cache_savings_estimate(self):
        parts = PromptParts(
            stable_prefix="x" * 800,
            dynamic_suffix="y" * 200,
        )
        assert parts.estimated_cache_savings_pct == pytest.approx(0.8, abs=0.01)

    def test_empty_inputs(self):
        parts = build_prompt(task="", context="", config=RalphConfig())
        assert isinstance(parts.stable_prefix, str)
        assert isinstance(parts.dynamic_suffix, str)
```

## References

- CLI `ralph_build_cacheable_prompt()`: Prefix/suffix split
- Claude prompt caching: cache_control breakpoints, 5-minute TTL
- [ralph-sdk-upgrade-evaluation.md](../../../TheStudio/docs/ralph-sdk-upgrade-evaluation.md) §1.8
