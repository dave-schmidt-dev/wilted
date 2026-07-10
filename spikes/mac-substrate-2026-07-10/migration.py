"""Read-only Item -> StationEntry/MediaDescriptor migration-cost reader.

Measures what it costs to map the existing SQLite ``Item`` shape
(``wilted.db.Item``, see ``src/wilted/db.py:162-211``) into the committed
station value objects (``wilted.station.models``). This is a measurement
tool for Task 0.3, not a production migration — it is deliberately minimal
and read-only.

Isolation (INV-5): this module NEVER opens the real ``data/wilted.db``. It
only operates against a caller-supplied SQLite path (typically a temp file
or ``:memory:``-backed temp path created by :func:`seed_isolated_db`, which
mirrors the ``isolated_data`` autouse fixture in ``tests/conftest.py``:
``reset_db()`` then ``run_migrations(path)`` against a path under a temp
directory, never ``wilted.DATA_DIR``).

Normalizes the pre-existing inconsistency described in the design doc and
confirmed in the Phase 0 inventory: article ``Item.audio_file`` is a
directory (per-paragraph MP3 cache), while podcast ``Item.audio_file`` is a
single file path. Both are normalized into one ``MediaDescriptor`` shape by
:func:`item_to_station_entry` — see its docstring for exactly which fields
have no clean equivalent and are filled with a conservative placeholder.
"""

from __future__ import annotations

import logging
import tempfile
from pathlib import Path
from typing import TYPE_CHECKING

from wilted.db import Item, reset_db, run_migrations
from wilted.station.models import (
    FinalizationState,
    MediaDescriptor,
    SafeInterruptionMap,
    StationEntry,
)

if TYPE_CHECKING:
    from collections.abc import Iterator

logger = logging.getLogger(__name__)

# Items whose transcript/duration data is missing get a conservative
# zero-duration, unfinalized placeholder rather than a guess — a migrated
# entry must never claim finalization it cannot prove (mirrors INV-4's
# "no pipeline stage may publish empty/unfinalized content").
_PLACEHOLDER_SHA256 = ""


def seed_isolated_db(db_path: Path) -> None:
    """Initialize an isolated SQLite DB at ``db_path`` and apply migrations.

    Mirrors the ``isolated_data`` autouse fixture in ``tests/conftest.py``
    (``reset_db()`` then ``run_migrations(path)``). Never touches
    ``wilted.DATA_DIR`` or the real ``data/`` tree — the caller is
    responsible for choosing an isolated ``db_path`` (a temp file).

    Args:
        db_path: Filesystem path for the isolated SQLite database. Created
            if it does not already exist.
    """
    reset_db()
    run_migrations(db_path)


def seed_sample_items() -> tuple[Item, Item]:
    """Create one representative article ``Item`` and one podcast ``Item``.

    Must be called after :func:`seed_isolated_db` has pointed the Peewee
    connection at an isolated database. Field shapes mirror real
    ``run_prepare()`` output (``src/wilted/prepare.py``): article
    ``audio_file`` is a directory, podcast ``audio_file`` is a file path.

    Returns:
        ``(article_item, podcast_item)``.
    """
    now = "2026-07-10T12:00:00Z"

    article_item = Item.create(
        guid="migration-spike-article-1",
        title="A Sample Article",
        source_name="NPR",
        source_url="https://example.org/article-1",
        discovered_at=now,
        item_type="article",
        status="ready",
        status_changed_at=now,
        word_count=850,
        duration_seconds=480.0,
        transcript_file="data/articles/1_a-sample-article.txt",
        # Article audio_file is a DIRECTORY (per-paragraph MP3 cache dir) —
        # see prepare.py:_prepare_article, DATA_DIR / "audio" / str(item_id).
        audio_file="data/audio/1",
    )

    podcast_item = Item.create(
        guid="migration-spike-podcast-1",
        title="A Sample Podcast Episode",
        source_name="Sample Podcast",
        source_url="https://example.org/podcast/ep-1",
        canonical_url="https://example.org/podcast/ep-1",
        discovered_at=now,
        item_type="podcast_episode",
        status="ready",
        status_changed_at=now,
        duration_seconds=5400.0,
        transcript_file="data/transcripts/2_transcript.json",
        enclosure_url="https://example.org/podcast/ep-1.mp3",
        enclosure_type="audio/mpeg",
        # Podcast audio_file is a single FILE — see
        # prepare.py:_prepare_podcast, download_podcast() return value.
        audio_file="data/podcasts/2/episode.mp3",
    )

    return article_item, podcast_item


