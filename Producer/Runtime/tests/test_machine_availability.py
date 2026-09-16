"""Tests for ``MachineAvailabilityMonitor`` (Milestone 1 of the
resource-aware smart processing queue feature).

``FakeBackend`` stands in for ``_DarwinAvailabilityBackend`` -- real
``os.getloadavg``/``pmset``/``ioreg`` are NEVER invoked by the
``TestMachineAvailabilityMonitor``/``TestParseAcPower``/``TestParseIdleSeconds``
sections below. The ``TestDarwinAvailabilityBackendSample`` and
``TestWrapperEntrypoint`` sections DO exercise the real
``_DarwinAvailabilityBackend`` class (and, transitively, the real ``main()``
CLI wrapper), but only against the actual probe output captured live on this
Mac (see ``machine_availability.py``'s module docstring) via mocked
``subprocess.run``/``os.getloadavg``/``os.cpu_count`` -- never a live
subprocess call.
"""

from __future__ import annotations

import runpy
import subprocess
import sys
from unittest.mock import patch

import pytest

from wilted.station_runtime.machine_availability import (
    AvailabilityBackend,
    MachineAvailability,
    MachineAvailabilityMonitor,
    _DarwinAvailabilityBackend,
    _parse_ac_power,
    _parse_idle_seconds,
)

pytestmark = pytest.mark.integration


# ---------------------------------------------------------------------------
# Real probe output, captured live on this Mac -- see the module docstring.
# ---------------------------------------------------------------------------

_REAL_PMSET_AC_OUTPUT = (
    "Now drawing from 'AC Power'\n -InternalBattery-0 (id=23003235)\t22%; charging; 20:00 remaining present: true\n"
)

_REAL_IOREG_OUTPUT = '    | | |   "HIDIdleTime" = 55957935791\n'


# ---------------------------------------------------------------------------
# Fakes
# ---------------------------------------------------------------------------


class FakeBackend(AvailabilityBackend):
    """Returns successive canned samples (or raises) on each call; records calls."""

    def __init__(self, *samples: MachineAvailability, raise_exc: Exception | None = None) -> None:
        self._samples = list(samples)
        self._raise_exc = raise_exc
        self.calls = 0

    def sample(self) -> MachineAvailability:
        self.calls += 1
        if self._raise_exc is not None:
            raise self._raise_exc
        if self._samples:
            return self._samples.pop(0)
        return _sample()


def _sample(**overrides: object) -> MachineAvailability:
    defaults = dict(
        load_per_core=0.5,
        on_ac_power=True,
        user_idle_seconds=42.0,
        sampled_at="2026-07-25T12:00:00Z",
        ok=True,
    )
    defaults.update(overrides)
    return MachineAvailability(**defaults)


# ---------------------------------------------------------------------------
# MachineAvailability interpretation via MachineAvailabilityMonitor + fake backend
# ---------------------------------------------------------------------------


class TestMachineAvailabilityMonitor:
    def test_sample_once_returns_the_backend_sample_and_records_it(self):
        sample = _sample()
        backend = FakeBackend(sample)
        monitor = MachineAvailabilityMonitor(backend=backend)

        result = monitor.sample_once()

        assert result == sample
        assert monitor.last_sample == sample
        assert backend.calls == 1

    def test_health_is_unknown_before_first_sample(self):
        monitor = MachineAvailabilityMonitor(backend=FakeBackend())

        assert monitor.health() == "unknown"
        assert monitor.last_sample is None
        assert monitor.last_error is None

    def test_health_is_healthy_after_ok_sample(self):
        monitor = MachineAvailabilityMonitor(backend=FakeBackend(_sample(ok=True)))

        monitor.sample_once()

        assert monitor.health() == "healthy"
        assert monitor.last_error is None

    def test_health_is_failed_after_not_ok_sample(self):
        failed = _sample(ok=False, load_per_core=0.0, on_ac_power=False, user_idle_seconds=None)
        monitor = MachineAvailabilityMonitor(backend=FakeBackend(failed))

        monitor.sample_once()

        assert monitor.health() == "failed"
        assert monitor.last_error is not None

    def test_backend_raising_unexpectedly_is_caught_and_never_raises(self):
        """A backend that raises OUTSIDE its own typed ok=False contract must
        still never crash the caller (INV-6) -- folded into a synthetic
        failed sample instead."""
        backend = FakeBackend(raise_exc=RuntimeError("kaboom"))
        monitor = MachineAvailabilityMonitor(backend=backend)

        result = monitor.sample_once()  # must not raise

        assert result.ok is False
        assert monitor.health() == "failed"
        assert monitor.last_error is not None

    def test_successive_samples_overwrite_last_sample(self):
        first = _sample(load_per_core=0.1)
        second = _sample(load_per_core=0.9)
        backend = FakeBackend(first, second)
        monitor = MachineAvailabilityMonitor(backend=backend)

        monitor.sample_once()
        monitor.sample_once()

        assert monitor.last_sample == second
        assert backend.calls == 2

    def test_default_construction_uses_the_real_darwin_backend(self):
        """No backend override -> the real ``_DarwinAvailabilityBackend`` is
        wired, mirroring how ``WeatherMonitor``/``RouteMonitor`` default to
        their real production backend."""
        monitor = MachineAvailabilityMonitor()

        assert isinstance(monitor._backend, _DarwinAvailabilityBackend)


