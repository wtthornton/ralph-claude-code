# Story OBSERVE-1: Lightweight Metrics and Analytics

**Epic:** [RALPH-OBSERVE](epic-observability.md)
**Priority:** Medium
**Status:** Open
**Effort:** Medium
**Component:** `ralph_loop.sh`, `.ralph/hooks/on-stop.sh`, new `.ralph/metrics/`

---

## Problem

Ralph tracks per-session state (call count, circuit breaker state, status.json) but discards historical data between sessions. Users cannot answer:
- How many loops did my last 10 runs take?
- What's my average token usage per task?
- How often does the circuit breaker trip?
- What's my task completion success rate?

## Solution

Append lightweight metrics to `.ralph/metrics/` after each loop iteration. Provide a `ralph --stats` command to display historical summaries. Keep storage local (JSON files) — TheStudio provides the premium observability stack.

## Implementation

1. Create metrics collection in `on-stop.sh` hook:
   ```bash
   append_metrics() {
     local metrics_file=".ralph/metrics/$(date +%Y-%m).jsonl"
     local entry=$(jq -n \
       --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       --arg session "$SESSION_ID" \
       --argjson loop "$LOOP_COUNT" \
       --arg work_type "$WORK_TYPE" \
       --arg exit_signal "$EXIT_SIGNAL" \
       --argjson calls "$CALL_COUNT" \
       --arg cb_state "$CB_STATE" \
       '{timestamp: $ts, session: $session, loop: $loop, work_type: $work_type, exit_signal: $exit_signal, calls: $calls, circuit_breaker: $cb_state}')
     echo "$entry" >> "$metrics_file"
   }
   ```

2. Monthly JSONL files in `.ralph/metrics/` (e.g., `2026-03.jsonl`)
   - One line per loop iteration
   - Rotated monthly to prevent unbounded growth

3. Add `ralph --stats` command:
   - Reads all `.ralph/metrics/*.jsonl` files
   - Displays: total runs, avg loops/run, success rate, CB trip count, calls/run
   - Supports `--stats --last 7d` for time-windowed summaries

4. Add `ralph --stats --json` for machine-readable output (TheStudio Outcome Ingestor compatibility)

### Key Design Decisions

1. **JSONL over SQLite:** No additional dependencies. JSONL is appendable, greppable, and readable by both bash and Python SDK.
2. **Monthly rotation:** Prevents single files from growing unbounded while keeping reasonable history.
3. **Collected in on-stop.sh:** Metrics piggyback on the existing hook — no new hook events needed.
4. **TheStudio-compatible output:** `--stats --json` output schema aligns with TheStudio's Outcome Ingestor input format, enabling seamless upgrade.

## Testing

```bash
@test "metrics are appended after each loop iteration" {
  run_ralph_loop_once "$TEST_PROJECT"
  [ -f ".ralph/metrics/$(date +%Y-%m).jsonl" ]
  lines=$(wc -l < ".ralph/metrics/$(date +%Y-%m).jsonl")
  [ "$lines" -ge 1 ]
}

@test "ralph --stats displays summary" {
  # Seed metrics file
  echo '{"timestamp":"2026-03-21T10:00:00Z","loop":1,"calls":5,"exit_signal":"false"}' > ".ralph/metrics/2026-03.jsonl"
  echo '{"timestamp":"2026-03-21T10:05:00Z","loop":2,"calls":3,"exit_signal":"true"}' >> ".ralph/metrics/2026-03.jsonl"
  run ralph --stats --project "$TEST_PROJECT"
  [[ "$output" == *"Total runs"* ]]
  [[ "$output" == *"Avg calls/run"* ]]
}

@test "ralph --stats --json produces valid JSON" {
  run ralph --stats --json --project "$TEST_PROJECT"
  echo "$output" | jq -e '.total_runs'
}
```

## Acceptance Criteria

- [ ] Metrics appended to `.ralph/metrics/YYYY-MM.jsonl` on each loop iteration
- [ ] Metrics include: timestamp, session, loop count, work type, exit signal, call count, CB state
- [ ] `ralph --stats` displays human-readable summary
- [ ] `ralph --stats --last 7d` filters by time window
- [ ] `ralph --stats --json` outputs machine-readable JSON
- [ ] JSON output schema compatible with TheStudio Outcome Ingestor
- [ ] Monthly file rotation prevents unbounded growth
- [ ] `.ralph/metrics/` added to `.gitignore` template
