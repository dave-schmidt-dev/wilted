"""``WeatherMonitor`` — in-process NWS zone+county active-alerts poller (Plan A task 4.2).

Polls the NWS active-alerts feed for the ADR-fixed forecast zone (``VAZ526``)
AND county (``VAC153``) — a zone-only query misses county-issued
tornado/severe-thunderstorm/flash-flood warnings (CR-1) — on a deterministic
``>=30``-second interval, escalation-aware-dedups qualifying alerts,
pre-generates the bulletin audio OFF the interrupt path, and hands the
finished, fully-playable bulletin off to whatever consumer is wired via
:attr:`WeatherMonitor.on_bulletin_ready` (Task 4.3: the safe-boundary-aware
``AcceptInterruption`` submission itself now lives in the TUI — see the
"Seam decision" note below — so this monitor never calls
``StationController.submit`` or holds a controller reference at all).

Combined single request (SR-5)
-------------------------------
The NWS ``/alerts/active`` endpoint's ``zone`` query parameter is a
comma-joined array (OpenAPI ``style: form, explode: false`` — confirmed
against ``https://api.weather.gov/openapi.json``'s ``AlertZone`` parameter
definition and live-verified 2026-07-11: ``?zone=VAZ526,VAC153`` returns a
single combined ``FeatureCollection`` covering both UGC codes, vs. repeated
``zone=A&zone=B`` params, which the live API does NOT combine — only the
last one wins). ``zone`` is documented as "Zone ID (forecast or county)": the
same parameter carries both forecast-zone (``Z`` suffix) and county
(``C`` suffix) UGC codes, so one comma-joined ``zone`` value is a genuine
single request covering both, not two requests and not an approximation.

Escalation-aware dedup (two-tier, per area)
--------------------------------------------
NWS mints a new CAP message ``id`` on every reissue/update of an ongoing
warning (the *previous* id drops out of ``/alerts/active`` once replaced), so
raw ``id``-keyed dedup would treat every routine reissue as brand new and
never actually dedup a "re-issued at the same severity" alert the way the
task spec requires. Per-area state (:class:`_AreaState`) is tracked instead:

    1. **Exact-repeat guard**: a full-signature match (id, status,
       message_type, severity, area, updated-time, content-hash — the
       composite the task spec names) against the *last* message seen for
       this area is a pure repeat (the dominant steady-state case: an
       unchanged active alert is re-served, unchanged, on every poll until
       it clears) and is skipped outright.
    2. **Escalation check**: a message that differs from the last one (a
       genuine reissue/update) only re-qualifies if its severity is
       STRICTLY HIGHER than the highest severity already qualified for this
       area (``_SEVERITY_RANK``: unknown < minor < moderate < severe <
       extreme). A same-or-lower-severity update (e.g. a wording correction,
       an extended expiry) is deduped without spamming a new bulletin.

An area's escalation bar resets when a poll's combined response no longer
contains ANY alert for that area (the prior warning cleared/expired) — see
:meth:`WeatherMonitor.poll_once` — so a *later, unrelated* alert for the same
area is not compared against a stale high-water-mark left behind by an alert
that is no longer active.

Seam decision: the TUI orchestrates; the monitor hands off (Task 4.3)
-----------------------------------------------------------------------
This module builds DETECTION + dedup/escalation + pre-generation + HANDOFF.
It deliberately does NOT:

    - Wait for / retry at a genuine safe playback boundary, or decide WHEN
      to interrupt at all. It has no live knowledge of the real playback
      offset — only the TUI (via its adapter) does — so it cannot safely
      pick an ``interrupt_offset_ms``. See ``wilted.tui.WiltedApp``'s
      ``_on_bulletin_ready`` / ``_maybe_submit_pending_bulletin``, which own
      the entire safe-boundary-detection-and-submit path, including the
      6s-cold/5s-warm generation budget and audible+visual fallback.
    - Submit ``AcceptInterruption`` or ``ResumeFromInterruption`` itself, or
      hold any reference to a ``StationController``. Once a bulletin is
      fully generated, published, and finalized, this monitor's job ends at
      :meth:`WeatherMonitor._hand_off_bulletin` — a plain callback handoff,
      not a station mutation.
    - Retry a rejected/deferred interruption. Once an area's escalation bar
      has advanced for a qualification attempt, a later poll at the same
      severity dedupes rather than re-generating — even if the TUI never
      found a safe boundary to interrupt at. Retry-at-the-next-safe-boundary
      for an already-generated, still-pending bulletin is the TUI's job.

Lifecycle discipline
---------------------
Mirrors ``CheckpointPoller``/``RouteMonitor`` exactly: :meth:`start` raises
``RuntimeError`` on a double-start, :meth:`stop` is idempotent, the poll loop
runs on one daemon thread. Unlike ``CheckpointPoller`` (which waits a full
interval before its first tick, since a checkpoint at t=0 would be redundant
with the ``StartPlayback`` that must have just run), :meth:`WeatherMonitor`
polls IMMEDIATELY at start — an active weather alert should be surfaced as
soon as possible, not after waiting out a full interval.

INV-6 extension (this module + its wrapper)
---------------------------------------------
``scripts/wilted-weather-monitor.sh`` is a one-shot poll-and-report wrapper
(mirrors ``wilted-nightly.sh``'s shape: resolve project root, ``uv run``,
flock, log, propagate the real exit code) invoking
``python -m wilted.station_runtime.weather_monitor``. Per the C1 lesson
(``wilted-nightly.sh`` invoking ``python -m wilted.cli``, which had no
``__main__`` guard and so exited 0 having run nothing every night), this
module's ``if __name__ == "__main__":`` guard actually calls :func:`main`,
which propagates a TRUTHFUL exit code — 0 only if a real poll completed with
non-failed health, 1 if the controller lease could not be acquired or the
poll itself failed. See ``tests/test_weather_monitor.py``'s wrapper gate
test. This is a standalone, single-poll health-check/manual-run path (for an
external scheduler or manual invocation) distinct from how
:class:`WeatherMonitor` is meant to run continuously: embedded, as a
background thread, in the same long-running process as the TUI/adapter (the
only place a bulletin can be safely interrupted-into) — see
``wilted.tui.WiltedApp``'s ``on_mount``/``on_unmount`` wiring of an injected
``weather_monitor`` instance and its ``on_bulletin_ready`` callback. This
wrapper's ``main()`` still acquires/releases a real ``StationController``
lease purely as a runtime-health smoke test (mirroring how the embedded
monitor's host process would also need a controller lease); it does not pass
that controller into :class:`WeatherMonitor`, which no longer needs one.
"""

