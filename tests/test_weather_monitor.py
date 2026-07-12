"""Integration tests for ``wilted.station_runtime.weather_monitor`` (Plan A tasks 4.2 + 4.3).

Covers: combined zone+county single-request coverage, the two-tier
escalation-aware dedup (exact-repeat guard + per-area escalation bar,
including the reset-on-clear behavior), pre-generation happening off the
interrupt path (synth before handoff, never from inside a reducer/interrupt
callback), the ``on_bulletin_ready`` handoff seam (Task 4.3 — this monitor no
longer submits ``AcceptInterruption`` itself; see ``tests/test_tui.py`` for
the safe-boundary-aware submission that now lives in the TUI), heartbeat/
health surfacing, per-item/per-poll failure isolation (INV-6 spirit), the
start/stop/double-start lifecycle discipline mirroring ``CheckpointPoller``,
and the INV-6-extended wrapper truthful-run/exit gate test.

Everything here is fixture-driven: ``fetch``/``synth`` are always fakes, and
the module's real ``_default_fetch_alerts`` is only ever reached via the
wrapper gate tests below, which intercept it at the ``urllib.request.urlopen``
layer (never a live NWS call) — see those tests' docstrings for why that
interception point, rather than monkeypatching the module's own attributes,
is required for a ``runpy``-driven ``__main__`` gate test to actually work.
"""

from __future__ import annotations

import json
import runpy
import sys
import threading
import time
from unittest.mock import patch

import pytest

from wilted.station.models import FinalizationState, MediaDescriptor, SafeInterruptionMap, StationEntry
from wilted.station_runtime import media_store
from wilted.station_runtime.weather_monitor import (
    DEFAULT_COUNTY,
    DEFAULT_ZONE,
    BulletinAudio,
    WeatherMonitor,
    _default_fetch_alerts,
    _default_synth_bulletin,
    build_production_monitor,
    make_trigger_file_fetch,
)

pytestmark = pytest.mark.integration


# ---------------------------------------------------------------------------
# Shared builders (mirrors tests/test_checkpoint_poller.py's patterns)
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


def _alert_feature(
    *,
    alert_id="id-1",
    event="Tornado Warning",
    area_desc="Northwest Prince William, VA",
    severity="Severe",
    status="Actual",
    message_type="Alert",
    updated="2026-07-11T12:00:00+00:00",
    headline="Tornado Warning for Northwest Prince William",
    description="A tornado warning is in effect.",
    instruction="Take shelter now.",
    expires="2026-07-11T13:00:00-04:00",
) -> dict:
    """Build one NWS-shaped GeoJSON alert feature."""
    return {
        "id": f"https://api.weather.gov/alerts/urn:oid:2.49.0.1.840.0.{alert_id}",
        "properties": {
            "id": alert_id,
            "event": event,
            "areaDesc": area_desc,
            "severity": severity,
            "status": status,
            "messageType": message_type,
            "sent": updated,
            "headline": headline,
            "description": description,
            "instruction": instruction,
            "expires": expires,
        },
    }


def _feature_collection(*features: dict) -> dict:
    return {"type": "FeatureCollection", "features": list(features)}


# ---------------------------------------------------------------------------
# Fakes
# ---------------------------------------------------------------------------


class _FixtureFetch:
    """Returns successive canned responses (or raises) on each call; records calls."""

    def __init__(self, *responses: dict | Exception) -> None:
        self._responses = list(responses)
        self.calls: list[tuple[str, str, str]] = []

    def __call__(self, zone: str, county: str, user_agent: str) -> dict:
        self.calls.append((zone, county, user_agent))
        if not self._responses:
            return _feature_collection()
        response = self._responses.pop(0)
        if isinstance(response, Exception):
            raise response
        return response


