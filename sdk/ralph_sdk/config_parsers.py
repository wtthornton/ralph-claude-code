"""Config source parsers for :class:`ralph_sdk.config.RalphConfig`.

Three pure functions, one per layer of the precedence chain, each returning a
``dict`` of validated-attr-name → value overrides:

- :func:`parse_ralphrc` — bash ``.ralphrc`` (``KEY=value`` lines).
- :func:`parse_json_config` — ``ralph.config.json`` (camelCase keys).
- :func:`parse_env` — process environment variables (highest precedence).

The original ``RalphConfig._parse_*`` staticmethods delegate here so the public
loading API is unchanged.
"""

from __future__ import annotations

import json
import os
import re
from pathlib import Path
from typing import Any


def parse_ralphrc(path: Path) -> dict[str, Any]:
    """Parse .ralphrc bash config file into config overrides."""
    mapping = {
        "PROJECT_NAME": ("project_name", str),
        "PROJECT_TYPE": ("project_type", str),
        "MAX_CALLS_PER_HOUR": ("max_calls_per_hour", int),
        "CLAUDE_TIMEOUT_MINUTES": ("timeout_minutes", int),
        "CLAUDE_OUTPUT_FORMAT": ("output_format", str),
        "ALLOWED_TOOLS": ("allowed_tools", lambda v: v.split(",")),
        "SESSION_CONTINUITY": ("session_continuity", lambda v: v.lower() == "true"),
        "SESSION_EXPIRY_HOURS": ("session_expiry_hours", int),
        "CB_NO_PROGRESS_THRESHOLD": ("cb_no_progress_threshold", int),
        "CB_SAME_ERROR_THRESHOLD": ("cb_same_error_threshold", int),
        "CB_OUTPUT_DECLINE_THRESHOLD": ("cb_output_decline_threshold", int),
        "CB_COOLDOWN_MINUTES": ("cb_cooldown_minutes", int),
        "CB_AUTO_RESET": ("cb_auto_reset", lambda v: v.lower() == "true"),
        "LOG_MAX_SIZE_MB": ("log_max_size_mb", int),
        "LOG_MAX_FILES": ("log_max_files", int),
        "LOG_MAX_OUTPUT_FILES": ("log_max_output_files", int),
        "DRY_RUN": ("dry_run", lambda v: v.lower() == "true"),
        "CLAUDE_CODE_CMD": ("claude_code_cmd", str),
        "CLAUDE_AUTO_UPDATE": ("claude_auto_update", lambda v: v.lower() == "true"),
        "RALPH_VERBOSE": ("verbose", lambda v: v.lower() == "true"),
        "RALPH_AGENT_NAME": ("agent_name", str),
        "RALPH_ENABLE_TEAMS": ("enable_teams", lambda v: v.lower() == "true"),
        "RALPH_MAX_TEAMMATES": ("max_teammates", int),
        "RALPH_BG_TESTING": ("bg_testing", lambda v: v.lower() == "true"),
        "RALPH_TEAMMATE_MODE": ("teammate_mode", str),
        "CB_MAX_CONSECUTIVE_FAST_FAILURES": ("cb_max_consecutive_fast_failures", int),
        "CB_FAST_FAILURE_THRESHOLD_SECONDS": ("cb_fast_failure_threshold_seconds", float),
        "CB_MAX_DEFERRED_TESTS": ("cb_max_deferred_tests", int),
        "CB_DEFERRED_TESTS_WARN_AT": ("cb_deferred_tests_warn_at", int),
        "CB_MAX_CONSECUTIVE_TIMEOUTS": ("cb_max_consecutive_timeouts", int),
        "DECOMPOSITION_FILE_COUNT_THRESHOLD": ("decomposition_file_count_threshold", int),
        "DECOMPOSITION_COMPLEXITY_THRESHOLD": ("decomposition_complexity_threshold", int),
        "DECOMPOSITION_NO_PROGRESS_THRESHOLD": ("decomposition_no_progress_threshold", int),
        "CANCEL_GRACE_SECONDS": ("cancel_grace_seconds", float),
        "ADAPTIVE_TIMEOUT_ENABLED": ("adaptive_timeout_enabled", lambda v: v.lower() == "true"),
        "ADAPTIVE_TIMEOUT_MIN_SAMPLES": ("adaptive_timeout_min_samples", int),
        "ADAPTIVE_TIMEOUT_MULTIPLIER": ("adaptive_timeout_multiplier", float),
        "ADAPTIVE_TIMEOUT_MIN_MINUTES": ("adaptive_timeout_min_minutes", int),
        "ADAPTIVE_TIMEOUT_MAX_MINUTES": ("adaptive_timeout_max_minutes", int),
        "MAX_SESSION_ITERATIONS": ("max_session_iterations", int),
        "MAX_SESSION_AGE_MINUTES": ("max_session_age_minutes", int),
        "CONTINUE_AS_NEW_ENABLED": ("continue_as_new_enabled", lambda v: v.lower() == "true"),
        "MAX_BUDGET_USD": ("max_budget_usd", float),
        "BUDGET_WARNING_PCT": ("budget_warning_pct", float),
        "BUDGET_CRITICAL_PCT": ("budget_critical_pct", float),
        "MODEL_ROUTING_ENABLED": ("model_routing_enabled", lambda v: v.lower() == "true"),
        "RALPH_MODEL_ROUTING_ENABLED": ("model_routing_enabled", lambda v: v.lower() == "true"),
        "MODEL_MAP_TRIVIAL": ("model_map_trivial", str),
        "MODEL_MAP_SMALL": ("model_map_small", str),
        "MODEL_MAP_MEDIUM": ("model_map_medium", str),
        "MODEL_MAP_LARGE": ("model_map_large", str),
        "MODEL_MAP_ARCHITECTURAL": ("model_map_architectural", str),
        "MAX_TOKENS_PER_HOUR": ("max_tokens_per_hour", int),
    }

    overrides: dict[str, Any] = {}
    content = path.read_text(encoding="utf-8")
    for line in content.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        match = re.match(r'^(?:export\s+)?([A-Z_]+)=(.*)$', line)
        if not match:
            continue
        key, value = match.group(1), match.group(2)
        value = value.strip('"').strip("'")
        value = re.sub(r'\$\{[A-Z_]+:-([^}]*)\}', r'\1', value)
        if key in mapping:
            attr_name, converter = mapping[key]
            try:
                overrides[attr_name] = converter(value)
            except (ValueError, TypeError):
                pass
    return overrides


