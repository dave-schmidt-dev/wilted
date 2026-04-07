"""lilt-tui — Textual TUI for the lilt local TTS article reader."""

from __future__ import annotations

import time
from typing import ClassVar

from textual import work
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical, VerticalScroll
from textual.screen import ModalScreen
from textual.widgets import DataTable, Footer, Header, Input, Label, ProgressBar, Static
from textual.worker import get_current_worker

from lilt import LANGUAGES, VOICES, WPM_ESTIMATE
from lilt.fetch import (
    extract_title_from_url,
    get_text_from_clipboard,
    get_text_from_url,
    resolve_apple_news_url,
)
from lilt.queue import (
    add_article,
    clear_queue,
    get_article_text,
    load_queue,
    mark_completed,
    remove_article,
)
from lilt.state import clear_article_state, get_article_state, set_article_state
from lilt.text import clean_text, extract_title_from_paste, split_paragraphs


# ---------------------------------------------------------------------------
# Voice settings modal
# ---------------------------------------------------------------------------


class VoiceSettingsScreen(ModalScreen[tuple[str, float, str] | None]):
    """Modal for selecting voice and speed."""

    DEFAULT_CSS = """
    VoiceSettingsScreen {
        align: center middle;
    }
    #voice-dialog {
        width: 60;
        height: auto;
        max-height: 80%;
        border: thick $accent;
        background: $surface;
        padding: 1 2;
    }
    #voice-dialog Label {
        width: 100%;
        margin-bottom: 1;
    }
    .voice-title {
        text-style: bold;
        content-align: center middle;
        width: 100%;
    }
    #voice-list {
        height: auto;
        max-height: 20;
        overflow-y: auto;
    }
    #voice-list DataTable {
        height: auto;
    }
    .speed-row {
        height: 3;
        align: center middle;
    }
    .speed-row Label {
        width: auto;
        margin: 0 1;
    }
    .lang-row {
        height: 3;
        align: center middle;
    }
    .lang-row Label {
        width: auto;
        margin: 0 1;
    }
    .button-row {
        height: 3;
        align: center middle;
        margin-top: 1;
    }
    .button-row Label {
        width: auto;
        margin: 0 2;
    }
    """

    BINDINGS = [
        Binding("escape", "cancel", "Cancel", show=True),
        Binding("enter", "confirm", "Confirm", show=True),
        Binding("minus", "speed_down", "-Speed"),
        Binding("equal,plus", "speed_up", "+Speed"),
        Binding("a", "lang_a", "American", show=False),
        Binding("b", "lang_b", "British", show=False),
        Binding("j", "lang_j", "Japanese", show=False),
        Binding("z", "lang_z", "Chinese", show=False),
    ]

    def __init__(
        self, current_voice: str, current_speed: float, current_lang: str = "a", **kwargs
    ) -> None:
        super().__init__(**kwargs)
        self.selected_voice = current_voice
        self.selected_speed = current_speed
        self.selected_lang = current_lang

    def compose(self) -> ComposeResult:
        with Vertical(id="voice-dialog"):
            yield Label("Voice Settings", classes="voice-title")
            with Vertical(id="voice-list"):
                yield DataTable(id="voice-table")
            with Horizontal(classes="speed-row"):
                yield Label("Speed:")
                yield Label(f"{self.selected_speed:.1f}x", id="speed-display")
                yield Label("  [-] slower  [+] faster")
            with Horizontal(classes="lang-row"):
                yield Label("Language:")
                yield Label(LANGUAGES.get(self.selected_lang, "Unknown"), id="lang-display")
                yield Label("  [a]merican [b]ritish [j]apanese [z]chinese")
            with Horizontal(classes="button-row"):
                yield Label("[enter] Confirm  [esc] Cancel")

    def on_mount(self) -> None:
        table = self.query_one("#voice-table", DataTable)
        table.cursor_type = "row"
        table.add_columns("ID", "Name", "Gender", "Accent")
        selected_row = 0
        for i, (vid, info) in enumerate(VOICES.items()):
            table.add_row(vid, info["name"], info["gender"], info["accent"])
            if vid == self.selected_voice:
                selected_row = i
        table.move_cursor(row=selected_row)

    def on_data_table_row_highlighted(
        self, event: DataTable.RowHighlighted
    ) -> None:
        if event.cursor_row is not None:
            table = self.query_one("#voice-table", DataTable)
            row_data = table.get_row_at(event.cursor_row)
            self.selected_voice = str(row_data[0])

    def action_speed_down(self) -> None:
        self.selected_speed = max(0.5, round(self.selected_speed - 0.1, 1))
        self.query_one("#speed-display", Label).update(
            f"{self.selected_speed:.1f}x"
        )

    def action_speed_up(self) -> None:
        self.selected_speed = min(2.0, round(self.selected_speed + 0.1, 1))
        self.query_one("#speed-display", Label).update(
            f"{self.selected_speed:.1f}x"
        )

    def _set_lang(self, code: str) -> None:
        self.selected_lang = code
        self.query_one("#lang-display", Label).update(LANGUAGES.get(code, "Unknown"))

    def action_lang_a(self) -> None:
        self._set_lang("a")

    def action_lang_b(self) -> None:
        self._set_lang("b")

    def action_lang_j(self) -> None:
        self._set_lang("j")

    def action_lang_z(self) -> None:
        self._set_lang("z")

    def action_confirm(self) -> None:
        self.dismiss((self.selected_voice, self.selected_speed, self.selected_lang))

    def action_cancel(self) -> None:
        self.dismiss(None)


