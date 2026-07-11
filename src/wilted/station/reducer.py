"""Pure state-transition reducer for the station contract.

Implements the lifecycle described in the design doc:

    idle -> playing(entry)
    playing(entry) -> checkpointed -> playing(bulletin) -> resumed(entry)
    playing(entry) -> handoff_pending -> paused_on_mac -> owned_by_iphone
    any state -> stopped (durable checkpoint retained)

``StationState`` is the immutable overall reducer state. Actions are a
small discriminated union of frozen dataclasses. ``apply(state, action,
requester_lease)`` is the single entry point: it checks lease ownership
centrally, then dispatches to a per-action pure transition function. Every
transition function returns a *new* ``StationState`` (or the identical
``state`` object when a write is rejected) — nothing here mutates its
arguments.

Rejection-vs-exception convention (documented once, applied consistently):
expected, spec-named rejection cases — stale revision, stale/repeated
mutation_id, non-owner lease, stale Mac epoch vs. phone epoch, expired
entry, incomplete bulletin media, missing safe checkpoint for interruption
— are all normal outcomes a caller must handle, so they return the
*current* state unchanged rather than raising. Exceptions
(``ValueError``/``TypeError``) are reserved for genuine programmer errors,
e.g. constructing a malformed action or calling a transition function with
an action type it does not handle.
"""

from __future__ import annotations

import dataclasses
from dataclasses import dataclass, field
from enum import Enum

from wilted.station.models import ControllerLease, PlaybackCheckpoint, StationEntry, StationEvent, now_utc_z


class StationLifecycle(Enum):
    """The station's coarse lifecycle position, per the design doc's diagram."""

    IDLE = "idle"
    PLAYING = "playing"
    CHECKPOINTED = "checkpointed"
    HANDOFF_PENDING = "handoff_pending"
    PAUSED_ON_MAC = "paused_on_mac"
    OWNED_BY_IPHONE = "owned_by_iphone"
    STOPPED = "stopped"


@dataclass(frozen=True, slots=True)
class StationState:
    """Immutable overall reducer state.

    Attributes:
        lifecycle: Current coarse lifecycle position.
        station_revision: Logical station revision, bumped on every accepted
            mutating write. Separate from the controller lease epoch.
        active_entry: The currently playing/paused entry, if any.
        checkpoint: The most recent accepted :class:`PlaybackCheckpoint`, if any.
        interruption_stack: Entries interrupted and not yet resumed, held
            in ascending ``priority`` order (index 0 = most urgent). See
            ``_accept_interruption``/``_resume_from_interruption``, which
            sort on insert and pop index 0. NOTE: this is *priority-ordered*
            resume, not strict LIFO "resume whatever you just interrupted";
            whether priority-ordered or most-recent-first is the intended
            product semantics is an open design question deferred to Plan A
            (see HISTORY.md / handoff.md). Holds full entries (matches the
            ``PlaybackCheckpoint.interrupted_entry_stack`` shape) so the
            reducer can pop back to them.
        lease: The current :class:`ControllerLease` holder, if any. None
            means no controller currently owns the station.
        phone_epoch: The last acknowledged iPhone ownership epoch, or None
            if the station has never been handed off to the phone. Distinct
            from ``lease.epoch`` — this tracks Mac/phone handoff specifically
            (see design doc section "Phone handoff: local-only first").
        seen_mutation_ids: Mutation ids already applied, for idempotent-write
            and stale-repeat detection on :class:`Checkpoint` actions.
        events: Bounded, append-only, in-memory diagnostic log. Not durable
            listening history — see :class:`~wilted.station.models.StationEvent`.
    """

    lifecycle: StationLifecycle = StationLifecycle.IDLE
    station_revision: int = 0
    active_entry: StationEntry | None = None
    checkpoint: PlaybackCheckpoint | None = None
    interruption_stack: tuple[StationEntry, ...] = ()
    lease: ControllerLease | None = None
    phone_epoch: int | None = None
    seen_mutation_ids: frozenset[str] = field(default_factory=frozenset)
    events: tuple[StationEvent, ...] = ()

    def with_event(self, event: StationEvent) -> StationState:
        """Return a new state with ``event`` appended to the diagnostic log."""
        return dataclasses.replace(self, events=(*self.events, event))


