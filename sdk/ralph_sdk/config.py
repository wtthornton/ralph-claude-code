"""Ralph SDK configuration — loads from .ralphrc, ralph.config.json, and environment."""

from __future__ import annotations

import json
import os
import re
import shlex
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


@dataclass
class RalphConfig:
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
    max_calls_per_hour: int = 100
    timeout_minutes: int = 15
    output_format: str = "json"

    # Tool permissions
    allowed_tools: list[str] = field(default_factory=lambda: [
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
    session_expiry_hours: int = 24

    # Circuit breaker
    cb_no_progress_threshold: int = 3
    cb_same_error_threshold: int = 5
    cb_output_decline_threshold: int = 70
    cb_cooldown_minutes: int = 30
    cb_auto_reset: bool = False

    # Log rotation
    log_max_size_mb: int = 10
    log_max_files: int = 5
    log_max_output_files: int = 20

    # Dry run
    dry_run: bool = False

    # Advanced
    claude_code_cmd: str = "claude"
    claude_auto_update: bool = True
    claude_min_version: str = "2.0.76"
    verbose: bool = False

    # Agent settings
    agent_name: str = "ralph"
    use_agent: bool = True

    # Teams (experimental)
    enable_teams: bool = False
    max_teammates: int = 3
    bg_testing: bool = False
    teammate_mode: str = "tmux"

    # Paths (derived)
    ralph_dir: str = ".ralph"

    # SDK-specific
    model: str = "claude-sonnet-4-20250514"
    max_turns: int = 50

    @classmethod
    def load(cls, project_dir: str | Path = ".") -> RalphConfig:
        """Load configuration with full precedence chain."""
        project_dir = Path(project_dir)
        config = cls()

        # Layer 1: .ralphrc (bash config)
        ralphrc_path = project_dir / ".ralphrc"
        if ralphrc_path.exists():
            config._load_ralphrc(ralphrc_path)

        # Layer 2: ralph.config.json
        json_config_path = project_dir / "ralph.config.json"
        if json_config_path.exists():
            config._load_json_config(json_config_path)

        # Layer 3: Environment variables (highest precedence)
        config._load_env()

        return config

    def _load_ralphrc(self, path: Path) -> None:
        """Parse .ralphrc bash config file."""
        content = path.read_text(encoding="utf-8")
        for line in content.splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            # Match VAR=value or VAR="value" patterns
            match = re.match(r'^([A-Z_]+)=(.*)$', line)
            if not match:
                continue
            key, value = match.group(1), match.group(2)
            # Strip surrounding quotes
            value = value.strip('"').strip("'")
            # Remove ${VAR:-default} shell patterns — take the default
            value = re.sub(r'\$\{[A-Z_]+:-([^}]*)\}', r'\1', value)
            self._set_from_key(key, value)

    def _load_json_config(self, path: Path) -> None:
        """Load ralph.config.json configuration."""
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            return

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
            "useAgent": "use_agent",
            "enableTeams": "enable_teams",
            "maxTeammates": "max_teammates",
            "bgTesting": "bg_testing",
            "teammateMode": "teammate_mode",
            "model": "model",
            "maxTurns": "max_turns",
        }

        for json_key, attr_name in key_map.items():
            if json_key in data:
                setattr(self, attr_name, data[json_key])

    def _load_env(self) -> None:
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
        }

        for env_key, (attr_name, converter) in env_map.items():
            value = os.environ.get(env_key)
            if value is not None:
                try:
                    setattr(self, attr_name, converter(value))
                except (ValueError, TypeError):
                    pass  # Skip invalid env values

    def _set_from_key(self, key: str, value: str) -> None:
        """Set a config attribute from a .ralphrc key=value pair."""
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
            "RALPH_USE_AGENT": ("use_agent", lambda v: v.lower() == "true"),
            "RALPH_AGENT_NAME": ("agent_name", str),
            "RALPH_ENABLE_TEAMS": ("enable_teams", lambda v: v.lower() == "true"),
            "RALPH_MAX_TEAMMATES": ("max_teammates", int),
            "RALPH_BG_TESTING": ("bg_testing", lambda v: v.lower() == "true"),
            "RALPH_TEAMMATE_MODE": ("teammate_mode", str),
        }

        if key in mapping:
            attr_name, converter = mapping[key]
            try:
                setattr(self, attr_name, converter(value))
            except (ValueError, TypeError):
                pass

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
            "useAgent": self.use_agent,
            "enableTeams": self.enable_teams,
            "maxTeammates": self.max_teammates,
            "bgTesting": self.bg_testing,
            "teammateMode": self.teammate_mode,
            "model": self.model,
            "maxTurns": self.max_turns,
        }

    def to_json(self, indent: int = 2) -> str:
        """Export configuration as JSON string."""
        return json.dumps(self.to_dict(), indent=indent)
