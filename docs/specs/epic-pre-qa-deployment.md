# Epic: Pre-QA Environment Verification

**Epic ID:** RALPH-DEPLOY
**Priority:** High
**Status:** Done
**Affects:** QA accuracy, test reliability, deployment correctness
**Components:** `.claude/agents/ralph-tester.md`, `ralph_loop.sh` (QA phase), PROMPT.md templates
**Related specs:** [epic-adaptive-timeout.md](epic-adaptive-timeout.md), [epic-loop-guard-rails.md](epic-loop-guard-rails.md)
**Depends on:** None
**Target Version:** v1.9.0

---

## Problem Statement

Ralph runs integration and e2e tests without verifying that the test environment reflects the current code. In containerized projects (Docker, Docker Compose), code changes may require a container rebuild/restart before tests can validate them.

### Evidence (from TheStudio, 2026-03-22)

- Docker Desktop shows all containers "Last started: 1 day ago"
- Ralph completed 28 implementation tasks in Epic 37 (all `[x]`)
- QA phase spawned 4 agents to run ruff, mypy, and pytest
- pytest would have tested against **stale containers** — 1-day-old code, not the changes just made
- Even if the 30-minute timeout hadn't killed the tests, the results would have been meaningless

### Root Cause

Ralph's QA workflow has no concept of "deploy changes before testing." The PROMPT.md, ralph.md agent, and ralph-tester.md agent contain no instructions to:
1. Detect if the project uses Docker/Docker Compose
2. Check if containers are running current code
3. Rebuild/restart containers before integration tests
4. Distinguish between unit tests (no deploy needed) and integration/e2e tests (deploy needed)

### Impact

- **False confidence**: Tests pass against old code, giving the impression that changes are safe
- **Wasted time**: Running 30+ minutes of tests that can't validate the actual changes
- **Missed regressions**: Integration bugs won't be caught until manual testing or production

## Research-Informed Adjustments

### CI/CD Pipeline Best Practices (2025)

All major CI/CD systems enforce a **build → deploy → test** pipeline:

- **GitHub Actions**: Separate `build`, `deploy`, `test` jobs with explicit dependencies
- **GitLab CI**: `stages: [build, deploy, test]` — test stage waits for deploy
- **Docker Compose Watch**: `docker compose up --build --wait` rebuilds and waits for health checks
- **Kubernetes**: `kubectl rollout status` waits for deployment to complete before proceeding

### Container Freshness Detection

```bash
# Check if containers are running code from current commit
CONTAINER_START=$(docker inspect --format='{{.State.StartedAt}}' container_name)
LAST_CODE_CHANGE=$(git log -1 --format=%cI -- src/)

if [[ "$LAST_CODE_CHANGE" > "$CONTAINER_START" ]]; then
    echo "Container is stale — code changed after container started"
fi
```

### Selective Rebuild Strategies

| Test Type | Rebuild Needed? | Rationale |
|-----------|----------------|-----------|
| Unit tests | No | Test code directly, no runtime dependency |
| Lint / type check | No | Static analysis of source files |
| Integration tests | Yes | Test against running services |
| E2e tests | Yes | Test full stack through UI/API |
| Contract tests | Maybe | Depends on whether mocking or hitting real services |

## Stories

| Story | Title | Priority | Effort | Status |
|-------|-------|----------|--------|--------|
| [DEPLOY-1](story-deploy-1-container-freshness-check.md) | Container Freshness Check Before Integration Tests | High | Small | Pending |
| [DEPLOY-2](story-deploy-2-agent-build-instructions.md) | Add Build/Deploy Instructions to QA Agent Prompts | Medium | Small | Pending |

## Implementation Order

1. **DEPLOY-1** (High) — Detect stale containers and warn/rebuild before running integration tests.
2. **DEPLOY-2** (Medium) — Update agent prompts so QA agents know how to rebuild when needed.

## Acceptance Criteria (Epic-level)

- [ ] Ralph detects when Docker containers are older than the latest code change
- [ ] Integration/e2e tests are skipped or preceded by a rebuild when containers are stale
- [ ] Unit tests and lint/type checks run without requiring a deploy
- [ ] QA agents have instructions for rebuilding containerized environments
- [ ] `.ralphrc` supports configuring the deploy command (e.g., `docker compose up --build -d`)

## Out of Scope

- Kubernetes deployment management
- Cloud deployment pipelines (CI/CD)
- Container health check implementation (that's the project's responsibility)
- Automatic Docker Compose file detection across arbitrary project structures