# ---------------------------------------------------------------------------
# Actions (discriminated union of frozen dataclasses)
# ---------------------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class StartPlayback:
    """idle -> playing(entry)."""

    entry: StationEntry
    now: str = field(default_factory=now_utc_z)


@dataclass(frozen=True, slots=True)
class Checkpoint:
    """Write a checkpoint with a mutation id and expected revision.

    Enforces idempotent-write (a repeated ``mutation_id`` is a no-op
    rejection, not a re-application) and stale-writer rejection (an
    ``expected_revision`` that does not match ``state.station_revision`` is
    rejected).
    """

    mutation_id: str
    expected_revision: int
    media_offset_ms: int
    state_label: str  # "playing" | "paused" | "stopped" — see PlaybackState
    writer_device: str
    now: str = field(default_factory=now_utc_z)


@dataclass(frozen=True, slots=True)
class AcceptInterruption:
    """playing(entry) -> checkpointed -> playing(bulletin).

    Accepted only when the policy is current (``policy_current=True``), the
    bulletin's media is complete and non-empty
    (``bulletin.media.is_playable``), and a safe resume checkpoint exists
    (the currently active entry's ``SafeInterruptionMap`` has a safe point
    at the given offset). Nested interruptions are queued by priority
    (ascending ``priority`` value = more urgent, ties broken by insertion
    order); expired entries (``bulletin.is_expired(now)``) are discarded.
    """

    bulletin: StationEntry
    interrupt_offset_ms: int
    policy_current: bool
    now: str = field(default_factory=now_utc_z)


@dataclass(frozen=True, slots=True)
class ResumeFromInterruption:
    """playing(bulletin) -> resumed(entry), popping the interruption stack."""

    now: str = field(default_factory=now_utc_z)


@dataclass(frozen=True, slots=True)
class RequestHandoff:
    """playing(entry) -> handoff_pending. iPhone requests takeover with the last Mac revision."""

    phone_device_id: str
    requested_epoch: int
    last_known_mac_revision: int
    now: str = field(default_factory=now_utc_z)


@dataclass(frozen=True, slots=True)
class AcknowledgeHandoff:
    """handoff_pending -> paused_on_mac -> owned_by_iphone.

    The Mac atomically records the phone ownership epoch and stops only
    after acknowledgement. A stale Mac (presenting an epoch older than
    ``state.phone_epoch``) cannot clobber a newer phone checkpoint and is
    rejected.
    """

    phone_device_id: str
    epoch: int
    now: str = field(default_factory=now_utc_z)


@dataclass(frozen=True, slots=True)
class Stop:
    """any state -> stopped (durable checkpoint retained)."""

    now: str = field(default_factory=now_utc_z)


Action = (
    StartPlayback
    | Checkpoint
    | AcceptInterruption
    | ResumeFromInterruption
    | RequestHandoff
    | AcknowledgeHandoff
    | Stop
)


# ---------------------------------------------------------------------------
# Central lease-checked entry point
# ---------------------------------------------------------------------------


def apply(state: StationState, action: Action, requester_lease: ControllerLease) -> StationState:
    """Apply ``action`` to ``state`` iff ``requester_lease`` matches the current holder.

    This is the single public entry point for mutating the station. It
    centrally enforces controller-owner-loss rejection: if ``state.lease``
    is unset, or does not match ``requester_lease`` (holder_id AND epoch),
    the action is rejected and a new state with the meaningful fields
    unchanged — ``station_revision`` not advanced, a diagnostic rejection
    event appended — is returned; the caller's lease has been lost or was
    never held. On a lease match, the
    action is dispatched to its per-action pure transition function.

    Args:
        state: Current immutable station state.
        action: One of the action dataclasses above.
        requester_lease: The lease the caller believes it holds.

    Returns:
        A new ``StationState`` on success. On any expected rejection
        (owner-loss, stale revision, stale mutation id, expired entry,
        incomplete media, missing safe checkpoint, stale epoch, etc) a new
        ``StationState`` is *also* returned — with the meaningful fields
        unchanged and a diagnostic rejection event appended.
        ``station_revision`` does not advance on rejection, so detect a
        rejection by comparing ``station_revision`` (or inspecting the
        appended event), never by object identity: ``result is state`` is
        always ``False``.

    Raises:
        TypeError: If ``action`` is not one of the recognized action types
            (a genuine programmer error, not a normal rejection case).
    """
    if state.lease is None or not state.lease.matches(requester_lease.holder_id, requester_lease.epoch):
        return state.with_event(
            StationEvent(
                kind="error",
                timestamp=action.now,
                entry_id=None,
                message="rejected: requester lease does not match current controller lease (owner-loss)",
            )
        )

    if isinstance(action, StartPlayback):
        return _start_playback(state, action)
    if isinstance(action, Checkpoint):
        return _checkpoint(state, action)
    if isinstance(action, AcceptInterruption):
        return _accept_interruption(state, action)
    if isinstance(action, ResumeFromInterruption):
        return _resume_from_interruption(state, action)
    if isinstance(action, RequestHandoff):
        return _request_handoff(state, action)
    if isinstance(action, AcknowledgeHandoff):
        return _acknowledge_handoff(state, action)
    if isinstance(action, Stop):
        return _stop(state, action)

    raise TypeError(f"apply() received an unrecognized action type: {type(action)!r}")


