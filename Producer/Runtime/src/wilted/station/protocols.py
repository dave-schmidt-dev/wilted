"""Protocol seams for the station contract's future store and audio backend.

These are pure interface definitions (``typing.Protocol``) with no
implementation. They describe the minimal surface a future real
``StationStore`` (SQLite, a versioned JSON document, or whatever Plan 0
selects) and a future real ``PlaybackAdapter`` (AVPlayer, a Python audio
engine, etc.) must implement — deliberately minimal, not a speculative
full API. Nothing in ``wilted.station`` implements these Protocols except
the in-memory test fakes in the test suite.
"""

from __future__ import annotations

from typing import TYPE_CHECKING, Protocol

if TYPE_CHECKING:
    from wilted.station.models import ControllerLease, MediaDescriptor, PlaybackCheckpoint, StationEvent
    from wilted.station.reducer import StationState


class StationStore(Protocol):
    """Interface a future durable station store must implement.

    Kept minimal: only what the reducer/controller needs to read current
    state and durably record checkpoints/events/lease changes. Does not
    speculate about query/filter/pagination APIs a real store might add.

    ``load_state``/``persist_state`` are the primary durable surface (a full
    ``StationState`` envelope, compare-and-set on ``station_revision``); the
    remaining methods (``current_checkpoint``, ``persist_checkpoint``,
    ``append_event``, ``current_lease``, ``persist_lease``) are thin facades
    over that full-state document, kept for callers that only care about one
    field at a time.
    """

    def load_state(self) -> StationState | None:
        """Return the full persisted station state, or None if none exists."""
        ...

    def persist_state(self, state: StationState, *, expected_revision: int) -> bool:
        """Durably record ``state`` if ``expected_revision`` is still current.

        Returns:
            True if the write was applied, False if ``expected_revision`` did
            not match the on-disk ``station_revision`` (i.e. someone else
            already advanced it) and the write was rejected. On rejection the
            on-disk document is left unchanged.
        """
        ...

    def current_checkpoint(self) -> PlaybackCheckpoint | None:
        """Return the most recently persisted checkpoint, or None if none exists."""
        ...

    def persist_checkpoint(self, checkpoint: PlaybackCheckpoint, *, expected_revision: int) -> bool:
        """Durably record ``checkpoint`` if ``expected_revision`` is still current.

        Returns:
            True if the write was applied, False if ``expected_revision`` was
            stale (i.e. someone else already advanced the revision) and the
            write was rejected.
        """
        ...

    def append_event(self, event: StationEvent) -> None:
        """Append a bounded diagnostic event. Not durable listening history."""
        ...

    def current_lease(self) -> ControllerLease | None:
        """Return the current controller lease holder, or None if unheld."""
        ...

    def persist_lease(self, lease: ControllerLease) -> None:
        """Durably record a new controller lease (e.g. on takeover/handoff)."""
        ...


class PlaybackAdapter(Protocol):
    """Interface a future real audio backend must implement.

    Kept minimal: play/pause/stop/seek against a resolved
    :class:`~wilted.station.models.MediaDescriptor` and an offset. No
    routing, device-selection, or session-management surface is speculated
    here — those belong to the concrete adapter chosen after Plan 0.
    """

    def play(self, media: MediaDescriptor, *, offset_ms: int) -> None:
        """Begin playback of ``media`` starting at ``offset_ms``."""
        ...

    def pause(self) -> None:
        """Pause playback, retaining the current position."""
        ...

    def stop(self) -> None:
        """Stop playback and release any held playback resources."""
        ...

    def seek(self, offset_ms: int) -> None:
        """Move the current playback position to ``offset_ms``."""
        ...

    def current_offset_ms(self) -> int:
        """Return the current playback position in milliseconds."""
        ...
