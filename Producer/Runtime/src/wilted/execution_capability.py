"""Pipeline-runner authority for expensive ML construction (Task 4.2).

Only :class:`~wilted.pipeline_runner.PipelineRunner` may issue execution
capability at run start. Gated factories (:func:`create_model_coordinator`,
:func:`wilted.llm.create_backend`, tier-3 :func:`wilted.transcribe.transcribe_audio`)
call :func:`require_execution_capability` and fail loudly when capability is
absent.
"""

from __future__ import annotations

import logging
from contextlib import contextmanager
from contextvars import ContextVar, Token
from dataclasses import dataclass
from typing import TYPE_CHECKING

from wilted.station_runtime.coordinator import ModelCoordinator, RuntimeBootstrap

if TYPE_CHECKING:
    from collections.abc import Iterator
    from pathlib import Path

logger = logging.getLogger(__name__)

_RUNNER_ISSUER = object()

_capability: ContextVar[ExecutionCapability | None] = ContextVar(
    "wilted_execution_capability",
    default=None,
)


class ExecutionCapabilityError(RuntimeError):
    """Raised when expensive ML work is attempted without runner authority."""


@dataclass(frozen=True, slots=True)
class ExecutionCapability:
    """Opaque runner-issued token authorizing expensive ML construction."""

    owner_id: str
    data_dir: Path


def issue_execution_capability(
    owner_id: str,
    data_dir: Path,
    *,
    _issuer: object | None = None,
) -> ExecutionCapability:
    """Issue runner authority for the current execution context.

    Args:
        owner_id: Opaque runner identity recorded on the capability.
        data_dir: Resolved data directory for this runner invocation.
        _issuer: Private sentinel; only :mod:`wilted.pipeline_runner` may pass it.

    Returns:
        The issued :class:`ExecutionCapability`.

    Raises:
        ExecutionCapabilityError: If called outside ``PipelineRunner.run()``.
        ValueError: If ``owner_id`` is empty.
    """
    if _issuer is not _RUNNER_ISSUER:
        raise ExecutionCapabilityError(
            "execution capability may only be issued by PipelineRunner.run()",
        )
    if not owner_id:
        raise ValueError("owner_id must be non-empty")

    capability = ExecutionCapability(
        owner_id=owner_id,
        data_dir=data_dir,
    )
    _capability.set(capability)
    logger.debug(
        "Issued execution capability owner_id=%s data_dir=%s",
        owner_id,
        data_dir,
    )
    return capability


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


def clear_execution_capability() -> None:
    """Clear any active execution capability for this context."""
    _capability.set(None)


@contextmanager
def execution_capability_scope(
    *,
    owner_id: str = "test",
    data_dir: Path,
) -> Iterator[ExecutionCapability]:
    """Activate a test-scoped execution capability.

    Args:
        owner_id: Capability owner label for tests.
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


def create_model_coordinator(*, bootstrap: RuntimeBootstrap | None = None) -> ModelCoordinator:
    """Construct :class:`ModelCoordinator` only under runner authority.

    Args:
        bootstrap: Optional runtime bootstrap for tqdm-lock wiring.

    Returns:
        A new :class:`ModelCoordinator`.

    Raises:
        ExecutionCapabilityError: When no execution capability is active.
    """
    require_execution_capability()
    return ModelCoordinator(bootstrap=bootstrap)
