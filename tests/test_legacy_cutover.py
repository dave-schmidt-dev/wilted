"""Integration tests for the explicit legacy content-state cutover (Task 2.2)."""

from __future__ import annotations

import os
import shutil
import sqlite3
import stat
from unittest.mock import patch

import pytest

import wilted
from wilted.background_work.legacy_mapping import (
    ArtifactCohort,
    ItemType,
    LegacyCohort,
    LegacyStatus,
    all_legacy_cohorts,
    map_legacy_cohort,
)
from wilted.db import Item, Report, ReportItem, SelectionHistory, _Meta, now_utc
from wilted.legacy_cutover import (
    META_CUTOVER_IN_PROGRESS,
    apply_legacy_cutover,
    build_cutover_plan,
    classify_artifact_cohort,
    create_backup,
    cutover_complete,
    cutover_in_progress,
    cutover_required,
    items_table_has_status_column,
    map_item_row,
    verify_backup,
)


def _now() -> str:
    return now_utc()


def _make_item(
    *,
    status: str,
    item_type: str = "article",
    transcript_file: str | None = None,
    audio_file: str | None = None,
    keep: bool = False,
    title: str | None = None,
) -> Item:
    return Item.create(
        feed=None,
        guid=f"guid-{status}-{item_type}-{title or 'item'}",
        title=title or f"{status} {item_type}",
        discovered_at=_now(),
        item_type=item_type,
        status=status,
        status_changed_at=_now(),
        transcript_file=transcript_file,
        audio_file=audio_file,
        keep=keep,
    )


def _write_artifacts(
    data_dir,
    item_id: int,
    *,
    transcript: bool = False,
    audio: bool = False,
) -> tuple[str | None, str | None]:
    transcript_path = None
    audio_path = None
    if transcript:
        transcript_path = data_dir / "articles" / f"{item_id}.txt"
        transcript_path.parent.mkdir(parents=True, exist_ok=True)
        transcript_path.write_text("sample transcript")
    if audio:
        audio_path = data_dir / "audio" / f"{item_id}.wav"
        audio_path.parent.mkdir(parents=True, exist_ok=True)
        audio_path.write_bytes(b"RIFF")
    return (
        str(transcript_path) if transcript_path else None,
        str(audio_path) if audio_path else None,
    )


class TestArtifactCohort:
    def test_classify_none_partial_complete(self, isolated_data):
        data_dir = wilted.DATA_DIR
        bare = _make_item(status="discovered")
        assert classify_artifact_cohort(bare, data_dir) is ArtifactCohort.NONE

        transcript_file, _ = _write_artifacts(data_dir, bare.id + 1000, transcript=True)
        partial = _make_item(status="fetched", transcript_file=transcript_file)
        assert classify_artifact_cohort(partial, data_dir) is ArtifactCohort.PARTIAL

        transcript_file, audio_file = _write_artifacts(data_dir, bare.id + 2000, transcript=True, audio=True)
        complete = _make_item(status="ready", transcript_file=transcript_file, audio_file=audio_file)
        assert classify_artifact_cohort(complete, data_dir) is ArtifactCohort.COMPLETE


class TestCutoverPlan:
    def test_map_item_row_matches_truth_table(self, isolated_data):
        data_dir = wilted.DATA_DIR
        transcript_file, audio_file = _write_artifacts(data_dir, 9001, transcript=True, audio=True)
        item = _make_item(status="ready", transcript_file=transcript_file, audio_file=audio_file)
        expected = map_legacy_cohort(
            LegacyCohort(
                status=LegacyStatus.READY,
                item_type=ItemType.ARTICLE,
                artifacts=ArtifactCohort.COMPLETE,
            )
        )
        assert map_item_row(item, data_dir) == expected

    def test_build_cutover_plan_counts_cohorts(self, isolated_data):
        data_dir = wilted.DATA_DIR
        _make_item(status="discovered")
        transcript_file, _ = _write_artifacts(data_dir, 9100, transcript=True)
        _make_item(status="classified", transcript_file=transcript_file)
        plan = build_cutover_plan(Item._meta.database, data_dir=data_dir)
        assert plan.items or plan.quarantined
        assert sum(plan.cohort_counts.values()) == 2


class TestBackup:
    def test_create_and_verify_backup(self, isolated_data, tmp_path):
        db_path = wilted.DATA_DIR / "wilted.db"
        backup_dir = tmp_path / "backups"
        backup_path = create_backup(db_path, backup_dir)
        assert verify_backup(backup_path)
        assert not verify_backup(backup_dir / "missing.db")


