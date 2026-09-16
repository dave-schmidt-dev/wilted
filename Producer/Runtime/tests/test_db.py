"""Tests for Phase 1 database layer — db.py, retention, timestamps."""

from __future__ import annotations

import threading
from datetime import UTC, datetime, timedelta

import pytest

import wilted
from wilted.db import Item

# ---------------------------------------------------------------------------
# db.py — CRUD
# ---------------------------------------------------------------------------


def _now() -> str:
    return datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def _make_item(**kwargs):
    defaults = dict(
        feed=None,
        guid="test-guid",
        title="Test Article",
        source_url=None,
        canonical_url=None,
        discovered_at=_now(),
        item_type="article",
        status="ready",
        status_changed_at=_now(),
        word_count=100,
    )
    defaults.update(kwargs)
    return Item.create(**defaults)


class TestItemCRUD:
    def test_create_and_read(self):
        item = _make_item(title="Hello", word_count=42)
        fetched = Item.get_by_id(item.id)
        assert fetched.title == "Hello"
        assert fetched.word_count == 42

    def test_update(self):
        item = _make_item()
        item.status = "completed"
        item.save()
        assert Item.get_by_id(item.id).status == "completed"

    def test_delete(self):
        item = _make_item()
        item_id = item.id
        item.delete_instance()
        with pytest.raises(Item.DoesNotExist):
            Item.get_by_id(item_id)

    def test_status_check_constraint(self):
        """Invalid status should raise IntegrityError from SQLite CHECK."""
        from peewee import IntegrityError

        with pytest.raises(IntegrityError):
            _make_item(status="invalid_status")

    def test_item_type_check_constraint(self):
        """Invalid item_type should raise IntegrityError from SQLite CHECK."""
        from peewee import IntegrityError

        with pytest.raises(IntegrityError):
            _make_item(item_type="invalid_type")

    def test_all_valid_statuses(self):
        valid = [
            "discovered",
            "fetched",
            "classified",
            "selected",
            "processing",
            "ready",
            "completed",
            "expired",
            "skipped",
            "error",
        ]
        for i, status in enumerate(valid):
            item = _make_item(guid=f"guid-{i}", title=f"Item {i}", status=status)
            assert Item.get_by_id(item.id).status == status

    def test_keep_field_defaults_false(self):
        item = _make_item()
        assert item.keep is False

    def test_select_by_status(self):
        _make_item(guid="a", title="Ready 1", status="ready")
        _make_item(guid="b", title="Ready 2", status="ready")
        _make_item(guid="c", title="Done", status="completed")
        ready = list(Item.select().where(Item.status == "ready"))
        assert len(ready) == 2

    def test_legacy_status_create_fields_pre_cutover(self):
        from wilted.db import legacy_status_create_fields

        fields = legacy_status_create_fields(status="ready")
        assert fields["status"] == "ready"
        assert fields["status_changed_at"].endswith("Z")