def _fake_synth(*, calls: list | None = None, order: list | None = None) -> callable:
    """Build a synth fixture; ``calls`` records invocations, ``order`` (shared
    with a fetch/handoff spy) records cross-call ordering."""

    def synth(text: str) -> BulletinAudio:
        if calls is not None:
            calls.append(text)
        if order is not None:
            order.append("synth")
        return BulletinAudio(audio_bytes=b"RIFF-fake-wav-bytes", duration_ms=4_200)

    return synth


class _BulletinRecorder:
    """``on_bulletin_ready`` fixture: records every handed-off bulletin, in order."""

    def __init__(self, *, order: list | None = None, raise_on_call: Exception | None = None) -> None:
        self.received: list[StationEntry] = []
        self._order = order
        self._raise_on_call = raise_on_call

    def __call__(self, bulletin: StationEntry) -> None:
        if self._order is not None:
            self._order.append("handoff")
        if self._raise_on_call is not None:
            raise self._raise_on_call
        self.received.append(bulletin)


def _monitor(
    *,
    fetch=None,
    synth=None,
    on_bulletin_ready=None,
    zone=DEFAULT_ZONE,
    county=DEFAULT_COUNTY,
    interval_s=30.0,
) -> WeatherMonitor:
    return WeatherMonitor(
        fetch=fetch if fetch is not None else _FixtureFetch(_feature_collection()),
        synth=synth if synth is not None else _fake_synth(),
        on_bulletin_ready=on_bulletin_ready,
        zone=zone,
        county=county,
        interval_s=interval_s,
    )


# ---------------------------------------------------------------------------
# Combined zone+county single-request coverage
# ---------------------------------------------------------------------------


class TestCombinedRequest:
    def test_poll_once_fetches_zone_and_county_in_one_combined_call(self):
        fetch = _FixtureFetch(_feature_collection())
        monitor = _monitor(fetch=fetch)

        monitor.poll_once()

        assert len(fetch.calls) == 1
        zone, county, user_agent = fetch.calls[0]
        assert zone == DEFAULT_ZONE
        assert county == DEFAULT_COUNTY
        assert user_agent  # descriptive UA is passed through, non-empty

    def test_alerts_for_zone_and_county_both_admit_from_one_response(self):
        zone_alert = _alert_feature(alert_id="zone-1", area_desc="Northwest Prince William, VA")
        county_alert = _alert_feature(alert_id="county-1", area_desc="Prince William County, VA")
        fetch = _FixtureFetch(_feature_collection(zone_alert, county_alert))
        recorder = _BulletinRecorder()
        monitor = _monitor(fetch=fetch, on_bulletin_ready=recorder)

        monitor.poll_once()

        assert len(fetch.calls) == 1  # both covered by the ONE combined poll
        assert len(recorder.received) == 2
        received_ids = {bulletin.entry_id for bulletin in recorder.received}
        assert received_ids == {"wx-zone-1", "wx-county-1"}


# ---------------------------------------------------------------------------
# Escalation-aware dedup (two-tier)
# ---------------------------------------------------------------------------


