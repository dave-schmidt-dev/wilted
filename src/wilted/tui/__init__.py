"""Textual TUI package for wilted.

WiltedApp is defined here (in __init__.py, not app.py) so that
``@patch("wilted.tui.get_playlist_items")`` and similar test patches intercept
calls made from WiltedApp methods — Python looks up free variables in the
containing module's __dict__ at call time, not at definition time.

Screens (AddArticleScreen, ConfirmScreen, etc.) are in tui/screens/.
"""

from __future__ import annotations

import logging
import re
import time
from typing import ClassVar

from textual import work
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical, VerticalScroll
from textual.theme import Theme
from textual.widgets import Footer, Header, Label, Static, Tree
from textual.worker import get_current_worker

from wilted import ICONS, WPM_ESTIMATE
from wilted.playlists import (
    clear_resume_position,
    ensure_default_playlists,
    get_playlist_items,
    get_resume_position,
    list_playlists,
    set_resume_position,
)
from wilted.queue import (
    clear_queue,
    get_article_text,
    mark_completed,
    remove_article_by_id,
)
from wilted.text import split_paragraphs
from wilted.tui.screens.add_article import AddArticleScreen
from wilted.tui.screens.confirm import ConfirmScreen
from wilted.tui.screens.report import ReportScreen
from wilted.tui.screens.text_preview import TextPreviewScreen
from wilted.tui.screens.voice_settings import VoiceSettingsScreen

logger = logging.getLogger(__name__)

# Status message priorities — higher priority messages hold for a minimum
# duration and won't be overwritten by lower-priority routine updates.
_STATUS_LOW = 0  # Routine: "Playing (cached)", "Generating audio..."
_STATUS_MEDIUM = 1  # Info: "Speed: 1.5x", "Ready", "Paused"
_STATUS_HIGH = 2  # Errors, important user actions