from __future__ import annotations

import argparse
import dataclasses
import hashlib
import json
import logging
import os
import sys
import threading
import urllib.parse
import urllib.request
from datetime import UTC, datetime
from typing import TYPE_CHECKING

from wilted.station.models import (
    FinalizationState,
    MediaDescriptor,
    SafeInterruptionMap,
    StationEntry,
    now_utc_z,
)
from wilted.station_runtime import media_store

if TYPE_CHECKING:
    from collections.abc import Callable

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# ADR-fixed location + protocol constants
# ---------------------------------------------------------------------------

DEFAULT_ZONE = "VAZ526"
"""NWS forecast zone UGC for the ADR-fixed location (ZIP 20169, Haymarket VA)."""

DEFAULT_COUNTY = "VAC153"
"""NWS county UGC for the ADR-fixed location — covers county-issued
tornado/severe-thunderstorm/flash-flood warnings a zone-only query misses (CR-1)."""

DEFAULT_USER_AGENT = "wilted-radio/0.2 (david@cipherblade.com)"
"""Descriptive User-Agent, per NWS API usage guidance — matches the string
verified against the live API with zero 403s in
``spikes/nws-gridpoint-2026-07-10/findings.md``."""

DEFAULT_INTERVAL_SECONDS = 30.0

_MIN_INTERVAL_SECONDS = 30.0
"""SR-5 floor: NWS asks for reasonable usage; a combined single request
already avoids doubling load, but the poll cadence itself must not go below
the task's explicit ``>=30s`` requirement."""

_NWS_ALERTS_URL = "https://api.weather.gov/alerts/active"
_FETCH_TIMEOUT_SECONDS = 10.0

