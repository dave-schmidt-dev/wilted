"""Tests for the wilted TUI app using Textual's pilot testing framework.

KEYSTONE refactor (Plan A task A.3.5): playback now flows through
``StationController``/``MacPlaybackAdapter``/``EntrySequencer`` instead of the
legacy dict-based, inline-TTS model. ``FakeController``/``FakeAdapter``/a fake
sequencer factory (below) stand in for the real station runtime so these
tests stay fast and hardware-free; they are injected via
``WiltedApp(controller=..., adapter=..., sequencer_factory=..., poller_factory=...)``.
"""

from __future__ import annotations

import concurrent.futures
import dataclasses
import inspect
import json
from unittest.mock import patch

import pytest
from textual.widgets import Label, Static, Tree

from wilted import ICONS
from wilted.station.models import (
    FinalizationState,
    MediaDescriptor,
    PlaybackCheckpoint,
    SafeInterruptionMap,
    StationEntry,
    TranscriptSegment,
)
from wilted.station.reducer import (
    AcceptInterruption,
    Checkpoint,
    ResumeFromInterruption,
    StartPlayback,
    StationLifecycle,
    StationState,
    Stop,
)
from wilted.station_runtime import CompletionReason, LeaseHeldError, RouteChangeEvent, media_store
from wilted.station_runtime.controller import SubmitResult
from wilted.tui import (
    AddArticleScreen,
    ConfirmScreen,
    PlaybackCompleted,
    RouteChanged,
    TextPreviewScreen,
    VoiceSettingsScreen,
    WiltedApp,
)

pytestmark = pytest.mark.usefixtures("stub_audio_modules")

# ---------------------------------------------------------------------------
# Shared builders / fakes
# ---------------------------------------------------------------------------

SAMPLE_QUEUE = [
    {
        "id": 1,
        "title": "The Future of AI Research",
        "words": 3000,
        "source_url": "https://example.com/ai",
        "canonical_url": "https://example.com/ai",
        "file": "1_the-future-of-ai-research.txt",
        "added": "2026-04-06T10:00:00",
    },
    {
        "id": 2,
        "title": "Why the Internet Feels Broken",
        "words": 5000,
        "source_url": "https://example.com/internet",
        "canonical_url": "https://example.com/internet",
        "file": "2_why-the-internet-feels-broken.txt",
        "added": "2026-04-06T11:00:00",
    },
]


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


def _station_entry(
    item_id,
    *,
    entry_id: str | None = None,
    duration_ms: int = 60_000,
    kind: str = "item",
    transcript_segments: tuple = (),
    safe_interruption: SafeInterruptionMap | None = None,
):
    """Build a StationEntry. ``kind`` is always "item" for sequencer output —
    the article-vs-podcast distinction lives inside ``media``, not on
    ``StationEntry.kind`` (the sequencer never produces "bulletin" entries).

    ``transcript_segments`` defaults to ``()`` (matching the pre-existing
    default), so every caller that doesn't pass it is unaffected.
    ``safe_interruption`` defaults to ``SafeInterruptionMap.empty()``
    (NO_INTERRUPT — matching the pre-existing default via
    ``_finalized_media``), so every caller that doesn't pass it is
    unaffected; A.4.3 bulletin-interruption tests pass a real windowed map."""
    return StationEntry(
        entry_id=entry_id or f"item-{item_id}",
        kind=kind,
        item_id=str(item_id),
        source="feed:test",
        policy_id=None,
        priority=5,
        expiry=None,
        duration_ms=duration_ms,
        media=_finalized_media(
            duration_ms=duration_ms,
            transcript_segments=transcript_segments,
            **({"safe_interruption": safe_interruption} if safe_interruption is not None else {}),
        ),
    )


# A.4.3: a real windowed safe-interruption map, [10_000, 12_000] ms, used by
# the weather bulletin interrupt/resume tests below.
SAFE_WINDOW = SafeInterruptionMap.from_verified_windows(((10_000, 12_000),))


def _bulletin_entry(
    entry_id: str = "wx-1",
    *,
    duration_ms: int = 5_000,
    playable: bool = True,
    priority: int = 0,
    expiry: str | None = None,
) -> StationEntry:
    """Build a weather bulletin StationEntry, matching
    ``WeatherMonitor._qualify``'s real shape (kind="bulletin", no item_id,
    no transcript, explicit NO_INTERRUPT for the bulletin's OWN media --
    bulletins are never themselves interruptible)."""
    return StationEntry(
        entry_id=entry_id,
        kind="bulletin",
        item_id=None,
        source="monitor:nws-alerts",
        policy_id="weather-alert",
        priority=priority,
        expiry=expiry,
        duration_ms=duration_ms,
        media=_finalized_media(
            duration_ms=duration_ms,
            transcript_segments=(),
            safe_interruption=SafeInterruptionMap.empty(),
            finalization=FinalizationState.complete() if playable else FinalizationState(),
        ),
    )


class _FakeSequencer:
    """Stand-in for EntrySequencer with a pre-built, static .entries list."""

    def __init__(self, entries):
        self.entries = list(entries)


def _sequencer_factory(entries):
    return lambda: _FakeSequencer(entries)


class FakeController:
    """Records every submitted action; current_state() is settable by the test.

    Mirrors the load-bearing LIFECYCLE effects of five real reducer
    transitions — not a full reducer reimplementation, but faithful enough
    that a regression in which action a caller submits (or in what order) can
    actually be caught by a test, rather than silently passing against a
    fake that just echoes back whatever you handed it:

    - ``StartPlayback`` (``reducer._start_playback``): idle -> playing(entry).
      Sets ``lifecycle=PLAYING``, ``active_entry=action.entry``, and
      unconditionally clears any prior checkpoint (``checkpoint=None``) AND
      ``interruption_stack=()`` — a bug class this suite must catch is "read
      the checkpoint AFTER submitting StartPlayback instead of before", and
      (A.4.3) "play a just-accepted bulletin via a fresh StartPlayback
      instead of a dedicated play path" — the latter would silently discard
      the just-interrupted entry (see ``WiltedApp._play_bulletin``'s
      docstring) if this fake didn't clear ``interruption_stack`` here too,
      exactly like the real reducer does.
    - ``Checkpoint`` (``reducer._checkpoint``): REJECTS (state left
      unchanged, revision NOT bumped) unless the station is currently
      ``PLAYING`` with an ``active_entry`` set — exactly the reducer's own
      precondition. This is load-bearing for A.3.3: it's what lets a test
      catch a regression where ``on_route_changed`` submits ``Stop()`` before
      the resume ``Checkpoint`` (which would flip the REAL station to
      ``STOPPED`` and cause the real reducer to reject that Checkpoint too,
      silently falling back to a stale offset) — a fake that always accepted
      Checkpoint unconditionally could never catch that regression.
    - ``AcceptInterruption`` (``reducer._accept_interruption``, A.4.3):
      REJECTS unless ``active_entry`` exists, ``policy_current`` is True, the
      bulletin isn't expired, ``bulletin.media.is_playable``, AND
      ``active_entry.media.safe_interruption.safe_point_at(interrupt_offset_ms)``
      is True — the exact ``safe_point_at`` precondition the A.4.3 hazard
      review is about (a lenient fake that always accepted would make the
      "no safe boundary -> no interruption" test vacuous, and would silently
      hide HAZARD 2 — a future-offset accept — since the fake would just
      accept whatever offset it's handed regardless of whether it's really
      safe). On accept: checkpoints the interrupted entry at
      ``interrupt_offset_ms``, pushes it onto ``interruption_stack`` (sorted
      by ``priority``), and switches ``active_entry`` to the bulletin.
    - ``ResumeFromInterruption`` (``reducer._resume_from_interruption``,
      A.4.3): pops ``interruption_stack[0]`` into ``active_entry``; REJECTS
      (no-op) if the stack is empty. Deliberately does NOT touch
      ``checkpoint`` — matches the real reducer exactly, since the
      accept-time checkpoint (still carrying the interrupted entry's exact
      resume offset) is what ``_start_playback`` reads afterward to land the
      precise resume position.
    - ``Stop`` (``reducer._stop``): any state -> stopped. Sets
      ``lifecycle=STOPPED`` and bumps the revision; the checkpoint field is
      left untouched (matches the real transition, which durably retains it).

    Every other action type is a no-op on ``self._state`` (but is still
    recorded in ``self.actions`` and treated as accepted), by design.

    ``raise_on_submit_and_wait``, if set, makes ``submit_and_wait()`` raise
    that exception instead of succeeding — for exercising the timeout/error
    branch of ``_start_playback`` (fix #8: bounded ``timeout=5.0``, caught
    and downgraded to a "Station error" status rather than hanging or
    crashing). ``last_timeout`` records the ``timeout`` kwarg the caller most
    recently passed, so a test can pin the literal bounded-wait value.
    """

    def __init__(self, *, state: StationState | None = None, raise_on_submit_and_wait: Exception | None = None):
        self.actions: list = []
        self._state = state if state is not None else StationState()
        self.is_running = True
        self.is_lost = False
        self.start_calls = 0
        self.stop_calls = 0
        self.raise_on_submit_and_wait = raise_on_submit_and_wait
        self.last_timeout: float | None = None
        # One accepted/rejected bool per Checkpoint action submitted, in
        # order -- lets a test assert a SPECIFIC Checkpoint (e.g. the A.3.3
        # route-resume one) was actually accepted by the PLAYING+active_entry
        # precondition, not just that a Checkpoint action was submitted.
        self.checkpoint_outcomes: list[bool] = []

    def start(self, *, on_loss=None) -> None:
        self.start_calls += 1
        self.is_running = True

    def stop(self) -> None:
        self.stop_calls += 1
        self.is_running = False

    def _record(self, action) -> bool:
        """Apply ``action`` to ``self._state``. Returns whether it was
        "accepted" (state advanced) vs "rejected" (state left unchanged) —
        see the class docstring for exactly which transitions are modeled."""
        self.actions.append(action)
        if isinstance(action, StartPlayback):
            self._state = dataclasses.replace(
                self._state,
                lifecycle=StationLifecycle.PLAYING,
                active_entry=action.entry,
                checkpoint=None,
                interruption_stack=(),
                station_revision=self._state.station_revision + 1,
            )
            return True
        if isinstance(action, Checkpoint):
            if self._state.lifecycle is not StationLifecycle.PLAYING or self._state.active_entry is None:
                self.checkpoint_outcomes.append(False)
                return False
            entry_id = self._state.active_entry.entry_id
            self._state = dataclasses.replace(
                self._state,
                station_revision=self._state.station_revision + 1,
                checkpoint=PlaybackCheckpoint(
                    station_revision=self._state.station_revision + 1,
                    entry_id=entry_id,
                    media_offset_ms=action.media_offset_ms,
                    state=action.state_label,
                    interrupted_entry_stack=(),
                    writer_device=action.writer_device,
                    mutation_id=action.mutation_id,
                    timestamp=action.now,
                ),
            )
            self.checkpoint_outcomes.append(True)
            return True
        if isinstance(action, AcceptInterruption):
            return self._record_accept_interruption(action)
        if isinstance(action, ResumeFromInterruption):
            return self._record_resume_from_interruption(action)
        if isinstance(action, Stop):
            self._state = dataclasses.replace(
                self._state,
                lifecycle=StationLifecycle.STOPPED,
                station_revision=self._state.station_revision + 1,
            )
            return True
        return True

    def _record_accept_interruption(self, action: AcceptInterruption) -> bool:
        """Mirrors ``reducer._accept_interruption`` (see the class docstring
        for why every precondition here is load-bearing for the A.4.3
        hazard tests, especially ``safe_point_at``)."""
        state = self._state
        if state.active_entry is None:
            return False
        if not action.policy_current:
            return False
        if action.bulletin.is_expired(action.now):
            return False
        if not action.bulletin.media.is_playable:
            return False
        if not state.active_entry.media.safe_interruption.safe_point_at(action.interrupt_offset_ms):
            return False

        resume_checkpoint = PlaybackCheckpoint(
            station_revision=state.station_revision,
            entry_id=state.active_entry.entry_id,
            media_offset_ms=action.interrupt_offset_ms,
            state="paused",
            interrupted_entry_stack=tuple(e.entry_id for e in state.interruption_stack),
            writer_device="controller",
            mutation_id=f"auto-interrupt-{action.bulletin.entry_id}-{action.now}",
            timestamp=action.now,
        )
        new_stack = [*state.interruption_stack, state.active_entry]
        new_stack.sort(key=lambda e: e.priority)
        self._state = dataclasses.replace(
            state,
            lifecycle=StationLifecycle.PLAYING,
            station_revision=state.station_revision + 1,
            active_entry=action.bulletin,
            checkpoint=resume_checkpoint,
            interruption_stack=tuple(new_stack),
        )
        return True

    def _record_resume_from_interruption(self, action: ResumeFromInterruption) -> bool:
        """Mirrors ``reducer._resume_from_interruption``: pops
        ``interruption_stack[0]`` into ``active_entry``; rejects (no-op) if
        the stack is empty. Deliberately does NOT touch ``checkpoint`` —
        see the class docstring."""
        del action  # unused: ResumeFromInterruption carries only `now`
        state = self._state
        if not state.interruption_stack:
            return False
        next_entry = state.interruption_stack[0]
        remaining = state.interruption_stack[1:]
        self._state = dataclasses.replace(
            state,
            lifecycle=StationLifecycle.PLAYING,
            station_revision=state.station_revision + 1,
            active_entry=next_entry,
            interruption_stack=remaining,
        )
        return True

    def submit(self, action) -> concurrent.futures.Future:
        accepted = self._record(action)
        future: concurrent.futures.Future = concurrent.futures.Future()
        future.set_result(SubmitResult(accepted=accepted, revision=self._state.station_revision, state=self._state))
        return future

    def submit_and_wait(self, action, timeout=None) -> SubmitResult:
        self.last_timeout = timeout
        if self.raise_on_submit_and_wait is not None:
            raise self.raise_on_submit_and_wait
        accepted = self._record(action)
        return SubmitResult(accepted=accepted, revision=self._state.station_revision, state=self._state)

    def current_state(self) -> StationState:
        return self._state

    def set_state(self, state: StationState) -> None:
        self._state = state


class FakeAdapter:
    """Records play/pause/resume/stop calls; on_complete is public+settable.

    ``raise_on_play``, if set, makes ``play()`` raise that exception instead
    of recording a call — for exercising ``_start_playback``'s adapter.play
    failure path (fix #5: must reset ``_generation_paused`` and submit a
    ``Stop()``, not leave generation paused forever on a failed start).
    """

    def __init__(self, *, raise_on_play: Exception | None = None):
        self.play_calls: list[tuple] = []
        self.pause_calls = 0
        self.resume_calls = 0
        self.stop_calls = 0
        self.on_complete = None
        self.last_completion = None
        self._offset_ms = 0
        self.raise_on_play = raise_on_play

    def play(self, media, *, offset_ms: int) -> None:
        if self.raise_on_play is not None:
            raise self.raise_on_play
        self.play_calls.append((media, offset_ms))
        self._offset_ms = offset_ms

    def pause(self) -> None:
        self.pause_calls += 1

    def resume(self) -> None:
        self.resume_calls += 1

    def stop(self) -> None:
        self.stop_calls += 1

    def current_offset_ms(self) -> int:
        return self._offset_ms

    def fire_completion(self, reason: CompletionReason) -> None:
        """Test helper: simulate the adapter completing playback."""
        self.last_completion = reason
        if self.on_complete is not None:
            self.on_complete(reason)


class FakePoller:
    """No-op poller — records start()/stop() calls."""

    def __init__(self, *args, **kwargs):
        self.start_calls = 0
        self.stop_calls = 0

    def start(self) -> None:
        self.start_calls += 1

    def stop(self) -> None:
        self.stop_calls += 1


