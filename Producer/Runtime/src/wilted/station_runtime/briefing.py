"""Briefing generator — a short spoken weather + top-N news briefing.

Produces a :class:`Briefing`: a NWS gridpoint-forecast weather line plus a
stable, snapshotted top-N news item set, assembled into a script within a
configurable duration budget (default 5 minutes), and synthesized by the
resident speech daemon. Tracks a generation time + max-age so a
stale briefing regenerates before play (see ``Briefing.is_stale`` /
``BriefingGenerator.ensure_fresh``).

Two structural seams keep this fully testable without the network or a
loaded model:

- ``BriefingGenerator.fetch_fn``: zero-arg callable returning the parsed NWS
  gridpoint-forecast JSON payload. Defaults to :func:`fetch_nws_gridpoint_forecast`,
  which reuses the exact request shape verified live in
  the 2026-07-10 NWS gridpoint spike (descriptive ``User-Agent``,
  ``Accept: application/geo+json``, and the deployer's configured office/grid
  -- see :func:`_resolve_gridpoint`).
- ``BriefingGenerator.synth_fn``: one-arg callable ``(script_text) -> result``.
  Defaults to the resident speech daemon; tests inject a fake that never
  performs synthesis.

CR-13 (stable top-N, not re-derived from live classification): the top-N
item set is queried from ``Item`` rows EXACTLY ONCE, inside
:meth:`BriefingGenerator.generate`, and copied into immutable
:class:`BriefingItem` snapshots stored on the returned (frozen) ``Briefing``.
Nothing about ``Briefing`` re-queries the database later -- a classification
change made after generation cannot alter an already-generated briefing's
``items``. See :func:`_select_top_n`.
"""

from __future__ import annotations

import json
import logging
import os
import urllib.request
from dataclasses import dataclass, field
from datetime import UTC, datetime
from typing import TYPE_CHECKING

from wilted import PROJECT_ROOT, WPM_ESTIMATE, load_config
from wilted.content_state import items_for_report
from wilted.engine import AudioEngine

if TYPE_CHECKING:
    from collections.abc import Callable, Sequence

logger = logging.getLogger(__name__)

__all__ = [
    "Briefing",
    "BriefingAudio",
    "BriefingGenerator",
    "BriefingItem",
    "WeatherLocationNotConfigured",
    "WeatherSnapshot",
    "fetch_nws_gridpoint_forecast",
    "synthesize_briefing_audio",
]

# ---------------------------------------------------------------------------
# NWS gridpoint forecast (A.0.3) -- ADR 0001 Decision 3, request shape verified
# live against api.weather.gov 2026-07-10
# (the 2026-07-10 NWS gridpoint spike). The one-time
# ZIP -> lat/lon -> /points -> gridpoint resolution the spike exercised is
# NOT repeated on every briefing generation: the office/grid are a fixed
# property of the deployer's configured location, so re-resolving via /points
# on every call would just add a second network hop and failure surface for a
# value that never changes. If the station ever needs to support more than one
# location, that resolution step belongs here as a separate, cached function --
# not inline in the per-briefing fetch path.
#
# The location itself is deployer data, not project data: it lives in
# ``wilted.toml``'s ``[weather]`` table (see :func:`_resolve_gridpoint`) and is
# deliberately absent from this checkout, which is public.
# ---------------------------------------------------------------------------
def _nws_user_agent() -> str:
    """The User-Agent sent to api.weather.gov.

    NWS asks callers to identify themselves with a contact address so they can
    reach the operator of a misbehaving client. That contact is the deployer's,
    not the project's, so it is read from ``WILTED_NWS_CONTACT`` rather than
    committed: a public checkout must not carry anyone's address, and a bare
    product token still satisfies the API (no 403s observed without a contact).
    """
    contact = os.environ.get("WILTED_NWS_CONTACT", "").strip()
    return f"Wilted/0.2 ({contact})" if contact else "Wilted/0.2"