def parse_json_config(path: Path) -> dict[str, Any]:
    """Load ralph.config.json configuration into config overrides."""
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return {}

    key_map = {
        "projectName": "project_name",
        "projectType": "project_type",
        "maxCallsPerHour": "max_calls_per_hour",
        "timeoutMinutes": "timeout_minutes",
        "outputFormat": "output_format",
        "allowedTools": "allowed_tools",
        "sessionContinuity": "session_continuity",
        "sessionExpiryHours": "session_expiry_hours",
        "cbNoProgressThreshold": "cb_no_progress_threshold",
        "cbSameErrorThreshold": "cb_same_error_threshold",
        "cbOutputDeclineThreshold": "cb_output_decline_threshold",
        "cbCooldownMinutes": "cb_cooldown_minutes",
        "cbAutoReset": "cb_auto_reset",
        "logMaxSizeMb": "log_max_size_mb",
        "logMaxFiles": "log_max_files",
        "logMaxOutputFiles": "log_max_output_files",
        "dryRun": "dry_run",
        "claudeCodeCmd": "claude_code_cmd",
        "claudeAutoUpdate": "claude_auto_update",
        "claudeMinVersion": "claude_min_version",
        "verbose": "verbose",
        "agentName": "agent_name",
        "enableTeams": "enable_teams",
        "maxTeammates": "max_teammates",
        "bgTesting": "bg_testing",
        "teammateMode": "teammate_mode",
        "model": "model",
        "maxTurns": "max_turns",
        "cbMaxConsecutiveFastFailures": "cb_max_consecutive_fast_failures",
        "cbFastFailureThresholdSeconds": "cb_fast_failure_threshold_seconds",
        "cbMaxDeferredTests": "cb_max_deferred_tests",
        "cbDeferredTestsWarnAt": "cb_deferred_tests_warn_at",
        "cbMaxConsecutiveTimeouts": "cb_max_consecutive_timeouts",
        "decompositionFileCountThreshold": "decomposition_file_count_threshold",
        "decompositionComplexityThreshold": "decomposition_complexity_threshold",
        "decompositionNoProgressThreshold": "decomposition_no_progress_threshold",
        "cancelGraceSeconds": "cancel_grace_seconds",
        "adaptiveTimeoutEnabled": "adaptive_timeout_enabled",
        "adaptiveTimeoutMinSamples": "adaptive_timeout_min_samples",
        "adaptiveTimeoutMultiplier": "adaptive_timeout_multiplier",
        "adaptiveTimeoutMinMinutes": "adaptive_timeout_min_minutes",
        "adaptiveTimeoutMaxMinutes": "adaptive_timeout_max_minutes",
        "maxSessionIterations": "max_session_iterations",
        "maxSessionAgeMinutes": "max_session_age_minutes",
        "continueAsNewEnabled": "continue_as_new_enabled",
        "maxBudgetUsd": "max_budget_usd",
        "budgetWarningPct": "budget_warning_pct",
        "budgetCriticalPct": "budget_critical_pct",
        "modelMapTrivial": "model_map_trivial",
        "modelMapSmall": "model_map_small",
        "modelMapMedium": "model_map_medium",
        "modelMapLarge": "model_map_large",
        "modelMapArchitectural": "model_map_architectural",
        "maxTokensPerHour": "max_tokens_per_hour",
    }

    overrides: dict[str, Any] = {}
    for json_key, attr_name in key_map.items():
        if json_key in data:
            overrides[attr_name] = data[json_key]
    return overrides


