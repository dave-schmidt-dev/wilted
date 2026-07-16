"""Set-equivalence tests: legacy status cohorts vs orthogonal query predicates.

Each test builds a mixed fixture (skipped, kept, completed, deferred, expired)
and asserts membership equality between the legacy ``Item.status`` query and
the new orthogonal predicate helpers.
"""

from __future__ import annotations

import wilted
from tests.orthogonal_test_helpers import ensure_test_orthogonal_state
from wilted.background_work.contracts import ReportDecision
from wilted.content_state import (
    apply_mapped_content_state,
    apply_retention_expiry,
    create_report_item,
    items_for_prepare,
    items_for_report,
)
from wilted.db import Item, Report, SelectionHistory, now_utc
from wilted.legacy_cutover import map_item_row


def _legacy_report_ids() -> set[int]:
    return {item.id for item in Item.select().where(Item.status == "classified")}


def _legacy_prepare_ids() -> set[int]:
    return {item.id for item in Item.select().where(Item.status == "selected")}


def _seed(**kwargs) -> Item:
    defaults = dict(
        feed=None,
        guid=f"guid-{kwargs.get('title', 'x')}",
        title="Fixture",
        discovered_at=now_utc(),
        item_type="article",
        status="classified",
        status_changed_at=now_utc(),
        _skip_orthogonal_backfill=True,
    )
    defaults.update(kwargs)
    item = Item.create(**defaults)
    return ensure_test_orthogonal_state(item)


class TestReportCohortEquivalence:
    def test_skipped_and_dismissed_items_excluded_like_legacy(self):
        pending = _seed(title="Pending", status="classified")

        skipped = _seed(title="Skipped", status="classified")
        skipped.status = "skipped"
        skipped.save()
        SelectionHistory.create(item=skipped, report=None, selected=False, selected_at=now_utc())

        report = Report.create(
            report_date="2026-07-16",
            generated_at=now_utc(),
            item_count=1,
            metadata="{}",
        )
        dismissed = _seed(title="Dismissed", status="classified")
        create_report_item(report=report, item=dismissed, rank=1, decision=ReportDecision.DISMISSED)
        dismissed.status = "skipped"
        dismissed.save()

        assert _legacy_report_ids() == {pending.id}
        assert {item.id for item in items_for_report()} == {pending.id}

    def test_discovered_podcast_in_report_cohort(self):
        from wilted.background_work.contracts import (
            AnalysisState,
            ContentState,
            FetchState,
            PlaybackState,
            PreparationState,
            RetentionFacts,
            RetentionState,
        )
        from wilted.content_state import transition_item

        podcast = Item.create(
            feed=None,
            guid="pod-ep",
            title="Podcast ep",
            discovered_at=now_utc(),
            item_type="podcast_episode",
            status="discovered",
            status_changed_at=now_utc(),
            enclosure_url="https://example.com/ep.mp3",
            _skip_orthogonal_backfill=True,
        )
        transition_item(
            podcast,
            ContentState(
                fetch=FetchState.METADATA,
                analysis=AnalysisState.PENDING,
                preparation=PreparationState.NOT_QUEUED,
                playback=PlaybackState.UNPLAYED,
                retention=RetentionFacts(state=RetentionState.ACTIVE),
            ),
            legacy_status="discovered",
        )

        ids = {item.id for item in items_for_report()}
        assert podcast.id in ids


class TestPrepareCohortEquivalence:
    def test_ready_and_completed_not_requeued_via_accepted_report(self):
        report = Report.create(
            report_date="2026-07-17",
            generated_at=now_utc(),
            item_count=1,
            metadata="{}",
        )
        ready = _seed(title="Ready", status="ready")
        create_report_item(report=report, item=ready, rank=0, decision=ReportDecision.ACCEPTED)

        completed = _seed(title="Done", status="completed")
        create_report_item(report=report, item=completed, rank=1, decision=ReportDecision.ACCEPTED)

        selected = _seed(title="Selected", status="selected")
        from wilted.background_work.contracts import (
            AnalysisState,
            ContentState,
            FetchState,
            PlaybackState,
            PreparationState,
            RetentionFacts,
            RetentionState,
        )
        from wilted.content_state import transition_item

        transition_item(
            selected,
            ContentState(
                fetch=FetchState.CONTENT_READY,
                analysis=AnalysisState.READY,
                preparation=PreparationState.QUEUED,
                playback=PlaybackState.UNPLAYED,
                retention=RetentionFacts(state=RetentionState.ACTIVE),
            ),
            legacy_status="selected",
        )

        assert _legacy_prepare_ids() == {selected.id}
        assert {item.id for item in items_for_prepare()} == {selected.id}


class TestCutoverPreservesKeep:
    def test_apply_mapped_content_state_preserves_keep_on_ready_item(self, tmp_path, monkeypatch):
        data_dir = tmp_path / "data"
        data_dir.mkdir(exist_ok=True)
        monkeypatch.setattr(wilted, "DATA_DIR", data_dir)

        item = Item.create(
            feed=None,
            guid="keep-me",
            title="Kept ready",
            discovered_at=now_utc(),
            item_type="article",
            status="ready",
            status_changed_at=now_utc(),
            keep=True,
            _skip_orthogonal_backfill=True,
        )
        item = ensure_test_orthogonal_state(item)
        transcript_path = data_dir / "transcripts" / f"{item.id}_transcript.json"
        audio_path = data_dir / "audio" / f"{item.id}.mp3"
        transcript_path.parent.mkdir(parents=True, exist_ok=True)
        audio_path.parent.mkdir(parents=True, exist_ok=True)
        transcript_path.write_text("{}", encoding="utf-8")
        audio_path.write_bytes(b"audio-bytes")
        item.transcript_file = str(transcript_path)
        item.audio_file = str(audio_path)
        item.save()

        outcome = map_item_row(item, data_dir)
        assert not outcome.quarantine and outcome.content is not None

        apply_mapped_content_state(item, outcome.content)
        refreshed = Item.get_by_id(item.id)
        assert refreshed.keep is True


class TestRetentionKeepOnExpiry:
    def test_kept_item_stays_active_and_legacy_not_expired(self):
        item = _seed(title="Kept old", status="ready", keep=True)
        past = "2020-01-01T00:00:00Z"
        item.retention_expires_at = past
        item.save()

        apply_retention_expiry(item, now="2026-01-01T00:00:00Z")
        refreshed = Item.get_by_id(item.id)
        assert refreshed.retention_state == "active"
        assert refreshed.keep is True
        assert refreshed.status != "expired"