# ---------------------------------------------------------------------------
# Add article modal
# ---------------------------------------------------------------------------


class AddArticleScreen(ModalScreen[tuple[str, dict] | None]):
    """Modal for adding an article from URL or clipboard."""

    DEFAULT_CSS = """
    AddArticleScreen {
        align: center middle;
    }
    #add-dialog {
        width: 70;
        height: auto;
        max-height: 60%;
        border: thick $accent;
        background: $surface;
        padding: 1 2;
    }
    .add-title {
        text-style: bold;
        content-align: center middle;
        width: 100%;
        margin-bottom: 1;
    }
    #url-input {
        margin: 1 0;
    }
    #add-status {
        margin-top: 1;
        text-style: italic;
        color: $text-muted;
    }
    .add-help {
        margin-top: 1;
    }
    """

    BINDINGS = [
        Binding("escape", "cancel", "Cancel", show=True),
        Binding("p", "play_after", "Add & Play", show=True, priority=True),
    ]

    def compose(self) -> ComposeResult:
        with Vertical(id="add-dialog"):
            yield Label("Add Article", classes="add-title")
            yield Label("URL (leave blank for clipboard):")
            yield Input(placeholder="https://...", id="url-input")
            yield Label("[enter] Add to queue  [p] Add & play  [esc] Cancel", classes="add-help")
            yield Label("Ready", id="add-status")

    def on_input_submitted(self, event: Input.Submitted) -> None:
        """Handle enter key on the URL input."""
        self._do_add(play_after=False)

    def action_play_after(self) -> None:
        """Add and play immediately."""
        self._do_add(play_after=True)

    def action_cancel(self) -> None:
        self.dismiss(None)

    def _do_add(self, play_after: bool) -> None:
        """Fetch article and dismiss with result."""
        url_input = self.query_one("#url-input", Input)
        url = url_input.value.strip()
        url_input.disabled = True  # Prevent double-submit
        self._fetch_article(url if url else None, play_after)

    @work(thread=True, group="fetch")
    def _fetch_article(self, url: str | None, play_after: bool) -> None:
        """Fetch article in background and dismiss when done."""
        status = self.query_one("#add-status", Label)
        try:
            if url and url.startswith(("http://", "https://")):
                # URL path
                source_url = url
                canonical_url = url

                if "apple.news" in url:
                    self.call_from_thread(status.update, "Resolving Apple News link...")
                    canonical_url = resolve_apple_news_url(url)

                self.call_from_thread(status.update, "Fetching article...")
                text, canonical_url = get_text_from_url(canonical_url if "apple.news" in url else url)

                if not text:
                    self.call_from_thread(status.update, "Error: Could not fetch article (paywall?)")
                    self.call_from_thread(self._re_enable_input)
                    return

                self.call_from_thread(status.update, "Extracting title...")
                title = extract_title_from_url(canonical_url)

                text = clean_text(text)
                entry = add_article(text, title=title, source_url=source_url, canonical_url=canonical_url)
            else:
                # Clipboard path
                self.call_from_thread(status.update, "Reading clipboard...")
                raw = get_text_from_clipboard()

                if not raw or len(raw.strip()) < 50:
                    self.call_from_thread(status.update, "Error: Clipboard empty or too short")
                    self.call_from_thread(self._re_enable_input)
                    return

                text = clean_text(raw)
                title = extract_title_from_paste(text)

                # Check for Apple News URL in clipboard
                import re
                url_match = re.search(r"https://apple\.news/\S+", raw)
                source_url = url_match.group(0) if url_match else None

                entry = add_article(text, title=title, source_url=source_url)

            action = "play" if play_after else "queued"
            title_display = entry.get("title", "Untitled")
            self.call_from_thread(status.update, f"Added: {title_display}")
            # Small delay so user can see the success message
            import time
            time.sleep(0.5)
            self.call_from_thread(self.dismiss, (action, entry))

        except Exception as e:
            self.call_from_thread(status.update, f"Error: {e}")
            self.call_from_thread(self._re_enable_input)

    def _re_enable_input(self) -> None:
        self.query_one("#url-input", Input).disabled = False


