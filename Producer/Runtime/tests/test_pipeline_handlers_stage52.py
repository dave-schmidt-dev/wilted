"""Tests for discover/report/briefing pipeline handlers (Task 5.2)."""

from __future__ import annotations

import logging
from datetime import UTC, date, datetime, timedelta
from unittest.mock import MagicMock

import pytest

import wilted
from wilted.background_work.contracts import (
    AnalysisState,
    JobKind,
    PreparationState,
    ProcessingJobState,
    ReportDecision,
    SubmissionOutcome,
)
from wilted.background_work.idempotency import build_idempotency_key, logical_identity_for_kind
from wilted.briefing_artifacts import load_newest_owed_briefing
from wilted.content_state import load_report_membership, read_content_state
from wilted.db import Item, ProcessingJob, Report
from wilted.feeds import add_feed
from wilted.pipeline_runner import PipelineRunner, RunExitReason
from wilted.pipeline_submit import (
    _discover_metadata,
    _submit_fresh_generation,
    items_needing_article_cache,
    run_classify_via_runner,
    run_discover_via_runner,
    run_prepare_via_runner,
    submit_article_cache,
    submit_briefing,
    submit_classify,
    submit_discover,
    submit_pending_article_cache_jobs,
    submit_prepare,
    submit_report,
)
from wilted.processing_jobs import get_job, submit_job, transition_job_state
from wilted.queue import add_article
from wilted.station_runtime.briefing import Briefing, BriefingAudio, BriefingItem
from wilted.station_runtime.coordinator import RuntimeBootstrap

pytestmark = [pytest.mark.integration, pytest.mark.usefixtures("execution_capability")]


def _now() -> str:
    return datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def _ready_bootstrap() -> RuntimeBootstrap:
    bootstrap = RuntimeBootstrap()
    bootstrap.init_tqdm_lock()
    return bootstrap


class _StubLLMBackend:
    """Minimal LLM backend for the classify submit-isolation test below.

    Returns a fixed, always-valid classification payload — content doesn't
    matter here, only that ``submit_classify``/the classify handler completes
    without a real model.
    """

    def load(self) -> None:
        return None

    def generate(self, system_prompt: str, user_content: str) -> tuple[str, int]:
        del system_prompt, user_content
        return ('{"playlist": "Work", "relevance_score": 0.8, "summary": "Test summary."}', 12)

    def close(self) -> None:
        return None


def _make_fetched_item_for_classify(*, suffix: str, text: str) -> Item:
    """Insert a fetched item ready for classification.

    Uses an explicit ``suffix`` (not ``id(object())``, which CPython can and
    does reuse across back-to-back calls once each temporary is
    garbage-collected — verified empirically) so three items created in one
    test never collide on ``guid`` or on-disk transcript path.
    """
    transcript = wilted.ARTICLES_DIR / f"stage52-classify-{suffix}.txt"
    transcript.write_text(text, encoding="utf-8")
    return Item.create(
        guid=f"stage52-classify-{suffix}",
        title=f"Stage52 Classify Item {suffix}",
        discovered_at=_now(),
        item_type="article",
        status="fetched",
        status_changed_at=_now(),
        transcript_file=str(transcript),
    )


def _make_selected_item_for_prepare(*, suffix: str, text: str) -> Item:
    """Insert a selected item ready for preparation. See ``suffix`` note above."""
    transcript = wilted.ARTICLES_DIR / f"stage52-prepare-{suffix}.txt"
    transcript.write_text(text, encoding="utf-8")
    return Item.create(
        guid=f"stage52-prepare-{suffix}",
        title=f"Stage52 Prepare Item {suffix}",
        discovered_at=_now(),
        item_type="article",
        status="selected",
        status_changed_at=_now(),
        transcript_file=str(transcript),
    )


def _has_warning_with_traceback(caplog: pytest.LogCaptureFixture, *, logger_name: str, needle: str) -> bool:
    """True iff a WARNING record from ``logger_name`` naming ``needle`` carries
    a real ``exc_info`` traceback — i.e. was logged from inside an ``except``
    block with ``exc_info=True``, not just a bare message."""
    return any(
        record.levelname == "WARNING"
        and record.name == logger_name
        and needle in record.getMessage()
        and record.exc_info is not None
        for record in caplog.records
    )


