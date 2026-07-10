"""Immutable value objects for the station contract.

All types in this module are frozen dataclasses. None of them import
anything from outside the Python standard library, and none of them import
any other part of the ``wilted`` package — see the package docstring in
``wilted/station/__init__.py`` for why that boundary matters.

Timestamps are UTC ISO-8601 strings with a literal ``Z`` suffix (e.g.
``"2026-04-20T06:00:00Z"``), matching the convention used elsewhere in
Wilted (``wilted.db.now_utc``). This module cannot import that helper
(it would violate substrate-neutrality), so ``now_utc_z()`` below is a
standalone equivalent.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import UTC, datetime
from enum import Enum
from typing import Literal

EntryKind = Literal["item", "bulletin"]
PlaybackState = Literal["playing", "paused", "stopped"]
StationEventKind = Literal["start", "checkpoint", "interruption", "resume", "skip", "error"]


def now_utc_z() -> str:
    """Return the current UTC time as an ISO-8601 string with a 'Z' suffix.

    Standalone equivalent of ``wilted.db.now_utc`` — duplicated rather than
    imported because ``wilted.station`` must not depend on any other part
    of the ``wilted`` package (substrate neutrality).
    """
    return datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def _parse_utc_z(timestamp: str) -> datetime:
    """Parse a 'Z'-suffixed UTC ISO-8601 string into an aware ``datetime``."""
    return datetime.strptime(timestamp, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=UTC)


# ---------------------------------------------------------------------------
# Transcript segments and safe interruption maps
# ---------------------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class TranscriptSegment:
    """One transcript/chapter segment of a media artifact.

    Attributes:
        start_ms: Segment start offset in milliseconds, inclusive.
        end_ms: Segment end offset in milliseconds, exclusive.
        text: The segment's text content (transcript line, chapter title,
            or a synthetic label for a verified time window).
    """

    start_ms: int
    end_ms: int
    text: str

    def __post_init__(self) -> None:
        if self.start_ms < 0:
            raise ValueError(f"TranscriptSegment.start_ms must be >= 0, got {self.start_ms}")
        if self.end_ms < self.start_ms:
            raise ValueError(f"TranscriptSegment.end_ms ({self.end_ms}) must be >= start_ms ({self.start_ms})")


class InterruptionMode(Enum):
    """Explicit, queryable mode for a :class:`SafeInterruptionMap`.

    ``NO_INTERRUPT`` is a first-class state, not an implicit consequence of
    an empty ``windows`` tuple. A caller must be able to distinguish "no
    safe-boundary data exists for this entry, so treat it as fully
    uninterruptible" from "this map has windows, none of which happen to
    cover the queried offset" — the two are not the same thing and must not
    be conflated (see the design doc: "an entry without one is visibly
    no-interrupt mode and cannot silently block an alert for its whole
    duration").
    """

    NO_INTERRUPT = "no_interrupt"
    WINDOWED = "windowed"


@dataclass(frozen=True, slots=True)
class SafeInterruptionMap:
    """Where within a media artifact it is safe to interrupt for a bulletin.

    Built from one of three sources (transcript segments, RSS chapters, or
    conservative verified time windows) via the ``from_*`` classmethods, or
    from :meth:`empty` for the explicit no-interrupt case. Do not construct
    directly with an empty ``windows`` tuple and ``mode=WINDOWED`` — that
    would recreate the ambiguity this type exists to prevent; validation in
    ``__post_init__`` rejects that combination.

    Attributes:
        mode: :class:`InterruptionMode` — ``NO_INTERRUPT`` or ``WINDOWED``.
        windows: Tuple of ``(start_ms, end_ms)`` pairs, each a closed
            interval considered safe to interrupt within. Empty iff
            ``mode is InterruptionMode.NO_INTERRUPT``.
        source: Free-text provenance label (``"transcript"``, ``"rss_chapters"``,
            ``"verified_windows"``, or ``"none"``) for observability/debugging.
    """

    mode: InterruptionMode
    windows: tuple[tuple[int, int], ...]
    source: str

    def __post_init__(self) -> None:
        if self.mode is InterruptionMode.NO_INTERRUPT and self.windows:
            raise ValueError("SafeInterruptionMap with mode=NO_INTERRUPT must have no windows")
        if self.mode is InterruptionMode.WINDOWED and not self.windows:
            raise ValueError("SafeInterruptionMap with mode=WINDOWED must have at least one window")
        for start_ms, end_ms in self.windows:
            if start_ms < 0 or end_ms < start_ms:
                raise ValueError(f"Invalid safe window ({start_ms}, {end_ms})")

    @property
    def is_no_interrupt(self) -> bool:
        """True if this entry has no known safe interruption points at all."""
        return self.mode is InterruptionMode.NO_INTERRUPT

    @classmethod
    def empty(cls) -> SafeInterruptionMap:
        """Build the explicit no-interrupt map (no safe boundary data exists)."""
        return cls(mode=InterruptionMode.NO_INTERRUPT, windows=(), source="none")

    @classmethod
    def from_transcript_segments(cls, segments: tuple[TranscriptSegment, ...]) -> SafeInterruptionMap:
        """Build a safe map treating each transcript segment boundary as safe.

        Each segment's start offset is treated as a safe interruption point;
        the safe window is a small closed interval around that boundary
        (the boundary itself, i.e. a zero-width-tolerant point encoded as
        ``(start_ms, start_ms)``) so :meth:`safe_point_at` can match exact
        segment starts. Empty ``segments`` yields :meth:`empty`.
        """
        if not segments:
            return cls.empty()
        windows = tuple((seg.start_ms, seg.start_ms) for seg in segments)
        return cls(mode=InterruptionMode.WINDOWED, windows=windows, source="transcript")

    @classmethod
    def from_rss_chapters(cls, chapters: tuple[TranscriptSegment, ...]) -> SafeInterruptionMap:
        """Build a safe map from RSS/podcast chapter markers.

        Each chapter is treated as a safe window spanning its full
        ``[start_ms, end_ms)`` range (chapter boundaries in podcast/RSS
        feeds are typically producer-authored pause points, so the whole
        chapter is conservatively considered safe). Empty ``chapters``
        yields :meth:`empty`.
        """
        if not chapters:
            return cls.empty()
        windows = tuple((ch.start_ms, ch.end_ms) for ch in chapters)
        return cls(mode=InterruptionMode.WINDOWED, windows=windows, source="rss_chapters")

    @classmethod
    def from_verified_windows(cls, windows: tuple[tuple[int, int], ...]) -> SafeInterruptionMap:
        """Build a safe map from conservative, independently-verified time windows.

        Used when neither transcript segments nor RSS chapters are
        available but a narrow, manually/heuristically verified safe range
        is known (e.g. confirmed silence). Empty ``windows`` yields
        :meth:`empty`.
        """
        if not windows:
            return cls.empty()
        return cls(mode=InterruptionMode.WINDOWED, windows=tuple(windows), source="verified_windows")

    def safe_point_at(self, offset_ms: int) -> bool:
        """Return True if ``offset_ms`` falls within a known-safe window.

        Always returns False when :attr:`mode` is ``NO_INTERRUPT`` — there
        is no window to match against, and that is the point: no-interrupt
        mode must never be mistaken for "safe everywhere".
        """
        if self.is_no_interrupt:
            return False
        return any(start <= offset_ms <= end for start, end in self.windows)

    def nearest_safe_point(self, offset_ms: int) -> int | None:
        """Return the safe-window offset nearest to ``offset_ms``, or None.

        Returns None when :attr:`mode` is ``NO_INTERRUPT`` (no data) or
        ``windows`` is otherwise empty. When ``offset_ms`` is inside a
        window it is returned unchanged; otherwise the nearest window
        boundary (start or end) is returned.
        """
        if self.is_no_interrupt:
            return None
        best: int | None = None
        best_distance: int | None = None
        for start, end in self.windows:
            if start <= offset_ms <= end:
                return offset_ms
            candidate = start if offset_ms < start else end
            distance = abs(candidate - offset_ms)
            if best_distance is None or distance < best_distance:
                best, best_distance = candidate, distance
        return best


# ---------------------------------------------------------------------------
# Media descriptor and finalization state
# ---------------------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class FinalizationState:
    """Tracks the four preconditions a :class:`MediaDescriptor` must clear.

    Modeled as four explicit booleans (rather than a single stage enum) so
    each precondition can be asserted independently in tests, but
    ``__post_init__`` enforces that later stages imply earlier ones — a
    descriptor cannot claim ``published=True`` while ``hashed=False``, for
    example, because that would be an internally-contradictory state. The
    enforced order is: ads_cut -> timing_map_created -> hashed -> published.

    Attributes:
        ads_cut: Ad-cutting has completed for this artifact.
        timing_map_created: A timing map (paragraph/segment offsets) exists.
        hashed: The content SHA-256 has been computed over final bytes.
        published: The artifact has been atomically published (visible at
            its final path, safe to reference from other processes).
    """

    ads_cut: bool = False
    timing_map_created: bool = False
    hashed: bool = False
    published: bool = False

    def __post_init__(self) -> None:
        stages = [
            ("ads_cut", self.ads_cut),
            ("timing_map_created", self.timing_map_created),
            ("hashed", self.hashed),
            ("published", self.published),
        ]
        reached_false = False
        for name, value in stages:
            if reached_false and value:
                raise ValueError(
                    f"FinalizationState is contradictory: {name}=True but an earlier "
                    "stage is False. Required order: ads_cut -> timing_map_created -> "
                    "hashed -> published."
                )
            if not value:
                reached_false = True

    @property
    def is_complete(self) -> bool:
        """True only when every finalization precondition has been met."""
        return self.ads_cut and self.timing_map_created and self.hashed and self.published

    @classmethod
    def complete(cls) -> FinalizationState:
        """Convenience constructor for a fully-finalized state."""
        return cls(ads_cut=True, timing_map_created=True, hashed=True, published=True)


@dataclass(frozen=True, slots=True)
class MediaDescriptor:
    """One normalized, immutable playback artifact.

    Hides the pre-existing inconsistency where article ``audio_file`` is a
    directory (per-paragraph MP3 cache) while podcast ``audio_file`` is a
    single file (see ``prepare.py:76-131,201-224``) — this type represents
    one canonical playable artifact regardless of which shape produced it.
    This layer never reads the database; callers are responsible for
    normalizing whatever the store contains into a ``MediaDescriptor``.

    An artifact is not playable or checkpointable until ad cutting, timing-map
    creation, hashing, and atomic publication are all complete — see
    :attr:`is_playable` / :attr:`is_checkpointable`, which gate on
    :attr:`finalization`.

    Attributes:
        sha256: Content hash of the final, published artifact bytes.
        byte_size: Total size in bytes.
        mime_type: MIME type of the artifact (e.g. ``"audio/mpeg"``).
        duration_ms: Total duration in milliseconds.
        transcript_segments: Ordered transcript/chapter segments, if any.
        safe_interruption: The artifact's :class:`SafeInterruptionMap`.
        byte_range_available: Whether byte-range (partial content) requests
            are supported for this artifact, e.g. for resumable/streamed
            playback. ``False`` means only whole-file access is available.
        finalization: :class:`FinalizationState` tracking publication readiness.
    """

    sha256: str
    byte_size: int
    mime_type: str
    duration_ms: int
    transcript_segments: tuple[TranscriptSegment, ...]
    safe_interruption: SafeInterruptionMap
    byte_range_available: bool
    finalization: FinalizationState = field(default_factory=FinalizationState)

    def __post_init__(self) -> None:
        if self.byte_size < 0:
            raise ValueError(f"MediaDescriptor.byte_size must be >= 0, got {self.byte_size}")
        if self.duration_ms < 0:
            raise ValueError(f"MediaDescriptor.duration_ms must be >= 0, got {self.duration_ms}")
        if self.finalization.published and (self.byte_size == 0 or not self.sha256):
            raise ValueError(
                "MediaDescriptor cannot be published with zero byte_size or empty sha256 "
                "(INV-4: no pipeline stage may publish empty/unfinalized content)"
            )

    @property
    def is_playable(self) -> bool:
        """True only when every finalization precondition has been met."""
        return self.finalization.is_complete

    @property
    def is_checkpointable(self) -> bool:
        """True only when every finalization precondition has been met.

        Checkpointing an unfinalized artifact would record an offset into
        media that may still change shape (e.g. ads not yet cut), so the
        gate is identical to :attr:`is_playable`.
        """
        return self.finalization.is_complete


# ---------------------------------------------------------------------------
# Station entry
# ---------------------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class StationEntry:
    """One immutable entry in the station queue.

    Attributes:
        entry_id: Stable, immutable identifier for this entry — never a
            positional/UI index (lifts INV-3's "stable id, never a
            positional index" rule to the station layer).
        kind: ``"item"`` for durable saved content or ``"bulletin"`` for
            session-scoped generated audio (routine/breaking/weather).
        item_id: The originating durable ``Item`` id, when ``kind == "item"``.
            None for bulletins, which are never a durable Item.
        source: Free-text provenance of the entry (e.g. ``"feed:npr-news"``,
            ``"monitor:nws-alerts"``, ``"manual"``). Exact taxonomy is left
            to the caller/store layer; this contract only requires *some*
            provenance string be attached.
        policy_id: Identifier of the policy/ruleset that admitted this entry
            (e.g. which interruption/ranking policy authorized a bulletin).
            None when no policy applies (e.g. a manually queued item).
        priority: Lower value = more urgent (0 is the most urgent). This
            direction is a judgment call — the spec does not fix it — chosen
            so that "priority 0" reads naturally as "top priority", matching
            common queue/heap conventions (e.g. Python's ``heapq`` is a
            min-heap). Nested interruptions are queued/ordered by ascending
            priority value.
        expiry: UTC ISO-8601 'Z' string after which this entry must be
            discarded rather than admitted/played. None means the entry
            never expires (e.g. most durable saved items).
        duration_ms: Expected playback duration in milliseconds — mirrors
            ``media.duration_ms`` but is kept on the entry too since an
            entry may be queued before its media is fully resolved.
        media: The entry's :class:`MediaDescriptor`.
    """

    entry_id: str
    kind: EntryKind
    item_id: str | None
    source: str
    policy_id: str | None
    priority: int
    expiry: str | None
    duration_ms: int
    media: MediaDescriptor

    def __post_init__(self) -> None:
        if not self.entry_id:
            raise ValueError("StationEntry.entry_id must be non-empty")
        if self.kind not in ("item", "bulletin"):
            raise ValueError(f"StationEntry.kind must be 'item' or 'bulletin', got {self.kind!r}")
        if self.kind == "bulletin" and self.item_id is not None:
            raise ValueError("StationEntry with kind='bulletin' must not have an item_id")
        if self.duration_ms < 0:
            raise ValueError(f"StationEntry.duration_ms must be >= 0, got {self.duration_ms}")

    def is_expired(self, now: str) -> bool:
        """Return True if :attr:`expiry` is set and is at/before ``now``.

        Args:
            now: UTC ISO-8601 'Z' string to compare against.
        """
        if self.expiry is None:
            return False
        return _parse_utc_z(self.expiry) <= _parse_utc_z(now)


# ---------------------------------------------------------------------------
# Playback checkpoint
# ---------------------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class PlaybackCheckpoint:
    """A revisioned, durable-intent record of playback position.

    Attributes:
        station_revision: Logical station revision this checkpoint applies to.
        entry_id: The entry being played when this checkpoint was written.
        media_offset_ms: Offset into the entry's media, in milliseconds.
        state: ``"playing"``, ``"paused"``, or ``"stopped"``.
        interrupted_entry_stack: Tuple of entry_ids interrupted (and not yet
            resumed), most-recently-interrupted last, for nested bulletins.
        writer_device: Identifies which device wrote this checkpoint (e.g.
            ``"mac"`` or ``"iphone"``, or a specific device id string).
        mutation_id: Unique id for this specific write attempt (e.g. a
            UUID string) — used for idempotent-write and stale-write
            detection by the reducer.
        timestamp: UTC ISO-8601 'Z' string of when this checkpoint was written.
    """

    station_revision: int
    entry_id: str
    media_offset_ms: int
    state: PlaybackState
    interrupted_entry_stack: tuple[str, ...]
    writer_device: str
    mutation_id: str
    timestamp: str

    def __post_init__(self) -> None:
        if self.station_revision < 0:
            raise ValueError(f"PlaybackCheckpoint.station_revision must be >= 0, got {self.station_revision}")
        if self.media_offset_ms < 0:
            raise ValueError(f"PlaybackCheckpoint.media_offset_ms must be >= 0, got {self.media_offset_ms}")
        if self.state not in ("playing", "paused", "stopped"):
            raise ValueError(f"PlaybackCheckpoint.state must be playing/paused/stopped, got {self.state!r}")
        if not self.mutation_id:
            raise ValueError("PlaybackCheckpoint.mutation_id must be non-empty")


# ---------------------------------------------------------------------------
# Station event (bounded diagnostic log, NOT durable listening history)
# ---------------------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class StationEvent:
    """An append-only, in-memory observability event.

    IMPORTANT: this is a bounded diagnostic log for the MVP, not a durable
    listening-history record. Nothing in this type or module persists
    events to disk/DB — callers that want a bounded in-memory ring buffer
    of these for UI/debugging purposes own that buffering themselves. Do
    not add persistence here; that would exceed what the design doc
    authorizes ("The MVP may retain a bounded diagnostic log, not
    listening history beyond existing durable records").

    Attributes:
        kind: One of ``"start"``, ``"checkpoint"``, ``"interruption"``,
            ``"resume"``, ``"skip"``, ``"error"``.
        timestamp: UTC ISO-8601 'Z' string of when the event occurred.
        entry_id: The entry this event relates to, if any.
        message: Free-text human-readable detail (e.g. an error message or
            skip reason).
    """

    kind: StationEventKind
    timestamp: str
    entry_id: str | None = None
    message: str = ""

    def __post_init__(self) -> None:
        valid_kinds = ("start", "checkpoint", "interruption", "resume", "skip", "error")
        if self.kind not in valid_kinds:
            raise ValueError(f"StationEvent.kind must be one of {valid_kinds}, got {self.kind!r}")


# ---------------------------------------------------------------------------
# Controller lease / ownership
# ---------------------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class ControllerLease:
    """Identifies the single live controller process allowed to mutate state.

    Separate from the logical station revision (per the design doc: "The
    lease is separate from logical station revisions so that an orphaned or
    stale process cannot continue playback after another controller takes
    ownership"). A mutating action must present a lease matching the
    current holder/epoch; a mismatch means the requester is stale/orphaned
    and must be rejected.

    Attributes:
        holder_id: Opaque identifier of the process/device holding the
            lease (e.g. a PID-derived string or device id).
        epoch: Monotonically increasing integer bumped every time the lease
            changes hands. A requester must present the current epoch.
    """

    holder_id: str
    epoch: int

    def __post_init__(self) -> None:
        if not self.holder_id:
            raise ValueError("ControllerLease.holder_id must be non-empty")
        if self.epoch < 0:
            raise ValueError(f"ControllerLease.epoch must be >= 0, got {self.epoch}")

    def matches(self, holder_id: str, epoch: int) -> bool:
        """Return True if ``holder_id``/``epoch`` match this lease exactly."""
        return self.holder_id == holder_id and self.epoch == epoch
