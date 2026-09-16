"""``StationController`` — the single-writer command queue (SR-1).

``wilted.station.reducer.apply`` is a pure, lease-checked function: it takes
a state, an action, and the caller's believed lease, and returns a new state
(accepted or rejected). Nothing in the reducer or in
``wilted.station_runtime.lease``/``wilted.station_runtime.store`` decides
*who* is allowed to call ``apply`` concurrently, or serializes concurrent
callers against each other — that is this module's entire job.

``StationController`` is the ONLY code in this codebase that calls
``reducer.apply`` (SR-1: single-writer). Producers (the audio worker, the
interruption monitor, the TUI, phone-handoff handling, ...) never hold a
lease or call ``apply`` themselves; they call :meth:`StationController.submit`,
which enqueues their action and returns a ``Future`` for the result. A single
background "drain" thread is the sole consumer of that queue and the sole
caller of :func:`wilted.station.reducer.apply` — see ``_apply_and_persist``,
which is the one and only call site.

Threading model:

- One ``queue.Queue`` holds ``(action, future)`` pairs submitted by any
  number of producer threads. ``queue.Queue`` is already internally
  thread-safe, so concurrent producers do not need any additional
  synchronization to enqueue.
- One drain thread pulls items off that queue strictly one at a time (a
  blocking ``queue.get`` with a short timeout so a stop request is noticed
  promptly) and is the only thread that ever reads-modifies-writes
  ``self._state`` or calls ``reducer.apply``. Because there is exactly one
  such thread, and it never reads/writes ``self._state`` concurrently with
  itself, apply-and-swap is inherently serialized without needing a lock
  *for the drain thread's own logic*.
- A ``threading.Lock`` (``self._state_lock``) still guards every read *and*
  write of ``self._state`` so that ``current_state()`` (called from any
  producer thread) never observes a half-updated snapshot torn between the
  drain thread's read and its write. Since ``StationState`` is a frozen
  dataclass, the snapshot handed out is safe to use after the lock is
  released.

Persist-on-accepted / CAS-failure / restore-on-start / lease-loss handling
(spec ambiguities resolved here, see also the module's docstring notes
inline):

- An accepted mutation (``station_revision`` advanced) is persisted via
  ``store.persist_state(new_state, expected_revision=<pre-apply revision>)``.
  If that CAS succeeds, the drain thread swaps ``self._state`` to
  ``new_state`` and resolves the future with ``accepted=True``.
- If the CAS returns False, that is a genuine anomaly: this controller holds
  the ``ControllerLeaseManager``'s flock for the entire life of its lease, so
  no other *live* controller can be writing concurrently. A False CAS result
  therefore means either (a) something wrote to the store out-of-band
  (bypassing this controller entirely), or (b) this controller's own
  in-memory view of the current revision has drifted from disk for some
  other reason. Rather than silently discarding the mutation or advancing
  in-memory state that disagrees with disk, the controller does NOT advance
  ``self._state``, flips into a terminal "lost" mode (``self._lost`` — every
  subsequent ``submit``/queued item fails fast with a clear
  ``StationControllerLostError``), and resolves the future for the mutation
  that hit the CAS failure with that same exception. An optional
  ``on_loss`` callback (constructor arg) is invoked once so a host process
  can alert/restart.
- A rejection (``station_revision`` unchanged — stale revision, non-owner
  lease, expired entry, etc.) still swaps ``self._state`` to the reducer's
  returned state, because the rejection path appends a diagnostic event to
  the in-memory event log and callers may want to see it via
  ``current_state()``. It is deliberately NOT persisted: the bounded event
  log is explicitly documented (``wilted.station.models.StationEvent``) as
  ephemeral/in-memory-only, not a durable record, so persisting on every
  rejection would write to disk for something the model says is not
  durable.
- Restore-on-start: ``ControllerLeaseManager.acquire()`` already does a
  single ``persist_state`` call that both claims the lease AND preserves any
  prior ``active_entry``/``checkpoint``/etc. from a previous (possibly
  crashed) session. ``start()`` simply re-``load_state()``s after
  ``acquire()`` succeeds and adopts whatever comes back as the initial
  in-memory state — no separate restore logic is needed here, since the
  lease manager already did the preserving CAS.
"""

from __future__ import annotations

import concurrent.futures
import logging
import queue
import threading
from dataclasses import dataclass
from typing import TYPE_CHECKING

