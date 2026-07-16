"""Orthogonal content-state persistence, query predicates, and transitions.

Production modules query orthogonal columns via the predicate helpers in this
module. Legacy ``Item.status`` is mirrored only through :func:`transition_item`
and :func:`backfill_orthogonal_from_legacy` for pre-cutover databases.
"""

from __future__ import annotations

import dataclasses
import logging

from peewee import fn

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
from wilted.background_work.legacy_mapping import LegacyStatus
from wilted.background_work.transitions import apply_report_regeneration, transition_retention
from wilted.db import Item, Report, ReportItem, SelectionHistory, now_utc

logger = logging.getLogger(__name__)


def read_content_state(item: Item) -> ContentState | None:
    """Read orthogonal content facts from an Item row.

    Returns ``None`` when no orthogonal columns have been populated yet.
    """
    if not any(
        (
            item.fetch_state,
            item.analysis_state,
            item.preparation_state,
            item.playback_state,
            item.retention_state,
        )
    ):
        return None

    retention = RetentionFacts(
        state=RetentionState(item.retention_state or RetentionState.ACTIVE.value),
        keep_override=bool(item.keep),
        expired_at=item.retention_expires_at if item.retention_state == RetentionState.EXPIRED.value else None,
    )
    return ContentState(
        fetch=FetchState(item.fetch_state or FetchState.METADATA.value),
        analysis=AnalysisState(item.analysis_state or AnalysisState.PENDING.value),
        preparation=PreparationState(item.preparation_state or PreparationState.NOT_QUEUED.value),
        playback=PlaybackState(item.playback_state or PlaybackState.UNPLAYED.value),
        retention=retention,
    )


def write_content_state(item: Item, state: ContentState) -> Item:
    """Persist orthogonal content facts onto an Item row.

    Does not update the legacy ``status`` column. ``item.keep`` mirrors
    ``state.retention.keep_override``.
    """
    item.fetch_state = state.fetch.value
    item.analysis_state = state.analysis.value
    item.preparation_state = state.preparation.value
    item.playback_state = state.playback.value
    item.retention_state = state.retention.state.value
    item.retention_expires_at = state.retention.expired_at
    item.keep = state.retention.keep_override
    item.save()
    return item


def apply_mapped_content_state(item: Item, state: ContentState) -> Item:
    """Apply mapped orthogonal state, preserving an explicit ``item.keep`` flag.

    Single write path for legacy backfill and destructive cutover so both
    agree on retention/keep semantics.
    """
    return write_content_state(item, _preserve_item_keep(state, item))


def legacy_status_for_state(state: ContentState, item_type: str) -> str:
    """Best-effort legacy ``status`` mirror for pre-cutover databases."""
    if state.retention.state is RetentionState.EXPIRED and not state.retention.keep_override:
        return LegacyStatus.EXPIRED.value
    if (
        state.fetch is FetchState.ERROR
        or state.analysis is AnalysisState.ERROR
        or state.preparation is PreparationState.ERROR
    ):
        return LegacyStatus.ERROR.value
    if state.playback is PlaybackState.COMPLETED:
        return LegacyStatus.COMPLETED.value
    if state.preparation is PreparationState.READY:
        return LegacyStatus.READY.value
    if state.preparation is PreparationState.QUEUED:
        return LegacyStatus.SELECTED.value
    if state.analysis is AnalysisState.READY:
        return LegacyStatus.CLASSIFIED.value
    if state.fetch is FetchState.CONTENT_READY:
        return LegacyStatus.FETCHED.value
    if state.fetch is FetchState.METADATA:
        return LegacyStatus.DISCOVERED.value
    if item_type == "article":
        return LegacyStatus.FETCHED.value
    return LegacyStatus.DISCOVERED.value


def legacy_display_status(item: Item) -> str:
    """Return a display/status string derived from orthogonal facts when present."""
    state = read_content_state(item)
    if state is not None:
        return legacy_status_for_state(state, item.item_type)
    return item.status


def transition_item(
    item: Item,
    state: ContentState,
    *,
    sync_legacy_status: bool = True,
    legacy_status: str | None = None,
    error_message: str | None = None,
) -> Item:
    """Write orthogonal content state and optionally mirror legacy ``status``.

    Args:
        item: Item row to update.
        state: Target orthogonal content facts.
        sync_legacy_status: When True and the legacy ``status`` column exists,
            set it to ``legacy_status`` or a best-effort mirror.
        legacy_status: Explicit legacy status override (e.g. ``processing``).
        error_message: Optional error message to persist on the item.
    """
    write_content_state(item, state)
    if error_message is not None:
        item.error_message = error_message
    if sync_legacy_status and hasattr(item, "status"):
        item.status = legacy_status or legacy_status_for_state(state, item.item_type)
        item.status_changed_at = now_utc()
    item.save()
    return item


