"""``JsonStationStore`` — the one concrete ``StationStore`` implementation.

Persists the full ``StationState`` envelope (all 9 fields) as a single
versioned JSON document at ``wilted.DATA_DIR / "station" / "state.json"``.
Writes are atomic (tempfile + ``os.replace``, mirroring
``wilted.cache.save_manifest``); reads/writes of the full document are
compare-and-set on ``station_revision``.

YAGNI scope: versioned JSON only. No SQLite, no migration framework, no
phone/handoff logic beyond what the reducer already models. An on-disk
document this store cannot understand — an unknown/newer ``schema_version``,
corrupt/non-JSON text, non-UTF-8 bytes, or JSON that doesn't even parse to an
object (``null``, a list, a string, a number) — is never silently overwritten
or truncated — :meth:`JsonStationStore.load_state` raises
:class:`StationStoreVersionError` instead, so a caller can decide how to
handle an unreadable store rather than losing data. Only a genuinely
*absent* file (``path.exists()`` is False) is treated as "no prior state".

``wilted.DATA_DIR`` is resolved by attribute access on the ``wilted`` module
at *call time* (never imported as a bare name at module scope) — see INV-5
in ``wilted.cache`` for why: a name bound at import time would go stale the
moment a test (or a future caller) monkeypatches the live ``wilted.DATA_DIR``
attribute.
"""

from __future__ import annotations

import dataclasses
import json
import os
import tempfile
from typing import TYPE_CHECKING, Any

import wilted
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
from wilted.station.reducer import StationLifecycle, StationState

if TYPE_CHECKING:
    from pathlib import Path

STATION_SCHEMA_VERSION = 1
"""Schema version of the on-disk ``StationState`` envelope.

Bump this, and add explicit migration/refusal handling in
:func:`_decode_state`, if the on-disk shape ever changes incompatibly. An
unknown version is always a hard refusal (see :class:`StationStoreVersionError`),
never a best-effort/partial read.
"""

_STATE_FILENAME = "state.json"

_MAX_CAS_ATTEMPTS = 8
"""Bound on the compare-and-set retry loops in ``append_event``/``persist_lease``.

A concurrent-writer race is expected to resolve in a handful of retries;
looping unboundedly under sustained contention (or a wedged writer) would
livelock instead of surfacing a clear error.
"""


class StationStoreVersionError(Exception):
    """Raised when the on-disk station state document cannot be read safely.

    Covers an unknown/newer ``schema_version``, structurally corrupt JSON,
    non-UTF-8/binary content, and JSON that parses but not to an object at
    its top level (``null``, a list, a string, a number). In every case the
    on-disk document is left completely untouched — this store never
    silently overwrites or truncates a document it cannot understand, and
    never conflates "unreadable" with "absent".
    """


# ---------------------------------------------------------------------------
# Encode: StationState -> plain JSON-able dict
# ---------------------------------------------------------------------------


def _encode_transcript_segment(seg: TranscriptSegment) -> dict[str, Any]:
    return {"start_ms": seg.start_ms, "end_ms": seg.end_ms, "text": seg.text}


def _encode_safe_interruption_map(m: SafeInterruptionMap) -> dict[str, Any]:
    return {
        "mode": m.mode.value,
        "windows": [[start, end] for start, end in m.windows],
        "source": m.source,
    }


def _encode_finalization_state(f: FinalizationState) -> dict[str, Any]:
    return {
        "ads_cut": f.ads_cut,
        "timing_map_created": f.timing_map_created,
        "hashed": f.hashed,
        "published": f.published,
    }


def _encode_media_descriptor(m: MediaDescriptor) -> dict[str, Any]:
    return {
        "sha256": m.sha256,
        "byte_size": m.byte_size,
        "mime_type": m.mime_type,
        "duration_ms": m.duration_ms,
        "transcript_segments": [_encode_transcript_segment(s) for s in m.transcript_segments],
        "safe_interruption": _encode_safe_interruption_map(m.safe_interruption),
        "byte_range_available": m.byte_range_available,
        "finalization": _encode_finalization_state(m.finalization),
    }


def _encode_station_entry(e: StationEntry) -> dict[str, Any]:
    return {
        "entry_id": e.entry_id,
        "kind": e.kind,
        "item_id": e.item_id,
        "source": e.source,
        "policy_id": e.policy_id,
        "priority": e.priority,
        "expiry": e.expiry,
        "duration_ms": e.duration_ms,
        "media": _encode_media_descriptor(e.media),
    }


