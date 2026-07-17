"""Tests for classify/prepare pipeline handlers and CLI runner routing (Task 5.1)."""

from __future__ import annotations

import ast
import inspect
import textwrap
from datetime import UTC, datetime

import pytest

import wilted
from wilted.background_work.contracts import JobKind, ProcessingJobState
from wilted.background_work.idempotency import build_idempotency_key, logical_identity_for_kind
from wilted.cli import cmd_classify
from wilted.db import Item, ProcessingJob
from wilted.pipeline_runner import PipelineRunner, RunExitReason, RunStats
from wilted.pipeline_submit import submit_prepare
from wilted.processing_jobs import submit_job
from wilted.station_runtime.coordinator import RuntimeBootstrap

pytestmark = [pytest.mark.integration, pytest.mark.usefixtures("execution_capability")]


def _now() -> str:
    return datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def _ready_bootstrap() -> RuntimeBootstrap:
    bootstrap = RuntimeBootstrap()
    bootstrap.init_tqdm_lock()
    return bootstrap


def _submit_classify_job(*, item_id: int) -> int:
    identity = logical_identity_for_kind(JobKind.CLASSIFY, item_id=str(item_id))
    key = build_idempotency_key(JobKind.CLASSIFY, operation_version=1, logical_identity=identity)
    return submit_job(key, item_id=item_id).job_id


class _MockLLMBackend:
    """Minimal LLM backend for handler integration tests."""

    def load(self) -> None:
        return None

    def generate(self, system_prompt: str, user_content: str) -> tuple[str, int]:
        del system_prompt, user_content
        return (
            '{"playlist": "Work", "relevance_score": 0.8, "summary": "Test summary."}',
            12,
        )

    def close(self) -> None:
        return None


def _make_fetched_item(*, text: str = "Article body for classification.") -> Item:
    transcript = wilted.ARTICLES_DIR / "handler-classify.txt"
    transcript.write_text(text, encoding="utf-8")
    return Item.create(
        guid=f"handler-classify-{id(object())}",
        title="Handler Classify Item",
        discovered_at=_now(),
        item_type="article",
        status="fetched",
        status_changed_at=_now(),
        transcript_file=str(transcript),
    )


def _make_selected_item(*, text: str = "Article body for preparation.") -> Item:
    transcript = wilted.ARTICLES_DIR / "handler-prepare.txt"
    transcript.write_text(text, encoding="utf-8")
    return Item.create(
        guid=f"handler-prepare-{id(object())}",
        title="Handler Prepare Item",
        discovered_at=_now(),
        item_type="article",
        status="selected",
        status_changed_at=_now(),
        transcript_file=str(transcript),
    )


class TestCliRunnerRouting:
    def test_cmd_classify_goes_through_via_runner(self, monkeypatch) -> None:
        """``cmd_classify`` dispatches to ``run_classify_via_runner``."""
        called = {"value": False}

        def _spy(**kwargs):
            called["value"] = True
            return {"classified": 0, "errors": 0, "total": 0}

        monkeypatch.setattr("wilted.pipeline_submit.run_classify_via_runner", _spy)
        cmd_classify([])
        assert called["value"] is True

    def test_cmd_classify_drains_runner_when_work_exists(self, monkeypatch) -> None:
        """``run_classify_via_runner`` invokes runner drain when classification work exists."""
        _make_fetched_item()
        drained: list[str] = []

        def _spy_drain(**kwargs):
            drained.append("drain")
            from wilted.pipeline_runner import RunStats

            return RunStats()

        monkeypatch.setattr("wilted.handlers.classify.create_backend", lambda *args, **kwargs: _MockLLMBackend())
        monkeypatch.setattr("wilted.pipeline_submit.drain_runner", _spy_drain)

        from wilted.pipeline_submit import run_classify_via_runner

        run_classify_via_runner(model="test", backend_type="gguf")

        assert drained == ["drain"]


class TestClassifyHandler:
    def test_handle_classify_processes_item_end_to_end(self, monkeypatch) -> None:
        """Classify handler completes one item with fake LLM backends."""
        item = _make_fetched_item()
        job_id = _submit_classify_job(item_id=item.id)
        monkeypatch.setattr("wilted.handlers.classify.create_backend", lambda *args, **kwargs: _MockLLMBackend())

        runner = PipelineRunner(max_jobs_per_run=1, bootstrap=_ready_bootstrap())
        result = runner.run(owner_id="handler-classify")

        assert result.exit_reason is RunExitReason.COMPLETED
        assert result.stats.submitted_handled == 1
        job = ProcessingJob.get_by_id(job_id)
        assert job.state == ProcessingJobState.COMPLETED.value
        item = Item.get_by_id(item.id)
        assert item.playlist_assigned == "Work"
        assert item.summary == "Test summary."