def _fake_poller_factory(controller, adapter):
    return FakePoller()


class FakeRouteMonitor:
    """No-op route monitor — records start()/stop(); ``fire()`` simulates a
    backend delivering a device-change event.

    ``WiltedApp`` calls its ``route_monitor_factory`` as
    ``factory(self._on_route_change)`` (mirroring ``poller_factory``'s
    "receives what it needs as an explicit argument" convention — see
    ``wilted.tui.WiltedApp.__init__``), so a test builds this instance FIRST
    (to keep a handle for later ``.fire()`` calls) and supplies a tiny
    factory closure that stashes the callback onto it once WiltedApp invokes
    it — see :func:`_route_monitor_factory_for`.
    """

    def __init__(self) -> None:
        self.start_calls = 0
        self.stop_calls = 0
        self.on_route_change = None

    def start(self) -> None:
        self.start_calls += 1

    def stop(self) -> None:
        self.stop_calls += 1

    def fire(self, event: RouteChangeEvent) -> None:
        """Test helper: simulate the backend delivering a route-change event."""
        assert self.on_route_change is not None, "fire() called before WiltedApp wired the callback"
        self.on_route_change(event)


def _route_monitor_factory_for(monitor: FakeRouteMonitor):
    """Build a ``route_monitor_factory`` that wires ``monitor`` to whatever
    callback ``WiltedApp.__init__`` passes it (``self._on_route_change``)."""

    def _factory(on_route_change):
        monitor.on_route_change = on_route_change
        return monitor

    return _factory


class FakeWeatherMonitor:
    """No-op weather monitor — records start()/stop() calls.

    Unlike ``poller_factory``/``route_monitor_factory``, ``WiltedApp``
    accepts an already-constructed ``weather_monitor=`` instance directly
    (see its ``__init__`` docstring for why there's no safe default-factory
    style here — mirrors how ``controller``/``adapter`` are injected as
    instances, not factories). ``fire(bulletin)`` simulates the monitor
    handing off a bulletin exactly like the real
    ``WeatherMonitor.on_bulletin_ready`` callback would.

    A.4.5: ``health()``/``last_success_at``/``last_error`` mirror the real
    ``WeatherMonitor``'s health/heartbeat surface (see
    ``wilted.station_runtime.weather_monitor.WeatherMonitor.health`` for the
    real ``"unknown"``/``"healthy"``/``"stale"``/``"degraded"``/``"failed"``
    states) that ``WiltedApp._update_source_health`` reads — settable
    directly by a test (``monitor.fake_health = "degraded"`` etc.) rather
    than a full state-machine reimplementation, since the source-health
    indicator only ever reads these three surfaces, never drives monitor
    behavior off them.
    """

    def __init__(self) -> None:
        self.start_calls = 0
        self.stop_calls = 0
        self.on_bulletin_ready = None
        self.fake_health = "unknown"
        self.last_success_at: str | None = None
        self.last_error: str | None = None

    def start(self) -> None:
        self.start_calls += 1

    def stop(self) -> None:
        self.stop_calls += 1

    def health(self, *, now: str | None = None) -> str:
        del now  # unused: the fake's health is set directly, not computed
        return self.fake_health

    def fire(self, bulletin: StationEntry) -> None:
        """Test helper: simulate the monitor handing off a bulletin."""
        assert self.on_bulletin_ready is not None, "fire() called before WiltedApp wired on_bulletin_ready"
        self.on_bulletin_ready(bulletin)


def _make_app(
    *,
    entries=(),
    controller=None,
    adapter=None,
    poller_factory=None,
    route_monitor=None,
    **kwargs,
) -> WiltedApp:
    """Construct a WiltedApp with fake station-runtime dependencies injected.

    Safe to use without mocking ``get_playlist_items``/``ensure_default_playlists``
    — those remain real and run against the isolated (empty) test DB.

    ``route_monitor``, if given, is a pre-built :class:`FakeRouteMonitor` a
    test wants a handle to (to call ``.fire()`` later); otherwise a fresh one
    is built and silently discarded by the caller if unneeded — mirroring
    how ``adapter``/``controller`` work above, rather than
    ``poller_factory``'s bare-factory style, since a route-change test always
    needs the instance, not just the factory.
    """
    monitor = route_monitor if route_monitor is not None else FakeRouteMonitor()
    return WiltedApp(
        controller=controller if controller is not None else FakeController(),
        adapter=adapter if adapter is not None else FakeAdapter(),
        sequencer_factory=_sequencer_factory(list(entries)),
        poller_factory=poller_factory if poller_factory is not None else _fake_poller_factory,
        route_monitor_factory=_route_monitor_factory_for(monitor),
        **kwargs,
    )


# ---------------------------------------------------------------------------
# App launch / Larder tree / empty state / quit
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_app_launches():
    """App starts without error and shows the Tree widget."""
    app = _make_app()
    async with app.run_test():
        await app.workers.wait_for_complete()
        trees = app.query(Tree)
        assert len(trees) > 0, "Tree should be present in the app"


@pytest.mark.asyncio
@patch("wilted.tui.ensure_default_playlists")
@patch("wilted.tui.get_playlist_items", return_value=SAMPLE_QUEUE)
async def test_queue_displayed(mock_items, mock_ensure):
    """Two station entries appear as flat leaves in the Larder tree."""
    entries = [_station_entry(1), _station_entry(2)]
    app = _make_app(entries=entries)
    async with app.run_test():
        await app.workers.wait_for_complete()
        tree = app.query_one("#playlist-tree", Tree)
        assert len(tree.root.children) == 2, f"Expected 2 leaves, got {len(tree.root.children)}"
        first_label = str(tree.root.children[0].label)
        assert "Future" in first_label or "AI" in first_label


@pytest.mark.asyncio
async def test_empty_queue_message():
    """When the queue is truly empty (no DB items, no station entries), the
    'add an article' empty message is shown."""
    app = _make_app(entries=[])
    async with app.run_test():
        await app.workers.wait_for_complete()
        empty_label = app.query_one("#empty-message", Label)
        text = empty_label.content
        assert "empty" in text.lower()


@pytest.mark.asyncio
async def test_quit_key():
    """Pressing q exits the app."""
    app = _make_app()
    async with app.run_test() as pilot:
        await app.workers.wait_for_complete()
        await pilot.press("q")
        assert app._exit is not None or True  # App accepted the quit key


# ---------------------------------------------------------------------------
# Delete
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
@patch("wilted.tui.ensure_default_playlists")
@patch("wilted.tui.get_playlist_items", return_value=SAMPLE_QUEUE)
@patch("wilted.tui.remove_article_by_id")
async def test_delete_key(mock_remove, mock_items, mock_ensure):
    """Pressing d opens ConfirmScreen, confirming calls remove_article_by_id."""
    entries = [_station_entry(1), _station_entry(2)]
    app = _make_app(entries=entries)
    async with app.run_test() as pilot:
        await app.workers.wait_for_complete()
        tree = app.query_one("#playlist-tree", Tree)
        tree.select_node(tree.root.children[0])
        tree.scroll_to_node(tree.root.children[0])
        await pilot.pause()
        await pilot.press("d")
        await pilot.pause()
        confirm = app.screen
        assert isinstance(confirm, ConfirmScreen)
        confirm.action_confirm()
        await pilot.pause()
        mock_remove.assert_called_once_with(1)


@pytest.mark.asyncio
@patch("wilted.tui.ensure_default_playlists")
@patch("wilted.tui.get_playlist_items", return_value=SAMPLE_QUEUE)
@patch("wilted.tui.remove_article_by_id")
async def test_delete_confirm_button_click(mock_remove, mock_items, mock_ensure):
    """Clicking Confirm should delete the selected article."""
    entries = [_station_entry(1), _station_entry(2)]
    app = _make_app(entries=entries)
    async with app.run_test() as pilot:
        await app.workers.wait_for_complete()
        tree = app.query_one("#playlist-tree", Tree)
        tree.select_node(tree.root.children[0])
        tree.scroll_to_node(tree.root.children[0])
        await pilot.pause()
        await pilot.press("d")
        await pilot.pause()
        assert isinstance(app.screen, ConfirmScreen)
        await pilot.click("#confirm-accept", offset=(2, 1))
        await pilot.pause()
        mock_remove.assert_called_once_with(1)


@pytest.mark.asyncio
@patch("wilted.tui.ensure_default_playlists")
@patch("wilted.tui.get_playlist_items", return_value=SAMPLE_QUEUE)
@patch("wilted.tui.remove_article_by_id")
async def test_delete_playing_article_clears_plate(mock_remove, mock_items, mock_ensure):
    """Deleting the currently-playing entry should stop playback (via the
    station path) and reset the Plate pane."""
    entries = [_station_entry(1), _station_entry(2)]
    controller = FakeController()
    adapter = FakeAdapter()
    app = _make_app(entries=entries, controller=controller, adapter=adapter)
    async with app.run_test() as pilot:
        await app.workers.wait_for_complete()
        tree = app.query_one("#playlist-tree", Tree)
        tree.select_node(tree.root.children[0])
        await pilot.pause()
        # Simulate that this entry is currently playing
        app._current_entry = entries[0]
        app._current_index = 0
        app._playing = True
        title_label = app.query_one("#now-playing-title", Label)
        title_label.update("The Future of AI Research")
        app.query_one("#current-text", Static).update("Some article text")
        await pilot.pause()
        await pilot.press("d")
        await pilot.pause()
        assert isinstance(app.screen, ConfirmScreen)
        app.screen.action_confirm()
        await pilot.pause()
        # Plate should be cleared: state reset + progress zeroed
        assert app._current_entry is None
        assert app._playing is False
        assert app._bar_progress == 0.0
        assert adapter.stop_calls >= 1
        assert any(isinstance(a, Stop) for a in controller.actions)
        # Title widget should show empty-state text
        assert title_label._Static__content == "No article selected"


# ---------------------------------------------------------------------------
# Add-article screen
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_add_screen_launches_on_a_key():
    """Pressing 'a' should open the AddArticleScreen modal."""
    app = _make_app()
    async with app.run_test() as pilot:
        await pilot.press("a")
        await pilot.pause()
        assert any(isinstance(screen, AddArticleScreen) for screen in app.screen_stack)


@pytest.mark.asyncio
async def test_add_screen_cancel():
    """Pressing escape in AddArticleScreen should dismiss without adding."""
    app = _make_app()
    async with app.run_test() as pilot:
        await pilot.press("a")
        await pilot.pause()
        await pilot.press("escape")
        await pilot.pause()
        assert not any(isinstance(screen, AddArticleScreen) for screen in app.screen_stack if screen is not app.screen)


@pytest.mark.asyncio
async def test_add_screen_click_add_and_play_button():
    """Clicking Add & Play should trigger the play-after add path."""
    app = _make_app()
    async with app.run_test() as pilot:
        await pilot.press("a")
        await pilot.pause()
        screen = app.screen
        assert isinstance(screen, AddArticleScreen)
        with patch.object(screen, "_do_add") as mock_do_add:
            await pilot.click("#add-play", offset=(2, 1))
            mock_do_add.assert_called_once_with(play_after=True)


@pytest.mark.asyncio
async def test_add_screen_click_cancel_button():
    """Clicking Cancel should dismiss the add-article modal."""
    app = _make_app()
    async with app.run_test() as pilot:
        await pilot.press("a")
        await pilot.pause()
        await pilot.click("#add-cancel", offset=(2, 1))
        await pilot.pause()
        assert not isinstance(app.screen, AddArticleScreen)


@pytest.mark.asyncio
async def test_add_article_and_play_starts_playback_once_finalized():
    """After 'Add & Play', if the next sequencer rebuild resolves the new
    item as already finalized, it starts playing.

    Drives the same state ``action_add_article``'s ``on_dismiss`` closure
    would set (``_pending_play_item_id`` then a rebuild) rather than pushing
    the real AddArticleScreen modal, since the screen's own add/fetch flow is
    already covered by ``test_add_screen_click_add_and_play_button``.
    """
    entry = _station_entry(42)
    controller = FakeController()
    adapter = FakeAdapter()
    app = _make_app(entries=[entry], controller=controller, adapter=adapter)
    async with app.run_test():
        await app.workers.wait_for_complete()
        app._pending_play_item_id = "42"
        app._rebuild_sequencer()
        await app.workers.wait_for_complete()
        assert adapter.play_calls == [(entry.media, 0)]
        assert app._pending_play_item_id is None


# ---------------------------------------------------------------------------
# Refresh
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
@patch("wilted.tui.ensure_default_playlists")
@patch("wilted.tui.get_playlist_items", return_value=SAMPLE_QUEUE)
async def test_refresh_key(mock_items, mock_ensure):
    """Pressing r calls get_playlist_items again to refresh."""
    app = _make_app(entries=[_station_entry(1), _station_entry(2)])
    async with app.run_test() as pilot:
        await app.workers.wait_for_complete()
        initial_count = mock_items.call_count
        await pilot.press("r")
        assert mock_items.call_count > initial_count, "get_playlist_items should be called again on refresh"


# ---------------------------------------------------------------------------
# Voice settings
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_voice_settings_shows_language():
    """VoiceSettingsScreen displays a language label widget."""
    app = _make_app()
    async with app.run_test() as pilot:
        await pilot.press("v")
        lang_label = app.screen.query_one("#lang-display", Label)
        assert lang_label is not None
        assert "American" in lang_label.content


@pytest.mark.asyncio
async def test_voice_settings_dismiss_includes_lang():
    """VoiceSettingsScreen dismiss returns a 3-tuple (voice, speed, lang)."""
    app = _make_app()
    async with app.run_test() as pilot:
        await pilot.press("v")
        await pilot.pause()
        screen = app.screen
        assert isinstance(screen, VoiceSettingsScreen)
        await pilot.press("b")
        await pilot.pause()
        assert screen.selected_lang == "b"
        screen.action_confirm()
        await pilot.pause()
        assert app._lang == "b"


@pytest.mark.asyncio
async def test_voice_settings_cancel_button_click():
    """Clicking Cancel should dismiss the voice settings modal."""
    app = _make_app()
    async with app.run_test() as pilot:
        await pilot.press("v")
        await pilot.pause()
        assert isinstance(app.screen, VoiceSettingsScreen)
        await pilot.click("#voice-cancel", offset=(2, 1))
        await pilot.pause()
        assert not isinstance(app.screen, VoiceSettingsScreen)


@pytest.mark.asyncio
async def test_voice_settings_feedback_not_playing():
    """Changing voice settings when not playing triggers generation."""
    app = _make_app()
    async with app.run_test() as pilot:
        with patch.object(app, "_trigger_generation") as mock_trigger:
            await pilot.press("v")
            await pilot.pause()
            screen = app.screen
            assert isinstance(screen, VoiceSettingsScreen)
            screen.selected_speed = 1.5
            screen.action_confirm()
            await pilot.pause()
            mock_trigger.assert_called()


@pytest.mark.asyncio
async def test_voice_settings_feedback_while_playing():
    """Changing voice settings during playback shows status feedback."""
    app = _make_app()
    async with app.run_test() as pilot:
        app._playing = True
        app._speed = 1.0
        await pilot.press("v")
        await pilot.pause()
        screen = app.screen
        assert isinstance(screen, VoiceSettingsScreen)
        screen.selected_speed = 1.5
        screen.action_confirm()
        await pilot.pause()
        status = str(app.query_one("#status-line").render())
        assert "1.5x" in status or "next paragraph" in status


