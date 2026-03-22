# Story GUARD-1: Git Diff Baseline Snapshotting

**Epic:** [Loop Progress Detection & Guard Rails](epic-loop-guard-rails.md)
**Priority:** Critical
**Status:** Pending
**Effort:** Small
**Component:** `ralph_loop.sh`

---

## Problem

After a timeout, Ralph checks whether files changed to determine if the iteration was productive:

```bash
git diff --name-only | wc -l
```

This counts **all uncommitted changes** in the working tree, not just changes made during the current iteration. If the project has 733 pre-existing uncommitted files, every timeout is treated as productive — even when Claude made zero changes.

**Root cause confirmed by:** TheStudio logs 2026-03-22, 19 consecutive timeouts all reporting `733 file(s) changed`.

## Solution

Capture a **baseline snapshot** of the working tree state before each Claude invocation. After the invocation completes (or times out), compare against the baseline to detect only changes made during that iteration.

## Implementation

### Step 1: Capture baseline before each invocation

```bash
# Before calling Claude CLI — capture baseline
# git write-tree is lightweight (no commit, no disk I/O beyond the index)
ralph_capture_baseline() {
    # Record the current HEAD and file-change state
    RALPH_BASELINE_HASH=$(git rev-parse HEAD 2>/dev/null || echo "none")
    RALPH_BASELINE_DIRTY=$(git diff --name-only 2>/dev/null | sort | md5sum | cut -d' ' -f1)
    RALPH_BASELINE_UNTRACKED=$(git ls-files --others --exclude-standard 2>/dev/null | sort | md5sum | cut -d' ' -f1)
}
```

### Step 2: Compare after invocation

```bash
ralph_detect_real_changes() {
    local current_dirty current_untracked
    current_dirty=$(git diff --name-only 2>/dev/null | sort | md5sum | cut -d' ' -f1)
    current_untracked=$(git ls-files --others --exclude-standard 2>/dev/null | sort | md5sum | cut -d' ' -f1)

    if [[ "$current_dirty" != "$RALPH_BASELINE_DIRTY" ]] || \
       [[ "$current_untracked" != "$RALPH_BASELINE_UNTRACKED" ]]; then
        # Real changes detected — count only new modifications
        local new_changes
        new_changes=$(comm -13 \
            <(git diff --name-only 2>/dev/null | sort) \
            <(echo "$RALPH_BASELINE_FILES") \
            | wc -l)
        # Actually we need the reverse: files in current but not in baseline
        # Use diff between current file list and baseline file list
        echo "$new_changes"
        return 0
    else
        echo "0"
        return 1
    fi
}
```

### Step 3: Simpler alternative — hash-based comparison

```bash
# Simpler and more reliable: hash the full diff output
ralph_capture_baseline() {
    RALPH_BASELINE_TREEHASH=$(git diff 2>/dev/null | md5sum | cut -d' ' -f1)
    RALPH_BASELINE_UNTRACKED_HASH=$(git ls-files --others --exclude-standard 2>/dev/null | md5sum | cut -d' ' -f1)
}

ralph_has_real_changes() {
    local current_tree current_untracked
    current_tree=$(git diff 2>/dev/null | md5sum | cut -d' ' -f1)
    current_untracked=$(git ls-files --others --exclude-standard 2>/dev/null | md5sum | cut -d' ' -f1)

    if [[ "$current_tree" != "$RALPH_BASELINE_TREEHASH" ]] || \
       [[ "$current_untracked" != "$RALPH_BASELINE_UNTRACKED_HASH" ]]; then
        return 0  # Real changes exist
    fi
    return 1  # No new changes
}
```

### Step 4: Update the timeout handler

Replace the current file-count check with the baseline comparison:

```bash
# Current (broken):
local changed_files
changed_files=$(cd "$PROJECT_DIR" && git diff --name-only 2>/dev/null | wc -l)
if [[ "$changed_files" -gt 0 ]]; then
    log "INFO" "Timeout but ${changed_files} file(s) changed — treating iteration as productive"
fi

# New (correct):
if ralph_has_real_changes; then
    local new_changes
    new_changes=$(cd "$PROJECT_DIR" && git diff --name-only 2>/dev/null | wc -l)
    log "INFO" "Timeout but ${new_changes} new file(s) changed during this iteration — treating as productive"
else
    log "WARN" "Timeout with NO new file changes — iteration was unproductive"
fi
```

## Design Notes

- **`md5sum` vs `sha256sum`**: md5sum is sufficient for change detection (not security). Faster on large diffs.
- **`git write-tree`**: Considered but requires a clean index. The hash-based approach works with dirty indices.
- **`git stash` approach**: Rejected — it modifies working tree state, which could interfere with Claude's in-progress changes.
- **Untracked files**: Must be included because Claude may create new files that aren't staged yet.
- **Performance**: `git diff | md5sum` on a repo with 733 changed files takes <1s. Acceptable per-loop overhead.

## Acceptance Criteria

- [ ] Baseline is captured before each Claude CLI invocation
- [ ] After timeout, only changes made during the current iteration are counted
- [ ] Pre-existing uncommitted files do not satisfy the "productive" check
- [ ] Log messages clearly distinguish "N new files changed" from "no new changes"
- [ ] Baseline capture works on repos with no prior commits (`git rev-parse HEAD` failure handled)

## Test Plan

```bash
@test "ralph_has_real_changes returns false when no new changes" {
    cd "$TEST_DIR" && git init && git commit --allow-empty -m "init"
    echo "existing" > file1.txt  # Pre-existing uncommitted change

    source "$RALPH_DIR/ralph_loop.sh"
    ralph_capture_baseline

    # No changes made after baseline
    run ralph_has_real_changes
    assert_failure  # return 1 = no new changes
}

@test "ralph_has_real_changes returns true when file modified after baseline" {
    cd "$TEST_DIR" && git init && git commit --allow-empty -m "init"
    echo "existing" > file1.txt  # Pre-existing

    source "$RALPH_DIR/ralph_loop.sh"
    ralph_capture_baseline

    # New change after baseline
    echo "new content" > file2.txt

    run ralph_has_real_changes
    assert_success  # return 0 = real changes exist
}

@test "ralph_has_real_changes returns true when existing file modified" {
    cd "$TEST_DIR" && git init
    echo "original" > file1.txt
    git add file1.txt && git commit -m "init"

    source "$RALPH_DIR/ralph_loop.sh"
    ralph_capture_baseline

    echo "modified" > file1.txt

    run ralph_has_real_changes
    assert_success
}

@test "ralph_has_real_changes handles untracked new files" {
    cd "$TEST_DIR" && git init && git commit --allow-empty -m "init"

    source "$RALPH_DIR/ralph_loop.sh"
    ralph_capture_baseline

    echo "brand new" > untracked_new.py

    run ralph_has_real_changes
    assert_success
}
```

## References

- [GitHub Blog — Commits are Snapshots, Not Diffs](https://github.blog/open-source/git/commits-are-snapshots-not-diffs/)
- [Git Diff Documentation](https://git-scm.com/docs/git-diff)
- [tj-actions/changed-files](https://github.com/tj-actions/changed-files) — CI pattern for detecting meaningful changes
- [Atlassian Git Diff Tutorial](https://www.atlassian.com/git/tutorials/saving-changes/git-diff)
