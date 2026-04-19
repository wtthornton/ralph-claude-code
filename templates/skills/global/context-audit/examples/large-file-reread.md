# Example: Avoiding a duplicate read of ralph_loop.sh

## Loop snapshot

- Session iteration: 14 of 20 (Continue-As-New will trigger soon)
- Main agent already Read `ralph_loop.sh` at iteration 3 (~2,300 lines
  = ~60k tokens).
- Current task: `- [ ] Add a --dump-cache-stats flag to ralph_loop.sh`

## Without context-audit

The loop opens `ralph_loop.sh` again with `Read` and no offset. That
re-issues ~60k tokens on top of the already-resident copy from earlier
this session. The cache miss also resets the prefix below that point.
Net loss: ~60k billed tokens, plus a cache-hit-rate dip visible in
the next `.ralph/metrics/*.jsonl` line.

## With context-audit

Step 1 — check: is `ralph_loop.sh` still in context? Yes (iteration 3),
and no Edit touched it since. Trust the earlier Read.

Step 2 — Grep for the insertion point:
```
Grep("--help", path="ralph_loop.sh", output_mode="content", -n=true, -B=1, -A=2)
```
Returns 4 lines around the existing `--help` flag parsing. ~150 tokens.

Step 3 — use `Read` with offset/limit to see only the neighboring 30
lines of the argument-parsing block, not the whole file.

Step 4 — Edit.

## Outcome

Total tokens consumed to make the change: ~800 (Grep output + ~30 lines
Read + Edit echo). Savings vs. the anti-pattern: ~59k tokens and a
cache hit preserved. Crucially, Continue-As-New now has room to reach
iteration 20 instead of tripping on context pressure at iteration 16.
