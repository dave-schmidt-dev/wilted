"""Candidate (a): extracted headless core with a native-client boundary.

``StationCore`` owns the authoritative ``wilted.station.reducer.StationState``
and exposes exactly two read surfaces (:meth:`StationCore.get_manifest`,
:meth:`StationCore.get_checkpoint`) plus a set of idempotent mutation
COMMANDS. Both read surfaces return plain, ``json.dumps``-round-trippable
``dict``/``list``/``str``/``int``/``bool`` structures — nothing else ever
crosses the boundary. This is the "sync a manifest, never the database"
design from the design doc's "Phone handoff: local-only first" section: a
client (Textual today, a native macOS/iOS client later) never touches
``StationState``, the reducer, or any station value object directly. It
only ever sees the JSON manifest/checkpoint and submits command dicts.

The core is a thin, stateful wrapper around the committed, substrate-neutral
reducer (``wilted.station.reducer``). It adds exactly one thing the reducer
does not have: ownership of *which* lease identity is asking, translated
from a plain ``(holder_id, epoch)`` pair into the reducer's
``ControllerLease`` at the call boundary. All correctness (owner-loss
rejection, stale-revision rejection, idempotent mutation ids, fencing-token
lease claims) is still enforced by the committed reducer — this module adds
no new business rules, only a serialization/command boundary around it.

No Textual import, no real audio, no persistence, no networking. A thin
in-process "client" object (:class:`InProcessClient`) demonstrates that the
boundary is language-neutral: it only ever sees ``bytes`` (the JSON-encoded
manifest) and submits plain command dicts, never a Python object from
``wilted.station``.
"""

from __future__ import annotations

import json
import logging
from typing import TYPE_CHECKING, Any

from wilted.station.models import ControllerLease, StationEntry
from wilted.station.reducer import (
    AcceptInterruption,
    AcknowledgeHandoff,
    Checkpoint,
    RequestHandoff,
    ResumeFromInterruption,
    StartPlayback,
    StationState,
    apply,
    claim_lease,
)

if TYPE_CHECKING:
    from collections.abc import Callable

logger = logging.getLogger(__name__)

# Manifest/checkpoint schema version. Bumped whenever the JSON shape crossing
# the boundary changes in a way a client needs to know about — the core
# principle of "sync a manifest, never the database" requires the manifest
# itself to be versioned independently of the internal reducer state shape.
MANIFEST_SCHEMA_VERSION = 1


class CommandRejected(Exception):
    """Raised by :class:`InProcessClient` when a command dict is malformed.

    Distinct from a reducer-level rejection (owner-loss, stale revision,
    etc.), which is a normal outcome reported via the manifest/event log,
    not an exception — see reducer.py's rejection-vs-exception convention,
    which this boundary preserves. This exception is reserved for a
    genuinely malformed command dict (unknown command name, missing
    required key) — a client-side protocol error, not a station rejection.
    """


def _entry_summary(entry: StationEntry | None) -> dict[str, Any] | None:
    """Reduce a :class:`StationEntry` to a plain-JSON summary, or None."""
    if entry is None:
        return None
    return {
        "entry_id": entry.entry_id,
        "kind": entry.kind,
        "item_id": entry.item_id,
        "source": entry.source,
        "priority": entry.priority,
        "duration_ms": entry.duration_ms,
        "media": {
            "duration_ms": entry.media.duration_ms,
            "mime_type": entry.media.mime_type,
            "is_playable": entry.media.is_playable,
        },
    }


