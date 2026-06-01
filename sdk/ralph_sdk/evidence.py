"""Ralph SDK EvidenceBundle — output model compatible with TheStudio schema.

Converts TaskResult into a structured evidence bundle for TheStudio
orchestration, with best-effort test/lint result extraction.
"""

from __future__ import annotations

from datetime import UTC, datetime

from pydantic import BaseModel, Field

from ralph_sdk.agent import TaskResult
from ralph_sdk.evidence_extractors import (
    LintEvidence,
    TestEvidence,
    _extract_lint_results,
    _extract_test_results,
)

__all__ = [
    "EvidenceBundle",
    "LintEvidence",
    "TestEvidence",
    "to_evidence_bundle",
]


class EvidenceBundle(BaseModel):
    """Structured evidence bundle compatible with TheStudio schema.

    Contains the full result plus extracted test/lint evidence.
    """
    taskpacket_id: str = ""
    intent_version: str = ""
    loopback_attempt: int = 0
    status: str = "IN_PROGRESS"
    exit_signal: bool = False
    work_type: str = "UNKNOWN"
    completed_task: str = ""
    progress_summary: str = ""
    agent_summary: str = ""
    test_results: list[TestEvidence] = Field(default_factory=list)
    lint_results: list[LintEvidence] = Field(default_factory=list)
    files_modified: list[str] = Field(default_factory=list)
    loop_count: int = 0
    duration_seconds: float = 0.0
    correlation_id: str = ""
    exit_code: int = 0
    error: str = ""
    tokens_in: int = 0
    tokens_out: int = 0
    created_at: datetime = Field(default_factory=lambda: datetime.now(UTC))


def to_evidence_bundle(
    result: TaskResult,
    taskpacket_id: str = "",
    intent_version: str = "",
    loopback_attempt: int = 0,
) -> EvidenceBundle:
    """Convert TaskResult to EvidenceBundle.

    Extracts test and lint results from raw output using best-effort
    pattern matching for pytest/jest/ruff/eslint.
    """
    raw = result.output or ""

    test_results = _extract_test_results(raw)
    lint_results = _extract_lint_results(raw)

    return EvidenceBundle(
        taskpacket_id=taskpacket_id,
        intent_version=intent_version,
        loopback_attempt=loopback_attempt,
        status=result.status.status.value,
        exit_signal=result.status.exit_signal,
        work_type=result.status.work_type.value,
        completed_task=result.status.completed_task,
        progress_summary=result.status.progress_summary,
        agent_summary=raw,
        test_results=test_results,
        lint_results=lint_results,
        loop_count=result.loop_count,
        duration_seconds=result.duration_seconds,
        correlation_id=result.status.correlation_id,
        exit_code=result.exit_code,
        error=result.error,
        tokens_in=result.tokens_in,
        tokens_out=result.tokens_out,
    )