def _assert_classify_stats_truthful(stats: dict, *, total_items: int) -> None:
    """The B1 accounting invariant for ``run_classify_via_runner`` (INV-6).

    Every submitted item lands in exactly one of classified/errors/
    submission_errors, and a failed submission is named (``submission_errors
    >= 1``), never vanished. Indexes ``stats["submission_errors"]`` directly —
    no ``.get`` default — so the pre-B1 shape (which lacks the key entirely)
    fails loudly instead of silently reading as zero.
    """
    assert stats["total"] == total_items
    assert stats["total"] == stats["classified"] + stats["errors"] + stats["submission_errors"]
    assert stats["submission_errors"] >= 1


def _assert_prepare_stats_truthful(stats: dict, *, total_items: int) -> None:
    """The B1 accounting invariant for ``run_prepare_via_runner`` (INV-6). See
    ``_assert_classify_stats_truthful`` above for the rationale."""
    assert total_items == stats["prepared"] + stats["errors"] + stats["skipped"] + stats["submission_errors"]
    assert stats["submission_errors"] >= 1


def _assert_article_cache_isolation_truthful(*, submitted: int, total_entries: int, failed_still_pending: bool) -> None:
    """The B2 accounting invariant for ``submit_pending_article_cache_jobs``
    (INV-6). There is no dedicated ``submission_errors`` counter here — per
    B2, ``_article_cache_stats_for_entries`` already derives ``errors`` from
    cache validity — so truthfulness means: the loop isn't aborted by one
    failure (the rest still submit), and the failed entry is never counted as
    if it had succeeded — it must still show up as pending, not vanish.
    """
    assert submitted == total_entries - 1
    assert failed_still_pending, "failed entry must remain visible as still needing cache, not vanish"


def _run_job(kind: JobKind, **identity_kwargs) -> None:
    if kind is JobKind.DISCOVER:
        identity = logical_identity_for_kind(kind, feed_id=identity_kwargs["feed_id"])
        metadata = {"feed_id": identity_kwargs["feed_id"], "operation_version": 1}
    elif kind is JobKind.REPORT_ASSEMBLY:
        identity = logical_identity_for_kind(kind, report_date=identity_kwargs["report_date"])
        metadata = {"report_date": identity_kwargs["report_date"], "operation_version": 1}
    else:
        identity = logical_identity_for_kind(
            kind,
            window_start=identity_kwargs["window_start"],
            window_end=identity_kwargs["window_end"],
        )
        metadata = {
            "window_start": identity_kwargs["window_start"],
            "window_end": identity_kwargs["window_end"],
            "operation_version": 1,
        }
    key = build_idempotency_key(kind, operation_version=1, logical_identity=identity)
    submit_job(key, metadata=metadata)
    runner = PipelineRunner(bootstrap=_ready_bootstrap(), max_jobs_per_run=4)
    result = runner.run()
    assert result.exit_reason is RunExitReason.COMPLETED


class TestDiscoverHandler:
    def test_polls_feed_without_auto_selecting_podcast(self, monkeypatch) -> None:
        feed = add_feed("https://example.com/podcast.xml", feed_type="podcast")
        stats = {"new": 1, "skipped": 0, "errors": 0}
        monkeypatch.setattr("wilted.handlers.discover._poll_feed", lambda f: stats if f.id == feed.id else stats)

        submit_discover(feed.id, sync_run=False)
        _run_job(JobKind.DISCOVER, feed_id=feed.id)

        job = ProcessingJob.get()
        assert job.state == ProcessingJobState.COMPLETED.value
        assert job.kind == JobKind.DISCOVER.value


def _submit_discover_for_run_date(feed_id: int, run_date: str):
    """Mirror ``submit_discover``'s body with an explicit ``run_date``.

    ``submit_discover`` always resolves "today" itself (real nightly callers
    never need anything else), so it cannot be parameterized by date directly.
    This drives the exact same primitives it's built from —
    :func:`logical_identity_for_kind` and :func:`_submit_fresh_generation` —
    to simulate rolling calendar days deterministically, without monkeypatching
    global date-resolution state (fragile — see module-reload interaction in
    ``TestSubstrateNeutrality.test_importing_package_does_not_pull_in_forbidden_modules``).
    """
    identity = logical_identity_for_kind(JobKind.DISCOVER, feed_id=feed_id, run_date=run_date)

    def _key_for_version(version: int):
        return build_idempotency_key(JobKind.DISCOVER, operation_version=version, logical_identity=identity)

    return _submit_fresh_generation(_key_for_version, metadata=_discover_metadata(feed_id=feed_id))