from wilted.station.reducer import StationState, apply
from wilted.station_runtime.lease import ControllerLeaseManager
from wilted.station_runtime.store import JsonStationStore

if TYPE_CHECKING:
    from collections.abc import Callable

    from wilted.station.models import ControllerLease
    from wilted.station.reducer import Action

logger = logging.getLogger(__name__)

_QUEUE_POLL_TIMEOUT_SECONDS = 0.25
"""How long the drain thread blocks on an empty queue before re-checking the
stop flag. Keeps ``stop()`` responsive without a busy-loop."""

_JOIN_TIMEOUT_SECONDS = 5.0
"""Bound on how long ``stop()`` waits for the drain thread to exit."""


class StationControllerError(RuntimeError):
    """Base class for :class:`StationController` usage/state errors."""


class StationControllerLostError(StationControllerError):
    """Raised for any submit made after the controller has entered "lost" mode.

    Entered when a persisted-accepted mutation's compare-and-set write
    unexpectedly fails (see module docstring) — since this controller holds
    the lease's flock for its entire lifetime, that CAS failure means the
    on-disk state has diverged from this controller's view for a reason
    outside the single-writer model this class assumes, and it is not safe
    to keep issuing further mutations against a stale base.
    """


@dataclass(frozen=True, slots=True)
class SubmitResult:
    """Outcome of one submitted action, as resolved on its ``Future``.

    Attributes:
        accepted: True iff the reducer's ``station_revision`` advanced (an
            accepted mutation) as opposed to a rejection (revision
            unchanged, a diagnostic event appended instead).
        revision: ``state.station_revision`` after this action was applied
            (for a rejection, this equals the pre-apply revision).
        state: The resulting ``StationState`` snapshot (frozen, safe to
            retain).
    """

    accepted: bool
    revision: int
    state: StationState


