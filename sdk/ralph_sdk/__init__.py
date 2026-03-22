"""Ralph SDK — Agent SDK integration for Ralph autonomous development loop.

Provides dual-mode operation: standalone CLI + TheStudio embedded.
"""

__version__ = "2.0.0"

from ralph_sdk.agent import RalphAgent, TaskInput, TaskResult
from ralph_sdk.config import RalphConfig
from ralph_sdk.state import FileStateBackend, NullStateBackend, RalphStateBackend
from ralph_sdk.status import (
    CircuitBreakerState,
    CircuitBreakerStateEnum,
    RalphLoopStatus,
    RalphStatus,
    WorkType,
)
from ralph_sdk.tools import (
    ralph_status_tool,
    ralph_rate_check_tool,
    ralph_circuit_state_tool,
    ralph_task_update_tool,
)

__all__ = [
    "RalphAgent",
    "RalphConfig",
    "RalphStateBackend",
    "FileStateBackend",
    "NullStateBackend",
    "TaskInput",
    "TaskResult",
    "RalphStatus",
    "RalphLoopStatus",
    "WorkType",
    "CircuitBreakerState",
    "CircuitBreakerStateEnum",
    "ralph_status_tool",
    "ralph_rate_check_tool",
    "ralph_circuit_state_tool",
    "ralph_task_update_tool",
]