class StationCore:
    """Headless core owning the authoritative station state.

    The core is the only thing in this candidate that ever imports or
    touches ``wilted.station`` types. Every public method either returns a
    plain-JSON dict (:meth:`get_manifest`, :meth:`get_checkpoint`) or is an
    idempotent mutation command that accepts plain scalars/strings and a
    ``(holder_id, epoch)`` lease pair, internally building the reducer's
    action/lease objects and calling ``apply()``/``claim_lease()``.

    Attributes:
        state: The current authoritative ``StationState``. Private in
            spirit (a real client boundary would not expose this at all —
            see ``InProcessClient``, which never touches it), but left as a
            plain attribute here since this is a spike, not a hardened
            service.
    """

    def __init__(self) -> None:
        self.state: StationState = StationState()

    # -- Read surface: JSON-serializable manifest/checkpoint -----------------

    def get_manifest(self) -> dict[str, Any]:
        """Return a versioned, plain-JSON snapshot of the station.

        This is the entire read surface a native client needs: revision,
        lifecycle, active entry summary, checkpoint, and lease/phone-epoch
        ownership info. Every value is a ``dict``/``list``/``str``/``int``/
        ``bool``/``None`` — no dataclass, enum, or other Python object
        crosses this boundary. Round-trip through ``json.dumps``/
        ``json.loads`` is asserted in ``measure.py``.

        Returns:
            Plain-JSON manifest dict.
        """
        state = self.state
        lease = state.lease
        return {
            "schema_version": MANIFEST_SCHEMA_VERSION,
            "station_revision": state.station_revision,
            "lifecycle": state.lifecycle.value,
            "active_entry": _entry_summary(state.active_entry),
            "interruption_stack": [e.entry_id for e in state.interruption_stack],
            "checkpoint": self.get_checkpoint(),
            "lease": ({"holder_id": lease.holder_id, "epoch": lease.epoch} if lease is not None else None),
            "phone_epoch": state.phone_epoch,
            "event_count": len(state.events),
            "last_event": (
                {
                    "kind": state.events[-1].kind,
                    "entry_id": state.events[-1].entry_id,
                    "message": state.events[-1].message,
                }
                if state.events
                else None
            ),
        }

    def get_checkpoint(self) -> dict[str, Any] | None:
        """Return the current :class:`PlaybackCheckpoint` as a plain-JSON dict, or None.

        Returns:
            Plain-JSON checkpoint dict, or None if no checkpoint has been
            written yet.
        """
        checkpoint = self.state.checkpoint
        if checkpoint is None:
            return None
        return {
            "station_revision": checkpoint.station_revision,
            "entry_id": checkpoint.entry_id,
            "media_offset_ms": checkpoint.media_offset_ms,
            "state": checkpoint.state,
            "interrupted_entry_stack": list(checkpoint.interrupted_entry_stack),
            "writer_device": checkpoint.writer_device,
            "mutation_id": checkpoint.mutation_id,
            "timestamp": checkpoint.timestamp,
        }

    def recent_events(self, limit: int = 10) -> list[dict[str, Any]]:
        """Return the last ``limit`` diagnostic events as plain-JSON dicts.

        Not part of the minimal manifest (kept separate so the manifest
        itself stays small/cheap to sync), but useful for the multi-process
        ownership demonstration in ``measure.py`` and for a native client's
        debug/log view.
        """
        events = self.state.events[-limit:] if limit > 0 else ()
        return [
            {"kind": e.kind, "timestamp": e.timestamp, "entry_id": e.entry_id, "message": e.message} for e in events
        ]

    # -- Mutation commands: each takes a lease identity + idempotency key ----

    def claim_lease(self, holder_id: str, epoch: int) -> dict[str, Any]:
        """Command: claim/replace the controller lease.

        Not gated by a pre-existing matching lease (mirrors
        ``reducer.claim_lease`` exactly) — this is the one command legitimately
        callable by a non-owner, since otherwise no client could ever acquire
        the first lease. The reducer's fencing-token check still applies: a
        stale/non-advancing epoch is rejected and logged as an ``error``
        event, not raised.

        Returns:
            The manifest after the command (whether accepted or rejected).
        """
        self.state = claim_lease(self.state, holder_id, epoch)
        return self.get_manifest()

    def start_playback(self, entry: StationEntry, holder_id: str, epoch: int) -> dict[str, Any]:
        """Command: idle -> playing(entry).

        ``entry`` is a :class:`StationEntry` here rather than a plain dict —
        this spike does not build an entry-construction wire format (YAGNI;
        the design doc's manifest/checkpoint boundary is the thing under
        test, not a full content-catalog sync protocol). A real native
        client would receive entries via a separate asset-manifest sync
        (design doc point 4, "Download prepared assets") and reference them
        by ``entry_id``; that is out of scope for this spike.
        """
        lease = ControllerLease(holder_id=holder_id, epoch=epoch)
        self.state = apply(self.state, StartPlayback(entry=entry), lease)
        return self.get_manifest()

    def submit_checkpoint(
        self,
        *,
        mutation_id: str,
        expected_revision: int,
        media_offset_ms: int,
        state_label: str,
        writer_device: str,
        holder_id: str,
        epoch: int,
    ) -> dict[str, Any]:
        """Command: idempotent checkpoint write.

        ``mutation_id`` + ``expected_revision`` give this command the exact
        idempotent-write / stale-writer-rejection shape the design doc
        requires for phone/Mac sync ("Every write includes a client mutation
        ID and expected station revision").
        """
        lease = ControllerLease(holder_id=holder_id, epoch=epoch)
        action = Checkpoint(
            mutation_id=mutation_id,
            expected_revision=expected_revision,
            media_offset_ms=media_offset_ms,
            state_label=state_label,  # type: ignore[arg-type]
            writer_device=writer_device,
        )
        self.state = apply(self.state, action, lease)
        return self.get_manifest()

    def accept_interruption(
        self,
        *,
        bulletin: StationEntry,
        interrupt_offset_ms: int,
        policy_current: bool,
        holder_id: str,
        epoch: int,
    ) -> dict[str, Any]:
        """Command: playing(entry) -> checkpointed -> playing(bulletin)."""
        lease = ControllerLease(holder_id=holder_id, epoch=epoch)
        action = AcceptInterruption(
            bulletin=bulletin,
            interrupt_offset_ms=interrupt_offset_ms,
            policy_current=policy_current,
        )
        self.state = apply(self.state, action, lease)
        return self.get_manifest()

    def resume(self, holder_id: str, epoch: int) -> dict[str, Any]:
        """Command: playing(bulletin) -> resumed(entry), popping the interruption stack."""
        lease = ControllerLease(holder_id=holder_id, epoch=epoch)
        self.state = apply(self.state, ResumeFromInterruption(), lease)
        return self.get_manifest()

    def request_handoff(
        self,
        *,
        phone_device_id: str,
        requested_epoch: int,
        last_known_mac_revision: int,
        holder_id: str,
        epoch: int,
    ) -> dict[str, Any]:
        """Command: playing(entry) -> handoff_pending."""
        lease = ControllerLease(holder_id=holder_id, epoch=epoch)
        action = RequestHandoff(
            phone_device_id=phone_device_id,
            requested_epoch=requested_epoch,
            last_known_mac_revision=last_known_mac_revision,
        )
        self.state = apply(self.state, action, lease)
        return self.get_manifest()

    def acknowledge_handoff(
        self, *, phone_device_id: str, epoch: int, holder_id: str, requester_epoch: int
    ) -> dict[str, Any]:
        """Command: handoff_pending -> paused_on_mac -> owned_by_iphone.

        Note two distinct epochs: ``epoch`` is the phone ownership epoch
        being acknowledged (``AcknowledgeHandoff.epoch``); ``requester_epoch``
        is the Mac controller lease epoch of the caller presenting this
        command (the Mac acknowledging, not the phone acting directly).
        """
        lease = ControllerLease(holder_id=holder_id, epoch=requester_epoch)
        action = AcknowledgeHandoff(phone_device_id=phone_device_id, epoch=epoch)
        self.state = apply(self.state, action, lease)
        return self.get_manifest()


