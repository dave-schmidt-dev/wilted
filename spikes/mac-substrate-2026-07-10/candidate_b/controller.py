"""CANDIDATE (b): a ``StationController`` hosted inside the current app process.

Models "the controller hosted by the current Python application" candidate
from the design doc's architecture decision framework (option 1: retain the
Python core, extract a headless station controller, keep Textual — or a thin
replacement — as the Mac surface). This mirrors how the Textual TUI would
host a controller today: in-process, called directly as Python methods, no
serialization boundary between the caller and the authoritative state.

``StationController`` holds one ``StationState`` in memory and exposes
methods that mirror the committed reducer's actions 1:1. Every method is a
thin wrapper: build the action dataclass, call ``wilted.station.reducer.apply``
(or ``claim_lease``), store the returned state, return it. No method does
anything the reducer itself doesn't already do — this class adds no new
state-transition logic, only an in-process home for the state and a
manifest/checkpoint read surface.

Deliberately NOT included (YAGNI / substrate-neutral per the spike's rules):

- No Textual import, no UI of any kind.
- No iOS/SQLite database of any kind.
- No IPC, no networking, no serialization boundary — callers hold a direct
  Python reference to the controller and call its methods synchronously.
- No real audio playback — the ``PlaybackAdapter`` protocol is not invoked
  here; this spike measures state/ownership behavior only.

The multi-process ownership weakness this candidate is expected to exhibit
(two independent in-memory controllers, no shared store, split-brain) is
demonstrated in ``measure.py``, not hidden or worked around here.
"""

from __future__ import annotations

import logging
from typing import TYPE_CHECKING

from wilted.station.models import ControllerLease
from wilted.station.reducer import (
    AcceptInterruption,
    AcknowledgeHandoff,
    Checkpoint,
    RequestHandoff,
    ResumeFromInterruption,
    StartPlayback,
    StationState,
    Stop,
    apply,
    claim_lease,
)

if TYPE_CHECKING:
    from wilted.station.models import PlaybackCheckpoint, StationEntry

logger = logging.getLogger(__name__)


