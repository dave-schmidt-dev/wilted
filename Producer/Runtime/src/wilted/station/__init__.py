"""Substrate-neutral station contract layer.

This package defines the immutable value objects, pure state-transition
reducer, and Protocol seams for the Wilted "station" concept — the ordered,
interruptible playback queue described in the Mac-first personal radio
design (see ``mac-first-personal-radio-2026-07-10.md``, "Station contract"
and "Playback and model coordination" sections).

Nothing here commits to a UI toolkit, a storage engine, or an audio
backend. It must remain importable and testable with zero third-party
dependencies beyond the Python standard library, and it must never import
``textual``, ``peewee``, ``sqlite3``, or anything from the rest of the
``wilted`` package (see ``tests/test_station_contracts.py`` for the
substrate-neutrality check that enforces this at test time).

Modules:
    models: Immutable value objects (``StationEntry``, ``MediaDescriptor``,
        ``TranscriptSegment``, ``SafeInterruptionMap``, ``PlaybackCheckpoint``,
        ``StationEvent``, ``ControllerLease``).
    protocols: ``typing.Protocol`` seams (``StationStore``, ``PlaybackAdapter``)
        that a future real store/audio backend will implement.
    reducer: The pure ``StationState`` type, the action union, and the
        ``apply()`` entry point implementing all state transitions.
"""

from wilted.station.models import (
    ControllerLease,
    FinalizationState,
    InterruptionMode,
    MediaDescriptor,
    PlaybackCheckpoint,
    SafeInterruptionMap,
    StationEntry,
    StationEvent,
    TranscriptSegment,
)
from wilted.station.protocols import PlaybackAdapter, StationStore
from wilted.station.reducer import (
    AcceptInterruption,
    AcknowledgeHandoff,
    Checkpoint,
    RequestHandoff,
    ResumeFromInterruption,
    StartPlayback,
    StationLifecycle,
    StationState,
    Stop,
    apply,
)

__all__ = [
    "AcceptInterruption",
    "AcknowledgeHandoff",
    "Checkpoint",
    "ControllerLease",
    "FinalizationState",
    "InterruptionMode",
    "MediaDescriptor",
    "PlaybackAdapter",
    "PlaybackCheckpoint",
    "RequestHandoff",
    "ResumeFromInterruption",
    "SafeInterruptionMap",
    "StartPlayback",
    "StationEntry",
    "StationEvent",
    "StationLifecycle",
    "StationState",
    "StationStore",
    "Stop",
    "TranscriptSegment",
    "apply",
]
