"""Ralph SDK configuration — loads from .ralphrc, ralph.config.json, and environment."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from pydantic import BaseModel, Field, field_validator

import ralph_sdk.config_parsers as config_parsers


class RalphConfigError(RuntimeError):
    """Raised when SDK configuration is invalid or environment fails preflight.

    TAP-1104: emitted on Claude CLI version mismatch instead of silently
    falling back to legacy `-p` mode (mirrors bash ADR-0006).
    """


class RalphConfig(BaseModel):
    """Configuration for Ralph SDK agent.

    Precedence (highest to lowest):
    1. Environment variables
    2. ralph.config.json
    3. .ralphrc (bash config)
    4. Defaults
    """

    # Project
    project_name: str = "my-project"
    project_type: str = "unknown"

    # Loop settings
    max_calls_per_hour: int = Field(default=200, ge=1, le=10000)
    timeout_minutes: int = Field(default=15, ge=1, le=1440)
    output_format: str = "json"

    # Tool permissions
    allowed_tools: list[str] = Field(default_factory=lambda: [
        "Write", "Read", "Edit", "Bash(git add *)", "Bash(git commit *)",
        "Bash(git diff *)", "Bash(git log *)", "Bash(git status)",
        "Bash(git status *)", "Bash(git push *)", "Bash(git pull *)",
        "Bash(git fetch *)", "Bash(git checkout *)", "Bash(git branch *)",
        "Bash(git stash *)", "Bash(git merge *)", "Bash(git tag *)",
        "Bash(git -C *)", "Bash(grep *)", "Bash(find *)", "Bash(npm *)",
        "Bash(pytest)", "Bash(xargs *)", "Bash(sort *)", "Bash(tee *)",
        "Bash(rm *)", "Bash(touch *)", "Bash(sed *)", "Bash(awk *)",
        "Bash(tr *)", "Bash(cut *)", "Bash(dirname *)", "Bash(basename *)",
        "Bash(realpath *)", "Bash(test *)", "Bash(true)", "Bash(false)",
        "Bash(sleep *)", "Bash(ls *)", "Bash(cat *)", "Bash(wc *)",
        "Bash(head *)", "Bash(tail *)", "Bash(mkdir *)", "Bash(cp *)",
        "Bash(mv *)",
    ])

    # Session management
    session_continuity: bool = True
    session_expiry_hours: int = Field(default=24, ge=1, le=168)

    # Circuit breaker
    cb_no_progress_threshold: int = Field(default=3, ge=1, le=50)
    cb_same_error_threshold: int = Field(default=5, ge=1, le=100)
    cb_output_decline_threshold: int = Field(default=70, ge=0, le=100)
    cb_cooldown_minutes: int = Field(default=30, ge=1, le=1440)
    cb_auto_reset: bool = False

    # SDK-SAFETY-1: Stall detection thresholds
    cb_max_consecutive_fast_failures: int = Field(default=3, ge=1, le=50)
    cb_fast_failure_threshold_seconds: float = Field(default=30.0, ge=1.0, le=300.0)
    cb_max_deferred_tests: int = Field(default=5, ge=1, le=100)
    cb_deferred_tests_warn_at: int = Field(default=5, ge=1, le=50)
    cb_max_consecutive_timeouts: int = Field(default=5, ge=1, le=50)

    # SDK-SAFETY-2: Task decomposition thresholds
    decomposition_file_count_threshold: int = Field(default=5, ge=1, le=100)
    decomposition_complexity_threshold: int = Field(default=4, ge=1, le=10)
    decomposition_no_progress_threshold: int = Field(default=3, ge=1, le=50)

    # Log rotation
    log_max_size_mb: int = Field(default=10, ge=1, le=1000)
    log_max_files: int = Field(default=5, ge=1, le=100)
    log_max_output_files: int = Field(default=20, ge=1, le=1000)

    # Dry run
    dry_run: bool = False

    # Advanced
    claude_code_cmd: str = "claude"
    claude_auto_update: bool = True
    claude_min_version: str = "2.1.0"
    verbose: bool = False

    # Agent settings
    agent_name: str = "ralph"

    # Teams (experimental)
    enable_teams: bool = False
    max_teammates: int = Field(default=3, ge=1, le=10)
    bg_testing: bool = False
    teammate_mode: str = "tmux"

    # Paths (derived)
    ralph_dir: str = ".ralph"

    # SDK-specific
    model: str = "claude-sonnet-4-6"
    max_turns: int = Field(default=50, ge=1, le=200)

    # SDK-LIFECYCLE-1: Cancel semantics
    cancel_grace_seconds: float = Field(default=10.0, ge=1.0, le=120.0)

    # Plan optimization (PLANOPT)
    optimize_plan: bool = True
    optimize_plan_cache_seconds: int = Field(default=3600, ge=0, le=86400)

    # SDK-LIFECYCLE-2: Adaptive timeout
    adaptive_timeout_enabled: bool = False
    adaptive_timeout_min_samples: int = Field(default=5, ge=1, le=100)
    adaptive_timeout_multiplier: float = Field(default=2.0, ge=1.0, le=10.0)
    adaptive_timeout_min_minutes: int = Field(default=5, ge=1, le=1440)
    adaptive_timeout_max_minutes: int = Field(default=60, ge=1, le=1440)

    # SDK-CONTEXT-3: Session Lifecycle Management
    max_session_iterations: int = Field(default=20, ge=1, le=1000)
    max_session_age_minutes: int = Field(default=120, ge=1, le=10080)
    continue_as_new_enabled: bool = True

    # SDK-COST-1: Budget guardrails
    max_budget_usd: float = Field(default=0.0, ge=0.0, description="Max budget in USD. 0 = disabled.")
    budget_warning_pct: float = Field(default=50.0, ge=0.0, le=100.0, description="Budget % for WARNING alert.")
    budget_critical_pct: float = Field(default=80.0, ge=0.0, le=100.0, description="Budget % for CRITICAL alert.")

    # SDK-COST-2: Dynamic model routing
    model_routing_enabled: bool = False
    model_map_trivial: str = "claude-haiku-4-5"
    model_map_small: str = "claude-haiku-4-5"
    model_map_medium: str = "claude-sonnet-4-6"
    model_map_large: str = "claude-opus-4-8"
    model_map_architectural: str = "claude-opus-4-8"

    # SDK-COST-3: Token-based rate limiting
    max_tokens_per_hour: int = Field(default=0, ge=0, description="Max tokens per hour. 0 = disabled.")

    @field_validator("output_format")
    @classmethod
    def validate_output_format(cls, v: str) -> str:
        if v not in ("json", "text"):
            raise ValueError("output_format must be 'json' or 'text'")
        return v

    @field_validator("teammate_mode")
    @classmethod
    def validate_teammate_mode(cls, v: str) -> str:
        if v not in ("tmux", "background"):
            raise ValueError("teammate_mode must be 'tmux' or 'background'")
        return v

    @classmethod
    def load(cls, project_dir: str | Path = ".") -> RalphConfig:
        """Load configuration with full precedence chain."""
        project_dir = Path(project_dir)
        overrides: dict[str, Any] = {}

        # Layer 1: .ralphrc (bash config)
        ralphrc_path = project_dir / ".ralphrc"
        if ralphrc_path.exists():
            overrides.update(cls._parse_ralphrc(ralphrc_path))

        # Layer 2: ralph.config.json
        json_config_path = project_dir / "ralph.config.json"
        if json_config_path.exists():
            overrides.update(cls._parse_json_config(json_config_path))

        # Layer 3: Environment variables (highest precedence)
        overrides.update(cls._parse_env())

        return cls(**overrides)

    @staticmethod
    def _parse_ralphrc(path: Path) -> dict[str, Any]:
        """Parse .ralphrc bash config file into config overrides."""
        return config_parsers.parse_ralphrc(path)

    @staticmethod
    def _parse_json_config(path: Path) -> dict[str, Any]:
        """Load ralph.config.json configuration into config overrides."""
        return config_parsers.parse_json_config(path)

    @staticmethod
    def _parse_env() -> dict[str, Any]:
        """Load from environment variables (highest precedence)."""
        return config_parsers.parse_env()

    def to_dict(self) -> dict[str, Any]:
        """Export configuration as dictionary."""
        return {
            "projectName": self.project_name,
            "projectType": self.project_type,
            "maxCallsPerHour": self.max_calls_per_hour,
            "timeoutMinutes": self.timeout_minutes,
            "outputFormat": self.output_format,
            "allowedTools": self.allowed_tools,
            "sessionContinuity": self.session_continuity,
            "sessionExpiryHours": self.session_expiry_hours,
            "cbNoProgressThreshold": self.cb_no_progress_threshold,
            "cbSameErrorThreshold": self.cb_same_error_threshold,
            "cbOutputDeclineThreshold": self.cb_output_decline_threshold,
            "cbCooldownMinutes": self.cb_cooldown_minutes,
            "cbAutoReset": self.cb_auto_reset,
            "logMaxSizeMb": self.log_max_size_mb,
            "logMaxFiles": self.log_max_files,
            "logMaxOutputFiles": self.log_max_output_files,
            "dryRun": self.dry_run,
            "claudeCodeCmd": self.claude_code_cmd,
            "claudeAutoUpdate": self.claude_auto_update,
            "claudeMinVersion": self.claude_min_version,
            "verbose": self.verbose,
            "agentName": self.agent_name,
            "enableTeams": self.enable_teams,
            "maxTeammates": self.max_teammates,
            "bgTesting": self.bg_testing,
            "teammateMode": self.teammate_mode,
            "model": self.model,
            "maxTurns": self.max_turns,
            "cbMaxConsecutiveFastFailures": self.cb_max_consecutive_fast_failures,
            "cbFastFailureThresholdSeconds": self.cb_fast_failure_threshold_seconds,
            "cbMaxDeferredTests": self.cb_max_deferred_tests,
            "cbDeferredTestsWarnAt": self.cb_deferred_tests_warn_at,
            "cbMaxConsecutiveTimeouts": self.cb_max_consecutive_timeouts,
            "decompositionFileCountThreshold": self.decomposition_file_count_threshold,
            "decompositionComplexityThreshold": self.decomposition_complexity_threshold,
            "decompositionNoProgressThreshold": self.decomposition_no_progress_threshold,
            "cancelGraceSeconds": self.cancel_grace_seconds,
            "adaptiveTimeoutEnabled": self.adaptive_timeout_enabled,
            "adaptiveTimeoutMinSamples": self.adaptive_timeout_min_samples,
            "adaptiveTimeoutMultiplier": self.adaptive_timeout_multiplier,
            "adaptiveTimeoutMinMinutes": self.adaptive_timeout_min_minutes,
            "adaptiveTimeoutMaxMinutes": self.adaptive_timeout_max_minutes,
            "maxSessionIterations": self.max_session_iterations,
            "maxSessionAgeMinutes": self.max_session_age_minutes,
            "continueAsNewEnabled": self.continue_as_new_enabled,
            "maxBudgetUsd": self.max_budget_usd,
            "budgetWarningPct": self.budget_warning_pct,
            "budgetCriticalPct": self.budget_critical_pct,
            "modelMapTrivial": self.model_map_trivial,
            "modelMapSmall": self.model_map_small,
            "modelMapMedium": self.model_map_medium,
            "modelMapLarge": self.model_map_large,
            "modelMapArchitectural": self.model_map_architectural,
            "maxTokensPerHour": self.max_tokens_per_hour,
        }

    def to_json(self, indent: int = 2) -> str:
        """Export configuration as JSON string."""
        return json.dumps(self.to_dict(), indent=indent)