def _encode_playback_checkpoint(c: PlaybackCheckpoint) -> dict[str, Any]:
    return {
        "station_revision": c.station_revision,
        "entry_id": c.entry_id,
        "media_offset_ms": c.media_offset_ms,
        "state": c.state,
        "interrupted_entry_stack": list(c.interrupted_entry_stack),
        "writer_device": c.writer_device,
        "mutation_id": c.mutation_id,
        "timestamp": c.timestamp,
    }


def _encode_station_event(e: StationEvent) -> dict[str, Any]:
    return {
        "kind": e.kind,
        "timestamp": e.timestamp,
        "entry_id": e.entry_id,
        "message": e.message,
    }


def _encode_controller_lease(lease: ControllerLease) -> dict[str, Any]:
    return {"holder_id": lease.holder_id, "epoch": lease.epoch}


def _encode_state(state: StationState) -> dict[str, Any]:
    """Encode a full ``StationState`` into a plain JSON-able dict.

    Handles nested dataclasses, enums (by ``.value``), tuples (as lists),
    and ``frozenset`` (as a list) explicitly — ``dataclasses.asdict`` alone
    does not round-trip enums or frozensets.
    """
    return {
        "schema_version": STATION_SCHEMA_VERSION,
        "lifecycle": state.lifecycle.value,
        "station_revision": state.station_revision,
        "active_entry": _encode_station_entry(state.active_entry) if state.active_entry is not None else None,
        "checkpoint": _encode_playback_checkpoint(state.checkpoint) if state.checkpoint is not None else None,
        "interruption_stack": [_encode_station_entry(e) for e in state.interruption_stack],
        "lease": _encode_controller_lease(state.lease) if state.lease is not None else None,
        "phone_epoch": state.phone_epoch,
        "seen_mutation_ids": list(state.seen_mutation_ids),
        "events": [_encode_station_event(e) for e in state.events],
    }


# ---------------------------------------------------------------------------
# Decode: plain JSON dict -> StationState
# ---------------------------------------------------------------------------


def _decode_transcript_segment(d: dict[str, Any]) -> TranscriptSegment:
    return TranscriptSegment(start_ms=d["start_ms"], end_ms=d["end_ms"], text=d["text"])


def _decode_safe_interruption_map(d: dict[str, Any]) -> SafeInterruptionMap:
    return SafeInterruptionMap(
        mode=InterruptionMode(d["mode"]),
        windows=tuple((w[0], w[1]) for w in d["windows"]),
        source=d["source"],
    )


def _decode_finalization_state(d: dict[str, Any]) -> FinalizationState:
    return FinalizationState(
        ads_cut=d["ads_cut"],
        timing_map_created=d["timing_map_created"],
        hashed=d["hashed"],
        published=d["published"],
    )


def _decode_media_descriptor(d: dict[str, Any]) -> MediaDescriptor:
    return MediaDescriptor(
        sha256=d["sha256"],
        byte_size=d["byte_size"],
        mime_type=d["mime_type"],
        duration_ms=d["duration_ms"],
        transcript_segments=tuple(_decode_transcript_segment(s) for s in d["transcript_segments"]),
        safe_interruption=_decode_safe_interruption_map(d["safe_interruption"]),
        byte_range_available=d["byte_range_available"],
        finalization=_decode_finalization_state(d["finalization"]),
    )


def _decode_station_entry(d: dict[str, Any]) -> StationEntry:
    return StationEntry(
        entry_id=d["entry_id"],
        kind=d["kind"],
        item_id=d["item_id"],
        source=d["source"],
        policy_id=d["policy_id"],
        priority=d["priority"],
        expiry=d["expiry"],
        duration_ms=d["duration_ms"],
        media=_decode_media_descriptor(d["media"]),
    )


def _decode_playback_checkpoint(d: dict[str, Any]) -> PlaybackCheckpoint:
    return PlaybackCheckpoint(
        station_revision=d["station_revision"],
        entry_id=d["entry_id"],
        media_offset_ms=d["media_offset_ms"],
        state=d["state"],
        interrupted_entry_stack=tuple(d["interrupted_entry_stack"]),
        writer_device=d["writer_device"],
        mutation_id=d["mutation_id"],
        timestamp=d["timestamp"],
    )


def _decode_station_event(d: dict[str, Any]) -> StationEvent:
    return StationEvent(kind=d["kind"], timestamp=d["timestamp"], entry_id=d["entry_id"], message=d["message"])


def _decode_controller_lease(d: dict[str, Any]) -> ControllerLease:
    return ControllerLease(holder_id=d["holder_id"], epoch=d["epoch"])


