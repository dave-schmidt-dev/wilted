"""Tests for bounded PipelineRunner (Task 4.1)."""

from __future__ import annotations

import json
import signal
import threading
import time
from unittest.mock import MagicMock, patch

import wilted
from wilted.background_work.contracts import ArtifactManifest, JobKind, ProcessingJobState
from wilted.background_work.idempotency import build_idempotency_key, logical_identity_for_kind
from wilted.db import ProcessingJob
from wilted.pipeline_runner import (
    HANDLERS,
    PipelineRunner,
    RunExitReason,
    is_station_active,
)
from wilted.processing_jobs import (
    record_job_completion,
    submit_job,
    try_acquire_execution_lock,
)
from wilted.station_runtime.coordinator import ModelCoordinator, RuntimeBootstrap


def _ready_bootstrap() -> RuntimeBootstrap:
    bootstrap = RuntimeBootstrap()
    bootstrap.init_tqdm_lock()
    return bootstrap


def _classify_key(*, item_id: str) -> object:
    identity = logical_identity_for_kind(JobKind.CLASSIFY, item_id=item_id)
    return build_idempotency_key(JobKind.CLASSIFY, operation_version=1, logical_identity=identity)


def _submit_queued(*, item_id: str, kind: JobKind = JobKind.CLASSIFY) -> int:
    identity = logical_identity_for_kind(kind, item_id=item_id)
    key = build_idempotency_key(kind, operation_version=1, logical_identity=identity)
    return submit_job(key).job_id


def _manifest() -> ArtifactManifest:
    return ArtifactManifest(
        item_id="42",
        input_digest="a" * 64,
        operation_version=1,
        output_digests=("b" * 64,),
        completeness_checks=("non_empty",),
    )


class TestIsStationActive:
    def test_env_override(self, monkeypatch):
        monkeypatch.delenv("WILTED_STATION_ACTIVE", raising=False)
        assert is_station_active() is False
        monkeypatch.setenv("WILTED_STATION_ACTIVE", "1")
        assert is_station_active() is True


