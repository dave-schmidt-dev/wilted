"""Unit tests for ``RouteMonitor`` — the CoreAudio default-output-device
listener wrapper (Plan A task A.3.3).

``FakeBackend`` stands in for ``_CoreAudioBackend``, mirroring the role
``FakeAdapter``/``FakeController`` play in ``test_tui.py`` for the rest of
the station runtime. Real CoreAudio is NEVER invoked here — the ctypes
backend is exercised only on real hardware (Plan A task A.5).
"""

from __future__ import annotations

import pytest

from wilted.station_runtime.route_monitor import RouteBackend, RouteChangeEvent, RouteMonitor

pytestmark = pytest.mark.unit


class FakeBackend(RouteBackend):
    """Records register()/unregister() calls; ``fire()`` simulates a device change.

    Deliberately does NOT drop its stored callback reference on
    ``unregister()`` — that lets ``test_post_stop_events_do_not_dispatch``
    prove the post-stop guard lives in ``RouteMonitor`` itself, not merely
    in whatever a well-behaved backend happens to do.
    """

    def __init__(self) -> None:
        self.register_calls = 0
        self.unregister_calls = 0
        self._callback = None

    def register(self, callback) -> None:
        self.register_calls += 1
        self._callback = callback

    def unregister(self) -> None:
        self.unregister_calls += 1

    def current_device(self) -> RouteChangeEvent:
        return RouteChangeEvent(device_id=1, device_name="Fake Output")

    def fire(self, event: RouteChangeEvent) -> None:
        """Test helper: invoke whatever callback is currently registered."""
        assert self._callback is not None, "fire() called before register()"
        self._callback(event)


def test_start_registers_the_backend():
    backend = FakeBackend()
    monitor = RouteMonitor(on_route_change=lambda event: None, backend=backend)

    monitor.start()

    assert backend.register_calls == 1
    assert backend.unregister_calls == 0


def test_backend_event_dispatches_a_route_change_event():
    backend = FakeBackend()
    received: list[RouteChangeEvent] = []
    monitor = RouteMonitor(on_route_change=received.append, backend=backend)
    monitor.start()

    event = RouteChangeEvent(device_id=42, device_name="USB Speakers")
    backend.fire(event)

    assert received == [event]


def test_double_start_raises_runtime_error():
    backend = FakeBackend()
    monitor = RouteMonitor(on_route_change=lambda event: None, backend=backend)
    monitor.start()

    with pytest.raises(RuntimeError):
        monitor.start()

    # The second (rejected) start() must not have re-registered the backend.
    assert backend.register_calls == 1


def test_stop_unregisters_the_backend():
    backend = FakeBackend()
    monitor = RouteMonitor(on_route_change=lambda event: None, backend=backend)
    monitor.start()

    monitor.stop()

    assert backend.unregister_calls == 1


def test_stop_is_idempotent():
    backend = FakeBackend()
    monitor = RouteMonitor(on_route_change=lambda event: None, backend=backend)
    monitor.start()

    monitor.stop()
    monitor.stop()

    assert backend.unregister_calls == 1


def test_stop_without_start_is_a_noop():
    backend = FakeBackend()
    monitor = RouteMonitor(on_route_change=lambda event: None, backend=backend)

    monitor.stop()

    assert backend.unregister_calls == 0


def test_post_stop_events_do_not_dispatch():
    """A backend event delivered after ``stop()`` must never reach
    ``on_route_change`` — ``RouteMonitor._dispatch`` guards on its own
    ``_running`` flag rather than trusting the backend to have fully torn
    down delivery (``FakeBackend`` deliberately keeps its stale callback
    reference around, per its docstring, so this test actually exercises
    that guard)."""
    backend = FakeBackend()
    received: list[RouteChangeEvent] = []
    monitor = RouteMonitor(on_route_change=received.append, backend=backend)
    monitor.start()
    monitor.stop()

    backend.fire(RouteChangeEvent(device_id=7, device_name="Stale Device"))

    assert received == []


def test_start_after_stop_registers_again():
    """A monitor is reusable: stop() then start() again should re-register,
    not raise (only a double-start without an intervening stop raises)."""
    backend = FakeBackend()
    received: list[RouteChangeEvent] = []
    monitor = RouteMonitor(on_route_change=received.append, backend=backend)
    monitor.start()
    monitor.stop()

    monitor.start()
    backend.fire(RouteChangeEvent(device_id=9, device_name="Reconnected"))

    assert backend.register_calls == 2
    assert received == [RouteChangeEvent(device_id=9, device_name="Reconnected")]
