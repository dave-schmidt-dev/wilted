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

import logging
import os
import re
import time
from typing import TYPE_CHECKING, ClassVar

from textual import work
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical, VerticalScroll
from textual.message import Message
from textual.theme import Theme
from textual.widgets import Footer, Header, Label, Static, Tree
from textual.worker import get_current_worker

from wilted import ICONS
from wilted.playlists import ensure_default_playlists, get_playlist_items
from wilted.queue import (
    clear_queue,
    get_article_text,
    mark_completed,
    remove_article_by_id,
)
from wilted.station.models import StationEntry
from wilted.station.reducer import StartPlayback, Stop
from wilted.station_runtime import (
    CheckpointPoller,
    LeaseHeldError,
    MacPlaybackAdapter,
    StationController,
)
from wilted.station_runtime.sequencer import EntrySequencer
from wilted.text import split_paragraphs
from wilted.tui.screens.add_article import AddArticleScreen
from wilted.tui.screens.confirm import ConfirmScreen
from wilted.tui.screens.report import ReportScreen
from wilted.tui.screens.text_preview import TextPreviewScreen
from wilted.tui.screens.voice_settings import VoiceSettingsScreen

if TYPE_CHECKING:
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
        margin-bottom: 1;
    }
    #playback-bar {
        height: 1;
        margin: 1 0;
        color: $primary;
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
        self._station_read_only: bool = False

        # -- Station backlog / now-playing state -----------------------------
        self._station_entries: list[StationEntry] = []
        self._current_entry: StationEntry | None = None
        self._current_index: int | None = None
        self._pending_play_item_id: str | None = None

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
                yield Static("", id="playback-bar")
                with VerticalScroll(id="text-scroll"):
                    yield Static("", id="current-text", markup=True)
                yield Static("", id="speed-display")
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
        poller/heartbeat threads would leak past this app instance. All three
        calls are documented no-ops if never started, and idempotent with
        :meth:`action_quit_app` calling them again.
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
            self._controller.stop()
        except Exception:
            logger.exception("on_unmount: controller.stop() failed")

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
        if not self._playing or self._paused:
            return

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
        """
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

        if not reason.is_clean_completion:
            self._poller.stop()
            self._poller_started = False
            self._generation_paused = False
            self._set_status("Playback interrupted — not advancing", _STATUS_HIGH)
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
            self._update_now_playing(
                title="Completed!", progress=100, time_remaining="", text_snippet="", status="Queue finished"
            )
            self._trigger_generation()

        # Keep the DB item cache fresh (title/word lookups, empty-state
        # message); the Larder tree itself is refreshed on the next natural
        # trigger (add/delete/mark/clear/manual-refresh/generation-complete)
        # rather than synchronously here, to keep completion handling cheap.
        self._refresh_playlists()

    # -- Actions (key bindings) ---------------------------------------------

    def action_toggle_play(self) -> None:
        """Play, pause, or resume playback.

        Pause/resume are adapter-only (NOT a reducer state change — the
        station stays in the PLAYING lifecycle while paused); only
        start/stop go through the controller.
        """
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
        self._playing = False
        self._paused = False
        self._generation_paused = False
        self._clear_transcript_state()
        self._set_status("Stopped", _STATUS_MEDIUM)
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