class StationController:
    """The sole writer: single-drain-thread command queue in front of ``reducer.apply``.

    Usage::

        controller = StationController(holder_id="mac-controller-pid123")
        controller.start()
        try:
            result = controller.submit_and_wait(StartPlayback(entry=entry))
        finally:
            controller.stop()

    Or as a context manager::

        with StationController(holder_id="mac-controller-pid123") as controller:
            controller.submit(Checkpoint(...))
    """

    def __init__(
        self,
        holder_id: str,
        *,
        store: JsonStationStore | None = None,
        lease_manager: ControllerLeaseManager | None = None,
    ) -> None:
        self._store = store if store is not None else JsonStationStore()
        self._lease_manager = (
            lease_manager if lease_manager is not None else ControllerLeaseManager(holder_id, store=self._store)
        )

        self._lease: ControllerLease | None = None
        self._state: StationState = StationState()
        self._state_lock = threading.Lock()

        self._queue: queue.Queue[tuple[Action, concurrent.futures.Future[SubmitResult]] | None] = queue.Queue()
        self._drain_thread: threading.Thread | None = None
        self._stop_event = threading.Event()
        # Serializes submit()'s stopped-check-then-enqueue against stop()'s
        # stopped-flag-set, so a producer can never enqueue an action onto a
        # queue whose drain thread has already been told to exit (which would
        # orphan that action's future forever). The drain thread never takes
        # this lock, so it cannot deadlock against a producer or against stop().
        self._lifecycle_lock = threading.Lock()
        self._started = False
        self._stopped = False

        self._lost = False
        self._lost_exc: BaseException | None = None
        self._on_loss: Callable[[BaseException], None] | None = None

    # ------------------------------------------------------------------
    # Lifecycle
    # ------------------------------------------------------------------

    def start(self, *, on_loss: Callable[[BaseException], None] | None = None) -> None:
        """Acquire the controller lease, restore prior state, and start the drain thread.

        Args:
            on_loss: Optional callback invoked (once) with the triggering
                exception if the drain thread ever enters "lost" mode (see
                module docstring). Invoked from the drain thread itself, so
                it should be quick/non-blocking.

        Raises:
            LeaseHeldError: Another live controller already holds the lease
                (propagated unchanged from ``ControllerLeaseManager.acquire``).
            RuntimeError: This controller has already been started.
        """
        if self._started:
            raise RuntimeError("StationController.start() called twice on the same instance")

        self._on_loss = on_loss

        # Raises LeaseHeldError on failure -- let it propagate. On success,
        # the store now holds a state whose `.lease` is ours and whose
        # active_entry/checkpoint from any prior session are preserved
        # (ControllerLeaseManager.acquire's single persist_state call).
        self._lease = self._lease_manager.acquire()

        # Everything after acquire() must either fully succeed or release the
        # lease before propagating -- otherwise a failure here (a corrupt
        # store on restore, an OS thread-spawn failure) would leave the flock
        # held with `_started` still False, so stop() would no-op and the
        # lease would be leaked, locking out every future controller until
        # this process dies.
        try:
            restored = self._store.load_state()
            if restored is None:
                # Shouldn't happen after a successful acquire() (which always
                # persists a state), but guard defensively rather than crash.
                restored = StationState(lease=self._lease)
            with self._state_lock:
                self._state = restored

            self._stop_event.clear()
            self._drain_thread = threading.Thread(
                target=self._drain_loop,
                name=f"station-controller-drain-{self._lease_manager.holder_id}",
                daemon=True,
            )
            self._drain_thread.start()
        except BaseException:
            self._lease_manager.release()
            self._lease = None
            self._drain_thread = None
            raise

        # Only now is the controller fully live. Set this last so a failed
        # start() leaves `_started` False (stop() no-ops, start() is
        # retryable). Nothing can be enqueued until this is True (submit()
        # requires it under _lifecycle_lock), so the drain thread only ever
        # sees an empty queue in the window before this assignment.
        self._started = True

    def stop(self) -> None:
        """Signal the drain thread to stop, join it, then release the lease.

        Safe to call if :meth:`start` was never called (no-op) or if already
        stopped (no-op).
        """
        # Flip _stopped under the lock that submit() also holds, so any
        # producer racing this stop() either enqueues fully *before* we mark
        # stopped (its future is then drained/failed by the loop below) or
        # observes _stopped=True and raises without enqueuing -- it can never
        # slip an action onto the queue after the drain thread has exited.
        with self._lifecycle_lock:
            if not self._started or self._stopped:
                return
            self._stopped = True
            self._stop_event.set()

        # Wake the drain thread promptly even if it's blocked on an empty
        # queue.get(); the sentinel is a no-op for the thread but guarantees
        # it re-checks the stop event without waiting out the poll timeout.
        self._queue.put(None)
        if self._drain_thread is not None:
            self._drain_thread.join(timeout=_JOIN_TIMEOUT_SECONDS)
            if self._drain_thread.is_alive():
                # The drain thread did not exit within the bound -- almost
                # certainly wedged inside a hung persist_state or on_loss
                # callback. Releasing the lease now would drop the flock while
                # that thread may still be mid-write to the store, opening the
                # exact double-writer/split-brain window the flock exists to
                # prevent. Keep the lease held (it is reclaimable once this
                # process dies; the drain thread is a daemon and won't block
                # exit) and surface the anomaly loudly instead.
                logger.error(
                    "StationController.stop(): drain thread %r did not exit within %.1fs; "
                    "NOT releasing the lease to avoid a split-brain double-writer window. "
                    "The lease stays held until this process exits.",
                    self._drain_thread.name,
                    _JOIN_TIMEOUT_SECONDS,
                )
                return

        self._lease_manager.release()

    def __enter__(self) -> StationController:
        self.start()
        return self

    def __exit__(self, *exc_info: object) -> None:
        self.stop()

    # ------------------------------------------------------------------
    # Submit API
    # ------------------------------------------------------------------

    def submit(self, action: Action) -> concurrent.futures.Future[SubmitResult]:
        """Thread-safe: enqueue ``action`` for the drain thread and return its ``Future``.

        Producers that care about the outcome call ``.result(timeout=...)``
        on the returned future; fire-and-forget callers may ignore it
        entirely. If ``reducer.apply`` itself raises (a genuine programmer
        error, e.g. an unrecognized action type), that exception is set on
        the future rather than raised here.

        Raises:
            RuntimeError: Called before :meth:`start` or after :meth:`stop`.
        """
        # Hold _lifecycle_lock across the check *and* the enqueue so this can
        # never interleave with stop() flipping _stopped: either we enqueue
        # before stop() marks stopped (the drain loop then fails our future
        # with a clear "stopping" error), or we see _stopped and raise here.
        # A returned future is therefore guaranteed to eventually resolve.
        with self._lifecycle_lock:
            if not self._started:
                raise RuntimeError("StationController.submit() called before start()")
            if self._stopped:
                raise RuntimeError("StationController.submit() called after stop()")

            future: concurrent.futures.Future[SubmitResult] = concurrent.futures.Future()
            self._queue.put((action, future))
            return future

    def submit_and_wait(self, action: Action, timeout: float | None = None) -> SubmitResult:
        """Convenience: :meth:`submit` then block for its result.

        Args:
            timeout: Forwarded to ``Future.result()``; None waits indefinitely.
        """
        return self.submit(action).result(timeout=timeout)

    # ------------------------------------------------------------------
    # State access
    # ------------------------------------------------------------------

    def current_state(self) -> StationState:
        """Return the current in-memory state snapshot (frozen, safe to retain)."""
        with self._state_lock:
            return self._state

    @property
    def held_epoch(self) -> int | None:
        """The lease epoch this controller currently believes it holds, or None."""
        return self._lease.epoch if self._lease is not None else None

    @property
    def is_running(self) -> bool:
        """True between a successful :meth:`start` and :meth:`stop`."""
        return self._started and not self._stopped

    @property
    def is_lost(self) -> bool:
        """True once a CAS anomaly has put the drain loop into terminal "lost" mode."""
        return self._lost

    # ------------------------------------------------------------------
    # Drain loop -- the ONLY caller of reducer.apply (SR-1)
    # ------------------------------------------------------------------

    def _drain_loop(self) -> None:
        while True:
            if self._stop_event.is_set() and self._queue.empty():
                return
            try:
                item = self._queue.get(timeout=_QUEUE_POLL_TIMEOUT_SECONDS)
            except queue.Empty:
                continue

            if item is None:
                # Wake-up sentinel from stop(); if we're stopping, drain
                # whatever else is already queued (below) then exit on the
                # next loop iteration's stop-check; otherwise ignore it.
                if self._stop_event.is_set() and self._queue.empty():
                    return
                continue

            action, future = item

            if self._stop_event.is_set():
                # Stopping: discard remaining queued mutations rather than
                # apply them against a controller that's shutting down --
                # fail their futures with a clear, unambiguous error.
                if not future.cancelled():
                    future.set_exception(StationControllerError("StationController is stopping; action discarded"))
                continue

            if self._lost:
                if not future.cancelled():
                    future.set_exception(self._lost_exc or StationControllerLostError("StationController is lost"))
                continue

            try:
                result = self._apply_and_persist(action)
            except BaseException as exc:  # noqa: BLE001 - surface programmer errors on the future, not the thread
                logger.exception("StationController: reducer.apply raised for action %r", action)
                if not future.cancelled():
                    future.set_exception(exc)
                continue

            if not future.cancelled():
                future.set_result(result)

    def _apply_and_persist(self, action: Action) -> SubmitResult:
        """The single call site for ``reducer.apply`` (SR-1). Only ever called
        from the drain thread, one action at a time.

        Persists accepted mutations (CAS against the pre-apply revision);
        leaves rejections unpersisted (see module docstring). On an
        unexpected CAS failure for an accepted mutation, flips the
        controller into terminal "lost" mode and raises
        ``StationControllerLostError`` instead of returning normally, so
        that failure path can never accidentally be treated as success by a
        caller that forgets to check ``accepted``.
        """
        with self._state_lock:
            base_state = self._state

        new_state = apply(base_state, action, self._lease)
        accepted = new_state.station_revision != base_state.station_revision

        if not accepted:
            # Rejection: adopt the reducer's returned state (carries the
            # diagnostic event) but do not persist -- the event log is
            # explicitly ephemeral/in-memory only.
            with self._state_lock:
                self._state = new_state
            return SubmitResult(accepted=False, revision=new_state.station_revision, state=new_state)

        persisted = self._store.persist_state(new_state, expected_revision=base_state.station_revision)
        if not persisted:
            exc = StationControllerLostError(
                "StationController: persist_state lost its compare-and-set even though this "
                "controller holds the lease's flock for its whole lifetime -- on-disk state was "
                "written out-of-band, or this controller's in-memory revision has otherwise "
                "diverged from disk. Refusing to advance in-memory state; the controller is now "
                "lost and will reject further submits."
            )
            logger.error(str(exc))
            self._lost = True
            self._lost_exc = exc
            if self._on_loss is not None:
                try:
                    self._on_loss(exc)
                except Exception:
                    logger.exception("StationController: on_loss callback raised")
            raise exc

        with self._state_lock:
            self._state = new_state
        return SubmitResult(accepted=True, revision=new_state.station_revision, state=new_state)


__all__ = [
    "StationController",
    "StationControllerError",
    "StationControllerLostError",
    "SubmitResult",
]
