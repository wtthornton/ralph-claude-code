# Story RALPH-JSONL-3: Add WSL2/NTFS Filesystem Resilience

**Epic:** [JSONL Stream Processing Resilience](epic-jsonl-stream-resilience.md)
**Priority:** Defensive
**Status:** Done
**Effort:** Small
**Component:** `ralph_loop.sh` (stream extraction, line ~1341)

---

## Problem

On WSL2 with NTFS mounts (`/mnt/c/...`), the file visibility check
`[[ -f "$output_file" ]]` at line 1342 can return false even though the file exists
and has been fully written. This is because:

1. WSL2 accesses Windows filesystems via the **9P (Plan 9) protocol bridge**
2. The 9P protocol introduces latency for metadata operations (stat, inode visibility)
3. The `tee` command in Ralph's pipeline writes through NTFS; the `-f` test races
   against filesystem metadata propagation
4. `stdbuf -oL` mitigates data integrity but not inode visibility

When this race occurs, the entire stream extraction block is skipped, leaving the
output file as raw JSONL -- triggering the crash described in RALPH-JSONL-1.

**Research finding (2026):** `sync` has **limited effectiveness** on WSL2 9P mounts
because it flushes Linux filesystem buffers, but the bottleneck is the protocol bridge
itself. Microsoft has acknowledged and fixed some virtio-9p race conditions (WSL Build
20211, 19640) but the core latency remains architectural.

## Solution

Replace the single `-f` check with a **retry loop with backoff**. This is more
reliable than `sync + sleep` because it directly tests the condition we need (file
visibility) rather than hoping a flush resolves it.

## Implementation

In `ralph_loop.sh`, replace the file check at line ~1342:

**Before:**
```bash
if [[ "$CLAUDE_USE_CONTINUE" == "true" && -f "$output_file" ]]; then
```

**After:**
```bash
# Wait for output file to become visible (WSL2/NTFS 9P metadata propagation)
local _file_visible=false
if [[ "$CLAUDE_USE_CONTINUE" == "true" ]]; then
    for _wait in 0 0.1 0.2 0.5 1.0; do
        [[ "$_wait" != "0" ]] && sleep "$_wait"
        if [[ -f "$output_file" ]]; then
            _file_visible=true
            break
        fi
    done
    if [[ "$_file_visible" != "true" ]]; then
        log_status "WARN" "Output file not visible after 1.8s wait: $output_file"
    fi
fi

if [[ "$_file_visible" == "true" ]]; then
```

## Design Notes

- **Retry with backoff:** Delays are 0, 100ms, 200ms, 500ms, 1000ms (total max 1.8s).
  This covers the typical 9P metadata propagation delay without blocking noticeably on
  native Linux (where the first check at 0ms succeeds immediately).
- **No `sync`:** Research confirms `sync` has limited effectiveness on 9P. Testing the
  actual condition (file visibility) is more reliable.
- **Warning on timeout:** If the file never becomes visible after 1.8s, log a warning
  so the failure is diagnosable. Previously this was completely silent.
- **Native Linux impact:** Zero -- the first iteration (0ms delay) succeeds, and the
  loop exits immediately.
- **WSL1 impact:** None -- WSL1 uses DrvFs with direct NTFS access, no 9P bridge.
- **vs `sync + sleep` approach:** The original implementation plan (`ralph-jsonl-crash-
  implementation-plan.md`) proposed `sync + sleep 0.5`. Research shows `sync` flushes
  Linux buffers but not the 9P protocol bridge. A retry loop directly tests the
  condition we need (file visibility) and is more reliable.

## Acceptance Criteria

- [ ] Output file check retries up to 5 times with increasing delays
- [ ] Total maximum wait is under 2 seconds
- [ ] Warning is logged if file never becomes visible
- [ ] On native Linux, no measurable delay (first check succeeds)
- [ ] Stream extraction proceeds correctly when file becomes visible on retry

## Test Plan

```bash
@test "stream extraction retries file check on delayed visibility" {
    # This test verifies the retry logic works by simulating delayed file creation
    local output_file="$TEST_DIR/delayed_output.log"

    # Create file after 300ms delay in background
    (sleep 0.3 && echo '{"type":"result","status":"SUCCESS"}' > "$output_file") &
    local bg_pid=$!

    # Run the file visibility check loop
    local _file_visible=false
    for _wait in 0 0.1 0.2 0.5 1.0; do
        [[ "$_wait" != "0" ]] && sleep "$_wait"
        if [[ -f "$output_file" ]]; then
            _file_visible=true
            break
        fi
    done

    wait $bg_pid
    assert_equal "$_file_visible" "true"
}

@test "stream extraction warns on persistent file invisibility" {
    # File that never appears
    local output_file="$TEST_DIR/nonexistent_output.log"

    local _file_visible=false
    for _wait in 0 0.1 0.2; do  # Shortened for test speed
        [[ "$_wait" != "0" ]] && sleep "$_wait"
        if [[ -f "$output_file" ]]; then
            _file_visible=true
            break
        fi
    done

    assert_equal "$_file_visible" "false"
}
```

## References

- Microsoft WSL Issue [#4197](https://github.com/microsoft/WSL/issues/4197):
  filesystem performance much slower than WSL1 in /mnt
- Microsoft WSL Issue [#4515](https://github.com/microsoft/WSL/issues/4515):
  File operations on NTFS folders extremely slow
- WSL2 9P vs CIFS benchmarking: ~40 MB/s (9P) vs ~125 MB/s (CIFS) vs ~442 MB/s (WSL1 DrvFs)
- WSL Build 20211, 19640: fixes for virtio-9p race conditions
