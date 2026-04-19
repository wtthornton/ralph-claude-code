# Example: "Add retry logic to the Linear API calls"

## Loop snapshot

- Task (from `fix_plan.md`): `- [ ] Add retry with backoff to lib/linear_backend.sh API calls`
- WORK_TYPE expected: IMPLEMENTATION
- Complexity (via `lib/complexity.sh`): MEDIUM

## Without search-first (anti-pattern)

Loop jumps to writing a `linear_retry()` helper in `lib/linear_backend.sh`
that re-implements exponential backoff and jitter. ~80 lines of shell.
Two loops later, the reviewer flags that this duplicates logic Ralph's
SDK already carries in `sdk/ralph_sdk/cost.py::TokenRateLimiter`.

## With search-first

1. **Repo scan** (~20s):
   `Grep("retry|backoff", path="lib/")` → no hits in shell libs.
   `Grep("retry|backoff", path="sdk/ralph_sdk/")` → `TokenRateLimiter` +
   the circuit-breaker cooldown in `circuit_breaker.py`.
2. **Installed deps**: `linear_backend.sh` is pure bash + `curl`. Nothing
   installed that retries HTTP.
3. **Decision**: the SDK has Python retry logic, but `lib/linear_backend.sh`
   is shell. No cross-language reuse possible.
4. **Resolution**: write a small `_linear_retry()` helper in the same file,
   but keep it simple (3 retries, exponential base=2, max=15s). Cite the
   SDK pattern in the commit message so the next iteration knows these
   two paths share a philosophy, even if not code.

## Why this matters for the loop

search-first turned a 15-minute iteration into a 5-minute one and
produced a simpler helper than the "I'll be thorough" version would
have. Ralph's throughput depends on small, informed commits — research
that leads to **no custom code** is the best possible outcome, and even
when it leads to custom code, it keeps that code minimal.