_NWS_USER_AGENT = _nws_user_agent()
_NWS_ACCEPT = "application/geo+json"
_NWS_FORECAST_URL_TEMPLATE = "https://api.weather.gov/gridpoints/{office}/{x},{y}/forecast"
_DEFAULT_NWS_TIMEOUT_S = 10.0

_WEATHER_CONFIG_HINT = (
    "Add the NWS office/gridpoint for your location to wilted.toml:\n"
    "\n"
    "    [weather]\n"
    '    office = "XXX"  # NWS forecast office id\n'
    "    grid_x = 0\n"
    "    grid_y = 0\n"
    "\n"
    "Look these up once with: "
    "https://api.weather.gov/points/<lat>,<lon> "
    "(properties.gridId / gridX / gridY)."
)


class WeatherLocationNotConfigured(RuntimeError):
    """The NWS gridpoint location is missing or malformed in ``wilted.toml``.

    Raised at the point of use -- before any request is made -- so an
    unconfigured station reports exactly which setting is missing instead of
    silently fetching some other place's forecast.
    """


def _resolve_gridpoint() -> tuple[str, int, int]:
    """Read ``office``/``grid_x``/``grid_y`` from ``wilted.toml``'s ``[weather]``.

    There is deliberately no default: a wrong location is worse than no
    weather, and the deployer's location must not be committed to a public
    checkout.

    Returns:
        ``(office, grid_x, grid_y)``.

    Raises:
        WeatherLocationNotConfigured: If any key is absent, empty, or not an
            integer where an integer is required. The message names the
            missing keys and the file to put them in.
    """
    table = load_config().get("weather", {})
    missing = [key for key in ("office", "grid_x", "grid_y") if table.get(key) in (None, "")]
    if missing:
        raise WeatherLocationNotConfigured(
            "NWS gridpoint location is not configured: missing "
            + ", ".join(f"[weather].{key}" for key in missing)
            + f" in {PROJECT_ROOT / 'wilted.toml'}.\n\n"
            + _WEATHER_CONFIG_HINT
        )
    try:
        return str(table["office"]), int(table["grid_x"]), int(table["grid_y"])
    except (TypeError, ValueError) as exc:
        raise WeatherLocationNotConfigured(
            f"NWS gridpoint location in {PROJECT_ROOT / 'wilted.toml'} is malformed "
            f"([weather].grid_x/grid_y must be integers): {exc}\n\n" + _WEATHER_CONFIG_HINT
        ) from exc

# ``[briefing]`` table keys recognized in wilted.toml (see wilted.load_config).
_DEFAULT_MAX_DURATION_S = 5 * 60.0
# Matches the NWS forecast endpoint's own cache lifetime observed in the spike
# (`cache-control: max-age=3600`) -- polling/regenerating more often than the
# upstream forecast itself changes buys nothing.
_DEFAULT_MAX_AGE_S = 60 * 60.0
_DEFAULT_TOP_N = 5