class TestDedupAndEscalation:
    def test_first_qualification_admits(self):
        fetch = _FixtureFetch(_feature_collection(_alert_feature()))
        recorder = _BulletinRecorder()
        monitor = _monitor(fetch=fetch, on_bulletin_ready=recorder)

        monitor.poll_once()

        assert len(recorder.received) == 1

    def test_identical_repeat_is_deduped_tier1(self):
        """The same still-active alert (unchanged id/severity/content) is
        re-served by NWS on every poll until it clears -- must dedup."""
        alert = _alert_feature()
        fetch = _FixtureFetch(_feature_collection(alert), _feature_collection(alert))
        recorder = _BulletinRecorder()
        monitor = _monitor(fetch=fetch, on_bulletin_ready=recorder)

        monitor.poll_once()
        monitor.poll_once()

        assert len(recorder.received) == 1

    def test_new_message_same_severity_is_deduped_tier2(self):
        """A genuine reissue (new id/content) at the SAME severity must not
        re-qualify -- only an escalation does."""
        first = _alert_feature(alert_id="id-1", severity="Severe", description="Initial description.")
        reissued = _alert_feature(alert_id="id-2", severity="Severe", description="Updated wording, same severity.")
        fetch = _FixtureFetch(_feature_collection(first), _feature_collection(reissued))
        recorder = _BulletinRecorder()
        monitor = _monitor(fetch=fetch, on_bulletin_ready=recorder)

        monitor.poll_once()
        monitor.poll_once()

        assert len(recorder.received) == 1
        assert recorder.received[0].entry_id == "wx-id-1"

    def test_escalation_to_higher_severity_requalifies(self):
        first = _alert_feature(alert_id="id-1", severity="Moderate")
        escalated = _alert_feature(alert_id="id-2", severity="Extreme")
        fetch = _FixtureFetch(_feature_collection(first), _feature_collection(escalated))
        recorder = _BulletinRecorder()
        monitor = _monitor(fetch=fetch, on_bulletin_ready=recorder)

        monitor.poll_once()
        monitor.poll_once()

        assert len(recorder.received) == 2
        assert [b.entry_id for b in recorder.received] == ["wx-id-1", "wx-id-2"]

    def test_deescalation_does_not_requalify(self):
        first = _alert_feature(alert_id="id-1", severity="Severe")
        deescalated = _alert_feature(alert_id="id-2", severity="Minor")
        fetch = _FixtureFetch(_feature_collection(first), _feature_collection(deescalated))
        recorder = _BulletinRecorder()
        monitor = _monitor(fetch=fetch, on_bulletin_ready=recorder)

        monitor.poll_once()
        monitor.poll_once()

        assert len(recorder.received) == 1

    def test_area_state_resets_after_alert_clears_allowing_lower_severity_later(self):
        """Once an alert for an area clears (absent from a poll's combined
        response), the escalation bar for that area resets -- a later,
        unrelated alert at even a low severity must be able to qualify."""
        severe = _alert_feature(alert_id="id-1", area_desc="Area A", severity="Severe")
        # Poll 2: nothing active for "Area A" (alert cleared).
        cleared = _feature_collection()
        minor_new = _alert_feature(alert_id="id-2", area_desc="Area A", severity="Minor")
        fetch = _FixtureFetch(_feature_collection(severe), cleared, _feature_collection(minor_new))
        recorder = _BulletinRecorder()
        monitor = _monitor(fetch=fetch, on_bulletin_ready=recorder)

        monitor.poll_once()  # qualifies at Severe
        monitor.poll_once()  # clears -> area state reset
        monitor.poll_once()  # new Minor alert -> should qualify again

        assert len(recorder.received) == 2
        assert [b.entry_id for b in recorder.received] == ["wx-id-1", "wx-id-2"]

    def test_distinct_areas_tracked_independently(self):
        area_a = _alert_feature(alert_id="a-1", area_desc="Area A", severity="Minor")
        area_b = _alert_feature(alert_id="b-1", area_desc="Area B", severity="Minor")
        fetch = _FixtureFetch(_feature_collection(area_a, area_b))
        recorder = _BulletinRecorder()
        monitor = _monitor(fetch=fetch, on_bulletin_ready=recorder)

        monitor.poll_once()

        assert len(recorder.received) == 2


# ---------------------------------------------------------------------------
# Pre-generation off the interrupt path
# ---------------------------------------------------------------------------


