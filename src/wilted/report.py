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
from datetime import date, datetime

from wilted.background_work.contracts import ReportDecision
from wilted.background_work.contracts import ReportItem as ReportItemContract
from wilted.content_state import (
    items_for_report,
    legacy_display_status,
    predicate_report_candidates,
    regenerate_report_membership,
    selection_history_available,
)
from wilted.db import Feed, Item, Report, ReportItem, SelectionHistory, SourceStat
from wilted.db import ensure_db as _ensure_db
from wilted.db import now_utc as _now_utc

logger = logging.getLogger(__name__)


def _local_date_str() -> str:
    """Get today's date as YYYY-MM-DD in local timezone."""
    return date.today().isoformat()


def assemble_report(report_date: str | None = None) -> dict:
    """Assemble a morning report snapshot with stable ReportItem membership.

    Groups classified candidates by playlist, sorts by relevance, persists a
    Report row, and regenerates pending ReportItem membership for the date.

    Args:
        report_date: ISO date string (YYYY-MM-DD). Defaults to today.

    Returns:
        Dict with stats: ``items``, ``playlists``, ``report_id``.
    """
    _ensure_db()

    today = report_date or _local_date_str()

    existing = Report.select().where(Report.report_date == today).first()
    classified_items = items_for_report()

    playlists: dict[str, list[Item]] = {}
    for item in classified_items:
        playlist = item.playlist_assigned or "Uncategorized"
        playlists.setdefault(playlist, []).append(item)

    for playlist_name in playlists:
        playlists[playlist_name].sort(
            key=lambda i: i.relevance_score if i.relevance_score is not None else 0,
            reverse=True,
        )

    playlist_counts: dict[str, int] = {k: len(v) for k, v in playlists.items()}
    if playlist_counts.get("Uncategorized", 0) == 0:
        playlist_counts.pop("Uncategorized", None)

    total_items = sum(playlist_counts.values())
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

    rank = 0
    proposed_pending: list[ReportItemContract] = []
    for playlist_name in sorted(playlists.keys()):
        for item in playlists[playlist_name]:
            proposed_pending.append(
                ReportItemContract(
                    report_id=report_id,
                    item_id=str(item.id),
                    rank=rank,
                    decision=ReportDecision.PENDING,
                ),
            )
            rank += 1

    regenerate_report_membership(report_id, tuple(proposed_pending))

    return {
        "items": total_items,
        "playlists": playlist_counts,
        "report_id": report_id,
    }


def run_report() -> dict:
    """Assemble a morning report from classified items.

    Synchronous helper for worker-thread callers (e.g. TUI report check).
    CLI and ingest use :func:`run_report_via_runner` instead.

    Returns:
        Dict with stats: ``items``, ``playlists``, ``report_id``.
    """
    return assemble_report()


def reset_latest_report() -> dict | None:
    """Undo the user's decisions on the most recent report so it can be reviewed again.

    Reverts every decided ``ReportItem`` on the latest report back to ``PENDING`` and
    returns any item that *the acceptance queued* (``preparation_state == QUEUED``) to
    ``NOT_QUEUED``, so it re-qualifies as a report candidate. Items that were already
    prepared, played, or queued independently of this report are left untouched. Then
    re-assembles the report so membership and counts reflect the restored candidates.

    Returns:
        Stats dict with ``report_id``, ``report_date``, ``cleared`` (decisions reset),
        ``requeued_cleared`` (items returned to the pool), and ``candidates`` (items now
        showable). ``None`` when no report exists.
    """
    import dataclasses

    from wilted.background_work.contracts import PreparationState
    from wilted.content_state import read_content_state, transition_item

    _ensure_db()

    latest = Report.select().order_by(Report.report_date.desc()).first()
    if latest is None:
        return None

    decided = list(
        ReportItem.select().where((ReportItem.report == latest) & (ReportItem.decision != ReportDecision.PENDING.value))
    )

    requeued_cleared = 0
    for report_item in decided:
        item = report_item.item
        current = read_content_state(item)
        # Compare by value, not enum identity: test suites that reload the
        # contracts module leave two PreparationState classes in play, and an
        # `is` check would silently misfire. Values ('queued') are stable.
        if current is not None and current.preparation.value == PreparationState.QUEUED.value:
            # Only un-queue work the acceptance itself queued; never un-prepare
            # already-generated audio (READY) or clobber independently queued items.
            transition_item(item, dataclasses.replace(current, preparation=PreparationState.NOT_QUEUED))
            requeued_cleared += 1
        # Clear the decision *before* re-assembly: regenerate_report_membership
        # preserves decided rows, so a still-accepted row would never resurface.
        report_item.decision = ReportDecision.PENDING.value
        report_item.defer_until = None
        report_item.save()

    stats = assemble_report(latest.report_date)

    logger.info(
        "Reset report #%d (%s): cleared %d decision(s), returned %d item(s) to the candidate pool",
        latest.id,
        latest.report_date,
        len(decided),
        requeued_cleared,
    )
    return {
        "report_id": latest.id,
        "report_date": latest.report_date,
        "cleared": len(decided),
        "requeued_cleared": requeued_cleared,
        "candidates": stats["items"],
    }


def _items_seen_in_prior_reports(report_date: str) -> set[int]:
    """Item ids that appeared in any report generated before ``report_date``.

    Report membership is durable and never rewritten across days
    (:func:`wilted.background_work.transitions.apply_report_regeneration` only
    touches the same report's pending rows), so an item's first report
    appearance is a stable signal. The morning email uses this to surface only
    items new since the previous report instead of re-sending the whole
    undecided candidate pool every day.
    """
    prior_report_ids = [r.id for r in Report.select(Report.id).where(Report.report_date < report_date)]
    if not prior_report_ids:
        return set()
    return {ri.item_id for ri in ReportItem.select(ReportItem.item).where(ReportItem.report << prior_report_ids)}


def get_report(report_date: str | None = None, *, new_only: bool = False) -> dict | None:
    """Retrieve a report and its items.

    Args:
        report_date: ISO date string (YYYY-MM-DD). Defaults to today.
        new_only: When True, exclude candidates that appeared in any earlier
            report — used by the morning email so it shows only what is new
            since the last report, not the cumulative undecided pool.

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
    all_classified = items_for_report()

    if new_only:
        seen_before = _items_seen_in_prior_reports(report_date)
        all_classified = [item for item in all_classified if item.id not in seen_before]

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
                "status": legacy_display_status(item),
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

    # Classified/discovered candidates without a durable report decision.
    # Pre-cutover DBs also exclude any item that already has a SelectionHistory row.
    unread_clause = predicate_report_candidates()
    if selection_history_available():
        unread_clause = unread_clause & ~(
            Item.id << SelectionHistory.select(SelectionHistory.item).where(SelectionHistory.item.is_null(False))
        )
    unread_items = Item.select().where(unread_clause).exists()

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
        if selection_history_available():
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
        else:
            items_selected = (
                ReportItem.select()
                .join(Item)
                .where(
                    (ReportItem.decision == ReportDecision.ACCEPTED.value)
                    & (Item.feed == feed)
                    & (ReportItem.created_at >= week_start_str)
                )
                .count()
            )

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
        (subject, body) tuple, or None if no report exists or nothing is new
        since the previous report (so the nightly run skips an empty email).
        Subject format: "Wilted Morning Report -- Apr 20"
        Body: plain text with playlist groups, titles, relevance scores, summaries.
    """
    # Only items new since the last report — never re-send the whole undecided
    # pool, so a report the user already triaged does not reappear each morning.
    data = get_report(report_date, new_only=True)
    if data is None or not data["items"]:
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
