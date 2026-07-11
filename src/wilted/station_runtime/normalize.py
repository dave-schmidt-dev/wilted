"""Normalize a durable DB ``Item`` (podcast or article) into a ``MediaDescriptor``.

This is the substrate-dependent glue between the durable database
(:mod:`wilted.db`) and the substrate-neutral station contract
(:mod:`wilted.station.models`). It reads the DB, resolves media through the
content-addressed store (:mod:`wilted.station_runtime.media_store`), and —
for articles — delegates to :mod:`wilted.station_runtime.article_assembly`.

Media resolution never hands out ``Item.audio_file`` directly: podcasts are
published into the content-addressed store via
:func:`wilted.station_runtime.media_store.publish_file` and articles are
assembled+published via
:func:`wilted.station_runtime.article_assembly.assemble_article_audio`. Both
paths mean the ``MediaDescriptor`` always refers to immutable, hash-addressed
bytes rather than a mutable filesystem path the DB row could later change out
from under a caller.

PM-1 (``spikes/integration-seam-2026-07-10/FINDINGS.md``): there are two
distinct ``TranscriptSegment`` types in this codebase —
``wilted.transcribe.TranscriptSegment`` (float **seconds**) and
``wilted.station.models.TranscriptSegment`` (int **milliseconds**). The only
conversion between them for podcast transcripts must live in exactly one
place: :func:`_transcribe_segment_to_station_ms`. Do not scatter ``* 1000`` /
``/ 1000`` at other call sites.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

from wilted.station.models import FinalizationState, MediaDescriptor, SafeInterruptionMap
from wilted.station.models import TranscriptSegment as StationTranscriptSegment
from wilted.station_runtime import media_store
from wilted.station_runtime.article_assembly import assemble_article_audio
from wilted.station_runtime.timing_map import save_timing_map

if TYPE_CHECKING:
    from wilted.db import Item
    from wilted.transcribe import TranscriptSegment as SecondsTranscriptSegment

__all__ = [
    "ItemNotFinalizedError",
    "normalize_item",
]

_MIME_TYPE_AUDIO_MPEG = "audio/mpeg"

# Matching tolerance (± ms) around each transcript-boundary safe point.
#
# This MUST be non-zero, and here is the closed-loop reasoning (a zero band
# shipped a station whose weather bulletin could never interrupt real
# playback):
#
# The bulletin interrupt path is pinned between two constraints that only a
# tolerance band can satisfy together:
#   1. The reducer (reducer.py:446) AND the TUI submitter
#      (`_maybe_submit_pending_bulletin`) both gate on
#      `safe_interruption.safe_point_at(offset)` against the entry's map.
#   2. HAZARD 2 (see `_maybe_submit_pending_bulletin`'s docstring) REQUIRES the
#      offset passed to AcceptInterruption to be the LIVE
#      `adapter.current_offset_ms()` — never a snapped/future boundary — or the
#      interrupted entry is checkpointed ahead of where playback actually is and
#      resume skips audio.
# So the live offset itself must satisfy `safe_point_at`. A zero-width
# (start_ms, start_ms) window requires the live, continuously-advancing offset
# to land on an EXACT millisecond — a probability-zero event — so the bulletin
# never fires (observed: article/podcast plays straight through a fired
# trigger). The earlier "callers snap via nearest_safe_point first" plan is
# unimplementable here precisely because HAZARD 2 forbids submitting that
# snapped value.
#
# A band makes `safe_point_at(live_offset)` true whenever playback is within
# ±band of a real transcript boundary; the LIVE offset is still what gets
# submitted/checkpointed, so resume stays exact. 1000 ms is chosen so the
# window (2000 ms wide) is comfortably larger than the UI's 1 s poll tick — the
# live offset advances ~1000 ms per tick, so a narrower window could be skipped
# between ticks. This does NOT claim ±1000 ms is silent (measured: only ~70% of
# boundaries have silence within ±250 ms); it lands the interrupt within ~1 s of
# a real transcript boundary, which is the right tradeoff for an emergency
# bulletin. This is the single tuning knob for that tolerance.
_SAFE_INTERRUPTION_BAND_MS = 1000


class ItemNotFinalizedError(Exception):
    """Raised when a podcast ``Item`` cannot be normalized because it is not prepared.

    Specifically: ``item.audio_file`` is ``None``, or points to a missing or
    zero-byte file. A ``MediaDescriptor`` can never be honestly constructed
    in this case — publishing would require real bytes to hash, and building
    an unpublished/unfinalized descriptor with a fabricated sha256 would be
    worse than refusing outright (see module docstring "Unfinalized items"
    discussion in the task spec). Raised BEFORE any call to
    ``media_store.publish_file``, so no blob is ever published for a
    not-actually-finalized item.

    Articles have their own, pre-existing analogue:
    :class:`wilted.station_runtime.article_assembly.ArticleCacheIncompleteError`,
    which is allowed to propagate unmodified from this module.
    """


def _transcribe_segment_to_station_ms(segment: SecondsTranscriptSegment) -> StationTranscriptSegment:
    """Convert one ``wilted.transcribe.TranscriptSegment`` (seconds) to station ms.

    This is the SINGLE conversion point for podcast transcripts (PM-1): every
    caller that needs a station-shaped, millisecond ``TranscriptSegment`` from
    a seconds-based transcript segment must route through this function
    rather than writing ``* 1000`` / ``/ 1000`` inline elsewhere.

    ``round()`` (not ``int()`` truncation) is used for both bounds so a
    segment like ``start_s=1.2345`` rounds to the nearest millisecond
    (``1235``ms) instead of always rounding down.
    """
    return StationTranscriptSegment(
        start_ms=round(segment.start_s * 1000),
        end_ms=round(segment.end_s * 1000),
        text=segment.text,
    )


def _safe_interruption_for(segments: tuple[StationTranscriptSegment, ...]) -> SafeInterruptionMap:
    """Build the safe-interruption map for a resolved set of transcript segments.

    The no-transcript rule: if there are no segments at all (a podcast with
    no transcript file, or a transcript file that failed to load / was
    empty), the item is explicitly NO_INTERRUPT
    (:meth:`SafeInterruptionMap.empty`) rather than silently getting an empty
    WINDOWED map — those are not the same state (see
    ``InterruptionMode`` docstring in ``station/models.py``). This is
    independent of playability: a no-transcript podcast can still be fully
    playable, just not safely interruptible.
    """
    if not segments:
        return SafeInterruptionMap.empty()
    return SafeInterruptionMap.from_transcript_segments(segments, band_ms=_SAFE_INTERRUPTION_BAND_MS)


def _resolve_podcast_media(item: Item) -> tuple[str, int, tuple[StationTranscriptSegment, ...], int]:
    """Resolve a podcast Item's media, transcript, and duration.

    Refuses (raises :class:`ItemNotFinalizedError`) BEFORE publishing if
    ``item.audio_file`` is unset, missing, or zero-byte — a not-actually-
    prepared podcast must never be published into the content-addressed
    store.

    Returns:
        ``(sha256, byte_size, transcript_segments, duration_ms)``.
    """
    from pathlib import Path

    if not item.audio_file:
        raise ItemNotFinalizedError(f"item {item.id!r}: podcast has no audio_file set; not finalized")

    audio_path = Path(item.audio_file)
    if not audio_path.exists() or audio_path.stat().st_size == 0:
        raise ItemNotFinalizedError(
            f"item {item.id!r}: podcast audio_file {item.audio_file!r} is missing or zero-byte; not finalized"
        )

    sha256 = media_store.publish_file(audio_path)
    published_path = media_store.path_for(sha256)
    if published_path is None:
        # publish_file os.replace's the blob to exactly the content-addressed
        # path path_for checks, so this should be unreachable from this
        # module's own flow — surfaced as a real error rather than silently
        # swallowed, in case something external deletes the blob in between.
        raise RuntimeError(
            f"media_store.publish_file reported {sha256} for item {item.id!r} but "
            "path_for returned None (published blob vanished immediately after publish)"
        )
    byte_size = published_path.stat().st_size

    transcript_segments: tuple[StationTranscriptSegment, ...] = ()
    if item.transcript_file:
        from wilted.transcribe import load_transcript

        loaded = load_transcript(Path(item.transcript_file))
        if loaded:
            transcript_segments = tuple(_transcribe_segment_to_station_ms(seg) for seg in loaded)

    if transcript_segments:
        duration_ms = transcript_segments[-1].end_ms
    elif item.duration_seconds is not None:
        duration_ms = round(item.duration_seconds * 1000)
    else:
        duration_ms = 0

    return sha256, byte_size, transcript_segments, duration_ms


def normalize_item(item: Item) -> MediaDescriptor:
    """Normalize a durable DB ``Item`` into a finalized ``MediaDescriptor``.

    Branches on ``item.item_type``:

    - ``"article"``: delegates entirely to
      :func:`wilted.station_runtime.article_assembly.assemble_article_audio`,
      which concatenates the per-paragraph cache, publishes it into the
      content-addressed store, and returns the cumulative timing map. Lets
      :class:`~wilted.station_runtime.article_assembly.ArticleCacheIncompleteError`
      propagate unmodified if the cache is not complete.
    - ``"podcast_episode"``: publishes ``item.audio_file`` into the
      content-addressed store (never hands out the raw, mutable path) and,
      if a transcript is available, converts it to station-shaped
      millisecond segments via the single tested conversion helper
      (:func:`_transcribe_segment_to_station_ms`). Raises
      :class:`ItemNotFinalizedError` before publishing if ``audio_file`` is
      unset or points at a missing/zero-byte file.

    FinalizationState: a resolved item (media published, sha computed, and a
    known playback duration) is always fully finalized
    (:meth:`FinalizationState.complete`), REGARDLESS of whether a transcript
    exists — playability and interruptibility are independent facts. See
    :attr:`MediaDescriptor.is_playable` docstring reasoning for why:

    - ``ads_cut=True``: for articles this is vacuously true (promo removal is
      a pre-TTS text-domain operation — see
      ``article_assembly`` module docstring); for podcasts, ``prepare.py``
      cuts ads before ever setting ``Item.audio_file``, so by the time this
      function runs the audio is already post-ad-cut.
    - ``timing_map_created=True``: playback duration is known — from the
      article assembly's cumulative segment map, or from a podcast's
      transcript/``duration_seconds`` (in that preference order).
    - ``hashed=True`` / ``published=True``: the media has been published
      into the content-addressed store above, which is exactly what
      "hashed" and "published" mean here.

    ``mime_type`` is hardcoded to ``"audio/mpeg"`` — both podcast and
    assembled-article artifacts in this codebase are mp3. ``byte_range_available``
    is hardcoded to ``False`` — MVP scope is whole-file access only; revisit
    if resumable/streamed byte-range playback is ever added.

    Args:
        item: A ``wilted.db.Item`` instance (``item_type`` must be
            ``"article"`` or ``"podcast_episode"``).

    As a final step (Task 2.5), the resolved ``(sha256, transcript_segments)``
    pair is persisted via
    :func:`wilted.station_runtime.timing_map.save_timing_map` — atomically,
    content-addressed by ``sha256`` — so a later caller can reload the
    timing map without re-deriving it. This always runs, even when
    ``transcript_segments`` is empty (the no-transcript case): an empty
    timing map is itself meaningful (distinct from "never normalized"), and
    the write is idempotent, so re-normalizing the same item harmlessly
    rewrites the same file.

    Returns:
        A fully-resolved, playable :class:`MediaDescriptor`.

    Raises:
        ItemNotFinalizedError: Podcast with no/missing/zero-byte
            ``audio_file``. No blob is published in this case.
        wilted.station_runtime.article_assembly.ArticleCacheIncompleteError:
            Article whose per-paragraph cache is not complete.
        ValueError: If ``item.item_type`` is neither ``"article"`` nor
            ``"podcast_episode"`` (should be unreachable given the DB CHECK
            constraint, but guarded rather than falling through silently).
    """
    if item.item_type == "article":
        assembled = assemble_article_audio(item.id)
        sha256 = assembled.sha256
        byte_size = assembled.byte_size
        duration_ms = assembled.duration_ms
        transcript_segments = assembled.segments
    elif item.item_type == "podcast_episode":
        sha256, byte_size, transcript_segments, duration_ms = _resolve_podcast_media(item)
    else:
        raise ValueError(
            f"item {item.id!r}: unknown item_type {item.item_type!r}, expected 'article' or 'podcast_episode'"
        )

    safe_interruption = _safe_interruption_for(transcript_segments)

    # Persist the timing map atomically alongside the descriptor (Task 2.5),
    # keyed by the same sha256/segments the returned MediaDescriptor carries.
    # Always persisted, even when transcript_segments is empty: an empty
    # timing map is itself a meaningful, legitimate fact for a no-transcript
    # podcast (see timing_map.py's module docstring) — persisting it means a
    # future load_timing_map(sha256) can distinguish "normalized with zero
    # segments" from "never normalized at all", rather than collapsing both
    # to None. Content-addressed and idempotent: re-normalizing the same
    # item re-derives and re-writes the same segments harmlessly.
    save_timing_map(sha256, transcript_segments)

    return MediaDescriptor(
        sha256=sha256,
        byte_size=byte_size,
        mime_type=_MIME_TYPE_AUDIO_MPEG,
        duration_ms=duration_ms,
        transcript_segments=transcript_segments,
        safe_interruption=safe_interruption,
        byte_range_available=False,
        finalization=FinalizationState.complete(),
    )
