"""Report assembly stage — group classified items into morning reports.

Stage 3 of the nightly pipeline. Groups classified items by playlist,
sorts by relevance, and creates a Report record. Instant, no models loaded.

Usage:
    from wilted.report import run_report, get_report, get_latest_unread_report

    stats = run_report()  # {'items': 12, 'playlists': {'Work': 5, ...}, 'report_id': 1}
    report = get_report()  # Get today's report
    unread = get_latest_unread_report()  # For TUI launch check
"""

from __future__ import annotations

import json
import logging
from datetime import UTC, date, datetime

from wilted.db import Feed, Item, Report, SelectionHistory, SourceStat

logger = logging.getLogger(__name__)


def _now_utc() -> str:
    return datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def _ensure_db() -> None:
    from wilted import DATA_DIR
    from wilted.db import connect_db

    connect_db(DATA_DIR / "wilted.db")


def _local_date_str() -> str:
    """Get today's date as YYYY-MM-DD in local timezone."""
    return date.today().isoformat()


def run_report() -> dict:
    """Assemble a morning report from classified items.

    Groups classified items by playlist, sorts by relevance, stores
    a Report record. Idempotent per day — regenerates if called again
    on the same date.

    Returns:
        Dict with stats: {'items': int, 'playlists': dict[str, int], 'report_id': int}
    """
    _ensure_db()

    today = _local_date_str()

    # Check if a report already exists for today
    existing = Report.select().where(Report.report_date == today).first()

    # Get classified items that haven't been selected or skipped yet
    # Exclude items with status != 'classified'
    classified_items = list(
        Item.select().where(Item.status == "classified").order_by(Item.relevance_score.desc(nulls="last"))
    )

    # Group items by playlist_assigned
    playlists: dict[str, list[Item]] = {}
    for item in classified_items:
        playlist = item.playlist_assigned or "Uncategorized"
        if playlist not in playlists:
            playlists[playlist] = []
        playlists[playlist].append(item)

    # Sort within each group by relevance_score descending
    for playlist_name in playlists:
        playlists[playlist_name].sort(
            key=lambda i: i.relevance_score if i.relevance_score is not None else 0,
            reverse=True,
        )

    # Count items per playlist
    playlist_counts: dict[str, int] = {k: len(v) for k, v in playlists.items()}

    # If Uncategorized is empty, remove it from the dict
    if playlist_counts.get("Uncategorized", 0) == 0:
        playlist_counts.pop("Uncategorized", None)

    total_items = sum(playlist_counts.values())

    # Store or update report
    metadata = {
        "playlists": playlist_counts,
        "total_items": total_items,
    }

    if existing:
        existing.item_count = total_items
        existing.metadata = json.dumps(metadata)
        existing.generated_at = _now_utc()
        existing.save()
        report_id = existing.id
        logger.info("Updated existing report #%d for %s: %d items", report_id, today, total_items)
    else:
        report = Report.create(
            report_date=today,
            generated_at=_now_utc(),
            item_count=total_items,
            metadata=json.dumps(metadata),
        )
        report_id = report.id
        logger.info("Created report #%d for %s: %d items", report_id, today, total_items)

    return {
        "items": total_items,
        "playlists": playlist_counts,
        "report_id": report_id,
    }


def get_report(report_date: str | None = None) -> dict | None:
    """Retrieve a report and its items.

    Args:
        report_date: ISO date string (YYYY-MM-DD). Defaults to today.

    Returns:
        Dict with 'report': Report row dict, 'items': list of Item rows grouped
        by playlist, or None if no report exists for that date.
    """
    _ensure_db()

    if report_date is None:
        report_date = _local_date_str()

    try:
        report = Report.get(Report.report_date == report_date)
    except Report.DoesNotExist:
        return None

    # Get all classified items — same criteria as run_report()
    all_classified = list(
        Item.select().where(Item.status == "classified").order_by(Item.relevance_score.desc(nulls="last"))
    )

    # Group by playlist
    playlists: dict[str, list[dict]] = {}
    for item in all_classified:
        playlist = item.playlist_assigned or "Uncategorized"
        if playlist not in playlists:
            playlists[playlist] = []
        playlists[playlist].append(
            {
                "id": item.id,
                "title": item.title,
                "source_name": item.source_name,
                "relevance_score": item.relevance_score,
                "summary": item.summary,
                "feed_id": item.feed.id if item.feed else None,
                "status": item.status,
            }
        )

    # Remove empty playlists
    playlists = {k: v for k, v in playlists.items() if v}

    return {
        "report": {
            "report_date": report.report_date,
            "generated_at": report.generated_at,
            "item_count": report.item_count,
            "metadata": json.loads(report.metadata) if report.metadata else {},
        },
        "items": playlists,
    }


