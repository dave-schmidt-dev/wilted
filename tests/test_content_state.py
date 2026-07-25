"""Tests for orthogonal content state and ReportItem membership (Task 2.1)."""

from __future__ import annotations

import importlib.util
from pathlib import Path

import pytest
from peewee import IntegrityError

from wilted.background_work.contracts import (
    AnalysisState,
    ContentState,
    FetchState,
    PlaybackState,
    PreparationState,
    ReportDecision,
    RetentionFacts,
    RetentionState,
)
from wilted.background_work.contracts import (
    ReportItem as ReportItemContract,
)
from wilted.content_state import (
    apply_retention_expiry,
    count_listenable_ready,
    create_report_item,
    items_for_report,
    load_report_membership,
    predicate_report_candidates,
    read_content_state,
    regenerate_report_membership,
    report_items_for_date,
    selection_history_available,
    transition_item,
    write_content_state,
)
from wilted.db import (
    Item,
    Report,
    ReportItem,
    connect_db,
    legacy_status_create_fields,
    now_utc,
    reset_db,
    run_migrations,
)


def _now() -> str:
    return now_utc()


def _make_item(**kwargs) -> Item:
    defaults = dict(
        feed=None,
        guid=f"guid-{kwargs.get('title', 'test')}",
        title="Test Article",
        discovered_at=_now(),
        item_type="article",
        status="ready",
        status_changed_at=_now(),
    )
    defaults.update(kwargs)
    return Item.create(**defaults)


def _make_report(report_date: str = "2026-07-16") -> Report:
    return Report.create(
        report_date=report_date,
        generated_at=_now(),
        item_count=0,
    )


def _content_state(**overrides) -> ContentState:
    defaults = dict(
        fetch=FetchState.CONTENT_READY,
        analysis=AnalysisState.READY,
        preparation=PreparationState.READY,
        playback=PlaybackState.UNPLAYED,
        retention=RetentionFacts(state=RetentionState.ACTIVE),
    )
    defaults.update(overrides)
    return ContentState(**defaults)


class TestContentStateConstraints:
    def test_invalid_fetch_state_rejected(self):
        item = _make_item()
        with pytest.raises(IntegrityError):
            item.fetch_state = "bogus"
            item.save()

    def test_invalid_analysis_state_rejected(self):
        item = _make_item()
        with pytest.raises(IntegrityError):
            item.analysis_state = "bogus"
            item.save()

    def test_invalid_preparation_state_rejected(self):
        item = _make_item()
        with pytest.raises(IntegrityError):
            item.preparation_state = "bogus"
            item.save()

    def test_invalid_playback_state_rejected(self):
        item = _make_item()
        with pytest.raises(IntegrityError):
            item.playback_state = "bogus"
            item.save()

    def test_invalid_retention_state_rejected(self):
        item = _make_item()
        with pytest.raises(IntegrityError):
            item.retention_state = "bogus"
            item.save()

    def test_all_valid_orthogonal_states_accepted(self):
        item = _make_item(guid="orthogonal-full")
        state = _content_state(
            retention=RetentionFacts(
                state=RetentionState.EXPIRED,
                expired_at="2026-07-15T00:00:00Z",
            ),
        )
        write_content_state(item, state)
        fetched = Item.get_by_id(item.id)
        assert read_content_state(fetched) == state

    def test_legacy_status_column_unchanged_by_orthogonal_write(self):
        item = _make_item(status="classified")
        write_content_state(item, _content_state())
        fetched = Item.get_by_id(item.id)
        assert fetched.status == "classified"


class TestCountListenableReady:
    def test_zero_when_no_items(self):
        assert count_listenable_ready() == 0

    def test_counts_only_playable_ready_items(self):
        ready_item = _make_item(guid="listenable-ready-1")
        write_content_state(ready_item, _content_state())

        completed_item = _make_item(guid="listenable-completed-1")
        write_content_state(completed_item, _content_state(playback=PlaybackState.COMPLETED))

        queued_item = _make_item(guid="listenable-queued-1")
        write_content_state(queued_item, _content_state(preparation=PreparationState.QUEUED))

        assert count_listenable_ready() == 1