def _preserve_item_keep(state: ContentState, item: Item) -> ContentState:
    """Fold an explicit ``item.keep`` flag into orthogonal retention facts."""
    if not item.keep:
        return state
    return dataclasses.replace(
        state,
        retention=RetentionFacts(
            state=state.retention.state,
            keep_override=True,
            expired_at=state.retention.expired_at,
        ),
    )


def backfill_orthogonal_from_legacy(item: Item) -> Item:
    """Map legacy ``status`` to orthogonal columns using the authoritative table.

    Uses artifact inspection consistent with :mod:`wilted.legacy_cutover`.
    No-op when ``fetch_state`` is already populated.
    """
    if item.fetch_state is not None:
        return item

    import wilted
    from wilted.legacy_cutover import map_item_row

    outcome = map_item_row(item, wilted.DATA_DIR)
    if outcome.quarantine or outcome.content is None:
        logger.warning(
            "Skipping orthogonal backfill for item #%d: %s",
            item.id,
            outcome.quarantine_reason or "quarantined cohort",
        )
        return item

    apply_mapped_content_state(item, outcome.content)
    return item


def backfill_items_with_null_fetch_state() -> int:
    """Backfill all items whose orthogonal columns have not been populated."""
    items = list(Item.select().where(Item.fetch_state.is_null(True)))
    for item in items:
        backfill_orthogonal_from_legacy(item)
    if items:
        logger.info("Backfilled orthogonal content state for %d item(s)", len(items))
    return len(items)


# ---------------------------------------------------------------------------
# Production query predicates (replace legacy status cohort queries)
# ---------------------------------------------------------------------------


def predicate_pending_classification():
    """Items awaiting classification (legacy ``fetched``)."""
    return (Item.fetch_state == FetchState.CONTENT_READY.value) & (Item.analysis_state == AnalysisState.PENDING.value)


def _report_decided_item_ids():
    """Items with a non-pending report decision (accepted, deferred, or dismissed)."""
    return ReportItem.select(ReportItem.item).where(ReportItem.decision != ReportDecision.PENDING.value)


def _legacy_skipped_item_ids():
    """Items explicitly skipped in a prior report (legacy ``SelectionHistory``)."""
    return SelectionHistory.select(SelectionHistory.item).where(SelectionHistory.selected == False)  # noqa: E712


def predicate_report_candidates():
    """Report/briefing candidates: classified articles and discovered podcast episodes.

    Excludes items the user already decided on (``ReportItem``) or skipped
    (legacy ``SelectionHistory``), matching the old ``status == 'classified'``
    cohort that implicitly excluded ``skipped`` rows.
    """
    article_candidates = (
        (Item.item_type == "article")
        & (Item.analysis_state == AnalysisState.READY.value)
        & (Item.preparation_state == PreparationState.NOT_QUEUED.value)
        & (Item.retention_state == RetentionState.ACTIVE.value)
    )
    podcast_candidates = (
        (Item.item_type == "podcast_episode")
        & (Item.fetch_state == FetchState.METADATA.value)
        & (Item.analysis_state == AnalysisState.PENDING.value)
        & (Item.preparation_state == PreparationState.NOT_QUEUED.value)
        & (Item.retention_state == RetentionState.ACTIVE.value)
    )
    undecided = ~(Item.id << _report_decided_item_ids()) & ~(Item.id << _legacy_skipped_item_ids())
    return (article_candidates | podcast_candidates) & undecided


def _accepted_report_item_ids():
    return ReportItem.select(ReportItem.item).where(ReportItem.decision == ReportDecision.ACCEPTED.value)


def predicate_prepare_queue():
    """Items selected for preparation (legacy ``selected``)."""
    accepted_needing_prep = (
        (Item.id << _accepted_report_item_ids())
        & (Item.preparation_state != PreparationState.READY.value)
        & (Item.preparation_state != PreparationState.ERROR.value)
        & (Item.playback_state != PlaybackState.COMPLETED.value)
    )
    return (Item.preparation_state == PreparationState.QUEUED.value) | accepted_needing_prep


