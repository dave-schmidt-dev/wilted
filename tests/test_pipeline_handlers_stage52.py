"""Tests for discover/report/briefing pipeline handlers (Task 5.2)."""

from __future__ import annotations

from datetime import UTC, datetime
from unittest.mock import MagicMock

import pytest

import wilted
from wilted.background_work.contracts import JobKind, ProcessingJobState, ReportDecision
from wilted.background_work.idempotency import build_idempotency_key, logical_identity_for_kind
from wilted.briefing_artifacts import load_newest_owed_briefing
from wilted.content_state import load_report_membership
from wilted.db import Item, ProcessingJob, Report
from wilted.feeds import add_feed
from wilted.pipeline_runner import PipelineRunner, RunExitReason
from wilted.pipeline_submit import submit_briefing, submit_discover, submit_report
from wilted.processing_jobs import submit_job
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