class TestPostCutoverGuards:
    def _run_cutover(self, tmp_path) -> None:
        import wilted
        from tests.orthogonal_test_helpers import finalize_post_cutover_db
        from wilted.legacy_cutover import apply_legacy_cutover

        data_dir = wilted.DATA_DIR
        articles = data_dir / "articles"
        audio = data_dir / "audio"
        articles.mkdir(parents=True, exist_ok=True)
        audio.mkdir(parents=True, exist_ok=True)
        transcript = articles / "cutover.txt"
        transcript.write_text("body")
        wav = audio / "cutover.wav"
        wav.write_bytes(b"RIFF")
        Item.create(
            feed=None,
            guid="cutover-seed",
            title="Seed",
            discovered_at=_now(),
            item_type="article",
            status="ready",
            status_changed_at=_now(),
            transcript_file=str(transcript),
            audio_file=str(wav),
        )
        db_path = data_dir / "wilted.db"
        apply_legacy_cutover(db_path, dry_run=False, backup_dir=tmp_path / "backups")
        finalize_post_cutover_db(db_path)

    def test_selection_history_available_false_after_cutover(self, isolated_data, tmp_path):
        self._run_cutover(tmp_path)
        assert selection_history_available() is False

    def test_predicate_report_candidates_without_selection_history(self, isolated_data, tmp_path):
        self._run_cutover(tmp_path)
        list(Item.select().where(predicate_report_candidates()))
        assert items_for_report() is not None

    def test_transition_item_skips_legacy_status_sync_post_cutover(self, isolated_data, tmp_path):
        self._run_cutover(tmp_path)
        item = Item.create(
            feed=None,
            guid="post-cutover-transition",
            title="Transition target",
            discovered_at=_now(),
            item_type="article",
            fetch_state=FetchState.CONTENT_READY.value,
            analysis_state=AnalysisState.READY.value,
            preparation_state=PreparationState.NOT_QUEUED.value,
            playback_state=PlaybackState.UNPLAYED.value,
            retention_state=RetentionState.ACTIVE.value,
            **legacy_status_create_fields(status="classified"),
        )
        target = _content_state(preparation=PreparationState.QUEUED)
        transition_item(item, target)
        refreshed = Item.get_by_id(item.id)
        assert read_content_state(refreshed) == target
        assert "status" not in Item._meta.fields


class TestReportItemConstraints:
    def test_invalid_decision_rejected(self):
        report = _make_report()
        item = _make_item(guid="decision-check")
        with pytest.raises(IntegrityError):
            ReportItem.create(
                report=report,
                item=item,
                rank=0,
                decision="maybe",
                created_at=_now(),
            )

    def test_duplicate_report_item_membership_rejected(self):
        report = _make_report()
        item = _make_item(guid="dup-member")
        create_report_item(report=report, item=item, rank=0)
        with pytest.raises(IntegrityError):
            create_report_item(report=report, item=item, rank=1)

    def test_defer_until_only_with_deferred_decision(self):
        report = _make_report()
        item = _make_item(guid="defer-contract")
        with pytest.raises(ValueError, match="defer_until"):
            create_report_item(
                report=report,
                item=item,
                rank=0,
                decision=ReportDecision.ACCEPTED,
                defer_until="2099-01-01T00:00:00Z",
            )


class TestReportRegeneration:
    def test_same_day_regeneration_replaces_only_pending_rows(self):
        report = _make_report()
        other_report = _make_report(report_date="2026-07-15")

        pending_item = _make_item(guid="pending-1", title="Pending 1")
        accepted_item = _make_item(guid="accepted-1", title="Accepted 1")
        deferred_item = _make_item(guid="deferred-1", title="Deferred 1")
        historical_item = _make_item(guid="historical-1", title="Historical 1")

        create_report_item(report=report, item=pending_item, rank=0, decision=ReportDecision.PENDING)
        create_report_item(report=report, item=accepted_item, rank=1, decision=ReportDecision.ACCEPTED)
        create_report_item(
            report=report,
            item=deferred_item,
            rank=2,
            decision=ReportDecision.DEFERRED,
            defer_until="2099-01-01T00:00:00Z",
        )
        create_report_item(report=other_report, item=historical_item, rank=0, decision=ReportDecision.PENDING)

        new_pending_1 = _make_item(guid="new-1", title="New 1")
        new_pending_2 = _make_item(guid="new-2", title="New 2")
        proposed = (
            ReportItemContract(
                report_id=report.id, item_id=str(new_pending_1.id), rank=0, decision=ReportDecision.PENDING
            ),
            ReportItemContract(
                report_id=report.id, item_id=str(new_pending_2.id), rank=1, decision=ReportDecision.PENDING
            ),
        )

        regenerate_report_membership(report.id, proposed)
        rows = {row.item_id: row for row in load_report_membership(report.id)}

        assert str(pending_item.id) not in rows
        assert rows[str(new_pending_1.id)].decision is ReportDecision.PENDING
        assert rows[str(new_pending_2.id)].decision is ReportDecision.PENDING
        assert rows[str(accepted_item.id)].decision is ReportDecision.ACCEPTED
        assert rows[str(deferred_item.id)].decision is ReportDecision.DEFERRED

        historical_rows = load_report_membership(other_report.id)
        assert len(historical_rows) == 1
        assert historical_rows[0].item_id == str(historical_item.id)

    def test_regeneration_preserves_stable_ordering_for_decided_rows(self):
        report = _make_report()
        first = _make_item(guid="decided-a", title="A")
        second = _make_item(guid="decided-b", title="B")
        create_report_item(report=report, item=first, rank=0, decision=ReportDecision.ACCEPTED)
        create_report_item(report=report, item=second, rank=1, decision=ReportDecision.DISMISSED)

        replacement = _make_item(guid="pending-new", title="Pending")
        regenerate_report_membership(
            report.id,
            (
                ReportItemContract(
                    report_id=report.id,
                    item_id=str(replacement.id),
                    rank=5,
                    decision=ReportDecision.PENDING,
                ),
            ),
        )

        rows = load_report_membership(report.id)
        assert [row.item_id for row in rows] == [str(first.id), str(second.id), str(replacement.id)]
        assert [row.rank for row in rows] == [0, 1, 5]