# ---------------------------------------------------------------------------
# Confirm dialog modal
# ---------------------------------------------------------------------------


class ConfirmScreen(ModalScreen[bool]):
    """Reusable confirmation dialog."""

    DEFAULT_CSS = """
    ConfirmScreen {
        align: center middle;
    }
    #confirm-dialog {
        width: 50;
        height: auto;
        border: thick $accent;
        background: $surface;
        padding: 1 2;
    }
    .confirm-title {
        text-style: bold;
        content-align: center middle;
        width: 100%;
        margin-bottom: 1;
    }
    #confirm-message {
        margin: 1 0;
    }
    .confirm-buttons {
        height: 3;
        align: center middle;
        margin-top: 1;
    }
    """

    BINDINGS = [
        Binding("enter", "confirm", "Confirm", show=True),
        Binding("escape", "cancel", "Cancel", show=True),
    ]

    def __init__(self, title: str, message: str, **kwargs) -> None:
        super().__init__(**kwargs)
        self._title = title
        self._message = message

    def compose(self) -> ComposeResult:
        with Vertical(id="confirm-dialog"):
            yield Label(self._title, classes="confirm-title")
            yield Label(self._message, id="confirm-message")
            yield Label("[enter] Confirm  [esc] Cancel", classes="confirm-buttons")

    def action_confirm(self) -> None:
        self.dismiss(True)

    def action_cancel(self) -> None:
        self.dismiss(False)


# ---------------------------------------------------------------------------
# Text preview modal
# ---------------------------------------------------------------------------


class TextPreviewScreen(ModalScreen[None]):
    """Scrollable text preview of an article."""

    DEFAULT_CSS = """
    TextPreviewScreen {
        align: center middle;
    }
    #preview-dialog {
        width: 80%;
        height: 80%;
        border: thick $accent;
        background: $surface;
        padding: 1 2;
    }
    .preview-title {
        text-style: bold;
        content-align: center middle;
        width: 100%;
        margin-bottom: 1;
    }
    #preview-scroll {
        height: 1fr;
        border: round $accent;
    }
    #preview-text {
        padding: 1;
    }
    .preview-footer {
        height: 3;
        align: center middle;
        margin-top: 1;
    }
    """

    BINDINGS = [
        Binding("escape", "close", "Close", show=True),
    ]

    def __init__(self, title: str, text: str, word_count: int, **kwargs) -> None:
        super().__init__(**kwargs)
        self._title = title
        self._text = text
        self._word_count = word_count

    def compose(self) -> ComposeResult:
        with Vertical(id="preview-dialog"):
            yield Label(self._title, classes="preview-title")
            with VerticalScroll(id="preview-scroll"):
                yield Static(self._text, id="preview-text")
            with Horizontal(classes="preview-footer"):
                yield Label(f"{self._word_count} words  [esc] Close")

    def action_close(self) -> None:
        self.dismiss(None)


# ---------------------------------------------------------------------------
# Main TUI app
# ---------------------------------------------------------------------------


