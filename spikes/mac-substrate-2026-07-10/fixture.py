"""Canonical mixed-media station fixture for the Task 0.3 substrate spike.

Builds three :class:`~wilted.station.models.StationEntry` instances purely
from the committed, substrate-neutral station value objects — no database,
no filesystem, no UI:

- ``ARTICLE_ENTRY``: a finalized, playable article with a transcript-derived
  :class:`~wilted.station.models.SafeInterruptionMap`.
- ``PODCAST_ENTRY``: a finalized, playable, 90-minute prepared podcast with
  an RSS-chapter-derived safe interruption map.
- ``BULLETIN_ENTRY``: a finalized, playable bulletin (``kind="bulletin"``,
  ``item_id=None``).

:func:`build_action_sequence` returns the canonical ordered action script
both candidate spikes must execute identically against the committed
reducer (``wilted.station.reducer.apply`` / ``claim_lease``):

    claim lease
    -> StartPlayback(article)
    -> Checkpoint
    -> AcceptInterruption(bulletin at a safe offset)
    -> ResumeFromInterruption
    -> StartPlayback(podcast)
    -> Checkpoint
    -> RequestHandoff
    -> AcknowledgeHandoff

The interrupt offset used in the sequence (``INTERRUPT_OFFSET_MS``) is a
real safe point in ``ARTICLE_ENTRY.media.safe_interruption`` — it exactly
matches one of the transcript-segment boundaries baked into
``ARTICLE_TRANSCRIPT_SEGMENTS``, so ``AcceptInterruption`` is accepted on
the happy path rather than rejected for lacking a safe checkpoint.
"""

from __future__ import annotations

from wilted.station.models import (
    FinalizationState,
    MediaDescriptor,
    SafeInterruptionMap,
    StationEntry,
    TranscriptSegment,
)
from wilted.station.reducer import (
    AcceptInterruption,
    AcknowledgeHandoff,
    Checkpoint,
    RequestHandoff,
    ResumeFromInterruption,
    StartPlayback,
    Stop,
)

# ---------------------------------------------------------------------------
# Shared identity constants — both candidates key off these exact strings.
# ---------------------------------------------------------------------------

MAC_HOLDER_ID = "mac-controller-spike"
MAC_LEASE_EPOCH = 1
PHONE_DEVICE_ID = "iphone-spike"
PHONE_REQUESTED_EPOCH = 1

# The article's transcript has a safe boundary at 45_000ms (see
# ARTICLE_TRANSCRIPT_SEGMENTS below) — AcceptInterruption in the canonical
# sequence uses exactly this offset so the bulletin interruption is accepted
# on the happy path, not rejected for missing a safe checkpoint.
INTERRUPT_OFFSET_MS = 45_000

# ---------------------------------------------------------------------------
# ARTICLE entry: transcript-derived safe interruption map.
# ---------------------------------------------------------------------------

ARTICLE_TRANSCRIPT_SEGMENTS = (
    TranscriptSegment(start_ms=0, end_ms=15_000, text="Paragraph one of the article."),
    TranscriptSegment(start_ms=15_000, end_ms=45_000, text="Paragraph two of the article."),
    TranscriptSegment(start_ms=45_000, end_ms=90_000, text="Paragraph three of the article."),
    TranscriptSegment(start_ms=90_000, end_ms=120_000, text="Paragraph four of the article."),
)

ARTICLE_MEDIA = MediaDescriptor(
    sha256="a" * 64,
    byte_size=2_400_000,
    mime_type="audio/mpeg",
    duration_ms=120_000,
    transcript_segments=ARTICLE_TRANSCRIPT_SEGMENTS,
    safe_interruption=SafeInterruptionMap.from_transcript_segments(ARTICLE_TRANSCRIPT_SEGMENTS),
    byte_range_available=False,
    finalization=FinalizationState.complete(),
)

ARTICLE_ENTRY = StationEntry(
    entry_id="article-spike-001",
    kind="item",
    item_id="item-101",
    source="feed:npr-news",
    policy_id=None,
    priority=5,
    expiry=None,
    duration_ms=ARTICLE_MEDIA.duration_ms,
    media=ARTICLE_MEDIA,
)

# ---------------------------------------------------------------------------
# PODCAST entry: RSS-chapter-derived safe interruption map, 90-minute show.
# ---------------------------------------------------------------------------

PODCAST_DURATION_MS = 90 * 60 * 1000  # 90 minutes, matches long-form prepared podcasts.

PODCAST_CHAPTERS = (
    TranscriptSegment(start_ms=0, end_ms=600_000, text="Chapter 1: Cold open and headlines."),
    TranscriptSegment(start_ms=600_000, end_ms=2_700_000, text="Chapter 2: Main interview."),
    TranscriptSegment(start_ms=2_700_000, end_ms=4_800_000, text="Chapter 3: Second segment."),
    TranscriptSegment(start_ms=4_800_000, end_ms=PODCAST_DURATION_MS, text="Chapter 4: Wrap-up and credits."),
)