def _decode_state(doc: dict[str, Any]) -> StationState:
    """Decode a plain JSON dict back into a full ``StationState``.

    Raises:
        StationStoreVersionError: If ``doc`` is not a dict at all (defense in
            depth — callers are expected to have already rejected this via
            :meth:`JsonStationStore._read_doc`).
        StationStoreVersionError: If ``schema_version`` is missing, not an
            int, or does not equal :data:`STATION_SCHEMA_VERSION` (covers
            both older and newer/unknown versions — this store does not
            attempt best-effort migration).
        StationStoreVersionError: If the document is otherwise structurally
            invalid (missing/malformed fields) — wraps the underlying
            ``KeyError``/``TypeError``/``ValueError`` so callers see one
            consistent "unreadable store" exception type.
    """
    if not isinstance(doc, dict):
        raise StationStoreVersionError(
            f"station state document is not a JSON object (got {type(doc).__name__}); "
            "refusing to read (and will not overwrite it)"
        )
    schema_version = doc.get("schema_version")
    if schema_version != STATION_SCHEMA_VERSION:
        raise StationStoreVersionError(
            f"station state document has schema_version={schema_version!r}, "
            f"expected {STATION_SCHEMA_VERSION!r}; refusing to read (and will not overwrite it)"
        )

    try:
        return StationState(
            lifecycle=StationLifecycle(doc["lifecycle"]),
            station_revision=doc["station_revision"],
            active_entry=_decode_station_entry(doc["active_entry"]) if doc["active_entry"] is not None else None,
            checkpoint=_decode_playback_checkpoint(doc["checkpoint"]) if doc["checkpoint"] is not None else None,
            interruption_stack=tuple(_decode_station_entry(e) for e in doc["interruption_stack"]),
            lease=_decode_controller_lease(doc["lease"]) if doc["lease"] is not None else None,
            phone_epoch=doc["phone_epoch"],
            seen_mutation_ids=frozenset(doc["seen_mutation_ids"]),
            events=tuple(_decode_station_event(e) for e in doc["events"]),
        )
    except (KeyError, TypeError, ValueError) as exc:
        raise StationStoreVersionError(
            f"station state document is structurally invalid and cannot be read safely: {exc!r}"
        ) from exc


# ---------------------------------------------------------------------------
# JsonStationStore
# ---------------------------------------------------------------------------


