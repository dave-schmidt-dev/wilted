"""``MachineAvailabilityMonitor`` — an on-demand macOS machine-availability sensor.

Milestone 1 of the "resource-aware smart processing queue" feature: wilted's
local-processing scheduler eventually wants to know whether THIS Mac has
slack — CPU headroom, AC power, an idle user — before kicking off a heavy
local job. This module ships ONLY the sensor: a single ``sample()`` call
that reads real machine state and returns a typed, non-raising snapshot. No
scheduler wiring, no cost model, no policy, no consumer yet — see the
milestone plan for what comes later.

Backend seam (mirrors ``RouteMonitor``/``RouteBackend``)
-----------------------------------------------------------
:class:`AvailabilityBackend` is a structural ``Protocol`` (like
``RouteBackend``) so :class:`MachineAvailabilityMonitor` and its tests never
need to touch real ``os.getloadavg``/``pmset``/``ioreg`` — every test injects
a fake backend. :class:`_DarwinAvailabilityBackend` is the real,
darwin-guarded implementation, exercised directly only by this module's own
probe-verified parsing tests (which mock the subprocess/os layer, never the
live commands) and by a human running ``python -m
wilted.station_runtime.machine_availability`` on real hardware.

Sample-on-demand, not a poller
--------------------------------
Unlike ``WeatherMonitor``/``RouteMonitor`` (which run a background
thread/CFRunLoop pump), this monitor has NO ``start``/``stop`` lifecycle and
NO thread: :meth:`MachineAvailabilityMonitor.sample_once` runs synchronously,
on the caller's thread, on demand. A future consumer (the scheduler, once it
exists) decides when to sample — this sensor has no opinion on cadence.

Real probe output (verified live on this Mac, 2026-07-25)
-------------------------------------------------------------
``pmset -g batt``::

    Now drawing from 'AC Power'
     -InternalBattery-0 (id=23003235)	22%; charging; 20:00 remaining present: true

AC power is on whenever the ``Now drawing from`` line contains the literal
``'AC Power'`` marker (the documented alternative is ``'Battery Power'`` —
not independently re-verified on battery here since this Mac was plugged in
during the probe, but the parse only depends on which of the two fixed
strings appears in that one line).

``ioreg -c IOHIDSystem | grep HIDIdleTime``::

        | | |   "HIDIdleTime" = 55957935791

``HIDIdleTime`` is nanoseconds since the last HID (keyboard/mouse/trackpad)
event; :func:`_parse_idle_seconds` regex-searches the FULL ``ioreg -c
IOHIDSystem`` output (no shell pipe needed — ``grep`` was only used above to
keep the manual probe readable) and divides by 1e9 to get seconds.

INV-6 / INV-11
----------------
Every subprocess call is timeout-bounded (``_SUBPROCESS_TIMEOUT_SECONDS``);
ANY failure — non-darwin platform, a missing/erroring/timed-out subprocess,
or output that doesn't match the expected shape — is caught and folded into
a typed ``MachineAvailability(ok=False, ...)`` with a WARNING log, never a
raw traceback (INV-6). All three probes (load average, AC power, idle time)
are local, synchronous, sub-100ms operations bounded by a 2s worst-case
timeout — no background thread, no silent multi-second wait (INV-11). This
module's ``if __name__ == "__main__":`` guard actually calls :func:`main`,
which propagates a truthful exit code (INV-6's C1 lesson, same discipline as
``weather_monitor.main`` — see that module's docstring for the history).
Unlike ``weather_monitor``, this is a non-speech, non-station-mutating
management entrypoint, so it does NOT probe the speech daemon or acquire a
``StationController`` lease (INV-6: "non-speech CLI/management entrypoints
stay daemon-independent").
"""

from __future__ import annotations

import argparse
import dataclasses
import logging
import os
import re
import subprocess
import sys
from typing import Protocol

from wilted.station.models import now_utc_z

logger = logging.getLogger(__name__)

_SUBPROCESS_TIMEOUT_SECONDS = 2.0
"""Per-probe timeout bound (INV-11) — ``pmset``/``ioreg`` are local, fast
commands; 2s is a generous ceiling that still fails fast on a genuinely
wedged subprocess rather than hanging the caller."""

_AC_POWER_LINE_PREFIX = "Now drawing from"
_AC_POWER_MARKER = "'AC Power'"

_HIDIDLE_TIME_PATTERN = re.compile(r'"HIDIdleTime"\s*=\s*(\d+)')
_NANOSECONDS_PER_SECOND = 1_000_000_000


# ---------------------------------------------------------------------------
# Value type
# ---------------------------------------------------------------------------


