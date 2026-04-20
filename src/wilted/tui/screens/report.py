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
        width: 90%;
        max-width: 120;
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
    #report-scroll {
        height: 1fr;
    }
    #report-table {
        height: auto;
    }
    DataTable {
        border: none;
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
    }
    """

    # priority=True overrides parent app bindings (s=stop, a=add, n=next, q=quit)
    BINDINGS = [
        Binding("a", "select_all", "Select All", priority=True),
        Binding("n", "select_none", "Select None", priority=True),
        Binding("s", "accept", "Accept Selected", priority=True),
        Binding("escape,q", "dismiss", "Dismiss", priority=True),
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
        self._header_rows: set[int] = set()  # row indices that are playlist headers

    def compose(self) -> ComposeResult:
        with Vertical(id="report-dialog"):
            yield Label("Morning Report", id="report-title")
            with VerticalScroll(id="report-scroll"):
                yield DataTable(id="report-table")
            yield Label(
                "[bold]enter[/bold] toggle  [bold]a[/bold] all  "
                "[bold]n[/bold] none  [bold]s[/bold] accept  [bold]q[/bold] dismiss",
                id="report-help",
            )
            with Horizontal(id="report-actions"):
                yield Button("Accept Selected", id="accept-button", variant="primary")
                yield Button("Dismiss", id="dismiss-button")

    def on_mount(self) -> None:
        table = self.query_one("#report-table", DataTable)
        table.cursor_type = "row"
        table.zebra_stripes = True
        table.add_columns(" ", "Title", "Source", "Category")
        self._populate_table(table)

    def _populate_table(self, table: DataTable) -> None:
        """Fill the table with report items grouped by playlist."""
        items_dict = self._report_data["items"]

        all_items: list[tuple[str, dict]] = []
        for playlist, items in sorted(items_dict.items()):
            for item in items:
                all_items.append((playlist, item))

        current_playlist = None
        first_data_row = None
        for playlist, item in all_items:
            if playlist != current_playlist:
                current_playlist = playlist
                count = len(items_dict.get(playlist, []))
                row_idx = table.row_count
                table.add_row(
                    "",
                    f"[bold $primary]{playlist}[/bold $primary] ({count})",
                    "",
                    "",
                    key=f"header-{playlist}",
                )
                self._header_rows.add(row_idx)

            item_id = item["id"]
            self._items.append(item)
            self._item_order.append(item_id)
            self._selected[item_id] = True
            self._playlist_index[item_id] = self._playlists.index(playlist) if playlist in self._playlists else 0
            self._original_playlist[item_id] = playlist

            title = item.get("title") or "Untitled"
            source = item.get("source_name") or ""
            playlist_cell = playlist or "Uncategorized"

            check = "  ✓" if self._selected[item_id] else "   "
            table.add_row(check, title, source, playlist_cell)

            if first_data_row is None:
                first_data_row = table.row_count - 1

        if first_data_row is not None:
            table.move_cursor(row=first_data_row)
        table.focus()

    def _rebuild_table(self) -> None:
        """Rebuild the table preserving cursor position."""
        table = self.query_one("#report-table", DataTable)
        saved_cursor = table.cursor_row
        table.clear()
        self._item_order = []
        self._header_rows = set()

        items_dict = self._report_data["items"]

        all_items: list[tuple[str, dict]] = []
        for playlist, items in sorted(items_dict.items()):
            for item in items:
                all_items.append((playlist, item))

        current_playlist = None
        first_data_row = None
        for playlist, item in all_items:
            if playlist != current_playlist:
                current_playlist = playlist
                count = len(items_dict.get(playlist, []))
                row_idx = table.row_count
                table.add_row(
                    "",
                    f"[bold $primary]{playlist}[/bold $primary] ({count})",
                    "",
                    "",
                )
                self._header_rows.add(row_idx)

            item_id = item["id"]
            self._item_order.append(item_id)

            title = item.get("title") or "Untitled"
            source = item.get("source_name") or ""
            playlist_cell = playlist or "Uncategorized"

            check = "  ✓" if self._selected.get(item_id, True) else "   "
            table.add_row(check, title, source, playlist_cell)

            if first_data_row is None:
                first_data_row = table.row_count - 1

        if saved_cursor is not None and saved_cursor < table.row_count:
            table.move_cursor(row=saved_cursor)
        elif first_data_row is not None:
            table.move_cursor(row=first_data_row)
        table.focus()

    def _get_item_at_cursor(self) -> tuple[int, dict] | None:
        """Get the item at the current cursor position, or None for header rows."""
        table = self.query_one("#report-table", DataTable)
        row_idx = table.cursor_row
        if row_idx is None or row_idx in self._header_rows:
            return None

        # Count header rows before cursor to find the data index
        header_count = sum(1 for h in self._header_rows if h < row_idx)
        data_row_idx = row_idx - header_count

        if 0 <= data_row_idx < len(self._item_order):
            item_id = self._item_order[data_row_idx]
            item = next((i for i in self._items if i["id"] == item_id), None)
            if item:
                return item_id, item
        return None

    # DataTable consumes space/enter for its own RowSelected event before
    # screen-level bindings fire. Hook into that event for toggle.
    def on_data_table_row_selected(self, event: DataTable.RowSelected) -> None:
        """Toggle selection when user presses enter/space on a row."""
        self.action_toggle_selection()

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
        """Deselect all items."""
        for item in self._items:
            self._selected[item["id"]] = False
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

                    SelectionHistory.create(
                        item=db_item,
                        report=report,
                        selected=selected,
                        selected_at=now,
                    )

                except Exception as e:
                    logger.error("Failed to save selection for item %d: %s", item_id, e)

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