class TestPipelineRunnerLifecycle:
    def test_happy_path_with_fake_handler(self):
        job_id = _submit_queued(item_id="happy-path")

        def _complete(job, coordinator):
            assert isinstance(coordinator, ModelCoordinator)
            record_job_completion(job.id, "runner-test", _manifest())

        runner = PipelineRunner(
            max_jobs_per_run=4,
            bootstrap=_ready_bootstrap(),
            handlers={**HANDLERS, JobKind.CLASSIFY: _complete},
        )

        result = runner.run(owner_id="runner-test")

        assert result.exit_reason is RunExitReason.COMPLETED
        assert result.stats.submitted_handled == 1
        assert result.stats.failed == 0
        assert ProcessingJob.get_by_id(job_id).state == ProcessingJobState.COMPLETED.value

    def test_sigterm_sets_stop_flag_between_jobs(self):
        first = _submit_queued(item_id="stop-first")
        second = _submit_queued(item_id="stop-second")
        handled: list[int] = []
        runner_holder: list[PipelineRunner] = []

        def _mark_handled(job, coordinator):
            handled.append(job.id)
            if len(handled) == 1:
                runner_holder[0].inject_stop()

        runner = PipelineRunner(
            max_jobs_per_run=8,
            bootstrap=_ready_bootstrap(),
            handlers={**HANDLERS, JobKind.CLASSIFY: _mark_handled},
        )
        runner_holder.append(runner)

        result = runner.run(owner_id="runner-stop")

        assert result.exit_reason is RunExitReason.STOPPED
        assert handled == [first]
        assert ProcessingJob.get_by_id(first).state == ProcessingJobState.RUNNING.value
        assert ProcessingJob.get_by_id(second).state == ProcessingJobState.QUEUED.value

    def test_lock_busy_when_second_runner_tries_same_data_dir(self):
        _submit_queued(item_id="lock-busy")
        bootstrap = _ready_bootstrap()
        results: list = []
        errors: list[Exception] = []

        def _hold_and_run() -> None:
            try:
                with try_acquire_execution_lock(wilted.DATA_DIR):
                    inner = PipelineRunner(max_jobs_per_run=1, bootstrap=bootstrap)
                    results.append(inner.run(owner_id="inner"))
            except Exception as exc:  # pragma: no cover - surfaced via errors list
                errors.append(exc)

        holder = threading.Thread(target=_hold_and_run)
        holder.start()
        time.sleep(0.05)

        outer = PipelineRunner(max_jobs_per_run=1, bootstrap=bootstrap)
        results.append(outer.run(owner_id="outer"))

        holder.join(timeout=5.0)

        assert errors == []
        assert len(results) == 2
        assert sum(1 for result in results if result.exit_reason is RunExitReason.LOCK_BUSY) == 1
        assert sum(1 for result in results if result.exit_reason is RunExitReason.COMPLETED) == 1

    def test_station_active_yields_without_claiming(self):
        job_id = _submit_queued(item_id="yield-me")

        runner = PipelineRunner(
            bootstrap=_ready_bootstrap(),
            station_active_check=lambda: True,
        )

        result = runner.run(owner_id="yield-runner")

        assert result.exit_reason is RunExitReason.DEFERRED_YIELD
        assert result.stats.deferred_yield == 1
        assert result.stats.submitted_handled == 0
        assert ProcessingJob.get_by_id(job_id).state == ProcessingJobState.QUEUED.value

    def test_coordinator_constructed_once(self):
        _submit_queued(item_id="coord-once")
        init_spy = MagicMock(side_effect=ModelCoordinator.__init__)
        close_spy = MagicMock()

        class _SpyCoordinator(ModelCoordinator):
            def __init__(self, bootstrap):
                init_spy(bootstrap)

            def close(self) -> None:
                close_spy()

        runner = PipelineRunner(
            max_jobs_per_run=2,
            bootstrap=_ready_bootstrap(),
            coordinator_factory=lambda bootstrap: _SpyCoordinator(bootstrap),
        )

        result = runner.run(owner_id="coord-runner")

        assert result.exit_reason is RunExitReason.COMPLETED
        init_spy.assert_called_once()
        close_spy.assert_called_once()

    def test_close_called_on_success_and_handler_error(self):
        success_id = _submit_queued(item_id="close-success")
        fail_id = _submit_queued(item_id="close-fail")
        close_calls: list[str] = []

        class _TrackingCoordinator(ModelCoordinator):
            def __init__(self, bootstrap):
                super().__init__(bootstrap)

            def close(self) -> None:
                close_calls.append("closed")
                super().close()

        def _flaky(job, coordinator):
            if job.id == fail_id:
                raise RuntimeError("simulated handler failure")

        runner = PipelineRunner(
            max_jobs_per_run=2,
            bootstrap=_ready_bootstrap(),
            coordinator_factory=lambda bootstrap: _TrackingCoordinator(bootstrap),
            handlers={**HANDLERS, JobKind.CLASSIFY: _flaky},
        )

        result = runner.run(owner_id="close-runner")

        assert result.exit_reason is RunExitReason.COMPLETED
        assert result.stats.submitted_handled == 1
        assert result.stats.failed == 1
        assert close_calls == ["closed"]
        assert ProcessingJob.get_by_id(success_id).state == ProcessingJobState.RUNNING.value

    def test_handler_error_records_redacted_metadata(self):
        job_id = _submit_queued(item_id="handler-error")

        def _raise(job, coordinator):
            raise RuntimeError("boom")

        runner = PipelineRunner(
            max_jobs_per_run=1,
            bootstrap=_ready_bootstrap(),
            handlers={**HANDLERS, JobKind.CLASSIFY: _raise},
        )

        result = runner.run(owner_id="error-runner")

        assert result.exit_reason is RunExitReason.COMPLETED
        assert result.stats.failed == 1
        job = ProcessingJob.get_by_id(job_id)
        assert job.state == ProcessingJobState.RETRY.value
        assert job.error_json is not None
        payload = json.loads(job.error_json)
        assert payload["error_type"] == "RuntimeError"
        assert payload["message"] == "boom"
        assert "Traceback" not in job.error_json

    def test_run_never_raises_to_caller(self):
        runner = PipelineRunner(bootstrap=_ready_bootstrap())

        with patch.object(
            PipelineRunner,
            "_run_under_lock",
            side_effect=RuntimeError("outer failure"),
        ):
            result = runner.run(owner_id="safe-runner")

        assert result.exit_reason is RunExitReason.ERROR

    def test_respects_max_jobs_per_run(self):
        for index in range(3):
            _submit_queued(item_id=f"batch-{index}")

        seen: list[int] = []

        def _mark(job, coordinator):
            seen.append(job.id)

        runner = PipelineRunner(
            max_jobs_per_run=2,
            bootstrap=_ready_bootstrap(),
            handlers={**HANDLERS, JobKind.CLASSIFY: _mark},
        )

        result = runner.run(owner_id="batch-runner")

        assert result.exit_reason is RunExitReason.COMPLETED
        assert result.stats.submitted_handled == 2
        assert len(seen) == 2
        assert ProcessingJob.select().where(ProcessingJob.state == ProcessingJobState.RUNNING.value).count() == 2
        assert ProcessingJob.select().where(ProcessingJob.state == ProcessingJobState.QUEUED.value).count() == 1


