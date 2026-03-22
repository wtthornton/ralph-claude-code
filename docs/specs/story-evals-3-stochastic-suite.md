# Story EVALS-3: Stochastic Eval Suite with Three-Valued Outcomes

**Epic:** [Agent Evaluation Framework](epic-agent-evals.md)
**Priority:** Medium
**Status:** Open
**Effort:** Medium
**Component:** new `tests/evals/stochastic/`

---

## Problem

Agent output is non-deterministic. A prompt change might produce correct output 80% of the time instead of 95%. Binary pass/fail testing can't detect this degradation — it takes at least 3 runs to establish statistical significance.

## Solution

Create a stochastic eval suite that runs golden-file comparisons multiple times, produces three-valued outcomes (Pass/Fail/Inconclusive), and reports confidence intervals.

## Implementation

### Three-valued outcome scoring

```bash
# Pass: All N runs match expected behavior
# Fail: All N runs deviate from expected behavior
# Inconclusive: Mixed results — needs investigation

RALPH_EVAL_RUNS=${RALPH_EVAL_RUNS:-3}
RALPH_EVAL_PASS_THRESHOLD=${RALPH_EVAL_PASS_THRESHOLD:-0.8}  # 80% pass rate

ralph_eval_stochastic() {
    local golden_file="$1"
    local passes=0 fails=0 total="$RALPH_EVAL_RUNS"

    for i in $(seq 1 "$total"); do
        local result
        result=$(ralph_run_eval "$golden_file")
        case "$result" in
            PASS) passes=$((passes + 1)) ;;
            FAIL) fails=$((fails + 1)) ;;
            *) ;;  # Inconclusive counts as neither
        esac
    done

    local pass_rate
    pass_rate=$(awk "BEGIN {printf \"%.2f\", $passes / $total}")

    if awk "BEGIN {exit !($pass_rate >= $RALPH_EVAL_PASS_THRESHOLD)}"; then
        echo "PASS (${passes}/${total}, rate=${pass_rate})"
    elif awk "BEGIN {exit !($pass_rate <= 0.2)}"; then
        echo "FAIL (${passes}/${total}, rate=${pass_rate})"
    else
        echo "INCONCLUSIVE (${passes}/${total}, rate=${pass_rate})"
    fi
}
```

### Confidence interval calculation

```bash
ralph_eval_confidence_interval() {
    local passes="$1" total="$2"
    # Wilson score interval (better than normal approximation for small N)
    local p z n lower upper
    p=$(awk "BEGIN {printf \"%.4f\", $passes / $total}")
    z=1.96  # 95% confidence
    n=$total

    lower=$(awk "BEGIN {
        p=$p; z=$z; n=$n
        printf \"%.3f\", (p + z*z/(2*n) - z * sqrt((p*(1-p) + z*z/(4*n))/n)) / (1 + z*z/n)
    }")
    upper=$(awk "BEGIN {
        p=$p; z=$z; n=$n
        printf \"%.3f\", (p + z*z/(2*n) + z * sqrt((p*(1-p) + z*z/(4*n))/n)) / (1 + z*z/n)
    }")

    echo "rate=${p} CI=[${lower}, ${upper}] (${passes}/${total})"
}
```

### Nightly CI integration

```yaml
eval-stochastic:
    runs-on: ubuntu-latest
    schedule:
        - cron: '0 3 * * *'  # 3 AM daily
    steps:
        - uses: actions/checkout@v4
        - run: npm install
        - run: npm run test:evals:stochastic
    timeout-minutes: 60
```

## Design Notes

- **3 runs minimum**: Based on AgentAssay research — 3 runs is the minimum for meaningful statistical analysis of non-deterministic systems.
- **Wilson score interval**: More accurate than normal approximation for small sample sizes (N=3-10).
- **Nightly only**: Stochastic evals are expensive (3× LLM calls). Not suitable for pre-merge CI.
- **Inconclusive is a valid outcome**: Better to report uncertainty than force a binary decision on ambiguous results.

## Acceptance Criteria

- [ ] Stochastic eval runner executes N runs per golden file
- [ ] Three-valued outcomes: Pass (>80%), Fail (<20%), Inconclusive (20-80%)
- [ ] Confidence intervals reported using Wilson score
- [ ] Suite runs nightly in CI (not pre-merge)
- [ ] Results stored in JSONL for trend analysis
- [ ] `npm run test:evals:stochastic` runs the suite

## References

- [AgentAssay — Token-Efficient Regression Testing](https://arxiv.org/html/2603.02601)
- [Anthropic — Demystifying Evals](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents)
- [SitePoint — Testing AI Agents Non-Deterministic Behavior](https://www.sitepoint.com/testing-ai-agents-deterministic-evaluation-in-a-non-deterministic-world/)