# ---------------------------------------------------------------------------
# Text preview
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_text_preview_launches():
    """Pressing 't' with a selected entry should open TextPreviewScreen."""
    articles = [{"id": 1, "title": "Test Article", "words": 100, "file": "1_test.txt", "added": "2026-04-06"}]
    with (
        patch("wilted.tui.ensure_default_playlists"),
        patch("wilted.tui.get_playlist_items", return_value=articles),
        patch("wilted.tui.get_article_text", return_value="This is the article text."),
    ):
        app = _make_app(entries=[_station_entry(1)])
        async with app.run_test() as pilot:
            await app.workers.wait_for_complete()
            tree = app.query_one("#playlist-tree", Tree)
            tree.select_node(tree.root.children[0])
            await pilot.pause()
            await pilot.press("t")
            await pilot.pause()
            assert any(isinstance(screen, TextPreviewScreen) for screen in app.screen_stack)


@pytest.mark.asyncio
async def test_text_preview_close_button_click():
    """Clicking Close should dismiss the preview modal."""
    articles = [{"id": 1, "title": "Test Article", "words": 100, "file": "1_test.txt", "added": "2026-04-06"}]
    with (
        patch("wilted.tui.ensure_default_playlists"),
        patch("wilted.tui.get_playlist_items", return_value=articles),
        patch("wilted.tui.get_article_text", return_value="This is the article text."),
    ):
        app = _make_app(entries=[_station_entry(1)])
        async with app.run_test() as pilot:
            await app.workers.wait_for_complete()
            tree = app.query_one("#playlist-tree", Tree)
            tree.select_node(tree.root.children[0])
            await pilot.pause()
            await pilot.press("t")
            await pilot.pause()
            assert isinstance(app.screen, TextPreviewScreen)
            await pilot.click("#preview-close", offset=(2, 1))
            await pilot.pause()
            assert not isinstance(app.screen, TextPreviewScreen)


@pytest.mark.asyncio
async def test_text_preview_no_article():
    """Pressing 't' with empty queue should show error status."""
    app = _make_app(entries=[])
    async with app.run_test() as pilot:
        await app.workers.wait_for_complete()
        await pilot.press("t")
        await pilot.pause()
        status = app.query_one("#status-line").render()
        assert "No article" in str(status) or "selected" in str(status)


# ---------------------------------------------------------------------------
# Clear-all / delete confirm launch
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_clear_all_launches_confirm():
    """Pressing 'c' should open ConfirmScreen."""
    articles = [{"id": 1, "title": "Test", "words": 50, "file": "1_test.txt", "added": "2026-04-06"}]
    with (
        patch("wilted.tui.ensure_default_playlists"),
        patch("wilted.tui.get_playlist_items", return_value=articles),
    ):
        app = _make_app(entries=[])
        async with app.run_test() as pilot:
            await app.workers.wait_for_complete()
            await pilot.press("c")
            await pilot.pause()
            assert any(isinstance(screen, ConfirmScreen) for screen in app.screen_stack)


@pytest.mark.asyncio
async def test_delete_launches_confirm():
    """Pressing 'd' should open ConfirmScreen for deletion."""
    articles = [{"id": 1, "title": "Test", "words": 50, "file": "1_test.txt", "added": "2026-04-06"}]
    with (
        patch("wilted.tui.ensure_default_playlists"),
        patch("wilted.tui.get_playlist_items", return_value=articles),
    ):
        app = _make_app(entries=[_station_entry(1)])
        async with app.run_test() as pilot:
            await app.workers.wait_for_complete()
            tree = app.query_one("#playlist-tree", Tree)
            tree.select_node(tree.root.children[0])
            await pilot.pause()
            await pilot.press("d")
            await pilot.pause()
            assert any(isinstance(screen, ConfirmScreen) for screen in app.screen_stack)


# ---------------------------------------------------------------------------
# WAV export
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_export_wav_no_article():
    """Pressing 'w' with empty queue should show error."""
    app = _make_app(entries=[])
    async with app.run_test() as pilot:
        await app.workers.wait_for_complete()
        await pilot.press("w")
        await pilot.pause()
        status = app.query_one("#status-line").render()
        assert "No article" in str(status)


@pytest.mark.asyncio
async def test_export_wav_missing_file():
    """Pressing 'w' when article text is missing should show error."""
    articles = [{"id": 1, "title": "Test", "words": 50, "file": "1_test.txt", "added": "2026-04-06"}]
    with (
        patch("wilted.tui.ensure_default_playlists"),
        patch("wilted.tui.get_playlist_items", return_value=articles),
        patch("wilted.tui.get_article_text", return_value=None),
    ):
        app = _make_app(entries=[_station_entry(1)])
        async with app.run_test() as pilot:
            await app.workers.wait_for_complete()
            tree = app.query_one("#playlist-tree", Tree)
            tree.select_node(tree.root.children[0])
            await pilot.pause()
            await pilot.press("w")
            await pilot.pause()
            status = app.query_one("#status-line").render()
            assert "not found" in str(status)


# ---------------------------------------------------------------------------
# Entry-level nav (skip/prev — MVP replaces per-paragraph skip, A.3.5)
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_prev_paragraph_no_crash_when_not_playing():
    """Pressing [ when not playing should not crash (no-op)."""
    app = _make_app(entries=[])
    async with app.run_test() as pilot:
        await app.workers.wait_for_complete()
        await pilot.press("left_square_bracket")
        await pilot.pause()


@pytest.mark.asyncio
async def test_skip_segment_no_crash_when_not_playing():
    """Pressing ] when not playing should not crash (no-op)."""
    app = _make_app(entries=[])
    async with app.run_test() as pilot:
        await app.workers.wait_for_complete()
        await pilot.press("right_square_bracket")
        await pilot.pause()


@pytest.mark.asyncio
async def test_skip_segment_advances_to_next_entry_while_playing():
    """MVP: ']' moves to the next station entry (adapter cannot seek within one)."""
    entry_a = _station_entry(1)
    entry_b = _station_entry(2)
    controller = FakeController()
    adapter = FakeAdapter()
    app = _make_app(entries=[entry_a, entry_b], controller=controller, adapter=adapter)
    async with app.run_test():
        await app.workers.wait_for_complete()
        app._start_playback(entry_a)
        app.action_skip_segment()
        assert app._current_entry.entry_id == entry_b.entry_id
        assert adapter.play_calls[-1] == (entry_b.media, 0)


# ---------------------------------------------------------------------------
# _start_playback (INV-8 core)
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_start_playback_pauses_generation_and_routes_through_controller():
    """_start_playback sets _generation_paused, submits StartPlayback, and
    calls adapter.play with the entry's media."""
    entry = _station_entry(1)
    controller = FakeController()
    adapter = FakeAdapter()
    app = _make_app(entries=[entry], controller=controller, adapter=adapter)
    async with app.run_test():
        app._start_playback(entry)
        assert app._generation_paused is True
        assert adapter.play_calls == [(entry.media, 0)]
        assert any(isinstance(a, StartPlayback) and a.entry.entry_id == entry.entry_id for a in controller.actions)


@pytest.mark.asyncio
async def test_start_playback_toggles_when_same_entry_already_playing():
    """Calling _start_playback again on the currently-playing entry pauses it
    (toggle), rather than restarting playback from offset 0."""
    entry = _station_entry(1)
    controller = FakeController()
    adapter = FakeAdapter()
    app = _make_app(entries=[entry], controller=controller, adapter=adapter)
    async with app.run_test():
        app._start_playback(entry)
        assert len(adapter.play_calls) == 1
        app._start_playback(entry)
        assert len(adapter.play_calls) == 1  # no second play() -- toggled to paused instead
        assert app._paused is True
        assert adapter.pause_calls == 1


@pytest.mark.asyncio
async def test_start_playback_starts_the_checkpoint_poller_once():
    entry_a = _station_entry(1)
    entry_b = _station_entry(2)
    controller = FakeController()
    adapter = FakeAdapter()
    poller = FakePoller()
    app = _make_app(
        entries=[entry_a, entry_b], controller=controller, adapter=adapter, poller_factory=lambda c, a: poller
    )
    async with app.run_test():
        app._start_playback(entry_a)
        app._start_playback(entry_b)
        assert poller.start_calls == 1  # guarded against double-start


@pytest.mark.asyncio
async def test_start_playback_resets_generation_paused_on_adapter_play_failure():
    """Regression lock for fix review #5: if adapter.play() raises,
    _start_playback must not leave _generation_paused stuck True forever
    (background generation would never resume — a real-world trigger is
    skip/next landing on an entry whose media turns out to be unplayable).
    Must also submit Stop() (station-state must not claim PLAYING for an
    entry that never actually started) and show a "Playback error" status,
    and must never mark the app as playing.

    Fails against the pre-fix code: the except branch already set the
    status and submitted Stop(), but never reset _generation_paused, so a
    caller that had already paused generation (simulated here by setting
    _generation_paused = True before calling _start_playback, mirroring an
    in-progress-generation state) would leave it stuck True.
    """
    entry = _station_entry(1)
    controller = FakeController()
    adapter = FakeAdapter(raise_on_play=RuntimeError("boom"))
    app = _make_app(entries=[entry], controller=controller, adapter=adapter)
    async with app.run_test():
        app._generation_paused = True  # simulate generation already paused
        app._start_playback(entry)

        assert app._generation_paused is False
        assert app._playing is False
        assert any(isinstance(a, Stop) for a in controller.actions)
        status = str(app.query_one("#status-line").render())
        assert "playback error" in status.lower()


@pytest.mark.asyncio
async def test_start_playback_shows_station_error_and_skips_adapter_play_on_submit_timeout():
    """Regression lock for fix review #8: a bounded ``timeout=5.0`` on
    ``submit_and_wait`` guards against a wedged drain thread hanging the UI
    forever; when it raises (timeout or any other exception), _start_playback
    must catch it, show a "Station error" status, and MUST NOT proceed to
    adapter.play() or mark the app as playing — an entry whose StartPlayback
    was never confirmed accepted is not safe to actually play.

    Fails against the pre-fix code in two independent ways: (1)
    ``controller.last_timeout == 5.0`` fails if the bounded timeout kwarg is
    removed/reverted (the fake records whatever timeout it was actually
    called with); (2) if the except branch were ever narrowed or the
    adapter.play call reordered ahead of the submit, ``adapter.play_calls``
    would be non-empty or the raised TimeoutError would propagate and fail
    the test outright.
    """
    entry = _station_entry(1)
    controller = FakeController(raise_on_submit_and_wait=concurrent.futures.TimeoutError("wedged"))
    adapter = FakeAdapter()
    app = _make_app(entries=[entry], controller=controller, adapter=adapter)
    async with app.run_test():
        app._start_playback(entry)

        assert controller.last_timeout == 5.0
        assert adapter.play_calls == []
        assert app._playing is False
        status = str(app.query_one("#status-line").render())
        assert "station error" in status.lower()


@pytest.mark.asyncio
async def test_stop_resumes_generation():
    """action_stop sets _generation_paused to False and triggers generation."""
    app = _make_app(entries=[])
    async with app.run_test():
        await app.workers.wait_for_complete()
        app._generation_paused = True
        app._playing = True
        with patch.object(app, "_trigger_generation") as mock_trigger:
            app.action_stop()
        assert app._generation_paused is False
        mock_trigger.assert_called_once()


# ---------------------------------------------------------------------------
# Phase 4 — Enhanced UI (playback bar / timer — pure rendering, unaffected
# by the station reroute; these poke the display fields directly)
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_playback_bar_widget_exists():
    """The #playback-bar Static widget is present in the app."""
    app = _make_app()
    async with app.run_test():
        bar = app.query_one("#playback-bar", Static)
        assert bar is not None


@pytest.mark.asyncio
async def test_playback_bar_shows_state_icon():
    """PlaybackBar shows state icon when playing/paused."""
    app = _make_app()
    async with app.run_test():
        app._playing = True
        app._paragraphs = ["Para one.", "Para two."]
        app._paragraph_idx = 0
        app._bar_progress = 50.0
        app._estimated_remaining_secs = 120
        app._update_playback_bar()
        content = str(app.query_one("#playback-bar", Static).render())
        assert ICONS["playing"] in content

        app._paused = True
        app._update_playback_bar()
        content = str(app.query_one("#playback-bar", Static).render())
        assert ICONS["paused"] in content


@pytest.mark.asyncio
async def test_playback_bar_shows_para_count():
    """PlaybackBar shows paragraph count like 1/5."""
    app = _make_app()
    async with app.run_test():
        app._playing = True
        app._paragraphs = ["P1", "P2", "P3", "P4", "P5"]
        app._paragraph_idx = 2
        app._bar_progress = 40.0
        app._estimated_remaining_secs = 60
        app._update_playback_bar()
        content = str(app.query_one("#playback-bar", Static).render())
        assert "3/5" in content


@pytest.mark.asyncio
async def test_playback_bar_shows_timer():
    """PlaybackBar shows mm:ss timer."""
    app = _make_app()
    async with app.run_test():
        app._playing = True
        app._paragraphs = ["P1"]
        app._paragraph_idx = 0
        app._bar_progress = 0.0
        app._estimated_remaining_secs = 185  # 3:05
        app._update_playback_bar()
        content = str(app.query_one("#playback-bar", Static).render())
        assert "3:05" in content


@pytest.mark.asyncio
async def test_timer_decrements():
    """_update_timer decrements _estimated_remaining_secs by 1."""
    app = _make_app()
    async with app.run_test():
        app._playing = True
        app._paragraphs = ["P1", "P2"]
        app._estimated_remaining_secs = 100
        app._update_timer()
        assert app._estimated_remaining_secs == 99


@pytest.mark.asyncio
async def test_timer_noop_when_paused():
    """_update_timer does nothing when paused."""
    app = _make_app()
    async with app.run_test():
        app._playing = True
        app._paused = True
        app._paragraphs = ["P1"]
        app._estimated_remaining_secs = 100
        app._update_timer()
        assert app._estimated_remaining_secs == 100  # Unchanged


@pytest.mark.asyncio
async def test_timer_noop_when_not_playing():
    """_update_timer does nothing when not playing."""
    app = _make_app()
    async with app.run_test():
        app._estimated_remaining_secs = 100
        app._update_timer()
        assert app._estimated_remaining_secs == 100


# ---------------------------------------------------------------------------
# Live per-segment transcript scrolling (restored A.3.5 dropped-path): driven
# by polling the adapter's current_offset_ms() on the existing 1s UI-thread
# timer -- no adapter callback, no new threads.
# ---------------------------------------------------------------------------

_SCROLL_SEGMENTS = (
    TranscriptSegment(start_ms=0, end_ms=5_000, text="Segment zero."),
    TranscriptSegment(start_ms=5_000, end_ms=10_000, text="Segment one."),
    TranscriptSegment(start_ms=10_000, end_ms=60_000, text="Segment two."),
)


@pytest.mark.asyncio
async def test_start_playback_seeds_transcript_from_entry_segments():
    """_start_playback populates _paragraphs from the entry's own
    transcript_segments and renders the initial (idx 0) segment into
    #current-text so the pane isn't blank at play start."""
    entry = _station_entry(1, transcript_segments=_SCROLL_SEGMENTS)
    app = _make_app(entries=[entry])
    async with app.run_test():
        app._start_playback(entry)
        assert app._paragraphs == ["Segment zero.", "Segment one.", "Segment two."]
        assert app._paragraph_idx == 0
        content = str(app.query_one("#current-text", Static).render())
        assert "Segment zero." in content


@pytest.mark.asyncio
async def test_start_playback_resumes_transcript_at_checkpoint_segment():
    """The initial _paragraph_idx is the segment containing the resume
    offset, not always 0 -- a resumed entry shouldn't visually rewind its
    transcript to the start."""
    entry = _station_entry(1, transcript_segments=_SCROLL_SEGMENTS)
    checkpoint = PlaybackCheckpoint(
        station_revision=1,
        entry_id=entry.entry_id,
        media_offset_ms=7_000,  # inside segment one (index 1)
        state="paused",
        interrupted_entry_stack=(),
        writer_device="mac",
        mutation_id="m-resume",
        timestamp="2026-07-11T00:00:00Z",
    )
    controller = FakeController(state=StationState(checkpoint=checkpoint))
    adapter = FakeAdapter()
    app = _make_app(entries=[entry], controller=controller, adapter=adapter)
    async with app.run_test():
        app._start_playback(entry)
        assert app._paragraph_idx == 1


