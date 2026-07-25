"""Allowlisted ML backend construction for pipeline handlers."""

from __future__ import annotations

from typing import TYPE_CHECKING

from wilted.llm import create_backend

if TYPE_CHECKING:
    from wilted.llm import LLMBackend


def build_llm_backend(backend_type: str, *, model: str) -> LLMBackend:
    """Construct an LLM backend under runner execution capability."""
    return create_backend(backend_type, model=model)
