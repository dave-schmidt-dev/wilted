"""Tests for discover/report/briefing pipeline handlers (Task 5.2)."""

from __future__ import annotations

from datetime import UTC, date, datetime, timedelta
from unittest.mock import MagicMock

import pytest

import wilted
from wilted.background_work.contracts import JobKind, ProcessingJobState, ReportDecision, SubmissionOutcome
from wilted.background_work.idempotency import build_idempotency_key, logical_identity_for_kind
from wilted.briefing_artifacts import load_newest_owed_briefing
from wilted.content_state import load_report_membership
from wilted.db import Item, ProcessingJob, Report
from wilted.feeds import add_feed
from wilted.pipeline_runner import PipelineRunner, RunExitReason
from wilted.pipeline_submit import (
    _discover_metadata,
    _submit_fresh_generation,
    run_discover_via_runner,
    submit_briefing,
    submit_discover,
    submit_report,
)
from wilted.processing_jobs import get_job, submit_job, transition_job_state
from wilted.station_runtime.briefing import Briefing, BriefingAudio, BriefingItem
from wilted.station_runtime.coordinator import RuntimeBootstrap

pytestmark = [pytest.mark.integration, pytest.mark.usefixtures("execution_capability")]


def _now() -> str:
    return datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def _ready_bootstrap() -> RuntimeBootstrap:
    bootstrap = RuntimeBootstrap()
    bootstrap.init_tqdm_lock()
    return bootstrap


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