@dataclasses.dataclass(frozen=True, slots=True)
class MachineAvailability:
    """One point-in-time snapshot of this machine's availability for local processing work.

    Attributes:
        load_per_core: 1-minute load average divided by CPU core count
            (``os.getloadavg()[0] / (os.cpu_count() or 1)``) — a
            core-count-normalized load figure so a fixed threshold means the
            same thing on a 4-core and a 16-core Mac. ``0.0`` (not
            meaningful) when ``ok`` is ``False``.
        on_ac_power: Whether ``pmset -g batt`` reports the Mac is drawing
            from AC power (vs. battery). ``False`` (not meaningful) when
            ``ok`` is ``False``.
        user_idle_seconds: Seconds since the last HID (keyboard/mouse/
            trackpad) event, per ``ioreg -c IOHIDSystem``'s ``HIDIdleTime``
            (nanoseconds, converted here). ``None`` when ``ok`` is ``False``.
        sampled_at: UTC 'Z' timestamp of when this sample was taken.
        ok: ``False`` if ANY probe failed (non-darwin platform, a subprocess
            error/timeout, or unparseable output) — the other fields are
            then placeholder values, never partial/best-effort real data, so
            a caller can trust ``ok`` as the single source of truth for
            "is this sample usable."
    """

    load_per_core: float
    on_ac_power: bool
    user_idle_seconds: float | None
    sampled_at: str
    ok: bool


class AvailabilityBackend(Protocol):
    """The seam :class:`MachineAvailabilityMonitor` depends on. Structural,
    not nominal — mirrors ``RouteBackend``. A backend need not be
    darwin-specific; only :class:`_DarwinAvailabilityBackend` is."""

    def sample(self) -> MachineAvailability: ...


# ---------------------------------------------------------------------------
# Pure parsing helpers — exercised directly against the real probe output
# captured in the module docstring, with no subprocess involved.
# ---------------------------------------------------------------------------


def _parse_ac_power(pmset_output: str) -> bool:
    """Parse ``pmset -g batt`` stdout for the "Now drawing from" line.

    Raises:
        ValueError: No "Now drawing from" line is present — a genuinely
            unexpected ``pmset`` output shape, not a normal outcome.
    """
    for line in pmset_output.splitlines():
        stripped = line.strip()
        if stripped.startswith(_AC_POWER_LINE_PREFIX):
            return _AC_POWER_MARKER in stripped
    raise ValueError(f"pmset -g batt output missing a {_AC_POWER_LINE_PREFIX!r} line: {pmset_output!r}")


def _parse_idle_seconds(ioreg_output: str) -> float:
    """Parse ``ioreg -c IOHIDSystem`` stdout for ``HIDIdleTime`` (nanoseconds -> seconds).

    Raises:
        ValueError: No ``HIDIdleTime`` entry is present.
    """
    match = _HIDIDLE_TIME_PATTERN.search(ioreg_output)
    if match is None:
        raise ValueError(f"ioreg -c IOHIDSystem output missing HIDIdleTime: {ioreg_output!r}")
    return int(match.group(1)) / _NANOSECONDS_PER_SECOND


def _failed_sample(sampled_at: str) -> MachineAvailability:
    return MachineAvailability(
        load_per_core=0.0, on_ac_power=False, user_idle_seconds=None, sampled_at=sampled_at, ok=False
    )


# ---------------------------------------------------------------------------
# Real backend — darwin only
# ---------------------------------------------------------------------------


class _DarwinAvailabilityBackend:
    """Real ``AvailabilityBackend``: stdlib ``os.getloadavg``/``os.cpu_count``
    plus timeout-bounded ``pmset``/``ioreg`` subprocess probes.

    Every probe is wrapped so a failure (non-darwin, subprocess error,
    timeout, or a parse miss) returns a typed ``ok=False`` sample rather than
    raising (INV-6) — see the module docstring. Exercised directly only by
    this module's own tests (which mock the subprocess/os layer, never the
    live commands, per the fake-backend testing rule the rest of this
    module's tests follow) and by a human running this module's ``main()``
    on real hardware.
    """

    def sample(self) -> MachineAvailability:
        now = now_utc_z()

        if sys.platform != "darwin":
            logger.warning("_DarwinAvailabilityBackend.sample(): unsupported platform %r (darwin-only)", sys.platform)
            return _failed_sample(now)

        try:
            load_per_core = os.getloadavg()[0] / (os.cpu_count() or 1)
        except OSError as exc:
            logger.warning("_DarwinAvailabilityBackend.sample(): os.getloadavg() failed: %r", exc)
            return _failed_sample(now)

        try:
            on_ac_power = self._probe_ac_power()
        except Exception as exc:  # noqa: BLE001 - a sample must never propagate (INV-6)
            logger.warning("_DarwinAvailabilityBackend.sample(): pmset probe failed: %r", exc)
            return _failed_sample(now)

        try:
            user_idle_seconds = self._probe_idle_seconds()
        except Exception as exc:  # noqa: BLE001 - a sample must never propagate (INV-6)
            logger.warning("_DarwinAvailabilityBackend.sample(): ioreg probe failed: %r", exc)
            return _failed_sample(now)

        return MachineAvailability(
            load_per_core=load_per_core,
            on_ac_power=on_ac_power,
            user_idle_seconds=user_idle_seconds,
            sampled_at=now,
            ok=True,
        )

    def _probe_ac_power(self) -> bool:
        result = subprocess.run(
            ["pmset", "-g", "batt"],
            capture_output=True,
            text=True,
            timeout=_SUBPROCESS_TIMEOUT_SECONDS,
            check=True,
        )
        return _parse_ac_power(result.stdout)

    def _probe_idle_seconds(self) -> float:
        result = subprocess.run(
            ["ioreg", "-c", "IOHIDSystem"],
            capture_output=True,
            text=True,
            timeout=_SUBPROCESS_TIMEOUT_SECONDS,
            check=True,
        )
        return _parse_idle_seconds(result.stdout)


