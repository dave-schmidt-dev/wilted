"""Build and drain an ordered backlog of station ``StationEntry`` objects.

``EntrySequencer`` bridges the durable, substrate-dependent queue
(:mod:`wilted.db` ``Item`` rows, ordered the same way
:func:`wilted.playlists.get_playlist_items` / ``wilted.queue`` already order
the user-facing "All" queue) into the substrate-neutral station contract
(:class:`wilted.station.models.StationEntry`), so a controller can auto-advance
via ``StartPlayback(sequencer.next())``.

Two admission rules govern which items make the backlog at all:

- **14-day freshness cap**: an item whose ``published_at`` is more than 14
  days older than ``now`` is excluded outright — it is considered stale news
  and never enters the backlog.
- **PM-11 admit-with-warning**: a ``published_at`` that is either ``None`` or
  unparseable does NOT exclude the item. Missing/bad publish-date metadata is
  a data-quality gap, not a reason to silently drop content the user
  discovered and expects to hear — the item is admitted and a WARNING is
  logged so the gap is visible without aborting the backlog build.

Per-item normalization failures are isolated (INV-6): if
:func:`wilted.station_runtime.normalize.normalize_item` raises for one item,
that item is skipped with a WARNING and the rest of the backlog is still
built/played — one bad item must never abort the whole sequence.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from typing import TYPE_CHECKING

from wilted.content_state import items_for_playlist_all
from wilted.station.models import StationEntry
from wilted.station_runtime.normalize import normalize_item

if TYPE_CHECKING:
    from collections.abc import Sequence

    from wilted.db import Item

logger = logging.getLogger(__name__)

__all__ = ["EntrySequencer"]

# PM-11 / freshness cap: items published more than this many days before
# "now" are excluded from the backlog outright.
_FRESHNESS_CAP_DAYS = 14

# Same cohort the "All" playlist admits (wilted.playlists.get_playlist_items),
# ordered the same way (Item.discovered_at ascending) — the sequencer follows
# that EXISTING ordering rather than inventing a new one.

_DEFAULT_PRIORITY = 5


def _parse_utc_z(timestamp: str) -> datetime:
    """Parse a UTC ISO-8601 'Z' string (e.g. ``wilted.db.now_utc()``'s format).

    Mirrors the parsing idiom already used at call sites across the codebase
    (``wilted.playlists``, ``wilted.queue``): ``fromisoformat`` after
    substituting the literal ``Z`` suffix for an explicit UTC offset. Raises
    ``ValueError`` on anything that doesn't match — callers are expected to
    catch that and fall back to the PM-11 admit-with-warning path rather than
    propagating it.
    """
    return datetime.fromisoformat(timestamp.replace("Z", "+00:00"))


def _is_stale(item: Item, *, now: datetime) -> bool:
    """Return True if *item* must be excluded under the 14-day freshness cap.

    A missing or unparseable ``published_at`` is NOT staleness — that is the
    PM-11 admit-with-warning case, handled by the caller before this is ever
    reached. This function only decides the freshness-cap boundary for a
    successfully parsed publish date.

    Boundary semantics (inclusive cap): an item is excluded only when it is
    STRICTLY MORE than 14 days old. An item exactly 14 days old (age ==
    timedelta(days=14)) is admitted — the cutoff is "older than 14 days", not
    "14 days or older". So: 13 days old -> admitted, exactly 14 days old ->
    admitted, 15 days old -> excluded.
    """
    published = _parse_utc_z(item.published_at)
    age = now - published
    return age > timedelta(days=_FRESHNESS_CAP_DAYS)


def _admit(item: Item, *, now: datetime) -> bool:
    """Return True if *item* should be admitted into the backlog.

    Implements both admission rules:

    - ``published_at is None`` -> admit-with-warning (PM-11): a missing
      publish date is a data-quality gap, not grounds for exclusion.
    - Unparseable ``published_at`` -> same admit-with-warning treatment: one
      bad date string must not silently drop content from the backlog.
    - Otherwise, apply the 14-day freshness cap.
    """
    if item.published_at is None:
        logger.warning(
            "item %r has no published_at; admitting into backlog without a freshness check",
            item.id,
        )
        return True

    try:
        stale = _is_stale(item, now=now)
    except (ValueError, TypeError):
        logger.warning(
            "item %r has unparseable published_at %r; admitting into backlog without a freshness check",
            item.id,
            item.published_at,
        )
        return True

    return not stale


def _source_for(item: Item) -> str:
    """Derive a ``StationEntry.source`` provenance string for *item*.

    Mirrors the ``"feed:<name>"`` convention used elsewhere (e.g.
    ``tests/test_station_store.py``'s ``source="feed:npr-news"``).
    ``Item.source_name`` is nullable, so falls back to a generic label rather
    than embedding ``None`` in the string.
    """
    if item.source_name:
        return f"feed:{item.source_name}"
    return "feed:unknown"


def _entry_id_for(item: Item) -> str:
    """Derive a stable, immutable ``StationEntry.entry_id`` from *item*.

    Prefixed with the item's durable DB id, which never changes for the life
    of the row, so re-building the backlog from the same items always
    produces the same entry ids (INV-3's "stable id" rule lifted to the
    station layer, per ``StationEntry.entry_id``'s docstring).
    """
    return f"item-{item.id}"


def _to_station_entry(item: Item) -> StationEntry:
    """Normalize *item* and wrap the result into a ``StationEntry``.

    ``kind="item"`` for all backlog entries produced here — bulletins are a
    session-scoped concept the sequencer never produces. Raises whatever
    :func:`normalize_item` raises (``ItemNotFinalizedError``,
    ``ArticleCacheIncompleteError``, etc.); the caller isolates that failure
    per-item rather than this function swallowing it.
    """
    media = normalize_item(item)
    return StationEntry(
        entry_id=_entry_id_for(item),
        kind="item",
        item_id=str(item.id),
        source=_source_for(item),
        policy_id=None,
        priority=_DEFAULT_PRIORITY,
        expiry=None,
        duration_ms=media.duration_ms,
        media=media,
    )


@dataclass
class EntrySequencer:
    """Produces an ordered backlog of ``StationEntry`` objects to play.

    Construct with :meth:`build`, which queries and filters ``Item`` rows,
    then drain one at a time with :meth:`next` until it returns ``None``.

    Attributes:
        entries: The backlog, in playback order. Populated by :meth:`build`;
            left empty if constructed directly without calling it.
    """

    entries: list[StationEntry] = field(default_factory=list)
    _position: int = field(default=0, repr=False)

    @classmethod
    def build(cls, *, now: datetime | None = None) -> EntrySequencer:
        """Query eligible ``Item`` rows and normalize them into a backlog.

        Args:
            now: The instant to treat as "now" for the 14-day freshness cap.
                Defaults to the current UTC time. Accepting this as a
                parameter (rather than calling a bare clock internally) keeps
                the freshness decision deterministic and testable.

        Ordering: follows the EXISTING "All" playlist/queue order — active
        preparation cohort sorted by ``discovered_at`` ascending (oldest
        discovered first). See ``wilted.playlists.get_playlist_items`` and
        ``wilted.queue``'s analogous query.

        Admission: each item is first checked against the freshness cap /
        PM-11 admit-with-warning rule (see :func:`_admit`). Admitted items are
        then normalized via :func:`wilted.station_runtime.normalize.normalize_item`
        and wrapped into a ``StationEntry``. If normalization raises for one
        item, that item is skipped with a WARNING (INV-6 per-item isolation)
        and the rest of the backlog is still built.

        Returns:
            A new ``EntrySequencer`` with :attr:`entries` populated in
            playback order.
        """
        resolved_now = now if now is not None else datetime.now(UTC)

        items: Sequence[Item] = items_for_playlist_all()

        entries: list[StationEntry] = []
        for item in items:
            if not _admit(item, now=resolved_now):
                continue
            try:
                entries.append(_to_station_entry(item))
            except Exception:
                logger.warning(
                    "item %r failed normalization; skipping without aborting the backlog",
                    item.id,
                    exc_info=True,
                )
                continue

        return cls(entries=entries)

    def next(self) -> StationEntry | None:
        """Return the next ``StationEntry`` in the backlog, or None if exhausted.

        Each call advances the internal position by one, so repeated calls
        drain the backlog in order; once exhausted, every subsequent call
        keeps returning ``None``.
        """
        if self._position >= len(self.entries):
            return None
        entry = self.entries[self._position]
        self._position += 1
        return entry

    def remaining(self) -> int:
        """Return the count of entries not yet returned by :meth:`next`."""
        return max(0, len(self.entries) - self._position)
