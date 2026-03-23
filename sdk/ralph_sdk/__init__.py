"""Ralph SDK — Agent SDK integration for Ralph autonomous development loop.

Provides dual-mode operation: standalone CLI + TheStudio embedded.
"""

__version__ = "2.0.2"

from ralph_sdk.agent import (
    CancelResult,
    ContinueAsNewState,
    DecompositionHint,
    IterationRecord,
    ProgressSnapshot,
    RalphAgent,
    TaskInput,
    TaskResult,
    compute_adaptive_timeout,
    detect_decomposition_needed,
)
from ralph_sdk.circuit_breaker import (
    CircuitBreaker,
    ConsecutiveTimeoutDetector,
    DeferredTestDetector,
    FastTripDetector,
    StallDetectorResult,
)
from ralph_sdk.config import RalphConfig
from ralph_sdk.context import (
    ContextManager,
    PromptCacheStats,
    PromptParts,
    estimate_tokens,
    split_prompt,
)
from ralph_sdk.metrics import (
    JsonlMetricsCollector,
    MetricEvent,
    MetricsCollector,
    NullMetricsCollector,
)
from ralph_sdk.parsing import (
    PermissionDenialEvent,
    detect_permission_denials,
    extract_files_changed,
)
from ralph_sdk.state import FileStateBackend, NullStateBackend, RalphStateBackend
from ralph_sdk.status import (
    CircuitBreakerState,
    CircuitBreakerStateEnum,
    ErrorCategory,
    RalphLoopStatus,
    RalphStatus,
    WorkType,
    classify_error,
)
from ralph_sdk.cost import (
    AlertLevel,
    BudgetStatus,
    CostComplexityBand,
    CostTracker,
    DEFAULT_MODEL_MAP,
    DEFAULT_PRICING,
    IterationCost,
    ModelCostBreakdown,
    ModelPricing,
    SessionCost,
    TokenRateLimiter,
    TokenUsage,
    select_model,
)
from ralph_sdk.converters import (
    ComplexityBand,
    IntentSpecInput,
    RiskFlag,
    TaskPacketInput,
    TrustTier,
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
    "ProgressSnapshot",
    "RalphStatus",
    "RalphLoopStatus",
    "WorkType",
    "ErrorCategory",
    "classify_error",
    "CircuitBreakerState",
    "CircuitBreakerStateEnum",
    "MetricEvent",
    "MetricsCollector",
    "JsonlMetricsCollector",
    "NullMetricsCollector",
    "extract_files_changed",
    "ComplexityBand",
    "TrustTier",
    "RiskFlag",
    "IntentSpecInput",
    "TaskPacketInput",
    "ralph_status_tool",
    "ralph_rate_check_tool",
    "ralph_circuit_state_tool",
    "ralph_task_update_tool",
    "AlertLevel",
    "BudgetStatus",
    "CostComplexityBand",
    "CostTracker",
    "DEFAULT_MODEL_MAP",
    "DEFAULT_PRICING",
    "IterationCost",
    "ModelCostBreakdown",
    "ModelPricing",
    "SessionCost",
    "TokenRateLimiter",
    "TokenUsage",
    "select_model",
    "ContinueAsNewState",
    "ContextManager",
    "PromptCacheStats",
    "PromptParts",
    "estimate_tokens",
    "split_prompt",
    # SDK-SAFETY-1: Stall detection
    "CircuitBreaker",
    "FastTripDetector",
    "DeferredTestDetector",
    "ConsecutiveTimeoutDetector",
    "StallDetectorResult",
    # SDK-SAFETY-2: Task decomposition
    "DecompositionHint",
    "IterationRecord",
    "detect_decomposition_needed",
    # SDK-LIFECYCLE-1: Cancel semantics
    "CancelResult",
    # SDK-LIFECYCLE-2: Adaptive timeout
    "compute_adaptive_timeout",
    # SDK-LIFECYCLE-3: Permission denial detection
    "PermissionDenialEvent",
    "detect_permission_denials",
]