def claim_lease(state: StationState, holder_id: str, epoch: int) -> StationState:
    """Grant/replace the controller lease. Not gated by :func:`apply`'s lease check.

    This is the one mutation that is legitimately allowed without already
    holding a matching lease — otherwise no process could ever acquire the
    first lease. A real controller is expected to guard calls to this with
    its own arbitration (e.g. "only via the local launchd-managed
    controller process"); this reducer only guarantees the *shape* of the
    transition, not who is allowed to call it.

    Enforces the fencing-token invariant: a claim is accepted only when it
    strictly advances ownership — either there is no current lease (first
    acquire), or ``epoch`` is strictly greater than the current lease's
    epoch. A claim at an old or equal epoch is a stale reclaim attempt
    (e.g. an orphaned process trying to steal ownership back after another
    controller already took over at a higher epoch) and is rejected: the
    lease is left unchanged and an ``error`` event is appended, per this
    module's rejection-vs-exception convention.
    """
    if state.lease is not None and epoch <= state.lease.epoch:
        return state.with_event(
            StationEvent(
                kind="error",
                timestamp=now_utc_z(),
                entry_id=None,
                message=(
                    f"rejected: stale lease claim by {holder_id!r} at epoch {epoch}, "
                    f"current lease epoch is {state.lease.epoch} (fencing token did not advance)"
                ),
            )
        )
    new_lease = ControllerLease(holder_id=holder_id, epoch=epoch)
    return dataclasses.replace(state, lease=new_lease)


# ---------------------------------------------------------------------------
# Per-action pure transition functions
# ---------------------------------------------------------------------------


def _start_playback(state: StationState, action: StartPlayback) -> StationState:
    """idle -> playing(entry). Rejects expired entries without admitting them."""
    if action.entry.is_expired(action.now):
        return state.with_event(
            StationEvent(
                kind="skip",
                timestamp=action.now,
                entry_id=action.entry.entry_id,
                message="rejected: entry is expired",
            )
        )

    new_revision = state.station_revision + 1
    return dataclasses.replace(
        state,
        lifecycle=StationLifecycle.PLAYING,
        station_revision=new_revision,
        active_entry=action.entry,
        checkpoint=None,
        interruption_stack=(),
        events=(
            *state.events,
            StationEvent(kind="start", timestamp=action.now, entry_id=action.entry.entry_id, message=""),
        ),
    )


