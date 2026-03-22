# Story CONFIG-2: Update Installation for SDK Support

**Epic:** [RALPH-CONFIG](epic-config-infrastructure.md)
**Priority:** Medium
**Status:** Open
**Effort:** Small
**Component:** `install.sh`, `ralph-enable`

---

## Problem

Ralph's installation script (`install.sh`) only sets up bash CLI dependencies. With SDK mode (RALPH-SDK epic), installation must also handle:
- Python 3.12+ verification
- Claude Agent SDK package installation
- SDK entry point registration
- Virtual environment management

## Solution

Extend the installation script to detect and install SDK dependencies when the user opts into SDK mode. SDK installation is optional — CLI-only users are unaffected.

## Implementation

1. Add SDK detection to `install.sh`:
   ```bash
   install_sdk() {
     # Check Python version
     python_version=$(python3 --version 2>/dev/null | grep -oP '\d+\.\d+')
     if [[ $(echo "$python_version < 3.12" | bc -l) -eq 1 ]]; then
       echo "ERROR: Python 3.12+ required for SDK mode (found $python_version)"
       return 1
     fi

     # Create venv and install dependencies
     python3 -m venv .ralph/.venv
     .ralph/.venv/bin/pip install claude-agent-sdk ralph-sdk
   }
   ```

2. Update `ralph-enable` wizard:
   - Add prompt: "Enable SDK mode? (requires Python 3.12+) [y/N]"
   - When yes: run `install_sdk()`, add `RALPH_SDK_ENABLED=true` to config
   - When no: skip SDK setup (default)

3. Update `ralph-enable-ci`:
   - Add `--sdk` flag for non-interactive SDK setup
   - Exit with clear error if Python requirements not met

4. Add `ralph doctor` command to verify all dependencies:
   - Checks bash, jq, Claude Code CLI (required)
   - Checks Python, Agent SDK, venv (optional, for SDK mode)
   - Reports status of each dependency

### Key Design Decisions

1. **SDK is opt-in:** Default installation remains CLI-only. No new dependencies forced on existing users.
2. **Virtual environment:** SDK dependencies live in `.ralph/.venv` to avoid polluting the system Python. This directory is already in `.gitignore`.
3. **Doctor command:** A single diagnostic command reduces support burden for installation issues.

## Testing

```bash
@test "install.sh works without SDK flag" {
  run ./install.sh
  [ "$status" -eq 0 ]
  [ ! -d ".ralph/.venv" ]
}

@test "install.sh --sdk creates venv" {
  run ./install.sh --sdk
  [ "$status" -eq 0 ]
  [ -d ".ralph/.venv" ]
}

@test "install.sh --sdk fails gracefully without Python 3.12+" {
  # Mock old Python
  export PATH="$MOCK_OLD_PYTHON:$PATH"
  run ./install.sh --sdk
  [ "$status" -ne 0 ]
  [[ "$output" == *"Python 3.12+ required"* ]]
}

@test "ralph doctor reports SDK status" {
  run ralph doctor
  [[ "$output" == *"Claude Code CLI"* ]]
  [[ "$output" == *"Python"* ]]
  [[ "$output" == *"Agent SDK"* ]]
}
```

## Acceptance Criteria

- [ ] `install.sh` works unchanged for CLI-only users
- [ ] `install.sh --sdk` installs Python SDK dependencies in `.ralph/.venv`
- [ ] Installation fails clearly when Python 3.12+ is not available
- [ ] `ralph-enable` wizard offers SDK mode toggle
- [ ] `ralph-enable-ci --sdk` enables non-interactive SDK setup
- [ ] `ralph doctor` reports status of all dependencies (CLI and SDK)
- [ ] `.ralph/.venv` is in `.gitignore` template