class TestDiscoverIdentityRollingDates:
    """Regression coverage for the permanent-identity version-walk exhaustion bug.

    Before T1.1, DISCOVER's logical identity was the undated ``feed:{feed_id}``.
    Every nightly run bumped ``operation_version`` past the prior day's terminal
    ``completed`` row, so after ~64 nightly runs the ``_submit_fresh_generation``
    walk (``range(1, 65)``) exhausted and raised ``RuntimeError`` — permanently
    killing discovery for that feed. With a ``run_date`` component in the
    identity, each day is a distinct identity and always resolves at v1.
    """

    def test_rolling_daily_submissions_never_exhaust_version_walk(self) -> None:
        feed = add_feed("https://example.com/rolling.xml", feed_type="podcast")
        base = date(2026, 1, 1)
        num_days = 120

        for offset in range(num_days):
            current = (base + timedelta(days=offset)).isoformat()

            result = _submit_discover_for_run_date(feed.id, current)

            assert result.outcome is SubmissionOutcome.SUBMITTED
            assert result.idempotency_key == f"discover:v1:feed:{feed.id}:{current}"

            # Mark the day's job completed, as a real nightly ingest run would,
            # so the next iteration's submission truly starts from a fresh
            # per-date identity rather than an unexercised row.
            job = get_job(result.job_id)
            assert transition_job_state(job.id, ProcessingJobState.QUEUED, ProcessingJobState.RUNNING)
            assert transition_job_state(job.id, ProcessingJobState.RUNNING, ProcessingJobState.COMPLETED)

        assert ProcessingJob.select().count() == num_days

    def test_same_day_resubmission_after_completion_still_climbs_version(self) -> None:
        """The per-date version walk is preserved, not removed — it just resets daily."""
        feed = add_feed("https://example.com/same-day.xml", feed_type="podcast")
        today = date(2026, 3, 15).isoformat()

        first = _submit_discover_for_run_date(feed.id, today)
        assert first.idempotency_key == f"discover:v1:feed:{feed.id}:{today}"
        job = get_job(first.job_id)
        assert transition_job_state(job.id, ProcessingJobState.QUEUED, ProcessingJobState.RUNNING)
        assert transition_job_state(job.id, ProcessingJobState.RUNNING, ProcessingJobState.COMPLETED)

        second = _submit_discover_for_run_date(feed.id, today)
        assert second.outcome is SubmissionOutcome.SUBMITTED
        assert second.idempotency_key == f"discover:v2:feed:{feed.id}:{today}"


class TestRunDiscoverViaRunner:
    def test_reports_real_nonzero_discovered_count_on_seeded_feed(self, monkeypatch) -> None:
        feed = add_feed("https://example.com/count-podcast.xml", feed_type="podcast")
        stats = {"new": 3, "skipped": 1, "errors": 0}
        monkeypatch.setattr("wilted.handlers.discover._poll_feed", lambda f: stats if f.id == feed.id else stats)

        result = run_discover_via_runner()

        assert result["discovered"] == 3
        assert result["feeds_polled"] == 1
        assert result["errors"] == 0
        assert result["unknown"] == 0

    def test_one_feed_submit_failure_does_not_abort_the_others(self, monkeypatch) -> None:
        """Per-feed isolation (INV-6): a feed whose submission raises must not
        abort the run. The remaining feeds still submit, drain, and report; the
        failed feed is tallied as ``unknown``, never as discovered."""
        add_feed("https://example.com/healthy.xml", feed_type="podcast")
        broken = add_feed("https://example.com/broken.xml", feed_type="podcast")
        stats = {"new": 2, "skipped": 0, "errors": 0}
        monkeypatch.setattr("wilted.handlers.discover._poll_feed", lambda f: stats)

        real_submit = submit_discover

        def _submit_or_raise(feed_id, **kwargs):
            if feed_id == broken.id:
                raise RuntimeError("simulated per-feed submit failure")
            return real_submit(feed_id, **kwargs)

        monkeypatch.setattr("wilted.pipeline_submit.submit_discover", _submit_or_raise)

        result = run_discover_via_runner()

        assert result["feeds_polled"] == 2
        assert result["discovered"] == 2  # healthy feed still processed end to end
        assert result["unknown"] == 1  # broken feed isolated, surfaced as unknown
        assert result["errors"] == 0