_JOIN_TIMEOUT_SECONDS = 5.0
"""Matches ``CheckpointPoller``/``RouteMonitor``/``StationController``'s own
``_JOIN_TIMEOUT_SECONDS`` convention."""

_SEVERITY_RANK: dict[str, int] = {
    "unknown": 0,
    "minor": 1,
    "moderate": 2,
    "severe": 3,
    "extreme": 4,
}
"""NWS CAP severity vocabulary, ranked low-to-high. An unrecognized/missing
severity string is treated as ``"unknown"`` (rank 0) rather than raising —
malformed severity must never crash a poll (INV-6 isolation spirit)."""

_DEGRADED_FAILURE_THRESHOLD = 1
_FAILED_FAILURE_THRESHOLD = 3
_STALE_HEARTBEAT_MULTIPLIER = 3.0
"""A heartbeat older than ``interval_s * this`` means the poll loop itself
has stalled (thread died, wedged) — distinct from a poll that ran and failed."""


# ---------------------------------------------------------------------------
# Value types
# ---------------------------------------------------------------------------


@dataclasses.dataclass(frozen=True, slots=True)
class BulletinAudio:
    """Synthesized bulletin audio, as returned by an injected ``synth`` seam.

    Attributes:
        audio_bytes: The encoded audio file's bytes (production default:
            WAV, via ``mlx_audio.audio_io.write``).
        duration_ms: Playback duration in milliseconds. Carried alongside
            the bytes (rather than re-probed from the published file) so
            neither the real synth path nor a test fixture needs a second
            decode step just to answer "how long is this."
    """

    audio_bytes: bytes
    duration_ms: int


@dataclasses.dataclass(slots=True)
class _AreaState:
    """Per-area escalation/dedup state (mutable — updated in place across polls).

    Attributes:
        last_signature: The full signature (see ``_AlertRecord.signature``)
            of the most recent message seen for this area, regardless of
            whether it qualified — the tier-1 exact-repeat guard.
        max_qualified_severity: The highest ``_SEVERITY_RANK`` value that has
            actually qualified (pre-generated + submitted) for this area.
            ``-1`` means nothing has qualified yet.
    """

    last_signature: tuple | None = None
    max_qualified_severity: int = -1


@dataclasses.dataclass(frozen=True, slots=True)
class _AlertRecord:
    """One parsed NWS CAP alert feature, normalized for dedup/escalation/display."""

    alert_id: str
    event: str
    area_desc: str
    severity: str
    severity_rank: int
    status: str
    message_type: str
    updated: str
    headline: str
    description: str
    instruction: str
    expires: str | None

    def signature(self) -> tuple:
        """The escalation-aware dedup signature: id + status/message-type +
        severity + area + updated-time + content-signature, per the task
        spec. A tuple (not a joined string) — no delimiter-collision concern,
        directly hashable/comparable.
        """
        content_hash = hashlib.sha256(f"{self.headline}\n{self.description}\n{self.instruction}".encode()).hexdigest()
        return (
            self.alert_id,
            self.status,
            self.message_type,
            self.severity,
            self.area_desc,
            self.updated,
            content_hash,
        )

    @classmethod
    def from_feature(cls, feature: object) -> _AlertRecord | None:
        """Parse one GeoJSON alert feature. Returns None (never raises) for
        anything malformed — a single bad feature must not abort the poll
        (INV-6 per-item isolation spirit)."""
        if not isinstance(feature, dict):
            return None
        props = feature.get("properties")
        if not isinstance(props, dict):
            return None

        # properties.id is the bare CAP <identifier> (e.g.
        # "urn:oid:2.49.0.1.840.0.<hash>.001.1"); the top-level feature.id is
        # the full API URL for the same resource
        # ("https://api.weather.gov/alerts/<that same urn>"). Both are
        # equally globally unique (confirmed live 2026-07-11 against
        # api.weather.gov/alerts/active), but properties.id is the shorter,
        # more idiomatic form for entry_id construction -- prefer it, falling
        # back to the full URL only if properties.id is somehow absent.
        alert_id = props.get("id") or feature.get("id")
        event = props.get("event")
        area_desc = props.get("areaDesc")
        if not alert_id or not event or not area_desc:
            return None

        severity_raw = str(props.get("severity") or "Unknown")
        expires = props.get("expires")

        return cls(
            alert_id=str(alert_id),
            event=str(event),
            area_desc=str(area_desc),
            severity=severity_raw,
            severity_rank=_severity_rank(severity_raw),
            status=str(props.get("status") or ""),
            message_type=str(props.get("messageType") or ""),
            updated=str(props.get("sent") or props.get("effective") or ""),
            headline=str(props.get("headline") or ""),
            description=str(props.get("description") or ""),
            instruction=str(props.get("instruction") or ""),
            expires=str(expires) if expires else None,
        )


