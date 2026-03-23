# Story SDK-CONTEXT-1: Progressive Context Loading

**Epic:** [SDK Context Management](epic-sdk-context-management.md)
**Priority:** P0
**Status:** Pending
**Effort:** 1–2 days
**Component:** `ralph_sdk/agent.py` (new: `ralph_sdk/context.py`)

---

## Problem

The CLI's `lib/context_management.sh` trims `fix_plan.md` to only the current epic section + next N unchecked items. The SDK loads the entire plan every iteration.

TheStudio fix plans can span multiple epics with 50+ tasks. Loading all of them:
- Wastes context window tokens on irrelevant completed work
- Confuses the agent with tasks from other epics
- Reduces response quality due to attention dilution in large contexts

At ~4 chars/token, a 50-task fix plan with descriptions could consume 2,000-5,000 tokens per iteration — tokens that would be better spent on the actual task context.

## Solution

Add a `ContextManager` class to the SDK with a `build_progressive_context()` method that extracts the current epic section and next N unchecked items, replacing completed sections with summary markers.

## Implementation

### Step 1: Create context module

```python
# ralph_sdk/context.py

import re
from dataclasses import dataclass


@dataclass
class ProgressiveContext:
    """Trimmed plan context for the current iteration."""
    text: str
    total_items: int
    completed_items: int
    remaining_items: int
    estimated_tokens: int


class ContextManager:
    """Manages progressive context loading for fix plans.

    Trims multi-epic fix plans to show only the current working section
    plus a configurable number of upcoming unchecked items. Completed
    sections are replaced with summary markers.
    """

    SECTION_PATTERN = re.compile(r"^##\s+(.+)$", re.MULTILINE)
    CHECKED_PATTERN = re.compile(r"^\s*-\s*\[x\]\s*", re.MULTILINE)
    UNCHECKED_PATTERN = re.compile(r"^\s*-\s*\[\s\]\s*", re.MULTILINE)

    def __init__(self, max_unchecked_items: int = 10):
        self.max_unchecked_items = max_unchecked_items

    def build_progressive_context(
        self, plan: str, max_items: int | None = None
    ) -> ProgressiveContext:
        """Return trimmed plan showing current section + N unchecked items.

        Args:
            plan: Full fix_plan.md content
            max_items: Override max unchecked items (uses instance default if None)

        Returns:
            ProgressiveContext with trimmed text and item counts
        """
        max_items = max_items or self.max_unchecked_items
        sections = self._split_sections(plan)

        total_items = len(self.CHECKED_PATTERN.findall(plan)) + len(
            self.UNCHECKED_PATTERN.findall(plan)
        )
        completed_items = len(self.CHECKED_PATTERN.findall(plan))

        # Find the current section (first section with unchecked items)
        current_idx = None
        for i, section in enumerate(sections):
            if self.UNCHECKED_PATTERN.search(section["body"]):
                current_idx = i
                break

        if current_idx is None:
            # All done — return full plan (it's just checked items)
            return ProgressiveContext(
                text=plan,
                total_items=total_items,
                completed_items=completed_items,
                remaining_items=0,
                estimated_tokens=self.estimate_tokens(plan),
            )

        # Build trimmed output
        parts: list[str] = []

        # Summarize completed sections
        completed_count = 0
        for i in range(current_idx):
            section_completed = len(
                self.CHECKED_PATTERN.findall(sections[i]["body"])
            )
            completed_count += section_completed

        if completed_count > 0:
            parts.append(f"({completed_count} completed items above)\n")

        # Include current section with item limit
        current = sections[current_idx]
        parts.append(current["header"])
        unchecked_count = 0
        for line in current["body"].split("\n"):
            if self.UNCHECKED_PATTERN.match(line):
                unchecked_count += 1
                if unchecked_count > max_items:
                    remaining_in_section = len(
                        self.UNCHECKED_PATTERN.findall(
                            "\n".join(current["body"].split("\n")[
                                current["body"].split("\n").index(line):
                            ])
                        )
                    )
                    parts.append(
                        f"\n({remaining_in_section} more items in this section)\n"
                    )
                    break
            parts.append(line)

        # Show next section header if it exists
        if current_idx + 1 < len(sections):
            next_section = sections[current_idx + 1]
            next_unchecked = len(
                self.UNCHECKED_PATTERN.findall(next_section["body"])
            )
            parts.append(f"\n{next_section['header']}")
            parts.append(f"({next_unchecked} items pending)\n")

        text = "\n".join(parts)
        return ProgressiveContext(
            text=text,
            total_items=total_items,
            completed_items=completed_items,
            remaining_items=total_items - completed_items,
            estimated_tokens=self.estimate_tokens(text),
        )

    @staticmethod
    def estimate_tokens(text: str) -> int:
        """Estimate token count using 4-char heuristic.

        This is a rough estimate suitable for budget awareness.
        For precise counting, use the Anthropic tokenizer.
        """
        return len(text) // 4

    def _split_sections(self, plan: str) -> list[dict[str, str]]:
        """Split plan into sections by ## headers."""
        sections: list[dict[str, str]] = []
        lines = plan.split("\n")
        current_header = ""
        current_body: list[str] = []

        for line in lines:
            if self.SECTION_PATTERN.match(line):
                if current_header or current_body:
                    sections.append({
                        "header": current_header,
                        "body": "\n".join(current_body),
                    })
                current_header = line
                current_body = []
            else:
                current_body.append(line)

        if current_header or current_body:
            sections.append({
                "header": current_header,
                "body": "\n".join(current_body),
            })

        return sections
```

