---
title: Testing guide
description: Run, write, debug, and maintain Ralph's BATS + evals test suite.
audience: [contributor, operator]
diataxis: how-to
last_reviewed: 2026-04-23
---

# Testing Ralph

Ralph has 1117+ tests across unit, integration, e2e, and evaluation layers. The quality gate is **100% pass rate**; coverage is informational.

## Contents

- [Quick start](#quick-start)
- [Test layers](#test-layers)
- [Writing tests](#writing-tests)
- [Test helpers](#test-helpers)
- [Evaluations](#evaluations)
- [CI pipeline](#ci-pipeline)
- [Debugging test failures](#debugging-test-failures)
- [Local vs CI differences](#local-vs-ci-differences)

## Quick start

```bash
# Install BATS + bats-assert + bats-support (one time)
npm install

# Run the full suite
npm test

# Narrower slices while iterating
npm run test:unit
npm run test:integration
npm run test:e2e
npm run test:evals:deterministic

# Single file or pattern
bats tests/unit/test_rate_limiting.bats
bats --filter "can_make_call" tests/unit/test_rate_limiting.bats

# Helpful flags
bats --verbose-run tests/unit/test_X.bats   # show each test as it runs
bats --tap tests/unit/test_X.bats           # TAP format for parsers
bats --timing tests/unit/test_X.bats        # per-test duration
```

## Test layers

```
tests/
├── unit/                      # Fast (<1s/file), isolated function tests
│   ├── test_rate_limiting.bats
│   ├── test_exit_detection.bats
│   ├── test_cli_parsing.bats
│   ├── test_json_parsing.bats
│   ├── test_session_continuity.bats
│   ├── test_circuit_breaker.bats
│   ├── test_hooks_on_stop.bats
│   ├── test_linear_backend.bats
│   ├── test_skills_install.bats
│   ├── test_brain_client.bats
│   └── ... (dozens more)
├── integration/               # Component interaction tests, real git + FS
│   ├── test_loop_execution.bats
│   ├── test_edge_cases.bats
│   ├── test_installation.bats
│   ├── test_project_setup.bats
│   ├── test_prd_import.bats
│   └── test_upgrade_project.bats
├── e2e/                       # Mock Claude CLI, full loop scenarios
│   └── (mock_claude.sh + scenarios)
├── evals/
│   ├── deterministic/         # 64 BATS cases pinning loop invariants
│   └── stochastic/            # Golden-file comparisons (live LLM, nightly)
└── helpers/
    ├── test_helper.bash       # Assertions, setup utilities
    ├── mocks.bash             # Mock external commands (claude, tmux, git)
    └── fixtures.bash          # Sample PRD, status, and output generators
```

| Layer | When | Speed | Blocking CI |
|---|---|---|---|
| Unit | During development | <1s/file | **Yes** |
| Integration | Before commit | 1-5s/file | **Yes** (no more `\|\| true` masking — TAP-537) |
| E2E | Before PR | ~10s/file | Yes |
| Deterministic evals | Before PR | <5 min total | **Yes** |
| Stochastic evals | Nightly / manual | Minutes | No — informational |

## Writing tests

### BATS basics

```bash
#!/usr/bin/env bats
# Unit tests for <module>

load '../helpers/test_helper'

setup() {
    export TEST_TEMP_DIR="$(mktemp -d /tmp/ralph-test.XXXXXX)"
    cd "$TEST_TEMP_DIR"
    # Arrange initial state
}

teardown() {
    cd /
    rm -rf "$TEST_TEMP_DIR"
}

@test "descriptive name — one behavior per test" {
    # Arrange
    echo "50" > "$CALL_COUNT_FILE"
    export MAX_CALLS_PER_HOUR=100

    # Act
    run can_make_call

    # Assert
    assert_success
}
```

### Conventions

- **One behavior per `@test`.** `"can_make_call returns success when under limit"` — not `"rate limiting works"`.
- **Isolate.** Each test owns its temp dir.
- **Use helpers.** Don't duplicate setup.
- **Mock external commands** in unit tests. Use real ones sparingly in integration tests.

### Common assertion patterns

```bash
# Exit status
run some_command
assert_success
assert_failure
[[ $status -eq 2 ]]

# Output content
assert_output "exact match"
[[ "$output" == *"substring"* ]]
[[ "$output" =~ ^[0-9]+$ ]]

# Files
assert_file_exists "status.json"
assert_file_not_exists "should_not_exist"
assert_dir_exists "logs/"

# JSON
assert_valid_json "status.json"
local val=$(get_json_field "status.json" ".state")
[[ "$val" == "CLOSED" ]]
```

## Test helpers

### `tests/helpers/test_helper.bash`

Provides assertions and test-env utilities.

```bash
# Assertions
assert_success                     # $status == 0
assert_failure                     # $status != 0
assert_equal "$actual" "$expected"
assert_output "expected"
assert_file_exists "path"
assert_dir_exists "path"
assert_valid_json "path.json"

# Pre-set environment vars (available after setup)
$TEST_TEMP_DIR       # unique temp dir for this test
$PROMPT_FILE         # "PROMPT.md"
$STATUS_FILE         # "status.json"
$CALL_COUNT_FILE     # ".call_count"
$EXIT_SIGNALS_FILE   # ".exit_signals"

# Mock data creation
create_mock_prompt
create_mock_fix_plan 5 2          # total=5, completed=2
create_mock_status 1 42 100       # loop=1, calls=42, max=100
create_mock_exit_signals 0 2 0    # test=0, done=2, complete=0
```

### `tests/helpers/mocks.bash`

Replaces external commands with configurable mocks.

```bash
setup_mocks                # call from setup()
teardown_mocks             # call from teardown()

# Claude CLI mock
MOCK_CLAUDE_SUCCESS=true|false
MOCK_CLAUDE_OUTPUT="..."
MOCK_CLAUDE_EXIT_CODE=0

# git mock
MOCK_GIT_AVAILABLE=true|false
MOCK_GIT_REPO=true|false

# tmux mock
MOCK_TMUX_AVAILABLE=true|false

# Others: mock_notify_send, mock_osascript, mock_stat, mock_timeout
```

### `tests/helpers/fixtures.bash`

Sample data generators for PRDs, status files, and Claude output.

```bash
# PRD fixtures
create_sample_prd_md "out.md"
create_sample_prd_txt "out.txt"
create_sample_prd_json "out.json"

# Project fixtures
create_sample_prompt "PROMPT.md"
create_sample_fix_plan "fix_plan.md" 10 3  # 10 tasks, 3 done
create_test_project "my-project"            # full scaffold

# Output fixtures
create_sample_claude_output_success "out.log"
create_sample_claude_output_error "out.log"
create_sample_claude_output_limit "out.log"
create_sample_status_running "status.json"
create_sample_status_completed "status.json"
```

## Evaluations

Ralph has two eval suites in addition to unit/integration tests.

### Deterministic evals (`tests/evals/deterministic/`)

64 BATS tests that pin loop-correctness invariants:

- Dual-condition exit gate
- Circuit breaker state transitions
- Tool restriction enforcement
- Hook contract (RALPH_STATUS → status.json)
- Linear backend fail-loud behavior (TAP-536)
- Push-mode count handling (TAP-741)
- `EXIT-CLEAN` branch
- `atomic_write` correctness

No LLM calls. Blocking CI. Run with `npm run test:evals:deterministic`.

### Stochastic evals (`tests/evals/stochastic/`)

Golden-file comparisons against a live LLM with three-valued outcomes (Pass / Fail / Inconclusive) and Wilson score confidence intervals. Designed for nightly CI jobs, not PR gating — API calls cost real money and outputs are non-deterministic.

Run with `npm run test:evals:stochastic`. Set `RALPH_EVAL_N` to control sample count (default 10).

## CI pipeline

Defined in [`.github/workflows/test.yml`](.github/workflows/test.yml).

| Step | Blocking | Notes |
|---|---|---|
| `npm run test:unit` | **Yes** | Core invariants |
| `npm run test:integration` | **Yes** | TAP-537 removed `\|\| true` masking |
| `npm run test:evals:deterministic` | **Yes** | 64 loop-correctness cases |
| `kcov` coverage | No (informational) | Subprocess tracing is structurally incomplete in BATS; stderr logged to `coverage/*.stderr.log` and surfaced as `::warning::` |
| `npm run test:evals:stochastic` | No (nightly/manual) | Live LLM calls |

When adding a new CI step, decide category up front. Informational steps must surface failure signal (`::warning::` annotation + artifact), not hide it with `|| true`. Silent masking is what TAP-537 rolled back.

### Triggers

Push to `main`, `develop`. PRs targeting `main`.

### Environment

Ubuntu latest. Node.js 18. `jq` installed via apt.

## Debugging test failures

### Read BATS output carefully

```
not ok 3 - can_make_call returns success when under limit
# (in test file tests/unit/test_rate_limiting.bats, line 58)
#   `assert_success' failed
# Expected success but got status 1
# Output: Error: file not found
```

- **Line 58** — where the assertion failed
- **`assert_success` failed** — exit code was non-zero
- **status 1** — actual exit code
- **Output** — what the command printed

### Debug techniques

```bash
# 1. Narrow to the failing test
bats --filter "can_make_call" tests/unit/test_rate_limiting.bats

# 2. Add debug output (fd 3 writes during BATS runs)
@test "debugging example" {
    echo "Setup state:" >&3
    cat "$CALL_COUNT_FILE" >&3

    run can_make_call

    echo "Status: $status" >&3
    echo "Output: $output" >&3

    assert_success
}

# 3. Trace with set -x
@test "trace example" {
    set -x
    run my_function
    set +x
}

# 4. Keep the temp dir after a failure
teardown() {
    echo "Temp dir: $TEST_TEMP_DIR" >&3
    # Comment out cleanup temporarily:
    # rm -rf "$TEST_TEMP_DIR"
}
```

### Common pitfalls

- **Mock not applied.** Confirm `setup_mocks` ran in `setup()`. `type git` should show `git is a function`.
- **Environment leak.** A previous test's `export` is still set. Always `unset` in `teardown()`.
- **jq not installed.** Install with your system package manager or let the Ralph installer bootstrap it.
- **Read-only temp dir.** Some CI runners restrict `/tmp`; override via `BATS_TEST_TMPDIR`.
- **Hard-coded paths.** Use `"$(dirname "$BATS_TEST_FILENAME")"`, never absolute paths.

## Local vs CI differences

| Aspect | Local | CI |
|---|---|---|
| Environment | your machine | ubuntu-latest container |
| Node | your version | v18 pinned |
| Dependencies | cached | fresh `npm ci` |
| Coverage | opt-in | automatic |
| Artifacts | manual | auto-uploaded |

To match CI exactly:

```bash
nvm use 18
npm ci              # not npm install
npm run test:unit
npm run test:integration
npm run test:evals:deterministic
```

## Coverage

Bash coverage with `kcov` has structural limits — it can't instrument BATS-spawned subprocesses. Reported coverage is always **lower than actual** coverage. The enforced quality gate is **100% test pass rate**, not coverage percentage.

If you want a local report anyway:

```bash
# Ubuntu/Debian
sudo apt install kcov

# Run unit tests with coverage
mkdir -p coverage
kcov --include-path="$(pwd)/ralph_loop.sh,$(pwd)/lib" coverage/ bats tests/unit/

# View
xdg-open coverage/index.html    # Linux
open coverage/index.html        # macOS
```

## Where to ask for help

- Check existing tests in the same area for patterns.
- [BATS documentation](https://bats-core.readthedocs.io/)
- [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md#tests-and-ci) for test-specific problems
- [GitHub Issues](https://github.com/wtthornton/ralph-claude-code/issues) for infrastructure bugs
