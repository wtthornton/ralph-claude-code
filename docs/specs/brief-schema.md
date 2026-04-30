# `.ralph/brief.json` schema

The coordinator agent (`.claude/agents/ralph-coordinator.md`, TAP-913)
writes a structured brief at the start of each task. Sub-agents and
`ralph_loop.sh` read it for context. The schema is enforced by
`lib/brief.sh::brief_validate`.

## Example

```json
{
  "schema_version": 1,
  "task_id": "TAP-912",
  "task_source": "linear",
  "task_summary": "Introduce ralph-coordinator agent that fronts brain_recall and writes a structured brief.",
  "risk_level": "MEDIUM",
  "affected_modules": ["lib/brief.sh", "ralph_loop.sh", ".claude/agents/ralph-coordinator.md"],
  "acceptance_criteria": [
    "lib/brief.sh sourceable",
    "brief_validate rejects invalid enum values",
    "brief_write is atomic"
  ],
  "prior_learnings": [
    {
      "source": "brain_recall",
      "tier": "procedural",
      "content": "previous attempt used base-class inheritance; broke 3 callers in sdk/"
    }
  ],
  "qa_required": true,
  "qa_scope": "tests/unit/test_brief_schema.bats",
  "delegate_to": "ralph",
  "coordinator_confidence": 0.9,
  "created_at": "2026-04-29T22:30:00Z"
}
```

## Required fields

| Field | Type | Constraint |
|---|---|---|
| `schema_version` | number | must equal `1` |
| `task_id` | string | non-empty (e.g. `TAP-915`, or a fix_plan section anchor) |
| `task_source` | string | enum: `linear` \| `file` |
| `task_summary` | string | non-empty, one sentence describing the work |
| `risk_level` | string | enum: `LOW` \| `MEDIUM` \| `HIGH` |
| `affected_modules` | array of strings | may be empty |
| `acceptance_criteria` | array of strings | may be empty |
| `qa_required` | boolean | true if test/review must run before close |
| `delegate_to` | string | enum: `ralph` \| `ralph-architect` |
| `coordinator_confidence` | number | in `[0.0, 1.0]` |
| `created_at` | string | ISO-8601 timestamp |

## Optional fields

| Field | Type | Default | Notes |
|---|---|---|---|
| `prior_learnings` | array of objects | `[]` | each entry: `{source, tier, content}` strings |
| `qa_scope` | string | `""` | e.g. a BATS file path or test pattern |

## Atomicity

`brief_write` validates JSON via `jq -c` before any filesystem write, then
hands off to `atomic_write` (tmp + best-effort sync + `mv -f`). A failed
write — invalid JSON, full disk, missing parent dir — leaves the previous
brief untouched.

## Lifecycle

1. **Task start** — `ralph-coordinator` writes a fresh brief.
2. **Task body** — main agent and sub-agents call `brief_read_field` for
   context (e.g. `risk_level`, `affected_modules`).
3. **Task close** — `ralph_loop.sh` calls `brief_clear` so the next loop
   starts with no stale brief.