class TestPrepareHandlerIsolation:
    def test_prepare_one_item_failure_does_not_abort_sibling(self, monkeypatch, tmp_path) -> None:
        """One failing prepare job does not prevent a sibling from completing."""
        good = _make_selected_item(text="Good article body.")
        bad = _make_selected_item(text="Bad article body.")
        bad.transcript_file = str(tmp_path / "missing.txt")
        bad.save()

        monkeypatch.setattr("wilted.cache.generate_article_cache", lambda *args, **kwargs: True)

        submit_prepare(good.id, use_llm=False, skip_tts=True, sync_run=False)
        submit_prepare(bad.id, use_llm=False, skip_tts=False, sync_run=False)

        runner = PipelineRunner(max_jobs_per_run=4, bootstrap=_ready_bootstrap())
        result = runner.run(owner_id="handler-prepare")

        assert result.exit_reason is RunExitReason.COMPLETED
        assert result.stats.submitted_handled == 2

        good_job = ProcessingJob.get(
            ProcessingJob.kind == JobKind.PREPARE.value,
            ProcessingJob.item_id == good.id,
        )
        bad_job = ProcessingJob.get(
            ProcessingJob.kind == JobKind.PREPARE.value,
            ProcessingJob.item_id == bad.id,
        )
        assert good_job.state == ProcessingJobState.COMPLETED.value
        assert bad_job.state == ProcessingJobState.COMPLETED.value

        good_item = Item.get_by_id(good.id)
        bad_item = Item.get_by_id(bad.id)
        assert good_item.preparation_state == "ready"
        assert bad_item.preparation_state == "error"


class TestArticleCacheHandler:
    def test_handle_article_cache_completes_item(self, monkeypatch) -> None:
        """Article-cache handler generates cache and records completion."""
        from unittest.mock import MagicMock

        import numpy as np

        from wilted.background_work.idempotency import build_idempotency_key, logical_identity_for_kind
        from wilted.cache import is_cache_valid
        from wilted.pipeline_submit import submit_article_cache
        from wilted.queue import add_article

        entry = add_article("Paragraph one.\n\nParagraph two.", title="Cache Handler Item")
        added = entry["added"]
        item_id = entry["id"]

        engine = MagicMock()
        engine.sample_rate = 24000
        engine.generate_audio.return_value = np.zeros(24000, dtype=np.float32)
        monkeypatch.setattr("wilted.handlers.article_cache.AudioEngine", lambda **kwargs: engine)
        monkeypatch.setattr("mlx_audio.audio_io.write", lambda *args, **kwargs: None)

        submit_article_cache(
            item_id,
            voice="af_heart",
            lang="a",
            speed=1.0,
            added=added,
            sync_run=False,
        )

        runner = PipelineRunner(max_jobs_per_run=1, bootstrap=_ready_bootstrap())
        result = runner.run(owner_id="handler-article-cache")

        assert result.exit_reason is RunExitReason.COMPLETED
        assert result.stats.submitted_handled == 1
        assert is_cache_valid(item_id, "af_heart", "a", 1.0, added)

        identity = logical_identity_for_kind(JobKind.ARTICLE_CACHE, item_id=str(item_id))
        key = build_idempotency_key(JobKind.ARTICLE_CACHE, operation_version=1, logical_identity=identity)
        job = ProcessingJob.get(ProcessingJob.idempotency_key == key.canonical)
        assert job.state == ProcessingJobState.COMPLETED.value