def _severity_rank(severity: str) -> int:
    return _SEVERITY_RANK.get(severity.strip().lower(), _SEVERITY_RANK["unknown"])


def _priority_for_severity(severity_rank: int) -> int:
    """Lower = more urgent (``StationEntry.priority`` convention). Extreme
    (rank 4) -> priority 0 (most urgent); Unknown (rank 0) -> priority 4."""
    return max(0, 4 - severity_rank)


def _parse_utc_z(timestamp: str) -> datetime:
    return datetime.strptime(timestamp, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=UTC)


def _to_utc_z(iso_string: str) -> str:
    """Convert an arbitrary-offset ISO-8601 string (NWS ``expires`` values
    carry an explicit local offset, e.g. ``-04:00``, never bare ``Z``) into
    the station contract's UTC ``Z``-suffixed string form."""
    dt = datetime.fromisoformat(iso_string)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=UTC)
    return dt.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def _seconds_between(earlier_z: str, later_z: str) -> float:
    return (_parse_utc_z(later_z) - _parse_utc_z(earlier_z)).total_seconds()


def _extract_features(response: object) -> list[dict]:
    """Pull the ``features`` array out of a parsed NWS alerts response.

    Raises (rather than silently returning ``[]``) on a structurally wrong
    top-level shape — that is a genuine fetch/parse failure the caller's
    health tracking must see, not a "zero alerts" outcome.
    """
    if not isinstance(response, dict):
        raise ValueError(f"NWS alerts response is not a JSON object: {type(response).__name__}")
    features = response.get("features")
    if features is None:
        return []
    if not isinstance(features, list):
        raise ValueError(f"NWS alerts response 'features' is not a list: {type(features).__name__}")
    return features


# ---------------------------------------------------------------------------
# Production seams (real NWS fetch / real TTS synth) — both injectable, both
# REQUIRED (no magic ``None``-default that would let a test silently reach
# a real network/model call) on ``WeatherMonitor``. Only ``main()`` (the CLI
# wrapper's entrypoint) wires these in.
# ---------------------------------------------------------------------------


def _default_fetch_alerts(zone: str, county: str, user_agent: str) -> dict:
    """Real NWS fetch: one combined GET covering both ``zone`` and ``county``.

    The ``zone`` query parameter is comma-joined (OpenAPI ``explode: false``
    array serialization — see module docstring for the live-verified
    confirmation), so this is genuinely ONE HTTP request regardless of how
    many UGC codes are requested.
    """
    query = urllib.parse.urlencode({"zone": f"{zone},{county}"})
    url = f"{_NWS_ALERTS_URL}?{query}"
    request = urllib.request.Request(
        url,
        headers={"User-Agent": user_agent, "Accept": "application/geo+json"},
    )
    with urllib.request.urlopen(request, timeout=_FETCH_TIMEOUT_SECONDS) as response:  # noqa: S310 - fixed https host
        raw = response.read()
    return json.loads(raw)


def _default_synth_bulletin(text: str) -> BulletinAudio:
    """Real TTS synth via the coordinator's single ML lease (INV-1/INV-2).

    Lazy-imports ``AudioEngine``/``ModelCoordinator``/``mlx_audio`` so
    importing this module never requires those (heavy, optional-at-import)
    dependencies — only the CLI wrapper's production path (:func:`main`)
    ever calls this; every test injects its own fixture ``synth`` instead.
    """
    import tempfile
    from pathlib import Path

    from mlx_audio.audio_io import write as _audio_write

    from wilted.engine import AudioEngine
    from wilted.station_runtime.coordinator import ModelCoordinator

    coordinator = ModelCoordinator()
    engine = AudioEngine()
    audio_np = coordinator.run_tts(engine, lambda e: e.generate_audio(text))
    duration_ms = round(len(audio_np) / engine.sample_rate * 1000)

    fd, tmp_name = tempfile.mkstemp(suffix=".wav")
    os.close(fd)
    tmp_path = Path(tmp_name)
    try:
        _audio_write(str(tmp_path), audio_np, engine.sample_rate)
        audio_bytes = tmp_path.read_bytes()
    finally:
        tmp_path.unlink(missing_ok=True)

    return BulletinAudio(audio_bytes=audio_bytes, duration_ms=duration_ms)


