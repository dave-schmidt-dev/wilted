"""End-to-end regression coverage for the post-cutover content-state schema.

The legacy "content-state cutover" (``wilted.legacy_cutover``) is a one-way,
destructive migration: it drops ``items.status`` / ``items.status_changed_at``
and the ``selection_history`` table entirely. ``test_legacy_cutover.py`` and
``test_schema_cutover_queries.py`` already cover the cutover mechanics and
individual query guards in isolation. This module instead drives the real
production pipeline stages back to back — discover, article ingest, report
save, source stats, and retention cleanup — against a single already-cutover
database, so a query that quietly reintroduces ``status`` or
``selection_history`` fails loudly with ``OperationalError`` /
"no such column" instead of only being caught by a narrower unit test.

Daemon-independent by design: discovery, report assembly, source stats, and
processing-job retention never load TTS/STT models, so none of these tests
require the speech daemon (see ``requires_speech_daemon`` in conftest.py for
the tests that do).
"""

from __future__ import annotations

from datetime import UTC, datetime

import pytest

from wilted.background_work.contracts import JobKind, ProcessingJobState
from wilted.content_state import selection_history_available
from wilted.db import Feed, Item, ProcessingJob, Report, ReportItem, SourceStat, legacy_status_create_fields, now_utc
from wilted.feeds import add_feed
from wilted.legacy_cutover import items_table_has_status_column
from wilted.pipeline_submit import run_discover_via_runner
from wilted.processing_jobs import get_job, prune_terminal_jobs
from wilted.queue import add_article
from wilted.report import assemble_report, get_feed_stats, update_source_stats

pytestmark = pytest.mark.e2e


def _now() -> str:
    return datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def _assert_post_cutover_schema() -> None:
    """Fail fast (with a clear message) if the fixture didn't really cut over."""
    assert not items_table_has_status_column(Item._meta.database)
    assert selection_history_available() is False
    assert "status" not in Item._meta.fields
    assert "status_changed_at" not in Item._meta.fields


def _make_report_candidate(feed: Feed, *, guid: str, playlist: str = "Testing") -> Item:
    """Create an article Item already in the 'ready for report' orthogonal state.

    Mirrors what the real classify stage would leave behind, without needing
    the ML coordinator: content fetched, analysis ready, not queued for
    preparation, retention active. Uses ``legacy_status_create_fields`` the
    same way production create paths (e.g. ``wilted.queue.add_article``) do,
    so on a post-cutover DB this correctly contributes no ``status`` kwargs.
    """
    return Item.create(
        feed=feed,
        guid=guid,
        title=f"Post-cutover candidate {guid}",
        discovered_at=_now(),
        item_type="article",
        fetch_state="content_ready",
        analysis_state="ready",
        preparation_state="not_queued",
        playback_state="unplayed",
        retention_state="active",
        relevance_score=0.8,
        playlist_assigned=playlist,
        **legacy_status_create_fields(status="classified"),
    )


