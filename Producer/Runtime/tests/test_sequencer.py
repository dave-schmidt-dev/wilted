"""Tests for ``wilted.station_runtime.sequencer.EntrySequencer``.

Covers the 14-day freshness boundary (+/-1 day plus the exact-14-day
decision), PM-11 admit-with-warning for missing/unparseable ``published_at``,
existing playlist/queue ordering, ``next()`` draining to exhaustion, and
per-item normalization-failure isolation (INV-6).

``normalize_item`` is monkeypatched at the sequencer's import site so the
freshness/ordering/isolation logic is what's under test, not the real media
pipeline (which would require actual published audio artifacts).
"""

from __future__ import annotations

import logging
from datetime import UTC, datetime, timedelta

import pytest

from wilted.db import Item
from wilted.station.models import FinalizationState, MediaDescriptor, SafeInterruptionMap
from wilted.station_runtime import sequencer as sequencer_mod
from wilted.station_runtime.sequencer import EntrySequencer

pytestmark = pytest.mark.unit

_NOW = datetime(2026, 7, 10, 12, 0, 0, tzinfo=UTC)


# ---------------------------------------------------------------------------
# Shared builders (mirrors tests/test_station_controller.py's patterns)
# ---------------------------------------------------------------------------


def _finalized_media(**overrides) -> MediaDescriptor:
    defaults = dict(
        sha256="a" * 64,
        byte_size=1024,
        mime_type="audio/mpeg",
        duration_ms=60_000,
        transcript_segments=(),
        safe_interruption=SafeInterruptionMap.empty(),
        byte_range_available=False,
        finalization=FinalizationState.complete(),
    )
    defaults.update(overrides)
    return MediaDescriptor(**defaults)


def _iso(dt: datetime) -> str:
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def _make_item(
    *,
    title: str = "Test Item",
    status: str = "ready",
    item_type: str = "article",
    published_at: str | None = None,
    discovered_at: str | None = None,
    source_name: str | None = "test-feed",
) -> Item:
    now = _iso(datetime.now(UTC))
    return Item.create(
        guid=f"test-{title}-{now}-{id(object())}",
        title=title,
        source_name=source_name,
        published_at=published_at,
        discovered_at=discovered_at or now,
        item_type=item_type,
        status=status,
        status_changed_at=now,
    )


@pytest.fixture(autouse=True)
def _stub_normalize(monkeypatch):
    """Replace normalize_item with a synthetic MediaDescriptor factory.

    Keeps the sequencer's own ordering/freshness logic under test rather than
    the real media pipeline (which needs actually-published audio bytes).
    """

    def _fake_normalize_item(item: Item) -> MediaDescriptor:
        return _finalized_media(duration_ms=1000 * item.id)

    monkeypatch.setattr(sequencer_mod, "normalize_item", _fake_normalize_item)
    yield


# ---------------------------------------------------------------------------
# 14-day freshness boundary
# ---------------------------------------------------------------------------


class TestFreshnessCap:
    def test_13_days_old_is_admitted(self, isolated_data):
        _make_item(published_at=_iso(_NOW - timedelta(days=13)))

        backlog = EntrySequencer.build(now=_NOW)

        assert len(backlog.entries) == 1

    def test_exactly_14_days_old_is_admitted(self, isolated_data):
        # Boundary decision: the cap excludes items STRICTLY MORE than 14
        # days old, so exactly-14-days-old is still admitted.
        _make_item(published_at=_iso(_NOW - timedelta(days=14)))

        backlog = EntrySequencer.build(now=_NOW)

        assert len(backlog.entries) == 1

    def test_15_days_old_is_excluded(self, isolated_data):
        _make_item(published_at=_iso(_NOW - timedelta(days=15)))

        backlog = EntrySequencer.build(now=_NOW)

        assert len(backlog.entries) == 0

    def test_14_days_and_one_second_old_is_excluded(self, isolated_data):
        # Sharper probe on the same exact-14-day boundary decision: one
        # second past the cap must already be excluded.
        _make_item(published_at=_iso(_NOW - timedelta(days=14, seconds=1)))

        backlog = EntrySequencer.build(now=_NOW)

        assert len(backlog.entries) == 0


# ---------------------------------------------------------------------------
# PM-11 admit-with-warning
# ---------------------------------------------------------------------------


