"""Allowlisted ML backend construction for pipeline handlers."""

from __future__ import annotations

from typing import TYPE_CHECKING

from wilted.llm import create_backend

if TYPE_CHECKING:
    from collections.abc import Callable

    from wilted.llm import LLMBackend
    from wilted.station_runtime.coordinator import ModelCoordinator


def build_llm_backend(backend_type: str, *, model: str) -> LLMBackend:
    """Construct an LLM backend under runner execution capability."""
    return create_backend(backend_type, model=model)


def run_llm_phase(
    coordinator: ModelCoordinator,
    backend_type: str,
    *,
    model: str,
    phase: Callable[[LLMBackend], None],
    on_load_failure: Callable[[], None] | None = None,
) -> bool:
    """Load one backend under the coordinator lease and run ``phase``.

    Returns:
        True when ``phase`` ran under a loaded backend, False when load failed
        and ``on_load_failure`` ran instead.
    """
    try:
        backend = build_llm_backend(backend_type, model=model)
    except Exception:
        if on_load_failure is not None:
            on_load_failure()
        return False

    phase_completed = False

    def _loaded(loaded_backend: LLMBackend) -> None:
        nonlocal phase_completed
        phase(loaded_backend)
        phase_completed = True

    try:
        coordinator.run_llm(backend, _loaded)
    except Exception:
        if phase_completed:
            raise
        if on_load_failure is not None:
            on_load_failure()
        return False
    return True