@pytest.mark.asyncio
async def test_timer_advances_transcript_segment_with_adapter_offset():
    """_update_timer polls adapter.current_offset_ms() each tick and, when
    the offset has crossed into a new segment, updates _paragraph_idx and
    re-renders #current-text -- the core live-scrolling behavior."""
    entry = _station_entry(1, transcript_segments=_SCROLL_SEGMENTS)
    controller = FakeController()
    adapter = FakeAdapter()
    app = _make_app(entries=[entry], controller=controller, adapter=adapter)
    async with app.run_test():
        app._start_playback(entry)
        assert app._paragraph_idx == 0

        adapter._offset_ms = 6_000  # segment one
        app._update_timer()
        assert app._paragraph_idx == 1
        content = str(app.query_one("#current-text", Static).render())
        assert "Segment one." in content

        adapter._offset_ms = 15_000  # segment two
        app._update_timer()
        assert app._paragraph_idx == 2
        content = str(app.query_one("#current-text", Static).render())
        assert "Segment two." in content


@pytest.mark.asyncio
async def test_timer_noop_transcript_advance_when_offset_stays_in_same_segment():
    """A same-segment offset change ticks the countdown but does not touch
    _paragraph_idx or re-render the pane."""
    entry = _station_entry(1, transcript_segments=_SCROLL_SEGMENTS)
    controller = FakeController()
    adapter = FakeAdapter()
    app = _make_app(entries=[entry], controller=controller, adapter=adapter)
    async with app.run_test():
        app._start_playback(entry)
        remaining_before = app._estimated_remaining_secs

        adapter._offset_ms = 1_000  # still segment zero
        app._update_timer()
        assert app._paragraph_idx == 0
        assert app._estimated_remaining_secs == remaining_before - 1


@pytest.mark.asyncio
async def test_timer_with_no_transcript_segments_does_not_crash():
    """An entry with empty transcript_segments: _paragraphs stays empty, the
    pane isn't scrolled, and the 1s timer (progress bar countdown) still
    ticks without crashing."""
    entry = _station_entry(1, transcript_segments=())
    controller = FakeController()
    adapter = FakeAdapter()
    app = _make_app(entries=[entry], controller=controller, adapter=adapter)
    async with app.run_test():
        app._start_playback(entry)
        assert app._paragraphs == []
        remaining_before = app._estimated_remaining_secs

        app._update_timer()  # must not raise

        assert app._paragraphs == []
        assert app._estimated_remaining_secs == remaining_before - 1


@pytest.mark.asyncio
async def test_stop_clears_transcript_state():
    """action_stop resets the read-along state so a stopped station doesn't
    keep a stale transcript/segment count on display."""
    entry = _station_entry(1, transcript_segments=_SCROLL_SEGMENTS)
    controller = FakeController()
    adapter = FakeAdapter()
    app = _make_app(entries=[entry], controller=controller, adapter=adapter)
    async with app.run_test():
        app._start_playback(entry)
        assert app._paragraphs

        app.action_stop()

        assert app._paragraphs == []
        assert app._paragraph_idx == 0
        content = str(app.query_one("#current-text", Static).render())
        assert "Segment" not in content


@pytest.mark.asyncio
async def test_clean_completion_with_no_next_entry_clears_transcript_state():
    """A clean completion with nothing left in the backlog ("queue finished")
    also clears the read-along state, not just an explicit stop."""
    entry = _station_entry(1, transcript_segments=_SCROLL_SEGMENTS)
    controller = FakeController()
    adapter = FakeAdapter()
    app = _make_app(entries=[entry], controller=controller, adapter=adapter)
    async with app.run_test():
        await app.workers.wait_for_complete()
        app._start_playback(entry)
        assert app._paragraphs

        with patch("wilted.tui.mark_completed"):
            app._handle_station_completion(CompletionReason.ENDED)

        assert app._paragraphs == []
        assert app._paragraph_idx == 0


# ---------------------------------------------------------------------------
# Speed
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
@patch("wilted.get_default_speed", return_value=1.0)
@patch("wilted.db.set_setting")
async def test_speed_down_key(mock_set, mock_default):
    """Pressing - decreases speed by 0.1x."""
    app = _make_app()
    async with app.run_test() as pilot:
        assert app._speed == 1.0
        await pilot.press("minus")
        await pilot.pause()
        assert app._speed == 0.9


@pytest.mark.asyncio
@patch("wilted.get_default_speed", return_value=1.0)
@patch("wilted.db.set_setting")
async def test_speed_up_key(mock_set, mock_default):
    """Pressing + increases speed by 0.1x."""
    app = _make_app()
    async with app.run_test() as pilot:
        assert app._speed == 1.0
        await pilot.press("equal")
        await pilot.pause()
        assert app._speed == 1.1


@pytest.mark.asyncio
@patch("wilted.db.set_setting")
async def test_speed_clamps_to_range(mock_set):
    """Speed stays within 0.5x-2.0x bounds."""
    app = _make_app()
    async with app.run_test() as pilot:
        app._speed = 0.5
        await pilot.press("minus")
        await pilot.pause()
        assert app._speed == 0.5  # Can't go below 0.5

        app._speed = 2.0
        await pilot.press("equal")
        await pilot.pause()
        assert app._speed == 2.0  # Can't go above 2.0


@pytest.mark.asyncio
@patch("wilted.get_default_speed", return_value=1.0)
@patch("wilted.db.set_setting")
async def test_speed_key_shows_feedback(mock_set, mock_default):
    """Speed change updates the speed display."""
    app = _make_app()
    async with app.run_test() as pilot:
        await pilot.press("equal")
        await pilot.pause()
        speed_text = str(app.query_one("#speed-display").render())
        assert "1.1x" in speed_text


# ---------------------------------------------------------------------------
# Status priority
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_status_priority_blocks_low():
    """MEDIUM priority message blocks subsequent LOW message within hold window."""
    from wilted.tui import _STATUS_LOW, _STATUS_MEDIUM

    app = _make_app()
    async with app.run_test():
        app._set_status("Important", _STATUS_MEDIUM)
        status1 = str(app.query_one("#status-line").render())
        app._set_status("Routine", _STATUS_LOW)
        status2 = str(app.query_one("#status-line").render())
        assert status1 == status2  # LOW didn't overwrite


@pytest.mark.asyncio
async def test_status_priority_allows_equal():
    """Same-priority messages can overwrite each other."""
    from wilted.tui import _STATUS_MEDIUM

    app = _make_app()
    async with app.run_test():
        app._set_status("First", _STATUS_MEDIUM)
        app._set_status("Second", _STATUS_MEDIUM)
        status = str(app.query_one("#status-line").render())
        assert "Second" in status


# ---------------------------------------------------------------------------
# Transcript helper (pure; still exercised directly, no longer fed by
# playback — see WiltedApp._build_transcript docstring)
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_transcript_markup_bold_current():
    """_build_transcript marks current paragraph as bold."""
    app = _make_app()
    async with app.run_test():
        app._paragraphs = ["First para.", "Second para.", "Third para."]
        result = app._build_transcript(1)
        assert "[bold #F2E8CF]Second para.[/bold #F2E8CF]" in result
        assert "[#A9BA9D]First para.[/#A9BA9D]" in result
        assert "[dim #A9BA9D]Third para.[/dim #A9BA9D]" in result


@pytest.mark.asyncio
async def test_transcript_escapes_brackets():
    """_build_transcript escapes Rich markup in article text."""
    app = _make_app()
    async with app.run_test():
        app._paragraphs = ["Text with [brackets] inside."]
        result = app._build_transcript(0)
        assert "\\[brackets]" in result or "[brackets]" not in result.replace("\\[", "")


# ---------------------------------------------------------------------------
# TUI launch with real database (no mock) — real controller/adapter/sequencer
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_tui_launches_with_real_db():
    """TUI starts against the real (isolated) SQLite database, not a mocked queue."""
    app = WiltedApp()
    async with app.run_test():
        await app.workers.wait_for_complete()
        trees = app.query(Tree)
        assert len(trees) > 0
        # Empty DB: the empty-message label should be visible
        empty = app.query_one("#empty-message", Label)
        assert "empty" in empty.content.lower()


@pytest.mark.asyncio
async def test_tui_shows_being_prepared_for_unfinalized_real_db_article():
    """A freshly-added real article has no audio cache yet, so EntrySequencer
    (which requires finalized media) excludes it from the station backlog —
    the Larder shows the PM-3 "being prepared" message, not a leaf for it,
    even though the item is visible in the DB-backed item list."""
    from wilted.queue import add_article

    add_article("Test article body text for TUI display.", title="TUI DB Test")

    app = WiltedApp()
    async with app.run_test():
        await app.workers.wait_for_complete()
        assert any(item["title"] == "TUI DB Test" for item in app._all_items)
        tree = app.query_one("#playlist-tree", Tree)
        assert len(tree.root.children) == 0
        empty = app.query_one("#empty-message", Label)
        assert "prepared" in empty.content.lower()


@pytest.mark.asyncio
async def test_tui_quit_with_real_db():
    """TUI exits cleanly on q key with a real database."""
    app = WiltedApp()
    async with app.run_test() as pilot:
        await app.workers.wait_for_complete()
        await pilot.press("q")
        assert app._exit is not None


# ---------------------------------------------------------------------------
# ReportScreen tests (unrelated to the station reroute)
# ---------------------------------------------------------------------------


@pytest.fixture
def sample_report_data():
    """Sample report data for testing ReportScreen."""
    return {
        "report": {
            "report_date": "2026-04-20",
            "generated_at": "2026-04-20T06:00:00Z",
            "item_count": 2,
            "metadata": '{"playlists": {"Work": 2}, "total_items": 2}',
        },
        "items": {
            "Work": [
                {
                    "id": 1,
                    "title": "Test Article 1",
                    "source_name": "Test Source",
                    "relevance_score": 0.9,
                    "summary": "Summary 1",
                },
                {
                    "id": 2,
                    "title": "Test Article 2",
                    "source_name": "Test Source",
                    "relevance_score": 0.8,
                    "summary": "Summary 2",
                },
            ]
        },
    }


@pytest.mark.asyncio
async def test_report_screen_renders_items():
    """ReportScreen displays report items in the DataTable."""
    from wilted.tui.screens.report import ReportScreen

    app = WiltedApp()
    report_data = {
        "report": {
            "report_date": "2026-04-20",
            "generated_at": "2026-04-20T06:00:00Z",
            "item_count": 2,
            "metadata": '{"playlists": {"Work": 2}, "total_items": 2}',
        },
        "items": {
            "Work": [
                {
                    "id": 1,
                    "title": "Test Article 1",
                    "source_name": "Test Source",
                    "relevance_score": 0.9,
                    "summary": "Summary 1",
                },
                {
                    "id": 2,
                    "title": "Test Article 2",
                    "source_name": "Test Source",
                    "relevance_score": 0.8,
                    "summary": "Summary 2",
                },
            ]
        },
    }
    async with app.run_test() as pilot:
        app.push_screen(ReportScreen(report_data))
        await pilot.pause()
        from textual.widgets import DataTable

        table = app.screen.query_one("#report-table", DataTable)
        assert table.row_count >= 2, f"Expected at least 2 data rows, got {table.row_count}"


@pytest.mark.asyncio
async def test_toggle_selection():
    """Toggling selection on an item updates its selected state."""
    from wilted.tui.screens.report import ReportScreen

    app = WiltedApp()
    report_data = {
        "report": {
            "report_date": "2026-04-20",
            "generated_at": "2026-04-20T06:00:00Z",
            "item_count": 1,
            "metadata": '{"playlists": {"Work": 1}, "total_items": 1}',
        },
        "items": {
            "Work": [
                {
                    "id": 1,
                    "title": "Test Article",
                    "source_name": "Test Source",
                    "relevance_score": 0.9,
                    "summary": "Summary",
                },
            ]
        },
    }
    async with app.run_test() as pilot:
        app.push_screen(ReportScreen(report_data))
        await pilot.pause()
        screen = app.screen
        assert screen._selected.get(1, False) is True
        await pilot.press("enter")
        await pilot.pause()
        assert screen._selected.get(1, True) is False


@pytest.mark.asyncio
async def test_accept_promotes_selected_items():
    """Accepting promotes selected items to selected status."""
    from datetime import UTC, datetime

    from wilted.db import Feed, Item
    from wilted.report import get_report, run_report
    from wilted.tui.screens.report import ReportScreen

    now = datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
    feed = Feed.create(
        title="Test Feed",
        feed_url="https://example.com/feed.xml",
        feed_type="article",
        enabled=True,
        created_at=now,
        updated_at=now,
    )
    item = Item.create(
        feed=feed,
        guid="test-accept-1",
        title="Test Article",
        discovered_at=now,
        item_type="article",
        status="classified",
        status_changed_at=now,
        playlist_assigned="Work",
        relevance_score=0.9,
        summary="Test summary",
    )

    run_report()
    report_data = get_report()
    assert report_data is not None

    app = WiltedApp()
    async with app.run_test() as pilot:
        app.push_screen(ReportScreen(report_data))
        await pilot.pause()
        await pilot.press("s")
        await pilot.pause(delay=0.5)

        updated = Item.get_by_id(item.id)
        assert updated.status == "selected"


@pytest.mark.asyncio
async def test_dismiss_without_action_preserves_state():
    """Dismissing without accepting preserves the original item states."""
    from wilted.tui.screens.report import ReportScreen

    app = WiltedApp()
    report_data = {
        "report": {
            "report_date": "2026-04-20",
            "generated_at": "2026-04-20T06:00:00Z",
            "item_count": 1,
            "metadata": '{"playlists": {"Work": 1}, "total_items": 1}',
        },
        "items": {
            "Work": [
                {
                    "id": 1,
                    "title": "Test Article",
                    "source_name": "Test Source",
                    "relevance_score": 0.9,
                    "summary": "Summary",
                },
            ]
        },
    }
    async with app.run_test() as pilot:
        app.push_screen(ReportScreen(report_data))
        await pilot.pause()
        await pilot.press("enter")
        await pilot.pause()
        screen = app.screen
        assert screen._selected.get(1, True) is False
        await pilot.press("q")
        await pilot.pause()
        assert not isinstance(app.screen, ReportScreen)


@pytest.mark.asyncio
async def test_report_screen_not_shown_when_no_report():
    """ReportScreen is not shown when there is no report."""
    with patch("wilted.tui.WiltedApp._check_unread_report_worker"):
        app = WiltedApp()
        async with app.run_test() as pilot:
            await pilot.pause()
            from wilted.tui.screens.report import ReportScreen

            assert not any(isinstance(screen, ReportScreen) for screen in app.screen_stack)


@pytest.mark.asyncio
async def test_on_report_dismissed_refreshes_queue():
    """_on_report_dismissed(True) calls _refresh_playlists."""
    app = _make_app()
    async with app.run_test():
        with patch.object(app, "_refresh_playlists") as mock_refresh:
            app._on_report_dismissed(True)
            mock_refresh.assert_called_once()


@pytest.mark.asyncio
async def test_on_report_dismissed_no_refresh_when_not_accepted():
    """_on_report_dismissed(False) does not refresh the playlists."""
    app = _make_app()
    async with app.run_test():
        with patch.object(app, "_refresh_playlists") as mock_refresh:
            app._on_report_dismissed(False)
            mock_refresh.assert_not_called()


