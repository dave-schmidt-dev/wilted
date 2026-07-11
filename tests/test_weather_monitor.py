"""Integration tests for ``wilted.station_runtime.weather_monitor`` (Plan A task 4.2).

Covers: combined zone+county single-request coverage, the two-tier
escalation-aware dedup (exact-repeat guard + per-area escalation bar,
including the reset-on-clear behavior), pre-generation happening off the
interrupt path (synth before submit, never from inside a reducer/interrupt
callback), the submitted ``AcceptInterruption`` action's shape, heartbeat/
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

import concurrent.futures
import dataclasses
import json
import runpy
import sys
import threading
import time
from unittest.mock import patch

import pytest

from wilted.station.models import (
    FinalizationState,
    MediaDescriptor,
    PlaybackCheckpoint,
    SafeInterruptionMap,
    StationEntry,
)
from wilted.station.reducer import AcceptInterruption, StationState
from wilted.station_runtime import media_store
from wilted.station_runtime.weather_monitor import (
    DEFAULT_COUNTY,
    DEFAULT_ZONE,
    BulletinAudio,
    WeatherMonitor,
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


def _entry(entry_id="entry-1", **overrides) -> StationEntry:
    defaults = dict(
        entry_id=entry_id,
        kind="item",
        item_id="item-1",
        source="feed:test",
        policy_id=None,
        priority=5,
        expiry=None,
        duration_ms=60_000,
        media=_finalized_media(),
    )
    defaults.update(overrides)
    return StationEntry(**defaults)


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


@dataclasses.dataclass(frozen=True)
class _SimpleSubmitResult:
    accepted: bool
    revision: int
    state: StationState


class _FakeController:
    """Records every submitted action; state is a settable real ``StationState``."""

    def __init__(self, state: StationState | None = None) -> None:
        self._state = state if state is not None else StationState()
        self.submitted: list[AcceptInterruption] = []
        self._accepted = True

    def set_state(self, state: StationState) -> None:
        self._state = state

    def set_accepted(self, accepted: bool) -> None:  # noqa: FBT001 - test helper
        self._accepted = accepted

    def current_state(self) -> StationState:
        return self._state

    def submit(self, action: AcceptInterruption) -> concurrent.futures.Future:
        self.submitted.append(action)
        future: concurrent.futures.Future = concurrent.futures.Future()
        future.set_result(
            _SimpleSubmitResult(
                accepted=self._accepted,
                revision=1 if self._accepted else 0,
                state=self._state,
            )
        )
        return future


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
    with a fetch/submit spy) records cross-call ordering."""

    def synth(text: str) -> BulletinAudio:
        if calls is not None:
            calls.append(text)
        if order is not None:
            order.append("synth")
        return BulletinAudio(audio_bytes=b"RIFF-fake-wav-bytes", duration_ms=4_200)

    return synth