# ---------------------------------------------------------------------------
# Pure parsing helpers, exercised against the REAL pmset/ioreg output
# captured live on this Mac (see the module docstring)
# ---------------------------------------------------------------------------


class TestParseAcPower:
    def test_parses_real_captured_ac_power_output(self):
        assert _parse_ac_power(_REAL_PMSET_AC_OUTPUT) is True

    def test_parses_battery_power(self):
        """Not independently re-probed on battery (this Mac was plugged in
        during the mandatory probe), but the branch only depends on which of
        the two fixed, documented ``pmset`` marker strings appears."""
        battery_output = (
            "Now drawing from 'Battery Power'\n"
            " -InternalBattery-0 (id=23003235)\t76%; discharging; 3:12 remaining present: true\n"
        )
        assert _parse_ac_power(battery_output) is False

    def test_missing_drawing_from_line_raises_value_error(self):
        with pytest.raises(ValueError, match="Now drawing from"):
            _parse_ac_power("garbage output\n")


class TestParseIdleSeconds:
    def test_parses_real_captured_idle_output(self):
        assert _parse_idle_seconds(_REAL_IOREG_OUTPUT) == pytest.approx(55.957935791)

    def test_missing_hididletime_raises_value_error(self):
        with pytest.raises(ValueError, match="HIDIdleTime"):
            _parse_idle_seconds("no idle time here\n")

    def test_zero_idle_time_parses_to_zero_seconds(self):
        assert _parse_idle_seconds('"HIDIdleTime" = 0') == 0.0


# ---------------------------------------------------------------------------
# _DarwinAvailabilityBackend.sample() -- real code path, mocked subprocess/os
# ---------------------------------------------------------------------------


def _fake_run(cmd, **kwargs):
    if cmd[0] == "pmset":
        return subprocess.CompletedProcess(cmd, 0, stdout=_REAL_PMSET_AC_OUTPUT, stderr="")
    if cmd[0] == "ioreg":
        return subprocess.CompletedProcess(cmd, 0, stdout=_REAL_IOREG_OUTPUT, stderr="")
    raise AssertionError(f"unexpected subprocess command: {cmd!r}")