class TestStartupRefusal:
    def test_main_exits_when_cutover_interrupted(self, isolated_data):
        from wilted.cli import main

        _Meta.replace(key=META_CUTOVER_IN_PROGRESS, value="1").execute()
        assert cutover_in_progress(Item._meta.database)

        with (
            patch("sys.argv", ["wilted", "list"]),
            pytest.raises(SystemExit) as exc,
        ):
            main()

        assert exc.value.code == 1


class TestCutoverApply:
    def _seed_representative_items(self, data_dir) -> None:
        for cohort in all_legacy_cohorts():
            outcome = map_legacy_cohort(cohort)
            if outcome.quarantine:
                continue
            title = f"{cohort.status}-{cohort.item_type}-{cohort.artifacts}"
            transcript_file = None
            audio_file = None
            if cohort.artifacts is ArtifactCohort.PARTIAL:
                transcript_file, _ = _write_artifacts(data_dir, hash(title) % 100000, transcript=True)
            elif cohort.artifacts is ArtifactCohort.COMPLETE:
                transcript_file, audio_file = _write_artifacts(
                    data_dir,
                    hash(title) % 100000,
                    transcript=True,
                    audio=True,
                )
            _make_item(
                status=cohort.status.value,
                item_type=cohort.item_type.value,
                transcript_file=transcript_file,
                audio_file=audio_file,
                keep=cohort.keep_override,
                title=title,
            )

    def test_cohort_equivalence_after_cutover(self, isolated_data, tmp_path):
        data_dir = wilted.DATA_DIR
        self._seed_representative_items(data_dir)
        db_path = data_dir / "wilted.db"

        report = apply_legacy_cutover(db_path, dry_run=False, backup_dir=tmp_path / "backups")
        assert all(row.matches for row in report.cohort_reconciliation)
        assert not items_table_has_status_column(Item._meta.database)
        assert cutover_complete()

    def test_quarantine_rows_visible_for_ambiguous_cohort(self, isolated_data, tmp_path):
        data_dir = wilted.DATA_DIR
        item = _make_item(status="discovered")
        transcript_file, _ = _write_artifacts(data_dir, item.id, transcript=True)
        item.transcript_file = transcript_file
        item.save()

        report = apply_legacy_cutover(
            data_dir / "wilted.db",
            dry_run=False,
            backup_dir=tmp_path / "backups",
        )
        assert report.items_quarantined >= 1
        assert any(row["item_id"] == item.id for row in report.quarantine_rows)

        conn = sqlite3.connect(data_dir / "wilted.db")
        try:
            rows = conn.execute("SELECT item_id, reason FROM migration_quarantine").fetchall()
        finally:
            conn.close()
        assert any(row[0] == item.id for row in rows)

    def test_selection_history_backfill(self, isolated_data, tmp_path):
        data_dir = wilted.DATA_DIR
        transcript_file, audio_file = _write_artifacts(data_dir, 42, transcript=True, audio=True)
        item = _make_item(status="ready", transcript_file=transcript_file, audio_file=audio_file)
        report = Report.create(report_date="2026-07-16", generated_at=_now(), item_count=1, metadata="{}")
        SelectionHistory.create(item=item, report=report, selected=True, selected_at=_now())

        apply_legacy_cutover(data_dir / "wilted.db", dry_run=False, backup_dir=tmp_path / "backups")

        rows = list(ReportItem.select().where(ReportItem.item == item.id))
        assert len(rows) == 1
        assert rows[0].decision == "accepted"

    def test_repeated_cutover_is_idempotent(self, isolated_data, tmp_path):
        data_dir = wilted.DATA_DIR
        transcript_file, audio_file = _write_artifacts(data_dir, 7, transcript=True, audio=True)
        _make_item(status="ready", transcript_file=transcript_file, audio_file=audio_file)
        db_path = data_dir / "wilted.db"
        first = apply_legacy_cutover(db_path, dry_run=False, backup_dir=tmp_path / "backups")
        assert "completed" in first.message.lower()

        second = apply_legacy_cutover(db_path, dry_run=False, backup_dir=tmp_path / "backups")
        assert "already complete" in second.message.lower()

    def test_live_cutover_requires_backup(self, isolated_data):
        data_dir = wilted.DATA_DIR
        _make_item(status="discovered")
        from wilted.legacy_cutover import CutoverError

        with pytest.raises(CutoverError, match="backup_dir"):
            apply_legacy_cutover(data_dir / "wilted.db", dry_run=False, backup_dir=None)