# ---------------------------------------------------------------------------
# Thin, stdlib-only boundary demonstration.
# ---------------------------------------------------------------------------

# A command dict has a "command" key naming the ``StationCore`` method and a
# "args" key holding the plain-JSON kwargs for it. This is the entire wire
# format a native client would need to reimplement in Swift: a JSON object
# in, a JSON manifest object out. No Python object ever crosses this line.
_COMMANDS: dict[str, str] = {
    "claim_lease": "claim_lease",
    "submit_checkpoint": "submit_checkpoint",
    "accept_interruption": "accept_interruption",
    "resume": "resume",
    "request_handoff": "request_handoff",
    "acknowledge_handoff": "acknowledge_handoff",
    "start_playback": "start_playback",
}


class InProcessClient:
    """An in-process stand-in for a native client, honoring the JSON boundary.

    Deliberately does NOT hold a reference to ``StationCore`` in any way
    that would let it reach into ``StationState`` or station value objects.
    It only ever calls :meth:`fetch_manifest_bytes` (raw JSON bytes) and
    :meth:`submit_command` (a plain command dict in, a plain manifest dict
    out) — exactly what a real native client's HTTP/IPC layer would see.
    This is enough to prove the boundary is language-neutral without
    standing up a real HTTP server (YAGNI per the task brief).

    A ``StationEntry`` must still be passed through for ``start_playback``/
    ``accept_interruption`` in this spike (see ``StationCore.start_playback``
    docstring for why entry-construction wire format is out of scope) — the
    client passes it through opaquely without inspecting or constructing it,
    which is the one deliberate seam left unclosed by this spike.

    Attributes:
        holder_id: This client's lease identity.
    """

    def __init__(self, core: StationCore, holder_id: str) -> None:
        self._dispatch: Callable[[dict[str, Any]], dict[str, Any]] = _make_dispatcher(core)
        self.holder_id = holder_id

    def fetch_manifest_bytes(self) -> bytes:
        """Return the current manifest as encoded JSON bytes (the wire format)."""
        manifest_dict = json.loads(self._dispatch({"command": "_get_manifest", "args": {}})["manifest_json"])
        return json.dumps(manifest_dict).encode("utf-8")

    def submit_command(self, command: str, **kwargs: Any) -> dict[str, Any]:
        """Submit a command dict and return the resulting manifest dict.

        Args:
            command: One of the keys in ``_COMMANDS``.
            **kwargs: Plain-JSON arguments for the command (excluding
                ``holder_id``/``epoch``, which this client injects from its
                own identity plus the caller-supplied ``epoch``).

        Raises:
            CommandRejected: If ``command`` is not a recognized command name.
        """
        if command not in _COMMANDS:
            raise CommandRejected(f"unknown command: {command!r}")
        payload = {"command": command, "args": {**kwargs, "holder_id": self.holder_id}}
        return self._dispatch(payload)


def _make_dispatcher(core: StationCore) -> Callable[[dict[str, Any]], dict[str, Any]]:
    """Build a closure that dispatches plain command dicts onto ``core``.

    This is the one place that translates a wire-format dict into a
    ``StationCore`` method call. It stands in for what an HTTP handler or
    IPC endpoint would do in a real deployment. ``core`` itself never
    escapes this closure — ``InProcessClient`` cannot reach it directly.
    """

    def dispatch(payload: dict[str, Any]) -> dict[str, Any]:
        command = payload["command"]
        args = dict(payload.get("args", {}))
        if command == "_get_manifest":
            return {"manifest_json": json.dumps(core.get_manifest())}
        method = getattr(core, _COMMANDS[command])
        result = method(**args)
        logger.debug("dispatched command=%s -> revision=%s", command, result.get("station_revision"))
        return result

    return dispatch


__all__ = [
    "MANIFEST_SCHEMA_VERSION",
    "CommandRejected",
    "InProcessClient",
    "StationCore",
]