class TestDarwinAvailabilityBackendSample:
    def test_sample_ok_combines_all_three_probes(self, monkeypatch):
        monkeypatch.setattr("os.getloadavg", lambda: (2.0, 1.5, 1.0))
        monkeypatch.setattr("os.cpu_count", lambda: 4)
        monkeypatch.setattr("subprocess.run", _fake_run)
        backend = _DarwinAvailabilityBackend()

        sample = backend.sample()

        assert sample.ok is True
        assert sample.load_per_core == pytest.approx(0.5)  # 2.0 / 4
        assert sample.on_ac_power is True
        assert sample.user_idle_seconds == pytest.approx(55.957935791)
        assert sample.sampled_at

    def test_cpu_count_none_falls_back_to_one(self, monkeypatch):
        """``os.cpu_count()`` can return ``None`` (undetermined) -- must not
        raise a ZeroDivisionError or crash the sample."""
        monkeypatch.setattr("os.getloadavg", lambda: (3.0, 1.0, 1.0))
        monkeypatch.setattr("os.cpu_count", lambda: None)
        monkeypatch.setattr("subprocess.run", _fake_run)
        backend = _DarwinAvailabilityBackend()

        sample = backend.sample()

        assert sample.ok is True
        assert sample.load_per_core == pytest.approx(3.0)  # 3.0 / (None or 1)

    def test_non_darwin_platform_returns_failed_sample(self, monkeypatch):
        monkeypatch.setattr(sys, "platform", "linux")
        backend = _DarwinAvailabilityBackend()

        sample = backend.sample()

        assert sample.ok is False
        assert sample.load_per_core == 0.0
        assert sample.on_ac_power is False
        assert sample.user_idle_seconds is None

    def test_getloadavg_failure_returns_failed_sample(self, monkeypatch):
        def raising_getloadavg():
            raise OSError("not supported")

        monkeypatch.setattr("os.getloadavg", raising_getloadavg)
        backend = _DarwinAvailabilityBackend()

        sample = backend.sample()  # must not raise

        assert sample.ok is False

    def test_pmset_timeout_returns_failed_sample(self, monkeypatch):
        monkeypatch.setattr("os.getloadavg", lambda: (1.0, 1.0, 1.0))
        monkeypatch.setattr("os.cpu_count", lambda: 4)

        def timing_out_run(cmd, **kwargs):
            raise subprocess.TimeoutExpired(cmd=cmd, timeout=2.0)

        monkeypatch.setattr("subprocess.run", timing_out_run)
        backend = _DarwinAvailabilityBackend()

        sample = backend.sample()  # must not raise

        assert sample.ok is False

    def test_pmset_nonzero_exit_returns_failed_sample(self, monkeypatch):
        monkeypatch.setattr("os.getloadavg", lambda: (1.0, 1.0, 1.0))
        monkeypatch.setattr("os.cpu_count", lambda: 4)

        def failing_run(cmd, **kwargs):
            if cmd[0] == "pmset":
                raise subprocess.CalledProcessError(returncode=1, cmd=cmd)
            return subprocess.CompletedProcess(cmd, 0, stdout=_REAL_IOREG_OUTPUT, stderr="")

        monkeypatch.setattr("subprocess.run", failing_run)
        backend = _DarwinAvailabilityBackend()

        sample = backend.sample()  # must not raise

        assert sample.ok is False

    def test_ioreg_parse_miss_returns_failed_sample(self, monkeypatch):
        monkeypatch.setattr("os.getloadavg", lambda: (1.0, 1.0, 1.0))
        monkeypatch.setattr("os.cpu_count", lambda: 4)

        def fake_run(cmd, **kwargs):
            if cmd[0] == "pmset":
                return subprocess.CompletedProcess(cmd, 0, stdout=_REAL_PMSET_AC_OUTPUT, stderr="")
            return subprocess.CompletedProcess(cmd, 0, stdout="no idle time field\n", stderr="")

        monkeypatch.setattr("subprocess.run", fake_run)
        backend = _DarwinAvailabilityBackend()

        sample = backend.sample()  # must not raise

        assert sample.ok is False


# ---------------------------------------------------------------------------
# Wrapper truthful-run/exit gate test (INV-6, extended -- see INVARIANTS.md)
# ---------------------------------------------------------------------------


class TestWrapperEntrypoint:
    """``python -m wilted.station_runtime.machine_availability`` must actually
    call ``main()`` and propagate a truthful exit code -- the INV-6 C1
    lesson (see ``weather_monitor``'s module docstring for the history).

    ``runpy.run_module(..., run_name="__main__")`` RE-EXECUTES the target
    module's top-level code in a fresh namespace (see
    ``test_weather_monitor.py``'s ``TestWrapperEntrypoint`` docstring for the
    empirically-verified reason), so a ``monkeypatch`` on the
    already-imported module's own attributes does NOT survive into that
    fresh re-execution. These tests instead patch the stdlib layer
    (``os.getloadavg``/``os.cpu_count``/``subprocess.run``) that the freshly
    re-executed module's real ``_DarwinAvailabilityBackend`` calls into --
    stdlib modules are NOT re-executed by ``runpy.run_module``, so a patch on
    them is visible to the fresh module. This proves the REAL production
    sample path actually ran (not a stub), with no live subprocess call.
    """

    def test_run_module_invokes_main_and_exits_zero_on_success(self, monkeypatch):
        monkeypatch.setattr("os.getloadavg", lambda: (2.0, 1.5, 1.0))
        monkeypatch.setattr("os.cpu_count", lambda: 4)
        monkeypatch.setattr("subprocess.run", _fake_run)

        with pytest.raises(SystemExit) as exc_info:
            with patch.object(sys, "argv", ["wilted-machine-availability"]):
                runpy.run_module("wilted.station_runtime.machine_availability", run_name="__main__", alter_sys=True)

        assert exc_info.value.code == 0

    def test_run_module_exits_nonzero_when_sample_fails(self, monkeypatch):
        def raising_getloadavg():
            raise OSError("not supported")

        monkeypatch.setattr("os.getloadavg", raising_getloadavg)

        with pytest.raises(SystemExit) as exc_info:
            with patch.object(sys, "argv", ["wilted-machine-availability"]):
                runpy.run_module("wilted.station_runtime.machine_availability", run_name="__main__", alter_sys=True)

        assert exc_info.value.code == 1