def fetch_nws_gridpoint_forecast(
    *,
    office: str | None = None,
    grid_x: int | None = None,
    grid_y: int | None = None,
    timeout: float = _DEFAULT_NWS_TIMEOUT_S,
) -> dict:
    """Fetch the live NWS gridpoint forecast (default ``fetch_fn`` implementation).

    Mirrors the 2026-07-10 NWS gridpoint spike's step 3 exactly:
    same URL shape, same descriptive ``User-Agent`` (required by NWS -- ADR
    0001 Decision 3), same ``Accept: application/geo+json``. That spike
    confirmed no 403s occur with this header on the first attempt, so no
    retry/backoff is implemented here.

    Args:
        office: NWS forecast office id. ``None`` (the default) reads
            ``[weather].office`` from ``wilted.toml``.
        grid_x: Gridpoint X coordinate. ``None`` reads ``[weather].grid_x``.
        grid_y: Gridpoint Y coordinate. ``None`` reads ``[weather].grid_y``.
        timeout: Socket timeout in seconds, matching the ``fetch.py``
            convention elsewhere in this codebase.

    Returns:
        The parsed JSON response body (``properties.periods`` is the field
        :func:`_parse_weather` reads).

    Raises:
        WeatherLocationNotConfigured: If an unsupplied coordinate is also
            absent from ``wilted.toml`` (raised before any request is made).
        urllib.error.URLError, urllib.error.HTTPError: On network/HTTP failure.
        json.JSONDecodeError: If the response body is not valid JSON.
    """
    if office is None or grid_x is None or grid_y is None:
        cfg_office, cfg_x, cfg_y = _resolve_gridpoint()
        office = cfg_office if office is None else office
        grid_x = cfg_x if grid_x is None else grid_x
        grid_y = cfg_y if grid_y is None else grid_y
    url = _NWS_FORECAST_URL_TEMPLATE.format(office=office, x=grid_x, y=grid_y)
    req = urllib.request.Request(url, method="GET")
    req.add_header("User-Agent", _NWS_USER_AGENT)
    req.add_header("Accept", _NWS_ACCEPT)
    with urllib.request.urlopen(req, timeout=timeout) as resp:  # noqa: S310 - fixed https:// NWS URL
        body = resp.read().decode("utf-8")
    return json.loads(body)


# ---------------------------------------------------------------------------
# Production TTS synth seam (A.4.1 wiring) -- the production ``synth_fn`` a
# caller injects into ``BriefingGenerator`` so ``Briefing.synth_result``
# becomes a playable, publishable audio artifact. Mirrors
# ``wilted.station_runtime.weather_monitor._default_synth_bulletin``/
# ``BulletinAudio`` exactly -- same daemon/engine synthesis discipline, same
# lazy-import-heavy-deps-only-when-actually-called
# discipline, same "encode to a temp .wav, read bytes, unlink" shape -- so
# the TUI's briefing-adoption path (``wilted.tui.WiltedApp._station_entry_from_briefing``)
# can build a ``StationEntry`` the exact same way ``WeatherMonitor._qualify``
# does for a bulletin.
# ---------------------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class BriefingAudio:
    """Synthesized briefing audio, as returned by :func:`synthesize_briefing_audio`.

    Mirrors ``wilted.station_runtime.weather_monitor.BulletinAudio`` exactly
    (same two fields, same reasoning: carrying ``duration_ms`` alongside the
    bytes avoids a second decode step just to answer "how long is this").

    Attributes:
        audio_bytes: The encoded audio file's bytes (WAV, via
            ``mlx_audio.audio_io.write``).
        duration_ms: Playback duration in milliseconds.
    """

    audio_bytes: bytes
    duration_ms: int


def synthesize_briefing_audio(
    text: str,
    *,
    engine: AudioEngine | None = None,
) -> BriefingAudio:
    """Real TTS synth via the resident speech daemon.

    This is the production ``synth_fn`` seam a caller injects into
    :meth:`BriefingGenerator.generate` (via ``BriefingGenerator(synth_fn=
    synthesize_briefing_audio)``) so ``Briefing.synth_result`` becomes a
    :class:`BriefingAudio` rather than a raw numpy array -- the shape
    ``wilted.tui.WiltedApp._station_entry_from_briefing`` needs to publish a
    playable bulletin ``StationEntry``, exactly like
    ``WeatherMonitor._qualify`` does for a weather bulletin.

    Lazy-imports ``mlx_audio``/``AudioEngine`` so
    importing this module never requires those (heavy, optional-at-import)
    dependencies -- only the production launch path ever calls this; every
    test injects its own fake ``synth_fn`` instead.

    Args:
        text: The briefing script to synthesize.
        engine: Optional shared ``AudioEngine`` (constructed if omitted).
    """
    import tempfile
    from pathlib import Path

    from mlx_audio.audio_io import write as _audio_write

    resolved_engine = engine if engine is not None else AudioEngine()
    audio_np = resolved_engine.generate_audio(text)
    duration_ms = round(len(audio_np) / resolved_engine.sample_rate * 1000)

    fd, tmp_name = tempfile.mkstemp(suffix=".wav")
    os.close(fd)
    tmp_path = Path(tmp_name)
    try:
        _audio_write(str(tmp_path), audio_np, resolved_engine.sample_rate)
        audio_bytes = tmp_path.read_bytes()
    finally:
        tmp_path.unlink(missing_ok=True)

    return BriefingAudio(audio_bytes=audio_bytes, duration_ms=duration_ms)


