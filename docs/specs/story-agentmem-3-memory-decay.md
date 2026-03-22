# Story AGENTMEM-3: Memory Decay and Relevance Scoring

**Epic:** [Cross-Session Agent Memory](epic-agent-memory.md)
**Priority:** Medium
**Status:** Open
**Effort:** Small
**Component:** `lib/memory.sh`

---

## Problem

Without decay, the episodic memory file grows unbounded and stale entries pollute relevance results. An episode from 2 weeks ago about a since-refactored module wastes context tokens.

## Solution

Apply time-based decay to episode relevance scores. Older episodes receive lower scores and are pruned when they fall below a relevance threshold.

## Implementation

```bash
RALPH_MEMORY_DECAY_DAYS=${RALPH_MEMORY_DECAY_DAYS:-14}
RALPH_MEMORY_DECAY_FACTOR=${RALPH_MEMORY_DECAY_FACTOR:-0.9}  # per day

ralph_decay_score() {
    local base_score="$1" episode_timestamp="$2"
    local now age_days decayed
    now=$(date +%s)
    local ep_epoch
    ep_epoch=$(date -d "$episode_timestamp" +%s 2>/dev/null || echo "$now")
    age_days=$(( (now - ep_epoch) / 86400 ))

    # Exponential decay: score * factor^days
    decayed=$(awk "BEGIN {printf \"%.2f\", $base_score * ($RALPH_MEMORY_DECAY_FACTOR ^ $age_days)}")
    echo "$decayed"
}

ralph_prune_stale_memories() {
    [[ ! -f "$RALPH_EPISODES_FILE" ]] && return 0
    local cutoff_epoch
    cutoff_epoch=$(( $(date +%s) - RALPH_MEMORY_DECAY_DAYS * 86400 ))

    awk -v cutoff="$cutoff_epoch" '
    {
        ts = $0; gsub(/.*"timestamp":"/, "", ts); gsub(/".*/, "", ts)
        cmd = "date -d \"" ts "\" +%s 2>/dev/null"
        cmd | getline epoch; close(cmd)
        if (epoch >= cutoff) print
    }' "$RALPH_EPISODES_FILE" > "${RALPH_EPISODES_FILE}.tmp"
    mv "${RALPH_EPISODES_FILE}.tmp" "$RALPH_EPISODES_FILE"
}
```

## Acceptance Criteria

- [ ] Episode scores decay exponentially with age
- [ ] Episodes older than `RALPH_MEMORY_DECAY_DAYS` are pruned
- [ ] Decay factor configurable via `.ralphrc`
- [ ] Pruning runs at session start (not every loop)

## References

- [Ebbinghaus Forgetting Curve](https://en.wikipedia.org/wiki/Forgetting_curve)
- [Mem0 — Memory Decay](https://github.com/mem0ai/mem0)