class TestInstallSignalHandlersOffMain:
    """BUG-2 regression: the TUI now drains the article-cache runner from a
    Textual ``@work(thread=True)`` worker thread (``WiltedApp._submit_article_cache_worker``
    -> ``_drain_article_cache_runner`` -> ``PipelineRunner.run``/``_run_under_lock``
    -> ``_install_signal_handlers``). ``signal.signal()`` only works on the
    main thread and raises ``ValueError: signal only works in main thread``
    if called off it, which would crash the worker. ``_install_signal_handlers``
    must detect the off-main case and skip installation entirely.
    """

    def test_install_signal_handlers_off_main_thread_is_noop(self):
        """Calling ``_install_signal_handlers`` from a worker thread must not
        raise, and must install nothing (empty mapping) rather than calling
        ``signal.signal()`` off the main thread."""
        runner = PipelineRunner(bootstrap=_ready_bootstrap())
        results: list[dict] = []
        errors: list[BaseException] = []

        def _call_off_main() -> None:
            try:
                results.append(runner._install_signal_handlers())
            except BaseException as exc:  # noqa: BLE001 - capture for assertion below
                errors.append(exc)

        thread = threading.Thread(target=_call_off_main)
        thread.start()
        thread.join(timeout=5.0)

        assert errors == [], f"_install_signal_handlers raised off-main: {errors}"
        assert results == [{}]

    def test_install_signal_handlers_on_main_thread_installs_handlers(self):
        """On the main thread, installation still works and returns the
        previous SIGTERM/SIGHUP handlers so a caller can restore them."""
        runner = PipelineRunner(bootstrap=_ready_bootstrap())

        previous = runner._install_signal_handlers()
        try:
            assert previous != {}
            assert set(previous) == {signal.SIGTERM, signal.SIGHUP}
        finally:
            # Restore immediately so this test never leaks handlers into the
            # rest of the suite.
            runner._restore_signal_handlers(previous)

    def test_run_from_worker_thread_with_no_runnable_jobs(self):
        """Fuller regression: a complete ``PipelineRunner.run()`` invocation
        executed entirely from a worker thread (mirroring the TUI's off-main
        article-cache drain) must not raise, exactly like the focused
        ``_install_signal_handlers`` test above but exercising the real call
        path a worker thread takes. No queued jobs means ``_claim_next_job_under_lock``
        returns ``None`` immediately, so no handler/coordinator work (and no
        real model load, no speech daemon) is required for this to be a
        meaningful off-main exercise of the signal-install guard.
        """
        runner = PipelineRunner(bootstrap=_ready_bootstrap())
        results: list = []
        errors: list[BaseException] = []

        def _run_off_main() -> None:
            try:
                results.append(runner.run(owner_id="off-main-runner"))
            except BaseException as exc:  # noqa: BLE001 - capture for assertion below
                errors.append(exc)

        thread = threading.Thread(target=_run_off_main)
        thread.start()
        thread.join(timeout=5.0)

        assert errors == [], f"PipelineRunner.run() raised off-main: {errors}"
        assert len(results) == 1
        assert results[0].exit_reason is RunExitReason.COMPLETED
        assert results[0].stats.submitted_handled == 0