class StationController:
    """In-process host for one authoritative ``StationState``.

    Instantiated directly by an in-process caller (e.g. the Textual TUI, a
    CLI command, or — as demonstrated in ``measure.py`` — a test harness
    simulating a second OS process). Two ``StationController`` instances
    never share memory or state: each owns an independent ``StationState``
    with its own lease. That is the point of the multi-process-ownership
    measurement in ``measure.py`` — this class provides no cross-instance
    coordination whatsoever, by construction.

    Attributes:
        holder_id: This controller's lease holder identity, used as the
            default requester identity for every mutating method.
        state: The current authoritative ``StationState``. Read directly by
            in-process callers; there is no accessor indirection because
            there is no serialization boundary to enforce one across.
    """

    def __init__(self, holder_id: str) -> None:
        """Create a controller with an empty (idle) station state.

        Args:
            holder_id: The identity this controller will present as
                ``requester_lease.holder_id`` on every mutating call, and
                that it will claim the lease under. Mirrors a real host
                process's own identity (e.g. a PID-derived string or a
                fixed id like the TUI's process).
        """
        self.holder_id = holder_id
        self.state: StationState = StationState()
        logger.debug("StationController %r initialized with idle StationState", holder_id)

    # -- Lease -----------------------------------------------------------

    def claim_lease(self, epoch: int) -> StationState:
        """Claim/reclaim the controller lease under this controller's ``holder_id``.

        Direct in-process call into ``wilted.station.reducer.claim_lease``.
        Not gated by any cross-process check — see the class docstring: this
        candidate has no mechanism to know whether another
        ``StationController`` instance (in this process or another) already
        holds a lease over some *other* state, because state is never
        shared.
        """
        self.state = claim_lease(self.state, self.holder_id, epoch)
        return self.state

    # -- Action methods (1:1 with reducer actions) ------------------------

    def start_playback(self, entry: StationEntry) -> StationState:
        """Mirror of ``StartPlayback``, called in-process with this controller's lease."""
        self.state = self._apply(StartPlayback(entry=entry))
        return self.state

    def checkpoint(
        self,
        *,
        mutation_id: str,
        expected_revision: int,
        media_offset_ms: int,
        state_label: str,
        writer_device: str,
    ) -> StationState:
        """Mirror of ``Checkpoint``, called in-process with this controller's lease."""
        self.state = self._apply(
            Checkpoint(
                mutation_id=mutation_id,
                expected_revision=expected_revision,
                media_offset_ms=media_offset_ms,
                state_label=state_label,
                writer_device=writer_device,
            )
        )
        return self.state

    def accept_interruption(
        self, *, bulletin: StationEntry, interrupt_offset_ms: int, policy_current: bool
    ) -> StationState:
        """Mirror of ``AcceptInterruption``, called in-process with this controller's lease."""
        self.state = self._apply(
            AcceptInterruption(
                bulletin=bulletin,
                interrupt_offset_ms=interrupt_offset_ms,
                policy_current=policy_current,
            )
        )
        return self.state

    def resume(self) -> StationState:
        """Mirror of ``ResumeFromInterruption``, called in-process with this controller's lease."""
        self.state = self._apply(ResumeFromInterruption())
        return self.state

    def request_handoff(
        self, *, phone_device_id: str, requested_epoch: int, last_known_mac_revision: int
    ) -> StationState:
        """Mirror of ``RequestHandoff``, called in-process with this controller's lease."""
        self.state = self._apply(
            RequestHandoff(
                phone_device_id=phone_device_id,
                requested_epoch=requested_epoch,
                last_known_mac_revision=last_known_mac_revision,
            )
        )
        return self.state

    def acknowledge_handoff(self, *, phone_device_id: str, epoch: int) -> StationState:
        """Mirror of ``AcknowledgeHandoff``, called in-process with this controller's lease."""
        self.state = self._apply(AcknowledgeHandoff(phone_device_id=phone_device_id, epoch=epoch))
        return self.state

    def stop(self) -> StationState:
        """Mirror of ``Stop``, called in-process with this controller's lease."""
        self.state = self._apply(Stop())
        return self.state

    def _apply(self, action: object) -> StationState:
        """Apply ``action`` using this controller's current lease as the requester.

        Presents ``(self.holder_id, self.state.lease.epoch)`` as the
        requester lease. If this controller has never claimed a lease
        (``self.state.lease is None``), presents epoch 0, which ``apply()``
        will reject (no lease held) exactly like any other unowned caller —
        there is no special-casing here beyond what the reducer already
        does.
        """
        current_epoch = self.state.lease.epoch if self.state.lease is not None else 0
        requester_lease = ControllerLease(holder_id=self.holder_id, epoch=current_epoch)
        return apply(self.state, action, requester_lease)  # type: ignore[arg-type]

    # -- Manifest / checkpoint read surface --------------------------------

    def get_manifest(self) -> dict[str, object]:
        """Return a versioned, in-process manifest snapshot of the current station state.

        Served directly from this controller's in-memory ``StationState`` to
        an in-process caller — there is no serialization boundary to cross,
        so this "manifest" is a plain dict view rather than a wire format.
        Still versioned (``station_revision``) per Task 0.3's done-when
        condition that both candidates expose a versioned manifest/checkpoint,
        so the shape is comparable to candidate (a)'s manifest even though
        the transport is trivial here (a Python method return value).

        Returns:
            A dict with ``station_revision``, ``lifecycle``, ``lease``
            (holder_id/epoch or None), ``phone_epoch``, ``active_entry_id``,
            and ``interruption_stack`` (tuple of entry ids).
        """
        lease = self.state.lease
        return {
            "station_revision": self.state.station_revision,
            "lifecycle": self.state.lifecycle.value,
            "lease": {"holder_id": lease.holder_id, "epoch": lease.epoch} if lease is not None else None,
            "phone_epoch": self.state.phone_epoch,
            "active_entry_id": self.state.active_entry.entry_id if self.state.active_entry else None,
            "interruption_stack": tuple(e.entry_id for e in self.state.interruption_stack),
        }

    def get_checkpoint(self) -> PlaybackCheckpoint | None:
        """Return the most recent accepted ``PlaybackCheckpoint``, or None.

        Served directly from in-process memory — identical value the
        controller itself would use, since there is no round trip for an
        in-process caller to go stale across.
        """
        return self.state.checkpoint


__all__ = ["StationController"]
