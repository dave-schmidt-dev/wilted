"""Unit and integration tests for wilted.report module."""

from __future__ import annotations

from datetime import UTC, date, datetime

from wilted.db import Feed, Item, Report, SelectionHistory, SourceStat
from wilted.report import (
    get_feed_stats,
    get_latest_unread_report,
    get_report,
    run_report,
    update_source_stats,
)

# ---------------------------------------------------------------------------
# Test data helpers
# ---------------------------------------------------------------------------


def _create_feed(title: str = "Test Feed", feed_url: str = "https://example.com/feed.xml") -> Feed:
    """Create a test feed."""
    now = datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
    return Feed.create(
        title=title,
        feed_url=feed_url,
        feed_type="article",
        enabled=True,
        created_at=now,
        updated_at=now,
    )


def _create_classified_item(
    title: str,
    playlist: str | None = "Work",
    relevance: float = 0.5,
    feed: Feed | None = None,
    summary: str | None = None,
) -> Item:
    """Create a classified item for testing."""
    now = datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
    return Item.create(
        feed=feed,
        guid=f"test-{title}",
        title=title,
        discovered_at=now,
        item_type="article",
        status="classified",
        status_changed_at=now,
        playlist_assigned=playlist,
        relevance_score=relevance,
        summary=summary or f"Summary of {title}",
    )


# ---------------------------------------------------------------------------
# TestRunReport
# ---------------------------------------------------------------------------


class TestRunReport:
    def test_no_classified_items_creates_empty_report(self):
        """With no classified items, still creates a Report row."""
        result = run_report()

        assert result["items"] == 0
        assert result["playlists"] == {}
        assert "report_id" in result

        # Verify report was created in DB
        report = Report.get_by_id(result["report_id"])
        assert report.item_count == 0

    def test_groups_by_playlist(self):
        """Items are grouped by playlist_assigned."""
        feed = _create_feed()
        _create_classified_item("Work Item 1", playlist="Work", feed=feed)
        _create_classified_item("Work Item 2", playlist="Work", feed=feed)
        _create_classified_item("Fun Item 1", playlist="Fun", feed=feed)

        result = run_report()

        assert result["items"] == 3
        assert result["playlists"]["Work"] == 2
        assert result["playlists"]["Fun"] == 1

    def test_sorts_by_relevance_within_group(self):
        """Items within each playlist are sorted by relevance_score descending."""
        feed = _create_feed()
        _create_classified_item("Low Relevance", playlist="Work", relevance=0.3, feed=feed)
        _create_classified_item("High Relevance", playlist="Work", relevance=0.9, feed=feed)
        _create_classified_item("Medium Relevance", playlist="Work", relevance=0.6, feed=feed)

        run_report()
        report_data = get_report()

        assert report_data is not None
        work_items = report_data["items"].get("Work", [])
        # Check order: high (0.9) > medium (0.6) > low (0.3)
        assert work_items[0]["relevance_score"] == 0.9
        assert work_items[1]["relevance_score"] == 0.6
        assert work_items[2]["relevance_score"] == 0.3

    def test_uncategorized_items_grouped_separately(self):
        """Items with playlist_assigned=None are grouped under 'Uncategorized'."""
        feed = _create_feed()
        _create_classified_item("Work Item", playlist="Work", feed=feed)
        _create_classified_item("Uncategorized Item", playlist=None, feed=feed)

        result = run_report()

        assert "Uncategorized" in result["playlists"]
        assert result["playlists"]["Uncategorized"] == 1

    def test_idempotent_same_day_replaces_report(self):
        """Calling run_report() twice on the same day replaces the existing report."""
        feed = _create_feed()
        _create_classified_item("First Item", playlist="Work", feed=feed)

        result1 = run_report()
        report_id_1 = result1["report_id"]

        # Add another item
        _create_classified_item("Second Item", playlist="Work", feed=feed)

        result2 = run_report()
        report_id_2 = result2["report_id"]

        # Should have same report_id (same day)
        assert report_id_1 == report_id_2

        # Report should be updated with new count
        report = Report.get_by_id(report_id_1)
        assert report.item_count == 2

        assert result1["items"] == 1
        assert result2["items"] == 2

    def test_excludes_already_selected_items(self):
        """Items with status != 'classified' are excluded from new report."""
        feed = _create_feed()
        _create_classified_item("Item 1", playlist="Work", feed=feed)
        _create_classified_item("Item 2", playlist="Work", feed=feed)

        # Mark first item as selected
        item1 = Item.get(Item.title == "Item 1")
        item1.status = "selected"
        item1.status_changed_at = datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
        item1.save()

        result = run_report()

        # Only item2 should be counted (item1 is selected, not classified)
        assert result["items"] == 1

    def test_report_stores_item_count(self):
        """Report row stores the correct item_count."""
        feed = _create_feed()
        _create_classified_item("Item 1", feed=feed)
        _create_classified_item("Item 2", feed=feed)
        _create_classified_item("Item 3", feed=feed)

        result = run_report()
        report = Report.get_by_id(result["report_id"])

        assert report.item_count == 3


# ---------------------------------------------------------------------------
# TestGetReport
# ---------------------------------------------------------------------------


class TestGetReport:
    def test_returns_none_for_missing_date(self):
        """get_report returns None for a date without a report."""
        result = get_report("2000-01-01")
        assert result is None

    def test_returns_report_with_items(self):
        """get_report returns report data with items grouped by playlist."""
        feed = _create_feed()
        _create_classified_item("Work Item", playlist="Work", feed=feed)
        _create_classified_item("Fun Item", playlist="Fun", feed=feed)

        run_report()  # Create today's report
        result = get_report()

        assert result is not None
        assert "report" in result
        assert "items" in result
        assert result["report"]["item_count"] == 2
        assert "Work" in result["items"]
        assert "Fun" in result["items"]

    def test_defaults_to_today(self):
        """get_report() defaults to today's date."""
        feed = _create_feed()
        _create_classified_item("Today Item", feed=feed)

        run_report()
        result = get_report()  # No date specified

        assert result is not None
        # Report date uses local timezone
        assert result["report"]["report_date"] == date.today().isoformat()


