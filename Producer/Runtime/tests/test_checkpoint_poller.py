"""Tests for ``wilted.station_runtime.checkpoint_poller.CheckpointPoller``.

Covers: submitting exactly one well-formed ``Checkpoint`` per tick while
playing, monotonic/distinct mutation ids across ticks, skipping ticks when
not playing or with no active entry, swallowing a ``controller.submit``
exception without propagating it, and clean start/stop thread lifecycle
(bounded polling, no further submits after ``stop()``, idempotent ``stop()``).

Everything here is fakes/no real I/O -- no controller, no store, no audio
engine -- so this is a unit-tier suite.
"""

from __future__ import annotations

import concurrent.futures
import dataclasses
import threading
import time

import pytest

from wilted.station.models import (
    FinalizationState,
    MediaDescriptor,
    SafeInterruptionMap,
    StationEntry,
)
from wilted.station.reducer import Checkpoint, StationLifecycle, StationState
from wilted.station_runtime.checkpoint_poller import CheckpointPoller

pytestmark = pytest.mark.unit


# ---------------------------------------------------------------------------
# Shared builders (mirrors tests/test_station_controller.py's patterns)
# ---------------------------------------------------------------------------


def _finalized_media(**overrides) -> MediaDescriptor:
    defaults = dict(
        sha256="a" * 64,
        byte_size=1024,
        mime_type="audio/mpeg",
        duration_ms=60_000,
        transcript_segments=(),
        safe_interruption=SafeInterruptionMap.empty(),
        byte_range_available=False,
        finalization=FinalizationState.complete(),
    )
    defaults.update(overrides)
    return MediaDescriptor(**defaults)


def _entry(entry_id="entry-1", kind="item", priority=5, expiry=None, media=None, **overrides) -> StationEntry:
    defaults = dict(
        entry_id=entry_id,
        kind=kind,
        item_id="item-1" if kind == "item" else None,
        source="feed:test",
        policy_id=None,
        priority=priority,
        expiry=expiry,
        duration_ms=60_000,
        media=media if media is not None else _finalized_media(),
    )
    defaults.update(overrides)
    return StationEntry(**defaults)


# ---------------------------------------------------------------------------
# Fakes
# ---------------------------------------------------------------------------


class _FakeController:
    """Records every submitted action; state is a settable real ``StationState``."""

    def __init__(self, state: StationState | None = None) -> None:
        self._state = state if state is not None else StationState()
        self.submitted: list[Checkpoint] = []
        self._raise_on_submit: BaseException | None = None
        self._accepted = True

    def set_state(self, state: StationState) -> None:
        self._state = state

    def raise_on_submit(self, exc: BaseException) -> None:
        self._raise_on_submit = exc

    def set_accepted(self, accepted: bool) -> None:  # noqa: FBT001 - test helper, positional bool is fine
        self._accepted = accepted

    def current_state(self) -> StationState:
        return self._state

    def submit(self, action: Checkpoint) -> concurrent.futures.Future:
        if self._raise_on_submit is not None:
            raise self._raise_on_submit

        self.submitted.append(action)

        future: concurrent.futures.Future = concurrent.futures.Future()
        result = SimpleSubmitResult(
            accepted=self._accepted,
            revision=action.expected_revision + (1 if self._accepted else 0),
            state=self._state,
        )
        future.set_result(result)
        return future


@dataclasses.dataclass(frozen=True)
class SimpleSubmitResult:
    """Minimal stand-in for ``StationController.SubmitResult``.

    ``_tick``'s done-callback only reads ``.accepted`` off the resolved
    future, so this avoids importing the real controller module entirely.
    """

    accepted: bool
    revision: int
    state: StationState


class _FakeAdapter:
    """Settable current offset; duck-types the ``current_offset_ms`` seam."""

    def __init__(self, offset_ms: int = 0) -> None:
        self._offset_ms = offset_ms

    def set_offset_ms(self, offset_ms: int) -> None:
        self._offset_ms = offset_ms

    def current_offset_ms(self) -> int:
        return self._offset_ms


def _playing_state(*, station_revision: int = 7, active_entry: StationEntry | None = None) -> StationState:
    return StationState(
        lifecycle=StationLifecycle.PLAYING,
        station_revision=station_revision,
        active_entry=active_entry if active_entry is not None else _entry(),
    )


# ---------------------------------------------------------------------------
# _tick behavior
# ---------------------------------------------------------------------------