class TestRunEntrypointsDoNotConstructCoordinator:
    @pytest.mark.parametrize("module_name", ["wilted.classify", "wilted.prepare"])
    def test_run_functions_do_not_call_create_model_coordinator(self, module_name: str) -> None:
        """``run_classify`` / ``run_prepare`` must not construct coordinators directly."""
        import importlib

        module = importlib.import_module(module_name)
        for name in ("run_classify", "run_prepare"):
            if not hasattr(module, name):
                continue
            source = textwrap.dedent(inspect.getsource(getattr(module, name)))
            tree = ast.parse(source)
            for node in ast.walk(tree):
                if isinstance(node, ast.Call) and isinstance(node.func, ast.Name):
                    assert node.func.id != "create_model_coordinator", (
                        f"{module_name}.{name} must not call create_model_coordinator()"
                    )

    def test_run_classify_requires_coordinator_and_backend_arguments(self) -> None:
        """Direct ``run_classify`` without coordinator/backend is a signature error."""
        from wilted.classify import run_classify

        with pytest.raises(TypeError):
            run_classify(model="test", backend_type="gguf")

    def test_run_prepare_requires_coordinator_and_factory_arguments(self) -> None:
        """Direct ``run_prepare`` without coordinator/factory is a signature error."""
        from wilted.prepare import run_prepare

        with pytest.raises((TypeError, ValueError)):
            run_prepare(use_llm=False, skip_tts=True)


def test_run_article_cache_via_runner_submits_without_typeerror(monkeypatch) -> None:
    """Regression: ``run_article_cache_via_runner`` passed ``sync_run=False`` to
    ``submit_pending_article_cache_jobs`` (which has no such parameter), so the
    entry point raised ``TypeError`` on every non-empty-queue call before any
    work was done. Collaborators are stubbed so the contract is exercised without
    a model load or DB write.
    """
    from wilted import pipeline_submit

    submitted: list[int] = []
    drained: list[dict] = []
    monkeypatch.setattr(
        pipeline_submit,
        "items_needing_article_cache",
        lambda *, voice, lang, speed: [{"id": 1, "added": ""}],
    )
    monkeypatch.setattr(
        pipeline_submit,
        "submit_article_cache",
        lambda item_id, **_kwargs: submitted.append(item_id),
    )
    monkeypatch.setattr(pipeline_submit, "drain_runner", lambda **kwargs: drained.append(kwargs))
    monkeypatch.setattr(
        pipeline_submit,
        "_article_cache_stats_for_entries",
        lambda entries, **_kwargs: {"cached": 0, "errors": 0, "total": len(entries)},
    )

    result = pipeline_submit.run_article_cache_via_runner(voice="af_heart", lang="a", speed=1.0)

    assert result == {"cached": 0, "errors": 0, "total": 1}
    assert submitted == [1]  # submit_pending_article_cache_jobs ran with a valid kwarg set
    # The entry point must actually drain what it submitted — instrument the stub so
    # the regression can't pass if the submit→drain path silently stops draining.
    assert drained, "run_article_cache_via_runner must drain the runner after submitting jobs"


class TestSpeechReadyPolicy:
    def test_non_speech_kinds(self) -> None:
        from wilted.speech_ready import job_requires_speech

        for kind in (JobKind.DISCOVER, JobKind.CLASSIFY, JobKind.REPORT_ASSEMBLY):
            assert job_requires_speech(kind=kind) is False

    def test_speech_kinds(self) -> None:
        from wilted.speech_ready import job_requires_speech

        for kind in (JobKind.ARTICLE_CACHE, JobKind.COMPACT_BRIEFING):
            assert job_requires_speech(kind=kind) is True

    def test_prepare_article_skip_tts_is_non_speech(self) -> None:
        from wilted.speech_ready import job_requires_speech

        assert (
            job_requires_speech(
                kind=JobKind.PREPARE,
                checkpoint_json='{"skip_tts": true}',
                item_type="article",
            )
            is False
        )

    def test_prepare_article_normal_is_speech(self) -> None:
        from wilted.speech_ready import job_requires_speech

        assert (
            job_requires_speech(
                kind=JobKind.PREPARE,
                checkpoint_json='{"skip_tts": false}',
                item_type="article",
            )
            is True
        )

    def test_prepare_podcast_is_speech_even_with_skip_tts(self) -> None:
        from wilted.speech_ready import job_requires_speech

        assert (
            job_requires_speech(
                kind=JobKind.PREPARE,
                checkpoint_json='{"skip_tts": true}',
                item_type="podcast_episode",
            )
            is True
        )