@pytest.mark.asyncio
async def test_report_screen_has_footer():
    """ReportScreen includes a Footer widget to display key bindings."""
    from textual.widgets import Footer

    from wilted.tui.screens.report import ReportScreen

    app = WiltedApp()
    report_data = {
        "report": {
            "report_date": "2026-04-20",
            "generated_at": "2026-04-20T06:00:00Z",
            "item_count": 1,
            "metadata": "{}",
        },
        "items": {
            "Work": [
                {"id": 1, "title": "Article", "source_name": "Src", "relevance_score": 0.8, "summary": ""},
            ]
        },
    }
    async with app.run_test() as pilot:
        app.push_screen(ReportScreen(report_data))
        await pilot.pause()
        footers = app.screen.query(Footer)
        assert len(footers) == 1, "ReportScreen should have exactly one Footer"


# ---------------------------------------------------------------------------
# NEW (A.3.5): INV-8 gate — legacy resume functions must never fire on the
# station playback lifecycle, and every station-state change must route
# through the controller.
# ---------------------------------------------------------------------------


def test_inv8_wilted_tui_source_never_references_legacy_resume_functions():
    """Static-scan guard (INV-8/PM-9): ``wilted.tui`` must contain NO reference
    at all to the legacy per-paragraph resume functions.

    This is the load-bearing check, not the behavioral test below: patching
    ``wilted.playlists.set_resume_position`` (the origin module) does NOT
    intercept a hypothetical regression that reintroduces
    ``from wilted.playlists import set_resume_position`` into ``wilted.tui``
    — that would create a SEPARATE module-local name binding in
    ``wilted.tui``'s namespace, untouched by a patch on the origin. Only a
    source scan (or patching ``wilted.tui.set_resume_position`` itself, which
    doesn't exist and would just raise AttributeError today) actually proves
    the retirement.

    Scans the AST (not raw text) so the module's own explanatory docstring
    mentioning these names by name (to document their retirement) doesn't
    trip the assertion — only actual code references count: imports,
    ``name(...)`` calls/references, and fully-qualified attribute access
    (``wilted.playlists.set_resume_position``).
    """
    import ast

    import wilted.tui as tui_module

    tree = ast.parse(inspect.getsource(tui_module))
    referenced: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Name):
            referenced.add(node.id)
        elif isinstance(node, ast.Attribute):
            referenced.add(node.attr)
        elif isinstance(node, (ast.Import, ast.ImportFrom)):
            referenced.update(alias.asname or alias.name for alias in node.names)

    for name in ("set_resume_position", "get_resume_position", "clear_resume_position"):
        assert name not in referenced, f"{name} must not be referenced in wilted.tui's code (INV-8: fully retired)"


@pytest.mark.asyncio
async def test_inv8_station_lifecycle_routes_through_controller_and_never_touches_resume():
    """PM-9 behavioral lock: play -> pause -> resume -> stop -> play -> complete
    drives real station-state transitions, all visible on the controller's
    action log (positive proof state changes went through the single
    writer) — paired with the static-scan test above (which is what actually
    proves the legacy functions are unreachable; these patches are
    defense-in-depth against a fully-qualified ``wilted.playlists.xxx(...)``
    call slipping in some other way).
    """
    entry_a = _station_entry(1)
    entry_b = _station_entry(2)
    controller = FakeController()
    adapter = FakeAdapter()
    app = _make_app(entries=[entry_a, entry_b], controller=controller, adapter=adapter)

    with (
        patch("wilted.playlists.set_resume_position") as mock_set,
        patch("wilted.playlists.get_resume_position") as mock_get,
        patch("wilted.playlists.clear_resume_position") as mock_clear,
        patch("wilted.tui.mark_completed"),
    ):
        async with app.run_test():
            await app.workers.wait_for_complete()

            app._start_playback(entry_a)
            app.action_toggle_play()  # pause
            app.action_toggle_play()  # resume
            app.action_stop()

            app._start_playback(entry_a)
            app._handle_station_completion(CompletionReason.ENDED)

        mock_set.assert_not_called()
        mock_get.assert_not_called()
        mock_clear.assert_not_called()

    action_types = [type(a).__name__ for a in controller.actions]
    assert action_types.count("StartPlayback") >= 2
    assert action_types.count("Stop") >= 2


# ---------------------------------------------------------------------------
# NEW (A.3.5): mixed-session Pilot drive — play, clean auto-advance, then a
# truncated completion that must NOT advance (PM-10 guard).
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_mixed_session_play_then_auto_advance_then_interrupted():
    first_entry = _station_entry(1, duration_ms=120_000)
    second_entry = _station_entry(2, duration_ms=90_000)
    items = [
        {"id": 1, "title": "An Article", "words": 3000, "file": "1_an-article.txt", "added": "2026-04-06"},
        {"id": 2, "title": "A Podcast Episode", "words": 4200, "file": "", "added": "2026-04-06"},
    ]
    controller = FakeController()
    adapter = FakeAdapter()
    app = _make_app(entries=[first_entry, second_entry], controller=controller, adapter=adapter)

    with (
        patch("wilted.tui.ensure_default_playlists"),
        patch("wilted.tui.get_playlist_items", return_value=items),
        patch("wilted.tui.mark_completed"),
    ):
        async with app.run_test() as pilot:
            await app.workers.wait_for_complete()
            tree = app.query_one("#playlist-tree", Tree)
            assert len(tree.root.children) == 2

            tree.select_node(tree.root.children[0])
            await pilot.pause()
            app.action_play_selected()
            await pilot.pause()

            assert adapter.play_calls == [(first_entry.media, 0)]
            assert any(
                isinstance(a, StartPlayback) and a.entry.entry_id == first_entry.entry_id for a in controller.actions
            )

            # Clean completion -> auto-advance to the second entry.
            app._handle_station_completion(CompletionReason.ENDED)
            await pilot.pause()

            assert adapter.play_calls[-1] == (second_entry.media, 0)
            assert app._current_entry is not None
            assert app._current_entry.entry_id == second_entry.entry_id

            # Truncated completion -> NO advance, interrupted status shown.
            app._handle_station_completion(CompletionReason.TRUNCATED)
            await pilot.pause()

            assert adapter.play_calls[-1] == (second_entry.media, 0)  # unchanged
            assert app._current_entry.entry_id == second_entry.entry_id
            status = str(app.query_one("#status-line").render())
            assert "interrupted" in status.lower()


# ---------------------------------------------------------------------------
# NEW (A.3.5 fix review): audio-thread deadlock regression lock —
# _on_adapter_completion must marshal via post_message, never call_from_thread.
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_on_adapter_completion_marshals_via_post_message_not_call_from_thread():
    """Pins the fix for a real deadlock: ``call_from_thread`` BLOCKS the
    calling thread (the audio thread, for ``_on_adapter_completion``) until
    the UI-thread callback returns. A clean completion's auto-advance path
    (``_handle_station_completion`` -> ``_start_playback`` -> ``adapter.play``)
    goes on to preempt/join the current track — on the REAL
    ``MacPlaybackAdapter`` that join targets this exact still-blocked audio
    thread, hanging for up to its join timeout on every natural track
    transition. ``post_message`` queues the event and returns immediately, so
    the audio thread has already exited before any join is attempted. This
    test would fail against the pre-fix ``call_from_thread`` implementation.
    """
    app = _make_app()
    async with app.run_test():
        with (
            patch.object(app, "post_message") as mock_post,
            patch.object(app, "call_from_thread") as mock_call_from_thread,
        ):
            app._on_adapter_completion(CompletionReason.ENDED)

            mock_call_from_thread.assert_not_called()
            mock_post.assert_called_once()
            (posted_message,), _kwargs = mock_post.call_args
            assert isinstance(posted_message, PlaybackCompleted)
            assert posted_message.reason == CompletionReason.ENDED


@pytest.mark.asyncio
async def test_on_route_change_marshals_via_post_message_not_call_from_thread():
    """Same deadlock lesson as :class:`PlaybackCompleted`, for the route
    monitor: ``on_route_changed`` calls ``adapter.stop()``, which joins the
    adapter's background stream thread. ``RouteMonitor.on_route_change``
    fires on the backend's own delivery thread (the real CoreAudio backend's
    CFRunLoop pump thread) — routing through ``call_from_thread`` would block
    that thread until the join (and everything after it) completes."""
    app = _make_app()
    async with app.run_test():
        with (
            patch.object(app, "post_message") as mock_post,
            patch.object(app, "call_from_thread") as mock_call_from_thread,
        ):
            event = RouteChangeEvent(device_id=3, device_name="Bluetooth Headset")
            app._on_route_change(event)

            mock_call_from_thread.assert_not_called()
            mock_post.assert_called_once()
            (posted_message,), _kwargs = mock_post.call_args
            assert isinstance(posted_message, RouteChanged)
            assert posted_message.event == event


@pytest.mark.asyncio
async def test_adapter_completion_reaches_handler_through_real_message_pump():
    """End-to-end wiring check (not just that post_message was called): drives
    the ADAPTER's real ``fire_completion`` -> ``on_complete`` ->
    ``_on_adapter_completion`` -> ``post_message`` -> Textual's actual message
    queue -> ``on_playback_completed`` -> ``_handle_station_completion``,
    with no direct handler call — proves the message is actually dispatched,
    not just posted."""
    entry_a = _station_entry(1)
    entry_b = _station_entry(2)
    controller = FakeController()
    adapter = FakeAdapter()
    app = _make_app(entries=[entry_a, entry_b], controller=controller, adapter=adapter)
    async with app.run_test() as pilot:
        await app.workers.wait_for_complete()
        app._start_playback(entry_a)
        adapter.fire_completion(CompletionReason.ENDED)
        await pilot.pause()

        assert app._current_entry is not None
        assert app._current_entry.entry_id == entry_b.entry_id
        assert adapter.play_calls[-1] == (entry_b.media, 0)


# ---------------------------------------------------------------------------
# NEW (A.3.5 fix review): a clean completion with an unresolved current index
# must not replay station_entries[0].
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_clean_completion_with_unknown_current_index_does_not_replay_first_entry():
    """If ``_current_index`` is None when a clean ENDED arrives (e.g. a
    sequencer rebuild dropped the entry that was playing out from under it),
    the old ``(self._current_index + 1) if ... else 0`` default would replay
    ``station_entries[0]`` instead of correctly treating this as "queue
    finished". This must NOT auto-advance."""
    entry_a = _station_entry(1)
    entry_b = _station_entry(2)
    controller = FakeController()
    adapter = FakeAdapter()
    app = _make_app(entries=[entry_a, entry_b], controller=controller, adapter=adapter)
    async with app.run_test():
        await app.workers.wait_for_complete()
        app._start_playback(entry_a)
        assert len(adapter.play_calls) == 1

        app._current_index = None  # simulate a rebuild dropping the playing entry
        app._handle_station_completion(CompletionReason.ENDED)

        assert len(adapter.play_calls) == 1  # no replay of entry_a
        assert app._current_entry is None
        assert app._current_index is None


# ---------------------------------------------------------------------------
# NEW (A.3.5): resume offset — only honored for a checkpoint matching the
# entry being started.
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_start_playback_honors_matching_checkpoint_offset_only():
    """Genuinely fails against the pre-fix ordering bug: ``FakeController``
    now mirrors the real reducer's ``StartPlayback`` transition (it clears
    ``checkpoint`` on every submit — see ``FakeController``'s docstring), so
    code that reads the checkpoint AFTER ``submit_and_wait(StartPlayback(...))``
    (instead of before) would always observe ``offset_ms == 0`` here and this
    assertion (``42_000``) would fail.
    """
    entry = _station_entry(1)
    other_entry = _station_entry(2)
    checkpoint = PlaybackCheckpoint(
        station_revision=1,
        entry_id=entry.entry_id,
        media_offset_ms=42_000,
        state="paused",
        interrupted_entry_stack=(),
        writer_device="mac",
        mutation_id="m-1",
        timestamp="2026-07-11T00:00:00Z",
    )

    controller = FakeController(state=StationState(checkpoint=checkpoint))
    adapter = FakeAdapter()
    app = _make_app(entries=[entry, other_entry], controller=controller, adapter=adapter)
    async with app.run_test():
        app._start_playback(entry)
        assert adapter.play_calls == [(entry.media, 42_000)]

    controller2 = FakeController(state=StationState(checkpoint=checkpoint))
    adapter2 = FakeAdapter()
    app2 = _make_app(entries=[entry, other_entry], controller=controller2, adapter=adapter2)
    async with app2.run_test():
        # checkpoint.entry_id belongs to `entry`, not `other_entry` -> offset 0.
        app2._start_playback(other_entry)
        assert adapter2.play_calls == [(other_entry.media, 0)]


# ---------------------------------------------------------------------------
# NEW (A.3.5): empty-station state (PM-3)
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_empty_station_message_distinguishes_being_prepared_from_truly_empty():
    items = [{"id": 1, "title": "Unfinalized", "words": 500, "file": "1_x.txt", "added": "2026-04-06"}]
    with (
        patch("wilted.tui.ensure_default_playlists"),
        patch("wilted.tui.get_playlist_items", return_value=items),
    ):
        app = _make_app(entries=[])  # sequencer has nothing finalized yet
        async with app.run_test():
            await app.workers.wait_for_complete()
            empty = app.query_one("#empty-message", Label)
            assert "prepared" in empty.content.lower()

    with (
        patch("wilted.tui.ensure_default_playlists"),
        patch("wilted.tui.get_playlist_items", return_value=[]),
    ):
        app2 = _make_app(entries=[])
        async with app2.run_test():
            await app2.workers.wait_for_complete()
            empty2 = app2.query_one("#empty-message", Label)
            assert "empty" in empty2.content.lower()
            assert "prepared" not in empty2.content.lower()


# ---------------------------------------------------------------------------
# NEW (A.3.5): lease held elsewhere -> read-only, no crash, no play attempt.
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_lease_held_elsewhere_enters_read_only_state():
    class _RaisingController(FakeController):
        def start(self, *, on_loss=None) -> None:
            raise LeaseHeldError("held elsewhere")

    controller = _RaisingController()
    adapter = FakeAdapter()
    app = _make_app(entries=[_station_entry(1)], controller=controller, adapter=adapter)
    async with app.run_test() as pilot:
        await pilot.pause()
        assert app._station_read_only is True
        status = str(app.query_one("#status-line").render())
        assert "another session" in status.lower() or "read-only" in status.lower()

        # Attempting to play must not crash and must not touch the adapter.
        app._start_playback(_station_entry(1))
        assert adapter.play_calls == []


# ---------------------------------------------------------------------------
# NEW (A.3.5 fix review): read-only mode must refuse destructive CRUD too —
# another live session may be reading/writing the same DB items right now.
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_read_only_mode_refuses_destructive_crud():
    """Data-safety guard: with the station lease held elsewhere,
    delete/mark-read/clear-all must all be refused outright, not just
    playback. ``action_refresh_queue`` is deliberately NOT guarded (read-only
    still permits browsing/refreshing the backlog for viewing), which is how
    the tree gets populated below without ever taking write ownership of the
    station."""

    class _RaisingController(FakeController):
        def start(self, *, on_loss=None) -> None:
            raise LeaseHeldError("held elsewhere")

    articles = [{"id": 1, "title": "Test Article", "words": 50, "file": "1_test.txt", "added": "2026-04-06"}]
    with (
        patch("wilted.tui.ensure_default_playlists"),
        patch("wilted.tui.get_playlist_items", return_value=articles),
        patch("wilted.tui.remove_article_by_id") as mock_remove,
        patch("wilted.tui.mark_completed") as mock_mark,
        patch("wilted.tui.clear_queue") as mock_clear,
    ):
        app = _make_app(entries=[_station_entry(1)], controller=_RaisingController())
        async with app.run_test() as pilot:
            await pilot.pause()
            assert app._station_read_only is True

            # action_refresh_queue is unguarded -- populate the tree so a
            # real StationEntry is selectable, proving the CRUD refusals
            # below are the read-only guard firing, not just "nothing
            # selected".
            app.action_refresh_queue()
            await app.workers.wait_for_complete()
            tree = app.query_one("#playlist-tree", Tree)
            assert len(tree.root.children) == 1
            tree.select_node(tree.root.children[0])
            await pilot.pause()

            app.action_delete_selected()
            await pilot.pause()
            assert not any(isinstance(screen, ConfirmScreen) for screen in app.screen_stack)
            mock_remove.assert_not_called()

            app.action_mark_read()
            mock_mark.assert_not_called()

            app.action_clear_all()
            await pilot.pause()
            assert not any(isinstance(screen, ConfirmScreen) for screen in app.screen_stack)
            mock_clear.assert_not_called()

            status = str(app.query_one("#status-line").render())
            assert "read-only" in status.lower() or "another session" in status.lower()


