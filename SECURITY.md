---
title: Security policy
description: Supported versions, vulnerability reporting process, Ralph's threat model, and defensive mechanisms.
audience: [operator, security-reviewer]
diataxis: reference
last_reviewed: 2026-04-23
---

<!-- tapps-generated: v3.2.3 -->
# Security policy

Ralph is an autonomous agent that invokes the Claude Code CLI, writes files, runs shell commands, and talks to external services. That makes security posture a first-class concern. This document covers:

- [Supported versions](#supported-versions)
- [Reporting a vulnerability](#reporting-a-vulnerability)
- [Threat model](#threat-model)
- [Defensive mechanisms](#defensive-mechanisms)
- [Automated scanning](#automated-scanning)
- [Security hardening checklist](#security-hardening-checklist)
- [Known tradeoffs](#known-tradeoffs)

## Supported versions

| Version | Supported |
|---|---|
| **2.8.x** (latest) | Yes — full support |
| 2.7.x | Yes — security fixes only |
| 2.6.x | Critical security fixes only |
| ≤ 2.5.x | End of life |

Ralph follows a rolling-support policy: only the last two minor lines receive patches. Upgrade regularly.

## Reporting a vulnerability

**Do not open a public GitHub issue for security vulnerabilities.**

Use GitHub's [private vulnerability reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing/privately-reporting-a-security-vulnerability) on `wtthornton/ralph-claude-code`. Include:

- A description of the vulnerability
- Steps to reproduce (minimal reproducer is ideal)
- Potential impact (data exfiltration, code execution, DoS, etc.)
- Suggested fix if you have one

### Response timeline

| Stage | SLA |
|---|---|
| Acknowledgment | 48 hours |
| Initial assessment (severity, affected versions) | 1 week |
| Fix or mitigation for critical issues | 2 weeks |
| Coordinated disclosure | Negotiated with reporter |

We will credit you in the security advisory unless you request otherwise.

## Threat model

Ralph runs as the operator's user with broad filesystem access. The primary adversaries to consider:

### In-scope threats

| Threat | Mitigation |
|---|---|
| Malicious `fix_plan.md` / `PROMPT.md` content | File-protection hooks, `ALLOWED_TOOLS` whitelist, hook-based sanitization |
| Prompt injection via issue trackers, PRDs, web content | `validate-command.sh` blocks destructive shell commands regardless of source |
| Shell injection via task titles or commit messages | `jq --arg` everywhere; historical issues closed by TAP-622, TAP-633, TAP-641, TAP-643 |
| Ralph loop editing its own control plane | `protect-ralph-files.sh` blocks writes to `.ralph/` and `.claude/` (TAP-623) |
| Credential leakage via logs or tracing | Secret sanitization in `lib/tracing.sh`; `secrets.env` never logged |
| Untrusted code execution from cloned repos | `ralph --sandbox` runs the loop in Docker with `--network none` and gVisor support |
| Concurrent-instance corruption | `flock` on `.ralph/.ralph.lock` |
| API key exfiltration | Keys loaded from `~/.ralph/secrets.env` or env vars; never written to state files |

### Out-of-scope threats

- **Anthropic API compromise.** Ralph trusts API responses. A compromised API would let an attacker run code via tool calls.
- **Local-user privilege escalation.** Ralph runs as the invoking user; it does not attempt privilege separation.
- **Side-channel attacks** on the host (timing, cache). Ralph is not hardened against them.
- **Supply-chain attacks on dependencies.** We run `pip-audit` and Dependabot, but can't guarantee upstream integrity.

### Trust boundaries

```
┌─────────────────────────────────────────────────────────┐
│ Operator (fully trusted)                                │
│ ─ starts Ralph, writes PROMPT.md, approves PRs          │
└──────────────────────┬──────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────┐
│ Ralph loop (partially trusted)                          │
│ ─ reads PROMPT.md, fix_plan.md                          │
│ ─ cannot modify .ralph/ or .claude/ (hook-enforced)     │
│ ─ bound by ALLOWED_TOOLS whitelist                      │
└──────────────────────┬──────────────────────────────────┘
                       │
                       ▼
┌─────────────────────────────────────────────────────────┐
│ Claude Code CLI + Anthropic API (external)              │
│ ─ runs tool calls the loop permits                      │
│ ─ subject to Anthropic's content filtering              │
└─────────────────────────────────────────────────────────┘
```

## Defensive mechanisms

### 1. Deny-by-default tool permissions (`ALLOWED_TOOLS`)

Every tool Claude tries to use must match the `ALLOWED_TOOLS` whitelist in `.ralphrc`. Granular bash patterns are supported:

```bash
ALLOWED_TOOLS="Write,Read,Edit,Bash(git add *),Bash(git commit *),Bash(grep *),Bash(find *),Bash(pytest)"
```

Claude Code enforces this at the tool layer; a denial generates an explicit error Ralph logs and the circuit breaker tracks.

### 2. File-protection hooks

- [`protect-ralph-files.sh`](templates/hooks/protect-ralph-files.sh) blocks `Write`, `Edit`, and `Bash` commands that modify anything under `.ralph/` or `.claude/`. Prevents the loop from editing its own control plane.
- [`validate-command.sh`](templates/hooks/validate-command.sh) blocks destructive git commands (`reset --hard` to unknown refs, `push --force` to `main`, `rm -rf` with path traversal, etc.). TAP-624 closed multiple whitelist bypasses.

### 3. Hook-based response analysis

The `Stop` hook is the single sanitization point for Claude's output. The loop never sees raw output — it reads the structured `status.json` written by the hook. This means any prompt injection that tries to manipulate `RALPH_STATUS` still goes through the hook's parser, which uses `jq --arg` for safe JSON construction.

### 4. Secret handling

- `TAPPS_BRAIN_AUTH_TOKEN` and similar credentials are loaded from `~/.ralph/secrets.env` (gitignored) or environment variables. Linear access is via the Linear MCP plugin's OAuth flow — no harness-side API key.
- Never written to `.ralph/status.json`, metrics files, or traces.
- Webhooks are built with `jq --arg` — sed-based escape was replaced in TAP-659 after an injection finding.

### 5. Sandbox mode

`ralph --sandbox` runs the entire loop inside a Docker container with:

- Rootless Docker detection (preferred) or rootful fallback
- `--network none` by default (override with `RALPH_SANDBOX_NETWORK`)
- gVisor runtime support (`RALPH_SANDBOX_RUNTIME=runsc`)
- Resource limits (CPU, memory, pids)
- Fresh filesystem each invocation

Use this when running Ralph on code you haven't reviewed.

### 6. Concurrent-instance prevention

`flock` on `.ralph/.ralph.lock` ensures only one Ralph process per project. State corruption from parallel loops is a class of bug this eliminates (LOCK-1).

### 7. Atomic state writes

Every counter or state-file write goes through `atomic_write`: temp file → fsync → `mv -f`. A SIGTERM between truncate and write cannot leave a zero-byte counter (TAP-535).

### 8. Kill switch

Touch `.ralph/.killswitch` or send SIGTERM to halt cleanly. See [KILLSWITCH.md](KILLSWITCH.md) for cleanup guarantees.

### 9. History and event capping

Circuit breaker history and event logs are capped to prevent unbounded growth (TAP-658). Long-running sessions can't OOM the host via state-file accumulation.

## Automated scanning

CI runs the following on every push to `main` and every pull request:

| Tool | Scope | Enforcement |
|---|---|---|
| **Bandit** | Python static analysis (SDK) | Blocking |
| **Secret scanning** | API keys, tokens in diffs | Blocking |
| **`pip-audit`** | Python dependency CVEs | Blocking (high/critical) |
| **CodeQL** | Semantic code analysis | Blocking |
| **Dependabot** | Dependency updates with grouped security patches | Auto-PR |
| **`shellcheck`** | Bash lint (ralph_loop.sh + lib/) | Blocking on errors |

Results are attached to the GitHub Security tab.

## Security hardening checklist

For operators running Ralph in a sensitive environment:

- [ ] Keep Ralph on the latest minor version (`ralph-upgrade`)
- [ ] Set `ALLOWED_TOOLS` to the minimum your workflow needs
- [ ] Keep `.ralph/` on an encrypted filesystem if tasks contain sensitive data
- [ ] Store API keys in `~/.ralph/secrets.env`, not `.ralphrc` (which may end up in backups)
- [ ] Run `ralph --sandbox` when working on unreviewed code
- [ ] Set `RALPH_SANDBOX_NETWORK=none` (the default) unless you need egress
- [ ] Review `.ralph/logs/` periodically; rotate or archive sensitive content
- [ ] Enable `CB_AUTO_RESET=false` in production so a tripped breaker requires manual review
- [ ] Pin Claude CLI version in `.ralphrc` (`CLAUDE_CODE_CMD`) to prevent unexpected CLI updates
- [ ] Use branch protection on `main`; require CI + code review
- [ ] Review `FAILSAFE.md` degradation hierarchy and confirm your monitoring catches each level

## Known tradeoffs

Ralph makes deliberate speed-vs-safety tradeoffs. Operators should know them:

| Tradeoff | Why |
|---|---|
| `PostToolUse` hooks **disabled** by default (v1.8.4+) | Per-tool-call overhead; `PreToolUse` catches problems before they land |
| `bypassPermissions` mode for main agent | Throughput win; `ALLOWED_TOOLS` still enforced by Claude Code |
| `effort: medium` (not high) for main agent | Cost win; architect handles LARGE tasks at higher effort |
| MCP grandchildren only killed if **orphaned** | Avoids killing editor MCPs belonging to Cursor / VS Code |
| `tapps-brain` memory writes are **fire-and-forget** | Deterministic brain-client won't block the loop on brain outages |
| Hook failures are **advisory** (don't halt loop) | A broken hook shouldn't stop productive work — the loop uses last-known-good `status.json` |

If any of these are unacceptable for your environment, file an issue describing the use case and we'll discuss tightening the default.

## References

- [FAILURE.md](FAILURE.md) — failure modes and response procedures
- [FAILSAFE.md](FAILSAFE.md) — safe-default behaviors
- [KILLSWITCH.md](KILLSWITCH.md) — emergency stop
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#loop-safety) — defensive mechanisms in architectural context
- [CLAUDE.md](CLAUDE.md) — invariants and historical security fixes