class TestReportHandler:
    def test_assembles_stable_report_membership(self) -> None:
        item = Item.create(
            guid="report-handler-item",
            title="Report Handler Item",
            discovered_at=_now(),
            item_type="article",
            status="classified",
            status_changed_at=_now(),
            playlist_assigned="Work",
            relevance_score=0.9,
            fetch_state="content_ready",
            analysis_state="ready",
            preparation_state="not_queued",
            playback_state="unplayed",
            retention_state="active",
        )
        today = datetime.now().strftime("%Y-%m-%d")
        submit_report(report_date=today, sync_run=False)
        _run_job(JobKind.REPORT_ASSEMBLY, report_date=today)

        report = Report.get(Report.report_date == today)
        membership = load_report_membership(report.id)
        assert len(membership) == 1
        assert membership[0].item_id == str(item.id)
        assert membership[0].decision is ReportDecision.PENDING


class TestBriefingHandler:
    def test_persists_owed_briefing_artifact(self, monkeypatch) -> None:
        briefing = Briefing(
            generated_at=datetime.now(UTC),
            max_age_s=3600.0,
            max_duration_s=300.0,
            items=(
                BriefingItem(
                    item_id="1",
                    title="Headline",
                    summary="Summary",
                    source_name="Src",
                    relevance_score=0.8,
                    playlist="Work",
                ),
            ),
            weather=None,
            script="Good morning.",
            word_count=2,
            estimated_duration_s=1.0,
            synth_result=BriefingAudio(audio_bytes=b"RIFFfake", duration_ms=500),
        )
        monkeypatch.setattr(
            "wilted.handlers.briefing.BriefingGenerator.from_config",
            lambda **kwargs: MagicMock(generate=lambda **kw: briefing),
        )

        today = datetime.now().strftime("%Y-%m-%d")
        submit_briefing(window_start=today, window_end=today, sync_run=False)
        _run_job(JobKind.COMPACT_BRIEFING, window_start=today, window_end=today)

        ref = load_newest_owed_briefing()
        assert ref is not None
        assert ref.adopted_at is None
        assert (wilted.DATA_DIR / "briefings" / ref.artifact_id / "briefing.wav").is_file()