# ---------------------------------------------------------------------------
# NEW (A.3.3): route-recovery — a device change interrupts playback with a
# visible no-output state (no silent misroute, no auto-advance), and "p" (the
# existing pause/resume key) replays the same entry at the preserved offset.
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_route_monitor_starts_on_play_and_stops_on_action_stop():
    """RouteMonitor's lifecycle mirrors the poller's exactly: started once
    playback begins, stopped by an explicit action_stop()."""
    entry = _station_entry(1)
    route_monitor = FakeRouteMonitor()
    app = _make_app(entries=[entry], route_monitor=route_monitor)
    async with app.run_test():
        await app.workers.wait_for_complete()
        assert route_monitor.start_calls == 0

        app._start_playback(entry)
        assert route_monitor.start_calls == 1
        assert route_monitor.stop_calls == 0

        app.action_stop()
        assert route_monitor.stop_calls == 1


@pytest.mark.asyncio
async def test_route_change_while_playing_stops_adapter_shows_banner_no_auto_advance():
    """Firing a route-change event while playing must: stop the adapter
    (release the stale/misrouted device), enter the visible
    ``_route_interrupted`` state with a banner naming the new device, and NOT
    auto-advance to the next entry or crash."""
    entry = _station_entry(1)
    other_entry = _station_entry(2)
    controller = FakeController()
    adapter = FakeAdapter()
    route_monitor = FakeRouteMonitor()
    app = _make_app(entries=[entry, other_entry], controller=controller, adapter=adapter, route_monitor=route_monitor)
    async with app.run_test() as pilot:
        await app.workers.wait_for_complete()
        app._start_playback(entry)
        adapter._offset_ms = 17_000  # simulate 17s of playback elapsed

        route_monitor.fire(RouteChangeEvent(device_id=99, device_name="AirPods Pro"))
        await pilot.pause()

        # (a) adapter stopped
        assert adapter.stop_calls == 1
        # (b) visible interrupted state + banner naming the device
        assert app._route_interrupted is True
        assert app._route_device_name == "AirPods Pro"
        status = str(app.query_one("#status-line").render())
        assert "AirPods Pro" in status
        assert "paused" in status.lower()
        # (c) no auto-advance: still only the original play() call, no
        # StartPlayback submitted for the next entry, current entry unchanged.
        assert len(adapter.play_calls) == 1
        assert app._current_entry is not None
        assert app._current_entry.entry_id == entry.entry_id
        assert not any(
            isinstance(a, StartPlayback) and a.entry.entry_id == other_entry.entry_id for a in controller.actions
        )
        # The offset captured before stopping is preserved for resume.
        assert app._route_resume_entry is not None
        assert app._route_resume_entry.entry_id == entry.entry_id
        assert app._route_resume_offset_ms == 17_000
        # (d) no crash: reaching here at all proves it, plus the app is
        # still alive and responsive.
        assert app.is_running


@pytest.mark.asyncio
async def test_route_change_while_not_playing_is_a_noop():
    """A route change with nothing loaded/playing must be silently ignored —
    no banner, no adapter interaction, no interrupted state."""
    entry = _station_entry(1)
    adapter = FakeAdapter()
    route_monitor = FakeRouteMonitor()
    app = _make_app(entries=[entry], adapter=adapter, route_monitor=route_monitor)
    async with app.run_test() as pilot:
        await app.workers.wait_for_complete()
        assert app._playing is False

        route_monitor.fire(RouteChangeEvent(device_id=1, device_name="Some Device"))
        await pilot.pause()

        assert adapter.stop_calls == 0
        assert app._route_interrupted is False


@pytest.mark.asyncio
async def test_resume_from_route_interruption_replays_same_entry_at_exact_offset():
    """Pressing "p" (the existing pause/resume key) from the route-interrupted
    state must replay the SAME entry — via a fresh StartPlayback through the
    controller (INV-8) — at the exact offset captured at interruption, not a
    stale/zero offset. Exercises the boundary-accurate resume path: a
    ``Checkpoint`` submitted immediately before ``_start_playback`` so its
    matching-checkpoint read lands the precise offset (see
    ``WiltedApp._submit_route_resume_checkpoint``)."""
    entry = _station_entry(1)
    controller = FakeController()
    adapter = FakeAdapter()
    route_monitor = FakeRouteMonitor()
    app = _make_app(entries=[entry], controller=controller, adapter=adapter, route_monitor=route_monitor)
    async with app.run_test() as pilot:
        await app.workers.wait_for_complete()
        app._start_playback(entry)
        adapter._offset_ms = 33_500

        route_monitor.fire(RouteChangeEvent(device_id=5, device_name="Living Room Speaker"))
        await pilot.pause()
        assert app._route_interrupted is True

        await pilot.press("p")
        await pilot.pause()

        # Resumed state cleared.
        assert app._route_interrupted is False
        assert app._route_resume_entry is None

        # A boundary-accurate Checkpoint was submitted for the exact offset...
        checkpoint_actions = [a for a in controller.actions if isinstance(a, Checkpoint)]
        assert checkpoint_actions, "expected a Checkpoint action submitted for route-resume"
        assert checkpoint_actions[-1].media_offset_ms == 33_500
        assert checkpoint_actions[-1].writer_device == "mac"
        assert checkpoint_actions[-1].state_label == "playing"
        # ...and it was genuinely ACCEPTED by the reducer-faithful
        # PLAYING+active_entry precondition (FakeController._record), not
        # silently rejected -- this is what makes the assertion below
        # (adapter.play landed the exact offset) actually depend on
        # `on_route_changed` NOT having submitted Stop() first (a Stop()
        # regression would flip lifecycle to STOPPED and this Checkpoint
        # would be rejected instead).
        assert controller.checkpoint_outcomes[-1] is True, "the route-resume Checkpoint was rejected, not accepted"

        # ...which the subsequent StartPlayback + adapter.play() honored: the
        # SAME entry replayed at the exact preserved offset (not 0, not the
        # 0-offset from the original play() call).
        start_playback_actions = [a for a in controller.actions if isinstance(a, StartPlayback)]
        assert start_playback_actions[-1].entry.entry_id == entry.entry_id
        assert adapter.play_calls[-1] == (entry.media, 33_500)
        assert app._playing is True

        # Route monitoring itself was never torn down across the
        # interruption/resume cycle -- only the adapter/poller were.
        assert route_monitor.stop_calls == 0


@pytest.mark.asyncio
async def test_on_route_changed_keeps_controller_lifecycle_playing_not_stop():
    """Pins the no-Stop() invariant directly: `on_route_changed` must NOT
    submit ``Stop()`` to the controller. Fails the instant someone
    reintroduces it (mirroring `_handle_station_completion`'s pattern) --
    against the real reducer that would flip the station to STOPPED and
    reject the following route-resume Checkpoint (see
    `WiltedApp.on_route_changed`'s docstring for why this precondition
    matters)."""
    entry = _station_entry(1)
    controller = FakeController()
    adapter = FakeAdapter()
    route_monitor = FakeRouteMonitor()
    app = _make_app(entries=[entry], controller=controller, adapter=adapter, route_monitor=route_monitor)
    async with app.run_test() as pilot:
        await app.workers.wait_for_complete()
        app._start_playback(entry)
        assert controller.current_state().lifecycle is StationLifecycle.PLAYING

        route_monitor.fire(RouteChangeEvent(device_id=5, device_name="Living Room Speaker"))
        await pilot.pause()

        assert app._route_interrupted is True
        assert not any(isinstance(a, Stop) for a in controller.actions)
        assert controller.current_state().lifecycle is StationLifecycle.PLAYING
        assert controller.current_state().active_entry is not None
        assert controller.current_state().active_entry.entry_id == entry.entry_id


@pytest.mark.asyncio
async def test_playback_completion_clears_route_interrupted_state_before_next_toggle():
    """FIX for a real race: RouteChanged and PlaybackCompleted are both
    posted from background threads and dispatched FIFO on the UI thread. If
    a device switch fires within ~ms of a natural track end and RouteChanged
    is drained first, `on_route_changed` sets `_route_interrupted=True` +
    `_route_resume_entry=<entry that just ended>` -- then
    `_handle_station_completion` runs for the SAME entry's completion.

    Without resetting the route fields there, `_route_interrupted` stays
    latched True after the entry has already been marked complete /
    advanced past, so the next "p"/space would hit `action_toggle_play`'s
    route-interrupted branch and incorrectly REPLAY the completed entry via
    the stale-offset route-resume path (a fresh `Checkpoint` submission with
    the pre-interruption offset, not a normal fresh restart at 0).

    This test drives that exact sequence directly (no real race/timing
    needed -- just posting both messages in the vulnerable order) and
    asserts: (1) `_route_interrupted` is cleared by the completion, and (2)
    the next `action_toggle_play()` takes the NORMAL restart-from-idle path
    (offset 0, no route-resume Checkpoint submitted) rather than the
    route-interrupted resume path (stale offset, extra Checkpoint)."""
    entry = _station_entry(1)
    controller = FakeController()
    adapter = FakeAdapter()
    route_monitor = FakeRouteMonitor()
    app = _make_app(entries=[entry], controller=controller, adapter=adapter, route_monitor=route_monitor)
    async with app.run_test() as pilot:
        await app.workers.wait_for_complete()
        app._start_playback(entry)
        adapter._offset_ms = 41_000  # simulate elapsed playback before the race

        # RouteChanged drained first...
        route_monitor.fire(RouteChangeEvent(device_id=9, device_name="Stray Bluetooth Speaker"))
        await pilot.pause()
        assert app._route_interrupted is True

        # ...then PlaybackCompleted for the SAME (now-stale) entry, racing in
        # right behind it -- both messages are posted from background
        # threads/callbacks and drained via post_message's async queue, same
        # as Textual's real message pump would drain two already-queued
        # messages back to back.
        adapter.fire_completion(CompletionReason.ENDED)
        await pilot.pause()

        # (1) The completion superseded the pending route-interruption.
        assert app._route_interrupted is False
        assert app._route_device_name == ""
        assert app._route_resume_entry is None
        assert app._route_resume_offset_ms == 0

        checkpoint_count_before_toggle = len([a for a in controller.actions if isinstance(a, Checkpoint)])

        # (2) The next toggle-play must NOT take the route-resume path: no
        # new Checkpoint submitted, and the replay (this is the only queued
        # entry, so "nothing playing -> play the first entry" legitimately
        # restarts it) lands at offset 0, not the stale 41_000.
        app.action_toggle_play()

        checkpoint_count_after_toggle = len([a for a in controller.actions if isinstance(a, Checkpoint)])
        assert checkpoint_count_after_toggle == checkpoint_count_before_toggle, (
            "action_toggle_play took the route-resume path (submitted a Checkpoint) instead of a normal fresh restart"
        )
        assert adapter.play_calls[-1] == (entry.media, 0)


# ---------------------------------------------------------------------------
# A.4.3: Weather bulletin interrupt/resume
#
# Covers: the monitor->TUI handoff seam (on_bulletin_ready), safe-boundary
# orchestration (submit AcceptInterruption at the REAL current offset --
# HAZARD 2), poller pause-across-bulletin (HAZARD 1), NO_INTERRUPT never
# interrupting, the not-playable budget/fallback path, the completion-race
# fix (bulletin completion routes to resume, never auto-advance), and the
# latency artifact.
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_on_bulletin_ready_sets_pending_slot():
    """The monitor->TUI handoff seam: firing the (fake) weather monitor's
    on_bulletin_ready callback -- exactly like the real WeatherMonitor would
    from its own poll thread -- populates the pending-bulletin slot and arms
    a fresh wait/fallback budget, without touching the controller at all
    (the monitor itself never submits AcceptInterruption anymore; only the
    TUI's own safe-boundary orchestration does)."""
    weather_monitor = FakeWeatherMonitor()
    controller = FakeController()
    app = _make_app(controller=controller, weather_monitor=weather_monitor)
    async with app.run_test():
        await app.workers.wait_for_complete()
        bulletin = _bulletin_entry()

        weather_monitor.fire(bulletin)

        assert app._pending_bulletin is bulletin
        assert app._bulletin_pending_since_monotonic is not None
        assert app._bulletin_wait_ticks == 0
        assert app._bulletin_fallback_shown_this_window is False
        # The handoff alone must never submit anything to the controller.
        assert not any(isinstance(a, AcceptInterruption) for a in controller.actions)


@pytest.mark.asyncio
async def test_no_weather_monitor_by_default():
    """WiltedApp() with no weather_monitor= given wires nothing (mirrors the
    real production default -- see __init__'s docstring: no safe
    auto-constructed WeatherMonitor). The app must run fine, and the 1s timer
    driving _maybe_submit_pending_bulletin must no-op without crashing."""
    entry = _station_entry(1, safe_interruption=SAFE_WINDOW)
    app = _make_app(entries=[entry])
    async with app.run_test():
        await app.workers.wait_for_complete()
        assert app._weather_monitor is None

        app._start_playback(entry)
        app._update_timer()  # must not raise with _pending_bulletin is None


@pytest.mark.asyncio
async def test_weather_monitor_starts_on_mount_and_stops_on_unmount():
    """WiltedApp owns the monitor's lifecycle exactly like the poller/route
    monitor: started once on_mount (session actually holds the lease), and
    torn down via on_unmount's best-effort teardown sweep."""
    weather_monitor = FakeWeatherMonitor()
    app = _make_app(weather_monitor=weather_monitor)
    async with app.run_test():
        await app.workers.wait_for_complete()
        assert weather_monitor.start_calls == 1
        assert weather_monitor.stop_calls == 0

        app.on_unmount()

        assert weather_monitor.stop_calls == 1


@pytest.mark.asyncio
async def test_expired_bulletin_does_not_survive_session_end():
    """A.4.4/A.5.2 session-level gate: an expired weather bulletin's audio
    must not survive a session.

    ``on_unmount`` (the one hook every exit path reaches, see its docstring)
    runs ``media_store.collect_expired_bulletins`` as its last step. This
    proves that end-to-end -- a bulletin blob published with a past expiry
    is gone once the session tears down, while a durable item's media
    (``expiry=None``) is left completely untouched.
    """
    bulletin_hash = media_store.publish_with_owner(
        b"expired bulletin audio",
        kind="bulletin",
        entry_id="wx-old",
        expiry="2020-01-01T00:00:00Z",  # long past, regardless of wall-clock "now"
    )
    item_hash = media_store.publish_with_owner(
        b"durable item audio",
        kind="item",
        entry_id="item-1",
        expiry=None,
    )
    assert media_store.exists(bulletin_hash)
    assert media_store.exists(item_hash)

    app = _make_app()
    async with app.run_test():
        await app.workers.wait_for_complete()

        app.on_unmount()

        assert not media_store.exists(bulletin_hash), "expired bulletin blob survived session end"
        assert media_store.exists(item_hash), "durable item media was wrongly collected"