### Step 2: Integrate with agent

```python
# In ralph_sdk/agent.py:
from ralph_sdk.context import ContextManager

# In RalphAgent.__init__():
self._context_manager = ContextManager(
    max_unchecked_items=config.max_context_items,
)

# In _build_iteration_prompt() or equivalent:
if self._fix_plan:
    ctx = self._context_manager.build_progressive_context(self._fix_plan)
    # Use ctx.text instead of self._fix_plan in the prompt
```

### Step 3: Add config field

```python
# In ralph_sdk/config.py:
max_context_items: int = Field(
    default=10, ge=1,
    description="Max unchecked items to include in progressive context"
)
```

## Acceptance Criteria

- [ ] `build_progressive_context()` returns trimmed plan with current section + N unchecked items
- [ ] Completed sections replaced with `(N completed items above)` summary
- [ ] Sections with more items than `max_items` show `(N more items in this section)` marker
- [ ] Next section header shown with pending item count
- [ ] `estimate_tokens()` returns len(text) // 4
- [ ] `max_context_items` configurable via `RalphConfig` (default 10)
- [ ] All-completed plans returned as-is
- [ ] Empty plans handled gracefully

## Test Plan

```python
import pytest
from ralph_sdk.context import ContextManager, ProgressiveContext

SAMPLE_PLAN = """## Epic 1: Authentication
- [x] Add login endpoint
- [x] Add password hashing
- [x] Add JWT token generation

## Epic 2: User Management
- [x] Create user model
- [ ] Add user CRUD endpoints
- [ ] Add role-based access control
- [ ] Add user profile page
- [ ] Add avatar upload

## Epic 3: Dashboard
- [ ] Create dashboard layout
- [ ] Add analytics widgets
- [ ] Add real-time notifications
"""

class TestContextManager:
    def test_progressive_loading_shows_current_section(self):
        cm = ContextManager(max_unchecked_items=10)
        ctx = cm.build_progressive_context(SAMPLE_PLAN)
        assert "Epic 2: User Management" in ctx.text
        assert "Add user CRUD endpoints" in ctx.text
        assert "Add login endpoint" not in ctx.text  # Completed section elided

    def test_completed_section_summarized(self):
        cm = ContextManager(max_unchecked_items=10)
        ctx = cm.build_progressive_context(SAMPLE_PLAN)
        assert "(3 completed items above)" in ctx.text

    def test_item_limit_enforced(self):
        cm = ContextManager(max_unchecked_items=2)
        ctx = cm.build_progressive_context(SAMPLE_PLAN)
        assert "Add user CRUD endpoints" in ctx.text
        assert "Add role-based access control" in ctx.text
        assert "more items in this section" in ctx.text

    def test_next_section_shown(self):
        cm = ContextManager(max_unchecked_items=10)
        ctx = cm.build_progressive_context(SAMPLE_PLAN)
        assert "Epic 3: Dashboard" in ctx.text
        assert "3 items pending" in ctx.text

    def test_all_completed_returns_full_plan(self):
        completed = "## Done\n- [x] Task 1\n- [x] Task 2\n"
        cm = ContextManager(max_unchecked_items=10)
        ctx = cm.build_progressive_context(completed)
        assert ctx.remaining_items == 0

    def test_estimate_tokens(self):
        assert ContextManager.estimate_tokens("a" * 400) == 100

    def test_item_counts(self):
        cm = ContextManager(max_unchecked_items=10)
        ctx = cm.build_progressive_context(SAMPLE_PLAN)
        assert ctx.total_items == 11
        assert ctx.completed_items == 4
        assert ctx.remaining_items == 7
```

## References

- CLI `lib/context_management.sh`: Progressive context trimming
- [ralph-sdk-upgrade-evaluation.md](../../../TheStudio/docs/ralph-sdk-upgrade-evaluation.md) §1.2