def _submit_kind_job(
    *,
    kind: JobKind,
    item_id: int | None = None,
    metadata: dict | None = None,
) -> int:
    if kind is JobKind.DISCOVER:
        identity = logical_identity_for_kind(kind, feed_id=1)
    elif kind is JobKind.REPORT_ASSEMBLY:
        identity = logical_identity_for_kind(kind, report_date="2026-07-17")
    elif kind is JobKind.COMPACT_BRIEFING:
        identity = logical_identity_for_kind(kind, window_start="2026-07-17", window_end="2026-07-17")
    else:
        assert item_id is not None
        identity = logical_identity_for_kind(kind, item_id=str(item_id))
    key = build_idempotency_key(kind, operation_version=1, logical_identity=identity)
    return submit_job(key, item_id=item_id, metadata=metadata).job_id


def _make_podcast_item() -> Item:
    transcript = wilted.ARTICLES_DIR / "handler-podcast.txt"
    transcript.write_text("Podcast transcript.", encoding="utf-8")
    return Item.create(
        guid=f"handler-podcast-{id(object())}",
        title="Handler Podcast Item",
        discovered_at=_now(),
        item_type="podcast_episode",
        status="selected",
        status_changed_at=_now(),
        transcript_file=str(transcript),
    )


def _stub_runner_run(**_kwargs):
    return type("R", (), {"stats": RunStats(), "exit_reason": RunExitReason.COMPLETED})()


def _stub_runner_run_deferred(**_kwargs):
    return type(
        "R",
        (),
        {
            "stats": RunStats(deferred_yield=1),
            "exit_reason": RunExitReason.DEFERRED_YIELD,
        },
    )()