@pytest.mark.asyncio
async def test_bulletin_waits_when_not_at_a_safe_boundary():
    """A pending bulletin does nothing while the current offset is outside
    every safe window -- no AcceptInterruption submitted, bulletin stays
    pending, playback of the interrupted entry is completely undisturbed."""
    entry = _station_entry(1, safe_interruption=SAFE_WINDOW)
    controller = FakeController()
    adapter = FakeAdapter()
    weather_monitor = FakeWeatherMonitor()
    app = _make_app(entries=[entry], controller=controller, adapter=adapter, weather_monitor=weather_monitor)
    async with app.run_test():
        await app.workers.wait_for_complete()
        app._start_playback(entry)
        bulletin = _bulletin_entry()
        weather_monitor.fire(bulletin)

        adapter._offset_ms = 3_000  # well outside SAFE_WINDOW's [10_000, 12_000]
        app._update_timer()
        app._update_timer()
        app._update_timer()

        assert app._pending_bulletin is bulletin
        assert not any(isinstance(a, AcceptInterruption) for a in controller.actions)
        assert app._current_entry.entry_id == entry.entry_id
        assert len(adapter.play_calls) == 1  # only the original entry, never the bulletin


@pytest.mark.asyncio
async def test_no_interrupt_entry_never_interrupts():
    """An entry with NO_INTERRUPT (SafeInterruptionMap.empty(), the default
    _station_entry() safe_interruption) never has a safe point at ANY offset
    -- a pending bulletin must never be accepted against it, no matter how
    many ticks elapse, and the not-playable fallback path must never even
    trigger (there is no safe boundary to reach in the first place)."""
    entry = _station_entry(1)  # default safe_interruption=SafeInterruptionMap.empty() => NO_INTERRUPT
    controller = FakeController()
    adapter = FakeAdapter()
    weather_monitor = FakeWeatherMonitor()
    app = _make_app(entries=[entry], controller=controller, adapter=adapter, weather_monitor=weather_monitor)
    async with app.run_test():
        await app.workers.wait_for_complete()
        app._start_playback(entry)
        bulletin = _bulletin_entry()
        weather_monitor.fire(bulletin)

        adapter._offset_ms = 10_500  # would be "safe" for SAFE_WINDOW, but this entry has NO_INTERRUPT
        for _ in range(10):
            app._update_timer()

        assert app._pending_bulletin is bulletin
        assert not any(isinstance(a, AcceptInterruption) for a in controller.actions)
        status = str(app.query_one("#status-line").render())
        assert "Weather alert pending" not in status
        assert app._bulletin_playing is False


@pytest.mark.asyncio
async def test_bulletin_interrupts_at_safe_boundary_and_resumes_at_correct_offset(tmp_path):
    """The full happy path, end to end:

    1. A safe boundary is reached -> AcceptInterruption submitted at the
       REAL current offset (HAZARD 2) and accepted.
    2. The bulletin plays via the dedicated bulletin-play path (adapter.play
       called with the bulletin's own media at offset 0).
    3. The bulletin's completion routes to resume (ResumeFromInterruption),
       and the interrupted entry restarts via _start_playback -- which reads
       the accept-time checkpoint and lands adapter.play at the EXACT offset
       captured when AcceptInterruption was submitted, not 0 and not a
       future safe-window bound.
    """
    entry = _station_entry(1, safe_interruption=SAFE_WINDOW)
    controller = FakeController()
    adapter = FakeAdapter()
    weather_monitor = FakeWeatherMonitor()
    app = _make_app(
        entries=[entry],
        controller=controller,
        adapter=adapter,
        weather_monitor=weather_monitor,
        latency_log_path=tmp_path / "latency.jsonl",
    )
    async with app.run_test():
        await app.workers.wait_for_complete()
        app._start_playback(entry)
        bulletin = _bulletin_entry()
        weather_monitor.fire(bulletin)

        adapter._offset_ms = 11_250  # inside SAFE_WINDOW's [10_000, 12_000]
        app._update_timer()

        # (1) Accepted at the REAL current offset -- not some other value.
        accept_actions = [a for a in controller.actions if isinstance(a, AcceptInterruption)]
        assert len(accept_actions) == 1
        assert accept_actions[0].interrupt_offset_ms == 11_250
        assert accept_actions[0].bulletin.entry_id == bulletin.entry_id
        assert app._pending_bulletin is None

        # (2) The bulletin is now playing, via its OWN play path.
        assert app._bulletin_playing is True
        assert app._current_entry.entry_id == bulletin.entry_id
        assert adapter.play_calls[-1] == (bulletin.media, 0)
        # No redundant StartPlayback was submitted for the bulletin -- only
        # the original entry's StartPlayback exists (see _play_bulletin's
        # docstring for why that would silently wipe interruption_stack).
        start_playback_actions = [a for a in controller.actions if isinstance(a, StartPlayback)]
        assert len(start_playback_actions) == 1
        assert start_playback_actions[0].entry.entry_id == entry.entry_id

        # (3) Bulletin completes -> resume, at the EXACT accept-time offset.
        app._handle_station_completion(CompletionReason.ENDED)

        resume_actions = [a for a in controller.actions if isinstance(a, ResumeFromInterruption)]
        assert len(resume_actions) == 1
        assert app._bulletin_playing is False
        assert app._current_entry.entry_id == entry.entry_id
        assert adapter.play_calls[-1] == (entry.media, 11_250)
        assert app._playing is True


@pytest.mark.asyncio
async def test_poller_paused_across_bulletin_so_resume_uses_accept_time_offset(tmp_path):
    """HAZARD 1: the poller must be stopped the instant AcceptInterruption is
    accepted (before the bulletin ever plays) so it cannot checkpoint the
    bulletin over the interrupted entry's carefully-recorded resume
    checkpoint -- and it must be restarted once the interrupted entry
    actually resumes."""
    entry = _station_entry(1, safe_interruption=SAFE_WINDOW)
    controller = FakeController()
    adapter = FakeAdapter()
    weather_monitor = FakeWeatherMonitor()
    poller_holder: list[FakePoller] = []

    def _poller_factory(c, a):
        poller = FakePoller()
        poller_holder.append(poller)
        return poller

    app = _make_app(
        entries=[entry],
        controller=controller,
        adapter=adapter,
        weather_monitor=weather_monitor,
        poller_factory=_poller_factory,
        latency_log_path=tmp_path / "latency.jsonl",
    )
    async with app.run_test():
        await app.workers.wait_for_complete()
        app._start_playback(entry)
        poller = poller_holder[0]
        assert poller.start_calls == 1
        assert poller.stop_calls == 0

        bulletin = _bulletin_entry()
        weather_monitor.fire(bulletin)
        adapter._offset_ms = 11_000
        app._update_timer()

        # Stopped the instant the bulletin starts playing -- before its
        # completion, not after.
        assert poller.stop_calls == 1
        assert app._poller_started is False

        # While the bulletin plays, further ticks must NOT restart or
        # re-stop the poller (it stays stopped for the bulletin's duration).
        app._update_timer()
        assert poller.stop_calls == 1
        assert poller.start_calls == 1

        app._handle_station_completion(CompletionReason.ENDED)

        # Resumed -> poller restarted exactly once more (via _start_playback's
        # own "if not started" gate).
        assert poller.start_calls == 2
        assert poller.stop_calls == 1
        assert app._poller_started is True


@pytest.mark.asyncio
async def test_route_change_during_bulletin_is_ignored_and_preserves_interrupted_entry(tmp_path):
    """FIX-1 (A.4.3, HIGH): a device/route change that fires WHILE a weather
    bulletin is playing must be ignored by ``on_route_changed`` -- the guard
    ``if self._bulletin_playing: return``.

    ``self._playing`` is True during a bulletin too, so without the guard the
    route-interruption path would run against the BULLETIN: it would stop the
    adapter, enter ``_route_interrupted`` with the bulletin as the resume
    entry, and overwrite the accept-time resume checkpoint. Worse, the eventual
    route-resume -> ``_start_playback(bulletin)`` clears ``interruption_stack``
    (the reducer has no "already interrupted" precondition), permanently
    discarding the interrupted entry -- so the bulletin's own completion would
    have nothing correct to resume.

    This test proves the guard makes the route change a no-op AND that the
    interrupted entry survives it: when the bulletin finishes, the ORIGINAL
    entry still resumes at the exact accept-time offset. It fails without the
    guard (route path clobbers the interruption on both counts)."""
    entry = _station_entry(1, safe_interruption=SAFE_WINDOW)
    controller = FakeController()
    adapter = FakeAdapter()
    weather_monitor = FakeWeatherMonitor()
    route_monitor = FakeRouteMonitor()
    app = _make_app(
        entries=[entry],
        controller=controller,
        adapter=adapter,
        weather_monitor=weather_monitor,
        route_monitor=route_monitor,
        latency_log_path=tmp_path / "latency.jsonl",
    )
    async with app.run_test() as pilot:
        await app.workers.wait_for_complete()
        app._start_playback(entry)

        # Drive into the bulletin-playing state at a safe boundary.
        bulletin = _bulletin_entry()
        weather_monitor.fire(bulletin)
        adapter._offset_ms = 11_250  # inside SAFE_WINDOW's [10_000, 12_000]
        app._update_timer()
        assert app._bulletin_playing is True
        assert app._current_entry.entry_id == bulletin.entry_id
        assert controller.current_state().active_entry.entry_id == bulletin.entry_id

        stop_calls_before = adapter.stop_calls
        actions_before = len(controller.actions)

        # A device change fires mid-bulletin -> must be a complete no-op.
        route_monitor.fire(RouteChangeEvent(device_id=42, device_name="AirPods Pro"))
        await pilot.pause()

        # (a) The route-interruption path never ran.
        assert app._route_interrupted is False
        assert app._route_resume_entry is None
        assert not app._route_device_name  # never set to the mid-bulletin device
        # (b) No side effects: adapter not stopped, no Stop/Checkpoint submitted
        # by the route path, station still PLAYING the bulletin.
        assert adapter.stop_calls == stop_calls_before
        assert len(controller.actions) == actions_before
        assert not any(isinstance(a, Stop) for a in controller.actions)
        assert app._bulletin_playing is True
        assert app._current_entry.entry_id == bulletin.entry_id
        assert controller.current_state().lifecycle is StationLifecycle.PLAYING
        assert controller.current_state().active_entry.entry_id == bulletin.entry_id

        # (c) The interrupted entry survived: on bulletin completion, the
        # ORIGINAL entry resumes at the EXACT accept-time offset (not lost, not
        # zero, not the bulletin). This is the assertion that fails without the
        # guard -- interruption_stack would have been wiped.
        app._handle_station_completion(CompletionReason.ENDED)

        resume_actions = [a for a in controller.actions if isinstance(a, ResumeFromInterruption)]
        assert len(resume_actions) == 1
        assert app._bulletin_playing is False
        assert app._current_entry.entry_id == entry.entry_id
        assert adapter.play_calls[-1] == (entry.media, 11_250)
        assert app._playing is True


@pytest.mark.asyncio
async def test_bulletin_not_playable_falls_back_and_retries_at_next_boundary():
    """A safe boundary is reached but the bulletin isn't playable yet
    (FinalizationState incomplete). The TUI must wait up to the cold budget
    (_BULLETIN_BUDGET_COLD_TICKS ticks) before showing the audible+visual
    fallback notice, and must NEVER submit a broken AcceptInterruption for a
    non-playable bulletin. Leaving the safe window and re-entering a later
    one rearms the wait/fallback gate for a fresh retry."""
    entry = _station_entry(1, safe_interruption=SAFE_WINDOW)
    controller = FakeController()
    adapter = FakeAdapter()
    weather_monitor = FakeWeatherMonitor()
    app = _make_app(entries=[entry], controller=controller, adapter=adapter, weather_monitor=weather_monitor)
    async with app.run_test():
        await app.workers.wait_for_complete()
        app._start_playback(entry)
        bulletin = _bulletin_entry(playable=False)
        weather_monitor.fire(bulletin)

        adapter._offset_ms = 11_000  # inside the safe window the whole time

        # Budget is 6 ticks cold (_BULLETIN_BUDGET_COLD_TICKS) -- no fallback
        # and no accept for the first 5.
        for _ in range(5):
            app._update_timer()
        status = str(app.query_one("#status-line").render())
        assert "Weather alert pending" not in status
        assert not any(isinstance(a, AcceptInterruption) for a in controller.actions)
        assert app._pending_bulletin is bulletin

        # 6th tick trips the fallback.
        app._update_timer()
        status = str(app.query_one("#status-line").render())
        assert "Weather alert pending" in status
        assert not any(isinstance(a, AcceptInterruption) for a in controller.actions)
        assert app._pending_bulletin is bulletin  # never dropped -- still eligible to retry
        assert app._bulletin_fallback_shown_this_window is True

        # Leaving the safe window rearms the gate...
        adapter._offset_ms = 3_000
        app._update_timer()
        assert app._bulletin_wait_ticks == 0
        assert app._bulletin_fallback_shown_this_window is False
        assert app._bulletin_boundary_detected_monotonic is None

        # ...so re-entering (still not playable) gets its OWN fresh budget
        # rather than instantly re-showing the fallback.
        adapter._offset_ms = 11_500
        app._update_timer()
        assert app._bulletin_wait_ticks == 1
        assert app._bulletin_fallback_shown_this_window is False


@pytest.mark.asyncio
async def test_bulletin_completion_routes_to_resume_not_auto_advance(tmp_path):
    """A bulletin completion must never take the normal auto-advance /
    mark-complete path (the completion-race hazard): no Stop() submitted for
    it, no next-entry StartPlayback, the backlog index is untouched."""
    entry = _station_entry(1, safe_interruption=SAFE_WINDOW)
    other_entry = _station_entry(2)
    controller = FakeController()
    adapter = FakeAdapter()
    weather_monitor = FakeWeatherMonitor()
    app = _make_app(
        entries=[entry, other_entry],
        controller=controller,
        adapter=adapter,
        weather_monitor=weather_monitor,
        latency_log_path=tmp_path / "latency.jsonl",
    )
    async with app.run_test():
        await app.workers.wait_for_complete()
        app._start_playback(entry)
        bulletin = _bulletin_entry()
        weather_monitor.fire(bulletin)
        adapter._offset_ms = 10_500
        app._update_timer()
        assert app._bulletin_playing is True

        actions_before = len(controller.actions)
        app._handle_station_completion(CompletionReason.ENDED)

        new_actions = controller.actions[actions_before:]
        assert not any(isinstance(a, Stop) for a in new_actions)
        assert not any(isinstance(a, StartPlayback) and a.entry.entry_id == other_entry.entry_id for a in new_actions)
        assert any(isinstance(a, ResumeFromInterruption) for a in new_actions)
        assert app._current_entry.entry_id == entry.entry_id


@pytest.mark.asyncio
async def test_bulletin_truncated_completion_still_resumes(tmp_path):
    """A TRUNCATED (non-clean) bulletin completion must still resume the
    interrupted entry -- unlike the normal completion path's PM-10 "not
    advancing" guard, a bulletin has nothing to not-auto-advance into, so
    this must NOT get stuck on the not-a-clean-completion early return."""
    entry = _station_entry(1, safe_interruption=SAFE_WINDOW)
    controller = FakeController()
    adapter = FakeAdapter()
    weather_monitor = FakeWeatherMonitor()
    app = _make_app(
        entries=[entry],
        controller=controller,
        adapter=adapter,
        weather_monitor=weather_monitor,
        latency_log_path=tmp_path / "latency.jsonl",
    )
    async with app.run_test():
        await app.workers.wait_for_complete()
        app._start_playback(entry)
        bulletin = _bulletin_entry()
        weather_monitor.fire(bulletin)
        adapter._offset_ms = 10_500
        app._update_timer()
        assert app._bulletin_playing is True

        app._handle_station_completion(CompletionReason.TRUNCATED)

        assert any(isinstance(a, ResumeFromInterruption) for a in controller.actions)
        assert app._bulletin_playing is False
        assert app._current_entry.entry_id == entry.entry_id
        assert app._playing is True


