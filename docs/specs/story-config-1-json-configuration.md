# Story CONFIG-1: JSON Configuration File Support

**Epic:** [RALPH-CONFIG](epic-config-infrastructure.md)
**Priority:** Medium
**Status:** Open
**Effort:** Medium
**Component:** `ralph_loop.sh`, `lib/config.sh`, new `ralph.config.json` schema

---

## Problem

Ralph's `.ralphrc` is a bash-sourced file. This works well for CLI mode but creates friction for:
- SDK consumers (Python) that need to read Ralph configuration
- TheStudio integration where config must be machine-readable
- CI/CD pipelines that generate config programmatically
- Users who prefer JSON over bash variable syntax

## Solution

Add `ralph.config.json` as an alternative configuration format. JSON config takes precedence over `.ralphrc` when both exist. The bash CLI reads JSON via `jq`, the SDK reads it natively.

## Implementation

1. Define JSON schema for `ralph.config.json`:
```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "type": "object",
  "properties": {
    "max_calls_per_hour": { "type": "integer", "default": 100 },
    "session_expiry_hours": { "type": "integer", "default": 24 },
    "circuit_breaker": {
      "type": "object",
      "properties": {
        "cooldown_minutes": { "type": "integer", "default": 30 },
        "max_no_progress_loops": { "type": "integer", "default": 3 },
        "auto_reset": { "type": "boolean", "default": true }
      }
    },
    "log_rotation": {
      "type": "object",
      "properties": {
        "max_size_mb": { "type": "integer", "default": 10 },
        "max_files": { "type": "integer", "default": 5 }
      }
    },
    "allowed_tools": { "type": "array", "items": { "type": "string" } },
    "sandbox": {
      "type": "object",
      "properties": {
        "enabled": { "type": "boolean", "default": false },
        "provider": { "type": "string", "enum": ["docker"], "default": "docker" },
        "resource_limits": { "type": "object" }
      }
    },
    "teams": {
      "type": "object",
      "properties": {
        "enabled": { "type": "boolean", "default": false },
        "max_teammates": { "type": "integer", "default": 3 }
      }
    }
  }
}
```

2. Add `load_json_config()` to `lib/config.sh`:
   - Check for `ralph.config.json` in project root
   - Parse with `jq` and export as environment variables
   - JSON values override `.ralphrc` values when both exist

3. Update `ralph-enable` wizard to offer JSON config generation option

4. Add `ralph config --format json` to export current `.ralphrc` as JSON

### Key Design Decisions

1. **JSON over YAML/TOML:** JSON is natively readable by Python SDK, parseable by `jq` in bash, and requires no additional dependencies.
2. **Precedence: JSON > .ralphrc > defaults:** Explicit ordering prevents config confusion.
3. **Schema-first:** The JSON schema enables validation and IDE autocompletion.

## Testing

```bash
@test "JSON config is loaded when present" {
  echo '{"max_calls_per_hour": 50}' > "$TEST_PROJECT/ralph.config.json"
  source lib/config.sh
  load_json_config "$TEST_PROJECT"
  [ "$MAX_CALLS_PER_HOUR" -eq 50 ]
}

@test "JSON config overrides .ralphrc" {
  echo 'MAX_CALLS_PER_HOUR=100' > "$TEST_PROJECT/.ralphrc"
  echo '{"max_calls_per_hour": 50}' > "$TEST_PROJECT/ralph.config.json"
  source lib/config.sh
  load_config "$TEST_PROJECT"
  [ "$MAX_CALLS_PER_HOUR" -eq 50 ]
}

@test "Invalid JSON config produces error" {
  echo '{invalid}' > "$TEST_PROJECT/ralph.config.json"
  run load_json_config "$TEST_PROJECT"
  [ "$status" -ne 0 ]
}

@test "ralph config --format json exports current config" {
  echo 'MAX_CALLS_PER_HOUR=75' > "$TEST_PROJECT/.ralphrc"
  run ralph config --format json --project "$TEST_PROJECT"
  echo "$output" | jq -e '.max_calls_per_hour == 75'
}
```

## Acceptance Criteria

- [ ] `ralph.config.json` is recognized and loaded by ralph_loop.sh
- [ ] JSON values override `.ralphrc` when both exist
- [ ] Invalid JSON produces a clear error message and exits
- [ ] `ralph-enable` wizard offers JSON config generation
- [ ] `ralph config --format json` exports current config as valid JSON
- [ ] JSON schema file included for IDE validation support
- [ ] SDK runner reads `ralph.config.json` natively (no jq dependency)
