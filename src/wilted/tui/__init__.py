"""Textual TUI package for wilted.

WiltedApp is defined here (in __init__.py, not app.py) so that
``@patch("wilted.tui.get_playlist_items")`` and similar test patches intercept
calls made from WiltedApp methods — Python looks up free variables in the
containing module's __dict__ at call time, not at definition time.

Screens (AddArticleScreen, ConfirmScreen, etc.) are in tui/screens/.

INV-8 boundary (KEYSTONE refactor, Plan A task A.3.5): "station state" is the
reducer's ``StationState`` (lifecycle / active_entry / checkpoint / resume
offset). ALL writes to that state route through ``StationController.submit``/
``submit_and_wait`` — this module never calls ``wilted.station.reducer.apply``
directly and never writes a checkpoint itself (the ``CheckpointPoller`` does
that on a timer). The legacy per-paragraph resume mechanism
(``wilted.playlists.set_resume_position``/``get_resume_position``/
``clear_resume_position``) is fully retired from this module: resume-on-start
now comes from ``StationController.current_state().checkpoint``. Item-DB CRUD
(add/remove/mark-complete/clear) is a *different* store and is intentionally
NOT routed through the controller — see each action's docstring.
"""

from __future__ import annotations

import json
import logging
import os
import re
import time
import uuid
from datetime import UTC, datetime
from typing import TYPE_CHECKING, ClassVar

from textual import work
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical, VerticalScroll
from textual.message import Message
from textual.theme import Theme
from textual.widgets import Footer, Header, Label, Static, Tree
from textual.worker import get_current_worker

from wilted import ICONS, PROJECT_ROOT
from wilted.playlists import ensure_default_playlists, get_playlist_items
from wilted.queue import (
    clear_queue,
    get_article_text,
    mark_completed,
    remove_article_by_id,
)
from wilted.station.models import StationEntry, now_utc_z
from wilted.station.reducer import AcceptInterruption, Checkpoint, ResumeFromInterruption, StartPlayback, Stop
from wilted.station_runtime import (
    CheckpointPoller,
    LeaseHeldError,
    MacPlaybackAdapter,
    RouteChangeEvent,
    RouteMonitor,
    StationController,
    WeatherMonitor,
    media_store,
)
from wilted.station_runtime.sequencer import EntrySequencer
from wilted.text import split_paragraphs
from wilted.tui.screens.add_article import AddArticleScreen
from wilted.tui.screens.confirm import ConfirmScreen
from wilted.tui.screens.report import ReportScreen
from wilted.tui.screens.text_preview import TextPreviewScreen
from wilted.tui.screens.voice_settings import VoiceSettingsScreen

if TYPE_CHECKING:
    from pathlib import Path

    from wilted.station.models import TranscriptSegment
    from wilted.station_runtime import CompletionReason

logger = logging.getLogger(__name__)

# Status message priorities — higher priority messages hold for a minimum
# duration and won't be overwritten by lower-priority routine updates.
_STATUS_LOW = 0  # Routine: "Playing (cached)", "Generating audio..."
_STATUS_MEDIUM = 1  # Info: "Speed: 1.5x", "Ready", "Paused"
_STATUS_HIGH = 2  # Errors, important user actions

# Minimum seconds a high/medium-priority message stays visible
_STATUS_HOLD_SECS = 2.0

# Shared status text for every read-only refusal (lease held by another
# live session) — kept as one constant so all refusal sites stay in sync.
_STATION_READ_ONLY_MSG = "Station active in another session — read-only"

# ---------------------------------------------------------------------------
# Weather bulletin interrupt/resume (A.4.3)
# ---------------------------------------------------------------------------

# Generation budget once a safe boundary has actually been reached, measured
# in _update_timer ticks (the timer fires once per nominal second in
# production — see on_mount's set_interval(1.0, ...) — so a tick count is a
# generous, machine-independent proxy for "N seconds", and it makes tests
# deterministic without mocking wall-clock time). "Cold" (model not yet
# resident) vs "warm" (resident) can't be observed directly from the TUI
# without deeper coupling to ModelCoordinator internals that isn't wired
# anywhere else in this module, so this uses a simple, documented proxy
# instead: the FIRST bulletin this session is treated as cold, every
# subsequent one as warm (see WiltedApp._bulletin_interruptions_handled).
_BULLETIN_BUDGET_COLD_TICKS = 6
_BULLETIN_BUDGET_WARM_TICKS = 5

# Where the safe-boundary -> bulletin-audible latency artifact is appended
# (JSON Lines, one record per completed interruption). Overridable via
# WiltedApp(latency_log_path=...) so tests never touch the real repo tree.
_DEFAULT_LATENCY_LOG_PATH = PROJECT_ROOT / "reports" / "weather-bulletin-latency.jsonl"

# ---------------------------------------------------------------------------
# Salad Palette — custom Textual theme
# ---------------------------------------------------------------------------

SALAD_THEME = Theme(
    name="salad",
    primary="#8FBC8F",  # Dark Sea Green — headers, active play
    secondary="#A9BA9D",  # Sage — secondary text, read items
    accent="#F2E8CF",  # Cream/Parchment — focus, selection
    foreground="#D4D4D4",  # Light gray text
    background="#121212",  # Ebony — deep background
    surface="#1A1A2E",  # Dark surface for panels
    panel="#1A1A2E",  # Panel background
    success="#A7C957",  # Bright Lime — new/unread
    warning="#EBCB8B",  # Warm yellow
    error="#BC4749",  # Muted Red — stop, delete
    dark=True,
    variables={
        "footer-key-foreground": "#8FBC8F",
        "footer-description-foreground": "#A9BA9D",
        "block-cursor-text-style": "none",
        "input-selection-background": "#8FBC8F 35%",
    },
)

# Playback icon helpers (read from the ICONS dict in wilted.__init__)
_ICON_PLAYING = ICONS["playing"]
_ICON_PAUSED = ICONS["paused"]

# Fractional block characters for smooth progress bar fill
_BLOCKS = " ▏▎▍▌▋▊▉█"


class PlaybackCompleted(Message):
    """Posted by :meth:`WiltedApp._on_adapter_completion`; handled on the UI thread.

    ``MacPlaybackAdapter.on_complete`` fires on the audio background thread.
    This MUST be marshalled to the UI thread via ``post_message`` — thread-safe
    (uses ``loop.call_soon_threadsafe`` internally) and NON-blocking — rather
    than ``call_from_thread``. ``call_from_thread`` blocks the calling
    (audio) thread until the UI-thread callback returns, and a clean
    completion's auto-advance path (``_handle_station_completion`` ->
    ``_start_playback`` -> ``adapter.play``) preempts the current track,
    which joins that very same still-blocked audio thread — a guaranteed
    hang (up to the preempt's join timeout) on every natural track
    transition. ``post_message`` queues the event and returns immediately,
    so the audio thread has already exited by the time anything tries to
    join it.
    """

    def __init__(self, reason: CompletionReason) -> None:
        self.reason = reason
        super().__init__()


class RouteChanged(Message):
    """Posted by :meth:`WiltedApp._on_route_change`; handled on the UI thread.

    ``RouteMonitor.on_route_change`` fires on the backend's own delivery
    thread (for the real CoreAudio backend, its CFRunLoop pump thread) — see
    ``wilted.station_runtime.route_monitor``'s module docstring. Exactly like
    :class:`PlaybackCompleted`, this MUST be marshalled via ``post_message``,
    NEVER ``call_from_thread``: the handler (:meth:`WiltedApp.on_route_changed`)
    calls ``adapter.stop()``, which joins the adapter's background stream
    thread — routing through ``call_from_thread`` would block the CoreAudio
    delivery thread until that join (and everything after it) completes, the
    same deadlock class ``PlaybackCompleted``'s docstring documents for the
    audio thread.
    """

    def __init__(self, event: RouteChangeEvent) -> None:
        self.event = event
        super().__init__()


