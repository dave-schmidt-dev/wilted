"""``CheckpointPoller`` — the timer that drives periodic playback checkpoints.

``StationController`` is the single writer (SR-1 / INV-7): every mutation of
station state flows through ``StationController.submit`` and, from there,
through the one drain thread that calls ``reducer.apply``. Playback progress
is no exception. In particular, the audio thread/backend must never write a
checkpoint directly — it only exposes a read-only ``current_offset_ms()``.

This module is the poller that closes that loop: on a fixed interval, it
reads the current offset from a playback adapter and submits a
``wilted.station.reducer.Checkpoint`` action to the controller. It is a
*producer* like any other (the TUI, the interruption monitor, phone-handoff
handling) — it never touches the reducer or the controller's internal state
directly, only ``controller.submit(...)``.

Checkpointing is fire-and-forget from this poller's point of view: a
rejected checkpoint (stale ``expected_revision`` because some other writer
advanced the station in the meantime, or a station that has since left
``PLAYING``) is an expected, benign outcome. The next tick simply reads a
fresh ``current_state()`` and tries again with the fresh revision, so no
tick needs to retry or escalate a rejection.
"""

from __future__ import annotations

import logging
import threading
from typing import TYPE_CHECKING, Protocol

from wilted.station.reducer import Checkpoint, StationLifecycle

if TYPE_CHECKING:
    import concurrent.futures

    from wilted.station.reducer import StationState
    from wilted.station_runtime.controller import SubmitResult

logger = logging.getLogger(__name__)

_JOIN_TIMEOUT_SECONDS = 5.0
"""Bound on how long :meth:`CheckpointPoller.stop` waits for the poll thread
to exit, following the same convention as ``StationController``'s
``_JOIN_TIMEOUT_SECONDS``."""


class _ControllerLike(Protocol):
    """The subset of ``StationController`` this poller depends on.

    Structural (``typing.Protocol``), not nominal: any object exposing these
    two methods works, so tests can inject a fake without inheriting from
    the real ``StationController``.
    """

    def submit(self, action: object) -> concurrent.futures.Future[SubmitResult]: ...

    def current_state(self) -> StationState: ...


class _AdapterLike(Protocol):
    """The subset of a playback adapter this poller depends on.

    Structural, mirroring ``_ControllerLike`` above — any object exposing a
    zero-arg ``current_offset_ms() -> int`` works, so tests never need to
    import ``MacPlaybackAdapter`` or ``AudioEngine``.
    """

    def current_offset_ms(self) -> int: ...


class CheckpointPoller:
    """Periodically checkpoints playback progress via ``controller.submit``.

    Runs one background daemon thread that wakes up every ``interval_s``
    seconds and performs a single checkpoint attempt (:meth:`_tick`). The
    first tick happens after one full interval has elapsed, not immediately
    at start: a checkpoint at t=0 would be redundant with the
    ``StartPlayback`` action that (by construction) must have just run to
    put the station into ``PLAYING`` in the first place.

    Double-start policy: calling :meth:`start` twice while already running
    raises ``RuntimeError``, matching ``StationController.start()``'s own
    convention of raising on double-start rather than silently no-op'ing.
    """

    def __init__(
        self,
        controller: _ControllerLike,
        adapter: _AdapterLike,
        *,
        interval_s: float = 30.0,
        writer_device: str = "mac",
    ) -> None:
        self._controller = controller
        self._adapter = adapter
        self._interval_s = interval_s
        self._writer_device = writer_device

        # Monotonic mutation-id counter. A single poller instance is normally
        # driven by its own single poll thread, but _tick() may also be
        # called directly/concurrently by tests or callers, so this needs to
        # be safe under concurrent calls without adding real contention: a
        # plain int guarded by a small lock is simple and obviously correct
        # (an itertools.count() would also work here, since its next() is
        # atomic in CPython, but an explicit lock does not rely on that
        # implementation detail).
        self._counter_lock = threading.Lock()
        self._counter = 0

        self._stop_event = threading.Event()
        self._thread: threading.Thread | None = None
        self._running = False

    def _next_mutation_id(self) -> str:
        with self._counter_lock:
            n = self._counter
            self._counter += 1
        return f"{self._writer_device}-ckpt-{n}"

    def _tick(self) -> None:
        """Perform one checkpoint attempt. Never raises.

        Skips (no submit) when the station is not currently playing an
        entry. Otherwise reads the adapter's offset, builds a ``Checkpoint``
        action with a fresh, distinct ``mutation_id``, and submits it
        fire-and-forget. A rejection (stale revision, station no longer
        playing by the time the drain thread applies it, etc.) is expected
        and benign -- the next tick self-corrects against a fresh
        ``current_state()`` -- so this only logs at DEBUG rather than
        treating it as an error.
        """
        try:
            state = self._controller.current_state()

            if state.lifecycle is not StationLifecycle.PLAYING or state.active_entry is None:
                logger.debug(
                    "CheckpointPoller: skipping tick, station is not playing an active entry "
                    "(lifecycle=%r, active_entry=%r)",
                    state.lifecycle,
                    state.active_entry,
                )
                return

            offset_ms = self._adapter.current_offset_ms()
            mutation_id = self._next_mutation_id()
            action = Checkpoint(
                mutation_id=mutation_id,
                expected_revision=state.station_revision,
                media_offset_ms=offset_ms,
                state_label="playing",
                writer_device=self._writer_device,
            )

            future = self._controller.submit(action)

            def _log_if_rejected(fut: concurrent.futures.Future[SubmitResult]) -> None:
                try:
                    result = fut.result()
                except Exception as exc:  # noqa: BLE001 - a done-callback must never raise
                    logger.debug("CheckpointPoller: checkpoint %r future raised: %r", mutation_id, exc)
                    return
                if not result.accepted:
                    logger.debug("CheckpointPoller: checkpoint %r was rejected by the reducer", mutation_id)

            future.add_done_callback(_log_if_rejected)
        except Exception as exc:  # noqa: BLE001 - a tick must never propagate; the next tick self-corrects
            logger.debug("CheckpointPoller: tick failed, will retry next interval: %r", exc)

    def start(self) -> None:
        """Start the background polling thread.

        Raises:
            RuntimeError: This poller is already running.
        """
        if self._running:
            raise RuntimeError("CheckpointPoller.start() called twice on the same instance")

        self._stop_event.clear()
        self._thread = threading.Thread(
            target=self._poll_loop,
            name=f"checkpoint-poller-{self._writer_device}",
            daemon=True,
        )
        self._running = True
        self._thread.start()

    def _poll_loop(self) -> None:
        # wait() returns False on timeout (interval elapsed, tick) and True
        # once stop() sets the event (exit promptly, no tick). Waiting first
        # means the first tick happens after one full interval, not at t=0.
        while not self._stop_event.wait(self._interval_s):
            self._tick()

    def stop(self) -> None:
        """Stop the background polling thread. Safe to call more than once.

        No-op if :meth:`start` was never called or if already stopped.
        Joins the poll thread with a bounded timeout, logging an error
        (rather than raising) if it does not exit in time.
        """
        if not self._running:
            return
        self._running = False

        self._stop_event.set()
        if self._thread is not None:
            self._thread.join(timeout=_JOIN_TIMEOUT_SECONDS)
            if self._thread.is_alive():
                logger.error(
                    "CheckpointPoller.stop(): poll thread %r did not exit within %.1fs",
                    self._thread.name,
                    _JOIN_TIMEOUT_SECONDS,
                )
            self._thread = None


__all__ = ["CheckpointPoller"]