class TestCrossDayMembership:
    def test_cross_day_membership_remains_stable(self):
        today = _make_report(report_date="2026-07-16")
        yesterday = _make_report(report_date="2026-07-15")

        today_item = _make_item(guid="today-item")
        yesterday_item = _make_item(guid="yesterday-item")

        create_report_item(report=today, item=today_item, rank=0, decision=ReportDecision.PENDING)
        create_report_item(report=yesterday, item=yesterday_item, rank=0, decision=ReportDecision.ACCEPTED)

        new_today_item = _make_item(guid="today-new")
        regenerate_report_membership(
            today.id,
            (
                ReportItemContract(
                    report_id=today.id,
                    item_id=str(new_today_item.id),
                    rank=0,
                    decision=ReportDecision.PENDING,
                ),
            ),
        )

        assert report_items_for_date("2026-07-15")[0].item_id == yesterday_item.id
        assert report_items_for_date("2026-07-16")[0].item_id == new_today_item.id


class TestRetentionKeepOverride:
    def test_keep_override_prevents_retention_expiry(self):
        item = _make_item(keep=True)
        write_content_state(
            item,
            _content_state(
                retention=RetentionFacts(state=RetentionState.ACTIVE, keep_override=True),
            ),
        )
        item.retention_expires_at = "2026-07-15T00:00:00Z"
        item.save()

        apply_retention_expiry(item, now="2026-07-17T00:00:00Z")
        refreshed = Item.get_by_id(item.id)

        assert refreshed.retention_state == RetentionState.ACTIVE.value
        assert refreshed.keep is True

    def test_without_keep_override_item_expires(self):
        item = _make_item(keep=False)
        write_content_state(
            item,
            _content_state(
                retention=RetentionFacts(state=RetentionState.ACTIVE, keep_override=False),
            ),
        )
        item.retention_expires_at = "2026-07-15T00:00:00Z"
        item.save()

        apply_retention_expiry(item, now="2026-07-17T00:00:00Z")
        refreshed = Item.get_by_id(item.id)

        assert refreshed.retention_state == RetentionState.EXPIRED.value
        assert refreshed.retention_expires_at == "2026-07-15T00:00:00Z"


class TestMigration002:
    def _load_migration(self):
        mig_path = Path(__file__).resolve().parent.parent / "migrations" / "002_orthogonal_content_state.py"
        spec = importlib.util.spec_from_file_location("migration_002", mig_path)
        module = importlib.util.module_from_spec(spec)
        assert spec.loader is not None
        spec.loader.exec_module(module)
        return module

    def test_idempotent_on_fresh_database(self, tmp_path):
        db_path = tmp_path / "fresh.db"
        reset_db()
        connect_db(db_path)
        run_migrations(db_path)

        from wilted.db import _db

        migration = self._load_migration()
        migration.up(_db)
        migration.up(_db)

        assert _column_exists(_db, "items", "fetch_state")
        assert _table_exists(_db, "report_items")

    def test_idempotent_on_existing_database(self, tmp_path):
        db_path = tmp_path / "existing.db"
        reset_db()
        connect_db(db_path)
        run_migrations(db_path)

        item = _make_item(guid="pre-migration", title="Legacy row", _skip_orthogonal_backfill=True)
        assert item.fetch_state is None

        from wilted.db import _db

        migration = self._load_migration()
        migration.up(_db)
        migration.up(_db)

        refreshed = Item.get_by_id(item.id)
        assert refreshed.fetch_state is None
        assert refreshed.status == "ready"


def _column_exists(db, table_name: str, column_name: str) -> bool:
    cursor = db.execute_sql(f"PRAGMA table_info({table_name})")
    return any(row[1] == column_name for row in cursor.fetchall())


def _table_exists(db, table_name: str) -> bool:
    cursor = db.execute_sql(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
        (table_name,),
    )
    return cursor.fetchone() is not None
