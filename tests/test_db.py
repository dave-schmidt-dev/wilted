"""Tests for Phase 1 database layer — db.py, migrate.py, retention, timestamps."""

from __future__ import annotations

import json
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
# migrate.py — field mapping and idempotency
# ---------------------------------------------------------------------------


class TestMigration:
    def _write_queue(self, entries: list[dict]):
        queue_file = wilted.DATA_DIR / "queue.json"
        queue_file.write_text(json.dumps(entries))
        return queue_file

    def test_basic_field_mapping(self):
        from wilted.migrate import run_migration

        self._write_queue(
            [
                {
                    "title": "My Article",
                    "source_url": "https://apple.news/abc",
                    "canonical_url": "https://example.com/article",
                    "words": 500,
                    "file": "1_my-article.txt",
                    "added": "2026-04-01T10:00:00",
                }
            ]
        )
        # Create the transcript file so the migration can resolve it
        (wilted.ARTICLES_DIR / "1_my-article.txt").write_text("body")

        counts = run_migration(wilted.DATA_DIR / "queue.json", wilted.ARTICLES_DIR)
        assert counts["imported"] == 1
        assert counts["errors"] == 0

        item = Item.select().first()
        assert item.title == "My Article"
        assert item.source_url == "https://apple.news/abc"
        assert item.canonical_url == "https://example.com/article"
        assert item.word_count == 500
        assert item.status == "ready"
        assert item.item_type == "article"
        # Timestamp should be UTC (ends with Z)
        assert item.discovered_at.endswith("Z")

    def test_idempotency_by_canonical_url(self):
        from wilted.migrate import run_migration

        entry = {"title": "Dupe", "canonical_url": "https://example.com/dupe", "words": 10}
        self._write_queue([entry])

        run_migration(wilted.DATA_DIR / "queue.json", wilted.ARTICLES_DIR)
        counts2 = run_migration(wilted.DATA_DIR / "queue.json", wilted.ARTICLES_DIR)

        assert counts2["imported"] == 0
        assert counts2["skipped"] == 1
        assert Item.select().count() == 1

    def test_idempotency_by_title_and_source(self):
        from wilted.migrate import run_migration

        entry = {"title": "No URL Article", "source_url": "https://src.com/", "words": 5}
        self._write_queue([entry])

        run_migration(wilted.DATA_DIR / "queue.json", wilted.ARTICLES_DIR)
        counts2 = run_migration(wilted.DATA_DIR / "queue.json", wilted.ARTICLES_DIR)

        assert counts2["skipped"] == 1
        assert Item.select().count() == 1

    def test_missing_queue_file(self):
        from wilted.migrate import run_migration

        counts = run_migration(wilted.DATA_DIR / "nonexistent.json", wilted.ARTICLES_DIR)
        assert counts == {"imported": 0, "skipped": 0, "errors": 0}

    def test_converts_naive_timestamp_to_utc(self):
        from wilted.migrate import run_migration

        self._write_queue([{"title": "Old Item", "added": "2026-01-15T08:30:00"}])
        run_migration(wilted.DATA_DIR / "queue.json", wilted.ARTICLES_DIR)

        item = Item.select().first()
        assert item.discovered_at.endswith("Z"), f"Expected UTC: {item.discovered_at}"

    def test_already_utc_timestamp_unchanged(self):
        from wilted.migrate import run_migration

        self._write_queue([{"title": "UTC Item", "added": "2026-01-15T08:30:00Z"}])
        run_migration(wilted.DATA_DIR / "queue.json", wilted.ARTICLES_DIR)

        item = Item.select().first()
        assert item.discovered_at == "2026-01-15T08:30:00Z"


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