def test_tick_while_playing_submits_one_checkpoint_with_expected_fields():
    entry = _entry(entry_id="entry-xyz")
    state = _playing_state(station_revision=42, active_entry=entry)
    controller = _FakeController(state)
    adapter = _FakeAdapter(offset_ms=12_345)

    poller = CheckpointPoller(controller, adapter, writer_device="mac-test")
    poller._tick()

    assert len(controller.submitted) == 1
    action = controller.submitted[0]
    assert action.media_offset_ms == 12_345
    assert action.expected_revision == 42
    assert action.state_label == "playing"
    assert action.writer_device == "mac-test"


def test_successive_ticks_produce_monotonic_distinct_mutation_ids():
    controller = _FakeController(_playing_state())
    adapter = _FakeAdapter(offset_ms=1_000)
    poller = CheckpointPoller(controller, adapter)

    poller._tick()
    poller._tick()
    poller._tick()

    assert len(controller.submitted) == 3
    mutation_ids = [action.mutation_id for action in controller.submitted]
    assert len(set(mutation_ids)) == 3

    # The id scheme embeds an increasing integer suffix ("<device>-ckpt-<n>");
    # confirm it is strictly increasing across ticks.
    suffixes = [int(mid.rsplit("-", 1)[-1]) for mid in mutation_ids]
    assert suffixes == sorted(suffixes)
    assert suffixes[0] < suffixes[1] < suffixes[2]


@pytest.mark.parametrize(
    "state",
    [
        pytest.param(
            StationState(lifecycle=StationLifecycle.IDLE, station_revision=1, active_entry=_entry()),
            id="not-playing-with-active-entry",
        ),
        pytest.param(
            StationState(lifecycle=StationLifecycle.PLAYING, station_revision=1, active_entry=None),
            id="playing-with-no-active-entry",
        ),
    ],
)
def test_tick_while_not_playing_or_no_active_entry_skips(state):
    controller = _FakeController(state)
    adapter = _FakeAdapter(offset_ms=999)
    poller = CheckpointPoller(controller, adapter)

    poller._tick()

    assert controller.submitted == []


def test_tick_swallows_controller_submit_exception():
    controller = _FakeController(_playing_state())
    controller.raise_on_submit(RuntimeError("boom"))
    adapter = _FakeAdapter(offset_ms=500)
    poller = CheckpointPoller(controller, adapter)

    poller._tick()  # must not raise


def test_tick_logs_but_does_not_raise_on_rejected_checkpoint():
    controller = _FakeController(_playing_state())
    controller.set_accepted(False)
    adapter = _FakeAdapter(offset_ms=500)
    poller = CheckpointPoller(controller, adapter)

    poller._tick()  # must not raise even though the future resolves to a rejection

    assert len(controller.submitted) == 1


# ---------------------------------------------------------------------------
# Thread lifecycle
# ---------------------------------------------------------------------------


def _wait_until(predicate, *, timeout_s: float = 2.0, poll_interval_s: float = 0.01) -> None:
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(poll_interval_s)
    raise AssertionError(f"condition not met within {timeout_s}s")


def test_start_ticks_at_least_once_then_stop_stops_cleanly():
    controller = _FakeController(_playing_state())
    adapter = _FakeAdapter(offset_ms=1)
    poller = CheckpointPoller(controller, adapter, interval_s=0.02)

    poller.start()
    try:
        _wait_until(lambda: len(controller.submitted) >= 1, timeout_s=2.0)
    finally:
        poller.stop()

    submitted_count_at_stop = len(controller.submitted)

    time.sleep(0.1)
    assert len(controller.submitted) == submitted_count_at_stop

    poller.stop()  # second stop() is a safe no-op


def test_start_twice_raises_runtime_error():
    controller = _FakeController(_playing_state())
    adapter = _FakeAdapter()
    poller = CheckpointPoller(controller, adapter, interval_s=10.0)

    poller.start()
    try:
        with pytest.raises(RuntimeError):
            poller.start()
    finally:
        poller.stop()


def test_stop_without_start_is_a_safe_noop():
    controller = _FakeController(_playing_state())
    adapter = _FakeAdapter()
    poller = CheckpointPoller(controller, adapter)

    poller.stop()  # must not raise


def test_tick_is_safe_when_called_concurrently():
    """_tick may be called directly/concurrently by callers other than the
    poll thread; the mutation-id counter must stay unique under that."""
    controller = _FakeController(_playing_state())
    adapter = _FakeAdapter(offset_ms=1)
    poller = CheckpointPoller(controller, adapter)

    threads = [threading.Thread(target=poller._tick) for _ in range(8)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(timeout=5.0)

    mutation_ids = [action.mutation_id for action in controller.submitted]
    assert len(mutation_ids) == 8
    assert len(set(mutation_ids)) == 8