class TestPreGeneration:
    def test_synth_runs_before_handoff_on_qualification(self):
        order: list[str] = []

        def synth(text: str) -> BulletinAudio:
            order.append("synth")
            return BulletinAudio(audio_bytes=b"fake-wav", duration_ms=1000)

        fetch = _FixtureFetch(_feature_collection(_alert_feature()))
        recorder = _BulletinRecorder(order=order)
        monitor = _monitor(fetch=fetch, synth=synth, on_bulletin_ready=recorder)

        monitor.poll_once()

        assert order == ["synth", "handoff"]

    def test_bulletin_media_is_playable_and_published(self, tmp_path):
        fetch = _FixtureFetch(_feature_collection(_alert_feature()))
        recorder = _BulletinRecorder()
        monitor = _monitor(fetch=fetch, on_bulletin_ready=recorder)

        monitor.poll_once()

        assert len(recorder.received) == 1
        bulletin = recorder.received[0]
        assert bulletin.kind == "bulletin"
        assert bulletin.item_id is None
        assert bulletin.media.is_playable
        assert bulletin.media.byte_size > 0
        assert bulletin.duration_ms == 4_200

        published_path = media_store.path_for(bulletin.media.sha256)
        assert published_path is not None
        assert published_path.read_bytes() == b"RIFF-fake-wav-bytes"

        owners = media_store.get_owners(bulletin.media.sha256)
        assert any(o["kind"] == "bulletin" and o["entry_id"] == bulletin.entry_id for o in owners)

    def test_synth_failure_skips_handoff_without_raising(self):
        def failing_synth(text: str) -> BulletinAudio:
            raise RuntimeError("model unavailable")

        fetch = _FixtureFetch(_feature_collection(_alert_feature()))
        recorder = _BulletinRecorder()
        monitor = _monitor(fetch=fetch, synth=failing_synth, on_bulletin_ready=recorder)

        monitor.poll_once()  # must not raise

        assert recorder.received == []


# ---------------------------------------------------------------------------
# on_bulletin_ready handoff seam (Task 4.3)
# ---------------------------------------------------------------------------


class TestBulletinReadyHandoff:
    def test_bulletin_shape_and_priority(self):
        """The constructed StationEntry's shape -- source/priority/kind --
        stays the monitor's responsibility even though submission moved to
        the TUI (Task 4.3)."""
        fetch = _FixtureFetch(_feature_collection(_alert_feature(severity="Extreme")))
        recorder = _BulletinRecorder()
        monitor = _monitor(fetch=fetch, on_bulletin_ready=recorder)

        monitor.poll_once()

        bulletin = recorder.received[0]
        assert bulletin.source == "monitor:nws-alerts"
        assert bulletin.priority == 0  # Extreme -> most urgent

    def test_no_consumer_wired_bulletin_is_dropped_without_raising(self):
        """The default ``on_bulletin_ready=None`` (the standalone one-shot
        CLI wrapper's situation, per the module docstring) must never crash
        the poll -- a qualifying bulletin is simply logged and dropped."""
        fetch = _FixtureFetch(_feature_collection(_alert_feature()))
        monitor = _monitor(fetch=fetch)  # on_bulletin_ready defaults to None

        monitor.poll_once()  # must not raise

    def test_callback_exception_is_caught_and_does_not_crash_the_poll(self):
        fetch = _FixtureFetch(_feature_collection(_alert_feature()))
        recorder = _BulletinRecorder(raise_on_call=RuntimeError("consumer exploded"))
        monitor = _monitor(fetch=fetch, on_bulletin_ready=recorder)

        monitor.poll_once()  # must not raise
        assert monitor.health() == "healthy"  # the poll itself still succeeded

    def test_two_qualifications_hand_off_in_order(self):
        first = _alert_feature(alert_id="id-1", area_desc="Area A", severity="Minor")
        second = _alert_feature(alert_id="id-2", area_desc="Area B", severity="Minor")
        fetch = _FixtureFetch(_feature_collection(first, second))
        recorder = _BulletinRecorder()
        monitor = _monitor(fetch=fetch, on_bulletin_ready=recorder)

        monitor.poll_once()

        assert [b.entry_id for b in recorder.received] == ["wx-id-1", "wx-id-2"]