# ---------------------------------------------------------------------------
# WeatherMonitor
# ---------------------------------------------------------------------------


class WeatherMonitor:
    """Polls NWS zone+county alerts; pre-generates bulletins and hands them off.

    See the module docstring for the combined-request, dedup/escalation, and
    monitor-hands-off/TUI-orchestrates seam design. ``fetch``/``synth`` are
    REQUIRED keyword-only seams (no real-implementation default) so a test
    can never accidentally construct a monitor that reaches a live NWS call
    or loads a real TTS model. This monitor holds no reference to a
    ``StationController`` and never calls ``reducer.apply``/``submit`` —
    see :attr:`on_bulletin_ready`.
    """

    def __init__(
        self,
        *,
        fetch: Callable[[str, str, str], dict],
        synth: Callable[[str], BulletinAudio],
        zone: str = DEFAULT_ZONE,
        county: str = DEFAULT_COUNTY,
        interval_s: float = DEFAULT_INTERVAL_SECONDS,
        user_agent: str = DEFAULT_USER_AGENT,
        on_bulletin_ready: Callable[[StationEntry], None] | None = None,
    ) -> None:
        if interval_s < _MIN_INTERVAL_SECONDS:
            raise ValueError(
                f"WeatherMonitor interval_s must be >= {_MIN_INTERVAL_SECONDS} "
                f"(SR-5 reasonable-usage floor), got {interval_s}"
            )
        self._fetch = fetch
        self._synth = synth
        self._zone = zone
        self._county = county
        self._interval_s = interval_s
        self._user_agent = user_agent

        #: Callback invoked with each fully-generated, published, playable
        #: bulletin — settable, exactly like ``MacPlaybackAdapter.on_complete``
        #: (see that class's docstring for the mirrored contract). ``None``
        #: (the default) means no consumer is wired: a qualifying bulletin is
        #: logged and dropped rather than silently lost with no trace — the
        #: expected state for the standalone one-shot CLI wrapper (``main()``
        #: below), which has no live TUI to hand off to. The live embedded
        #: monitor (``wilted.tui.WiltedApp``) always wires this before
        #: :meth:`start`.
        self.on_bulletin_ready = on_bulletin_ready

        self._area_state: dict[str, _AreaState] = {}
        self._poll_lock = threading.Lock()

        self._last_poll_at: str | None = None
        self._last_success_at: str | None = None
        self._last_error: str | None = None
        self._consecutive_failures = 0

        self._stop_event = threading.Event()
        self._thread: threading.Thread | None = None
        self._running = False

    # ------------------------------------------------------------------
    # Lifecycle (mirrors CheckpointPoller/RouteMonitor)
    # ------------------------------------------------------------------

    def start(self) -> None:
        """Start the background polling thread. Polls immediately (t=0), then
        every ``interval_s`` thereafter.

        Raises:
            RuntimeError: This monitor is already running.
        """
        if self._running:
            raise RuntimeError("WeatherMonitor.start() called twice on the same instance")

        self._stop_event.clear()
        self._thread = threading.Thread(target=self._poll_loop, name="weather-monitor", daemon=True)
        self._running = True
        self._thread.start()

    def _poll_loop(self) -> None:
        self.poll_once()
        while not self._stop_event.wait(self._interval_s):
            self.poll_once()

    def stop(self) -> None:
        """Stop the background polling thread. Safe to call more than once
        or without a prior :meth:`start` (no-op)."""
        if not self._running:
            return
        self._running = False

        self._stop_event.set()
        if self._thread is not None:
            self._thread.join(timeout=_JOIN_TIMEOUT_SECONDS)
            if self._thread.is_alive():
                logger.error(
                    "WeatherMonitor.stop(): poll thread %r did not exit within %.1fs",
                    self._thread.name,
                    _JOIN_TIMEOUT_SECONDS,
                )
            self._thread = None

    # ------------------------------------------------------------------
    # Health / heartbeat surface
    # ------------------------------------------------------------------

    @property
    def last_poll_at(self) -> str | None:
        """UTC 'Z' timestamp of the most recent poll ATTEMPT (success or
        failure) — the heartbeat: proves the loop is alive even during a
        run of fetch failures."""
        return self._last_poll_at

    @property
    def last_success_at(self) -> str | None:
        """UTC 'Z' timestamp of the most recent poll that completed without
        a fetch/parse error (independent of whether any alert qualified)."""
        return self._last_success_at

    @property
    def last_error(self) -> str | None:
        """``repr()`` of the most recent fetch/parse failure, or None."""
        return self._last_error

    @property
    def consecutive_failures(self) -> int:
        return self._consecutive_failures

    def health(self, *, now: str | None = None) -> str:
        """Compute the current health status: ``unknown`` / ``healthy`` /
        ``stale`` / ``degraded`` / ``failed``.

        Args:
            now: Optional UTC 'Z' timestamp to evaluate staleness against
                (defaults to the real current time). Injectable so tests can
                assert staleness deterministically without sleeping.
        """
        if self._last_poll_at is None:
            return "unknown"
        if self._consecutive_failures >= _FAILED_FAILURE_THRESHOLD:
            return "failed"
        if self._consecutive_failures >= _DEGRADED_FAILURE_THRESHOLD:
            return "degraded"

        effective_now = now if now is not None else now_utc_z()
        if _seconds_between(self._last_poll_at, effective_now) > self._interval_s * _STALE_HEARTBEAT_MULTIPLIER:
            return "stale"
        return "healthy"

    # ------------------------------------------------------------------
    # Poll cycle
    # ------------------------------------------------------------------

    def poll_once(self) -> None:
        """Perform one combined zone+county poll cycle. Never raises.

        A fetch/parse failure updates the heartbeat + failure counters and
        returns (per-source isolation — a bad NWS response must not crash
        the poll loop or propagate to the controller/TUI). A malformed
        individual alert feature is skipped without aborting the rest of the
        batch (INV-6 per-item isolation spirit).
        """
        with self._poll_lock:
            self._poll_once_locked()

    def _poll_once_locked(self) -> None:
        now = now_utc_z()
        self._last_poll_at = now

        try:
            response = self._fetch(self._zone, self._county, self._user_agent)
            features = _extract_features(response)
        except Exception as exc:  # noqa: BLE001 - a poll must never propagate; health surfaces the failure
            self._consecutive_failures += 1
            self._last_error = repr(exc)
            logger.warning(
                "WeatherMonitor: poll failed (%d consecutive failures): %r",
                self._consecutive_failures,
                exc,
            )
            return

        self._last_success_at = now
        self._consecutive_failures = 0
        self._last_error = None

        seen_areas: set[str] = set()
        for feature in features:
            record = _AlertRecord.from_feature(feature)
            if record is None:
                logger.debug("WeatherMonitor: skipping malformed alert feature: %r", feature)
                continue
            seen_areas.add(record.area_desc)
            try:
                self._handle_alert(record)
            except Exception:  # noqa: BLE001 - one bad alert must not abort the batch
                logger.exception("WeatherMonitor: failed handling alert %s (%s)", record.alert_id, record.event)

        # An area with no active alert in this poll's response has cleared
        # since the last poll -- reset its escalation bar so a later,
        # unrelated alert for the same area is not compared against a stale
        # high-water-mark.
        for area in [a for a in self._area_state if a not in seen_areas]:
            del self._area_state[area]

    def _handle_alert(self, record: _AlertRecord) -> None:
        state = self._area_state.setdefault(record.area_desc, _AreaState())

        signature = record.signature()
        if state.last_signature == signature:
            return  # tier 1: identical to the last message seen for this area
        state.last_signature = signature

        if record.severity_rank <= state.max_qualified_severity:
            return  # tier 2: not an escalation over what already qualified

        state.max_qualified_severity = record.severity_rank
        self._qualify(record)

    # ------------------------------------------------------------------
    # Qualification: pre-generate (off the interrupt path) + hand off
    # ------------------------------------------------------------------

    def _bulletin_text(self, record: _AlertRecord) -> str:
        if record.headline:
            return record.headline
        return f"{record.event} for {record.area_desc}."

    def _qualify(self, record: _AlertRecord) -> None:
        """Pre-generate the bulletin's audio and hand it off to the consumer.

        Synthesis happens here, synchronously, inside the poll cycle -- NOT
        triggered from within the reducer/interrupt path -- which is what
        "off the interrupt path" means: by the time
        :meth:`_hand_off_bulletin` runs below, the bulletin is already fully
        published and playable (``FinalizationState.complete()``).
        """
        text = self._bulletin_text(record)
        try:
            audio = self._synth(text)
        except Exception:
            logger.exception(
                "WeatherMonitor: bulletin synthesis failed for alert %s (%s); interruption not submitted",
                record.alert_id,
                record.event,
            )
            return

        entry_id = f"wx-{record.alert_id}"
        expiry = _to_utc_z(record.expires) if record.expires else None

        sha256 = media_store.publish_with_owner(audio.audio_bytes, kind="bulletin", entry_id=entry_id, expiry=expiry)
        published_path = media_store.path_for(sha256)
        byte_size = published_path.stat().st_size if published_path is not None else len(audio.audio_bytes)

        descriptor = MediaDescriptor(
            sha256=sha256,
            byte_size=byte_size,
            mime_type="audio/wav",
            duration_ms=audio.duration_ms,
            transcript_segments=(),
            # A bulletin is not itself meant to be safely interrupted mid-play
            # (short, urgent, session-scoped) -- explicit NO_INTERRUPT, same
            # "no-transcript-shaped content is visibly no-interrupt" contract
            # normalize.py uses for transcript-less podcasts.
            safe_interruption=SafeInterruptionMap.empty(),
            byte_range_available=False,
            finalization=FinalizationState.complete(),
        )
        bulletin = StationEntry(
            entry_id=entry_id,
            kind="bulletin",
            item_id=None,
            source="monitor:nws-alerts",
            policy_id="weather-alert",
            priority=_priority_for_severity(record.severity_rank),
            expiry=expiry,
            duration_ms=audio.duration_ms,
            media=descriptor,
        )
        self._hand_off_bulletin(bulletin)

    def _hand_off_bulletin(self, bulletin: StationEntry) -> None:
        """Hand the pre-generated, fully-playable bulletin to :attr:`on_bulletin_ready`.

        Task 4.3 moved safe-boundary-aware submission (the actual
        ``AcceptInterruption``, using the REAL live playback offset) to the
        TUI, which is the only component with that live knowledge — see
        ``wilted.tui.WiltedApp._on_bulletin_ready`` /
        ``_maybe_submit_pending_bulletin``. This monitor's job ends here:
        escalation/dedup gating already happened in :meth:`_handle_alert`,
        and the bulletin is already published + finalized.

        A callback exception is caught and logged, never propagated to the
        poll loop -- the same discipline ``MacPlaybackAdapter`` applies to
        its own ``on_complete`` callback. If no callback is wired (``None``,
        the default -- e.g. the standalone one-shot CLI wrapper below, which
        has no live TUI to hand off to), the bulletin is logged and dropped
        rather than silently vanishing with no trace.
        """
        if self.on_bulletin_ready is None:
            logger.info(
                "WeatherMonitor: bulletin %s ready but no on_bulletin_ready consumer is wired -- dropped "
                "(expected for the standalone CLI wrapper; the live embedded monitor always wires this)",
                bulletin.entry_id,
            )
            return
        try:
            self.on_bulletin_ready(bulletin)
        except Exception:
            logger.error("WeatherMonitor: on_bulletin_ready callback raised for %s", bulletin.entry_id, exc_info=True)