class LiltApp(App):
    """Local TTS article reader — Textual TUI."""

    TITLE = "lilt"

    DEFAULT_CSS = """
    Screen {
        layout: horizontal;
    }
    #left-panel {
        width: 2fr;
        height: 100%;
        border-right: solid $accent;
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
        margin-bottom: 1;
    }
    #queue-table {
        height: 1fr;
    }
    #now-playing-title {
        text-style: bold;
        margin-bottom: 1;
    }
    #progress-bar {
        margin: 1 0;
    }
    #time-remaining {
        margin-bottom: 1;
    }
    #current-text {
        height: auto;
        max-height: 10;
        margin: 1 0;
        padding: 1;
        border: round $accent;
    }
    #voice-display {
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
        Binding("space", "toggle_play", "Play/Pause"),
        Binding("s", "stop", "Stop"),
        Binding("enter", "play_selected", "Play Selected"),
        Binding("right", "skip_segment", "Skip Seg"),
        Binding("n", "next_article", "Next"),
        Binding("v", "voice_settings", "Voice"),
        Binding("a", "add_article", "Add"),
        Binding("d", "delete_selected", "Delete"),
        Binding("t", "text_preview", "Preview"),
        Binding("c", "clear_all", "Clear All"),
        Binding("w", "export_wav", "Export WAV"),
        Binding("r", "refresh_queue", "Refresh"),
        Binding("q", "quit_app", "Quit"),
    ]

    def __init__(self, **kwargs) -> None:
        super().__init__(**kwargs)
        self._queue: list[dict] = []
        self._engine = None
        self._current_entry: dict | None = None
        self._paragraphs: list[str] = []
        self._paragraph_idx: int = 0
        self._segment_in_paragraph: int = 0
        self._total_segments: int = 0
        self._segments_played: int = 0
        self._playing: bool = False
        self._paused: bool = False
        self._voice: str = "af_heart"
        self._speed: float = 1.0
        self._lang: str = "a"
        self._last_state_save: float = 0.0
        self._playback_worker = None

    def compose(self) -> ComposeResult:
        yield Header()
        with Horizontal():
            with Vertical(id="left-panel"):
                yield Label("Reading List", classes="panel-title")
                yield DataTable(id="queue-table")
                yield Label("", id="empty-message")
            with Vertical(id="right-panel"):
                yield Label("Now Playing", classes="panel-title")
                yield Label("No article selected", id="now-playing-title")
                yield ProgressBar(id="progress-bar", total=100, show_eta=False)
                yield Label("", id="time-remaining")
                yield Static("", id="current-text")
                yield Label("", id="voice-display")
                yield Label("", id="status-line")
        yield Footer()

    def on_mount(self) -> None:
        table = self.query_one("#queue-table", DataTable)
        table.cursor_type = "row"
        table.add_columns("#", "Title", "Words", "Est. Time")
        self._refresh_queue_display()
        self._update_voice_display()

    # -- Queue display ------------------------------------------------------

    def _refresh_queue_display(self) -> None:
        """Reload queue from disk and update the DataTable."""
        self._queue = load_queue()
        table = self.query_one("#queue-table", DataTable)
        saved_cursor = table.cursor_row
        table.clear()
        empty_msg = self.query_one("#empty-message", Label)
        if not self._queue:
            empty_msg.update("Queue is empty. Press [a] to add an article.")
            empty_msg.display = True
        else:
            empty_msg.display = False
            for i, entry in enumerate(self._queue, 1):
                words = entry.get("words", 0)
                minutes = max(1, round(words / (WPM_ESTIMATE * self._speed)))
                title = entry.get("title", "Untitled")
                if len(title) > 40:
                    title = title[:37] + "..."
                table.add_row(str(i), title, str(words), f"~{minutes} min")
        if saved_cursor is not None and saved_cursor < len(self._queue):
            table.move_cursor(row=saved_cursor)

    def _update_voice_display(self) -> None:
        voice_info = VOICES.get(self._voice, {})
        name = voice_info.get("name", self._voice)
        lang_name = LANGUAGES.get(self._lang, self._lang)
        self.query_one("#voice-display", Label).update(
            f"Voice: {self._voice} ({name})  Speed: {self._speed:.1f}x  Lang: {lang_name}"
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
        bar = self.query_one("#progress-bar", ProgressBar)
        bar.update(progress=progress)
        self.query_one("#time-remaining", Label).update(time_remaining)
        self.query_one("#current-text", Static).update(text_snippet)
        if status:
            self.query_one("#status-line", Label).update(status)

    def _set_status(self, msg: str) -> None:
        self.query_one("#status-line", Label).update(msg)

    # -- Engine lazy load ---------------------------------------------------

    def _ensure_engine(self) -> None:
        """Lazy-load the AudioEngine on first use."""
        if self._engine is None:
            from lilt.engine import AudioEngine

            self._engine = AudioEngine(lang=self._lang)

    # -- Playback worker ----------------------------------------------------

    @work(thread=True, exclusive=True, group="playback")
    def _play_article(self, entry: dict, resume_para: int = 0, resume_seg: int = 0) -> None:
        """Play an article from the given paragraph/segment position."""
        worker = get_current_worker()

        self.call_from_thread(self._update_now_playing, status="Loading model...")
        self._ensure_engine()
        engine = self._engine

        engine.voice = self._voice
        engine.speed = self._speed
        engine.lang = self._lang

        text = get_article_text(entry)
        if not text:
            self.call_from_thread(self._set_status, "Error: article text not found")
            return

        paragraphs = split_paragraphs(text)
        if not paragraphs:
            self.call_from_thread(self._set_status, "Error: no text to play")
            return

        self._paragraphs = paragraphs
        self._total_segments = len(paragraphs)  # approximate: 1 segment per paragraph
        self._paragraph_idx = resume_para
        self._segments_played = resume_para

        total_words = entry.get("words", 0)
        title = entry.get("title", "Untitled")

        self.call_from_thread(
            self._update_now_playing,
            title=title,
            status="Playing",
        )

        for para_idx in range(resume_para, len(paragraphs)):
            if worker.is_cancelled:
                break

            self._paragraph_idx = para_idx
            self._segment_in_paragraph = 0

            paragraph = paragraphs[para_idx]
            snippet = paragraph[:120] + "..." if len(paragraph) > 120 else paragraph

            # Calculate progress
            progress = (para_idx / len(paragraphs)) * 100
            words_remaining = sum(len(p.split()) for p in paragraphs[para_idx:])
            mins_remaining = max(1, round(words_remaining / (WPM_ESTIMATE * self._speed)))

            self.call_from_thread(
                self._update_now_playing,
                progress=progress,
                time_remaining=f"~{mins_remaining} min remaining  (para {para_idx + 1}/{len(paragraphs)})",
                text_snippet=snippet,
                status="Playing",
            )

            # Periodically save state
            now = time.time()
            if now - self._last_state_save >= 30:
                set_article_state(entry["id"], para_idx, 0)
                self._last_state_save = now

            # Read voice/speed/lang at segment boundary (allows mid-playback changes)
            engine.voice = self._voice
            engine.speed = self._speed
            engine.lang = self._lang

            try:
                self.call_from_thread(
                    self._set_status, "Generating audio..."
                )
                engine.generate_and_play(paragraph)
            except Exception as e:
                self.call_from_thread(
                    self._set_status, f"Playback error: {e}"
                )
                break

            if worker.is_cancelled:
                break

            self._segments_played = para_idx + 1

        # Finished or cancelled
        if not worker.is_cancelled and self._segments_played >= len(paragraphs):
            # Article completed
            self.call_from_thread(self._on_article_completed, entry)
        else:
            # Stopped or cancelled — save state
            set_article_state(entry["id"], self._paragraph_idx, 0)

    def _on_article_completed(self, entry: dict) -> None:
        """Handle article completion on the main thread."""
        clear_article_state(entry["id"])
        mark_completed(entry)
        self._playing = False
        self._paused = False
        self._current_entry = None
        self._update_now_playing(
            title="Completed!",
            progress=100,
            time_remaining="",
            text_snippet="",
            status="Article finished",
        )
        self._refresh_queue_display()
        # Auto-advance to next article
        if self._queue:
            self._start_playback(self._queue[0])

    def _start_playback(self, entry: dict, resume_para: int = 0, resume_seg: int = 0) -> None:
        """Start playing an article, stopping any current playback."""
        if self._playing and self._engine:
            self._engine.stop()
        if self._playback_worker and self._playback_worker.is_running:
            self._playback_worker.cancel()

        self._current_entry = entry
        self._playing = True
        self._paused = False
        self._last_state_save = time.time()
        self._playback_worker = self._play_article(entry, resume_para, resume_seg)

    # -- Actions (key bindings) ---------------------------------------------

    def action_toggle_play(self) -> None:
        """Play, pause, or resume playback."""
        if self._playing and not self._paused:
            # Pause
            if self._engine:
                self._engine.pause()
            self._paused = True
            self._set_status("Paused")
            if self._current_entry:
                set_article_state(
                    self._current_entry["id"], self._paragraph_idx, 0
                )
        elif self._playing and self._paused:
            # Resume
            if self._engine:
                self._engine.resume()
            self._paused = False
            self._set_status("Playing")
        else:
            # Start playing selected or first article
            entry = self._get_selected_entry()
            if not entry and self._queue:
                entry = self._queue[0]
            if entry:
                # Check for resume state
                saved = get_article_state(entry["id"])
                resume_para = saved["paragraph_idx"] if saved else 0
                resume_seg = saved.get("segment_in_paragraph", 0) if saved else 0
                self._start_playback(entry, resume_para, resume_seg)

    def action_stop(self) -> None:
        """Stop playback completely."""
        if self._playing and self._engine:
            self._engine.stop()
        if self._playback_worker and self._playback_worker.is_running:
            self._playback_worker.cancel()
        if self._current_entry:
            set_article_state(
                self._current_entry["id"], self._paragraph_idx, 0
            )
        self._playing = False
        self._paused = False
        self._set_status("Stopped")

    def action_play_selected(self) -> None:
        """Play the selected article from the queue list."""
        entry = self._get_selected_entry()
        if entry:
            saved = get_article_state(entry["id"])
            resume_para = saved["paragraph_idx"] if saved else 0
            resume_seg = saved.get("segment_in_paragraph", 0) if saved else 0
            self._start_playback(entry, resume_para, resume_seg)

    def action_skip_segment(self) -> None:
        """Skip to the next segment/paragraph."""
        if self._playing and self._engine:
            self._engine.stop()
            # The worker loop will naturally advance to the next paragraph

    def action_next_article(self) -> None:
        """Stop current and play next article in queue."""
        self.action_stop()
        if len(self._queue) > 1:
            # Find current article index and advance
            if self._current_entry:
                current_id = self._current_entry["id"]
                idx = next(
                    (i for i, e in enumerate(self._queue) if e["id"] == current_id),
                    -1,
                )
                next_idx = idx + 1 if idx >= 0 else 0
            else:
                next_idx = 0
            if next_idx < len(self._queue):
                entry = self._queue[next_idx]
                saved = get_article_state(entry["id"])
                resume_para = saved["paragraph_idx"] if saved else 0
                self._start_playback(entry, resume_para)
        elif self._queue:
            self._start_playback(self._queue[0])

    def action_voice_settings(self) -> None:
        """Open voice/speed settings modal."""

        def on_dismiss(result: tuple[str, float, str] | None) -> None:
            if result is not None:
                self._voice, self._speed, self._lang = result
                self._update_voice_display()
                self._refresh_queue_display()  # Update est. time column

        self.push_screen(
            VoiceSettingsScreen(self._voice, self._speed, self._lang), on_dismiss
        )

    def action_add_article(self) -> None:
        """Open the add article dialog."""
        def on_dismiss(result: tuple[str, dict] | None) -> None:
            if result is not None:
                action, entry = result
                self._refresh_queue_display()
                self._set_status(f"Added: {entry.get('title', 'Untitled')}")
                if action == "play":
                    self._start_playback(entry)

        self.push_screen(AddArticleScreen(), on_dismiss)

    def action_delete_selected(self) -> None:
        """Delete the selected article with confirmation."""
        entry = self._get_selected_entry()
        if not entry:
            self._set_status("Nothing to delete")
            return

        title = entry.get("title", "Untitled")
        if len(title) > 40:
            title = title[:37] + "..."

        def on_dismiss(confirmed: bool) -> None:
            if confirmed:
                table = self.query_one("#queue-table", DataTable)
                row_idx = table.cursor_row
                if row_idx is not None and 0 <= row_idx < len(self._queue):
                    # Stop playback if deleting current article
                    if self._current_entry and entry["id"] == self._current_entry["id"]:
                        self.action_stop()
                        self._current_entry = None
                    try:
                        remove_article(row_idx)
                        clear_article_state(entry["id"])
                        self._set_status(f"Deleted: {entry.get('title', 'Untitled')}")
                    except IndexError:
                        self._set_status("Delete failed: invalid index")
                    self._refresh_queue_display()

        self.push_screen(
            ConfirmScreen("Delete Article?", f'Delete "{title}"?'),
            on_dismiss,
        )

    def action_text_preview(self) -> None:
        """Preview the text of the selected article."""
        entry = self._get_selected_entry()
        if not entry:
            self._set_status("No article selected")
            return

        text = get_article_text(entry)
        if text is None:
            self._set_status("Error: article text not found")
            return

        title = entry.get("title", "Untitled")
        word_count = entry.get("words", len(text.split()))
        self.push_screen(TextPreviewScreen(title, text, word_count))

    def action_clear_all(self) -> None:
        """Clear all articles with confirmation."""
        if not self._queue:
            self._set_status("Queue is already empty")
            return

        count = len(self._queue)

        def on_dismiss(confirmed: bool) -> None:
            if confirmed:
                if self._playing:
                    self.action_stop()
                    self._current_entry = None
                cleared = clear_queue()
                self._set_status(f"Cleared {cleared} article(s)")
                self._refresh_queue_display()

        self.push_screen(
            ConfirmScreen("Clear All Articles?", f"This will remove {count} article(s) and delete all cached text."),
            on_dismiss,
        )

    def action_refresh_queue(self) -> None:
        """Refresh queue from disk."""
        self._refresh_queue_display()
        self._set_status("Queue refreshed")

    def action_quit_app(self) -> None:
        """Save state and quit."""
        if self._playing and self._engine:
            self._engine.stop()
        if self._playback_worker and self._playback_worker.is_running:
            self._playback_worker.cancel()
        if self._current_entry:
            set_article_state(
                self._current_entry["id"], self._paragraph_idx, 0
            )
        self.exit()

    # -- WAV export ---------------------------------------------------------

    def action_export_wav(self) -> None:
        """Export selected article to WAV file."""
        entry = self._get_selected_entry()
        if not entry:
            self._set_status("No article selected")
            return

        text = get_article_text(entry)
        if text is None:
            self._set_status("Error: article text not found")
            return

        self._export_wav(entry, text)

    @work(thread=True, exclusive=True, group="export")
    def _export_wav(self, entry: dict, text: str) -> None:
        """Export article to WAV file with progress."""
        import re

        worker = get_current_worker()

        self.call_from_thread(self._set_status, "Loading model...")
        self._ensure_engine()
        engine = self._engine
        engine.voice = self._voice
        engine.speed = self._speed
        engine.lang = self._lang

        paragraphs = split_paragraphs(text)
        if not paragraphs:
            self.call_from_thread(self._set_status, "Error: no text to export")
            return

        all_audio = []
        total = len(paragraphs)

        for i, paragraph in enumerate(paragraphs):
            if worker.is_cancelled:
                self.call_from_thread(self._set_status, "Export cancelled")
                return

            progress = ((i + 1) / total) * 100
            self.call_from_thread(
                self._update_now_playing,
                title=f"Exporting: {entry.get('title', 'Untitled')}",
                progress=progress,
                time_remaining=f"Generating paragraph {i + 1}/{total}",
                status="Exporting...",
            )

            try:
                audio = engine.generate_audio(paragraph)
                if len(audio) > 0:
                    all_audio.append(audio)
            except RuntimeError as e:
                self.call_from_thread(self._set_status, f"Export error: {e}")
                return

        if not all_audio:
            self.call_from_thread(self._set_status, "Error: no audio generated")
            return

        import numpy as np
        combined = np.concatenate(all_audio)

        # Generate filename from title
        title = entry.get("title", "untitled")
        slug = re.sub(r"[^\w\s-]", "", title.lower())
        slug = re.sub(r"[\s_]+", "-", slug).strip("-")[:50]
        filename = f"{slug}.wav"

        self.call_from_thread(self._set_status, f"Writing {filename}...")

        try:
            from mlx_audio.audio_io import write as audio_write
            audio_write(filename, combined, engine.sample_rate)
        except Exception as e:
            self.call_from_thread(self._set_status, f"Write error: {e}")
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
        """Get the queue entry for the currently selected DataTable row."""
        table = self.query_one("#queue-table", DataTable)
        row_idx = table.cursor_row
        if row_idx is not None and 0 <= row_idx < len(self._queue):
            return self._queue[row_idx]
        return None


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    app = LiltApp()
    app.run()
