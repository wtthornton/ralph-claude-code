# Story OBSERVE-3: State Backup and Rollback

**Epic:** [RALPH-OBSERVE](epic-observability.md)
**Priority:** Low
**Status:** Open
**Effort:** Small
**Component:** `ralph_loop.sh`, new `lib/backup.sh`, `.ralph/backups/`

---

## Problem

When a Ralph loop fails mid-task or produces unexpected results, recovery is manual:
- fix_plan.md may have been partially updated
- Session state may be inconsistent
- Circuit breaker state may need manual reset
- No way to "undo" to the state before the loop started

## Solution

Create automatic snapshots of `.ralph/` state before each loop run. Provide `ralph --rollback` to restore the previous snapshot. Scope is strictly **local .ralph/ state** — production-level code rollback is git's job, and TheStudio provides tier-based governance.

## Implementation

1. Create `lib/backup.sh`:
   ```bash
   create_backup() {
     local backup_dir=".ralph/backups/$(date +%Y%m%d-%H%M%S)"
     mkdir -p "$backup_dir"
     # Snapshot key state files
     cp -f .ralph/fix_plan.md "$backup_dir/" 2>/dev/null
     cp -f .ralph/PROMPT.md "$backup_dir/" 2>/dev/null
     cp -f .ralph/status.json "$backup_dir/" 2>/dev/null
     cp -f .ralph/.circuit_breaker_state "$backup_dir/" 2>/dev/null
     cp -f .ralph/.claude_session_id "$backup_dir/" 2>/dev/null
     cp -f .ralph/.call_count "$backup_dir/" 2>/dev/null
     echo "$backup_dir"
   }

   rollback_to_latest() {
     local latest=$(ls -td .ralph/backups/*/ 2>/dev/null | head -1)
     if [ -z "$latest" ]; then
       echo "No backups found"
       return 1
     fi
     echo "Rolling back to: $latest"
     cp -f "$latest"/* .ralph/ 2>/dev/null
   }

   cleanup_old_backups() {
     local max_backups="${RALPH_MAX_BACKUPS:-10}"
     ls -td .ralph/backups/*/ 2>/dev/null | tail -n +$((max_backups + 1)) | xargs rm -rf
   }
   ```

2. Call `create_backup` at the start of each `ralph` run (before first loop iteration)

3. Add `ralph --rollback` command:
   - Shows diff between current state and latest backup
   - Prompts for confirmation
   - Restores state files from backup

4. Add `ralph --rollback --list` to show available backups with timestamps

5. Configuration:
   ```bash
   RALPH_BACKUP_ENABLED="true"    # Create backups before each run
   RALPH_MAX_BACKUPS=10           # Keep last N backups
   ```

### Key Design Decisions

1. **State files only, not code:** Ralph doesn't backup git-tracked files. `git stash` / `git reset` handle code rollback. Ralph backups are for `.ralph/` operational state.
2. **Max 10 backups:** Prevents unbounded disk usage. Oldest backups pruned automatically.
3. **No backup of logs or metrics:** These are append-only and don't need rollback. Only mutable state files are backed up.

## Testing

```bash
@test "backup created before loop starts" {
  run ralph --project "$TEST_PROJECT" --dry-run
  [ -d ".ralph/backups" ]
  backup_count=$(ls -d .ralph/backups/*/ 2>/dev/null | wc -l)
  [ "$backup_count" -ge 1 ]
}

@test "rollback restores previous state" {
  echo "- [ ] original task" > .ralph/fix_plan.md
  create_backup
  echo "- [x] modified task" > .ralph/fix_plan.md
  rollback_to_latest
  grep -q "original task" .ralph/fix_plan.md
}

@test "old backups are cleaned up" {
  for i in $(seq 1 15); do
    mkdir -p ".ralph/backups/backup-$i"
  done
  RALPH_MAX_BACKUPS=10 cleanup_old_backups
  backup_count=$(ls -d .ralph/backups/*/ | wc -l)
  [ "$backup_count" -eq 10 ]
}
```

## Acceptance Criteria

- [ ] Backup created automatically before each `ralph` run
- [ ] Backup contains: fix_plan.md, PROMPT.md, status.json, circuit breaker state, session ID
- [ ] `ralph --rollback` restores latest backup with confirmation prompt
- [ ] `ralph --rollback --list` shows available backups with timestamps
- [ ] Old backups pruned to `RALPH_MAX_BACKUPS` (default 10)
- [ ] Backup disabled via `RALPH_BACKUP_ENABLED=false`
- [ ] `.ralph/backups/` added to `.gitignore` template
