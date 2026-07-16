"""Tests for pipeline-runner execution capability gating (Task 4.2)."""

from __future__ import annotations

import importlib

import pytest

import wilted
from wilted.background_work.contracts import JobKind
from wilted.execution_capability import (
    ExecutionCapabilityError,
    clear_execution_capability,
    create_model_coordinator,
    execution_capability_scope,
    issue_execution_capability,
    require_execution_capability,
)
from wilted.llm import create_backend
from wilted.pipeline_runner import HANDLERS, PipelineRunner, RunExitReason
from wilted.processing_jobs import record_job_completion, submit_job
from wilted.station_runtime.coordinator import RuntimeBootstrap


def _ready_bootstrap() -> RuntimeBootstrap:
    bootstrap = RuntimeBootstrap()
    bootstrap.init_tqdm_lock()
    return bootstrap


def _submit_classify_job(*, item_id: str) -> int:
    from wilted.background_work.idempotency import build_idempotency_key, logical_identity_for_kind

    identity = logical_identity_for_kind(JobKind.CLASSIFY, item_id=item_id)
    key = build_idempotency_key(JobKind.CLASSIFY, operation_version=1, logical_identity=identity)
    return submit_job(key).job_id


class TestGatedFactories:
    def test_create_backend_fails_without_capability(self) -> None:
        clear_execution_capability()
        with pytest.raises(ExecutionCapabilityError, match="PipelineRunner execution capability"):
            create_backend("mlx", model="test-model")

    def test_create_model_coordinator_fails_without_capability(self) -> None:
        clear_execution_capability()
        with pytest.raises(ExecutionCapabilityError, match="PipelineRunner execution capability"):
            create_model_coordinator()

    def test_gated_factories_succeed_inside_scope(self) -> None:
        clear_execution_capability()
        with execution_capability_scope(owner_id="scope-test", data_dir=wilted.DATA_DIR):
            coordinator = create_model_coordinator()
            backend = create_backend("mlx", model="test-model")
        coordinator.close()
        assert backend.model_name == "test-model"

    def test_dynamic_import_bypass_still_hits_gated_factory(self) -> None:
        clear_execution_capability()
        llm_mod = importlib.import_module("wilted.llm")
        factory = getattr(llm_mod, "create_backend")
        with pytest.raises(ExecutionCapabilityError, match="PipelineRunner execution capability"):
            factory("mlx", model="bypass-model")

    def test_issue_execution_capability_rejects_non_runner_caller(self) -> None:
        with pytest.raises(ExecutionCapabilityError, match="only be issued by PipelineRunner"):
            issue_execution_capability("rogue", wilted.DATA_DIR)


class TestPipelineRunnerCapability:
    def test_run_issues_capability_during_handlers(self) -> None:
        from wilted.background_work.contracts import ArtifactManifest

        _submit_classify_job(item_id="cap-during-handler")
        seen: list[str] = []

        def _capture_capability(job, coordinator) -> None:
            capability = require_execution_capability()
            seen.append(capability.owner_id)
            manifest = ArtifactManifest(
                item_id="42",
                input_digest="a" * 64,
                operation_version=1,
                output_digests=("b" * 64,),
                completeness_checks=("non_empty",),
            )
            record_job_completion(job.id, "cap-runner", manifest)

        runner = PipelineRunner(
            max_jobs_per_run=1,
            bootstrap=_ready_bootstrap(),
            handlers={**HANDLERS, JobKind.CLASSIFY: _capture_capability},
        )

        result = runner.run(owner_id="cap-runner")

        assert result.exit_reason is RunExitReason.COMPLETED
        assert seen == ["cap-runner"]
        clear_execution_capability()
        with pytest.raises(ExecutionCapabilityError):
            require_execution_capability()

    def test_run_clears_capability_after_close(self) -> None:
        runner = PipelineRunner(max_jobs_per_run=1, bootstrap=_ready_bootstrap())
        runner.run(owner_id="clear-runner")
        with pytest.raises(ExecutionCapabilityError):
            require_execution_capability()