def predicate_playable_ready():
    """Prepared, not-yet-completed items (legacy ``ready``)."""
    return (
        (Item.preparation_state == PreparationState.READY.value)
        & (Item.playback_state != PlaybackState.COMPLETED.value)
        & (Item.retention_state == RetentionState.ACTIVE.value)
    )


def predicate_playable_queue():
    """Playable queue items (legacy ``ready`` or ``selected`` articles)."""
    queued_article = (
        (Item.preparation_state == PreparationState.QUEUED.value)
        & (Item.item_type == "article")
        & (Item.retention_state == RetentionState.ACTIVE.value)
    )
    return predicate_playable_ready() | queued_article


def predicate_playlist_active():
    """Playlist-visible items (legacy ``ready`` or ``selected``)."""
    return (
        Item.preparation_state.in_((PreparationState.READY.value, PreparationState.QUEUED.value))
        & (Item.playback_state != PlaybackState.COMPLETED.value)
        & (Item.retention_state == RetentionState.ACTIVE.value)
    )


def predicate_retention_cleanup():
    """Completed items eligible for file retention cleanup."""
    return (Item.playback_state == PlaybackState.COMPLETED.value) & (Item.keep == False)  # noqa: E712


def items_pending_classification() -> list[Item]:
    """Return items whose fetch/analysis state matches the classify cohort."""
    return list(Item.select().where(predicate_pending_classification()))


def items_for_report() -> list[Item]:
    """Return classified items eligible for morning report assembly."""
    return list(Item.select().where(predicate_report_candidates()).order_by(Item.relevance_score.desc(nulls="last")))


def items_for_prepare() -> list[Item]:
    """Return items queued for the prepare stage."""
    return list(Item.select().where(predicate_prepare_queue()).order_by(Item.discovered_at))


def items_playable_in_queue() -> list[Item]:
    """Return playable queue items in display order."""
    return list(Item.select().where(predicate_playable_queue()).order_by(Item.discovered_at))


def items_playable_ready_only() -> list[Item]:
    """Return only fully prepared queue rows (legacy ready-only subset)."""
    return list(Item.select().where(predicate_playable_ready()).order_by(Item.discovered_at))


def items_for_playlist_all() -> list[Item]:
    """Return items for the dynamic ``All`` playlist."""
    return list(Item.select().where(predicate_playlist_active()).order_by(Item.discovered_at.asc()))


def items_for_playlist_dynamic(playlist_name: str) -> list[Item]:
    """Return active items for a named dynamic playlist."""
    effective = fn.COALESCE(Item.playlist_override, Item.playlist_assigned)
    return list(
        Item.select()
        .where(predicate_playlist_active() & (effective == playlist_name))
        .order_by(Item.relevance_score.desc())
    )


def items_for_retention_cleanup() -> list[Item]:
    """Return completed items subject to retention file cleanup."""
    return list(Item.select().where(predicate_retention_cleanup()))


def report_item_to_contract(row: ReportItem) -> ReportItemContract:
    """Convert a durable report membership row to the contract value object."""
    return ReportItemContract(
        report_id=row.report_id,
        item_id=str(row.item_id),
        rank=row.rank,
        decision=ReportDecision(row.decision),
        defer_until=row.defer_until,
    )


def load_report_membership(report_id: int | None = None) -> tuple[ReportItemContract, ...]:
    """Load report membership rows, optionally scoped to one report."""
    query = ReportItem.select().order_by(ReportItem.report_id, ReportItem.rank)
    if report_id is not None:
        query = query.where(ReportItem.report == report_id)
    return tuple(report_item_to_contract(row) for row in query)


def persist_report_membership(rows: tuple[ReportItemContract, ...]) -> list[ReportItem]:
    """Replace all report membership rows with the provided contract tuple.

    Intended for tests and future report assembly; callers must supply the
    full desired membership set for affected reports.
    """
    if not rows:
        return []

    report_ids = {row.report_id for row in rows}
    created_at = now_utc()
    persisted: list[ReportItem] = []

    with ReportItem._meta.database.atomic():
        ReportItem.delete().where(ReportItem.report_id << list(report_ids)).execute()
        for row in rows:
            persisted.append(
                ReportItem.create(
                    report=row.report_id,
                    item=int(row.item_id),
                    rank=row.rank,
                    decision=row.decision.value,
                    defer_until=row.defer_until,
                    created_at=created_at,
                )
            )
    return persisted