class TestAdmitWithWarning:
    def test_missing_published_at_is_admitted_with_warning(self, isolated_data, caplog):
        _make_item(published_at=None)

        with caplog.at_level(logging.WARNING, logger="wilted.station_runtime.sequencer"):
            backlog = EntrySequencer.build(now=_NOW)

        assert len(backlog.entries) == 1
        assert any("published_at" in msg for msg in caplog.messages)

    def test_unparseable_published_at_is_admitted_with_warning(self, isolated_data, caplog):
        _make_item(published_at="not-a-date")

        with caplog.at_level(logging.WARNING, logger="wilted.station_runtime.sequencer"):
            backlog = EntrySequencer.build(now=_NOW)

        assert len(backlog.entries) == 1
        assert any("published_at" in msg for msg in caplog.messages)


# ---------------------------------------------------------------------------
# Ordering matches the existing playlist/queue order
# ---------------------------------------------------------------------------


class TestOrdering:
    def test_backlog_orders_by_discovered_at_ascending(self, isolated_data):
        oldest = _make_item(
            title="oldest",
            published_at=_iso(_NOW - timedelta(days=1)),
            discovered_at=_iso(_NOW - timedelta(days=3)),
        )
        middle = _make_item(
            title="middle",
            published_at=_iso(_NOW - timedelta(days=1)),
            discovered_at=_iso(_NOW - timedelta(days=2)),
        )
        newest = _make_item(
            title="newest",
            published_at=_iso(_NOW - timedelta(days=1)),
            discovered_at=_iso(_NOW - timedelta(days=1)),
        )

        backlog = EntrySequencer.build(now=_NOW)

        assert [e.item_id for e in backlog.entries] == [str(oldest.id), str(middle.id), str(newest.id)]

    def test_only_ready_and_selected_statuses_are_included(self, isolated_data):
        _make_item(title="fetched", status="fetched", published_at=_iso(_NOW))
        _make_item(title="completed", status="completed", published_at=_iso(_NOW))
        ready = _make_item(title="ready", status="ready", published_at=_iso(_NOW))
        selected = _make_item(title="selected", status="selected", published_at=_iso(_NOW))

        backlog = EntrySequencer.build(now=_NOW)

        assert {e.item_id for e in backlog.entries} == {str(ready.id), str(selected.id)}


# ---------------------------------------------------------------------------
# next() sequencing
# ---------------------------------------------------------------------------


class TestNext:
    def test_next_returns_entries_in_order_then_none(self, isolated_data):
        first = _make_item(title="first", published_at=_iso(_NOW), discovered_at=_iso(_NOW - timedelta(days=2)))
        second = _make_item(title="second", published_at=_iso(_NOW), discovered_at=_iso(_NOW - timedelta(days=1)))

        backlog = EntrySequencer.build(now=_NOW)

        assert backlog.next().item_id == str(first.id)
        assert backlog.next().item_id == str(second.id)
        assert backlog.next() is None
        # Exhaustion is sticky — repeated calls keep returning None.
        assert backlog.next() is None

    def test_next_on_empty_backlog_returns_none(self, isolated_data):
        backlog = EntrySequencer.build(now=_NOW)

        assert backlog.next() is None

    def test_remaining_counts_down_as_next_drains(self, isolated_data):
        _make_item(title="a", published_at=_iso(_NOW))
        _make_item(title="b", published_at=_iso(_NOW))

        backlog = EntrySequencer.build(now=_NOW)

        assert backlog.remaining() == 2
        backlog.next()
        assert backlog.remaining() == 1
        backlog.next()
        assert backlog.remaining() == 0


# ---------------------------------------------------------------------------
# Per-item normalization failure isolation (INV-6)
# ---------------------------------------------------------------------------


class TestNormalizationIsolation:
    def test_one_failing_item_is_skipped_without_aborting_the_backlog(self, isolated_data, monkeypatch, caplog):
        good_first = _make_item(
            title="good-first", published_at=_iso(_NOW), discovered_at=_iso(_NOW - timedelta(days=2))
        )
        failing = _make_item(
            title="failing", published_at=_iso(_NOW), discovered_at=_iso(_NOW - timedelta(days=1, hours=12))
        )
        good_second = _make_item(
            title="good-second", published_at=_iso(_NOW), discovered_at=_iso(_NOW - timedelta(days=1))
        )

        def _flaky_normalize_item(item: Item) -> MediaDescriptor:
            if item.id == failing.id:
                raise RuntimeError("simulated normalization failure")
            return _finalized_media(duration_ms=1000 * item.id)

        monkeypatch.setattr(sequencer_mod, "normalize_item", _flaky_normalize_item)

        with caplog.at_level(logging.WARNING, logger="wilted.station_runtime.sequencer"):
            backlog = EntrySequencer.build(now=_NOW)

        assert [e.item_id for e in backlog.entries] == [str(good_first.id), str(good_second.id)]
        assert any("normalization" in msg for msg in caplog.messages)
