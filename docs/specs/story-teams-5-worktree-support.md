# Story RALPH-TEAMS-5: Add Worktree Support and .gitignore Updates

**Epic:** [Agent Teams + Parallelism](epic-agent-teams-parallelism.md)
**Priority:** Important
**Status:** Done
**Effort:** Trivial
**Component:** `.gitignore`

---

## Problem

When agents use `isolation: worktree`, Claude Code creates temporary git worktrees
for isolated file operations. These worktrees should be excluded from version control
and not interfere with Ralph's file tracking.

## Solution

Update `.gitignore` to exclude worktree directories and Claude Code local settings.

## Implementation

### .gitignore additions

```gitignore
# Claude Code worktrees (agent isolation)
.claude/worktrees/

# Claude Code local settings (experimental, not committed)
.claude/settings.local.json

# Claude Code agent memory (project-scoped)
.claude/agent-memory/
.claude/agent-memory-local/
```

### Key Design Decisions

1. **`.claude/worktrees/`** — Worktree directories are temporary and auto-cleaned.
   Should never be committed.

2. **`.claude/settings.local.json`** — Contains experimental flags (like agent teams).
   Each developer should control their own local settings.

3. **`.claude/agent-memory/`** — Project-scoped agent memory. Contains auto-generated
   MEMORY.md files. Should not be committed as content is machine-generated and
   session-specific.

4. **`.claude/agent-memory-local/`** — Local agent memory. Always excluded.

## Testing

```bash
@test ".gitignore excludes Claude Code worktrees" {
  grep -q "\.claude/worktrees/" .gitignore
}

@test ".gitignore excludes local settings" {
  grep -q "settings.local.json" .gitignore
}

@test ".gitignore excludes agent memory" {
  grep -q "agent-memory" .gitignore
}
```

## Acceptance Criteria

- [ ] `.gitignore` excludes `.claude/worktrees/`
- [ ] `.gitignore` excludes `.claude/settings.local.json`
- [ ] `.gitignore` excludes `.claude/agent-memory/` and `.claude/agent-memory-local/`
- [ ] Existing `.gitignore` entries preserved (additions only)