def _checkpoint(state: StationState, action: Checkpoint) -> StationState:
    """Write a checkpoint. Rejects stale revision, stale/repeated mutation ids,
    and checkpoints on a non-playing station."""
    if action.mutation_id in state.seen_mutation_ids:
        return state.with_event(
            StationEvent(
                kind="error",
                timestamp=action.now,
                entry_id=state.active_entry.entry_id if state.active_entry else None,
                message=f"rejected: mutation_id {action.mutation_id!r} already applied (stale/repeated write)",
            )
        )

    if state.lifecycle is not StationLifecycle.PLAYING or state.active_entry is None:
        return state.with_event(
            StationEvent(
                kind="error",
                timestamp=action.now,
                entry_id=state.active_entry.entry_id if state.active_entry else None,
                message=(
                    f"rejected: checkpoint requires a playing station with an active entry "
                    f"(lifecycle was {state.lifecycle.value}, active_entry="
                    f"{state.active_entry.entry_id if state.active_entry else None})"
                ),
            )
        )

    if action.expected_revision != state.station_revision:
        return state.with_event(
            StationEvent(
                kind="error",
                timestamp=action.now,
                entry_id=state.active_entry.entry_id if state.active_entry else None,
                message=(
                    f"rejected: expected_revision {action.expected_revision} != "
                    f"current station_revision {state.station_revision} (stale writer)"
                ),
            )
        )

    new_revision = state.station_revision + 1
    new_checkpoint = PlaybackCheckpoint(
        station_revision=new_revision,
        entry_id=state.active_entry.entry_id,
        media_offset_ms=action.media_offset_ms,
        state=action.state_label,  # type: ignore[arg-type]
        interrupted_entry_stack=tuple(e.entry_id for e in state.interruption_stack),
        writer_device=action.writer_device,
        mutation_id=action.mutation_id,
        timestamp=action.now,
    )
    new_lifecycle = StationLifecycle.STOPPED if action.state_label == "stopped" else state.lifecycle
    return dataclasses.replace(
        state,
        lifecycle=new_lifecycle,
        station_revision=new_revision,
        checkpoint=new_checkpoint,
        seen_mutation_ids=state.seen_mutation_ids | {action.mutation_id},
        events=(
            *state.events,
            StationEvent(kind="checkpoint", timestamp=action.now, entry_id=state.active_entry.entry_id, message=""),
        ),
    )


def _accept_interruption(state: StationState, action: AcceptInterruption) -> StationState:
    """playing(entry) -> checkpointed -> playing(bulletin).

    Rejects (state unchanged, active entry untouched) when: the policy is
    not current, the bulletin is expired, the bulletin's media is not
    playable (failed/incomplete generation — logged and skipped per the
    design doc), or the currently active entry has no safe interruption
    point at the given offset (including the explicit no-interrupt mode,
    which must never silently defer forever — it is rejected here exactly
    like any other missing-safe-checkpoint case, with a visible/attributable
    rejection event).
    """
    if state.active_entry is None:
        return state.with_event(
            StationEvent(
                kind="skip",
                timestamp=action.now,
                entry_id=action.bulletin.entry_id,
                message="rejected: no active entry to interrupt",
            )
        )

    if not action.policy_current:
        return state.with_event(
            StationEvent(
                kind="skip",
                timestamp=action.now,
                entry_id=action.bulletin.entry_id,
                message="rejected: interruption policy is not current",
            )
        )

    if action.bulletin.is_expired(action.now):
        return state.with_event(
            StationEvent(
                kind="skip",
                timestamp=action.now,
                entry_id=action.bulletin.entry_id,
                message="rejected: bulletin entry is expired, discarded",
            )
        )

    if not action.bulletin.media.is_playable:
        return state.with_event(
            StationEvent(
                kind="error",
                timestamp=action.now,
                entry_id=action.bulletin.entry_id,
                message="rejected: bulletin generation failed/incomplete (media not playable), skipped",
            )
        )

    if not state.active_entry.media.safe_interruption.safe_point_at(action.interrupt_offset_ms):
        reason = (
            "no-interrupt mode: entry has no safe interruption map"
            if state.active_entry.media.safe_interruption.is_no_interrupt
            else "offset is not within a known-safe window"
        )
        return state.with_event(
            StationEvent(
                kind="skip",
                timestamp=action.now,
                entry_id=action.bulletin.entry_id,
                message=f"rejected: no safe resume checkpoint for active entry ({reason})",
            )
        )

    # Accepted: checkpoint the active entry, push it onto the interruption
    # stack ordered by priority (queue nested interruptions by priority —
    # ascending value = more urgent), then switch to playing the bulletin.
    resume_checkpoint = PlaybackCheckpoint(
        station_revision=state.station_revision,
        entry_id=state.active_entry.entry_id,
        media_offset_ms=action.interrupt_offset_ms,
        state="paused",
        interrupted_entry_stack=tuple(e.entry_id for e in state.interruption_stack),
        writer_device="controller",
        mutation_id=f"auto-interrupt-{action.bulletin.entry_id}-{action.now}",
        timestamp=action.now,
    )

    new_stack = list(state.interruption_stack)
    new_stack.append(state.active_entry)
    new_stack.sort(key=lambda e: e.priority)

    new_revision = state.station_revision + 1
    return dataclasses.replace(
        state,
        lifecycle=StationLifecycle.PLAYING,
        station_revision=new_revision,
        active_entry=action.bulletin,
        checkpoint=resume_checkpoint,
        interruption_stack=tuple(new_stack),
        events=(
            *state.events,
            StationEvent(kind="interruption", timestamp=action.now, entry_id=action.bulletin.entry_id, message=""),
        ),
    )


