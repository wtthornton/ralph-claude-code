# Epic: Configuration & Infrastructure (Phase 7)

**Epic ID:** RALPH-CONFIG
**Priority:** Medium
**Status:** Done
**Affects:** Installation, configuration, developer documentation
**Components:** `ralph_loop.sh`, `install.sh`, `.ralphrc`, new `ralph.config.json`
**Related specs:** `IMPLEMENTATION_PLAN.md` (§Phase 3)
**Target Version:** v1.4.0
**Depends on:** RALPH-SDK (Phase 6) for SDK installation and documentation stories

---

## Problem Statement

Ralph's configuration is currently bash-sourced `.ralphrc` files only. As Ralph gains SDK support and dual-mode operation, the infrastructure needs to mature:

1. **JSON configuration** — Machine-readable config for SDK consumers and TheStudio integration
2. **SDK-aware installation** — Installation scripts that set up both CLI and SDK dependencies
3. **Unified documentation** — CLI and SDK usage documented together so users understand both modes

## Stories

| Story | Title | Priority | Effort | Status |
|-------|-------|----------|--------|--------|
| [CONFIG-1](story-config-1-json-configuration.md) | JSON Configuration File Support | Medium | Medium | **Done** |
| [CONFIG-2](story-config-2-sdk-installation.md) | Update Installation for SDK Support | Medium | Small | **Done** |
| [CONFIG-3](story-config-3-cli-sdk-documentation.md) | Create CLI and SDK Documentation | Medium | Medium | **Done** |

## Implementation Order

1. **CONFIG-1 (Medium)** — JSON config enables SDK consumers to read Ralph settings programmatically
2. **CONFIG-2 (Medium)** — Installation must support SDK dependencies; depends on RALPH-SDK completion
3. **CONFIG-3 (Medium)** — Documentation written last, after SDK and config are stable

## Verification Criteria

- [ ] `ralph.config.json` is read and merged with `.ralphrc` settings (JSON takes precedence)
- [ ] `ralph-enable` wizard offers JSON config option
- [ ] Installation script detects and installs SDK dependencies when SDK mode is selected
- [ ] Documentation covers standalone CLI, SDK standalone, and TheStudio embedded modes
- [ ] Existing `.ralphrc` configurations continue to work unchanged

## Rollback

All changes are additive. `.ralphrc` remains supported. JSON config and SDK installation are opt-in.
