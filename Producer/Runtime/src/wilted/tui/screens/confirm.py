"""Confirmation dialog modal screen."""

from __future__ import annotations

from typing import TYPE_CHECKING

from textual.binding import Binding

if TYPE_CHECKING:
    from textual.app import ComposeResult
from textual.containers import Horizontal, Vertical
from textual.screen import ModalScreen
from textual.widgets import Button, Label


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
        height: auto;
        align: center middle;
        margin-top: 1;
    }
    .confirm-buttons Button {
        width: auto;
        margin: 0 1;
    }
    .confirm-help {
        width: 100%;
        content-align: center middle;
        color: $text-muted;
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
            with Horizontal(classes="confirm-buttons"):
                yield Button("Confirm", id="confirm-accept", variant="error")
                yield Button("Cancel", id="confirm-cancel")
            yield Label("[enter] Confirm  [esc] Cancel", classes="confirm-help")

    def action_confirm(self) -> None:
        self.dismiss(True)

    def action_cancel(self) -> None:
        self.dismiss(False)

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "confirm-accept":
            self.action_confirm()
        elif event.button.id == "confirm-cancel":
            self.action_cancel()
