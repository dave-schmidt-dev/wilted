"""Voice settings modal screen."""

from __future__ import annotations

from typing import TYPE_CHECKING

from textual.binding import Binding

if TYPE_CHECKING:
    from textual.app import ComposeResult
from textual.containers import Horizontal, Vertical, VerticalScroll
from textual.screen import ModalScreen
from textual.widgets import Button, DataTable, Label

from wilted import LANGUAGES, VOICES


class VoiceSettingsScreen(ModalScreen[tuple[str, float, str] | None]):
    """Modal for selecting voice and speed."""

    DEFAULT_CSS = """
    VoiceSettingsScreen {
        align: center middle;
    }
    #voice-dialog {
        width: 60;
        height: 80%;
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
        height: 1fr;
    }
    #voice-list DataTable {
        height: auto;
    }
    .speed-row {
        height: auto;
        align: center middle;
    }
    .speed-row Label {
        width: auto;
        margin: 0 1;
    }
    .lang-row {
        height: auto;
        align: center middle;
    }
    .lang-row Label {
        width: auto;
        margin: 0 1;
    }
    .button-row {
        height: auto;
        align: center middle;
        margin-top: 1;
    }
    .button-row Button {
        width: auto;
        margin: 0 1;
    }
    .button-help {
        width: 100%;
        content-align: center middle;
        color: $text-muted;
    }
    """

    BINDINGS = [
        Binding("escape", "cancel", "Cancel", show=True),
        Binding("enter", "confirm", "Confirm", show=True),
        Binding("left,minus", "speed_down", "-Speed"),
        Binding("right,equal,plus", "speed_up", "+Speed"),
        Binding("a", "lang_a", "American", show=False),
        Binding("b", "lang_b", "British", show=False),
        Binding("j", "lang_j", "Japanese", show=False),
        Binding("z", "lang_z", "Chinese", show=False),
    ]

    def __init__(self, current_voice: str, current_speed: float, current_lang: str = "a", **kwargs) -> None:
        super().__init__(**kwargs)
        self.selected_voice = current_voice
        self.selected_speed = current_speed
        self.selected_lang = current_lang

    def compose(self) -> ComposeResult:
        with Vertical(id="voice-dialog"):
            yield Label("Voice Settings", classes="voice-title")
            with VerticalScroll(id="voice-list"):
                yield DataTable(id="voice-table")
            with Horizontal(classes="speed-row"):
                yield Label("Speed:")
                yield Label(f"{self.selected_speed:.1f}x", id="speed-display")
                yield Label("  [←] slower  [→] faster")
            with Horizontal(classes="lang-row"):
                yield Label("Language:")
                yield Label(LANGUAGES.get(self.selected_lang, "Unknown"), id="lang-display")
                yield Label("  [a]merican [b]ritish [j]apanese [z]chinese")
            with Horizontal(classes="button-row"):
                yield Button("Confirm", id="voice-confirm", variant="primary")
                yield Button("Cancel", id="voice-cancel")
            yield Label("[enter] Confirm  [esc] Cancel", classes="button-help")

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
        table.focus()

    def on_data_table_row_selected(self, event: DataTable.RowSelected) -> None:
        self.action_confirm()

    def on_data_table_row_highlighted(self, event: DataTable.RowHighlighted) -> None:
        if event.cursor_row is not None:
            table = self.query_one("#voice-table", DataTable)
            row_data = table.get_row_at(event.cursor_row)
            self.selected_voice = str(row_data[0])

    def action_speed_down(self) -> None:
        self.selected_speed = max(0.5, round(self.selected_speed - 0.1, 1))
        self.query_one("#speed-display", Label).update(f"{self.selected_speed:.1f}x")

    def action_speed_up(self) -> None:
        self.selected_speed = min(2.0, round(self.selected_speed + 0.1, 1))
        self.query_one("#speed-display", Label).update(f"{self.selected_speed:.1f}x")

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

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "voice-confirm":
            self.action_confirm()
        elif event.button.id == "voice-cancel":
            self.action_cancel()
