"""Textual snapshot tests for the A.4.5 station-state indicators.

Uses ``pytest-textual-snapshot``'s ``snap_compare`` fixture (added as a dev
dependency for this task -- see ``pyproject.toml``'s ``[tool.uv]
override-dependencies`` note for why ``syrupy`` is overridden to 5.x: the
pinned ``syrupy==4.8.0`` transitively requires ``pytest<9.0.0``, incompatible
with this project's ``pytest>=9.0.2``).

``snap_compare`` drives the app through its OWN ``App.run(headless=True,
...)`` entry point (``textual._doc.take_svg_screenshot``), which calls
``asyncio.run()`` internally -- NOT ``app.run_test()``. These tests MUST stay
plain sync functions (never ``async def`` / ``@pytest.mark.asyncio``), or
``asyncio.run()`` raises "cannot be called from a running event loop".

Reuses the same fakes/builders as ``test_tui.py`` (``FakeController``,
``FakeAdapter``, ``FakeRouteMonitor``, ``FakeWeatherMonitor``, ``_make_app``,
``_station_entry``, ``_bulletin_entry``) rather than reimplementing them --
``tests`` is a proper package (``tests/__init__.py``), so this is a plain
module import, not test-collection duplication.

Terminal size is pinned (not the fixture's (80, 24) default) so the new
indicator lines are never clipped and the SVG baseline stays stable across
runs/machines.

Baselines live under ``tests/__snapshots__/test_tui_snapshots/`` (the
plugin's default ``SingleFileSnapshotExtension`` location) and are
regenerated with ``pytest tests/test_tui_snapshots.py --snapshot-update``.
"""

from __future__ import annotations

import pytest

from tests.test_tui import (
    SAFE_WINDOW,
    FakeAdapter,
    FakeController,
    FakeRouteMonitor,
    FakeWeatherMonitor,
    _bulletin_entry,
    _make_app,
    _station_entry,
)
from wilted.station_runtime import RouteChangeEvent

pytestmark = pytest.mark.usefixtures("stub_audio_modules")

# Wide/tall enough that the title/kind/playback-bar/interrupt-banner/
# source-health/status-line stack never wraps or clips.
_SNAPSHOT_TERMINAL_SIZE = (100, 32)


def test_bulletin_interrupting_indicator(snap_compare, tmp_path):
    """Snapshot: interrupt banner (admission reason) + source-health line
    while a weather bulletin is actively interrupting playback."""
    entry = _station_entry(1, safe_interruption=SAFE_WINDOW)
    controller = FakeController()
    adapter = FakeAdapter()
    weather_monitor = FakeWeatherMonitor()
    weather_monitor.fake_health = "healthy"
    weather_monitor.last_success_at = "2026-07-11T00:00:00Z"
    bulletin = _bulletin_entry()
    app = _make_app(
        entries=[entry],
        controller=controller,
        adapter=adapter,
        weather_monitor=weather_monitor,
        latency_log_path=tmp_path / "latency.jsonl",
    )

    async def _drive(pilot):
        await pilot.app.workers.wait_for_complete()
        pilot.app._start_playback(entry)
        weather_monitor.fire(bulletin)
        adapter._offset_ms = 11_000  # inside SAFE_WINDOW's [10_000, 12_000]
        pilot.app._update_timer()
        await pilot.pause()

    assert snap_compare(app, run_before=_drive, terminal_size=_SNAPSHOT_TERMINAL_SIZE)


def test_route_interrupted_no_output_indicator(snap_compare):
    """Snapshot: interrupt banner (no-output + device name) + source-health
    line while route-interrupted (A.3.3 no-output floor)."""
    entry = _station_entry(1)
    controller = FakeController()
    adapter = FakeAdapter()
    route_monitor = FakeRouteMonitor()
    app = _make_app(entries=[entry], controller=controller, adapter=adapter, route_monitor=route_monitor)

    async def _drive(pilot):
        await pilot.app.workers.wait_for_complete()
        pilot.app._start_playback(entry)
        route_monitor.fire(RouteChangeEvent(device_id=42, device_name="AirPods Pro"))
        await pilot.pause()

    assert snap_compare(app, run_before=_drive, terminal_size=_SNAPSHOT_TERMINAL_SIZE)


def test_backend_indicator_daemon(snap_compare):
    """Snapshot: the daemon-only indicator shows click-to-warm."""
    entry = _station_entry(1)
    app = _make_app(entries=[entry])

    async def _drive(pilot):
        await pilot.app.workers.wait_for_complete()
        await pilot.pause()

    assert snap_compare(app, run_before=_drive, terminal_size=_SNAPSHOT_TERMINAL_SIZE)