def _resume_from_interruption(state: StationState, action: ResumeFromInterruption) -> StationState:
    """playing(bulletin) -> resumed(entry), popping the interruption stack.

    Pops the highest-priority (lowest ``priority`` value) interrupted entry.
    No-op (state unchanged) if the stack is empty.
    """
    if not state.interruption_stack:
        return state.with_event(
            StationEvent(
                kind="skip",
                timestamp=action.now,
                entry_id=None,
                message="rejected: no interrupted entry to resume",
            )
        )

    next_entry = state.interruption_stack[0]
    remaining = state.interruption_stack[1:]
    new_revision = state.station_revision + 1
    return dataclasses.replace(
        state,
        lifecycle=StationLifecycle.PLAYING,
        station_revision=new_revision,
        active_entry=next_entry,
        interruption_stack=remaining,
        events=(
            *state.events,
            StationEvent(kind="resume", timestamp=action.now, entry_id=next_entry.entry_id, message=""),
        ),
    )


def _request_handoff(state: StationState, action: RequestHandoff) -> StationState:
    """playing(entry) -> handoff_pending. Records the phone's requested takeover.

    Rejected unless the station is currently ``playing`` with an active
    entry — this enforces the spec's ``playing(entry) -> handoff_pending``
    edge, blocking "handoff of nothing" from idle/stopped and a duplicate
    request while already ``handoff_pending`` (or any other non-playing
    phase). Also rejected if ``last_known_mac_revision`` does not match the
    current ``station_revision`` (the phone's view is stale; it must
    retry/take over explicitly with fresh state) or if ``requested_epoch``
    is not newer than any already-acknowledged ``phone_epoch``.
    """
    if state.lifecycle is not StationLifecycle.PLAYING or state.active_entry is None:
        return state.with_event(
            StationEvent(
                kind="error",
                timestamp=action.now,
                entry_id=state.active_entry.entry_id if state.active_entry else None,
                message=(
                    f"rejected: handoff can only be requested from a playing station with an "
                    f"active entry (lifecycle was {state.lifecycle.value})"
                ),
            )
        )

    if action.last_known_mac_revision != state.station_revision:
        return state.with_event(
            StationEvent(
                kind="error",
                timestamp=action.now,
                entry_id=state.active_entry.entry_id if state.active_entry else None,
                message=(
                    f"rejected: stale handoff request, last_known_mac_revision "
                    f"{action.last_known_mac_revision} != current {state.station_revision}"
                ),
            )
        )

    if state.phone_epoch is not None and action.requested_epoch <= state.phone_epoch:
        return state.with_event(
            StationEvent(
                kind="error",
                timestamp=action.now,
                entry_id=state.active_entry.entry_id if state.active_entry else None,
                message=(
                    f"rejected: requested_epoch {action.requested_epoch} is not newer than "
                    f"current phone_epoch {state.phone_epoch}"
                ),
            )
        )

    return dataclasses.replace(
        state,
        lifecycle=StationLifecycle.HANDOFF_PENDING,
        # Accepted mutating write => advance the revision (StationState's
        # documented contract: bumped on every accepted mutating write). The
        # StationController detects acceptance-vs-rejection by this delta and
        # persists only on a bump, and the store's compare-and-set fencing
        # token relies on every persisted write advancing the revision.
        station_revision=state.station_revision + 1,
        events=(
            *state.events,
            StationEvent(
                kind="checkpoint",
                timestamp=action.now,
                entry_id=state.active_entry.entry_id if state.active_entry else None,
                message=f"handoff requested by {action.phone_device_id} at epoch {action.requested_epoch}",
            ),
        ),
    )