class WiltedApp(App):
    """Local TTS article reader — Textual TUI."""

    TITLE = "🥬 wilted"

    DEFAULT_CSS = """
    Screen {
        layout: horizontal;
    }
    #left-panel {
        width: 2fr;
        height: 100%;
        border-right: solid $primary;
        padding: 0 1;
    }
    #right-panel {
        width: 3fr;
        height: 100%;
        padding: 0 1;
    }
    #left-panel Label {
        width: 100%;
    }
    .panel-title {
        text-style: bold;
        color: $primary;
        margin-bottom: 1;
    }
    #playlist-tree {
        height: 1fr;
    }
    #now-playing-title {
        text-style: bold;
        color: $accent;
        margin-bottom: 0;
    }
    #now-playing-kind {
        color: $secondary;
        margin-bottom: 1;
    }
    #playback-bar {
        height: 1;
        margin: 1 0;
        color: $primary;
    }
    #interrupt-indicator {
        height: auto;
        text-style: bold;
        color: $warning;
        margin: 0 0 1 0;
    }
    #text-scroll {
        height: 1fr;
        min-height: 5;
        margin: 1 0;
        border: round $primary;
    }
    #current-text {
        padding: 1;
    }
    #speed-display {
        margin-top: 1;
        color: $secondary;
    }
    #source-health {
        color: $text-muted;
        margin-top: 1;
    }
    #status-line {
        text-style: italic;
        color: $text-muted;
        margin-top: 1;
    }
    #empty-message {
        margin-top: 2;
        text-style: italic;
        color: $text-muted;
    }
    """

    BINDINGS: ClassVar[list[Binding | tuple]] = [
        Binding("p,space", "toggle_play", "Play/Pause"),
        Binding("right,right_square_bracket", "skip_segment", ">>"),
        Binding("left_square_bracket", "prev_paragraph", "<<"),
        Binding("n", "next_article", "Next"),
        Binding("a", "add_article", "Add"),
        Binding("m", "mark_read", "Read"),
        Binding("d", "delete_selected", "Del"),
        Binding("t", "text_preview", "Text"),
        Binding("v", "voice_settings", "Voice", show=False),
        Binding("minus", "speed_down", show=False),
        Binding("equal,plus", "speed_up", show=False),
        Binding("c", "clear_all", show=False),
        Binding("w", "export_wav", show=False),
        Binding("r", "refresh_queue", show=False),
        Binding("q", "quit_app", "Quit"),
    ]

    def __init__(
        self,
        *,
        controller: StationController | None = None,
        adapter: MacPlaybackAdapter | None = None,
        sequencer_factory=None,
        poller_factory=None,
        route_monitor_factory=None,
        weather_monitor: WeatherMonitor | None = None,
        latency_log_path: Path | None = None,
        **kwargs,
    ) -> None:
        super().__init__(**kwargs)
        self.register_theme(SALAD_THEME)
        self.theme = "salad"

        # -- Station runtime (INV-8 single-writer plumbing) -----------------
        self._controller = (
            controller if controller is not None else StationController(holder_id=f"mac-tui-{os.getpid()}")
        )
        self._adapter = adapter if adapter is not None else MacPlaybackAdapter()
        # Always install the completion marshaller, for injected fakes AND
        # the default adapter alike.
        self._adapter.on_complete = self._on_adapter_completion
        self._sequencer_factory = sequencer_factory if sequencer_factory is not None else EntrySequencer.build
        self._poller_factory = poller_factory if poller_factory is not None else (lambda c, a: CheckpointPoller(c, a))
        self._poller = self._poller_factory(self._controller, self._adapter)
        self._poller_started: bool = False
        # RouteMonitor (A.3.3): mirrors _poller_factory/_poller exactly, but
        # is called with the on_route_change callback (what it needs)
        # instead of (controller, adapter) (what the poller needs) — same
        # "factory receives what it needs as an explicit argument"
        # convention, so a test factory never needs to close over `self`
        # before this app instance exists.
        self._route_monitor_factory = (
            route_monitor_factory
            if route_monitor_factory is not None
            else (lambda on_route_change: RouteMonitor(on_route_change=on_route_change))
        )
        self._route_monitor = self._route_monitor_factory(self._on_route_change)
        self._route_monitor_started: bool = False
        self._station_read_only: bool = False

        # WeatherMonitor (A.4.3): unlike the poller/route-monitor above,
        # there is NO safe default construction here — WeatherMonitor's own
        # design deliberately has no real-implementation default for
        # fetch/synth (see its class docstring: "so a test can never
        # accidentally construct a monitor that reaches a live NWS call or
        # loads a real TTS model"). Mirroring that here, `weather_monitor`
        # defaults to None (no monitor wired/started at all) rather than an
        # auto-constructed real one — the real embedded monitor is wired
        # explicitly by whatever launches the production TUI. When given,
        # this app wires ITS OWN `on_bulletin_ready` onto it (mirroring
        # `self._adapter.on_complete = self._on_adapter_completion` above)
        # and owns its start/stop lifecycle (see on_mount/on_unmount).
        self._weather_monitor = weather_monitor
        if self._weather_monitor is not None:
            self._weather_monitor.on_bulletin_ready = self._on_bulletin_ready
        self._weather_monitor_started: bool = False
        self._latency_log_path: Path = latency_log_path if latency_log_path is not None else _DEFAULT_LATENCY_LOG_PATH

        # -- Weather bulletin interruption state (A.4.3) ---------------------
        # `_pending_bulletin` is set by `_on_bulletin_ready` (the monitor's
        # handoff callback) and consumed by `_maybe_submit_pending_bulletin`
        # (driven off the existing 1s `_update_timer`) once playback is
        # actually sitting inside a real safe-interruption window. See those
        # methods' docstrings for the full state machine.
        self._pending_bulletin: StationEntry | None = None
        self._bulletin_playing: bool = False
        self._bulletin_wait_ticks: int = 0
        self._bulletin_fallback_shown_this_window: bool = False
        self._bulletin_interruptions_handled: int = 0
        self._bulletin_boundary_detected_monotonic: float | None = None
        self._bulletin_pending_since_monotonic: float | None = None

        # -- Station backlog / now-playing state -----------------------------
        self._station_entries: list[StationEntry] = []
        self._current_entry: StationEntry | None = None
        self._current_index: int | None = None
        self._pending_play_item_id: str | None = None

        # -- Route-change interruption state (A.3.3) --------------------------
        # Set by on_route_changed when a device switch interrupts active
        # playback; cleared on resume (_resume_from_route_interruption) or on
        # any explicit stop (action_stop). See on_route_changed's docstring.
        self._route_interrupted: bool = False
        self._route_device_name: str = ""
        self._route_resume_entry: StationEntry | None = None
        self._route_resume_offset_ms: int = 0

        # -- DB item cache (CRUD + display-title resolution; a DIFFERENT
        # store than station state — see module docstring) ------------------
        self._all_items: list[dict] = []
        self._item_lookup: dict[str, dict] = {}

        # -- TTS generation feeder (unrelated to station playback) -----------
        self._engine = None
        self._voice: str = "af_heart"
        from wilted import get_default_speed

        self._speed: float = get_default_speed()
        self._lang: str = "a"
        self._generation_paused: bool = False
        self._generation_worker = None

        # -- Display-only state -----------------------------------------------
        self._paragraphs: list[str] = []
        self._paragraph_idx: int = 0
        # The currently-playing entry's transcript segments (start_ms-ordered),
        # kept alongside _paragraphs so _update_timer can map a polled
        # current_offset_ms() back to a segment index. See _start_playback /
        # _update_timer / _segment_index_for_offset.
        self._current_segments: tuple[TranscriptSegment, ...] = ()
        self._playing: bool = False
        self._paused: bool = False
        self._status_priority: int = _STATUS_LOW
        self._status_time: float = 0.0
        self._estimated_remaining_secs: float = 0
        self._bar_progress: float = 0.0
        self._bar_time_override: str = ""

    def compose(self) -> ComposeResult:
        yield Header()
        with Horizontal():
            with Vertical(id="left-panel"):
                yield Label("The Larder", classes="panel-title")
                yield Tree("Playlists", id="playlist-tree")
                yield Label("", id="empty-message")
            with Vertical(id="right-panel"):
                yield Label("The Plate", classes="panel-title")
                yield Label("No article selected", id="now-playing-title")
                yield Label("", id="now-playing-kind")
                yield Static("", id="playback-bar")
                yield Label("", id="interrupt-indicator")
                with VerticalScroll(id="text-scroll"):
                    yield Static("", id="current-text", markup=True)
                yield Static("", id="speed-display")
                yield Label("", id="source-health")
                yield Label("", id="status-line")
        yield Footer()

    def on_mount(self) -> None:
        self._update_speed_display()
        self.query_one("#playlist-tree", Tree).focus()
        # 1-second timer for live playback countdown
        self.set_interval(1.0, self._update_timer)

        try:
            self._controller.start(on_loss=self._on_controller_loss)
        except LeaseHeldError:
            # Another live session already owns the station: enter a visible
            # read-only state rather than crash or attempt to steal the lease.
            self._station_read_only = True
            self._refresh_playlists()
            self._set_status(_STATION_READ_ONLY_MSG, _STATUS_HIGH)
        else:
            self._rebuild_sequencer()

        # WeatherMonitor (A.4.3): only the session actually holding the
        # station lease may interrupt playback, so only that session runs
        # detection/generation too — a read-only second session starting its
        # OWN poller would duplicate NWS polling and TTS synthesis for a
        # bulletin it could never actually submit (_maybe_submit_pending_bulletin
        # itself also guards on _station_read_only, defense in depth).
        if self._weather_monitor is not None and not self._station_read_only:
            self._weather_monitor.start()
            self._weather_monitor_started = True

        self._refresh_status_indicators()

        # Preload TTS model only if there are items that need TTS synthesis.
        # Pipeline items with audio_file set already have generated audio; skip.
        if any(not e.get("audio_file") for e in self._all_items):
            self._preload_model()
        # Check for unread report on launch
        self._check_unread_report()

    def on_unmount(self) -> None:
        """Best-effort teardown so the station lease/threads never outlive this app.

        A safety net for the (many) code paths that end the app without going
        through :meth:`action_quit_app` (e.g. a test's ``run_test()`` context
        exiting) — without this, the controller's OS-level flock and the
        poller/heartbeat/route-monitor/weather-monitor threads would leak
        past this app instance. All five calls are documented no-ops if
        never started, and idempotent with :meth:`action_quit_app` calling
        them again.
        """
        try:
            self._adapter.stop()
        except Exception:
            logger.exception("on_unmount: adapter.stop() failed")
        try:
            self._poller.stop()
        except Exception:
            logger.exception("on_unmount: poller.stop() failed")
        try:
            self._route_monitor.stop()
        except Exception:
            logger.exception("on_unmount: route_monitor.stop() failed")
        if self._weather_monitor is not None:
            try:
                self._weather_monitor.stop()
            except Exception:
                logger.exception("on_unmount: weather_monitor.stop() failed")
        try:
            self._controller.stop()
        except Exception:
            logger.exception("on_unmount: controller.stop() failed")

        # Task 4.4: session-end bulletin GC. on_unmount is the one hook every
        # exit path reaches exactly once (see docstring above), which is
        # what a sweep like this needs — no partial/duplicate runs. Ordered
        # last so it runs after every writer (controller, weather monitor)
        # has stopped, though correctness does not actually depend on that:
        # collect_expired_bulletins takes the same flock record_owner does,
        # and the reducer already refuses to hand a bulletin whose expiry
        # has passed to playback (StationEntry.is_expired), so a hash this
        # sweep collects can never be one something is still relying on —
        # in this session or any other live session sharing the data dir.
        try:
            media_store.collect_expired_bulletins(datetime.now(UTC))
        except Exception:
            logger.exception("on_unmount: collect_expired_bulletins() failed")

    def _on_controller_loss(self, exc: BaseException) -> None:
        """Invoked from the controller's drain thread if it enters terminal "lost" mode."""
        logger.error("Station controller lost: %s", exc)
        self.call_from_thread(self._set_status, "Station controller lost — playback unavailable", _STATUS_HIGH)

    # -- Report check -------------------------------------------------------

    def _check_unread_report(self) -> None:
        """Check if there's an unread report and show ReportScreen if so."""
        self._check_unread_report_worker()

    @work(thread=True, exclusive=True, group="report-check")
    def _check_unread_report_worker(self) -> None:
        """Check for unread report in a worker thread."""
        from wilted.db import worker_db
        from wilted.report import get_latest_unread_report, run_report

        try:
            with worker_db():
                from datetime import date

                from wilted.db import Report

                today = date.today().isoformat()
                # Generate report only if one doesn't exist for today
                if not Report.select().where(Report.report_date == today).exists():
                    run_report()
                report = get_latest_unread_report()
                if report:
                    self.call_from_thread(self.push_screen, ReportScreen(report), self._on_report_dismissed)
        except Exception as e:
            logger.warning("Failed to check for unread report: %s", e)

    def _on_report_dismissed(self, accepted: bool) -> None:
        """Called when ReportScreen is dismissed — refresh queue if items were accepted."""
        if accepted:
            self._refresh_playlists()

    # -- DB item cache (CRUD + display) --------------------------------------

    def _refresh_playlists(self) -> None:
        """Reload the DB item list used for CRUD lookups, display-title
        resolution, and the empty-state message.

        This does NOT touch the Larder tree — the tree is driven by the
        station backlog (see :meth:`_rebuild_sequencer`), a different concept
        from "everything ready/selected in the DB".

        No-ops if the app is shutting down/already stopped: this may be
        reached via ``call_from_thread`` from a background worker (e.g. the
        generation worker's post-completion rebuild) that can legitimately
        still be in flight after the app has begun tearing down its screen.
        """
        if not self.is_running:
            return
        ensure_default_playlists()
        self._all_items = get_playlist_items("All")
        self._item_lookup = {str(item["id"]): item for item in self._all_items}
        self._update_empty_message()

    def _update_empty_message(self) -> None:
        """PM-3: distinguish "nothing queued at all" from "queued but not finalized yet"."""
        if not self.is_running:
            return
        empty_msg = self.query_one("#empty-message", Label)
        if self._station_entries:
            empty_msg.display = False
            return
        if self._all_items:
            empty_msg.update("Items are being prepared — they'll appear here once ready.")
        else:
            empty_msg.update("The larder is empty. Press [a] to add an article.")
        empty_msg.display = True

    # -- Station backlog (Larder tree) ---------------------------------------

    def _rebuild_sequencer(self) -> None:
        """Refresh the DB item cache, then rebuild the station backlog off-thread."""
        self._refresh_playlists()
        self._build_sequencer_worker()

    @work(thread=True, exclusive=True, group="sequencer")
    def _build_sequencer_worker(self) -> None:
        """Build the station backlog in a worker thread.

        ``EntrySequencer.build()`` runs ffmpeg concat per article to check
        finalization and would freeze the UI if run on the main thread.
        """
        from wilted.db import worker_db

        try:
            with worker_db():
                sequencer = self._sequencer_factory()
                entries = list(sequencer.entries)
        except Exception:
            logger.exception("Failed to build station backlog")
            self.call_from_thread(self._set_status, "Error preparing station backlog", _STATUS_HIGH)
            return
        self.call_from_thread(self._apply_sequencer_result, entries)

    def _apply_sequencer_result(self, entries: list[StationEntry]) -> None:
        """Adopt a freshly-built backlog (main thread) and refresh the Larder tree.

        No-ops if the app has begun shutting down by the time this
        ``call_from_thread``-marshalled callback runs (see
        :meth:`_refresh_playlists`'s docstring for why that race is real).
        """
        if not self.is_running:
            return
        self._station_entries = entries
        self._current_index = self._index_of(self._current_entry) if self._current_entry is not None else None
        self._rebuild_larder_tree()
        self._update_empty_message()

        if self._pending_play_item_id is not None:
            pending_id = self._pending_play_item_id
            self._pending_play_item_id = None
            match = next((e for e in entries if e.item_id == pending_id), None)
            if match is not None:
                self._start_playback(match)
            else:
                self._set_status("Added — being prepared, will appear once ready", _STATUS_MEDIUM)

    def _rebuild_larder_tree(self) -> None:
        """Show ``self._station_entries`` as a flat list of leaves under the hidden root."""
        tree = self.query_one("#playlist-tree", Tree)
        tree.show_root = False
        tree.root.remove_children()
        for entry in self._station_entries:
            item = self._item_lookup.get(entry.item_id or "")
            title = item.get("title", "Untitled") if item else f"Entry {entry.entry_id}"
            if len(title) > 50:
                title = title[:47] + "..."
            words = item.get("words", 0) if item else 0
            tree.root.add_leaf(f"{title}  ({words}w)", data=entry)

    def _index_of(self, entry: StationEntry) -> int | None:
        for idx, candidate in enumerate(self._station_entries):
            if candidate.entry_id == entry.entry_id:
                return idx
        return None

    def _display_title(self, entry: StationEntry) -> str:
        item = self._item_lookup.get(entry.item_id or "")
        return item.get("title", "Untitled") if item else entry.entry_id

    # NOTE: deliberately no ``on_tree_node_selected`` handler. Textual's
    # ``Tree.select_node()`` (used throughout the test suite, and reachable
    # via keyboard) posts a ``NodeSelected`` message on every cursor move to
    # a node, not just an explicit "play this" gesture — wiring playback to
    # that message would start audio as a side effect of merely navigating
    # the Larder to delete/mark/preview an item. Playback-from-the-tree stays
    # on the explicit ``action_play_selected`` action (see BINDINGS to bind a
    # key to it), matching ``_get_selected_entry()``'s existing "currently
    # highlighted node" semantics used by toggle-play/mark/delete/etc.

    def _update_speed_display(self) -> None:
        spd = f"{self._speed:.1f}x"
        self.query_one("#speed-display", Static).update(
            f"Speed: {spd}  "
            "[@click=app.speed_down]◀[/]  "
            "[@click=app.speed_up]▶[/]  "
            "│  "
            "[@click=app.voice_settings]voice[/]"
        )

    def _update_now_playing(
        self,
        title: str = "",
        progress: float = 0.0,
        time_remaining: str = "",
        text_snippet: str = "",
        status: str = "",
    ) -> None:
        # Reachable via a completion/teardown race (see `_refresh_playlists`'s
        # docstring for why this is a real race, not just a test artifact).
        if not self.is_running:
            return
        if title:
            widget = self.query_one("#now-playing-title", Label)
            widget.update(title)
            widget.refresh()
        self._bar_progress = progress
        self._bar_time_override = time_remaining
        self._update_playback_bar()
        if text_snippet:
            widget = self.query_one("#current-text", Static)
            widget.update(text_snippet)
            widget.refresh()
            self.query_one("#text-scroll", VerticalScroll).scroll_home(animate=False)
        if status:
            self._set_status(status)
        self.screen.refresh()

    def _update_playback_bar(self) -> None:
        """Render the PlaybackBar with state icon, progress, para count, and timer."""
        # State icon
        if self._paused:
            icon = _ICON_PAUSED
        elif self._playing:
            icon = _ICON_PLAYING
        else:
            icon = ""

        # Progress bar — fractional block characters for smooth fill
        bar_width = 20
        frac = max(0.0, min(self._bar_progress / 100, 1.0))
        total_eighths = int(frac * bar_width * 8)
        full_blocks = total_eighths // 8
        remainder = total_eighths % 8
        bar_str = "█" * full_blocks
        if remainder > 0 and full_blocks < bar_width:
            bar_str += _BLOCKS[remainder]
            bar_str += "░" * (bar_width - full_blocks - 1)
        else:
            bar_str += "░" * (bar_width - full_blocks)

        # Paragraph counter
        if self._paragraphs:
            total = len(self._paragraphs)
            current = min(self._paragraph_idx + 1, total)
            para_info = f"{current}/{total}"
        else:
            para_info = ""

        # Timer — use override (for export) or live countdown
        if self._bar_time_override:
            time_str = self._bar_time_override
        else:
            secs = max(0, int(self._estimated_remaining_secs))
            m, s = divmod(secs, 60)
            time_str = f"~{m}:{s:02d}" if secs > 0 or self._playing else ""

        parts = [p for p in [icon, bar_str, para_info, time_str] if p]
        self.query_one("#playback-bar", Static).update("  ".join(parts))

    # -- Station-state indicators (A.4.5, display-only) ----------------------
    #
    # Three widgets, all pure renderers of EXISTING state (no new controller
    # round-trips, INV-8 untouched): #now-playing-kind (content kind badge,
    # set directly by _start_playback/_play_bulletin next to the title),
    # #interrupt-indicator (persistent banner for the two interrupting
    # states), and #source-health (weather/route monitor status line).

    def _display_kind(self, entry: StationEntry) -> str:
        """Human-readable content kind for the now-playing badge.

        ``StationEntry.kind`` is only ever ``"item"`` or ``"bulletin"`` (see
        its class docstring) — the finer podcast/article/briefing
        distinction lives in the DB item's ``item_type``, resolved via
        ``_item_lookup``. An ``"item"`` entry with no matching DB item
        (``item_id`` unset, or not found) is displayed as "Briefing": the
        shape a future non-Item briefing entry would take, since
        ``Item.item_type`` only ever allows ``"article"``/``"podcast_episode"``
        — a briefing can never BE a durable Item (see ``station_runtime.briefing``).
        """
        if entry.kind == "bulletin":
            return "Weather bulletin"
        item = self._item_lookup.get(entry.item_id or "")
        item_type = item.get("item_type") if item is not None else None
        if item_type == "podcast_episode":
            return "Podcast"
        if item_type == "article":
            return "Article"
        return "Briefing"

    def _update_interrupt_indicator(self) -> None:
        """Persistent interrupt banner.

        Unlike ``#status-line`` (transient — holds for ``_STATUS_HOLD_SECS``
        then is overwritten by the next routine update), this stays visible
        for the FULL duration of an active interruption, so a glance at the
        screen always shows whether one is in progress and why it was
        admitted. Exactly two interrupting states exist today: a weather
        bulletin (A.4.3) or a route/device-change no-output floor (A.3.3);
        hidden (no space taken) otherwise.
        """
        if not self.is_running:
            return
        widget = self.query_one("#interrupt-indicator", Label)
        if self._bulletin_playing:
            widget.update("⚠ Weather bulletin interrupting — admitted at safe boundary")
            widget.display = True
        elif self._route_interrupted:
            widget.update(f"⏸ No output — route changed to '{self._route_device_name}'. Press [p] to resume.")
            widget.display = True
        else:
            widget.update("")
            widget.display = False

    def _update_source_health(self) -> None:
        """Compact weather-monitor + route-monitor health line.

        Degrades gracefully when no weather monitor is wired
        (``_weather_monitor is None`` — e.g. a read-only second session, or
        a launch that never wired one): shows "not configured" rather than
        raising. Route status reads the same ``_route_interrupted``/
        ``_route_monitor_started`` fields :meth:`_update_interrupt_indicator`
        and :meth:`on_route_changed` already maintain — no new state.
        """
        if not self.is_running:
            return
        if self._weather_monitor is None:
            weather_text = "Weather: not configured"
        else:
            health = self._weather_monitor.health()
            last_error = self._weather_monitor.last_error
            last_success = self._weather_monitor.last_success_at
            if health == "failed" and last_error:
                weather_text = f"Weather: failed ({last_error})"
            elif last_success:
                weather_text = f"Weather: {health} (last success {last_success})"
            else:
                weather_text = f"Weather: {health}"
        if self._route_interrupted:
            route_text = "Route: interrupted"
        elif self._route_monitor_started:
            route_text = "Route: monitoring"
        else:
            route_text = "Route: idle"
        self.query_one("#source-health", Label).update(f"{weather_text}   {route_text}")

    def _refresh_status_indicators(self) -> None:
        """Refresh the interrupt banner + source-health line together —
        called at every station-state transition that could affect either,
        so both stay in sync with ``_bulletin_playing``/``_route_interrupted``/
        ``_route_monitor_started``/``_weather_monitor`` without a dedicated
        timer (the 1s ``_update_timer`` also refreshes source-health every
        tick, for staleness/health transitions that happen with no discrete
        event to hang a call off of)."""
        self._update_interrupt_indicator()
        self._update_source_health()

    def _update_timer(self) -> None:
        """1-second interval: tick down the remaining estimate, refresh the
        bar, and (when the current entry has transcript segments) drive live
        per-segment transcript scrolling.

        ``MacPlaybackAdapter`` has no per-segment progress callback (and none
        is added — see the class docstring / A.3.5 report), so this polls
        the adapter's existing ``current_offset_ms()`` directly from the UI
        thread on the app's existing 1-second timer: a plain, non-blocking
        getter call, no new threads. The countdown/bar tick always runs while
        playing-and-not-paused; the segment lookup only runs when
        ``self._paragraphs`` is non-empty (entries with no transcript
        segments simply don't scroll — see :meth:`_start_playback`).
        """
        if not self.is_running:
            return

        # Source-health (staleness/failure transitions have no discrete event
        # to hang a call off of) refreshes every tick regardless of playback
        # state; everything else below is playing-and-not-paused only.
        self._update_source_health()

        if not self._playing or self._paused:
            return

        self._maybe_submit_pending_bulletin()

        if self._paragraphs:
            offset_ms = self._adapter.current_offset_ms()
            new_idx = self._segment_index_for_offset(offset_ms)
            if new_idx != self._paragraph_idx:
                self._paragraph_idx = new_idx
                self.query_one("#current-text", Static).update(self._build_transcript(new_idx))
                self.query_one("#text-scroll", VerticalScroll).scroll_home(animate=False)

        self._estimated_remaining_secs = max(0, self._estimated_remaining_secs - 1)
        self._update_playback_bar()

    def _segment_index_for_offset(self, offset_ms: int) -> int:
        """Map a media offset (ms) to an index into ``self._current_segments``.

        Returns the index of the LAST segment whose ``start_ms <= offset_ms``
        (segments are ordered by ``start_ms`` per
        :class:`~wilted.station.models.TranscriptSegment`'s contract), i.e.
        the segment currently playing at ``offset_ms``. Returns 0 if there
        are no segments, or if ``offset_ms`` precedes the first segment.
        """
        if not self._current_segments:
            return 0
        idx = 0
        for i, seg in enumerate(self._current_segments):
            if seg.start_ms <= offset_ms:
                idx = i
            else:
                break
        return idx

    def _clear_transcript_state(self) -> None:
        """Reset read-along display state so a stopped/completed track
        doesn't keep showing (or scrolling) stale transcript text.

        Called from :meth:`action_stop` and :meth:`_handle_station_completion`.
        ``_update_timer``'s ``self._playing`` guard already prevents further
        scrolling once playback ends, so this is display hygiene (clearing
        the pane/paragraph-counter), not a fix for a still-running timer.
        """
        self._paragraphs = []
        self._paragraph_idx = 0
        self._current_segments = ()
        if self.is_running:
            self.query_one("#current-text", Static).update("")

    def _build_transcript(self, para_idx: int) -> str:
        """Build Rich markup showing paragraphs around the current one.

        Fed by the station playback path via :meth:`_start_playback` (initial
        render) and :meth:`_update_timer` (live per-segment scrolling, driven
        by polling ``current_offset_ms()`` — see that method's docstring for
        why this is UI-thread polling rather than an adapter callback). Also
        still exercised directly by
        ``test_transcript_markup_bold_current``/``test_transcript_escapes_brackets``.
        """
        from rich.markup import escape

        if not self._paragraphs:
            return ""
        lines: list[str] = []
        start = max(0, para_idx - 1)
        end = min(len(self._paragraphs), para_idx + 3)
        for i in range(start, end):
            text = escape(self._paragraphs[i])
            if i < para_idx:
                lines.append(f"[#A9BA9D]{text}[/#A9BA9D]")
            elif i == para_idx:
                lines.append(f"[bold #F2E8CF]{text}[/bold #F2E8CF]")
            else:
                lines.append(f"[dim #A9BA9D]{text}[/dim #A9BA9D]")
        return "\n\n".join(lines)

    def _set_status(self, msg: str, priority: int = _STATUS_LOW) -> None:
        """Update the status line, respecting message priorities.

        Higher-priority messages hold for _STATUS_HOLD_SECS and won't be
        overwritten by lower-priority routine updates during that window.

        No-ops if the app is shutting down: reachable via ``call_from_thread``
        from several background workers (generation, preload, report-check,
        export) whose tail call can legitimately still be in flight after the
        app has begun tearing down its screen (see ``_refresh_playlists``'s
        docstring for why this race is real, not just a test artifact).
        """
        if not self.is_running:
            return
        now = time.time()
        if priority < self._status_priority and now - self._status_time < _STATUS_HOLD_SECS:
            return
        self._status_priority = priority
        self._status_time = now
        self.query_one("#status-line", Label).update(msg)

    # -- Engine lazy load (TTS generation feeder only) -----------------------

    def _ensure_engine(self) -> None:
        """Lazy-load the AudioEngine on first use."""
        if self._engine is None:
            from wilted.engine import AudioEngine

            self._engine = AudioEngine(lang=self._lang)

    @work(thread=True, exclusive=True, group="preload")
    def _preload_model(self) -> None:
        """Eagerly load the TTS model in the background at startup.

        Note: we intentionally do NOT wrap load_model() in
        suppress_subprocess_output(). That context manager redirects OS-level
        fd 1/2 to /dev/null, which blinds Textual's renderer for the entire
        ~1.6 s model load and makes the UI appear frozen. The model produces
        no stdout/stderr output when cached (the common case). First-time
        downloads may print progress bars, but that one-time noise is
        preferable to a frozen UI on every launch.
        """
        try:
            self._ensure_engine()
            self.call_from_thread(self._set_status, "Loading TTS model...")
            self._engine.load_model()
            # Only clear status if it still says "Loading" — avoid clobbering
            # messages set by other actions while the model was loading.
            status_widget = self.query_one("#status-line", Label)
            if "Loading" in str(status_widget.render()):
                self.call_from_thread(self._set_status, "Ready")
            # Start background generation now that model is loaded
            self.call_from_thread(self._trigger_generation)
        except Exception:
            # Non-fatal — model will load on first play instead
            pass

    # -- Background generation worker (finalization feeder) ------------------

    @work(thread=True, exclusive=True, group="generate")
    def _generate_cache(self) -> None:
        """Background worker: generate audio cache for queued articles.

        This is what makes an article *finalizable* — once its per-paragraph
        cache is complete, the next station backlog rebuild can normalize and
        include it (see ``wilted.station_runtime.normalize.normalize_item``).
        """
        from wilted.cache import generate_article_cache, is_cache_valid
        from wilted.playlists import get_playlist_items as _get_playlist_items
        from wilted.queue import get_article_text

        worker = get_current_worker()

        self._ensure_engine()
        engine = self._engine
        engine.load_model()  # no-op if preload already finished

        try:
            queue = _get_playlist_items("All")
        except ValueError:
            # Playlists may not be initialised yet (e.g. during tests).
            return
        for entry in queue:
            if worker.is_cancelled:
                break

            # Pipeline items already have pre-generated audio; skip TTS for them.
            if entry.get("audio_file"):
                continue

            article_id = entry["id"]
            added = entry.get("added", "")
            voice, lang, speed = self._voice, self._lang, self._speed

            if is_cache_valid(article_id, voice, lang, speed, added):
                continue

            text = get_article_text(entry)
            if not text:
                continue

            title = entry.get("title", "Untitled")

            def on_progress(para_idx, total):
                if not self._playing:
                    self.call_from_thread(
                        self._set_status,
                        f"Generating audio: {title[:30]} — para {para_idx + 1}/{total}",
                    )

            def should_cancel():
                if worker.is_cancelled:
                    return True
                # Spin-wait while generation is paused (playback active)
                while self._generation_paused and not worker.is_cancelled:
                    time.sleep(0.1)
                return worker.is_cancelled

            generate_article_cache(
                engine,
                text,
                article_id,
                voice,
                lang,
                speed,
                added,
                on_progress=on_progress,
                should_cancel=should_cancel,
            )

        if not worker.is_cancelled:
            # A newly-finalized article may now be eligible for the station
            # backlog — rebuild so it appears in the Larder.
            self.call_from_thread(self._rebuild_sequencer)
            if not self._playing:
                self.call_from_thread(self._set_status, "Ready")

    def _trigger_generation(self) -> None:
        """Start or restart the background generation worker."""
        if self._generation_worker and self._generation_worker.is_running:
            self._generation_worker.cancel()
        self._generation_worker = self._generate_cache()

    # -- Playback (INV-8 core) ------------------------------------------------

    def _start_playback(self, entry: StationEntry) -> None:
        """Start playing a station entry through the controller + adapter.

        The ONLY write path for starting playback: ``StartPlayback`` is
        submitted through :attr:`_controller` (SR-1/INV-8) before anything
        else happens. Resume offset comes from the controller's current
        checkpoint (only honored when it belongs to THIS entry — a stale
        checkpoint from a different entry must never leak into a fresh
        entry's start position); periodic checkpoints during playback are
        written by the ``CheckpointPoller``, never by this method.
        """
        if self._station_read_only:
            self._set_status(_STATION_READ_ONLY_MSG, _STATUS_HIGH)
            return

        # Guard: if already playing this exact entry, treat as toggle.
        if self._playing and self._current_entry is not None and entry.entry_id == self._current_entry.entry_id:
            self.action_toggle_play()
            return

        # Read any existing checkpoint BEFORE submitting StartPlayback. The
        # reducer's StartPlayback transition (idle -> playing(entry))
        # unconditionally clears the checkpoint on every call — reading it
        # AFTER submission would always observe None, so resume would never
        # work. The pre-submit checkpoint can still be valid for THIS entry
        # (e.g. a checkpoint left by a prior playing session for the same
        # entry — app restart, or re-selecting the currently-paused entry);
        # it is only honored when it belongs to this exact entry, never a
        # stale checkpoint from a different one.
        prior_checkpoint = self._controller.current_state().checkpoint
        offset_ms = (
            prior_checkpoint.media_offset_ms
            if (prior_checkpoint is not None and prior_checkpoint.entry_id == entry.entry_id)
            else 0
        )

        try:
            result = self._controller.submit_and_wait(StartPlayback(entry=entry), timeout=5.0)
        except Exception as e:
            self._set_status(f"Station error: {e}", _STATUS_HIGH)
            return
        if not result.accepted:
            self._set_status("Could not start playback", _STATUS_HIGH)
            return

        try:
            self._adapter.play(entry.media, offset_ms=offset_ms)
        except Exception as e:
            self._set_status(f"Playback error: {e}", _STATUS_HIGH)
            self._generation_paused = False  # don't leave generation paused forever on a failed start
            if self._controller.is_running:
                self._controller.submit(Stop())
            return

        self._generation_paused = True  # Pause background generation during playback
        self._current_entry = entry
        self._current_index = self._index_of(entry)
        self._playing = True
        self._paused = False

        # Read-along state, seeded from THIS entry's own transcript segments
        # (empty tuple if it has none — no scroll for those, per
        # _update_timer). _paragraph_idx starts at the segment containing the
        # resume offset, not always 0, so a resumed entry doesn't visually
        # rewind its transcript to the start.
        self._current_segments = entry.media.transcript_segments
        self._paragraphs = [seg.text for seg in self._current_segments]
        self._paragraph_idx = self._segment_index_for_offset(offset_ms) if self._paragraphs else 0

        duration_s = entry.duration_ms / 1000 if entry.duration_ms else 0.0
        self._estimated_remaining_secs = max(0.0, duration_s - offset_ms / 1000)
        self._bar_progress = (offset_ms / entry.duration_ms * 100) if entry.duration_ms else 0.0

        self._update_now_playing(title=self._display_title(entry), progress=self._bar_progress, status="Playing")
        if self.is_running:
            self.query_one("#now-playing-kind", Label).update(self._display_kind(entry))

        # Initial transcript render so the pane isn't blank at play start;
        # _update_timer takes over live scrolling from here. No-op display
        # (pane cleared) for entries with no transcript segments.
        if self.is_running:
            current_text = self.query_one("#current-text", Static)
            if self._paragraphs:
                current_text.update(self._build_transcript(self._paragraph_idx))
                self.query_one("#text-scroll", VerticalScroll).scroll_home(animate=False)
            else:
                current_text.update("")

        if not self._poller_started:
            self._poller.start()
            self._poller_started = True
        if not self._route_monitor_started:
            self._route_monitor.start()
            self._route_monitor_started = True

        # A fresh/resumed entry always supersedes any interrupting state
        # (route-interrupted is already cleared before this call on the
        # resume path; bulletin state is unaffected here since a bulletin
        # is played via _play_bulletin, never _start_playback — see that
        # method's docstring) -- refresh so the banner/health line reflect
        # the entry that is now ACTUALLY playing.
        self._refresh_status_indicators()

    # -- Weather bulletin interrupt/resume (A.4.3) ---------------------------

    def _on_bulletin_ready(self, bulletin: StationEntry) -> None:
        """Callback wired as ``WeatherMonitor.on_bulletin_ready`` (mirrors
        ``MacPlaybackAdapter.on_complete`` / ``RouteMonitor.on_route_change``'s
        injectable-callback seam). Runs on the monitor's OWN poll thread (see
        ``WeatherMonitor._poll_loop``), so -- exactly like
        :class:`PlaybackCompleted`/:class:`RouteChanged` -- this must never
        touch Textual widgets or submit a controller action directly from
        this thread. Unlike those two, though, there is no need to marshal
        onto the UI thread via ``post_message``: setting
        ``self._pending_bulletin`` is a single reference assignment (atomic
        under the GIL), and the actual safe-boundary submit only ever
        happens later, from :meth:`_maybe_submit_pending_bulletin` on the UI
        thread's existing 1s timer -- so a plain attribute write here is
        sufficient.

        A second bulletin arriving while one is already pending (or already
        playing) replaces the pending slot (last-one-wins) rather than
        queuing: nested/queued weather bulletins are out of scope here (the
        monitor's own escalation-aware dedup is what keeps this rare), and
        there is no mechanism to play two pending bulletins before either
        reaches a safe boundary.

        Cross-thread smell (accepted, not fixed): a bulletin arriving here
        and overwriting ``self._pending_bulletin`` WHILE ``_accept_pending_bulletin``
        is already mid-flight for the previous one (on the UI thread) can be
        silently dropped -- that method unconditionally clears
        ``self._pending_bulletin`` on acceptance, with no check that it still
        refers to the same bulletin it started with. Benign in practice: the
        monitor's own dedup/escalation logic is what keeps concurrent
        bulletins rare in the first place.
        """
        self._pending_bulletin = bulletin
        self._bulletin_pending_since_monotonic = time.monotonic()
        self._bulletin_wait_ticks = 0
        self._bulletin_fallback_shown_this_window = False

    def _maybe_submit_pending_bulletin(self) -> None:
        """Called every tick from :meth:`_update_timer`. Submits the pending
        weather bulletin's ``AcceptInterruption`` the instant playback is
        ACTUALLY sitting inside a real safe-interruption window.

        HAZARD 2 (real-time safe-boundary accept): the offset passed to
        ``AcceptInterruption`` must be the LIVE ``adapter.current_offset_ms()``
        read right now, never a precomputed/future safe-window bound --
        otherwise the reducer would accept immediately (the static map says
        the offset is safe) but checkpoint the interrupted entry at a FUTURE
        offset, and resume would then skip the audio in between. Only this
        method (via the adapter) has that live offset.
        """
        if (
            self._pending_bulletin is None
            or not self._playing
            or self._paused
            or self._bulletin_playing
            or self._station_read_only
            or self._current_entry is None
        ):
            return

        offset_ms = self._adapter.current_offset_ms()
        at_safe_point = self._current_entry.media.safe_interruption.safe_point_at(offset_ms)

        if not at_safe_point:
            # Not (or no longer) inside a safe window -- rearm the
            # wait/fallback gate AND the boundary-detected timestamp so the
            # NEXT boundary gets its own fresh budget, its own fallback
            # notice, and an accurate boundary-wait latency measurement
            # (without this reset, re-entering a later window would keep
            # reporting boundary-wait from the FIRST window ever detected,
            # not the one that actually led to the eventual accept).
            self._bulletin_wait_ticks = 0
            self._bulletin_fallback_shown_this_window = False
            self._bulletin_boundary_detected_monotonic = None
            return

        if self._bulletin_boundary_detected_monotonic is None:
            self._bulletin_boundary_detected_monotonic = time.monotonic()

        bulletin = self._pending_bulletin
        if not bulletin.media.is_playable:
            # Defensive: the reducer would reject a non-playable bulletin
            # anyway (see reducer._accept_interruption), but this TUI must
            # not even attempt it -- fall back instead. In the real monitor
            # flow a handed-off bulletin is always already fully generated
            # and published (Task 4.2's off-the-interrupt-path pregeneration
            # guarantees FinalizationState.complete()), so this branch is a
            # safety net, not the expected steady state.
            self._handle_bulletin_not_playable_at_boundary(bulletin)
            return

        self._accept_pending_bulletin(bulletin, offset_ms)

    def _handle_bulletin_not_playable_at_boundary(self, bulletin: StationEntry) -> None:
        """A safe boundary was reached but the pending bulletin still isn't
        playable. Waits up to the cold/warm generation budget (in
        ``_update_timer`` ticks -- see the module-level constants' docstring)
        before taking the audible+visual fallback and deferring to the next
        safe boundary. Never submits a broken ``AcceptInterruption``."""
        if self._bulletin_fallback_shown_this_window:
            return  # already notified for this boundary encounter; wait for the next one

        self._bulletin_wait_ticks += 1
        budget_ticks = (
            _BULLETIN_BUDGET_WARM_TICKS if self._bulletin_interruptions_handled > 0 else _BULLETIN_BUDGET_COLD_TICKS
        )
        if self._bulletin_wait_ticks < budget_ticks:
            return

        self._bulletin_fallback_shown_this_window = True
        logger.warning(
            "Weather bulletin %s: still not playable %d ticks after reaching a safe boundary "
            "(budget %d) -- falling back to a visible notice; will retry at the next safe boundary",
            bulletin.entry_id,
            self._bulletin_wait_ticks,
            budget_ticks,
        )
        # Audible+visual fallback (no silent drop): a guaranteed-visible,
        # held status-line banner. A synthesized spoken "canned/degraded"
        # announcement was not implemented -- there is no existing canned
        # audio asset/generation path to draw on -- see the task report for
        # this documented scope call.
        self._set_status("⚠ Weather alert pending — audio not ready, will interrupt shortly", _STATUS_HIGH)

    def _accept_pending_bulletin(self, bulletin: StationEntry, offset_ms: int) -> None:
        """Submit ``AcceptInterruption`` at the REAL current offset (hazard 2)."""
        # HAZARD 1 (poller clobber): stop the poller BEFORE even submitting
        # AcceptInterruption -- not just before playing the bulletin.
        # Stopping only after a successful submit_and_wait() would leave a
        # short race window between the accept's reducer transition landing
        # (active_entry -> bulletin, checkpoint -> the interrupted entry's
        # accept-time resume checkpoint) and this thread reaching
        # poller.stop(): a poll tick landing in that window would read the
        # NEW active_entry (the bulletin, now PLAYING) together with the
        # adapter's OLD offset (adapter.play() for the bulletin hasn't run
        # yet), and submit a Checkpoint that overwrites the resume checkpoint
        # with a mismatched entry_id -- silently making _start_playback fall
        # back to offset 0 on resume instead of the real interrupt offset.
        # poller.stop() blocks until the poll thread has fully joined
        # (bounded), so stopping first closes the window completely rather
        # than merely narrowing it. Restarted below on any non-acceptance
        # path (nothing actually got interrupted), and otherwise only once
        # the interrupted entry is actually resumed (_start_playback in
        # _handle_bulletin_completion below).
        self._poller.stop()
        self._poller_started = False

        action = AcceptInterruption(
            bulletin=bulletin,
            interrupt_offset_ms=offset_ms,
            policy_current=True,
            now=now_utc_z(),
        )
        try:
            result = self._controller.submit_and_wait(action, timeout=5.0)
        except Exception:
            logger.exception("Weather bulletin %s: AcceptInterruption submission failed", bulletin.entry_id)
            self._poller.start()
            self._poller_started = True
            return

        if not result.accepted:
            logger.info(
                "Weather bulletin %s: AcceptInterruption rejected at offset %d ms -- will retry at the "
                "next safe boundary",
                bulletin.entry_id,
                offset_ms,
            )
            self._poller.start()
            self._poller_started = True
            return

        self._pending_bulletin = None
        self._bulletin_wait_ticks = 0
        self._bulletin_fallback_shown_this_window = False

        self._play_bulletin(bulletin)

    def _play_bulletin(self, bulletin: StationEntry) -> None:
        """Play an already-ACCEPTED bulletin directly via the adapter.

        Deliberately bypasses :meth:`_start_playback`'s controller
        submission. The station state was already correctly transitioned to
        playing(bulletin) by the just-accepted ``AcceptInterruption`` --
        which pushed the interrupted entry onto ``interruption_stack`` and
        wrote its resume ``checkpoint``. Reusing ``_start_playback`` here
        would submit a REDUNDANT ``StartPlayback`` action, and the reducer's
        ``StartPlayback`` transition (``reducer._start_playback``)
        UNCONDITIONALLY clears BOTH ``checkpoint`` AND
        ``interruption_stack`` on every call (it has no "already
        interrupted" precondition) -- silently discarding the just-pushed
        interrupted entry before :class:`ResumeFromInterruption` ever gets a
        chance to pop it back. This is the load-bearing reason a bulletin
        needs its OWN play path instead of ``_start_playback``.
        """
        try:
            self._adapter.play(bulletin.media, offset_ms=0)
        except Exception as e:
            logger.exception("Weather bulletin %s: adapter.play failed", bulletin.entry_id)
            self._set_status(f"Weather bulletin playback error: {e}", _STATUS_HIGH)
            self._handle_bulletin_completion(bulletin, reason=None)
            return

        audible_monotonic = time.monotonic()
        self._record_bulletin_latency(bulletin, audible_monotonic)
        self._bulletin_interruptions_handled += 1

        self._current_entry = bulletin
        self._playing = True
        self._paused = False
        self._generation_paused = True
        self._bulletin_playing = True

        self._current_segments = ()
        self._paragraphs = []
        self._paragraph_idx = 0

        duration_s = bulletin.duration_ms / 1000 if bulletin.duration_ms else 0.0
        self._estimated_remaining_secs = duration_s
        self._bar_progress = 0.0

        self._update_now_playing(
            title="⚠ Weather Alert", progress=0.0, text_snippet="", status="Weather bulletin playing"
        )
        if self.is_running:
            self.query_one("#current-text", Static).update("")
            self.query_one("#now-playing-kind", Label).update(self._display_kind(bulletin))
        # _bulletin_playing is now True: the interrupt banner must show
        # immediately, not wait for the next 1s timer tick.
        self._refresh_status_indicators()

    def _handle_bulletin_completion(self, bulletin: StationEntry, reason: CompletionReason | None) -> None:
        """A weather bulletin finished (cleanly, truncated, or via an
        adapter.play failure -- ``reason=None``) -- ALWAYS resume the
        interrupted entry, never auto-advance/mark-complete like the normal
        completion path does (a bulletin is never a durable Item and is
        never part of the station backlog).

        ``bulletin`` is passed explicitly (rather than read from
        ``self._current_entry``) so the log message below is accurate even
        when called from :meth:`_play_bulletin`'s ``adapter.play`` failure
        path, where ``self._current_entry`` is still the INTERRUPTED entry
        (the bulletin never got far enough to become current).

        This deliberately does NOT gate on ``reason.is_clean_completion``
        the way :meth:`_handle_station_completion` gates auto-advance
        (PM-10): the bulletin itself has nothing further to
        "not auto-advance into" -- it is session-scoped and one-shot, never
        itself resumed -- so a TRUNCATED/UNKNOWN bulletin completion still
        resumes the interrupted entry rather than stranding playback
        indefinitely. This is the "completion race" hazard from the task
        briefing: a bulletin completion must route HERE, never through the
        normal auto-advance path.
        """
        logger.debug(
            "Weather bulletin %s completed (reason=%r) -- resuming interrupted entry", bulletin.entry_id, reason
        )
        self._bulletin_playing = False
        self._playing = False
        self._paused = False
        self._generation_paused = False
        self._clear_transcript_state()
        # _bulletin_playing just flipped False -- hide the interrupt banner
        # immediately, whether or not there's anything to resume below.
        self._refresh_status_indicators()

        resumed_entry = self._resume_from_interruption()
        if resumed_entry is None:
            logger.error(
                "Weather bulletin %s completed but ResumeFromInterruption found nothing to resume -- "
                "station left stopped rather than silently replaying/skipping",
                bulletin.entry_id,
            )
            self._current_entry = None
            self._current_index = None
            if self._controller.is_running:
                self._controller.submit(Stop())
            self._poller.stop()
            self._poller_started = False
            self._set_status("Weather bulletin finished — nothing to resume", _STATUS_HIGH)
            self._trigger_generation()
            return

        # _start_playback reads the accept-time checkpoint (entry_id matches
        # the resumed entry; untouched by ResumeFromInterruption) for the
        # exact resume offset, and restarts the poller/route-monitor it was
        # only ever paused across the bulletin.
        #
        # nesting: single-bulletin MVP -- reducer.StartPlayback unconditionally
        # clears interruption_stack (see _play_bulletin's docstring), so this
        # would silently drop any DEEPER queued interruption. Safe today only
        # because _maybe_submit_pending_bulletin's `not self._bulletin_playing`
        # guard means a second bulletin can never be accepted while one is
        # already playing, so the stack never exceeds depth 1 in practice.
        # Revisit this call if nested bulletin-of-bulletin interruptions are
        # ever enabled.
        self._start_playback(resumed_entry)

    def _resume_from_interruption(self) -> StationEntry | None:
        """Submit ``ResumeFromInterruption``; return the resumed entry (the
        reducer's freshly-popped ``active_entry``) on acceptance, or
        ``None`` on rejection/failure (e.g. an empty interruption stack)."""
        action = ResumeFromInterruption(now=now_utc_z())
        try:
            result = self._controller.submit_and_wait(action, timeout=5.0)
        except Exception:
            logger.exception("ResumeFromInterruption submission failed")
            return None
        if not result.accepted:
            return None
        return result.state.active_entry

    def _record_bulletin_latency(self, bulletin: StationEntry, audible_monotonic: float) -> None:
        """Append one JSON-Lines record of this interruption's latency to
        :attr:`_latency_log_path`. Boundary-wait (how long playback had to
        keep going before a genuinely safe boundary showed up) is reported
        SEPARATELY from accept-to-audible (submit + adapter.play latency,
        the "hot path" once a boundary was found) -- these are independent
        quantities that happen to sum to the total. Bulletin GENERATION time
        (the monitor's TTS synth, entirely before hand-off) is not
        observable from here and is out of scope for this artifact -- see
        the task report.

        Best-effort: a write failure is logged, never raised (a metrics
        artifact must not be able to break playback).
        """
        pending_since = self._bulletin_pending_since_monotonic
        boundary_detected = self._bulletin_boundary_detected_monotonic
        self._bulletin_pending_since_monotonic = None
        self._bulletin_boundary_detected_monotonic = None
        if pending_since is None or boundary_detected is None:
            return

        record = {
            "timestamp": now_utc_z(),
            "bulletin_entry_id": bulletin.entry_id,
            "boundary_wait_ms": round((boundary_detected - pending_since) * 1000),
            "accept_to_audible_ms": round((audible_monotonic - boundary_detected) * 1000),
            "total_latency_ms": round((audible_monotonic - pending_since) * 1000),
            "cold_or_warm": "cold" if self._bulletin_interruptions_handled == 0 else "warm",
        }
        try:
            self._latency_log_path.parent.mkdir(parents=True, exist_ok=True)
            with self._latency_log_path.open("a", encoding="utf-8") as f:
                f.write(json.dumps(record) + "\n")
        except Exception:
            logger.exception("Weather bulletin %s: failed to write latency artifact", bulletin.entry_id)

    def _on_adapter_completion(self, reason: CompletionReason) -> None:
        """Thin marshaller installed on the adapter — runs on the audio background thread.

        Uses ``post_message`` (thread-safe, non-blocking), NOT
        ``call_from_thread`` — see :class:`PlaybackCompleted`'s docstring for
        the deadlock this avoids.
        """
        self.post_message(PlaybackCompleted(reason))

    def on_playback_completed(self, message: PlaybackCompleted) -> None:
        """UI-thread entry point for :class:`PlaybackCompleted`, dispatched by Textual's message pump."""
        self._handle_station_completion(message.reason)

    def _handle_station_completion(self, reason: CompletionReason) -> None:
        """UI-thread completion handling (PM-10): auto-advance ONLY on a verified clean end.

        ``reason.is_clean_completion`` is True only for ``ENDED`` — a
        verified play-to-the-end. ``TRUNCATED``/``UNKNOWN`` must never
        auto-advance or mark-complete (the PM-10 guard): the entry may not
        have actually finished playing, so treating it as done would silently
        skip content.

        A weather bulletin's completion (A.4.3) is intercepted FIRST, before
        any of this method's normal side effects (in particular, before the
        unconditional ``Stop()`` submit just below): a bulletin completion
        must route to :meth:`_handle_bulletin_completion` (resume the
        interrupted entry), never fall through to this method's
        auto-advance/"not advancing" logic. This ordering matters for a
        TRUNCATED bulletin completion specifically -- the normal body below
        returns early on ``not reason.is_clean_completion`` without ever
        reaching the auto-advance code, so resume would silently never fire
        if this check were placed any later.
        """
        if self._bulletin_playing:
            self._handle_bulletin_completion(self._current_entry, reason)
            return

        finished_entry = self._current_entry
        if self._controller.is_running:
            self._controller.submit(Stop())
        self._playing = False
        self._paused = False
        # Auto-advance (clean completion with a next entry) immediately
        # repopulates this via _start_playback -- clearing first here is
        # harmless (synchronous, no visible flicker) and keeps every other
        # completion path (interrupted / queue-finished) from showing stale
        # transcript text for an entry that is no longer playing.
        self._clear_transcript_state()
        # A completion supersedes any PENDING route-interruption of this same
        # entry (same "supersede" reasoning as _clear_transcript_state above).
        # Without this reset, a RouteChanged that races in and is dispatched
        # just before a PlaybackCompleted for the same entry (both posted
        # from background threads, drained FIFO on the UI thread) would leave
        # `_route_interrupted` latched True after the entry has already been
        # marked complete / advanced past -- so the next "p"/space would hit
        # action_toggle_play's route-interrupted branch and incorrectly
        # replay the already-completed entry.
        self._route_interrupted = False
        self._route_device_name = ""
        self._route_resume_entry = None
        self._route_resume_offset_ms = 0

        if not reason.is_clean_completion:
            self._poller.stop()
            self._poller_started = False
            self._route_monitor.stop()
            self._route_monitor_started = False
            self._generation_paused = False
            self._set_status("Playback interrupted — not advancing", _STATUS_HIGH)
            self._refresh_status_indicators()
            return

        if finished_entry is not None and finished_entry.item_id is not None:
            item = self._item_lookup.get(finished_entry.item_id)
            if item is not None:
                mark_completed(item)

        # `_current_index is None` means we don't actually know where in the
        # backlog we are (e.g. a sequencer rebuild dropped the entry that was
        # playing) — that must fall through to "queue finished", NOT replay
        # station_entries[0]. Only a known index advances to the next slot.
        if self._current_index is not None and self._current_index + 1 < len(self._station_entries):
            self._start_playback(self._station_entries[self._current_index + 1])
        else:
            self._current_entry = None
            self._current_index = None
            self._generation_paused = False
            self._poller.stop()
            self._poller_started = False
            self._route_monitor.stop()
            self._route_monitor_started = False
            self._update_now_playing(
                title="Completed!", progress=100, time_remaining="", text_snippet="", status="Queue finished"
            )
            if self.is_running:
                self.query_one("#now-playing-kind", Label).update("")
            self._refresh_status_indicators()
            self._trigger_generation()

        # Keep the DB item cache fresh (title/word lookups, empty-state
        # message); the Larder tree itself is refreshed on the next natural
        # trigger (add/delete/mark/clear/manual-refresh/generation-complete)
        # rather than synchronously here, to keep completion handling cheap.
        self._refresh_playlists()

    # -- Route-change interruption (A.3.3, floor-first, spike-validated) ----

    def _on_route_change(self, event: RouteChangeEvent) -> None:
        """Thin marshaller installed on the route monitor — runs on its delivery thread.

        Uses ``post_message`` (thread-safe, non-blocking), NOT
        ``call_from_thread`` — see :class:`RouteChanged`'s docstring for the
        deadlock this avoids (same class of bug as :class:`PlaybackCompleted`).
        """
        self.post_message(RouteChanged(event))

    def on_route_changed(self, message: RouteChanged) -> None:
        """UI-thread entry point for :class:`RouteChanged`, dispatched by Textual's message pump.

        A device change is an INTERRUPTION, not a completion: no
        auto-advance, no mark-complete (same discipline
        :meth:`_handle_station_completion` applies to a non-clean
        completion). Ignored entirely when idle/stopped (``self._playing`` is
        False) — nothing is bound to a device to interrupt. Still handled
        while merely paused: ``self._playing`` stays True during a
        user-initiated pause (only ``self._paused`` toggles), and a paused
        stream still holds the audio device open.

        Deliberately does NOT submit ``Stop()`` to the controller (unlike
        :meth:`_handle_station_completion`'s non-clean path): the station's
        ``StationState`` stays ``PLAYING`` with ``active_entry`` unchanged,
        which is what lets :meth:`_resume_from_route_interruption` submit a
        boundary-accurate ``Checkpoint`` on resume (the reducer's
        ``_checkpoint`` transition requires a ``PLAYING`` station with an
        active entry — see ``wilted.station.reducer``). Only the adapter
        (releases the stale/misrouted device) and the poller (would
        otherwise checkpoint a dead stream) are stopped here.

        A.4.3: ignored entirely while a weather bulletin is playing
        (``self._bulletin_playing``) — ``self._playing`` is True for a
        bulletin too, so without this guard a device change mid-bulletin
        would run the route-interruption path against the BULLETIN instead
        of the interrupted entry: it would overwrite the accept-time resume
        checkpoint with the bulletin's own, and the eventual
        ``_resume_from_route_interruption`` -> ``_start_playback(bulletin)``
        would clear ``interruption_stack`` (reducer._start_playback has no
        "already interrupted" precondition — see :meth:`_play_bulletin`'s
        docstring), permanently discarding the interrupted entry. A bulletin
        is short-lived and self-recovers anyway: :meth:`_resume_from_interruption`
        -> :meth:`_start_playback` opens a fresh, unpinned stream that binds
        to whatever the CURRENT default device is at that point (the same
        "route-recovery via restart" mechanism :meth:`_resume_from_route_interruption`
        itself relies on), so the interrupted entry lands on the new device
        once it resumes. Accepted limitation: a device change DURING the
        bulletin isn't recovered until the bulletin finishes — it may keep
        playing to the stale/disconnected device for its remaining seconds.
        """
        if self._bulletin_playing:
            return
        if not self._playing:
            return

        event = message.event
        offset_ms = self._adapter.current_offset_ms()
        self._adapter.stop()
        self._poller.stop()
        self._poller_started = False

        self._route_interrupted = True
        self._route_device_name = event.device_name
        self._route_resume_entry = self._current_entry
        self._route_resume_offset_ms = offset_ms

        self._playing = False
        self._paused = False
        self._generation_paused = False

        self._set_status(
            f"Audio output changed to '{event.device_name}' — playback paused. Press [p] to resume on the new device.",
            _STATUS_HIGH,
        )
        if self.is_running:
            self._update_playback_bar()
        # _route_interrupted just flipped True -- the persistent banner
        # (unlike the status line above) must stay up until resumed, not
        # just for _STATUS_HOLD_SECS.
        self._refresh_status_indicators()

    def _resume_from_route_interruption(self) -> None:
        """Resume onto the new default device after a route interruption.

        A fresh :meth:`_start_playback` opens a fresh ``sd.OutputStream`` with
        no pinned ``device=`` (``engine.py``'s ``_stream_pcm``), which binds
        to whatever is the CURRENT default output device at open time — that
        IS the recovery onto the new device (see
        ``spikes/route-recovery-listener-2026-07-10/`` + the A.3.3 design
        note: "route-recovery via restart", no mid-stream engine surgery
        needed).
        """
        entry = self._route_resume_entry
        offset_ms = self._route_resume_offset_ms
        self._route_interrupted = False
        self._route_device_name = ""
        self._route_resume_entry = None
        self._route_resume_offset_ms = 0
        # Hide the banner immediately -- covers both the normal resume path
        # below (_start_playback also refreshes at its own end, harmlessly
        # redundant) and the "nothing to resume" edge case, which returns
        # before ever reaching _start_playback.
        self._refresh_status_indicators()

        if entry is None:
            self._set_status("Nothing to resume", _STATUS_MEDIUM)
            return

        self._submit_route_resume_checkpoint(entry, offset_ms)
        self._start_playback(entry)

    def _submit_route_resume_checkpoint(self, entry: StationEntry, offset_ms: int) -> None:
        """Best-effort: write a boundary-accurate ``Checkpoint`` for ``entry``
        at ``offset_ms`` immediately before :meth:`_start_playback` reads it.

        ``_start_playback`` derives its resume offset from
        ``self._controller.current_state().checkpoint`` (only honored when
        its ``entry_id`` matches). Without this call, that would fall back to
        whichever ``Checkpoint`` the ``CheckpointPoller`` last wrote — up to
        one poll interval (default 30s) stale. Submitting through the
        controller (INV-8: the sole write path) right before the matching
        read closes that gap to the exact captured offset.

        Submitted via ``submit_and_wait`` (not fire-and-forget) so this
        method returns only once the checkpoint the following
        ``_start_playback`` call will read is durably in place — reusing the
        ``CheckpointPoller``'s own field conventions (``expected_revision``
        = current revision, ``state_label="playing"``, ``writer_device="mac"``,
        a fresh ``mutation_id``).

        A rejection (e.g. ``expected_revision`` went stale between the
        interruption and this resume) is expected and benign, same as any
        other checkpoint write in this codebase: ``_start_playback`` simply
        falls back to reading whatever checkpoint IS current, at most one
        poll interval stale — never worse than before this call existed.
        """
        try:
            state = self._controller.current_state()
            action = Checkpoint(
                mutation_id=f"mac-route-resume-{uuid.uuid4().hex}",
                expected_revision=state.station_revision,
                media_offset_ms=offset_ms,
                state_label="playing",
                writer_device="mac",
            )
            self._controller.submit_and_wait(action, timeout=5.0)
        except Exception:
            logger.exception(
                "route-resume: exact checkpoint submission failed; falling back to the existing checkpoint"
            )

    # -- Actions (key bindings) ---------------------------------------------

    def action_toggle_play(self) -> None:
        """Play, pause, or resume playback.

        Pause/resume are adapter-only (NOT a reducer state change — the
        station stays in the PLAYING lifecycle while paused); only
        start/stop go through the controller.

        A route-interrupted state (see :meth:`on_route_changed`) takes
        priority over the ordinary play/pause/resume branches below: "p"/
        space is the resume affordance for that state too, reusing the
        existing pause/resume key rather than adding a new binding.
        """
        if self._route_interrupted:
            self._resume_from_route_interruption()
            return
        if self._playing and not self._paused:
            self._adapter.pause()
            self._paused = True
            self._set_status("Paused", _STATUS_MEDIUM)
        elif self._playing and self._paused:
            self._adapter.resume()
            self._paused = False
            self._set_status("Playing", _STATUS_MEDIUM)
        else:
            entry = self._get_selected_entry()
            if entry is None and self._station_entries:
                entry = self._station_entries[0]
            if entry is not None:
                self._start_playback(entry)
            else:
                self._set_status("Nothing to play", _STATUS_MEDIUM)

    def action_stop(self) -> None:
        """Stop playback completely (adapter stop + reducer Stop + poller stop)."""
        self._adapter.stop()
        if self._controller.is_running:
            self._controller.submit(Stop())
        self._poller.stop()
        self._poller_started = False
        self._route_monitor.stop()
        self._route_monitor_started = False
        self._playing = False
        self._paused = False
        self._generation_paused = False
        self._clear_transcript_state()
        self._route_interrupted = False
        self._route_device_name = ""
        self._route_resume_entry = None
        self._route_resume_offset_ms = 0
        # A manual stop mid-bulletin abandons the interruption cleanly rather
        # than leaving _bulletin_playing latched True (which would otherwise
        # misroute the NEXT entry's completion through the bulletin-resume
        # path instead of normal auto-advance). The pending bulletin (if any)
        # is deliberately left in place -- a weather alert doesn't stop
        # mattering just because playback was paused/stopped, so it's still
        # eligible to interrupt the next safe boundary once playback resumes.
        self._bulletin_playing = False
        self._set_status("Stopped", _STATUS_MEDIUM)
        self._refresh_status_indicators()
        self._trigger_generation()

    def action_play_selected(self) -> None:
        """Play the selected item from the playlist tree."""
        entry = self._get_selected_entry()
        if entry is not None:
            self._start_playback(entry)

    def action_skip_segment(self) -> None:
        """Advance to the next station entry.

        MVP change (A.3.5): per-paragraph skip is dropped — the
        ``MacPlaybackAdapter`` has no in-place seek (``adapter.seek`` raises
        ``NotImplementedError``; only ``play(media, offset_ms=...)`` at
        start). The ">>" binding now means "next entry", entry-level.
        """
        if not self._playing or self._current_index is None:
            return
        next_index = self._current_index + 1
        if next_index < len(self._station_entries):
            self._start_playback(self._station_entries[next_index])
        else:
            self._set_status("No next item", _STATUS_MEDIUM)

    def action_prev_paragraph(self) -> None:
        """Go back to the previous station entry.

        MVP change (A.3.5): per-paragraph rewind is dropped for the same
        reason as :meth:`action_skip_segment` — no in-place seek. The "<<"
        binding now means "previous entry", entry-level.
        """
        if not self._playing or self._current_index is None:
            return
        prev_index = self._current_index - 1
        if prev_index >= 0:
            self._start_playback(self._station_entries[prev_index])
        else:
            self._set_status("No previous item", _STATUS_MEDIUM)

    def _save_speed(self) -> None:
        """Persist current speed to the database for next session."""
        from wilted.db import set_setting

        set_setting("speed", str(self._speed))

    def action_speed_down(self) -> None:
        """Decrease playback speed by 0.1x."""
        self._speed = max(0.5, round(self._speed - 0.1, 1))
        self._update_speed_display()
        self._save_speed()

    def action_speed_up(self) -> None:
        """Increase playback speed by 0.1x."""
        self._speed = min(2.0, round(self._speed + 0.1, 1))
        self._update_speed_display()
        self._save_speed()

    def action_next_article(self) -> None:
        """Advance to the next entry in the station backlog (entry-level, wraps to 0)."""
        if not self._station_entries:
            self._set_status("Nothing to play", _STATUS_MEDIUM)
            return
        next_index = (self._current_index + 1) if self._current_index is not None else 0
        if next_index >= len(self._station_entries):
            next_index = 0
        self._start_playback(self._station_entries[next_index])

    def action_voice_settings(self) -> None:
        """Open voice/speed settings modal."""

        def on_dismiss(result: tuple[str, float, str] | None) -> None:
            if result is not None:
                old_voice, old_speed, old_lang = self._voice, self._speed, self._lang
                self._voice, self._speed, self._lang = result
                self._update_speed_display()
                changed = old_voice != self._voice or old_speed != self._speed or old_lang != self._lang
                if changed:
                    self._save_speed()
                    if self._playing:
                        self._set_status(f"Speed: {self._speed:.1f}x — takes effect next paragraph", _STATUS_MEDIUM)
                    else:
                        self._trigger_generation()

        self.push_screen(VoiceSettingsScreen(self._voice, self._speed, self._lang), on_dismiss)

    def action_add_article(self) -> None:
        """Open the add article dialog.

        Item-DB CRUD — writes the item store directly (not station-state, no
        controller routing). After a successful add, the sequencer is
        rebuilt so the new item can appear once finalized; "add & play"
        defers the actual play until that rebuild resolves whether the item
        is already finalized (see :meth:`_apply_sequencer_result`).
        """

        def on_dismiss(result: tuple[str, dict] | None) -> None:
            if result is not None:
                action, entry_dict = result
                self._set_status(f"Added: {entry_dict.get('title', 'Untitled')}", _STATUS_MEDIUM)
                self._pending_play_item_id = str(entry_dict["id"]) if action == "play" else None
                self._rebuild_sequencer()
                self._trigger_generation()

        self.push_screen(AddArticleScreen(), on_dismiss)

    def _stop_and_clear_plate(self) -> None:
        """Stop playback and reset the Plate pane to its empty state."""
        self.action_stop()
        self._current_entry = None
        self._current_index = None
        self.query_one("#now-playing-title", Label).update("No article selected")
        self.query_one("#now-playing-kind", Label).update("")
        self.query_one("#current-text", Static).update("")
        self._bar_progress = 0.0
        self._bar_time_override = ""
        self._update_playback_bar()

    def action_mark_read(self) -> None:
        """Mark the selected item as read (completed). Keeps it in the DB for metrics.

        Item-DB CRUD (mark_completed writes a different store than station
        state). If the currently-playing entry is the target, stop playback
        via the station path FIRST (:meth:`_stop_and_clear_plate`) rather
        than poking the DB out from under an active playback session.

        Data-safety guard: refused entirely in read-only mode (another live
        session owns the station lease) — that session may be reading/
        writing this same DB item right now.
        """
        if self._station_read_only:
            self._set_status(_STATION_READ_ONLY_MSG, _STATUS_HIGH)
            return
        entry = self._get_selected_entry()
        if entry is None:
            self._set_status("Nothing to mark", _STATUS_MEDIUM)
            return
        item = self._item_lookup.get(entry.item_id or "")
        if item is None:
            self._set_status("Nothing to mark", _STATUS_MEDIUM)
            return
        if self._current_entry is not None and entry.entry_id == self._current_entry.entry_id:
            self._stop_and_clear_plate()
        mark_completed(item)
        title = item.get("title", "Untitled")
        if len(title) > 40:
            title = title[:37] + "..."
        self._set_status(f"Marked as read: {title}", _STATUS_MEDIUM)
        self._rebuild_sequencer()

    def action_delete_selected(self) -> None:
        """Delete the selected article with confirmation.

        Item-DB CRUD. Stops playback via the station path first if the
        target is currently playing (same rule as :meth:`action_mark_read`).

        Data-safety guard: refused entirely in read-only mode — see
        :meth:`action_mark_read`.
        """
        if self._station_read_only:
            self._set_status(_STATION_READ_ONLY_MSG, _STATUS_HIGH)
            return
        entry = self._get_selected_entry()
        if entry is None:
            self._set_status("Nothing to delete", _STATUS_MEDIUM)
            return
        item = self._item_lookup.get(entry.item_id or "")
        title = item.get("title", "Untitled") if item else entry.entry_id
        if len(title) > 40:
            title = title[:37] + "..."

        def on_dismiss(confirmed: bool) -> None:
            if confirmed:
                if self._current_entry is not None and entry.entry_id == self._current_entry.entry_id:
                    self._stop_and_clear_plate()
                if item is not None:
                    try:
                        remove_article_by_id(item["id"])
                        self._set_status(f"Deleted: {item.get('title', 'Untitled')}", _STATUS_MEDIUM)
                    except Exception as e:
                        self._set_status(f"Delete failed: {e}", _STATUS_HIGH)
                self._rebuild_sequencer()

        self.push_screen(
            ConfirmScreen("Permanently Delete?", f'Permanently delete "{title}"? Use [m] to mark as read instead.'),
            on_dismiss,
        )

    def action_text_preview(self) -> None:
        """Preview the text of the selected article."""
        entry = self._get_selected_entry()
        if entry is None:
            self._set_status("No article selected", _STATUS_MEDIUM)
            return
        item = self._item_lookup.get(entry.item_id or "")
        if item is None:
            self._set_status("No article selected", _STATUS_MEDIUM)
            return

        text = get_article_text(item)
        if text is None:
            self._set_status("Error: article text not found", _STATUS_HIGH)
            return

        title = item.get("title", "Untitled")
        word_count = item.get("words", len(text.split()))
        self.push_screen(TextPreviewScreen(title, text, word_count))

    def action_clear_all(self) -> None:
        """Clear all articles with confirmation. Item-DB CRUD.

        Data-safety guard: refused entirely in read-only mode — see
        :meth:`action_mark_read`.
        """
        if self._station_read_only:
            self._set_status(_STATION_READ_ONLY_MSG, _STATUS_HIGH)
            return
        if not self._all_items:
            self._set_status("Queue is already empty", _STATUS_MEDIUM)
            return

        count = len(self._all_items)

        def on_dismiss(confirmed: bool) -> None:
            if confirmed:
                if self._playing:
                    self.action_stop()
                self._current_entry = None
                self._current_index = None
                cleared = clear_queue()
                self._set_status(f"Cleared {cleared} article(s)", _STATUS_MEDIUM)
                self._rebuild_sequencer()

        self.push_screen(
            ConfirmScreen("Clear All Articles?", f"This will remove {count} article(s) and delete all cached text."),
            on_dismiss,
        )

    def action_refresh_queue(self) -> None:
        """Refresh queue from disk and rebuild the station backlog."""
        self._rebuild_sequencer()
        self._set_status("Queue refreshed")

    def action_quit_app(self) -> None:
        """Stop playback/polling and release the station lease, then exit."""
        self._adapter.stop()
        self._poller.stop()
        self._poller_started = False
        self._route_monitor.stop()
        self._route_monitor_started = False
        if self._weather_monitor is not None:
            self._weather_monitor.stop()
            self._weather_monitor_started = False
        self._controller.stop()
        self.exit()

    # -- WAV export ---------------------------------------------------------

    def action_export_wav(self) -> None:
        """Export selected article to WAV file."""
        entry = self._get_selected_entry()
        if entry is None:
            self._set_status("No article selected", _STATUS_MEDIUM)
            return
        item = self._item_lookup.get(entry.item_id or "")
        if item is None:
            self._set_status("No article selected", _STATUS_MEDIUM)
            return

        text = get_article_text(item)
        if text is None:
            self._set_status("Error: article text not found", _STATUS_HIGH)
            return

        self._export_wav(item, text)

    @work(thread=True, exclusive=True, group="export")
    def _export_wav(self, entry: dict, text: str) -> None:
        """Export article to WAV file with progress."""
        from wilted.engine import export_to_wav

        worker = get_current_worker()

        self.call_from_thread(self._set_status, "Loading model...")
        self._ensure_engine()
        engine = self._engine
        engine.voice = self._voice
        engine.speed = self._speed
        engine.lang = self._lang

        paragraphs = split_paragraphs(text)
        if not paragraphs:
            self.call_from_thread(self._set_status, "Error: no text to export", _STATUS_HIGH)
            return

        # Generate filename from title
        title = entry.get("title", "untitled")
        slug = re.sub(r"[^\w\s-]", "", title.lower())
        slug = re.sub(r"[\s_]+", "-", slug).strip("-")[:50]
        filename = f"{slug}.wav"

        def on_progress(current, total_chunks):
            progress = (current / total_chunks) * 100
            self.call_from_thread(
                self._update_now_playing,
                title=f"Exporting: {entry.get('title', 'Untitled')}",
                progress=progress,
                time_remaining=f"Generating paragraph {current}/{total_chunks}",
                status="Exporting...",
            )

        try:
            export_to_wav(
                engine,
                paragraphs,
                filename,
                on_progress=on_progress,
                should_cancel=lambda: worker.is_cancelled,
            )
        except InterruptedError:
            self.call_from_thread(self._set_status, "Export cancelled", _STATUS_HIGH)
            return
        except (ValueError, RuntimeError) as e:
            self.call_from_thread(self._set_status, f"Export error: {e}", _STATUS_HIGH)
            return

        self.call_from_thread(
            self._update_now_playing,
            title="Export Complete",
            progress=100,
            time_remaining="",
            text_snippet="",
            status=f"Saved to {filename}",
        )

    # -- Helpers ------------------------------------------------------------

    def _get_selected_entry(self) -> StationEntry | None:
        """Get the StationEntry for the currently highlighted Tree leaf node."""
        tree = self.query_one("#playlist-tree", Tree)
        node = tree.cursor_node
        if node is None:
            return None
        data = node.data
        if isinstance(data, StationEntry):
            return data
        return None