def regenerate_report_membership(
    report_id: int,
    proposed_pending: tuple[ReportItemContract, ...],
) -> tuple[ReportItemContract, ...]:
    """Apply same-day report regeneration to durable membership rows.

    Uses :func:`wilted.background_work.transitions.apply_report_regeneration` to
    replace pending-only rows while preserving decided and cross-report history.
    """
    existing = load_report_membership()
    updated = apply_report_regeneration(existing, proposed_pending, report_id=report_id)

    report_ids = {row.report_id for row in updated}
    created_at = now_utc()

    with ReportItem._meta.database.atomic():
        ReportItem.delete().where(ReportItem.report_id << list(report_ids)).execute()
        for row in updated:
            ReportItem.create(
                report=row.report_id,
                item=int(row.item_id),
                rank=row.rank,
                decision=row.decision.value,
                defer_until=row.defer_until,
                created_at=created_at,
            )

    logger.info(
        "Regenerated report membership for report_id=%d (%d rows total)",
        report_id,
        len(updated),
    )
    return updated


def apply_retention_expiry(item: Item, *, now: str | None = None) -> Item:
    """Expire retention when ``retention_expires_at`` has passed.

    Honors ``item.keep`` as a keep override via :func:`transition_retention`.
    No-op when orthogonal retention columns are unset or expiry is not due.
    """
    if not item.retention_expires_at:
        return item

    current = read_content_state(item)
    if current is None:
        return item

    now_ts = now or now_utc()
    if now_ts < item.retention_expires_at:
        return item

    updated_retention = transition_retention(
        current.retention,
        RetentionState.EXPIRED,
        expires_at=item.retention_expires_at,
        now=now_ts,
    )
    new_state = ContentState(
        fetch=current.fetch,
        analysis=current.analysis,
        preparation=current.preparation,
        playback=current.playback,
        retention=updated_retention,
    )
    return transition_item(
        item,
        new_state,
        legacy_status=legacy_status_for_state(new_state, item.item_type),
    )


def items_with_fetch_state(fetch: FetchState) -> list[Item]:
    """Return items whose orthogonal fetch state matches ``fetch``."""
    return list(Item.select().where(Item.fetch_state == fetch.value))


def items_with_retention_state(retention: RetentionState) -> list[Item]:
    """Return items whose orthogonal retention state matches ``retention``."""
    return list(Item.select().where(Item.retention_state == retention.value))


def report_items_for_date(report_date: str) -> list[ReportItem]:
    """Return ordered report membership rows for a calendar report date."""
    return list(ReportItem.select().join(Report).where(Report.report_date == report_date).order_by(ReportItem.rank))


def create_report_item(
    *,
    report: Report | int,
    item: Item | int,
    rank: int,
    decision: ReportDecision = ReportDecision.PENDING,
    defer_until: str | None = None,
) -> ReportItem:
    """Create one report membership row with contract validation."""
    contract = ReportItemContract(
        report_id=report.id if isinstance(report, Report) else report,
        item_id=str(item.id if isinstance(item, Item) else item),
        rank=rank,
        decision=decision,
        defer_until=defer_until,
    )
    return ReportItem.create(
        report=contract.report_id,
        item=int(contract.item_id),
        rank=contract.rank,
        decision=contract.decision.value,
        defer_until=contract.defer_until,
        created_at=now_utc(),
    )


__all__ = [
    "apply_mapped_content_state",
    "apply_retention_expiry",
    "backfill_items_with_null_fetch_state",
    "backfill_orthogonal_from_legacy",
    "create_report_item",
    "items_for_playlist_all",
    "items_for_playlist_dynamic",
    "items_for_prepare",
    "items_for_report",
    "items_for_retention_cleanup",
    "items_pending_classification",
    "items_playable_in_queue",
    "items_playable_ready_only",
    "items_with_fetch_state",
    "items_with_retention_state",
    "legacy_display_status",
    "legacy_status_for_state",
    "load_report_membership",
    "persist_report_membership",
    "predicate_pending_classification",
    "predicate_playable_queue",
    "predicate_playable_ready",
    "predicate_playlist_active",
    "predicate_prepare_queue",
    "predicate_report_candidates",
    "predicate_retention_cleanup",
    "read_content_state",
    "regenerate_report_membership",
    "report_item_to_contract",
    "report_items_for_date",
    "transition_item",
    "write_content_state",
]