class JsonStationStore:
    """Concrete ``StationStore`` backed by a single versioned JSON document.

    Resolves ``wilted.DATA_DIR`` via attribute access at call time (INV-5),
    never at import/construction time, so tests (or callers) that
    monkeypatch ``wilted.DATA_DIR`` are respected for every operation.
    """

    def _state_path(self) -> Path:
        # INV-5: attribute access on the `wilted` module at call time, not a
        # bare name imported at module scope — see module docstring.
        base = wilted.DATA_DIR
        return base / "station" / _STATE_FILENAME

    def _read_doc(self) -> dict[str, Any] | None:
        """Read and JSON-parse the on-disk document, or None if it doesn't exist.

        The absent-vs-unreadable distinction is based solely on
        ``path.exists()``. A file that exists but whose parsed content is not
        a dict (``null``, a list, a string, a number, ...) is unreadable, not
        absent — it must never be treated as "no prior state" and silently
        overwritten.

        Raises:
            StationStoreVersionError: If the file exists but is not valid
                JSON, is not decodable as UTF-8 text, or its top-level parsed
                value is not a JSON object (dict).
        """
        path = self._state_path()
        if not path.exists():
            return None
        try:
            with path.open() as f:
                doc = json.load(f)
        except json.JSONDecodeError as exc:
            raise StationStoreVersionError(
                f"station state document at {path} is corrupt (invalid JSON): {exc!r}"
            ) from exc
        except UnicodeDecodeError as exc:
            raise StationStoreVersionError(
                f"station state document at {path} is not valid UTF-8 text: {exc!r}"
            ) from exc
        if not isinstance(doc, dict):
            raise StationStoreVersionError(
                f"station state document at {path} does not contain a JSON object at its "
                f"top level (got {type(doc).__name__}); refusing to read (and will not "
                "overwrite it)"
            )
        return doc

    def _write_doc(self, doc: dict[str, Any]) -> None:
        """Atomically write ``doc`` to the state file (tempfile + os.replace)."""
        path = self._state_path()
        path.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile("w", dir=path.parent, suffix=".tmp", delete=False) as f:
            json.dump(doc, f, indent=2)
            tmp_path = f.name
        os.replace(tmp_path, path)

    # -- full-state surface ---------------------------------------------

    def load_state(self) -> StationState | None:
        """Return the full persisted station state, or None if none exists.

        Raises:
            StationStoreVersionError: If the on-disk document exists but has
                an unknown/newer ``schema_version`` or is otherwise corrupt/
                unreadable. Never silently overwrites or truncates it.
        """
        doc = self._read_doc()
        if doc is None:
            return None
        return _decode_state(doc)

    def persist_state(self, state: StationState, *, expected_revision: int) -> bool:
        """Compare-and-set write of the full state envelope.

        Applies the write only if the on-disk ``station_revision`` (or the
        absence of any on-disk document, when ``expected_revision == 0``)
        matches ``expected_revision``; otherwise leaves the on-disk document
        completely unchanged and returns False.

        Raises:
            StationStoreVersionError: If an existing on-disk document cannot
                be safely read (unknown schema version or corrupt JSON) — the
                CAS check requires reading the current revision first, and
                this store never blindly overwrites a document it cannot
                understand.
        """
        doc = self._read_doc()
        current_revision = 0 if doc is None else _decode_state(doc).station_revision
        if current_revision != expected_revision:
            return False
        self._write_doc(_encode_state(state))
        return True

    # -- thin facades over the full-state document -----------------------

    def current_checkpoint(self) -> PlaybackCheckpoint | None:
        """Return ``load_state().checkpoint``, or None if no state exists."""
        state = self.load_state()
        return None if state is None else state.checkpoint

    def persist_checkpoint(self, checkpoint: PlaybackCheckpoint, *, expected_revision: int) -> bool:
        """CAS full-state update that sets ``.checkpoint`` and bumps ``station_revision``."""
        state = self.load_state()
        if state is None:
            base_state = StationState()
        else:
            base_state = state
        if base_state.station_revision != expected_revision:
            return False
        new_state = dataclasses.replace(
            base_state,
            checkpoint=checkpoint,
            station_revision=base_state.station_revision + 1,
        )
        return self.persist_state(new_state, expected_revision=expected_revision)

    def append_event(self, event: StationEvent) -> None:
        """Append a bounded diagnostic event to the persisted state's event log.

        Retries the CAS loop up to :data:`_MAX_CAS_ATTEMPTS` times against
        the latest on-disk revision before giving up.

        Raises:
            StationStoreVersionError: If the on-disk document becomes
                unreadable (unknown schema version or corrupt) partway
                through the retry loop.
            RuntimeError: If :data:`_MAX_CAS_ATTEMPTS` consecutive attempts
                all lose the CAS race to a concurrent writer.
        """
        for _ in range(_MAX_CAS_ATTEMPTS):
            state = self.load_state()
            base_state = state if state is not None else StationState()
            new_state = base_state.with_event(event)
            if self.persist_state(new_state, expected_revision=base_state.station_revision):
                return
            # Lost a race with a concurrent writer; retry against the new
            # current state rather than dropping the event.
        raise RuntimeError(
            f"append_event: exhausted {_MAX_CAS_ATTEMPTS} attempts without winning the "
            "compare-and-set race; giving up rather than looping forever"
        )

    def current_lease(self) -> ControllerLease | None:
        """Return ``load_state().lease``, or None if no state exists."""
        state = self.load_state()
        return None if state is None else state.lease

    def persist_lease(self, lease: ControllerLease) -> None:
        """Durably record a new controller lease, retrying on a revision race.

        Retries the CAS loop up to :data:`_MAX_CAS_ATTEMPTS` times against
        the latest on-disk revision before giving up.

        Raises:
            StationStoreVersionError: If the on-disk document becomes
                unreadable (unknown schema version or corrupt) partway
                through the retry loop.
            RuntimeError: If :data:`_MAX_CAS_ATTEMPTS` consecutive attempts
                all lose the CAS race to a concurrent writer.
        """
        for _ in range(_MAX_CAS_ATTEMPTS):
            state = self.load_state()
            base_state = state if state is not None else StationState()
            new_state = dataclasses.replace(base_state, lease=lease, station_revision=base_state.station_revision + 1)
            if self.persist_state(new_state, expected_revision=base_state.station_revision):
                return
        raise RuntimeError(
            f"persist_lease: exhausted {_MAX_CAS_ATTEMPTS} attempts without winning the "
            "compare-and-set race; giving up rather than looping forever"
        )


__all__ = [
    "STATION_SCHEMA_VERSION",
    "JsonStationStore",
    "StationStoreVersionError",
]
