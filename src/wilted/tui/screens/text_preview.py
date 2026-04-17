"""Text preview modal screen."""

from __future__ import annotations

from typing import TYPE_CHECKING

from textual.binding import Binding

if TYPE_CHECKING:
    from textual.app import ComposeResult
from textual.containers import Horizontal, Vertical, VerticalScroll
from textual.screen import ModalScreen
from textual.widgets import Button, Label, Static


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
        height: auto;
        align: center middle;
        margin-top: 1;
    }
    .preview-footer Button {
        width: auto;
        margin-right: 1;
    }
    .preview-help {
        width: auto;
        color: $text-muted;
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
                yield Button("Close", id="preview-close", variant="primary")
                yield Label(f"{self._word_count} words", classes="preview-help")

    def action_close(self) -> None:
        self.dismiss(None)

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "preview-close":
            self.action_close()