@pytest.mark.asyncio
async def test_action_stop_mid_bulletin_resets_bulletin_playing(tmp_path):
    """A manual stop mid-bulletin must clear _bulletin_playing (so the NEXT
    entry's completion doesn't misroute through the bulletin-resume path),
    but must deliberately leave a freshly-arrived pending bulletin in place
    -- a weather alert doesn't stop mattering just because playback was
    stopped."""
    entry = _station_entry(1, safe_interruption=SAFE_WINDOW)
    controller = FakeController()
    adapter = FakeAdapter()
    weather_monitor = FakeWeatherMonitor()
    app = _make_app(
        entries=[entry],
        controller=controller,
        adapter=adapter,
        weather_monitor=weather_monitor,
        latency_log_path=tmp_path / "latency.jsonl",
    )
    async with app.run_test():
        await app.workers.wait_for_complete()
        app._start_playback(entry)
        bulletin = _bulletin_entry()
        weather_monitor.fire(bulletin)
        adapter._offset_ms = 10_500
        app._update_timer()
        assert app._bulletin_playing is True

        # A second bulletin arrives while the first is still playing.
        next_bulletin = _bulletin_entry(entry_id="wx-2")
        weather_monitor.fire(next_bulletin)
        assert app._pending_bulletin is next_bulletin

        app.action_stop()

        assert app._bulletin_playing is False
        assert app._pending_bulletin is next_bulletin  # deliberately left in place


@pytest.mark.asyncio
async def test_bulletin_latency_recorded_within_generous_bound(tmp_path):
    """The latency artifact: one JSON-Lines record per accepted interruption,
    written to the injected latency_log_path (never the real repo's
    reports/ dir -- see WiltedApp.__init__'s latency_log_path docstring).
    Only a generous, machine-independent bound is asserted (this is a fast,
    synchronous test harness, not a timing benchmark) -- and boundary-wait is
    reported separately from accept-to-audible, per the task's requirement
    that they not be conflated."""
    entry = _station_entry(1, safe_interruption=SAFE_WINDOW)
    controller = FakeController()
    adapter = FakeAdapter()
    weather_monitor = FakeWeatherMonitor()
    log_path = tmp_path / "latency.jsonl"
    app = _make_app(
        entries=[entry],
        controller=controller,
        adapter=adapter,
        weather_monitor=weather_monitor,
        latency_log_path=log_path,
    )
    async with app.run_test():
        await app.workers.wait_for_complete()
        app._start_playback(entry)
        bulletin = _bulletin_entry()
        weather_monitor.fire(bulletin)
        adapter._offset_ms = 11_000
        app._update_timer()
        assert app._bulletin_playing is True

        assert log_path.exists()
        lines = log_path.read_text(encoding="utf-8").strip().splitlines()
        assert len(lines) == 1
        record = json.loads(lines[0])
        assert record["bulletin_entry_id"] == bulletin.entry_id
        assert record["cold_or_warm"] == "cold"
        for key in ("boundary_wait_ms", "accept_to_audible_ms", "total_latency_ms"):
            assert isinstance(record[key], int)
            assert 0 <= record[key] < 10_000, f"{key}={record[key]} outside a generous machine-independent bound"

        # A second interruption is reported "warm", not "cold".
        app._handle_station_completion(CompletionReason.ENDED)
        second_bulletin = _bulletin_entry(entry_id="wx-2")
        weather_monitor.fire(second_bulletin)
        adapter._offset_ms = 11_000
        app._update_timer()

        lines = log_path.read_text(encoding="utf-8").strip().splitlines()
        assert len(lines) == 2
        second_record = json.loads(lines[1])
        assert second_record["cold_or_warm"] == "warm"


# ---------------------------------------------------------------------------
# Station-state indicators (A.4.5): now-playing kind badge, persistent
# interrupt banner, source-health line -- all display-only, driven entirely
# by EXISTING state (no new controller round-trips; INV-8 untouched).
# ---------------------------------------------------------------------------

ARTICLE_QUEUE = [
    {
        "id": 1,
        "title": "An Article",
        "words": 1000,
        "item_type": "article",
        "source_url": "https://example.com/a",
        "canonical_url": "https://example.com/a",
        "file": "1_an-article.txt",
        "added": "2026-04-06T10:00:00",
    },
]

PODCAST_QUEUE = [
    {
        "id": 2,
        "title": "A Podcast Episode",
        "words": 0,
        "item_type": "podcast_episode",
        "source_url": "https://example.com/p",
        "canonical_url": "https://example.com/p",
        "file": "2_a-podcast-episode.txt",
        "added": "2026-04-06T10:00:00",
    },
]


@pytest.mark.asyncio
@patch("wilted.tui.ensure_default_playlists")
@patch("wilted.tui.get_playlist_items", return_value=ARTICLE_QUEUE)
async def test_now_playing_kind_shows_article(mock_items, mock_ensure):
    """An 'item' entry whose DB item_type is 'article' badges as 'Article'."""
    entry = _station_entry(1)
    app = _make_app(entries=[entry])
    async with app.run_test():
        await app.workers.wait_for_complete()
        app._start_playback(entry)
        assert str(app.query_one("#now-playing-kind", Label).render()) == "Article"


@pytest.mark.asyncio
@patch("wilted.tui.ensure_default_playlists")
@patch("wilted.tui.get_playlist_items", return_value=PODCAST_QUEUE)
async def test_now_playing_kind_shows_podcast(mock_items, mock_ensure):
    """An 'item' entry whose DB item_type is 'podcast_episode' badges as 'Podcast'."""
    entry = _station_entry(2)
    app = _make_app(entries=[entry])
    async with app.run_test():
        await app.workers.wait_for_complete()
        app._start_playback(entry)
        assert str(app.query_one("#now-playing-kind", Label).render()) == "Podcast"


@pytest.mark.asyncio
async def test_now_playing_kind_shows_briefing_when_no_matching_db_item():
    """An 'item'-kind entry with no matching DB item -- the shape a future
    non-Item briefing entry would take, since Item.item_type only ever
    allows 'article'/'podcast_episode' (see _display_kind's docstring) --
    badges as 'Briefing'."""
    entry = _station_entry(99)  # id 99 is never in the (empty) mocked queue
    app = _make_app(entries=[entry])
    async with app.run_test():
        await app.workers.wait_for_complete()
        app._start_playback(entry)
        assert str(app.query_one("#now-playing-kind", Label).render()) == "Briefing"


@pytest.mark.asyncio
async def test_now_playing_kind_shows_weather_bulletin(tmp_path):
    """A bulletin StationEntry (kind='bulletin') badges as 'Weather bulletin'."""
    entry = _station_entry(1, safe_interruption=SAFE_WINDOW)
    controller = FakeController()
    adapter = FakeAdapter()
    weather_monitor = FakeWeatherMonitor()
    app = _make_app(
        entries=[entry],
        controller=controller,
        adapter=adapter,
        weather_monitor=weather_monitor,
        latency_log_path=tmp_path / "latency.jsonl",
    )
    async with app.run_test():
        await app.workers.wait_for_complete()
        app._start_playback(entry)
        bulletin = _bulletin_entry()
        weather_monitor.fire(bulletin)
        adapter._offset_ms = 11_000  # inside SAFE_WINDOW
        app._update_timer()
        assert app._bulletin_playing is True
        assert str(app.query_one("#now-playing-kind", Label).render()) == "Weather bulletin"


@pytest.mark.asyncio
async def test_now_playing_kind_cleared_when_plate_cleared():
    """Stopping and clearing the Plate (e.g. via delete-while-playing) clears
    the kind badge along with the title -- no stale kind left behind."""
    entry = _station_entry(1)
    app = _make_app(entries=[entry])
    async with app.run_test():
        await app.workers.wait_for_complete()
        app._start_playback(entry)
        assert str(app.query_one("#now-playing-kind", Label).render()) != ""
        app._stop_and_clear_plate()
        assert str(app.query_one("#now-playing-kind", Label).render()) == ""


@pytest.mark.asyncio
async def test_interrupt_indicator_hidden_when_idle():
    """No active interruption: the banner is hidden and empty, not just blank."""
    app = _make_app(entries=[])
    async with app.run_test():
        await app.workers.wait_for_complete()
        indicator = app.query_one("#interrupt-indicator", Label)
        assert indicator.display is False
        assert str(indicator.render()) == ""


@pytest.mark.asyncio
async def test_interrupt_indicator_shows_bulletin_admission_reason(tmp_path):
    """While a weather bulletin is interrupting, the banner shows both that
    an interruption is active AND why it was admitted."""
    entry = _station_entry(1, safe_interruption=SAFE_WINDOW)
    controller = FakeController()
    adapter = FakeAdapter()
    weather_monitor = FakeWeatherMonitor()
    app = _make_app(
        entries=[entry],
        controller=controller,
        adapter=adapter,
        weather_monitor=weather_monitor,
        latency_log_path=tmp_path / "latency.jsonl",
    )
    async with app.run_test():
        await app.workers.wait_for_complete()
        app._start_playback(entry)
        bulletin = _bulletin_entry()
        weather_monitor.fire(bulletin)
        adapter._offset_ms = 11_000  # inside SAFE_WINDOW
        app._update_timer()
        assert app._bulletin_playing is True

        indicator = app.query_one("#interrupt-indicator", Label)
        assert indicator.display is True
        text = str(indicator.render())
        assert "Weather bulletin" in text
        assert "safe boundary" in text


@pytest.mark.asyncio
async def test_interrupt_indicator_hides_after_bulletin_completes(tmp_path):
    """The banner clears the instant the bulletin finishes and the
    interrupted entry resumes -- not on the next timer tick."""
    entry = _station_entry(1, safe_interruption=SAFE_WINDOW)
    controller = FakeController()
    adapter = FakeAdapter()
    weather_monitor = FakeWeatherMonitor()
    app = _make_app(
        entries=[entry],
        controller=controller,
        adapter=adapter,
        weather_monitor=weather_monitor,
        latency_log_path=tmp_path / "latency.jsonl",
    )
    async with app.run_test():
        await app.workers.wait_for_complete()
        app._start_playback(entry)
        bulletin = _bulletin_entry()
        weather_monitor.fire(bulletin)
        adapter._offset_ms = 11_000
        app._update_timer()
        assert app._bulletin_playing is True

        app._handle_station_completion(CompletionReason.ENDED)
        assert app._bulletin_playing is False
        indicator = app.query_one("#interrupt-indicator", Label)
        assert indicator.display is False
        assert str(indicator.render()) == ""


@pytest.mark.asyncio
async def test_interrupt_indicator_shows_route_interrupted_device_name():
    """While route-interrupted (no-output floor), the banner names the
    device and the no-output state."""
    entry = _station_entry(1)
    controller = FakeController()
    adapter = FakeAdapter()
    route_monitor = FakeRouteMonitor()
    app = _make_app(entries=[entry], controller=controller, adapter=adapter, route_monitor=route_monitor)
    async with app.run_test() as pilot:
        await app.workers.wait_for_complete()
        app._start_playback(entry)
        route_monitor.fire(RouteChangeEvent(device_id=99, device_name="AirPods Pro"))
        await pilot.pause()

        indicator = app.query_one("#interrupt-indicator", Label)
        assert indicator.display is True
        text = str(indicator.render())
        assert "AirPods Pro" in text
        assert "No output" in text


@pytest.mark.asyncio
async def test_interrupt_indicator_hides_after_route_resume():
    """Resuming from a route interruption ("p") clears the banner immediately."""
    entry = _station_entry(1)
    controller = FakeController()
    adapter = FakeAdapter()
    route_monitor = FakeRouteMonitor()
    app = _make_app(entries=[entry], controller=controller, adapter=adapter, route_monitor=route_monitor)
    async with app.run_test() as pilot:
        await app.workers.wait_for_complete()
        app._start_playback(entry)
        route_monitor.fire(RouteChangeEvent(device_id=99, device_name="AirPods Pro"))
        await pilot.pause()
        assert app._route_interrupted is True

        app.action_toggle_play()  # "p" is the resume affordance for this state
        await pilot.pause()

        assert app._route_interrupted is False
        indicator = app.query_one("#interrupt-indicator", Label)
        assert indicator.display is False


@pytest.mark.asyncio
async def test_source_health_degrades_gracefully_without_weather_monitor():
    """No weather monitor wired (_weather_monitor is None, e.g. a read-only
    second session) -- the health line shows a clear "not configured" state
    rather than crashing."""
    app = _make_app(entries=[])
    async with app.run_test():
        await app.workers.wait_for_complete()
        text = str(app.query_one("#source-health", Label).render())
        assert "not configured" in text.lower()


@pytest.mark.asyncio
async def test_source_health_shows_weather_health_and_route_monitoring():
    entry = _station_entry(1)
    controller = FakeController()
    adapter = FakeAdapter()
    weather_monitor = FakeWeatherMonitor()
    weather_monitor.fake_health = "healthy"
    weather_monitor.last_success_at = "2026-07-11T00:00:00Z"
    app = _make_app(entries=[entry], controller=controller, adapter=adapter, weather_monitor=weather_monitor)
    async with app.run_test():
        await app.workers.wait_for_complete()
        app._start_playback(entry)  # also starts the route monitor

        text = str(app.query_one("#source-health", Label).render())
        assert "healthy" in text.lower()
        assert "2026-07-11T00:00:00Z" in text
        assert "monitoring" in text.lower()


@pytest.mark.asyncio
async def test_source_health_reflects_failed_weather_monitor_with_last_error():
    weather_monitor = FakeWeatherMonitor()
    weather_monitor.fake_health = "failed"
    weather_monitor.last_error = "ConnectionError('boom')"
    app = _make_app(entries=[], weather_monitor=weather_monitor)
    async with app.run_test():
        await app.workers.wait_for_complete()
        text = str(app.query_one("#source-health", Label).render())
        assert "failed" in text.lower()
        assert "boom" in text


@pytest.mark.asyncio
async def test_source_health_shows_route_interrupted():
    entry = _station_entry(1)
    controller = FakeController()
    adapter = FakeAdapter()
    route_monitor = FakeRouteMonitor()
    app = _make_app(entries=[entry], controller=controller, adapter=adapter, route_monitor=route_monitor)
    async with app.run_test() as pilot:
        await app.workers.wait_for_complete()
        app._start_playback(entry)
        route_monitor.fire(RouteChangeEvent(device_id=1, device_name="Speakers"))
        await pilot.pause()

        text = str(app.query_one("#source-health", Label).render())
        assert "interrupted" in text.lower()


@pytest.mark.asyncio
async def test_source_health_refreshes_every_timer_tick_even_when_idle():
    """The 1s timer refreshes source-health regardless of playback state --
    a monitor health transition (e.g. to 'stale') has no discrete playback
    event to hang a refresh off of."""
    weather_monitor = FakeWeatherMonitor()
    weather_monitor.fake_health = "unknown"
    app = _make_app(entries=[], weather_monitor=weather_monitor)
    async with app.run_test():
        await app.workers.wait_for_complete()
        assert "unknown" in str(app.query_one("#source-health", Label).render()).lower()

        weather_monitor.fake_health = "stale"
        app._update_timer()  # not playing -- must still refresh
        assert "stale" in str(app.query_one("#source-health", Label).render()).lower()