def _monitor(
    controller,
    *,
    fetch=None,
    synth=None,
    zone=DEFAULT_ZONE,
    county=DEFAULT_COUNTY,
    interval_s=30.0,
) -> WeatherMonitor:
    return WeatherMonitor(
        controller,
        fetch=fetch if fetch is not None else _FixtureFetch(_feature_collection()),
        synth=synth if synth is not None else _fake_synth(),
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
        controller = _FakeController()
        monitor = _monitor(controller, fetch=fetch)

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
        controller = _FakeController()
        monitor = _monitor(controller, fetch=fetch)

        monitor.poll_once()

        assert len(fetch.calls) == 1  # both covered by the ONE combined poll
        assert len(controller.submitted) == 2
        submitted_ids = {action.bulletin.entry_id for action in controller.submitted}
        assert submitted_ids == {"wx-zone-1", "wx-county-1"}


# ---------------------------------------------------------------------------
# Escalation-aware dedup (two-tier)
# ---------------------------------------------------------------------------


class TestDedupAndEscalation:
    def test_first_qualification_admits(self):
        fetch = _FixtureFetch(_feature_collection(_alert_feature()))
        controller = _FakeController()
        monitor = _monitor(controller, fetch=fetch)

        monitor.poll_once()

        assert len(controller.submitted) == 1

    def test_identical_repeat_is_deduped_tier1(self):
        """The same still-active alert (unchanged id/severity/content) is
        re-served by NWS on every poll until it clears -- must dedup."""
        alert = _alert_feature()
        fetch = _FixtureFetch(_feature_collection(alert), _feature_collection(alert))
        controller = _FakeController()
        monitor = _monitor(controller, fetch=fetch)

        monitor.poll_once()
        monitor.poll_once()

        assert len(controller.submitted) == 1

    def test_new_message_same_severity_is_deduped_tier2(self):
        """A genuine reissue (new id/content) at the SAME severity must not
        re-qualify -- only an escalation does."""
        first = _alert_feature(alert_id="id-1", severity="Severe", description="Initial description.")
        reissued = _alert_feature(alert_id="id-2", severity="Severe", description="Updated wording, same severity.")
        fetch = _FixtureFetch(_feature_collection(first), _feature_collection(reissued))
        controller = _FakeController()
        monitor = _monitor(controller, fetch=fetch)

        monitor.poll_once()
        monitor.poll_once()

        assert len(controller.submitted) == 1
        assert controller.submitted[0].bulletin.entry_id == "wx-id-1"

    def test_escalation_to_higher_severity_requalifies(self):
        first = _alert_feature(alert_id="id-1", severity="Moderate")
        escalated = _alert_feature(alert_id="id-2", severity="Extreme")
        fetch = _FixtureFetch(_feature_collection(first), _feature_collection(escalated))
        controller = _FakeController()
        monitor = _monitor(controller, fetch=fetch)

        monitor.poll_once()
        monitor.poll_once()

        assert len(controller.submitted) == 2
        assert [a.bulletin.entry_id for a in controller.submitted] == ["wx-id-1", "wx-id-2"]

    def test_deescalation_does_not_requalify(self):
        first = _alert_feature(alert_id="id-1", severity="Severe")
        deescalated = _alert_feature(alert_id="id-2", severity="Minor")
        fetch = _FixtureFetch(_feature_collection(first), _feature_collection(deescalated))
        controller = _FakeController()
        monitor = _monitor(controller, fetch=fetch)

        monitor.poll_once()
        monitor.poll_once()

        assert len(controller.submitted) == 1

    def test_area_state_resets_after_alert_clears_allowing_lower_severity_later(self):
        """Once an alert for an area clears (absent from a poll's combined
        response), the escalation bar for that area resets -- a later,
        unrelated alert at even a low severity must be able to qualify."""
        severe = _alert_feature(alert_id="id-1", area_desc="Area A", severity="Severe")
        # Poll 2: nothing active for "Area A" (alert cleared).
        cleared = _feature_collection()
        minor_new = _alert_feature(alert_id="id-2", area_desc="Area A", severity="Minor")
        fetch = _FixtureFetch(_feature_collection(severe), cleared, _feature_collection(minor_new))
        controller = _FakeController()
        monitor = _monitor(controller, fetch=fetch)

        monitor.poll_once()  # qualifies at Severe
        monitor.poll_once()  # clears -> area state reset
        monitor.poll_once()  # new Minor alert -> should qualify again

        assert len(controller.submitted) == 2
        assert [a.bulletin.entry_id for a in controller.submitted] == ["wx-id-1", "wx-id-2"]

    def test_distinct_areas_tracked_independently(self):
        area_a = _alert_feature(alert_id="a-1", area_desc="Area A", severity="Minor")
        area_b = _alert_feature(alert_id="b-1", area_desc="Area B", severity="Minor")
        fetch = _FixtureFetch(_feature_collection(area_a, area_b))
        controller = _FakeController()
        monitor = _monitor(controller, fetch=fetch)

        monitor.poll_once()

        assert len(controller.submitted) == 2


# ---------------------------------------------------------------------------
# Pre-generation off the interrupt path
# ---------------------------------------------------------------------------


class TestPreGeneration:
    def test_synth_runs_before_submit_on_qualification(self):
        order: list[str] = []

        def synth(text: str) -> BulletinAudio:
            order.append("synth")
            return BulletinAudio(audio_bytes=b"fake-wav", duration_ms=1000)

        class _OrderRecordingController(_FakeController):
            def submit(self, action):
                order.append("submit")
                return super().submit(action)

        fetch = _FixtureFetch(_feature_collection(_alert_feature()))
        controller = _OrderRecordingController()
        monitor = _monitor(controller, fetch=fetch, synth=synth)

        monitor.poll_once()

        assert order == ["synth", "submit"]

    def test_bulletin_media_is_playable_and_published(self, tmp_path):
        fetch = _FixtureFetch(_feature_collection(_alert_feature()))
        controller = _FakeController()
        monitor = _monitor(controller, fetch=fetch)

        monitor.poll_once()

        assert len(controller.submitted) == 1
        bulletin = controller.submitted[0].bulletin
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

    def test_synth_failure_skips_submission_without_raising(self):
        def failing_synth(text: str) -> BulletinAudio:
            raise RuntimeError("model unavailable")

        fetch = _FixtureFetch(_feature_collection(_alert_feature()))
        controller = _FakeController()
        monitor = _monitor(controller, fetch=fetch, synth=failing_synth)

        monitor.poll_once()  # must not raise

        assert controller.submitted == []


# ---------------------------------------------------------------------------
# Submitted action shape
# ---------------------------------------------------------------------------


class TestSubmittedActionShape:
    def test_uses_last_known_checkpoint_offset(self):
        checkpoint = PlaybackCheckpoint(
            station_revision=3,
            entry_id="entry-1",
            media_offset_ms=45_000,
            state="playing",
            interrupted_entry_stack=(),
            writer_device="mac",
            mutation_id="m-1",
            timestamp="2026-07-11T12:00:00Z",
        )
        state = StationState(station_revision=3, active_entry=_entry(), checkpoint=checkpoint)
        controller = _FakeController(state)
        fetch = _FixtureFetch(_feature_collection(_alert_feature()))
        monitor = _monitor(controller, fetch=fetch)

        monitor.poll_once()

        assert controller.submitted[0].interrupt_offset_ms == 45_000

    def test_falls_back_to_zero_offset_with_no_checkpoint(self):
        controller = _FakeController(StationState())
        fetch = _FixtureFetch(_feature_collection(_alert_feature()))
        monitor = _monitor(controller, fetch=fetch)

        monitor.poll_once()

        assert controller.submitted[0].interrupt_offset_ms == 0

    def test_policy_current_and_source_fields(self):
        fetch = _FixtureFetch(_feature_collection(_alert_feature(severity="Extreme")))
        controller = _FakeController()
        monitor = _monitor(controller, fetch=fetch)

        monitor.poll_once()

        action = controller.submitted[0]
        assert action.policy_current is True
        assert action.bulletin.source == "monitor:nws-alerts"
        assert action.bulletin.priority == 0  # Extreme -> most urgent

    def test_rejected_submission_is_not_retried(self):
        """A rejected AcceptInterruption (e.g. no safe point right now) is
        logged but NOT retried by this monitor -- Task 4.3 owns safe-boundary
        retry. Confirms the monitor doesn't loop/spin on a rejection."""
        controller = _FakeController()
        controller.set_accepted(False)
        fetch = _FixtureFetch(_feature_collection(_alert_feature()))
        monitor = _monitor(controller, fetch=fetch)

        monitor.poll_once()

        assert len(controller.submitted) == 1  # exactly one attempt, no retry loop


# ---------------------------------------------------------------------------
# Failure isolation (INV-6 spirit) + health/heartbeat
# ---------------------------------------------------------------------------


class TestFailureIsolationAndHealth:
    def test_health_is_unknown_before_first_poll(self):
        controller = _FakeController()
        monitor = _monitor(controller)
        assert monitor.health() == "unknown"

    def test_health_is_healthy_after_successful_poll(self):
        controller = _FakeController()
        monitor = _monitor(controller)
        monitor.poll_once()
        assert monitor.health() == "healthy"
        assert monitor.last_success_at is not None
        assert monitor.last_error is None

    def test_fetch_failure_never_raises_and_marks_degraded_then_failed(self):
        fetch = _FixtureFetch(RuntimeError("network down"))
        controller = _FakeController()
        monitor = _monitor(controller, fetch=fetch)

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
        controller = _FakeController()
        monitor = _monitor(controller, fetch=fetch)

        monitor.poll_once()
        assert monitor.consecutive_failures == 1

        monitor.poll_once()
        assert monitor.consecutive_failures == 0
        assert monitor.health() == "healthy"

    def test_malformed_alert_feature_is_skipped_without_crashing_others(self):
        malformed = {"properties": {"event": "Missing area and id"}}
        good = _alert_feature(alert_id="good-1")
        fetch = _FixtureFetch(_feature_collection(malformed, good))
        controller = _FakeController()
        monitor = _monitor(controller, fetch=fetch)

        monitor.poll_once()  # must not raise

        assert len(controller.submitted) == 1
        assert controller.submitted[0].bulletin.entry_id == "wx-good-1"

    def test_heartbeat_updates_even_on_failure(self):
        fetch = _FixtureFetch(RuntimeError("down"))
        controller = _FakeController()
        monitor = _monitor(controller, fetch=fetch)

        assert monitor.last_poll_at is None
        monitor.poll_once()
        assert monitor.last_poll_at is not None

    def test_health_is_stale_when_heartbeat_old_relative_to_interval(self):
        controller = _FakeController()
        monitor = _monitor(controller, interval_s=30.0)
        monitor.poll_once()

        far_future = "2099-01-01T00:00:00Z"
        assert monitor.health(now=far_future) == "stale"


# ---------------------------------------------------------------------------
# Lifecycle (mirrors test_checkpoint_poller.py's patterns)
# ---------------------------------------------------------------------------


class TestLifecycle:
    def test_interval_below_floor_raises_value_error(self):
        controller = _FakeController()
        with pytest.raises(ValueError, match="30"):
            _monitor(controller, interval_s=10.0)

    def _wait_until(self, predicate, *, timeout_s: float = 2.0, poll_interval_s: float = 0.01) -> None:
        deadline = time.monotonic() + timeout_s
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(poll_interval_s)
        raise AssertionError(f"condition not met within {timeout_s}s")

    def test_start_polls_immediately_then_stop_stops_cleanly(self):
        fetch = _FixtureFetch(_feature_collection())
        controller = _FakeController()
        monitor = _monitor(controller, fetch=fetch, interval_s=30.0)

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
        controller = _FakeController()
        monitor = _monitor(controller, interval_s=30.0)

        monitor.start()
        try:
            with pytest.raises(RuntimeError):
                monitor.start()
        finally:
            monitor.stop()

    def test_stop_without_start_is_a_safe_noop(self):
        controller = _FakeController()
        monitor = _monitor(controller)
        monitor.stop()  # must not raise

    def test_poll_once_is_safe_when_called_concurrently(self):
        """poll_once may be invoked directly/concurrently (tests, or a manual
        call racing the poll thread); shared per-area state must not corrupt."""
        fetch = _FixtureFetch(*[_feature_collection(_alert_feature(alert_id=f"id-{i}")) for i in range(8)])
        controller = _FakeController()
        monitor = _monitor(controller, fetch=fetch)

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
    path actually ran (not a stub), with no live NWS call.
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