# ---------------------------------------------------------------------------
# Failure isolation (INV-6 spirit) + health/heartbeat
# ---------------------------------------------------------------------------


class TestFailureIsolationAndHealth:
    def test_health_is_unknown_before_first_poll(self):
        monitor = _monitor()
        assert monitor.health() == "unknown"

    def test_health_is_healthy_after_successful_poll(self):
        monitor = _monitor()
        monitor.poll_once()
        assert monitor.health() == "healthy"
        assert monitor.last_success_at is not None
        assert monitor.last_error is None

    def test_fetch_failure_never_raises_and_marks_degraded_then_failed(self):
        fetch = _FixtureFetch(RuntimeError("network down"))
        monitor = _monitor(fetch=fetch)

        monitor.poll_once()  # must not raise
        assert monitor.health() == "degraded"
        assert monitor.consecutive_failures == 1
        assert "network down" in monitor.last_error

        monitor._fetch = _FixtureFetch(RuntimeError("still down"), RuntimeError("still down"))
        monitor.poll_once()
        monitor.poll_once()
        assert monitor.health() == "failed"
        assert monitor.consecutive_failures == 3

    def test_success_after_failure_resets_consecutive_failures(self):
        fetch = _FixtureFetch(RuntimeError("blip"), _feature_collection())
        monitor = _monitor(fetch=fetch)

        monitor.poll_once()
        assert monitor.consecutive_failures == 1

        monitor.poll_once()
        assert monitor.consecutive_failures == 0
        assert monitor.health() == "healthy"

    def test_malformed_alert_feature_is_skipped_without_crashing_others(self):
        malformed = {"properties": {"event": "Missing area and id"}}
        good = _alert_feature(alert_id="good-1")
        fetch = _FixtureFetch(_feature_collection(malformed, good))
        recorder = _BulletinRecorder()
        monitor = _monitor(fetch=fetch, on_bulletin_ready=recorder)

        monitor.poll_once()  # must not raise

        assert len(recorder.received) == 1
        assert recorder.received[0].entry_id == "wx-good-1"

    def test_heartbeat_updates_even_on_failure(self):
        fetch = _FixtureFetch(RuntimeError("down"))
        monitor = _monitor(fetch=fetch)

        assert monitor.last_poll_at is None
        monitor.poll_once()
        assert monitor.last_poll_at is not None

    def test_health_is_stale_when_heartbeat_old_relative_to_interval(self):
        monitor = _monitor(interval_s=30.0)
        monitor.poll_once()

        far_future = "2099-01-01T00:00:00Z"
        assert monitor.health(now=far_future) == "stale"


# ---------------------------------------------------------------------------
# Lifecycle (mirrors test_checkpoint_poller.py's patterns)
# ---------------------------------------------------------------------------


class TestLifecycle:
    def test_interval_below_floor_raises_value_error(self):
        with pytest.raises(ValueError, match="30"):
            _monitor(interval_s=10.0)

    def _wait_until(self, predicate, *, timeout_s: float = 2.0, poll_interval_s: float = 0.01) -> None:
        deadline = time.monotonic() + timeout_s
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(poll_interval_s)
        raise AssertionError(f"condition not met within {timeout_s}s")

    def test_start_polls_immediately_then_stop_stops_cleanly(self):
        fetch = _FixtureFetch(_feature_collection())
        monitor = _monitor(fetch=fetch, interval_s=30.0)

        monitor.start()
        try:
            self._wait_until(lambda: len(fetch.calls) >= 1, timeout_s=2.0)
        finally:
            monitor.stop()

        calls_at_stop = len(fetch.calls)
        time.sleep(0.1)
        assert len(fetch.calls) == calls_at_stop  # no further ticks after stop()

        monitor.stop()  # second stop() is a safe no-op

    def test_double_start_raises_runtime_error(self):
        monitor = _monitor(interval_s=30.0)

        monitor.start()
        try:
            with pytest.raises(RuntimeError):
                monitor.start()
        finally:
            monitor.stop()

    def test_stop_without_start_is_a_safe_noop(self):
        monitor = _monitor()
        monitor.stop()  # must not raise

    def test_poll_once_is_safe_when_called_concurrently(self):
        """poll_once may be invoked directly/concurrently (tests, or a manual
        call racing the poll thread); shared per-area state must not corrupt."""
        fetch = _FixtureFetch(*[_feature_collection(_alert_feature(alert_id=f"id-{i}")) for i in range(8)])
        monitor = _monitor(fetch=fetch)

        threads = [threading.Thread(target=monitor.poll_once) for _ in range(8)]
        for t in threads:
            t.start()
        for t in threads:
            t.join(timeout=5.0)

        assert len(fetch.calls) == 8