def item_to_station_entry(item: Item, *, priority: int = 5) -> StationEntry:
    """Map one ``Item`` row into a ``StationEntry``/``MediaDescriptor`` pair.

    This is the measured mapping. Field-by-field:

    - ``entry_id``      <- ``f"item-{item.id}"`` (Item.id is an int PK; the
                            station contract requires a stable string id).
    - ``kind``           <- always ``"item"`` (Items are never bulletins).
    - ``item_id``        <- ``str(item.id)``.
    - ``source``         <- ``item.source_name`` or ``item.source_url``,
                            falling back to ``"unknown"``.
    - ``policy_id``      <- always ``None`` (Items carry no policy/ranking
                            provenance — that concept does not exist on the
                            current schema).
    - ``priority``       <- NO CLEAN EQUIVALENT. ``Item`` has no priority
                            column; the caller must assign one (defaulted
                            here to the same "unprivileged" 5 used by the
                            fixture's article/podcast entries).
    - ``expiry``         <- always ``None`` (Items don't expire in the
                            current schema; only ``Playlist`` rows have
                            ``expiry_days``, and that's playlist-level, not
                            per-item).
    - ``duration_ms``    <- ``item.duration_seconds * 1000`` if set, else 0.
    - ``media.sha256``   <- NO CLEAN EQUIVALENT. The current schema never
                            computes or stores a content hash for
                            ``audio_file``/``transcript_file`` (that's new
                            with ``MediaDescriptor``/INV-4). Left empty
                            here, which correctly keeps ``finalization``
                            from claiming ``published=True`` (see
                            ``__post_init__``'s INV-4 check).
    - ``media.byte_size``<- NO CLEAN EQUIVALENT. Never stored on ``Item``;
                            would need a filesystem stat of ``audio_file``,
                            which this read-only reader deliberately does
                            not perform (measuring schema mapping cost, not
                            doing I/O against real media).
    - ``media.mime_type``<- ``item.enclosure_type`` if set (podcasts),
                            else a hardcoded ``"audio/mpeg"`` guess for
                            articles (Item has no article MIME column).
    - ``media.duration_ms`` <- same source as the entry's ``duration_ms``.
    - ``media.transcript_segments`` <- NO CLEAN EQUIVALENT. ``Item`` only
                            stores a *path* to a transcript file
                            (``transcript_file``); the segments themselves
                            live in a separate JSON file this reader does
                            not open (would require ``transcribe.py``'s
                            JSON schema, out of scope for a schema-mapping
                            measurement). Left empty.
    - ``media.safe_interruption`` <- NO CLEAN EQUIVALENT, follows directly
                            from the above: no transcript segments read
                            means no safe map can be derived here, so this
                            always maps to ``SafeInterruptionMap.empty()``
                            (explicit no-interrupt) rather than a guess.
    - ``media.byte_range_available`` <- NO CLEAN EQUIVALENT. Never modeled
                            on ``Item``. Defaulted to ``False``
                            (conservative: whole-file access only).
    - ``media.finalization`` <- NO CLEAN EQUIVALENT, and not merely
                            "approximate": ``item.status in ("ready",
                            "completed")`` looks like a natural match for
                            ``FinalizationState.complete()``, but
                            ``MediaDescriptor.__post_init__`` (INV-4)
                            *rejects* ``published=True`` when ``sha256`` is
                            empty or ``byte_size`` is 0 — which this reader
                            always has, since it deliberately does not hash
                            or stat the real audio file (see
                            ``media.sha256``/``media.byte_size`` above).
                            Concretely: a real migration cannot claim
                            "finalized" from ``status`` alone; it must also
                            hash and size the artifact, which is I/O this
                            schema-mapping measurement is scoped to avoid.
                            This function therefore always maps to the
                            all-``False`` default ``FinalizationState()``
                            regardless of ``status`` — the honest
                            reflection of "unproven", not an approximation
                            of "probably ready".

    Args:
        item: A ``wilted.db.Item`` row (article or podcast episode).
        priority: Priority to assign the migrated entry (no Item column
            maps to this concept — see above).

    Returns:
        The mapped ``StationEntry``.
    """
    source = item.source_name or item.source_url or "unknown"
    duration_ms = int(item.duration_seconds * 1000) if item.duration_seconds else 0
    mime_type = item.enclosure_type or "audio/mpeg"

    media = MediaDescriptor(
        sha256=_PLACEHOLDER_SHA256,
        byte_size=0,
        mime_type=mime_type,
        duration_ms=duration_ms,
        transcript_segments=(),
        safe_interruption=SafeInterruptionMap.empty(),
        byte_range_available=False,
        # Always unfinalized: this reader never hashes/stats the real audio
        # file, so it cannot honestly claim FinalizationState.complete()
        # regardless of item.status — see the docstring's media.finalization
        # entry (INV-4 rejects published=True with empty sha256/byte_size=0).
        finalization=FinalizationState(),
    )

    return StationEntry(
        entry_id=f"item-{item.id}",
        kind="item",
        item_id=str(item.id),
        source=source,
        policy_id=None,
        priority=priority,
        expiry=None,
        duration_ms=duration_ms,
        media=media,
    )


def run_migration_measurement() -> dict[str, object]:
    """Seed an isolated DB, migrate its rows, and return measured stats.

    Returns:
        A dict with ``item_count``, ``mapped_entries`` (list of
        ``StationEntry``), and ``unmapped_fields`` (the field names from
        the docstring of :func:`item_to_station_entry` that have no clean
        ``Item`` equivalent), for ``measure.py``/the scorecard to report.
    """
    with tempfile.TemporaryDirectory(prefix="wilted-spike-migration-") as tmp_dir:
        db_path = Path(tmp_dir) / "spike-isolated.db"
        seed_isolated_db(db_path)
        try:
            article_item, podcast_item = seed_sample_items()
            entries = [item_to_station_entry(article_item), item_to_station_entry(podcast_item)]
        finally:
            reset_db()

    return {
        "item_count": len(entries),
        "mapped_entries": entries,
        "unmapped_fields": (
            "priority",
            "media.sha256",
            "media.byte_size",
            "media.transcript_segments",
            "media.safe_interruption",
            "media.byte_range_available",
            "media.finalization",
        ),
    }


def _iter_mapped_entries() -> Iterator[StationEntry]:
    """Yield the two sample-mapped entries (helper for ad hoc inspection)."""
    result = run_migration_measurement()
    yield from result["mapped_entries"]  # type: ignore[misc]


__all__ = [
    "item_to_station_entry",
    "run_migration_measurement",
    "seed_isolated_db",
    "seed_sample_items",
]