def parse_env() -> dict[str, Any]:
    """Load from environment variables (highest precedence)."""
    env_map = {
        "MAX_CALLS_PER_HOUR": ("max_calls_per_hour", int),
        "CLAUDE_TIMEOUT_MINUTES": ("timeout_minutes", int),
        "CLAUDE_OUTPUT_FORMAT": ("output_format", str),
        "CLAUDE_ALLOWED_TOOLS": ("allowed_tools", lambda v: v.split(",")),
        "ALLOWED_TOOLS": ("allowed_tools", lambda v: v.split(",")),
        "CLAUDE_USE_CONTINUE": ("session_continuity", lambda v: v.lower() == "true"),
        "SESSION_CONTINUITY": ("session_continuity", lambda v: v.lower() == "true"),
        "CLAUDE_SESSION_EXPIRY_HOURS": ("session_expiry_hours", int),
        "CB_NO_PROGRESS_THRESHOLD": ("cb_no_progress_threshold", int),
        "CB_SAME_ERROR_THRESHOLD": ("cb_same_error_threshold", int),
        "CB_OUTPUT_DECLINE_THRESHOLD": ("cb_output_decline_threshold", int),
        "CB_COOLDOWN_MINUTES": ("cb_cooldown_minutes", int),
        "CB_AUTO_RESET": ("cb_auto_reset", lambda v: v.lower() == "true"),
        "LOG_MAX_SIZE_MB": ("log_max_size_mb", int),
        "LOG_MAX_FILES": ("log_max_files", int),
        "LOG_MAX_OUTPUT_FILES": ("log_max_output_files", int),
        "DRY_RUN": ("dry_run", lambda v: v.lower() == "true"),
        "CLAUDE_CODE_CMD": ("claude_code_cmd", str),
        "CLAUDE_AUTO_UPDATE": ("claude_auto_update", lambda v: v.lower() == "true"),
        "RALPH_VERBOSE": ("verbose", lambda v: v.lower() == "true"),
        "RALPH_ENABLE_TEAMS": ("enable_teams", lambda v: v.lower() == "true"),
        "RALPH_MAX_TEAMMATES": ("max_teammates", int),
        "RALPH_MODEL": ("model", str),
        "RALPH_MAX_TURNS": ("max_turns", int),
        "PROJECT_NAME": ("project_name", str),
        "PROJECT_TYPE": ("project_type", str),
        "CB_MAX_CONSECUTIVE_FAST_FAILURES": ("cb_max_consecutive_fast_failures", int),
        "CB_FAST_FAILURE_THRESHOLD_SECONDS": ("cb_fast_failure_threshold_seconds", float),
        "CB_MAX_DEFERRED_TESTS": ("cb_max_deferred_tests", int),
        "CB_DEFERRED_TESTS_WARN_AT": ("cb_deferred_tests_warn_at", int),
        "CB_MAX_CONSECUTIVE_TIMEOUTS": ("cb_max_consecutive_timeouts", int),
        "DECOMPOSITION_FILE_COUNT_THRESHOLD": ("decomposition_file_count_threshold", int),
        "DECOMPOSITION_COMPLEXITY_THRESHOLD": ("decomposition_complexity_threshold", int),
        "DECOMPOSITION_NO_PROGRESS_THRESHOLD": ("decomposition_no_progress_threshold", int),
        "CANCEL_GRACE_SECONDS": ("cancel_grace_seconds", float),
        "ADAPTIVE_TIMEOUT_ENABLED": ("adaptive_timeout_enabled", lambda v: v.lower() == "true"),
        "ADAPTIVE_TIMEOUT_MIN_SAMPLES": ("adaptive_timeout_min_samples", int),
        "ADAPTIVE_TIMEOUT_MULTIPLIER": ("adaptive_timeout_multiplier", float),
        "ADAPTIVE_TIMEOUT_MIN_MINUTES": ("adaptive_timeout_min_minutes", int),
        "ADAPTIVE_TIMEOUT_MAX_MINUTES": ("adaptive_timeout_max_minutes", int),
        "MAX_SESSION_ITERATIONS": ("max_session_iterations", int),
        "MAX_SESSION_AGE_MINUTES": ("max_session_age_minutes", int),
        "CONTINUE_AS_NEW_ENABLED": ("continue_as_new_enabled", lambda v: v.lower() == "true"),
        "MAX_BUDGET_USD": ("max_budget_usd", float),
        "BUDGET_WARNING_PCT": ("budget_warning_pct", float),
        "BUDGET_CRITICAL_PCT": ("budget_critical_pct", float),
        "MODEL_ROUTING_ENABLED": ("model_routing_enabled", lambda v: v.lower() == "true"),
        "RALPH_MODEL_ROUTING_ENABLED": ("model_routing_enabled", lambda v: v.lower() == "true"),
        "MODEL_MAP_TRIVIAL": ("model_map_trivial", str),
        "MODEL_MAP_SMALL": ("model_map_small", str),
        "MODEL_MAP_MEDIUM": ("model_map_medium", str),
        "MODEL_MAP_LARGE": ("model_map_large", str),
        "MODEL_MAP_ARCHITECTURAL": ("model_map_architectural", str),
        "MAX_TOKENS_PER_HOUR": ("max_tokens_per_hour", int),
        "RALPH_NO_OPTIMIZE": ("optimize_plan", lambda v: v.lower() != "true"),
    }

    overrides: dict[str, Any] = {}
    for env_key, (attr_name, converter) in env_map.items():
        value = os.environ.get(env_key)
        if value is not None:
            try:
                overrides[attr_name] = converter(value)
            except (ValueError, TypeError):
                pass
    return overrides