# ---------------------------------------------------------------------------
# Wrapper truthful-run/exit gate test (INV-6, extended — see INVARIANTS.md)
# ---------------------------------------------------------------------------


class _FakeHTTPResponse:
    """Context-manager-compatible stand-in for ``http.client.HTTPResponse``."""

    def __init__(self, payload: dict) -> None:
        self._body = json.dumps(payload).encode("utf-8")

    def read(self) -> bytes:
        return self._body

    def __enter__(self) -> _FakeHTTPResponse:
        return self

    def __exit__(self, *exc_info: object) -> bool:
        return False


class TestWrapperEntrypoint:
    """`scripts/wilted-weather-monitor.sh` invokes `python -m
    wilted.station_runtime.weather_monitor`. Per the INV-6 C1 lesson
    (wilted-nightly.sh's `python -m wilted.cli` had no `__main__` guard and
    so exited 0 having run nothing every night), this module's own
    `__main__` guard must actually call main(), and main() must propagate a
    TRUTHFUL exit code -- not a hardcoded 0.

    ``runpy.run_module(..., run_name="__main__")`` RE-EXECUTES the target
    module's top-level code in a fresh namespace (verified empirically: a
    ``monkeypatch.setattr`` on the already-imported
    ``wilted.station_runtime.weather_monitor`` module object does NOT
    survive into that fresh re-execution, since it defines its own new
    ``_default_fetch_alerts`` from scratch). So these tests intercept at
    ``urllib.request.urlopen`` instead -- a stdlib module that is NOT
    re-executed by ``runpy.run_module`` (only the explicitly named target
    module is), so a patch on it is visible to the freshly re-executed
    module's real ``_default_fetch_alerts`` when it does
    ``urllib.request.urlopen(...)``. This proves the REAL production fetch
    path actually ran (not a stub), with no live NWS call. ``main()`` still
    acquires/releases a real ``StationController`` lease as a runtime-health
    smoke test (see the module docstring) even though ``WeatherMonitor``
    itself no longer takes a controller -- these tests exercise that real
    lease acquisition too, unaffected by the Task 4.3 handoff-seam change.
    """

    def test_run_module_invokes_main_and_exits_zero_on_success(self, monkeypatch):
        captured_requests = []

        def fake_urlopen(request, timeout=None):
            captured_requests.append(request)
            return _FakeHTTPResponse({"type": "FeatureCollection", "features": []})

        monkeypatch.setattr("urllib.request.urlopen", fake_urlopen)

        with pytest.raises(SystemExit) as exc_info:
            with patch.object(sys, "argv", ["wilted-weather-monitor"]):
                runpy.run_module("wilted.station_runtime.weather_monitor", run_name="__main__", alter_sys=True)

        assert exc_info.value.code == 0
        assert len(captured_requests) == 1
        # Combined single request: both UGC codes present in the ONE URL.
        assert DEFAULT_ZONE in captured_requests[0].full_url
        assert DEFAULT_COUNTY in captured_requests[0].full_url

    def test_run_module_exits_nonzero_when_poll_fails(self, monkeypatch):
        def failing_urlopen(request, timeout=None):
            raise OSError("network unreachable")

        monkeypatch.setattr("urllib.request.urlopen", failing_urlopen)

        with pytest.raises(SystemExit) as exc_info:
            with patch.object(sys, "argv", ["wilted-weather-monitor"]):
                runpy.run_module("wilted.station_runtime.weather_monitor", run_name="__main__", alter_sys=True)

        assert exc_info.value.code == 1