class TestCopiedDatabaseFixture:
    def test_cutover_on_restricted_copied_db(self, isolated_data, tmp_path):
        source_db = wilted.DATA_DIR / "wilted.db"
        transcript_file, audio_file = _write_artifacts(wilted.DATA_DIR, 99, transcript=True, audio=True)
        _make_item(status="ready", transcript_file=transcript_file, audio_file=audio_file)

        copied_dir = tmp_path / "copied-live"
        copied_dir.mkdir()
        copied_db = copied_dir / "wilted.db"
        with sqlite3.connect(source_db) as conn:
            conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        shutil.copy2(source_db, copied_db)
        os.chmod(copied_db, stat.S_IRUSR | stat.S_IWUSR)

        backup_dir = copied_dir / "backups"
        report = apply_legacy_cutover(copied_db, dry_run=False, backup_dir=backup_dir)
        assert report.backup_path is not None
        assert verify_backup(report.backup_path)

        conn = sqlite3.connect(copied_db)
        try:
            columns = [row[1] for row in conn.execute("PRAGMA table_info(items)").fetchall()]
        finally:
            conn.close()
        assert "status" not in columns

        copied_db.unlink(missing_ok=True)
        if report.backup_path is not None:
            report.backup_path.unlink(missing_ok=True)


class TestCutoverRequired:
    def test_cutover_required_before_and_after(self, isolated_data, tmp_path):
        db = Item._meta.database
        assert cutover_required(db)

        data_dir = wilted.DATA_DIR
        transcript_file, audio_file = _write_artifacts(data_dir, 1, transcript=True, audio=True)
        _make_item(status="ready", transcript_file=transcript_file, audio_file=audio_file)
        apply_legacy_cutover(data_dir / "wilted.db", dry_run=False, backup_dir=tmp_path / "backups")
        assert not cutover_required(db)


class TestDryRun:
    def test_dry_run_does_not_mutate_schema(self, isolated_data):
        data_dir = wilted.DATA_DIR
        _make_item(status="discovered")
        db_path = data_dir / "wilted.db"
        report = apply_legacy_cutover(db_path, dry_run=True)
        assert report.dry_run is True
        assert items_table_has_status_column(Item._meta.database)
        assert Item.select().where(Item.status == "discovered").count() == 1


def _apply_post_cutover_fixture(tmp_path, *, include_classified: bool = False) -> None:
    """Seed minimal legacy rows and run a live cutover for post-cutover regression tests."""
    from tests.orthogonal_test_helpers import finalize_post_cutover_db

    data_dir = wilted.DATA_DIR
    transcript_file, audio_file = _write_artifacts(data_dir, 8800, transcript=True, audio=True)
    _make_item(status="ready", transcript_file=transcript_file, audio_file=audio_file, title="Ready seed")
    if include_classified:
        classified_transcript, _ = _write_artifacts(data_dir, 8801, transcript=True)
        _make_item(
            status="classified",
            transcript_file=classified_transcript,
            title="Classified seed",
        )
    db_path = data_dir / "wilted.db"
    apply_legacy_cutover(db_path, dry_run=False, backup_dir=tmp_path / "backups")
    finalize_post_cutover_db(db_path)


class TestPostCutoverHardening:
    def test_selection_history_unavailable_after_cutover(self, isolated_data, tmp_path):
        from wilted.content_state import selection_history_available

        _apply_post_cutover_fixture(tmp_path)
        assert not items_table_has_status_column(Item._meta.database)
        assert selection_history_available() is False

    def test_item_create_without_status_after_cutover(self, isolated_data, tmp_path):
        from wilted.background_work.contracts import (
            AnalysisState,
            FetchState,
            PlaybackState,
            PreparationState,
            RetentionState,
        )
        from wilted.db import legacy_status_create_fields

        _apply_post_cutover_fixture(tmp_path)
        assert legacy_status_create_fields(status="classified") == {}

        item = Item.create(
            feed=None,
            guid="post-cutover-no-status",
            title="Created without status",
            discovered_at=_now(),
            item_type="article",
            fetch_state=FetchState.CONTENT_READY.value,
            analysis_state=AnalysisState.READY.value,
            preparation_state=PreparationState.NOT_QUEUED.value,
            playback_state=PlaybackState.UNPLAYED.value,
            retention_state=RetentionState.ACTIVE.value,
            **legacy_status_create_fields(status="classified"),
        )
        fetched = Item.get_by_id(item.id)
        assert fetched.title == "Created without status"
        assert "status" not in Item._meta.fields

    def test_report_predicates_after_cutover(self, isolated_data, tmp_path):
        from wilted.content_state import items_for_report, predicate_report_candidates

        _apply_post_cutover_fixture(tmp_path, include_classified=True)

        candidate_ids = {row.id for row in Item.select().where(predicate_report_candidates())}
        report_ids = {item.id for item in items_for_report()}
        assert candidate_ids == report_ids
        assert candidate_ids  # classified seed survived cutover mapping

    def test_item_select_does_not_reference_dropped_status_column(self, isolated_data, tmp_path):
        _apply_post_cutover_fixture(tmp_path)
        rows = list(Item.select())
        assert len(rows) >= 1
        assert all(row.title for row in rows)
