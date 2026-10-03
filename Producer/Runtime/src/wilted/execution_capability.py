"""Worker authority for expensive ML construction (Task 4.2).

Only the preparation worker (``Producer/Workers/wilted_pipeline.py``) activates
execution capability, through :func:`execution_capability_scope`. Gated
factories (:func:`wilted.llm.create_backend`, tier-3
:func:`wilted.transcribe.transcribe_audio`) call
:func:`require_execution_capability` and fail loudly when capability is absent.
"""

from __future__ import annotations

from contextlib import contextmanager
from contextvars import ContextVar, Token
from dataclasses import dataclass
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from collections.abc import Iterator
    from pathlib import Path

_capability: ContextVar[ExecutionCapability | None] = ContextVar(
    "wilted_execution_capability",
    default=None,
)


class ExecutionCapabilityError(RuntimeError):
    """Raised when expensive ML work is attempted without worker authority."""


@dataclass(frozen=True, slots=True)
class ExecutionCapability:
    """Opaque token authorizing expensive ML construction."""

    owner_id: str
    data_dir: Path


def require_execution_capability() -> ExecutionCapability:
    """Return the active capability or raise if absent.

    Raises:
        ExecutionCapabilityError: When no capability is active for this context.
    """
    capability = _capability.get()
    if capability is None:
        raise ExecutionCapabilityError(
            "expensive ML construction requires PipelineRunner execution capability",
        )
    return capability


@contextmanager
def execution_capability_scope(
    *,
    owner_id: str = "test",
    data_dir: Path,
) -> Iterator[ExecutionCapability]:
    """Activate an execution capability for the enclosed block.

    Args:
        owner_id: Capability owner label.
        data_dir: Data directory bound to the capability.

    Yields:
        The active :class:`ExecutionCapability`.
    """
    capability = ExecutionCapability(
        owner_id=owner_id,
        data_dir=data_dir,
    )
    token: Token[ExecutionCapability | None] = _capability.set(capability)
    try:
        yield capability
    finally:
        _capability.reset(token)