@dataclass(frozen=True)
class WeatherSnapshot:
    """A frozen summary of one NWS gridpoint-forecast period.

    Only the first period in the payload (the current/next applicable
    period, e.g. "Tonight" or "Saturday" -- see the spike's step 3 table) is
    kept; the briefing is a short "right now" summary, not a multi-day
    outlook.
    """

    period_name: str | None
    short_forecast: str
    temperature: float | None
    temperature_unit: str | None
    raw: dict = field(default_factory=dict, compare=False, repr=False)


def _parse_weather(payload: dict) -> WeatherSnapshot:
    """Extract a :class:`WeatherSnapshot` from a raw NWS forecast payload.

    Raises ``ValueError`` if the payload has no forecast periods -- the
    caller (:meth:`BriefingGenerator.generate`) treats that the same as any
    other fetch failure: log a warning and fall back to a "weather
    unavailable" line rather than aborting the whole briefing.
    """
    periods = payload.get("properties", {}).get("periods", [])
    if not periods:
        raise ValueError("NWS gridpoint forecast payload has no forecast periods")
    period = periods[0]
    return WeatherSnapshot(
        period_name=period.get("name"),
        short_forecast=period.get("shortForecast", ""),
        temperature=period.get("temperature"),
        temperature_unit=period.get("temperatureUnit"),
        raw=period,
    )


def _weather_line(weather: WeatherSnapshot | None) -> str:
    """Render one spoken sentence for the briefing script's weather segment."""
    if weather is None:
        return "Weather is currently unavailable."
    label = f"{weather.period_name}: " if weather.period_name else ""
    forecast = weather.short_forecast or "conditions unavailable"
    if weather.temperature is not None:
        unit = weather.temperature_unit or ""
        temp = f", around {weather.temperature}{unit}".rstrip()
    else:
        temp = ""
    return f"{label}{forecast}{temp}."


# ---------------------------------------------------------------------------
# Stable top-N snapshot (CR-13)
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class BriefingItem:
    """One frozen top-N news entry snapshotted into a :class:`Briefing`.

    Plain, copied data -- never a live reference to the originating ``Item``
    row -- so a later classification/ranking change to that row cannot alter
    an already-generated briefing (CR-13).
    """

    item_id: str
    title: str
    summary: str | None
    source_name: str | None
    relevance_score: float | None
    playlist: str | None


def _select_top_n(n: int) -> tuple[BriefingItem, ...]:
    """Snapshot the current top-N classified items, ranked like ``report.py``.

    Mirrors the exact filter/sort ``report.py``'s ``run_report``/``get_report``
    use for their relevance ranking (orthogonal report-candidate cohort —
    ``analysis=ready``, ``preparation=not_queued``, ``retention=active``,
    ``relevance_score`` descending with NULLs last), rather than depending on
    a persisted ``Report`` row: ``Report`` is a separate, date-scoped
    nightly-digest concept that may not exist yet when the station starts
    (nothing here should have to call ``run_report()`` as a side effect just
    to read the briefing's item set). This function is
    called EXACTLY ONCE per :meth:`BriefingGenerator.generate` call -- the
    returned tuple is copied plain data, not a live queryset, which is what
    gives the briefing its CR-13 stability once embedded in a ``Briefing``.
    """
    classified = items_for_report()
    return tuple(
        BriefingItem(
            item_id=str(item.id),
            title=item.title,
            summary=item.summary,
            source_name=item.source_name,
            relevance_score=item.relevance_score,
            playlist=item.playlist_assigned,
        )
        for item in classified[:n]
    )