def get_latest_unread_report() -> dict | None:
    """Get the most recent report that has unselected items.

    Used by the TUI to decide whether to show the ReportScreen on launch.
    A report is 'unread' if it has classified items with no corresponding
    selection_history entries.

    Returns:
        Dict with 'report' and 'items' keys, or None if no unread report exists.
    """
    _ensure_db()

    # Use NOT EXISTS to find classified items without selection history in one query
    # Then get the latest report that has items matching those
    unread_items = (
        Item.select()
        .where(
            (Item.status == "classified")
            & ~(Item.id << SelectionHistory.select(SelectionHistory.item).where(SelectionHistory.item.is_null(False)))
        )
        .exists()
    )

    if not unread_items:
        return None

    # Get the latest report
    latest_report = Report.select().order_by(Report.report_date.desc()).first()
    if latest_report:
        return get_report(latest_report.report_date)

    return None


def update_source_stats() -> None:
    """Aggregate selection rates per feed for the current week.

    Called after selection. Updates source_stats table.
    """
    _ensure_db()

    from datetime import timedelta

    today = date.today()
    week_start = today - timedelta(days=today.weekday())
    week_end = week_start + timedelta(days=6)

    week_start_str = week_start.isoformat()
    week_end_str = week_end.isoformat()

    # Get all feeds
    feeds = list(Feed.select())

    for feed in feeds:
        # Count discovered items for this feed in the current week
        discovered = list(Item.select().where((Item.feed == feed) & (Item.discovered_at >= week_start_str)))
        items_discovered = len(discovered)

        # Count selected items for this feed in the current week
        selected = list(
            SelectionHistory.select()
            .join(Item)
            .where(
                (SelectionHistory.selected == True)  # noqa: E712
                & (Item.feed == feed)
                & (SelectionHistory.selected_at >= week_start_str)
            )
        )
        items_selected = len(selected)

        selection_rate = items_selected / items_discovered if items_discovered > 0 else None

        # Update or create source stat for this period
        try:
            stat = SourceStat.get((SourceStat.feed == feed) & (SourceStat.period_start == week_start_str))
            stat.items_discovered = items_discovered
            stat.items_selected = items_selected
            stat.selection_rate = selection_rate
            stat.period_end = week_end_str
            stat.save()
        except SourceStat.DoesNotExist:
            SourceStat.create(
                feed=feed,
                period_start=week_start_str,
                period_end=week_end_str,
                items_discovered=items_discovered,
                items_selected=items_selected,
                selection_rate=selection_rate,
            )


def format_report_email(report_date: str | None = None) -> tuple[str, str] | None:
    """Format the morning report as plain text email.

    Args:
        report_date: ISO date (YYYY-MM-DD), defaults to today.

    Returns:
        (subject, body) tuple, or None if no report exists.
        Subject format: "Wilted Morning Report -- Apr 20"
        Body: plain text with playlist groups, titles, relevance scores, summaries.
    """
    data = get_report(report_date)
    if data is None:
        return None

    # Parse the report date for the subject line
    report_date_str = data["report"]["report_date"]
    parsed_date = datetime.strptime(report_date_str, "%Y-%m-%d").date()
    date_label = parsed_date.strftime("%b %-d")  # e.g. "Apr 20"

    subject = f"Wilted Morning Report -- {date_label}"

    # Build body
    lines: list[str] = [f"Wilted Morning Report -- {date_label}", ""]

    playlists = data["items"]
    total = 0
    for playlist_name, items in playlists.items():
        lines.append(f"=== {playlist_name} ===")
        for item in items:
            score = item["relevance_score"]
            score_str = f"{score:.2f}" if score is not None else "n/a"
            lines.append(f"[{score_str}] {item['title']}")
            if item.get("summary"):
                lines.append(f"      {item['summary']}")
            lines.append("")
        total += len(items)

    lines.append(f"Total items: {total}")

    body = "\n".join(lines)
    return subject, body


def get_feed_stats(feed_id: int | None = None) -> list[dict]:
    """Get selection stats. All feeds if feed_id is None.

    Args:
        feed_id: Optional feed ID to filter by.

    Returns:
        List of dicts with feed info and stats.
    """
    _ensure_db()

    if feed_id is not None:
        stats = list(SourceStat.select().where(SourceStat.feed == feed_id).order_by(SourceStat.period_start.desc()))
    else:
        stats = list(SourceStat.select().join(Feed).order_by(Feed.id, SourceStat.period_start.desc()))

    result = []
    for stat in stats:
        result.append(
            {
                "feed_id": stat.feed.id if stat.feed else None,
                "feed_title": stat.feed.title if stat.feed else "Unknown",
                "period_start": stat.period_start,
                "period_end": stat.period_end,
                "items_discovered": stat.items_discovered,
                "items_selected": stat.items_selected,
                "selection_rate": stat.selection_rate,
            }
        )

    return result