# Minimum seconds a high/medium-priority message stays visible
_STATUS_HOLD_SECS = 2.0

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
        Binding("space", "toggle_play", "Play/Pause"),
        Binding("p", "play_selected", "Play"),
        Binding("s", "stop", "Stop"),
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

    def __init__(self, **kwargs) -> None:
        super().__init__(**kwargs)
        self.register_theme(SALAD_THEME)
        self.theme = "salad"
        self._playlist_items: dict[str, list[dict]] = {}
        self._all_items: list[dict] = []
        self._engine = None
        self._current_entry: dict | None = None
        self._paragraphs: list[str] = []
        self._paragraph_idx: int = 0
        self._total_segments: int = 0
        self._segments_played: int = 0
        self._playing: bool = False
        self._paused: bool = False
        self._voice: str = "af_heart"
        self._speed: float = 1.0
        self._lang: str = "a"
        self._last_state_save: float = 0.0
        self._playback_worker = None
        self._generation_paused: bool = False
        self._generation_worker = None
        self._rewind_to: int | None = None
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
        self._refresh_playlists()
        self._update_speed_display()
        self.query_one("#playlist-tree", Tree).focus()
        # 1-second timer for live playback countdown
        self.set_interval(1.0, self._update_timer)
        # Preload TTS model only if there are items that need TTS synthesis.
        # Pipeline items with audio_file set already have generated audio; skip.
        if any(not e.get("audio_file") for e in self._all_items):
            self._preload_model()
        # Check for unread report on launch
        self._check_unread_report()

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

    # -- Playlist display -----------------------------------------------------

    def _refresh_playlists(self) -> None:
        """Reload playlists and items, rebuild the Tree widget."""
        ensure_default_playlists()
        tree = self.query_one("#playlist-tree", Tree)
        tree.show_root = False

        # Save which playlists are expanded
        expanded = set()
        for node in tree.root.children:
            if node.is_expanded:
                expanded.add(node.data)

        tree.root.remove_children()

        self._playlist_items = {}

        playlists = list_playlists()
        for pl in playlists:
            items = get_playlist_items(pl.name)
            self._playlist_items[pl.name] = items
            count = len(items)
            label = f"{pl.name} ({count} items)"
            node = tree.root.add(label, data=pl.name)

            for item in items:
                title = item.get("title", "Untitled")
                if len(title) > 50:
                    title = title[:47] + "..."
                words = item.get("words", 0)
                node.add_leaf(f"{title}  ({words}w)", data=item)

            # Expand "All" by default on first load, preserve state after
            if pl.name in expanded or (pl.name == "All" and not expanded):
                node.expand()

        self._all_items = get_playlist_items("All")

        empty_msg = self.query_one("#empty-message", Label)
        if not self._all_items:
            empty_msg.update("The larder is empty. Press [a] to add an article.")
            empty_msg.display = True
        else:
            empty_msg.display = False

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
        if title:
            self.query_one("#now-playing-title", Label).update(title)
        self._bar_progress = progress
        self._bar_time_override = time_remaining
        self._update_playback_bar()
        if text_snippet:
            self.query_one("#current-text", Static).update(text_snippet)
            self.query_one("#text-scroll", VerticalScroll).scroll_home(animate=False)
        if status:
            self._set_status(status)

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
        """1-second interval: tick down the remaining estimate and refresh the bar."""
        if not self._playing or self._paused or not self._paragraphs:
            return
        self._estimated_remaining_secs = max(0, self._estimated_remaining_secs - 1)
        self._update_playback_bar()

    def _build_transcript(self, para_idx: int) -> str:
        """Build Rich markup showing paragraphs around the current one."""
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
        """
        now = time.time()
        if priority < self._status_priority and now - self._status_time < _STATUS_HOLD_SECS:
            return
        self._status_priority = priority
        self._status_time = now
        self.query_one("#status-line", Label).update(msg)

    # -- Engine lazy load ---------------------------------------------------

    def _ensure_engine(self) -> None:
        """Lazy-load the AudioEngine on first use."""
        if self._engine is None:
            from wilted.engine import AudioEngine

            self._engine = AudioEngine(lang=self._lang)

    @work(thread=True, exclusive=True, group="preload")
    def _preload_model(self) -> None:
        """Eagerly load the TTS model in the background at startup."""
        from wilted.fetch import suppress_subprocess_output

        try:
            self._ensure_engine()
            self.call_from_thread(self._set_status, "Loading TTS model...")
            with suppress_subprocess_output():
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

    # -- Background generation worker ----------------------------------------

    @work(thread=True, exclusive=True, group="generate")
    def _generate_cache(self) -> None:
        """Background worker: generate audio cache for queued articles."""
        from wilted.cache import generate_article_cache, is_cache_valid
        from wilted.fetch import suppress_subprocess_output
        from wilted.playlists import get_playlist_items as _get_playlist_items
        from wilted.queue import get_article_text

        worker = get_current_worker()

        self._ensure_engine()
        engine = self._engine
        with suppress_subprocess_output():
            engine.load_model()

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

        if not worker.is_cancelled and not self._playing:
            self.call_from_thread(self._set_status, "Ready")

    def _trigger_generation(self) -> None:
        """Start or restart the background generation worker."""
        if self._generation_worker and self._generation_worker.is_running:
            self._generation_worker.cancel()
        self._generation_worker = self._generate_cache()

    # -- Playback worker ----------------------------------------------------

    @work(thread=True, exclusive=True, group="playback")
    def _play_article(self, entry: dict, resume_para: int = 0) -> None:
        """Play an article from the given paragraph/segment position."""
        worker = get_current_worker()

        from wilted.fetch import suppress_subprocess_output

        self.call_from_thread(self._update_now_playing, status="Loading model...")
        self._ensure_engine()
        engine = self._engine
        # Ensure model is loaded (no-op if preload already finished)
        with suppress_subprocess_output():
            engine.load_model()

        engine.voice = self._voice
        engine.speed = self._speed
        engine.lang = self._lang

        text = get_article_text(entry)
        if not text:
            self.call_from_thread(self._set_status, "Error: article text not found", _STATUS_HIGH)
            return

        paragraphs = split_paragraphs(text)
        if not paragraphs:
            self.call_from_thread(self._set_status, "Error: no text to play", _STATUS_HIGH)
            return

        self._paragraphs = paragraphs
        self._total_segments = len(paragraphs)  # approximate: 1 segment per paragraph
        self._paragraph_idx = resume_para
        self._segments_played = resume_para

        title = entry.get("title", "Untitled")

        self.call_from_thread(
            self._update_now_playing,
            title=title,
            status="Playing",
        )

        from wilted.cache import is_paragraph_cached, load_audio

        article_id = entry["id"]
        added = entry.get("added", "")

        para_idx = resume_para
        while para_idx < len(paragraphs):
            if worker.is_cancelled:
                break

            # Check for rewind request
            if self._rewind_to is not None:
                para_idx = self._rewind_to
                self._rewind_to = None

            self._paragraph_idx = para_idx
            paragraph = paragraphs[para_idx]

            # Calculate progress and resync the countdown timer
            progress = (para_idx / len(paragraphs)) * 100
            words_remaining = sum(len(p.split()) for p in paragraphs[para_idx:])
            self._estimated_remaining_secs = words_remaining / (WPM_ESTIMATE * self._speed) * 60

            transcript = self._build_transcript(para_idx)

            self.call_from_thread(
                self._update_now_playing,
                progress=progress,
                text_snippet=transcript,
                status="Playing",
            )

            # Periodically save state
            now = time.time()
            if now - self._last_state_save >= 30:
                set_resume_position(entry["id"], para_idx, 0)
                self._last_state_save = now

            # Read voice/speed/lang at segment boundary (allows mid-playback changes)
            engine.voice = self._voice
            engine.speed = self._speed
            engine.lang = self._lang

            try:
                # Hybrid playback: cache hit → play_audio, miss → generate_and_play
                if is_paragraph_cached(article_id, para_idx, self._voice, self._lang, self._speed, added):
                    cached = load_audio(article_id, para_idx)
                    if cached is not None:
                        audio_np, _sr = cached
                        self.call_from_thread(self._set_status, "Playing (cached)")
                        engine.play_audio(audio_np)
                    else:
                        # File disappeared between check and load — fall through
                        self.call_from_thread(self._set_status, "Generating audio...")
                        engine.generate_and_play(paragraph)
                else:
                    self.call_from_thread(self._set_status, "Generating audio...")
                    engine.generate_and_play(paragraph)
            except Exception as e:
                self.call_from_thread(self._set_status, f"Playback error: {e}", _STATUS_HIGH)
                break

            if worker.is_cancelled:
                break

            # Check for rewind before advancing
            if self._rewind_to is not None:
                continue

            self._segments_played = para_idx + 1
            para_idx += 1

        # Finished or cancelled
        if not worker.is_cancelled and self._segments_played >= len(paragraphs):
            # Article completed
            self.call_from_thread(self._on_article_completed, entry)
        else:
            # Stopped or cancelled — save state
            set_resume_position(entry["id"], self._paragraph_idx, 0)

    def _on_article_completed(self, entry: dict) -> None:
        """Handle article completion on the main thread."""
        clear_resume_position(entry["id"])
        mark_completed(entry)
        self._playing = False
        self._paused = False
        self._generation_paused = False
        self._current_entry = None
        self._update_now_playing(
            title="Completed!",
            progress=100,
            time_remaining="",
            text_snippet="",
            status="Article finished",
        )
        self._refresh_playlists()
        # Auto-advance to next article
        if self._all_items:
            self._start_playback(self._all_items[0])
        else:
            self._trigger_generation()

    def _start_playback(self, entry: dict, resume_para: int = 0) -> None:
        """Start playing an article, stopping any current playback."""
        if self._playing and self._engine:
            self._engine.stop()
        if self._playback_worker and self._playback_worker.is_running:
            self._playback_worker.cancel()

        self._generation_paused = True  # Pause background generation during playback
        self._current_entry = entry
        self._playing = True
        self._paused = False
        self._rewind_to = None
        self._last_state_save = time.time()
        self._playback_worker = self._play_article(entry, resume_para)

    # -- Actions (key bindings) ---------------------------------------------

    def action_toggle_play(self) -> None:
        """Play, pause, or resume playback."""
        if self._playing and not self._paused:
            # Pause
            if self._engine:
                self._engine.pause()
            self._paused = True
            self._set_status("Paused", _STATUS_MEDIUM)
            if self._current_entry:
                set_resume_position(self._current_entry["id"], self._paragraph_idx, 0)
        elif self._playing and self._paused:
            # Resume
            if self._engine:
                self._engine.resume()
            self._paused = False
            self._set_status("Playing", _STATUS_MEDIUM)
        else:
            # Start playing selected or first article
            entry = self._get_selected_entry()
            if not entry and self._all_items:
                entry = self._all_items[0]
            if entry:
                # Check for resume state
                saved = get_resume_position(entry["id"])
                resume_para = saved["paragraph_idx"] if saved else 0
                self._start_playback(entry, resume_para)

    def action_stop(self) -> None:
        """Stop playback completely."""
        if self._playing and self._engine:
            self._engine.stop()
        if self._playback_worker and self._playback_worker.is_running:
            self._playback_worker.cancel()
        if self._current_entry:
            set_resume_position(self._current_entry["id"], self._paragraph_idx, 0)
        self._playing = False
        self._paused = False
        self._generation_paused = False
        self._set_status("Stopped", _STATUS_MEDIUM)
        self._trigger_generation()

    def action_play_selected(self) -> None:
        """Play the selected item from the playlist tree."""
        tree = self.query_one("#playlist-tree", Tree)
        node = tree.cursor_node
        if node is None:
            return
        data = node.data
        if isinstance(data, dict) and "id" in data:
            saved = get_resume_position(data["id"])
            resume_para = saved["paragraph_idx"] if saved else 0
            self._start_playback(data, resume_para)

    def action_skip_segment(self) -> None:
        """Skip to the next paragraph."""
        if self._playing and self._engine:
            self._engine.stop()
            # The while loop will naturally advance para_idx

    def action_prev_paragraph(self) -> None:
        """Rewind to the previous paragraph."""
        if self._playing and self._engine:
            self._rewind_to = max(0, self._paragraph_idx - 1)
            self._engine.stop()  # Stop current audio; while loop picks up _rewind_to

    def action_speed_down(self) -> None:
        """Decrease playback speed by 0.1x."""
        self._speed = max(0.5, round(self._speed - 0.1, 1))
        self._update_speed_display()

    def action_speed_up(self) -> None:
        """Increase playback speed by 0.1x."""
        self._speed = min(2.0, round(self._speed + 0.1, 1))
        self._update_speed_display()

    def action_next_article(self) -> None:
        """Stop current and play next article in queue."""
        self.action_stop()
        if len(self._all_items) > 1:
            # Find current article index and advance
            if self._current_entry:
                current_id = self._current_entry["id"]
                idx = next(
                    (i for i, e in enumerate(self._all_items) if e["id"] == current_id),
                    -1,
                )
                next_idx = idx + 1 if idx >= 0 else 0
            else:
                next_idx = 0
            if next_idx < len(self._all_items):
                entry = self._all_items[next_idx]
                saved = get_resume_position(entry["id"])
                resume_para = saved["paragraph_idx"] if saved else 0
                self._start_playback(entry, resume_para)
        elif self._all_items:
            self._start_playback(self._all_items[0])

    def action_voice_settings(self) -> None:
        """Open voice/speed settings modal."""

        def on_dismiss(result: tuple[str, float, str] | None) -> None:
            if result is not None:
                old_voice, old_speed, old_lang = self._voice, self._speed, self._lang
                self._voice, self._speed, self._lang = result
                self._update_speed_display()
                self._refresh_playlists()  # Update est. time column
                changed = old_voice != self._voice or old_speed != self._speed or old_lang != self._lang
                if changed and self._playing:
                    self._set_status(f"Speed: {self._speed:.1f}x — takes effect next paragraph", _STATUS_MEDIUM)
                elif changed and not self._playing:
                    self._trigger_generation()

        self.push_screen(VoiceSettingsScreen(self._voice, self._speed, self._lang), on_dismiss)

    def action_add_article(self) -> None:
        """Open the add article dialog."""

        def on_dismiss(result: tuple[str, dict] | None) -> None:
            if result is not None:
                action, entry = result
                self._refresh_playlists()
                self._set_status(f"Added: {entry.get('title', 'Untitled')}", _STATUS_MEDIUM)
                if action == "play":
                    self._start_playback(entry)
                self._trigger_generation()

        self.push_screen(AddArticleScreen(), on_dismiss)

    def action_mark_read(self) -> None:
        """Mark the selected item as read (completed). Keeps it in the DB for metrics."""
        entry = self._get_selected_entry()
        if not entry:
            self._set_status("Nothing to mark", _STATUS_MEDIUM)
            return
        if self._current_entry and entry["id"] == self._current_entry["id"]:
            self.action_stop()
            self._current_entry = None
        mark_completed(entry)
        clear_resume_position(entry["id"])
        title = entry.get("title", "Untitled")
        if len(title) > 40:
            title = title[:37] + "..."
        self._set_status(f"Marked as read: {title}", _STATUS_MEDIUM)
        self._refresh_playlists()

    def action_delete_selected(self) -> None:
        """Delete the selected article with confirmation."""
        entry = self._get_selected_entry()
        if not entry:
            self._set_status("Nothing to delete", _STATUS_MEDIUM)
            return

        title = entry.get("title", "Untitled")
        if len(title) > 40:
            title = title[:37] + "..."

        def on_dismiss(confirmed: bool) -> None:
            if confirmed:
                # Stop playback if deleting current article
                if self._current_entry and entry["id"] == self._current_entry["id"]:
                    self.action_stop()
                    self._current_entry = None
                try:
                    remove_article_by_id(entry["id"])
                    clear_resume_position(entry["id"])
                    self._set_status(f"Deleted: {entry.get('title', 'Untitled')}", _STATUS_MEDIUM)
                except Exception as e:
                    self._set_status(f"Delete failed: {e}", _STATUS_HIGH)
                self._refresh_playlists()

        self.push_screen(
            ConfirmScreen("Permanently Delete?", f'Permanently delete "{title}"? Use [m] to mark as read instead.'),
            on_dismiss,
        )

    def action_text_preview(self) -> None:
        """Preview the text of the selected article."""
        entry = self._get_selected_entry()
        if not entry:
            self._set_status("No article selected", _STATUS_MEDIUM)
            return

        text = get_article_text(entry)
        if text is None:
            self._set_status("Error: article text not found", _STATUS_HIGH)
            return

        title = entry.get("title", "Untitled")
        word_count = entry.get("words", len(text.split()))
        self.push_screen(TextPreviewScreen(title, text, word_count))

    def action_clear_all(self) -> None:
        """Clear all articles with confirmation."""
        if not self._all_items:
            self._set_status("Queue is already empty", _STATUS_MEDIUM)
            return

        count = len(self._all_items)

        def on_dismiss(confirmed: bool) -> None:
            if confirmed:
                if self._playing:
                    self.action_stop()
                    self._current_entry = None
                cleared = clear_queue()
                self._set_status(f"Cleared {cleared} article(s)", _STATUS_MEDIUM)
                self._refresh_playlists()

        self.push_screen(
            ConfirmScreen("Clear All Articles?", f"This will remove {count} article(s) and delete all cached text."),
            on_dismiss,
        )

    def action_refresh_queue(self) -> None:
        """Refresh queue from disk."""
        self._refresh_playlists()
        self._set_status("Queue refreshed")

    def action_quit_app(self) -> None:
        """Save state and quit."""
        if self._playing and self._engine:
            self._engine.stop()
        if self._playback_worker and self._playback_worker.is_running:
            self._playback_worker.cancel()
        if self._current_entry:
            set_resume_position(self._current_entry["id"], self._paragraph_idx, 0)
        self.exit()

    # -- WAV export ---------------------------------------------------------

    def action_export_wav(self) -> None:
        """Export selected article to WAV file."""
        entry = self._get_selected_entry()
        if not entry:
            self._set_status("No article selected", _STATUS_MEDIUM)
            return

        text = get_article_text(entry)
        if text is None:
            self._set_status("Error: article text not found", _STATUS_HIGH)
            return

        self._export_wav(entry, text)

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

    def _get_selected_entry(self) -> dict | None:
        """Get the item dict for the currently highlighted Tree node."""
        tree = self.query_one("#playlist-tree", Tree)
        node = tree.cursor_node
        if node is None:
            return None
        data = node.data
        if isinstance(data, dict) and "id" in data:
            return data
        return None