def _item_line(item: BriefingItem) -> str:
    """Render one spoken line for a single briefing news item."""
    if item.summary:
        return f"{item.title}. {item.summary}"
    return item.title


def _word_count(text: str) -> int:
    return len(text.split())


def _estimate_duration_s(word_count: int) -> float:
    """Estimate spoken duration using the same WPM constant as the rest of the app."""
    return (word_count / WPM_ESTIMATE) * 60.0


def _assemble_script(
    weather: WeatherSnapshot | None,
    candidates: Sequence[BriefingItem],
    *,
    max_duration_s: float,
) -> tuple[str, tuple[BriefingItem, ...]]:
    """Build the briefing script text, keeping it within ``max_duration_s``.

    The weather line always goes in first. News items are then appended
    in ``candidates`` order (already relevance-ranked by :func:`_select_top_n`)
    as long as doing so keeps the running word count under the budget implied
    by ``max_duration_s`` and ``wilted.WPM_ESTIMATE``. This is the ONLY
    truncation point: once an item would push the script over budget, that
    item and everything after it (lower-ranked) is dropped, not re-ordered.

    Returns:
        ``(script_text, items_actually_included)`` -- the latter becomes
        ``Briefing.items``, i.e. the stable snapshot reflects exactly what
        made it into the synthesized script, not the full ``top_n`` request.
    """
    max_words = max(1, round(max_duration_s / 60.0 * WPM_ESTIMATE))

    lines = [_weather_line(weather)]
    word_count = _word_count(lines[0])

    included: list[BriefingItem] = []
    for item in candidates:
        line = _item_line(item)
        line_words = _word_count(line)
        if word_count + line_words > max_words:
            break
        lines.append(line)
        included.append(item)
        word_count += line_words

    return "\n".join(lines), tuple(included)


# ---------------------------------------------------------------------------
# Briefing + generator
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class Briefing:
    """A generated, immutable station briefing.

    ``items`` is the stable snapshot actually assembled into ``script``
    (CR-13) -- nothing on this object re-queries the database, so it stays
    exactly as generated even if classification/ranking changes afterward.
    Call :meth:`is_stale` against a fresh clock reading to decide whether
    :meth:`BriefingGenerator.ensure_fresh` should regenerate.
    """

    generated_at: datetime
    max_age_s: float
    max_duration_s: float
    items: tuple[BriefingItem, ...]
    weather: WeatherSnapshot | None
    script: str
    word_count: int
    estimated_duration_s: float
    synth_result: object = field(default=None, compare=False, repr=False)
    """Whatever the ``synth_fn`` seam returned (default: daemon TTS's
    ``generate_audio`` array). Excluded from ``__eq__``/``repr`` since it may
    be a numpy array (ambiguous truth value under tuple/dataclass equality)."""

    def is_stale(self, now: datetime | None = None) -> bool:
        """Return True if this briefing is older than ``max_age_s`` as of ``now``.

        ``now`` defaults to the current UTC time; callers that need
        deterministic behavior (tests, ``ensure_fresh``) should always pass
        an explicit value -- mirrors ``EntrySequencer.build``'s
        injectable-clock convention.
        """
        resolved_now = now if now is not None else datetime.now(UTC)
        age_s = (resolved_now - self.generated_at).total_seconds()
        return age_s > self.max_age_s