class TestPostCutoverArticleToReportFlow:
    """Article ingest -> report save -> source stats, all on a cutover DB."""

    def test_add_article_survives_post_cutover_schema(self, cutover_applied_db):
        """``add_article`` (the manual-add / discover-adjacent write path) must
        not emit the dropped ``status``/``status_changed_at`` columns."""
        _assert_post_cutover_schema()

        entry = add_article("Some article body text.", title="Post-cutover manual add")

        assert entry["title"] == "Post-cutover manual add"
        stored = Item.get_by_id(entry["id"])
        assert stored.title == "Post-cutover manual add"

    def test_report_save_and_source_stats_survive_post_cutover_schema(self, cutover_applied_db):
        """Full report assembly + source-stats aggregation on a cutover DB.

        Exercises ``assemble_report`` (which calls ``items_for_report`` /
        ``regenerate_report_membership``, both selection_history-aware) and
        ``update_source_stats`` (which branches on ``selection_history_available``)
        end to end, then reads the result back through ``get_feed_stats`` — the
        same query the ``wilted feed stats`` CLI action uses.
        """
        _assert_post_cutover_schema()

        feed = add_feed("https://example.com/post-cutover-feed.xml", feed_type="article")
        item = _make_report_candidate(feed, guid="report-candidate-1")

        report_result = assemble_report(report_date="2026-07-19")

        assert report_result["items"] == 1
        assert report_result["playlists"] == {"Testing": 1}
        report = Report.get_by_id(report_result["report_id"])
        assert report.report_date == "2026-07-19"
        membership = list(ReportItem.select().where(ReportItem.report == report))
        assert len(membership) == 1
        assert membership[0].item_id == item.id
        assert membership[0].decision == "pending"

        # Accept the item into the report the way the TUI/report-decision path
        # would, so source stats has a non-zero "selected" cohort to aggregate.
        accepted = membership[0]
        accepted.decision = "accepted"
        accepted.save()

        update_source_stats()

        stats = get_feed_stats(feed_id=feed.id)
        assert len(stats) == 1
        assert stats[0]["feed_id"] == feed.id
        assert stats[0]["items_discovered"] == 1
        assert stats[0]["items_selected"] == 1
        assert stats[0]["selection_rate"] == 1.0

        stat_row = SourceStat.get(SourceStat.feed == feed)
        assert stat_row.items_discovered == 1


class TestPostCutoverDiscoverFlow:
    """Discovery job pipeline (real ProcessingJob/PipelineRunner wiring) on a cutover DB."""

    def test_run_discover_via_runner_survives_post_cutover_schema(self, cutover_applied_db, monkeypatch):
        """Drives the real discover handler + PipelineRunner drain loop.

        ``_poll_feed`` (network I/O) is stubbed — matching the existing
        ``TestRunDiscoverViaRunner`` coverage in ``test_pipeline_handlers_stage52.py`` —
        so this stays daemon- and network-independent while still exercising the
        real ``ProcessingJob`` admission/lease/completion path against the
        cutover-applied database.
        """
        _assert_post_cutover_schema()

        add_feed("https://example.com/post-cutover-discover.xml", feed_type="podcast")
        stats = {"new": 2, "skipped": 0, "errors": 0}
        monkeypatch.setattr("wilted.handlers.discover._poll_feed", lambda f: stats)

        result = run_discover_via_runner()

        assert result["discovered"] == 2
        assert result["feeds_polled"] == 1
        assert result["errors"] == 0
        assert result["unknown"] == 0


class TestPostCutoverRetentionCleanup:
    """``prune_terminal_jobs`` retention sweep against a cutover DB."""

    def test_prune_terminal_jobs_survives_post_cutover_schema(self, cutover_applied_db):
        """Terminal jobs referencing a post-cutover Item are pruned cleanly."""
        _assert_post_cutover_schema()

        feed = add_feed("https://example.com/post-cutover-retention.xml", feed_type="article")
        item = _make_report_candidate(feed, guid="retention-candidate-1")

        old = "2020-01-01T00:00:00Z"
        stale_job = ProcessingJob.create(
            idempotency_key="discover:v1:post-cutover-retention:stale",
            kind=JobKind.DISCOVER.value,
            item=item,
            state=ProcessingJobState.COMPLETED.value,
            priority=0,
            attempt_count=1,
            max_attempts=3,
            created_at=old,
            updated_at=old,
            completed_at=old,
        )
        fresh_job = ProcessingJob.create(
            idempotency_key="discover:v1:post-cutover-retention:fresh",
            kind=JobKind.DISCOVER.value,
            item=item,
            state=ProcessingJobState.COMPLETED.value,
            priority=0,
            attempt_count=1,
            max_attempts=3,
            created_at=now_utc(),
            updated_at=now_utc(),
            completed_at=now_utc(),
        )

        deleted = prune_terminal_jobs(older_than_days=14, now="2020-02-01T00:00:00Z")

        assert deleted == 1
        assert get_job(stale_job.id) is None
        assert get_job(fresh_job.id) is not None
        # The item itself (post-cutover schema) is untouched by job retention.
        assert Item.get_by_id(item.id).title == item.title