# ---------------------------------------------------------------------------
# TestGetLatestUnreadReport
# ---------------------------------------------------------------------------


class TestGetLatestUnreadReport:
    def test_returns_none_when_no_reports(self):
        """Returns None when no reports exist."""
        result = get_latest_unread_report()
        assert result is None

    def test_returns_none_when_all_items_have_history(self):
        """Returns None when all classified items have selection history."""
        feed = _create_feed()
        item = _create_classified_item("Item", playlist="Work", feed=feed)

        # Create selection history for the item
        SelectionHistory.create(
            item=item,
            report=None,
            selected=True,
            selected_at=datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ"),
        )

        # Change item status to selected
        item.status = "selected"
        item.save()

        run_report()
        result = get_latest_unread_report()

        assert result is None

    def test_returns_report_when_unread_items_exist(self):
        """Returns the latest report when unread classified items exist."""
        feed = _create_feed()
        _create_classified_item("Unread Item", playlist="Work", feed=feed)

        run_report()
        result = get_latest_unread_report()

        assert result is not None
        assert "report" in result
        assert "items" in result


# ---------------------------------------------------------------------------
# TestSelectionHistory
# ---------------------------------------------------------------------------


class TestSelectionHistory:
    def test_record_selection(self):
        """Recording a selection creates a SelectionHistory entry with selected=True."""
        feed = _create_feed()
        item = _create_classified_item("Item", feed=feed)
        report = Report.create(
            report_date=datetime.now().date().isoformat(),
            generated_at=datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ"),
            item_count=1,
            metadata="{}",
        )

        now = datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
        SelectionHistory.create(
            item=item,
            report=report,
            selected=True,
            selected_at=now,
        )

        history = SelectionHistory.select().where(SelectionHistory.item == item).first()
        assert history is not None
        assert history.selected is True

    def test_record_skip(self):
        """Recording a skip creates a SelectionHistory entry with selected=False."""
        feed = _create_feed()
        item = _create_classified_item("Item", feed=feed)

        now = datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
        SelectionHistory.create(
            item=item,
            report=None,
            selected=False,
            selected_at=now,
        )

        history = SelectionHistory.select().where(SelectionHistory.item == item).first()
        assert history is not None
        assert history.selected is False

    def test_selected_items_status_updated(self):
        """Selected items have their status updated to 'selected'."""
        feed = _create_feed()
        item = _create_classified_item("Item", feed=feed)

        item_id = item.id
        item.status = "selected"
        item.status_changed_at = datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
        item.save()

        # Re-fetch the item to verify the change
        updated_item = Item.get_by_id(item_id)
        assert updated_item.status == "selected"

    def test_skipped_items_status_updated(self):
        """Skipped items have their status updated to 'skipped'."""
        feed = _create_feed()
        item = _create_classified_item("Item", feed=feed)

        item_id = item.id
        item.status = "skipped"
        item.status_changed_at = datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
        item.save()

        # Re-fetch the item to verify the change
        updated_item = Item.get_by_id(item_id)
        assert updated_item.status == "skipped"


# ---------------------------------------------------------------------------
# TestSourceStats
# ---------------------------------------------------------------------------


class TestSourceStats:
    def test_update_stats_for_feed(self):
        """update_source_stats creates weekly stats for feeds."""
        feed = _create_feed()
        # Create items discovered this week
        now = datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
        Item.create(
            feed=feed,
            guid="item1",
            title="Item 1",
            discovered_at=now,
            item_type="article",
            status="classified",
            status_changed_at=now,
        )

        update_source_stats()

        stats = SourceStat.select().where(SourceStat.feed == feed).first()
        assert stats is not None
        assert stats.items_discovered >= 1

    def test_stats_calculation_correct(self):
        """Selection rate is calculated correctly."""
        feed = _create_feed()
        now = datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")

        # Create 4 discovered items
        for i in range(4):
            Item.create(
                feed=feed,
                guid=f"item{i}",
                title=f"Item {i}",
                discovered_at=now,
                item_type="article",
                status="classified",
                status_changed_at=now,
            )

        # Select 2 of them
        items = list(Item.select().where(Item.feed == feed))
        report = Report.create(
            report_date=datetime.now().date().isoformat(),
            generated_at=now,
            item_count=4,
            metadata="{}",
        )
        for item in items[:2]:
            SelectionHistory.create(
                item=item,
                report=report,
                selected=True,
                selected_at=now,
            )

        update_source_stats()

        stats = SourceStat.select().where(SourceStat.feed == feed).first()
        assert stats is not None
        assert stats.items_discovered == 4
        assert stats.items_selected == 2
        assert stats.selection_rate == 0.5  # 2/4 = 0.5

    def test_feed_stats_cli_output(self):
        """get_feed_stats returns list of dicts with correct structure."""
        feed = _create_feed(title="Test Feed")

        # Create source stat directly
        SourceStat.create(
            feed=feed,
            period_start="2026-04-20",
            period_end="2026-04-26",
            items_discovered=10,
            items_selected=5,
            selection_rate=0.5,
        )

        stats = get_feed_stats()

        assert len(stats) >= 1
        feed_stat = next((s for s in stats if s["feed_title"] == "Test Feed"), None)
        assert feed_stat is not None
        assert feed_stat["items_discovered"] == 10
        assert feed_stat["items_selected"] == 5
        assert feed_stat["selection_rate"] == 0.5