# ---------------------------------------------------------------------------
# CLI wrapper entrypoint (scripts/wilted-weather-monitor.sh)
# ---------------------------------------------------------------------------


def main(argv: list[str] | None = None) -> int:
    """One-shot poll-and-report CLI entrypoint for ``scripts/wilted-weather-monitor.sh``.

    Acquires a real ``StationController`` lease, performs exactly one
    combined zone+county poll, logs the resulting health, and releases the
    lease. Intended for a manual run or an external scheduler at an interval
    respecting the SR-5 floor -- see the module docstring for why this is
    distinct from how ``WeatherMonitor`` is meant to run continuously
    in-process.

    Returns:
        0 if the controller lease was acquired and the poll completed
        without a fetch/parse error. 1 if the lease could not be acquired, or
        the poll itself failed. Never returns 0 without a real
        :meth:`WeatherMonitor.poll_once` call having actually happened (the
        INV-6 C1 lesson, extended to this module).

        Deliberately checks ``monitor.last_error`` rather than
        ``monitor.health()`` here: ``health()``'s ``"failed"`` state requires
        3 CONSECUTIVE failed polls, which is the right bar for a
        long-running in-process monitor's observability surface, but this
        CLI wrapper constructs a fresh ``WeatherMonitor`` and calls
        :meth:`WeatherMonitor.poll_once` exactly once per invocation --
        under that threshold, a single failed poll could only ever reach
        ``"degraded"``, never ``"failed"``, and this wrapper's exit code
        would never truthfully reflect a failure (the exact C1 "exits 0
        regardless of outcome" bug class this whole pattern exists to
        prevent). ``last_error`` reflects THIS poll's outcome directly.
    """
    from wilted.log import setup_logging
    from wilted.station_runtime.controller import StationController

    parser = argparse.ArgumentParser(
        prog="wilted-weather-monitor",
        description="One-shot NWS zone+county active-alerts poll (scripts/wilted-weather-monitor.sh).",
    )
    parser.add_argument("--zone", default=DEFAULT_ZONE, help=f"NWS forecast zone UGC (default: {DEFAULT_ZONE})")
    parser.add_argument("--county", default=DEFAULT_COUNTY, help=f"NWS county UGC (default: {DEFAULT_COUNTY})")
    parser.add_argument("--user-agent", default=DEFAULT_USER_AGENT)
    parser.add_argument(
        "--holder-id",
        default=None,
        help="StationController lease holder id (default: weather-monitor-<pid>)",
    )
    parser.add_argument("--debug", action="store_true")
    args = parser.parse_args(argv)

    setup_logging(debug=args.debug)

    holder_id = args.holder_id or f"weather-monitor-{os.getpid()}"
    controller = StationController(holder_id=holder_id)
    try:
        controller.start()
    except Exception:
        logger.exception("wilted-weather-monitor: failed to start StationController (lease unavailable?)")
        return 1

    try:
        # `controller` above is acquired/released purely as a runtime-health
        # smoke test (see the module docstring) -- WeatherMonitor itself no
        # longer takes a controller; it has no on_bulletin_ready consumer in
        # this standalone one-shot path, so a qualifying bulletin is logged
        # and dropped (see _hand_off_bulletin).
        monitor = WeatherMonitor(
            fetch=_default_fetch_alerts,
            synth=_default_synth_bulletin,
            zone=args.zone,
            county=args.county,
            user_agent=args.user_agent,
        )
        monitor.poll_once()
        health = monitor.health()
        logger.info(
            "wilted-weather-monitor: poll complete, health=%s, last_error=%r",
            health,
            monitor.last_error,
        )
        if monitor.last_error is not None:
            logger.error("wilted-weather-monitor: poll failed: %s", monitor.last_error)
            return 1
        return 0
    finally:
        controller.stop()


# INV-6 (extended, this task): without this guard, `python -m
# wilted.station_runtime.weather_monitor` would import the module, define
# main(), and exit 0 having polled NOTHING -- exactly the C1 class of bug
# wilted-nightly.sh's `python -m wilted.cli` history documents. This makes
# the module actually invoke main() and propagate its real exit status.
if __name__ == "__main__":
    sys.exit(main())


__all__ = [
    "DEFAULT_COUNTY",
    "DEFAULT_INTERVAL_SECONDS",
    "DEFAULT_USER_AGENT",
    "DEFAULT_ZONE",
    "BulletinAudio",
    "WeatherMonitor",
    "main",
]