# ---------------------------------------------------------------------------
# build_production_monitor / make_trigger_file_fetch (A.5.1 launch wiring +
# manual speaker test hook)
# ---------------------------------------------------------------------------


class TestBuildProductionMonitor:
    def test_no_trigger_path_wires_real_fetch_and_synth(self):
        monitor = build_production_monitor()

        assert isinstance(monitor, WeatherMonitor)
        assert monitor._fetch is _default_fetch_alerts
        assert monitor._synth is _default_synth_bulletin
        # Live-NWS mode: no test trigger recorded (drives the TUI status line).
        assert monitor.test_trigger_path is None

    def test_trigger_path_swaps_in_the_trigger_file_fetch_but_keeps_real_synth(self, tmp_path):
        trigger_path = tmp_path / "trigger"

        monitor = build_production_monitor(trigger_path=trigger_path)

        assert monitor._fetch is not _default_fetch_alerts
        assert monitor._synth is _default_synth_bulletin
        # The armed path is recorded for observability so the TUI can show
        # "TEST-TRIGGER ARMED" (the manual tester's confirmation it is armed).
        assert monitor.test_trigger_path == trigger_path


class TestMakeTriggerFileFetch:
    def test_returns_no_features_when_trigger_file_absent(self, tmp_path):
        trigger_path = tmp_path / "trigger"
        fetch = make_trigger_file_fetch(trigger_path)

        response = fetch(DEFAULT_ZONE, DEFAULT_COUNTY, "wilted-test-agent")

        assert response == {"features": []}

    def test_returns_one_qualifying_severe_feature_when_trigger_file_present(self, tmp_path):
        trigger_path = tmp_path / "trigger"
        trigger_path.write_text("fire")
        fetch = make_trigger_file_fetch(trigger_path)

        response = fetch(DEFAULT_ZONE, DEFAULT_COUNTY, "wilted-test-agent")

        assert len(response["features"]) == 1
        props = response["features"][0]["properties"]
        assert props["severity"] == "Severe"
        assert props["areaDesc"] == "Prince William, VA"  # human-readable, not the UGC code
        assert props["status"] == "Actual"
        assert props["messageType"] == "Alert"
        assert props["headline"]  # becomes the spoken bulletin text
        assert props["expires"]  # ISO-8601 offset-aware, ~3h out

    def test_drives_a_real_monitor_through_fire_dedup_clear_and_requalify(self, tmp_path):
        """End-to-end through the real WeatherMonitor -- not just the raw
        fetch response -- proving the trigger file actually flows through
        dedup/escalation/handoff unmodified."""
        trigger_path = tmp_path / "trigger"
        recorder = _BulletinRecorder()
        monitor = WeatherMonitor(
            fetch=make_trigger_file_fetch(trigger_path),
            synth=_fake_synth(),
            on_bulletin_ready=recorder,
        )

        monitor.poll_once()  # file absent -- nothing fires yet
        assert len(recorder.received) == 0

        trigger_path.write_text("fire")
        monitor.poll_once()  # file present -- fires exactly once
        assert len(recorder.received) == 1

        monitor.poll_once()  # still present -- deduped, no re-fire
        assert len(recorder.received) == 1

        trigger_path.unlink()
        monitor.poll_once()  # cleared -- fires nothing
        assert len(recorder.received) == 1

        trigger_path.write_text("fire again")
        monitor.poll_once()  # re-created -- area-clear re-qualify, fires again
        assert len(recorder.received) == 2