@dataclass
class BriefingGenerator:
    """Configuration + regeneration policy for station briefings.

    Construct once (e.g. at controller/station startup) with the desired
    knobs, then call :meth:`ensure_fresh` before every play of the briefing
    slot: it returns the existing :class:`Briefing` unchanged if still
    fresh, or generates (and returns) a new one if ``current`` is ``None`` or
    :meth:`Briefing.is_stale`.

    Configurable knobs (plan A.4 Task 4.1 -- "≤5-min configurable briefing"
    + "generation-time + max-age"):
        max_duration_s: Script duration budget in seconds. Default 300 (5 min).
        max_age_s: How long a generated briefing stays fresh. Default 3600
            (1 hour -- matches the NWS forecast endpoint's own cache lifetime).
        top_n: How many ranked news items to request from :func:`_select_top_n`
            before the duration budget (:func:`_assemble_script`) may still
            trim further. Default 5.
    Use :meth:`from_config` to source these from ``wilted.toml``'s
    ``[briefing]`` table (mirrors ``wilted.get_default_speed()``'s
    explicit-arg > toml > builtin-default precedence) instead of the
    hard-coded defaults below.

    Injectable seams (so tests never hit the network or load a model):
        fetch_fn: Zero-arg callable returning the raw NWS forecast JSON
            payload. Defaults to :func:`fetch_nws_gridpoint_forecast` bound
            to ``nws_office``/``nws_grid_x``/``nws_grid_y`` -- each of which,
            left ``None``, is read from ``wilted.toml``'s ``[weather]`` table
            (:func:`_resolve_gridpoint`); there is no built-in location.
        synth_fn: One-arg callable ``(script_text) -> result``. Defaults to
            resident-daemon TTS through ``engine`` (constructed lazily -- see
            :meth:`_default_synth_fn`).
    """

    max_duration_s: float = _DEFAULT_MAX_DURATION_S
    max_age_s: float = _DEFAULT_MAX_AGE_S
    top_n: int = _DEFAULT_TOP_N

    nws_office: str | None = None
    nws_grid_x: int | None = None
    nws_grid_y: int | None = None

    voice: str | None = None
    lang: str | None = None
    speed: float | None = None

    fetch_fn: Callable[[], dict] | None = None
    synth_fn: Callable[[str], object] | None = None

    # Only consulted by the DEFAULT synth_fn (i.e. when synth_fn is None).
    # Injectable so production code can share one engine configuration across
    # callers instead of this module constructing its own.
    engine: AudioEngine | None = None

    @classmethod
    def from_config(cls, **overrides: object) -> BriefingGenerator:
        """Build a generator from ``wilted.toml``'s ``[briefing]`` table.

        Precedence is explicit-``overrides`` > ``wilted.toml`` > the builtin
        dataclass defaults -- the same precedence
        ``wilted.get_default_speed()`` uses for ``[playback].speed``. Only
        ``max_duration_s``/``max_age_s``/``top_n`` are read from the
        ``[briefing]`` table here; the injectable seams and voice knobs are
        code-level concerns, not end-user config. The NWS location IS end-user
        config, but lives in its own ``[weather]`` table and is resolved on the
        fetch path (:func:`_resolve_gridpoint`), not here -- so an unconfigured
        location fails when weather is actually needed, naming the missing
        keys.

        Example ``wilted.toml``::

            [briefing]
            max_duration_s = 240
            max_age_s = 1800
            top_n = 3
        """
        toml_briefing = load_config().get("briefing", {})
        kwargs: dict[str, object] = {
            key: toml_briefing[key] for key in ("max_duration_s", "max_age_s", "top_n") if key in toml_briefing
        }
        kwargs.update(overrides)
        return cls(**kwargs)

    def _resolve_fetch_fn(self) -> Callable[[], dict]:
        if self.fetch_fn is not None:
            return self.fetch_fn
        office, grid_x, grid_y = self.nws_office, self.nws_grid_x, self.nws_grid_y
        if office is None or grid_x is None or grid_y is None:
            # Resolve EAGERLY, here: an unconfigured location must surface as
            # WeatherLocationNotConfigured, not get swallowed by generate()'s
            # weather-unavailable fallback for transient fetch failures.
            cfg_office, cfg_x, cfg_y = _resolve_gridpoint()
            office = cfg_office if office is None else office
            grid_x = cfg_x if grid_x is None else grid_x
            grid_y = cfg_y if grid_y is None else grid_y
        return lambda: fetch_nws_gridpoint_forecast(office=office, grid_x=grid_x, grid_y=grid_y)

    def _default_synth_fn(self) -> Callable[[str], object]:
        """Build the default TTS synth seam with the resident speech daemon.

        Constructs ``AudioEngine()`` lazily -- only
        when this is actually reached, i.e. only when the caller did NOT
        supply their own ``synth_fn`` -- so tests that inject a fake never
        pay for real synthesis.
        """
        engine = self.engine if self.engine is not None else AudioEngine()
        voice, lang, speed = self.voice, self.lang, self.speed

        def _synth(text: str) -> object:
            return engine.generate_audio(text, voice=voice, lang=lang, speed=speed)

        return _synth

    def generate(self, *, now: datetime | None = None) -> Briefing:
        """Generate a fresh :class:`Briefing`: snapshot top-N + weather + synth.

        Args:
            now: The instant to record as ``Briefing.generated_at``. Defaults
                to the current UTC time; tests should pass an explicit value
                for determinism (mirrors ``EntrySequencer.build``).

        Raises:
            WeatherLocationNotConfigured: If no NWS location is configured
                (see :func:`_resolve_gridpoint`) and no ``fetch_fn`` was
                injected -- raised before synthesis, never downgraded.

        Weather-fetch failures (network error, malformed payload, no
        forecast periods) are caught and logged as a WARNING rather than
        propagated -- the briefing still generates, with a "weather
        currently unavailable" line, so a transient NWS/network hiccup can
        never be the reason the station fails to start its first program.
        """
        resolved_now = now if now is not None else datetime.now(UTC)

        candidates = _select_top_n(self.top_n)

        # Outside the try on purpose: a MISSING location is a configuration
        # error the operator must see (WeatherLocationNotConfigured), not a
        # transient fetch failure to be downgraded to "weather unavailable".
        fetch_fn = self._resolve_fetch_fn()

        weather: WeatherSnapshot | None
        try:
            payload = fetch_fn()
            weather = _parse_weather(payload)
        except Exception:
            logger.warning(
                "NWS gridpoint forecast fetch failed; briefing will report weather unavailable",
                exc_info=True,
            )
            weather = None

        script, included_items = _assemble_script(weather, candidates, max_duration_s=self.max_duration_s)
        word_count = _word_count(script)
        estimated_duration_s = _estimate_duration_s(word_count)

        synth = self.synth_fn if self.synth_fn is not None else self._default_synth_fn()
        synth_result = synth(script)

        briefing = Briefing(
            generated_at=resolved_now,
            max_age_s=self.max_age_s,
            max_duration_s=self.max_duration_s,
            items=included_items,
            weather=weather,
            script=script,
            word_count=word_count,
            estimated_duration_s=estimated_duration_s,
            synth_result=synth_result,
        )
        logger.info(
            "generated briefing: %d item(s), %d words (~%.0fs), weather=%s",
            len(included_items),
            word_count,
            estimated_duration_s,
            "ok" if weather is not None else "unavailable",
        )
        return briefing

    def ensure_fresh(self, current: Briefing | None, *, now: datetime | None = None) -> Briefing:
        """Return ``current`` unchanged if still fresh, else :meth:`generate` a new one.

        This is the "regenerate-if-stale" path: callers hold onto the
        returned ``Briefing`` and pass it back in on the next check rather
        than calling :meth:`generate` unconditionally, so a fresh briefing is
        never resynthesized just because playback is about to start.
        """
        resolved_now = now if now is not None else datetime.now(UTC)
        if current is not None and not current.is_stale(resolved_now):
            return current
        return self.generate(now=resolved_now)
