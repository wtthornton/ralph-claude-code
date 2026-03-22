# Agent Build Instructions

## Project Setup
```bash
# Install dependencies (example for Node.js project)
npm install

# Or for Python project
pip install -r requirements.txt

# Or for Rust project  
cargo build
```

## Running Tests

> **EPIC-BOUNDARY ONLY:** Do NOT run tests mid-epic. Only run at epic boundaries
> (last `- [ ]` in a `##` section of fix_plan.md) or before EXIT_SIGNAL: true.
> Mid-epic: set `TESTS_STATUS: DEFERRED` and move on.

```bash
# Node.js
npm test

# Python
pytest

# Rust
cargo test
```

## Build Commands
```bash
# Production build
npm run build
# or
cargo build --release
```

## Deploy (for QA)

```bash
# Rebuild and restart containers (if Docker project):
docker compose up --build -d

# Wait for health:
docker compose ps

# Check logs:
docker compose logs --tail=20
```

## Development Server
```bash
# Start development server
npm run dev
# or
cargo run
```

## Key Learnings
- Update this section when you learn new build optimizations
- Document any gotchas or special setup requirements
- Keep track of the fastest test/build cycle

## Quality Standards

### Testing Requirements
- Tests must validate behavior, not just achieve coverage metrics
- Only write tests for NEW functionality you implement
- Do NOT refactor existing tests unless broken
- Do NOT add "additional test coverage" as busy work

### Git Workflow
- Use conventional commits: `feat:`, `fix:`, `docs:`, `test:`, `refactor:`
- Commit with descriptive messages after each task
- Mark items complete in .ralph/fix_plan.md upon completion

### Feature Completion Checklist (EPIC BOUNDARY ONLY)

This checklist applies ONLY at epic boundaries (last task in a `##` section of fix_plan.md)
or before EXIT_SIGNAL: true. Mid-epic tasks just need implementation + commit.

**Mid-epic task:**
- [ ] Implementation matches the acceptance criteria in fix_plan.md
- [ ] Changes committed with descriptive message
- [ ] fix_plan.md updated: `- [ ]` → `- [x]`

**Epic boundary (last task in section):**
- [ ] All above, plus:
- [ ] All tests pass with appropriate framework command
- [ ] Code formatted according to project standards
- [ ] Type checking passes (if applicable)
- [ ] .ralph/AGENT.md updated (if new patterns introduced)