class TestPerItemSubmitFailureIsolationAndTruthfulness:
    """B3 — INV-6 isolation + truthfulness gate (behavioral truthfulness).

    Extends ``TestRunDiscoverViaRunner.test_one_feed_submit_failure_does_not_abort_the_others``
    above (same pattern: drive the real production runner, monkeypatch only
    the genuine ``submit_*`` boundary) to the other two per-item submit loops
    backported in B1 (``run_classify_via_runner``, ``run_prepare_via_runner``,
    PM-1) and B2 (``submit_pending_article_cache_jobs``). For each target, one
    item's ``submit_*`` raises, and the fix must survive it three ways:

    (a) NO ABORT — the run returns normally and the other items are still
        processed.
    (b) TRUTHFUL ACCOUNTING — the failed item is named in a not-success
        bucket the caller can see, never silently dropped from the totals.
    (c) LOGGING — a WARNING with a real traceback (``exc_info``) is emitted
        for the failed item, so an operator watching the log sees it.
    """

    def test_classify_one_item_submit_failure_does_not_abort_and_is_accounted(self, monkeypatch, caplog) -> None:
        good_a = _make_fetched_item_for_classify(suffix="good-a", text="Good classify body A.")
        good_b = _make_fetched_item_for_classify(suffix="good-b", text="Good classify body B.")
        bad = _make_fetched_item_for_classify(suffix="bad", text="Bad classify body.")
        monkeypatch.setattr("wilted.handlers.classify.create_backend", lambda *a, **k: _StubLLMBackend())

        real_submit_classify = submit_classify

        def _submit_or_raise(*, item_id=None, **kwargs):
            if item_id == bad.id:
                raise RuntimeError("simulated per-item classify submit failure")
            return real_submit_classify(item_id=item_id, **kwargs)

        monkeypatch.setattr("wilted.pipeline_submit.submit_classify", _submit_or_raise)

        with caplog.at_level(logging.WARNING, logger="wilted.pipeline_submit"):
            stats = run_classify_via_runner(model="test", backend_type="gguf")

        # (a) NO ABORT: the other two items were still submitted, drained, and classified.
        assert read_content_state(Item.get_by_id(good_a.id)).analysis is AnalysisState.READY
        assert read_content_state(Item.get_by_id(good_b.id)).analysis is AnalysisState.READY

        # (b) TRUTHFUL ACCOUNTING: the failed item is named, not vanished.
        assert stats["classified"] == 2
        _assert_classify_stats_truthful(stats, total_items=3)

        # (c) LOGGING: a WARNING with a real traceback names the failed item.
        assert _has_warning_with_traceback(caplog, logger_name="wilted.pipeline_submit", needle=str(bad.id))

    def test_prepare_one_item_submit_failure_does_not_abort_and_is_accounted(self, monkeypatch, caplog) -> None:
        good_a = _make_selected_item_for_prepare(suffix="good-a", text="Good prepare body A.")
        good_b = _make_selected_item_for_prepare(suffix="good-b", text="Good prepare body B.")
        bad = _make_selected_item_for_prepare(suffix="bad", text="Bad prepare body.")
        monkeypatch.setattr("wilted.cache.generate_article_cache", lambda *a, **k: True)

        real_submit_prepare = submit_prepare

        def _submit_or_raise(item_id, **kwargs):
            if item_id == bad.id:
                raise RuntimeError("simulated per-item prepare submit failure")
            return real_submit_prepare(item_id, **kwargs)

        monkeypatch.setattr("wilted.pipeline_submit.submit_prepare", _submit_or_raise)

        with caplog.at_level(logging.WARNING, logger="wilted.pipeline_submit"):
            stats = run_prepare_via_runner(use_llm=False, skip_tts=True)

        # (a) NO ABORT: the other two items were still submitted, drained, and prepared.
        assert read_content_state(Item.get_by_id(good_a.id)).preparation is PreparationState.READY
        assert read_content_state(Item.get_by_id(good_b.id)).preparation is PreparationState.READY

        # (b) TRUTHFUL ACCOUNTING: the failed item is named, not vanished.
        assert stats["prepared"] == 2
        _assert_prepare_stats_truthful(stats, total_items=3)

        # (c) LOGGING: a WARNING with a real traceback names the failed item.
        assert _has_warning_with_traceback(caplog, logger_name="wilted.pipeline_submit", needle=str(bad.id))

    def test_article_cache_one_entry_submit_failure_does_not_abort_and_entry_stays_pending(
        self, monkeypatch, caplog
    ) -> None:
        """Targets ``submit_pending_article_cache_jobs`` directly (not the
        ``run_article_cache_via_runner`` entry point above it) — ARTICLE_CACHE
        is a speech-requiring job kind (see ``TestSpeechReadyPolicy`` in
        ``test_pipeline_handlers.py``), so this deliberately never drains;
        draining is exercised elsewhere. Isolation is instead observed
        directly on the processing-job ledger.
        """
        from wilted.playlists import ensure_default_playlists

        ensure_default_playlists()  # items_needing_article_cache reads the "All" playlist
        good_a = add_article("Good cache body A.\n\nSecond paragraph.", title="Stage52 Cache Good A")
        good_b = add_article("Good cache body B.\n\nSecond paragraph.", title="Stage52 Cache Good B")
        bad = add_article("Bad cache body.\n\nSecond paragraph.", title="Stage52 Cache Bad")

        real_submit_article_cache = submit_article_cache

        def _submit_or_raise(item_id, **kwargs):
            if item_id == bad["id"]:
                raise RuntimeError("simulated per-entry article-cache submit failure")
            return real_submit_article_cache(item_id, **kwargs)

        monkeypatch.setattr("wilted.pipeline_submit.submit_article_cache", _submit_or_raise)

        voice, lang, speed = "af_heart", "a", 1.0
        with caplog.at_level(logging.WARNING, logger="wilted.pipeline_submit"):
            submitted = submit_pending_article_cache_jobs(voice=voice, lang=lang, speed=speed)

        entries = [good_a, good_b, bad]

        # (a) NO ABORT: both healthy entries got a real job admitted despite the failure.
        assert submitted == len(entries) - 1
        assert (
            ProcessingJob.select()
            .where(ProcessingJob.kind == JobKind.ARTICLE_CACHE.value, ProcessingJob.item_id == good_a["id"])
            .exists()
        )
        assert (
            ProcessingJob.select()
            .where(ProcessingJob.kind == JobKind.ARTICLE_CACHE.value, ProcessingJob.item_id == good_b["id"])
            .exists()
        )
        # The failed entry's own submit call is what raised — no job for it.
        assert (
            not ProcessingJob.select()
            .where(ProcessingJob.kind == JobKind.ARTICLE_CACHE.value, ProcessingJob.item_id == bad["id"])
            .exists()
        )

        # (b) TRUTHFUL ACCOUNTING: the failed entry is still surfaced as pending,
        # not silently dropped from the "needs cache" set.
        still_needing = {e["id"] for e in items_needing_article_cache(voice=voice, lang=lang, speed=speed)}
        _assert_article_cache_isolation_truthful(
            submitted=submitted,
            total_entries=len(entries),
            failed_still_pending=bad["id"] in still_needing,
        )

        # (c) LOGGING: a WARNING with a real traceback names the failed entry.
        assert _has_warning_with_traceback(caplog, logger_name="wilted.pipeline_submit", needle=str(bad["id"]))