PODCAST_MEDIA = MediaDescriptor(
    sha256="b" * 64,
    byte_size=86_400_000,
    mime_type="audio/mpeg",
    duration_ms=PODCAST_DURATION_MS,
    transcript_segments=PODCAST_CHAPTERS,
    safe_interruption=SafeInterruptionMap.from_rss_chapters(PODCAST_CHAPTERS),
    byte_range_available=True,
    finalization=FinalizationState.complete(),
)

PODCAST_ENTRY = StationEntry(
    entry_id="podcast-spike-001",
    kind="item",
    item_id="item-202",
    source="feed:npr-podcast",
    policy_id=None,
    priority=5,
    expiry=None,
    duration_ms=PODCAST_MEDIA.duration_ms,
    media=PODCAST_MEDIA,
)

# ---------------------------------------------------------------------------
# BULLETIN entry: no durable item_id, short generated interruption audio.
# ---------------------------------------------------------------------------

BULLETIN_MEDIA = MediaDescriptor(
    sha256="c" * 64,
    byte_size=180_000,
    mime_type="audio/mpeg",
    duration_ms=20_000,
    transcript_segments=(),
    safe_interruption=SafeInterruptionMap.empty(),
    byte_range_available=False,
    finalization=FinalizationState.complete(),
)

BULLETIN_ENTRY = StationEntry(
    entry_id="bulletin-spike-001",
    kind="bulletin",
    item_id=None,
    source="monitor:nws-alerts",
    policy_id="policy:weather-v1",
    priority=0,
    expiry=None,
    duration_ms=BULLETIN_MEDIA.duration_ms,
    media=BULLETIN_MEDIA,
)


def build_action_sequence() -> list[tuple[object, tuple[str, int]]]:
    """Return the canonical ordered action script both candidates must run.

    Each element is a ``(action, requester_lease)`` pair, where
    ``requester_lease`` is a ``(holder_id, epoch)`` tuple identifying the
    lease the caller must present to ``wilted.station.reducer.apply``. The
    lease claim itself (``claim_lease(state, MAC_HOLDER_ID, MAC_LEASE_EPOCH)``)
    is not part of this list — it is not gated by ``apply()`` and must be
    performed once by the caller before applying the first action. See
    ``measure.py`` for the reference execution order.

    Returns:
        Ordered list of ``(action, (holder_id, epoch))`` pairs. All actions
        before ``RequestHandoff``/``AcknowledgeHandoff`` present the Mac's
        lease; ``AcknowledgeHandoff`` also presents the Mac's lease (it is
        the Mac acknowledging the phone's takeover, not the phone acting
        directly on the reducer).
    """
    mac_lease = (MAC_HOLDER_ID, MAC_LEASE_EPOCH)
    return [
        (StartPlayback(entry=ARTICLE_ENTRY), mac_lease),
        (
            Checkpoint(
                mutation_id="ckpt-article-1",
                expected_revision=1,
                media_offset_ms=INTERRUPT_OFFSET_MS,
                state_label="playing",
                writer_device="mac",
            ),
            mac_lease,
        ),
        (
            AcceptInterruption(
                bulletin=BULLETIN_ENTRY,
                interrupt_offset_ms=INTERRUPT_OFFSET_MS,
                policy_current=True,
            ),
            mac_lease,
        ),
        (ResumeFromInterruption(), mac_lease),
        (StartPlayback(entry=PODCAST_ENTRY), mac_lease),
        (
            Checkpoint(
                mutation_id="ckpt-podcast-1",
                expected_revision=5,
                media_offset_ms=300_000,
                state_label="playing",
                writer_device="mac",
            ),
            mac_lease,
        ),
        (
            RequestHandoff(
                phone_device_id=PHONE_DEVICE_ID,
                requested_epoch=PHONE_REQUESTED_EPOCH,
                last_known_mac_revision=6,
            ),
            mac_lease,
        ),
        (
            AcknowledgeHandoff(
                phone_device_id=PHONE_DEVICE_ID,
                epoch=PHONE_REQUESTED_EPOCH,
            ),
            mac_lease,
        ),
    ]


__all__ = [
    "ARTICLE_ENTRY",
    "ARTICLE_MEDIA",
    "ARTICLE_TRANSCRIPT_SEGMENTS",
    "BULLETIN_ENTRY",
    "BULLETIN_MEDIA",
    "INTERRUPT_OFFSET_MS",
    "MAC_HOLDER_ID",
    "MAC_LEASE_EPOCH",
    "PHONE_DEVICE_ID",
    "PHONE_REQUESTED_EPOCH",
    "PODCAST_CHAPTERS",
    "PODCAST_DURATION_MS",
    "PODCAST_ENTRY",
    "PODCAST_MEDIA",
    "Stop",
    "build_action_sequence",
]
