"""Tests for execution capability gating (Task 4.2)."""

from __future__ import annotations

import importlib

import pytest

from wilted.execution_capability import (
    ExecutionCapabilityError,
    execution_capability_scope,
)
from wilted.llm import create_backend


class TestGatedFactories:
    def test_create_backend_fails_without_capability(self) -> None:
        with pytest.raises(ExecutionCapabilityError, match="PipelineRunner execution capability"):
            create_backend("mlx", model="test-model")

    def test_gated_factories_succeed_inside_scope(self, tmp_path) -> None:
        with execution_capability_scope(owner_id="scope-test", data_dir=tmp_path):
            backend = create_backend("mlx", model="test-model")
        assert backend.model_name == "test-model"

    def test_dynamic_import_bypass_still_hits_gated_factory(self) -> None:
        llm_mod = importlib.import_module("wilted.llm")
        factory = getattr(llm_mod, "create_backend")
        with pytest.raises(ExecutionCapabilityError, match="PipelineRunner execution capability"):
            factory("mlx", model="bypass-model")