class TestTruthfulnessGateIsNotVacuous:
    """Negative control (required, B3): proves the truthfulness helpers used
    above actually gate the historical silent-drop bug shape rather than
    passing trivially. These are the exact result shapes a revert of B1/B2
    would produce — one that let a failed submission vanish from the
    counted totals instead of landing in a not-success bucket — so if that
    ever regresses, this test (and the primary tests above, which call the
    very same helpers against real production output) goes red.
    """

    def test_classify_helper_rejects_pre_b1_shape_missing_the_counter_entirely(self) -> None:
        # Pre-B1: no try/except around submit_classify meant a failed item
        # never landed in classified/errors, and _classify_stats_for_items(items)
        # was returned unmodified — no submission_errors key at all.
        pre_b1_stats = {"classified": 2, "errors": 0, "total": 3}
        with pytest.raises(KeyError):
            _assert_classify_stats_truthful(pre_b1_stats, total_items=3)

    def test_classify_helper_rejects_shape_where_the_failure_is_zeroed_out(self) -> None:
        # A partial revert that keeps the key but never increments it (or
        # shrinks `total` instead of tallying the failure) must still fail.
        broken_stats = {"classified": 2, "errors": 0, "total": 2, "submission_errors": 0}
        with pytest.raises(AssertionError):
            _assert_classify_stats_truthful(broken_stats, total_items=3)

    def test_prepare_helper_rejects_pre_b1_shape_missing_the_counter_entirely(self) -> None:
        pre_b1_stats = {"prepared": 2, "errors": 0, "skipped": 0}
        with pytest.raises(KeyError):
            _assert_prepare_stats_truthful(pre_b1_stats, total_items=3)

    def test_prepare_helper_rejects_shape_where_the_failure_is_zeroed_out(self) -> None:
        broken_stats = {"prepared": 2, "errors": 0, "skipped": 0, "submission_errors": 0}
        with pytest.raises(AssertionError):
            _assert_prepare_stats_truthful(broken_stats, total_items=3)

    def test_article_cache_helper_rejects_a_failure_reported_as_if_it_had_succeeded(self) -> None:
        # If B2 regressed so the failed entry were (wrongly) counted among
        # `submitted`, or fell out of the pending set as though it had valid
        # cache, the gate must catch it rather than pass silently.
        with pytest.raises(AssertionError):
            _assert_article_cache_isolation_truthful(submitted=3, total_entries=3, failed_still_pending=True)
        with pytest.raises(AssertionError):
            _assert_article_cache_isolation_truthful(submitted=2, total_entries=3, failed_still_pending=False)