def _acknowledge_handoff(state: StationState, action: AcknowledgeHandoff) -> StationState:
    """handoff_pending -> paused_on_mac -> owned_by_iphone.

    The Mac atomically records the phone ownership epoch and stops only
    after this acknowledgement. Rejects a stale Mac acknowledgement whose
    epoch is not newer than the currently recorded ``phone_epoch`` — such a
    write must not clobber a newer phone checkpoint. Also rejects if the
    station is not currently ``handoff_pending`` (an acknowledgement without
    a matching request is a programmer/protocol error at the call site, but
    the reducer still treats it as a normal rejection rather than raising,
    per this module's rejection-vs-exception convention).

    Composes both lifecycle steps (``paused_on_mac`` then
    ``owned_by_iphone``) into a single transition so no intermediate state
    is ever observable where the Mac is still an active playing owner *and*
    the phone is marked as owner simultaneously — the two are mutually
    exclusive in the returned state.

    The epoch/clobber check runs before the lifecycle-phase check: a stale
    Mac replaying an old acknowledgement after ownership has already moved
    on (station is no longer ``handoff_pending``) is still, first and
    foremost, an attempt to clobber a newer phone checkpoint — that is the
    more specific and security-relevant rejection reason, so it takes
    priority over the more generic "wrong lifecycle phase" rejection.
    """
    if state.phone_epoch is not None and action.epoch <= state.phone_epoch:
        return state.with_event(
            StationEvent(
                kind="error",
                timestamp=action.now,
                entry_id=state.active_entry.entry_id if state.active_entry else None,
                message=(
                    f"rejected: stale Mac acknowledgement, epoch {action.epoch} is not newer than "
                    f"current phone_epoch {state.phone_epoch} (would clobber newer phone checkpoint)"
                ),
            )
        )

    if state.lifecycle is not StationLifecycle.HANDOFF_PENDING:
        return state.with_event(
            StationEvent(
                kind="error",
                timestamp=action.now,
                entry_id=state.active_entry.entry_id if state.active_entry else None,
                message=f"rejected: acknowledge_handoff called outside handoff_pending (was {state.lifecycle.value})",
            )
        )

    if state.checkpoint is not None:
        # A checkpoint already exists (from a prior Checkpoint action) —
        # mark it stopped in place, preserving its recorded offset.
        durable_checkpoint = dataclasses.replace(state.checkpoint, state="stopped")
    elif state.active_entry is not None:
        # No checkpoint was ever explicitly written, but there is an active
        # entry — synthesize a durable stopped checkpoint at offset 0 so the
        # "Mac stops, durable checkpoint retained" guarantee holds even when
        # the caller never wrote an intermediate Checkpoint action.
        durable_checkpoint = PlaybackCheckpoint(
            station_revision=state.station_revision,
            entry_id=state.active_entry.entry_id,
            media_offset_ms=0,
            state="stopped",
            interrupted_entry_stack=tuple(e.entry_id for e in state.interruption_stack),
            writer_device="mac",
            mutation_id=f"auto-handoff-stop-{action.phone_device_id}-{action.epoch}",
            timestamp=action.now,
        )
    else:
        durable_checkpoint = None

    return dataclasses.replace(
        state,
        lifecycle=StationLifecycle.OWNED_BY_IPHONE,
        # Accepted mutating write => advance the revision (see _request_handoff
        # / _stop). The synthesized/preserved durable checkpoint above keeps
        # its own recorded station_revision (the revision of the entry it
        # checkpoints), mirroring _accept_interruption's resume_checkpoint.
        station_revision=state.station_revision + 1,
        phone_epoch=action.epoch,
        checkpoint=durable_checkpoint,
        # The Mac releases controller ownership on handoff: combined with
        # claim_lease's monotonic-epoch enforcement (FIX 1), a stale Mac
        # cannot reclaim at an old epoch, and apply()'s central lease gate
        # rejects any further Mac action outright (no lease to match).
        lease=None,
        events=(
            *state.events,
            StationEvent(
                kind="checkpoint",
                timestamp=action.now,
                entry_id=state.active_entry.entry_id if state.active_entry else None,
                message=f"handoff acknowledged: mac stopped, {action.phone_device_id} now owns at epoch {action.epoch}",
            ),
        ),
    )


def _stop(state: StationState, action: Stop) -> StationState:
    """any state -> stopped (durable checkpoint retained)."""
    return dataclasses.replace(
        state,
        lifecycle=StationLifecycle.STOPPED,
        # Accepted mutating write => advance the revision (see _request_handoff).
        # Without this, a controller restart would reload the pre-Stop state
        # and resume playing after the station was durably stopped.
        station_revision=state.station_revision + 1,
        events=(
            *state.events,
            StationEvent(
                kind="checkpoint",
                timestamp=action.now,
                entry_id=state.active_entry.entry_id if state.active_entry else None,
                message="stopped",
            ),
        ),
    )
