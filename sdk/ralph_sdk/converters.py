"""Ralph SDK TaskPacket conversion — Ralph-side mirror models (no TheStudio dependency).

Converts TheStudio TaskPacket + IntentSpec into Ralph TaskInput with:
- Goal -> prompt
- Constraints -> constraint appendix
- Acceptance criteria -> prompt appendix
- Non-goals -> constraint exclusions
- Risk flags -> safety constraints
- Context packs -> context_files
- Trust tier -> permission_mode hint
- Complexity -> max_turns scaling
- Loopback context -> prompt prepend for retries
"""

from __future__ import annotations

import warnings
from enum import Enum
from typing import Any

from pydantic import BaseModel, Field

from ralph_sdk.agent import TaskInput


class ComplexityBand(str, Enum):
    """Task complexity classification for max_turns scaling."""
    LOW = "low"
    MEDIUM = "medium"
    HIGH = "high"
    UNKNOWN = "unknown"


class TrustTier(str, Enum):
    """Trust level determining permission mode."""
    FULL = "full"
    STANDARD = "standard"
    RESTRICTED = "restricted"
    UNTRUSTED = "untrusted"


class RiskFlag(BaseModel):
    """A risk flag attached to a task packet."""
    category: str = ""
    severity: str = "low"
    description: str = ""


class ContextPack(BaseModel):
    """A context file/resource to include."""
    path: str = ""
    content: str = ""
    type: str = "file"


class IntentSpecInput(BaseModel):
    """Ralph-side mirror of TheStudio IntentSpec (no TheStudio dependency).

    Maps IntentSpec fields to Ralph TaskInput construction.
    """
    goal: str = ""
    constraints: list[str] = Field(default_factory=list)
    acceptance_criteria: list[str] = Field(default_factory=list)
    non_goals: list[str] = Field(default_factory=list)
    risk_flags: list[RiskFlag] = Field(default_factory=list)
    context_packs: list[ContextPack] = Field(default_factory=list)
    trust_tier: TrustTier = TrustTier.STANDARD
    complexity: ComplexityBand = ComplexityBand.UNKNOWN


class TaskPacketInput(BaseModel):
    """Ralph-side mirror of TheStudio TaskPacket (no TheStudio dependency).

    Contains the task packet envelope fields that Ralph needs.
    """
    id: str = ""
    type: str = "implementation"
    intent: IntentSpecInput = Field(default_factory=IntentSpecInput)
    loopback_context: str = ""
    loopback_attempt: int = 0
    expert_outputs: list[dict[str, Any]] = Field(default_factory=list)
    payload: dict[str, Any] = Field(default_factory=dict)


# Complexity -> max_turns mapping
COMPLEXITY_MAX_TURNS = {
    ComplexityBand.LOW: 20,
    ComplexityBand.MEDIUM: 30,
    ComplexityBand.HIGH: 50,
    ComplexityBand.UNKNOWN: 30,
}

# Trust tier -> permission mode hint
TRUST_PERMISSION_MAP = {
    TrustTier.FULL: "bypassPermissions",
    TrustTier.STANDARD: "default",
    TrustTier.RESTRICTED: "plan",
    TrustTier.UNTRUSTED: "plan",
}


def from_task_packet(
    packet: TaskPacketInput,
    intent: IntentSpecInput | None = None,
    *,
    loopback_context: str = "",
    expert_outputs: list[dict[str, Any]] | None = None,
) -> TaskInput:
    """Convert TaskPacket + IntentSpec into Ralph TaskInput (v2 signature).

    Args:
        packet: The TaskPacket envelope.
        intent: IntentSpec (defaults to packet.intent if not provided).
        loopback_context: Override for retry context (defaults to packet.loopback_context).
        expert_outputs: Expert agent outputs to include in context.

    Returns:
        TaskInput ready for RalphAgent.run_iteration().
    """
    intent = intent or packet.intent
    loopback = loopback_context or packet.loopback_context
    experts = expert_outputs or packet.expert_outputs

    # Build prompt from goal
    prompt_parts = []

    # Prepend loopback context for retries
    if loopback:
        prompt_parts.append(f"## Retry Context\n\n{loopback}\n")

    # Main goal
    prompt_parts.append(intent.goal)

    # Acceptance criteria as appendix
    if intent.acceptance_criteria:
        criteria_text = "\n".join(f"- {c}" for c in intent.acceptance_criteria)
        prompt_parts.append(f"\n\n## Acceptance Criteria\n\n{criteria_text}")

    # Expert outputs as context
    if experts:
        expert_text = "\n\n".join(
            f"### Expert: {e.get('agent', 'unknown')}\n{e.get('output', '')}"
            for e in experts
        )
        prompt_parts.append(f"\n\n## Expert Analysis\n\n{expert_text}")

    prompt = "\n".join(prompt_parts)

    # Build constraints (constraints + non_goals as exclusions + risk flags as safety)
    constraint_parts = []
    if intent.constraints:
        constraint_parts.extend(intent.constraints)
    if intent.non_goals:
        constraint_parts.extend(f"DO NOT: {ng}" for ng in intent.non_goals)
    if intent.risk_flags:
        for rf in intent.risk_flags:
            if rf.severity in ("high", "critical"):
                constraint_parts.append(f"SAFETY: {rf.description} ({rf.category})")

    # Build agent instructions from constraints and context packs
    instructions_parts = []
    if constraint_parts:
        constraints_text = "\n".join(f"- {c}" for c in constraint_parts)
        instructions_parts.append(f"## Constraints\n\n{constraints_text}")

    if intent.context_packs:
        for cp in intent.context_packs:
            if cp.content:
                instructions_parts.append(f"## Context: {cp.path}\n\n{cp.content}")

    agent_instructions = "\n\n".join(instructions_parts) if instructions_parts else ""

    return TaskInput(
        prompt=prompt,
        agent_instructions=agent_instructions,
        task_packet_id=packet.id,
        task_packet_type=packet.type,
        task_packet_payload=packet.payload,
    )


def from_task_packet_dict(packet: dict[str, Any]) -> TaskInput:
    """DEPRECATED: Convert raw dict TaskPacket to TaskInput.

    Use from_task_packet(TaskPacketInput(...), IntentSpecInput(...)) instead.
    """
    warnings.warn(
        "from_task_packet_dict() is deprecated. Use from_task_packet() with typed models.",
        DeprecationWarning,
        stacklevel=2,
    )
    # Wrap to typed models and delegate
    typed_packet = TaskPacketInput(**{
        k: v for k, v in packet.items()
        if k in TaskPacketInput.model_fields
    })
    return from_task_packet(typed_packet)


def get_max_turns(complexity: ComplexityBand) -> int:
    """Get max_turns for a complexity band."""
    return COMPLEXITY_MAX_TURNS.get(complexity, 30)


def get_permission_mode(trust_tier: TrustTier) -> str:
    """Get permission mode hint for a trust tier."""
    return TRUST_PERMISSION_MAP.get(trust_tier, "default")
