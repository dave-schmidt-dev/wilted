"""Add article modal screen."""

from __future__ import annotations

import time
from typing import TYPE_CHECKING

from textual import work
from textual.binding import Binding

if TYPE_CHECKING:
    from textual.app import ComposeResult
from textual.containers import Horizontal, Vertical
from textual.screen import ModalScreen
from textual.widgets import Button, Input, Label

from wilted.queue import add_article


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
        height: auto;
        overflow-y: auto;
    }
    #add-actions {
        height: auto;
        align: center middle;
        margin-top: 1;
    }
    #add-actions Button {
        width: auto;
        margin: 0 1;
    }
    .add-help {
        margin-top: 1;
        width: 100%;
        content-align: center middle;
        color: $text-muted;
    }
    """

    BINDINGS = [
        Binding("escape", "cancel", "Cancel", show=True),
        Binding("ctrl+p", "play_after", "Add & Play", show=True),
    ]

    def compose(self) -> ComposeResult:
        with Vertical(id="add-dialog"):
            yield Label("Add Article", classes="add-title")
            yield Label("URL (or leave blank to use article text from clipboard):")
            yield Input(placeholder="https://...", id="url-input")
            with Horizontal(id="add-actions"):
                yield Button("Add to Queue", id="add-queue", variant="primary")
                yield Button("Add & Play", id="add-play", variant="success")
                yield Button("Cancel", id="add-cancel")
            yield Label("[enter] Add to queue  [ctrl+p] Add & play  [esc] Cancel", classes="add-help")
            yield Label("Ready", id="add-status")

    def on_mount(self) -> None:
        self.query_one("#url-input", Input).focus()

    def on_input_submitted(self, event: Input.Submitted) -> None:
        """Handle enter key on the URL input."""
        self._do_add(play_after=False)

    def on_button_pressed(self, event: Button.Pressed) -> None:
        button_id = event.button.id
        if button_id == "add-queue":
            self._do_add(play_after=False)
        elif button_id == "add-play":
            self._do_add(play_after=True)
        elif button_id == "add-cancel":
            self.action_cancel()

    def action_play_after(self) -> None:
        """Add and play immediately."""
        self._do_add(play_after=True)

    def action_cancel(self) -> None:
        self.dismiss(None)

    def _do_add(self, play_after: bool) -> None:
        """Fetch article and dismiss with result."""
        url_input = self.query_one("#url-input", Input)
        if url_input.disabled:
            return
        url = url_input.value.strip()
        self._set_controls_disabled(True)
        self._fetch_article(url if url else None, play_after)

    @work(thread=True, group="fetch")
    def _fetch_article(self, url: str | None, play_after: bool) -> None:
        """Fetch article in background and dismiss when done."""
        from wilted.ingest import resolve_article

        status = self.query_one("#add-status", Label)
        try:
            result = resolve_article(
                url=url if url and url.startswith(("http://", "https://")) else None,
                min_clipboard_len=50,
                on_status=lambda msg: self.app.call_from_thread(status.update, msg),
            )

            entry = add_article(
                result.text,
                title=result.title,
                source_url=result.source_url,
                canonical_url=result.canonical_url,
            )

            action = "play" if play_after else "queued"
            title_display = entry.get("title", "Untitled")
            self.app.call_from_thread(status.update, f"🥬 Added to larder: {title_display}")
            # Small delay so user can see the success message
            time.sleep(0.5)
            self.app.call_from_thread(self.dismiss, (action, entry))

        except Exception as e:
            self.app.call_from_thread(status.update, f"Error: {e}")
            self.app.call_from_thread(self._set_controls_disabled, False)

    def _set_controls_disabled(self, disabled: bool) -> None:
        self.query_one("#url-input", Input).disabled = disabled
        for button in self.query(Button):
            button.disabled = disabled