# ---------------------------------------------------------------------------
# MachineAvailabilityMonitor — thin sample-on-demand wrapper
# ---------------------------------------------------------------------------


class MachineAvailabilityMonitor:
    """Sample-on-demand wrapper around an :class:`AvailabilityBackend`.

    Unlike ``WeatherMonitor``/``RouteMonitor`` there is no ``start``/``stop``
    lifecycle and no background thread — see the module docstring. Every
    call to :meth:`sample_once` is synchronous and runs on the caller's
    thread; a future scheduler decides cadence, not this class.
    """

    def __init__(self, *, backend: AvailabilityBackend | None = None) -> None:
        self._backend: AvailabilityBackend = backend if backend is not None else _DarwinAvailabilityBackend()
        self._last_sample: MachineAvailability | None = None
        self._last_error: str | None = None

    def sample_once(self) -> MachineAvailability:
        """Take one sample. Never raises (INV-6) — a backend that raises
        unexpectedly (beyond its own typed ``ok=False`` contract) is caught
        here and folded into a synthetic failed sample too."""
        try:
            sample = self._backend.sample()
        except Exception as exc:  # noqa: BLE001 - a sample must never propagate (INV-6)
            logger.warning("MachineAvailabilityMonitor: backend.sample() raised unexpectedly: %r", exc)
            sample = _failed_sample(now_utc_z())

        self._last_sample = sample
        self._last_error = None if sample.ok else f"sample reported ok=False: {sample!r}"
        return sample

    @property
    def last_sample(self) -> MachineAvailability | None:
        """The most recent sample taken, or ``None`` before the first :meth:`sample_once`."""
        return self._last_sample

    @property
    def last_error(self) -> str | None:
        """A description of the most recent failed sample, or ``None`` if the
        last sample (if any) succeeded."""
        return self._last_error

    def health(self) -> str:
        """``unknown`` before any sample, else ``healthy``/``failed`` per the
        last sample's ``ok`` flag. No staleness concept — sample-on-demand
        has no interval to be stale relative to."""
        if self._last_sample is None:
            return "unknown"
        return "healthy" if self._last_sample.ok else "failed"


# ---------------------------------------------------------------------------
# CLI wrapper entrypoint
# ---------------------------------------------------------------------------


def main(argv: list[str] | None = None) -> int:
    """One-shot sample-and-report CLI entrypoint.

    Non-speech, non-station-mutating (INV-6: "non-speech CLI/management
    entrypoints stay daemon-independent") — no speech-daemon probe, no
    ``StationController`` lease, unlike ``weather_monitor.main``.

    Returns:
        0 if the sample succeeded (``ok=True``). 1 otherwise. Never returns
        0 without a real :meth:`MachineAvailabilityMonitor.sample_once` call
        having actually happened (the INV-6 C1 lesson).
    """
    from wilted.log import setup_logging

    parser = argparse.ArgumentParser(
        prog="wilted-machine-availability",
        description="One-shot machine-availability sample (load/AC-power/idle-time).",
    )
    parser.add_argument("--debug", action="store_true")
    args = parser.parse_args(argv)

    setup_logging(debug=args.debug)

    monitor = MachineAvailabilityMonitor()
    sample = monitor.sample_once()
    logger.info(
        "wilted-machine-availability: sample complete, health=%s, sample=%r", monitor.health(), monitor.last_sample
    )
    if not sample.ok:
        logger.error("wilted-machine-availability: sample failed: %s", monitor.last_error)
        return 1
    return 0


# INV-6: without this guard, `python -m wilted.station_runtime.machine_availability`
# would import the module, define main(), and exit 0 having sampled NOTHING --
# the C1 bug class this pattern exists to prevent (see weather_monitor's
# module docstring for the history). This makes the module actually invoke
# main() and propagate its real exit status.
if __name__ == "__main__":
    sys.exit(main())


__all__ = [
    "AvailabilityBackend",
    "MachineAvailability",
    "MachineAvailabilityMonitor",
    "main",
]
