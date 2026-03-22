# Story DEPLOY-2: Add Build/Deploy Instructions to QA Agent Prompts

**Epic:** [Pre-QA Environment Verification](epic-pre-qa-deployment.md)
**Priority:** Medium
**Status:** Pending
**Effort:** Small
**Component:** `.claude/agents/ralph-tester.md`, `templates/PROMPT.md`, `templates/AGENT.md`

---

## Problem

The ralph-tester agent has no awareness of containerized environments. When spawned for QA at an epic boundary, it immediately runs `pytest` (including integration/e2e tests) without checking whether containers are running or current. The AGENT.md file (project build/run instructions) may contain Docker commands, but the tester agent doesn't read or act on them before testing.

**Evidence:** TheStudio 2026-03-22 — QA agents ran ruff/mypy/pytest without rebuilding 1-day-old containers.

## Solution

Update the ralph-tester agent prompt and PROMPT.md templates to include deployment awareness:
1. Tester agent reads AGENT.md for build/deploy commands
2. Before integration tests, checks if containers need rebuild
3. Distinguishes test types that need deployment vs. those that don't

## Implementation

### Step 1: Update ralph-tester.md agent definition

Add a "Pre-Test Environment Check" section:

```markdown
## Pre-Test Environment Check

Before running integration or e2e tests, verify the test environment:

1. **Read AGENT.md** for build/deploy/run commands
2. **Check for Docker Compose**: If `docker-compose.yml` or `compose.yml` exists:
   - Run `docker compose ps` to check container status
   - If containers are not running: attempt `docker compose up -d`
   - If containers are running but stale (check `.ralph/status.json` for last deploy time): rebuild with `docker compose up --build -d`
3. **Test type routing**:
   - **Static analysis** (ruff, mypy): Run immediately — no deploy needed
   - **Unit tests**: Run immediately — no deploy needed
   - **Integration/e2e tests**: Only after deployment verification
   - If deployment fails: Report `DEPLOY_FAILED` and skip integration tests

## Test Execution Order

1. Static analysis (ruff check, mypy) — fast, no dependencies
2. Unit tests (pytest tests/unit/) — fast, no runtime dependencies
3. Deploy verification (if Docker project) — rebuild if stale
4. Integration tests (pytest tests/integration/) — requires running services
5. E2e tests (pytest tests/e2e/) — requires full stack
```

### Step 2: Update PROMPT.md template

Add deployment context section:

```markdown
## Environment

- Use `python3` (not `python`) for Python commands
- If the project uses Docker: check `docker compose ps` before integration tests
- Read AGENT.md for build/deploy/run commands specific to this project
```

### Step 3: Update AGENT.md template

Add a standardized deploy section:

```markdown
## Deploy (for QA)

<!-- Fill in your project's deploy command -->
```bash
# Rebuild and restart containers:
docker compose up --build -d

# Wait for health:
docker compose ps

# Check logs:
docker compose logs --tail=20
```
```

### Step 4: Add AGENT.md to ralph-tester's read list

In the ralph-tester agent definition, add:

```markdown
## Files to Read Before Testing

1. **AGENT.md** — Build, run, and deploy commands for this project
2. **fix_plan.md** — Current task context (what was changed)
3. **pyproject.toml** / **package.json** — Test framework configuration
```

## Design Notes

- **AGENT.md as single source of truth**: Each project's AGENT.md already contains build/run instructions. The tester just needs to read and act on them.
- **Test type routing**: Static analysis and unit tests should always run first (fast, no deploy needed). Integration/e2e tests only after deploy verification.
- **Fail gracefully**: If Docker is not available or deploy fails, the tester should still run unit tests and report that integration tests were skipped.
- **No Ralph core changes needed**: This is purely an agent prompt update — the tester agent gains awareness through instructions, not code.

## Acceptance Criteria

- [ ] ralph-tester reads AGENT.md before running tests
- [ ] Tester checks `docker compose ps` for Docker projects
- [ ] Static analysis and unit tests run first (no deploy dependency)
- [ ] Integration/e2e tests wait for deploy verification
- [ ] Tester reports deploy status in its output
- [ ] AGENT.md template includes a deploy section

## Test Plan

```bash
@test "ralph-tester agent includes pre-test environment check" {
    run grep -c "Pre-Test Environment Check" "$RALPH_DIR/.claude/agents/ralph-tester.md"
    assert [ "$output" -ge 1 ]
}

@test "ralph-tester agent references AGENT.md" {
    run grep -c "AGENT.md" "$RALPH_DIR/.claude/agents/ralph-tester.md"
    assert [ "$output" -ge 1 ]
}

@test "AGENT.md template includes deploy section" {
    run grep -c "Deploy" "$RALPH_DIR/templates/AGENT.md"
    assert [ "$output" -ge 1 ]
}
```

## References

- [Docker Compose CLI — up command](https://docs.docker.com/reference/cli/docker/compose/up/)
- [Docker Compose — Profiles for test environments](https://docs.docker.com/compose/how-tos/profiles/)
- [GitHub Actions — Service containers](https://docs.github.com/en/actions/using-containerized-services/about-service-containers)