class TestDrainRunnerSpeechReadiness:
    def test_non_speech_cohorts_skip_readiness(self, monkeypatch) -> None:
        from unittest.mock import MagicMock

        from wilted.pipeline_submit import drain_runner

        ready = MagicMock()
        monkeypatch.setattr("wilted.pipeline_submit.require_speech_ready", ready)
        monkeypatch.setattr("wilted.pipeline_submit.PipelineRunner.run", lambda self, **kwargs: _stub_runner_run())

        item = _make_fetched_item()
        for kind in (JobKind.CLASSIFY, JobKind.DISCOVER, JobKind.REPORT_ASSEMBLY):
            ready.reset_mock()
            _submit_kind_job(kind=kind, item_id=item.id if kind is JobKind.CLASSIFY else None)
            drain_runner(kind=kind, max_jobs_per_run=1)
            ready.assert_not_called()

    def test_skip_tts_article_prepare_skips_readiness(self, monkeypatch) -> None:
        from unittest.mock import MagicMock

        from wilted.pipeline_submit import drain_runner

        item = _make_selected_item()
        submit_prepare(item.id, use_llm=False, skip_tts=True, sync_run=False)

        ready = MagicMock()
        monkeypatch.setattr("wilted.pipeline_submit.require_speech_ready", ready)
        monkeypatch.setattr("wilted.pipeline_submit.PipelineRunner.run", lambda self, **kwargs: _stub_runner_run())

        drain_runner(kind=JobKind.PREPARE, max_jobs_per_run=1)
        ready.assert_not_called()

    @pytest.mark.parametrize(
        "setup",
        [
            "article_cache",
            "compact_briefing",
            "article_prepare",
            "podcast_prepare",
        ],
    )
    def test_speech_cohorts_gate_once(self, monkeypatch, setup: str) -> None:
        from unittest.mock import MagicMock

        from wilted.pipeline_submit import drain_runner

        ready = MagicMock()
        monkeypatch.setattr("wilted.pipeline_submit.require_speech_ready", ready)
        monkeypatch.setattr("wilted.pipeline_submit.PipelineRunner.run", lambda self, **kwargs: _stub_runner_run())

        if setup == "article_cache":
            item = _make_selected_item()
            _submit_kind_job(kind=JobKind.ARTICLE_CACHE, item_id=item.id, metadata={"voice": "af_heart"})
            drain_runner(kind=JobKind.ARTICLE_CACHE, max_jobs_per_run=1)
        elif setup == "compact_briefing":
            _submit_kind_job(kind=JobKind.COMPACT_BRIEFING, metadata={"window_start": "2026-07-17"})
            drain_runner(kind=JobKind.COMPACT_BRIEFING, max_jobs_per_run=1)
        elif setup == "article_prepare":
            item = _make_selected_item()
            submit_prepare(item.id, use_llm=False, skip_tts=False, sync_run=False)
            drain_runner(kind=JobKind.PREPARE, max_jobs_per_run=1)
        else:
            item = _make_podcast_item()
            submit_prepare(item.id, use_llm=False, skip_tts=True, sync_run=False)
            drain_runner(kind=JobKind.PREPARE, max_jobs_per_run=1)

        ready.assert_called_once()

    def test_multiple_speech_jobs_probe_once(self, monkeypatch) -> None:
        from unittest.mock import MagicMock

        from wilted.pipeline_submit import drain_runner

        item_a = _make_selected_item(text="Cache A.")
        item_b = _make_selected_item(text="Cache B.")
        _submit_kind_job(kind=JobKind.ARTICLE_CACHE, item_id=item_a.id, metadata={"voice": "af_heart"})
        _submit_kind_job(kind=JobKind.ARTICLE_CACHE, item_id=item_b.id, metadata={"voice": "af_heart"})

        ready = MagicMock()
        monkeypatch.setattr("wilted.pipeline_submit.require_speech_ready", ready)
        monkeypatch.setattr("wilted.pipeline_submit.PipelineRunner.run", lambda self, **kwargs: _stub_runner_run())

        drain_runner(kind=JobKind.ARTICLE_CACHE, max_jobs_per_run=4)
        ready.assert_called_once()

    def test_readiness_failure_leaves_jobs_unchanged(self, monkeypatch) -> None:
        from speech_stack import client

        from wilted.pipeline_submit import drain_runner

        item = _make_selected_item()
        job_id = _submit_kind_job(kind=JobKind.ARTICLE_CACHE, item_id=item.id, metadata={"voice": "af_heart"})
        before = ProcessingJob.get_by_id(job_id)

        monkeypatch.setattr(
            "wilted.pipeline_submit.require_speech_ready",
            lambda: (_ for _ in ()).throw(client.DaemonUnavailable("down")),
        )

        with pytest.raises(client.DaemonUnavailable):
            drain_runner(kind=JobKind.ARTICLE_CACHE, max_jobs_per_run=1)

        after = ProcessingJob.get_by_id(job_id)
        assert after.state == before.state == ProcessingJobState.QUEUED.value
        assert after.attempt_count == before.attempt_count == 0

    def test_station_active_deferral_skips_readiness(self, monkeypatch) -> None:
        from unittest.mock import MagicMock

        from wilted.pipeline_submit import drain_runner

        item = _make_selected_item()
        _submit_kind_job(kind=JobKind.ARTICLE_CACHE, item_id=item.id, metadata={"voice": "af_heart"})

        ready = MagicMock()
        monkeypatch.setattr("wilted.pipeline_submit.require_speech_ready", ready)
        monkeypatch.setattr(
            "wilted.pipeline_submit.PipelineRunner.run", lambda self, **kwargs: _stub_runner_run_deferred()
        )

        drain_runner(
            kind=JobKind.ARTICLE_CACHE,
            max_jobs_per_run=1,
            station_active_check=lambda: True,
        )
        ready.assert_not_called()

    def test_empty_drain_skips_readiness(self, monkeypatch) -> None:
        from unittest.mock import MagicMock

        from wilted.pipeline_submit import drain_runner

        ready = MagicMock()
        monkeypatch.setattr("wilted.pipeline_submit.require_speech_ready", ready)

        drain_runner(kind=JobKind.ARTICLE_CACHE, max_jobs_per_run=1)
        ready.assert_not_called()

    def test_not_yet_due_speech_job_skips_drain_and_readiness(self, monkeypatch) -> None:
        """Future not_before jobs are not claimable — drain must not probe or run."""
        from unittest.mock import MagicMock

        from wilted.background_work.idempotency import build_idempotency_key, logical_identity_for_kind
        from wilted.pipeline_submit import drain_runner

        item = _make_selected_item()
        identity = logical_identity_for_kind(JobKind.ARTICLE_CACHE, item_id=str(item.id))
        key = build_idempotency_key(JobKind.ARTICLE_CACHE, operation_version=1, logical_identity=identity)
        submit_job(
            key,
            item_id=item.id,
            metadata={"voice": "af_heart"},
            not_before="2099-01-01T00:00:00Z",
        )

        ready = MagicMock()
        runner_cls = MagicMock()
        monkeypatch.setattr("wilted.pipeline_submit.require_speech_ready", ready)
        monkeypatch.setattr("wilted.pipeline_submit.PipelineRunner", runner_cls)

        stats = drain_runner(kind=JobKind.ARTICLE_CACHE, max_jobs_per_run=1)
        ready.assert_not_called()
        runner_cls.assert_not_called()
        assert stats.submitted_handled == 0
