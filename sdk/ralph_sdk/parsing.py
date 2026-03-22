"""Ralph SDK structured response parsing — 3-strategy parse chain.

Strategies (tried in order):
1. JSON fenced code block — structured output from agent
2. JSONL stream result — from Claude CLI --output-format json
3. Text fallback — regex extraction of RALPH_STATUS fields
"""

from __future__ import annotations

import json
import logging
import re
from typing import Any

from pydantic import BaseModel, Field, field_validator

from ralph_sdk.status import RalphLoopStatus, RalphStatus, WorkType

logger = logging.getLogger("ralph.sdk.parsing")


class TestsStatus(str, __import__("enum").Enum):
    """Status of test execution."""
    UNKNOWN = "UNKNOWN"
    PASSED = "PASSED"
    FAILED = "FAILED"
    SKIPPED = "SKIPPED"
    DEFERRED = "DEFERRED"


class RalphStatusBlock(BaseModel):
    """Structured status block parsed from agent response.

    This is the expected JSON output format from the agent, containing
    all status fields plus a version marker.
    """
    version: int = 1
    work_type: WorkType = WorkType.UNKNOWN
    completed_task: str = ""
    next_task: str = ""
    progress_summary: str = ""
    exit_signal: bool = False
    tests_status: TestsStatus = TestsStatus.UNKNOWN

    @field_validator("exit_signal", mode="before")
    @classmethod
    def coerce_exit_signal(cls, v: Any) -> bool:
        """Coerce EXIT_SIGNAL from various truthy representations."""
        if isinstance(v, bool):
            return v
        if isinstance(v, str):
            return v.lower() in ("true", "yes", "1")
        if isinstance(v, (int, float)):
            return bool(v)
        return False

    def to_ralph_status(self) -> RalphStatus:
        """Convert to RalphStatus for backward compatibility."""
        return RalphStatus(
            work_type=self.work_type,
            completed_task=self.completed_task,
            next_task=self.next_task,
            progress_summary=self.progress_summary,
            exit_signal=self.exit_signal,
            status=RalphLoopStatus.COMPLETED if self.exit_signal else RalphLoopStatus.IN_PROGRESS,
        )


def parse_ralph_status(text: str) -> RalphStatus:
    """Parse response text using 3-strategy chain.

    1. JSON fenced block: ```json { "work_type": ... } ```
    2. JSONL result: {"type": "result", "result": "..."}
    3. Text fallback: WORK_TYPE: ... regex extraction
    """
    # Strategy 1: JSON fenced code block
    status = _parse_json_block(text)
    if status is not None:
        logger.debug("Parsed via JSON block strategy")
        return status

    # Strategy 2: JSONL result object
    status = _parse_jsonl_result(text)
    if status is not None:
        logger.debug("Parsed via JSONL strategy")
        return status

    # Strategy 3: Text fallback
    logger.debug("Falling back to text extraction")
    return _parse_text_fallback(text)


def _parse_json_block(text: str) -> RalphStatus | None:
    """Strategy 1: Extract JSON from fenced code block."""
    # Match ```json ... ``` or ``` ... ```
    pattern = r'```(?:json)?\s*\n({[^`]+})\s*\n```'
    match = re.search(pattern, text, re.DOTALL)
    if not match:
        return None

    try:
        data = json.loads(match.group(1))
        # Normalize keys to lowercase
        normalized = {k.lower(): v for k, v in data.items()}
        block = RalphStatusBlock(**normalized)
        return block.to_ralph_status()
    except (json.JSONDecodeError, Exception) as e:
        logger.debug("JSON block parse failed: %s", e)
        return None


def _parse_jsonl_result(text: str) -> RalphStatus | None:
    """Strategy 2: Extract from JSONL stream result object."""
    for line in reversed(text.strip().splitlines()):
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
            if obj.get("type") == "result":
                result_text = obj.get("result", "")
                if isinstance(result_text, str):
                    # Try JSON block within the result text
                    status = _parse_json_block(result_text)
                    if status is not None:
                        return status
                    # Fall through to text extraction on the result text
                    return _parse_text_fallback(result_text)
        except json.JSONDecodeError:
            continue
    return None


def _parse_text_fallback(text: str) -> RalphStatus:
    """Strategy 3: Regex extraction of RALPH_STATUS fields."""
    # Auto-unescape JSON-encoded \n (matching STREAM-3)
    text = text.replace("\\n", "\n")

    status = RalphStatus()

    field_patterns = {
        "work_type": r"WORK_TYPE:\s*(.+?)(?:\n|$)",
        "completed_task": r"COMPLETED_TASK:\s*(.+?)(?:\n|$)",
        "next_task": r"NEXT_TASK:\s*(.+?)(?:\n|$)",
        "progress_summary": r"PROGRESS_SUMMARY:\s*(.+?)(?:\n|$)",
        "exit_signal": r"EXIT_SIGNAL:\s*(.+?)(?:\n|$)",
    }

    for field_name, pattern in field_patterns.items():
        match = re.search(pattern, text, re.IGNORECASE)
        if match:
            value = match.group(1).strip()
            if field_name == "exit_signal":
                status.exit_signal = value.lower() in ("true", "yes", "1")
            elif field_name == "work_type":
                try:
                    status.work_type = WorkType(value.upper())
                except ValueError:
                    status.work_type = WorkType.UNKNOWN
            else:
                setattr(status, field_name, value)

    return status


def _handle_multi_result_jsonl(text: str) -> list[RalphStatus]:
    """Handle JSONL with multiple result objects (subagent filtering)."""
    results = []
    for line in text.strip().splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
            if obj.get("type") == "result":
                result_text = obj.get("result", "")
                if isinstance(result_text, str):
                    status = _parse_text_fallback(result_text)
                    results.append(status)
        except json.JSONDecodeError:
            continue
    return results
