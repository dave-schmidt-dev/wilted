"""Report screen — display morning report items for user selection and review."""

from __future__ import annotations

import logging
from datetime import UTC, datetime
from typing import TYPE_CHECKING

from textual import work
from textual.binding import Binding
from textual.containers import Horizontal, Vertical, VerticalScroll
from textual.screen import ModalScreen
from textual.widgets import Button, DataTable, Label

if TYPE_CHECKING:
    from textual.app import ComposeResult

from wilted.db import Item, Report, SelectionHistory, worker_db
from wilted.report import update_source_stats

logger = logging.getLogger(__name__)


def _now_utc() -> str:
    return datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


class ReportScreen(ModalScreen[bool]):
    """Modal screen displaying the morning report for user review and selection."""

    DEFAULT_CSS = """
    ReportScreen {
        align: center middle;
    }
    #report-dialog {
        width: 80;
        height: 80%;
        max-height: 80%;
        border: thick $primary;
        background: $surface;
        padding: 1 2;
    }
    #report-title {
        text-style: bold;
        color: $primary;
        content-align: center middle;
        width: 100%;
        margin-bottom: 1;
    }
    #report-table {
        height: 1fr;
    }
    DataTable {
        border: none;
    }
    .report-header {
        text-style: bold;
        color: $accent;
        background: $surface;
    }
    .report-selected {
        color: $accent;
        text-style: bold;
    }
    #report-actions {
        height: auto;
        align: center middle;
        margin-top: 1;
    }
    #report-actions Button {
        width: auto;
        margin: 0 1;
    }
    #report-help {
        width: 100%;
        content-align: center middle;
        color: $text-muted;
        margin-top: 1;
    }
    """

    BINDINGS = [
        Binding("escape,q", "dismiss", "Dismiss", show=True),
        Binding("space,enter", "toggle_selection", "Toggle", show=True),
        Binding("a", "select_all", "Select All", show=True),
        Binding("n", "select_none", "Select None", show=True),
        Binding("p", "cycle_playlist", "Cycle Playlist", show=True),
        Binding("s", "accept", "Accept", show=True),
    ]

    def __init__(self, report_data: dict, **kwargs) -> None:
        super().__init__(**kwargs)
        self._report_data = report_data
        self._items: list[dict] = []
        self._item_order: list[int] = []  # item_ids in table order (excluding headers)
        self._selected: dict[int, bool] = {}  # item_id -> selected
        self._playlist_index: dict[int, int] = {}  # item_id -> playlist index
        self._original_playlist: dict[int, str | None] = {}  # item_id -> original playlist from DB
        self._playlists = ["Work", "Fun", "Education"]

    def compose(self) -> ComposeResult:
        with Vertical(id="report-dialog"):
            yield Label("Morning Report", id="report-title")
            with VerticalScroll(id="report-scroll"):
                yield DataTable(id="report-table")
            with Horizontal(id="report-actions"):
                yield Button("Accept Selected", id="accept-button", variant="primary")
                yield Button("Dismiss", id="dismiss-button")
            yield Label(
                "[space] Select  [a] All  [n] None  [p] Playlist  [s] Accept  [q] Dismiss",
                id="report-help",
            )

    def on_mount(self) -> None:
        table = self.query_one("#report-table", DataTable)
        table.cursor_type = "row"
        table.add_columns("", "Selected", "Title", "Source", "Score", "Playlist")

        items_dict = self._report_data["items"]

        # Flatten items and track their playlist
        all_items: list[tuple[str, dict]] = []
        for playlist, items in sorted(items_dict.items()):
            for item in items:
                all_items.append((playlist, item))

        # Add header row for each playlist group
        current_playlist = None
        first_data_row = None
        for playlist, item in all_items:
            if playlist != current_playlist:
                current_playlist = playlist
                # Add a separator/label row
                table.add_row(
                    "",
                    "",
                    f"[bold]{playlist}[/bold]",
                    "",
                    "",
                    "",
                    key=f"header-{playlist}",
                )

            item_id = item["id"]
            self._items.append(item)
            self._item_order.append(item_id)
            self._selected[item_id] = True  # Default: all selected
            self._playlist_index[item_id] = self._playlists.index(playlist) if playlist in self._playlists else 0
            self._original_playlist[item_id] = playlist  # Track original for override detection

            title = item.get("title") or "Untitled"
            if len(title) > 40:
                title = title[:37] + "..."

            source = item.get("source_name") or "Unknown"
            if len(source) > 25:
                source = source[:22] + "..."

            score = item.get("relevance_score")
            score_str = f"{score:.2f}" if score is not None else "N/A"

            playlist_cell = playlist or "Uncategorized"

            self._add_item_row(table, item_id, title, source, score_str, playlist_cell)
            # Track first data row
            if first_data_row is None:
                first_data_row = table.row_count - 1

        # Position cursor on first data row if available, otherwise row 0
        if first_data_row is not None:
            table.move_cursor(row=first_data_row)
        else:
            table.move_cursor(row=0)
        table.focus()

    def _add_item_row(self, table: DataTable, item_id: int, title: str, source: str, score: str, playlist: str) -> None:
        """Add a row for an item and track its position."""
        checkbox = "[x]" if self._selected.get(item_id, True) else "[ ]"
        style = "report-selected" if self._selected.get(item_id, True) else ""
        if style:
            checkbox_str = f"[{style}]{checkbox}[/{style}]"
        else:
            checkbox_str = checkbox
        table.add_row(
            "",
            checkbox_str,
            title,
            source,
            score,
            playlist,
        )

    def _rebuild_table(self) -> None:
        """Rebuild the entire table from scratch."""
        table = self.query_one("#report-table", DataTable)
        saved_cursor = table.cursor_row  # Save cursor position
        table.clear()

        items_dict = self._report_data["items"]

        # Flatten items and track their playlist
        all_items: list[tuple[str, dict]] = []
        for playlist, items in sorted(items_dict.items()):
            for item in items:
                all_items.append((playlist, item))

        # Clear item order
        self._item_order = []

        # Add header row for each playlist group
        current_playlist = None
        first_data_row = None
        for playlist, item in all_items:
            if playlist != current_playlist:
                current_playlist = playlist
                # Add a separator/label row
                table.add_row(
                    "",
                    "",
                    f"[bold]{playlist}[/bold]",
                    "",
                    "",
                    "",
                )

            item_id = item["id"]
            self._item_order.append(item_id)

            title = item.get("title") or "Untitled"
            if len(title) > 40:
                title = title[:37] + "..."

            source = item.get("source_name") or "Unknown"
            if len(source) > 25:
                source = source[:22] + "..."

            score = item.get("relevance_score")
            score_str = f"{score:.2f}" if score is not None else "N/A"

            playlist_cell = playlist or "Uncategorized"
            self._add_item_row(table, item_id, title, source, score_str, playlist_cell)
            # Track first data row
            if first_data_row is None:
                first_data_row = table.row_count - 1

        # Restore cursor position, or fall back to first data row
        if saved_cursor is not None and saved_cursor < table.row_count:
            table.move_cursor(row=saved_cursor)
        elif first_data_row is not None:
            table.move_cursor(row=first_data_row)
        table.focus()

    def _get_item_at_cursor(self) -> tuple[int, dict] | None:
        """Get the item at the current cursor position."""
        table = self.query_one("#report-table", DataTable)
        row_idx = table.cursor_row
        if row_idx is None:
            return None

        # Check if cursor is on a header row (headers have empty col 1)
        row_data = table.get_row_at(row_idx)
        if row_data and len(row_data) >= 2 and not str(row_data[1]).strip():
            return None  # Cursor is on a header row

        # Account for header rows
        # Headers are rows with empty col 0,1 and text in col 2
        header_count = 0
        for i in range(row_idx + 1):
            row_data = table.get_row_at(i)
            if (
                row_data
                and len(row_data) >= 3
                and not str(row_data[0]).strip()
                and not str(row_data[1]).strip()
                and str(row_data[2]).strip()
            ):
                header_count += 1

        data_row_idx = row_idx - header_count

        if 0 <= data_row_idx < len(self._item_order):
            item_id = self._item_order[data_row_idx]
            item = next((i for i in self._items if i["id"] == item_id), None)
            if item:
                return item_id, item
        return None

    def action_toggle_selection(self) -> None:
        """Toggle selection for the item at cursor."""
        cursor_data = self._get_item_at_cursor()
        if cursor_data:
            item_id, _ = cursor_data
            self._selected[item_id] = not self._selected.get(item_id, True)
            self._rebuild_table()

    def action_select_all(self) -> None:
        """Select all items."""
        for item in self._items:
            self._selected[item["id"]] = True
        self._rebuild_table()

    def action_select_none(self) -> None:
        """Select none of the items."""
        for item in self._items:
            self._selected[item["id"]] = False
        self._rebuild_table()

    def action_cycle_playlist(self) -> None:
        """Cycle the playlist for the item at cursor."""
        cursor_data = self._get_item_at_cursor()
        if cursor_data:
            item_id, _ = cursor_data
            current_idx = self._playlist_index.get(item_id, 0)
            new_idx = (current_idx + 1) % len(self._playlists)
            self._playlist_index[item_id] = new_idx
            self._rebuild_table()

    def action_accept(self) -> None:
        """Accept selected items, skip unselected, record in history."""
        if not self._items:
            self.dismiss(True)
            return

        self._save_selections()

    @work(thread=True, exclusive=True, group="report")
    def _save_selections(self) -> None:
        """Save selections to database in a worker thread."""
        with worker_db():
            report_date = self._report_data["report"]["report_date"]

            try:
                report = Report.get(Report.report_date == report_date)
            except Report.DoesNotExist:
                report = None

            now = _now_utc()

            for item in self._items:
                item_id = item["id"]
                selected = self._selected.get(item_id, True)

                # Update item status
                try:
                    db_item = Item.get_by_id(item_id)
                    db_item.status = "selected" if selected else "skipped"
                    db_item.status_changed_at = now

                    # Apply playlist override only if changed from original
                    playlist_idx = self._playlist_index.get(item_id, 0)
                    if playlist_idx < len(self._playlists):
                        new_playlist = self._playlists[playlist_idx]
                        original = self._original_playlist.get(item_id)
                        if new_playlist != original:
                            db_item.playlist_override = new_playlist

                    db_item.save()

                    # Record in selection history
                    SelectionHistory.create(
                        item=db_item,
                        report=report,
                        selected=selected,
                        selected_at=now,
                    )

                except Exception as e:
                    logger.error("Failed to save selection for item %d: %s", item_id, e)

            # Update source stats after selection
            try:
                update_source_stats()
            except Exception as e:
                logger.error("Failed to update source stats: %s", e)

        self.app.call_from_thread(self.dismiss, True)

    def action_dismiss(self) -> None:
        """Dismiss without saving."""
        self.dismiss(False)

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "accept-button":
            self.action_accept()
        elif event.button.id == "dismiss-button":
            self.action_dismiss()