class TestLegacyStatusCreateFieldsPostCutover:
    def test_returns_empty_dict_after_cutover(self, isolated_data, tmp_path):
        import wilted
        from tests.orthogonal_test_helpers import finalize_post_cutover_db
        from wilted.db import legacy_status_create_fields
        from wilted.legacy_cutover import apply_legacy_cutover

        data_dir = wilted.DATA_DIR
        articles = data_dir / "articles"
        audio = data_dir / "audio"
        articles.mkdir(parents=True, exist_ok=True)
        audio.mkdir(parents=True, exist_ok=True)
        transcript = articles / "9000.txt"
        transcript.write_text("body")
        wav = audio / "9000.wav"
        wav.write_bytes(b"RIFF")
        Item.create(
            feed=None,
            guid="cutover-ready",
            title="Ready",
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
        assert legacy_status_create_fields(status="ready") == {}


class TestThreadSafety:
    def test_concurrent_inserts(self):
        """Multiple threads can insert items without corrupting data."""
        errors = []

        def insert_item(n):
            try:
                from wilted.db import connect_db

                connect_db(wilted.DATA_DIR / "wilted.db")
                _make_item(guid=f"thread-{n}", title=f"Thread {n}")
            except Exception as e:
                errors.append(e)

        threads = [threading.Thread(target=insert_item, args=(i,)) for i in range(5)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        assert errors == [], f"Thread errors: {errors}"
        count = Item.select().count()
        assert count == 5


# ---------------------------------------------------------------------------
# Retention policy (queue.run_retention)
# ---------------------------------------------------------------------------


class TestRetentionPolicy:
    def _completed_item(self, days_ago: int, keep: bool = False) -> Item:
        """Create a completed item with status_changed_at = N days ago."""
        changed = datetime.now(UTC) - timedelta(days=days_ago)
        changed_str = changed.strftime("%Y-%m-%dT%H:%M:%SZ")
        item = _make_item(status="completed", status_changed_at=changed_str)
        item.keep = keep
        item.save()
        return item

    def test_old_item_files_deleted(self):
        from wilted.queue import run_retention

        item = self._completed_item(days_ago=31)
        tf = wilted.ARTICLES_DIR / f"{item.id}_test.txt"
        tf.write_text("content")
        item.transcript_file = str(tf)
        item.save()

        cleaned = run_retention(retention_days=30)
        assert cleaned == 1
        assert not tf.exists()

    def test_recent_item_not_deleted(self):
        from wilted.queue import run_retention

        item = self._completed_item(days_ago=5)
        tf = wilted.ARTICLES_DIR / f"{item.id}_test.txt"
        tf.write_text("content")
        item.transcript_file = str(tf)
        item.save()

        cleaned = run_retention(retention_days=30)
        assert cleaned == 0
        assert tf.exists()

    def test_keep_flag_exempts_item(self):
        from wilted.queue import run_retention

        item = self._completed_item(days_ago=60, keep=True)
        tf = wilted.ARTICLES_DIR / f"{item.id}_keep.txt"
        tf.write_text("keep me")
        item.transcript_file = str(tf)
        item.save()

        cleaned = run_retention(retention_days=30)
        assert cleaned == 0
        assert tf.exists()

    def test_ready_items_not_touched(self):
        from wilted.queue import add_article, run_retention

        entry = add_article("Active content.", title="Active")
        cleaned = run_retention(retention_days=0)  # even with 0-day threshold
        assert cleaned == 0
        # File still exists
        tf = wilted.ARTICLES_DIR / entry["file"]
        assert tf.exists()

    def test_audio_file_also_deleted(self):
        from wilted.queue import run_retention

        item = self._completed_item(days_ago=40)
        af = wilted.AUDIO_DIR / f"{item.id}_audio.mp3"
        af.write_bytes(b"audio")
        item.audio_file = str(af)
        item.save()

        run_retention(retention_days=30)
        assert not af.exists()

    def test_uses_discovered_at_when_status_changed_at_absent(self, isolated_data, tmp_path):
        """Post-cutover DBs drop status_changed_at; retention clock falls back to discovered_at."""
        from tests.orthogonal_test_helpers import finalize_post_cutover_db
        from wilted.legacy_cutover import apply_legacy_cutover
        from wilted.queue import run_retention

        data_dir = wilted.DATA_DIR
        old = (datetime.now(UTC) - timedelta(days=40)).strftime("%Y-%m-%dT%H:%M:%SZ")
        articles = data_dir / "articles"
        audio = data_dir / "audio"
        articles.mkdir(parents=True, exist_ok=True)
        audio.mkdir(parents=True, exist_ok=True)
        transcript = articles / "retention.txt"
        transcript.write_text("old transcript")
        wav = audio / "retention.wav"
        wav.write_bytes(b"RIFF")

        item = Item.create(
            feed=None,
            guid="completed-old",
            title="Completed old",
            discovered_at=old,
            item_type="article",
            status="completed",
            status_changed_at=datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ"),
            transcript_file=str(transcript),
            audio_file=str(wav),
        )

        db_path = data_dir / "wilted.db"
        apply_legacy_cutover(db_path, dry_run=False, backup_dir=tmp_path / "backups")
        finalize_post_cutover_db(db_path)
        assert "status_changed_at" not in Item._meta.fields

        refreshed = Item.get_by_id(item.id)
        assert refreshed.discovered_at == old
        assert refreshed.playback_state == "completed"

        cleaned = run_retention(retention_days=30)
        assert cleaned == 1
        assert not transcript.exists()


# ---------------------------------------------------------------------------
# Temporal convention — utc_to_local_date
# ---------------------------------------------------------------------------


class TestUtcToLocalDate:
    def test_z_suffix_parsed(self):
        from wilted.queue import utc_to_local_date

        result = utc_to_local_date("2026-04-17T12:00:00Z")
        # Result should be a valid date string (YYYY-MM-DD)
        assert len(result) == 10
        assert result[4] == "-" and result[7] == "-"

    def test_empty_string(self):
        from wilted.queue import utc_to_local_date

        assert utc_to_local_date("") == ""

    def test_fallback_on_bad_input(self):
        from wilted.queue import utc_to_local_date

        # Falls back to first 10 chars
        assert utc_to_local_date("not-a-date") == "not-a-date"

    def test_utc_midnight_gives_sensible_local_date(self):
        from wilted.queue import utc_to_local_date

        # UTC midnight: local date is either same day or previous day — both valid
        result = utc_to_local_date("2026-04-17T00:00:00Z")
        assert result in ("2026-04-16", "2026-04-17")

    def test_stored_timestamps_end_with_z(self):
        """New items must store timestamps in UTC (Z suffix)."""
        from wilted.queue import add_article

        add_article("Content.", title="UTC check")
        item = Item.select().first()
        assert item.discovered_at.endswith("Z")
        assert item.status_changed_at.endswith("Z")
