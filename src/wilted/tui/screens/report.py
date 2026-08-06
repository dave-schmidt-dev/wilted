"""Report screen — display morning report items for user selection and review."""

from __future__ import annotations

import logging
from typing import TYPE_CHECKING

from rich.text import Text
from textual import events, on, work
from textual.binding import Binding
from textual.containers import Horizontal, Vertical, VerticalScroll
from textual.coordinate import Coordinate
from textual.screen import ModalScreen
from textual.widgets import Button, DataTable, Footer, Label

if TYPE_CHECKING:
    from textual.app import ComposeResult

from wilted.background_work.contracts import (
    AnalysisState,
    ContentState,
    FetchState,
    PlaybackState,
    PreparationState,
    ReportDecision,
    RetentionFacts,
    RetentionState,
)
from wilted.content_state import read_content_state, selection_history_available, transition_item
from wilted.db import Item, Report, ReportItem, SelectionHistory, worker_db
from wilted.db import now_utc as _now_utc
from wilted.report import update_source_stats

logger = logging.getLogger(__name__)


class ClickSelectDataTable(DataTable):
    """A ``DataTable`` where a single click selects the row that was clicked.

    Textual's ``DataTable._on_click`` computes ``highlight_click`` *before* it moves
    the cursor::

        highlight_click = new_coordinate == self.cursor_coordinate
        self.cursor_coordinate = new_coordinate
        if highlight_click:
            self._post_selected_message()

    so ``RowSelected`` is posted only when the click lands on the row that already
    held the cursor. Clicking down a fresh list moves the cursor and selects nothing
    (BUG-8) — two clicks per row, with the first giving no feedback that it did
    anything.

    The fix is to move the cursor to the clicked row *ahead* of Textual's handler, so
    its own equality check comes out true for the row the user actually clicked. That
    keeps the selection message on Textual's side rather than reimplementing it here.

    This is deliberately the public ``on_click`` rather than an ``_on_click``
    override: ``MessagePump._get_dispatch_methods`` walks the MRO taking
    ``cls.__dict__["_on_click"] or cls.__dict__["on_click"]`` per class, so an
    ``_on_click`` override would be dispatched *in addition to* ``DataTable``'s, and
    a ``super()`` call inside it would run Textual's handler twice. Public handlers
    on a subclass run first, which is exactly the ordering this needs.
    """

    def on_click(self, event: events.Click) -> None:
        meta = event.style.meta
        if "row" not in meta or "column" not in meta:
            return
        row, column = meta["row"], meta["column"]
        # Negative indices are the header row and row labels; leave those to Textual,
        # which has its own HeaderSelected/RowLabelSelected paths for them.
        if row < 0 or column < 0:
            return
        self.cursor_coordinate = Coordinate(row, column)


class ReportScreen(ModalScreen[bool]):
    """Modal screen displaying the morning report for user review and selection."""

    DEFAULT_CSS = """
    ReportScreen {
        align: center middle;
    }
    /* height: auto so a short report is a short dialog. Without it the dialog was
       always 80% tall and a 3-item report left most of the box blank (BUG-9). */
    #report-dialog {
        width: 90%;
        max-width: 120;
        height: auto;
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
    /* auto (not 1fr) so the scroll region collapses to its content and the dialog's
       height: auto can take effect. On long reports this is overridden at runtime by
       _fit_scroll_height(), which is what keeps the action row inside the dialog. */
    #report-scroll {
        height: auto;
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
    # Every close path routes to save_and_close: there is no cancel-without-saving,
    # so a dismissal in the report always sticks (the bug this screen used to have).
    BINDINGS = [
        Binding("a", "select_all", "Select All", priority=True),
        Binding("n", "select_none", "Select None", priority=True),
        Binding("escape,q,s", "save_and_close", "Save & Close", priority=True),
    ]

    def __init__(self, report_data: dict, **kwargs) -> None:
        super().__init__(**kwargs)
        self._report_data = report_data
        self._items: list[dict] = []
        self._item_order: list[int] = []  # item_ids in table order (excluding headers)
        self._selected: dict[int, bool] = {}  # item_id -> selected
        # item_id -> index into _playlists, or None when the item's current playlist is
        # not one of _playlists (e.g. "Uncategorized"). None is a real sentinel, never 0:
        # defaulting to 0 silently means "Work" and was written to the DB as an override
        # the user never chose (BUG-6).
        self._playlist_index: dict[int, int | None] = {}
        self._original_playlist: dict[int, str | None] = {}  # item_id -> original playlist from DB
        self._playlists = ["Work", "Fun", "Education"]
        self._header_rows: set[int] = set()  # row indices that are playlist headers

    def compose(self) -> ComposeResult:
        with Vertical(id="report-dialog"):
            yield Label("Morning Report", id="report-title")
            with VerticalScroll(id="report-scroll"):
                yield ClickSelectDataTable(id="report-table")
            with Horizontal(id="report-actions"):
                yield Button("Save & Close", id="done-button", variant="primary")
            yield Label(
                "[space/enter] Select   [a] All   [n] None   [esc] Save & close — unselected items are dismissed",
                id="report-help",
            )
        yield Footer()

    # Explicit widths keep the Category column on screen instead of letting long
    # titles push it past the dialog's right edge (BUG-9).
    COLUMNS = (
        ("Sel", 3),
        ("Title", 52),
        ("Source", 18),
        ("Category", 12),
    )

    def on_mount(self) -> None:
        table = self.query_one("#report-table", DataTable)
        table.cursor_type = "row"
        table.zebra_stripes = True
        for label, width in self.COLUMNS:
            table.add_column(label, width=width)
        self._populate_table(table)

    def _header_cells(self, playlist: str, count: int) -> tuple[Text, ...]:
        """Cells for a playlist group-header row.

        Built as Rich ``Text`` with a literal style rather than markup. DataTable cells
        are rendered by Rich, which cannot resolve Textual CSS variables, so the previous
        ``[bold $primary]`` markup was dropped and headers rendered identically to items
        (BUG-9). Uppercase plus the marker glyph keeps them distinct without depending on
        a theme colour.
        """
        return (
            Text("▼"),
            Text(f"{playlist.upper()}  ({count})", style="bold"),
            Text(""),
            Text(""),
        )

    def _item_cells(self, item: dict, playlist: str) -> tuple[Text, ...]:
        """Cells for a single report-item row."""
        # An empty checkbox still reads as a checkbox; the old blank cell made the
        # selection column invisible until something was selected (BUG-9).
        check = "[x]" if self._selected.get(item["id"], False) else "[ ]"
        return (
            Text(check),
            Text(item.get("title") or "Untitled"),
            Text(item.get("source_name") or ""),
            Text(playlist or "Uncategorized"),
        )

    def _fill_table(self, table: DataTable) -> int | None:
        """Build every row from the report data, preserving existing selections.

        Shared by first population and rebuild so the two cannot drift apart — the
        header-row bookkeeping that ``_get_item_at_cursor`` relies on is derived here
        once. Returns the index of the first data row, or None if the report is empty.
        """
        self._items = []
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
                self._header_rows.add(table.row_count)
                table.add_row(*self._header_cells(playlist, count))

            item_id = item["id"]
            self._items.append(item)
            self._item_order.append(item_id)
            # Unselected by default: closing without choosing dismisses the report
            # rather than queueing everything (opt-in selection).
            self._selected.setdefault(item_id, False)
            # None, not 0, when the current playlist is not one we can cycle through.
            # Index 0 resolves to the real playlist "Work", which save-and-close then
            # wrote as an override the user never chose (BUG-6).
            self._playlist_index.setdefault(
                item_id,
                self._playlists.index(playlist) if playlist in self._playlists else None,
            )
            self._original_playlist.setdefault(item_id, playlist)

            table.add_row(*self._item_cells(item, playlist))

            if first_data_row is None:
                first_data_row = table.row_count - 1

        return first_data_row

    # Rows the dialog spends on chrome around the scroll region: border (2), padding
    # (2), title plus its margin (2), the action row plus its margin (4), help (1).
    # Locked by the long-report layout test — change the CSS above and it fails.
    CHROME_ROWS = 11
    # Must track max-height on #report-dialog.
    MAX_DIALOG_FRACTION = 0.8

    def _fit_scroll_height(self) -> None:
        """Size the scroll region to its content, capped to leave room for the buttons.

        ``height: auto`` on the dialog is what makes a short report a short dialog
        instead of a mostly-blank 80%-tall box (BUG-9). But Textual's auto layout
        clips at ``max-height`` without re-distributing space, so an unbounded table
        pushes the Save & Close button outside the dialog — off screen entirely on a
        24-row terminal. Capping the scroll here is what keeps both cases correct.

        Two known floors, neither worth code: the ``max(3, ...)`` below keeps three
        rows visible, so on a terminal under ~14 rows the dialog overflows again
        (three rows of list are more useful there than a correctly-clipped empty
        one). And the columns want 93 cells, so ``Category`` is clipped below ~110
        columns — see ``REPORT_WIDTH_FLOOR`` in the layout test.
        """
        table = self.query_one("#report-table", DataTable)
        scroll = self.query_one("#report-scroll", VerticalScroll)
        content = table.row_count + 1  # + the column-label row
        available = int(self.size.height * self.MAX_DIALOG_FRACTION) - self.CHROME_ROWS
        scroll.styles.height = max(3, min(content, available))

    def on_resize(self) -> None:
        self._fit_scroll_height()

    def _populate_table(self, table: DataTable) -> None:
        """Fill the table with report items grouped by playlist."""
        first_data_row = self._fill_table(table)
        self._fit_scroll_height()
        if first_data_row is not None:
            table.move_cursor(row=first_data_row)
        table.focus()

    def _rebuild_table(self) -> None:
        """Rebuild the table preserving cursor position."""
        table = self.query_one("#report-table", DataTable)
        saved_cursor = table.cursor_row
        table.clear()
        first_data_row = self._fill_table(table)
        self._fit_scroll_height()

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
            self._selected[item_id] = not self._selected.get(item_id, False)
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

    def action_save_and_close(self) -> None:
        """Persist the current selection and close.

        Selected items are queued, unselected items are dismissed. Every close
        path (esc/q/s and the button) routes here — there is no cancel-without-
        saving — so a dismissal always sticks. Items default to unselected, so
        closing without choosing dismisses the whole report.
        """
        if not self._items:
            self.dismiss(True)
            return
        # Emit an app-level toast before the modal closes so the disappearance
        # reads as a committed action, not a glitch. Counts come from in-memory
        # selection state; the toast survives dismiss (notifications are app-level).
        accepted = sum(1 for item in self._items if self._selected.get(item["id"], False))
        skipped = len(self._items) - accepted
        if accepted and skipped:
            message = f"Queued {accepted} for audio · dismissed {skipped}"
        elif accepted:
            message = f"Queued {accepted} item{'s' if accepted != 1 else ''} for audio"
        else:
            message = f"Dismissed {skipped} item{'s' if skipped != 1 else ''}"
        self.notify(message, title="Morning report", timeout=4)
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

            for rank, item in enumerate(self._items):
                item_id = item["id"]
                selected = self._selected.get(item_id, False)

                try:
                    db_item = Item.get_by_id(item_id)
                    current = read_content_state(db_item)
                    base_fetch = current.fetch if current else FetchState.CONTENT_READY
                    base_analysis = current.analysis if current else AnalysisState.READY
                    base_playback = current.playback if current else PlaybackState.UNPLAYED
                    base_retention = current.retention if current else RetentionFacts(state=RetentionState.ACTIVE)

                    if selected:
                        transition_item(
                            db_item,
                            ContentState(
                                fetch=base_fetch,
                                analysis=base_analysis,
                                preparation=PreparationState.QUEUED,
                                playback=base_playback,
                                retention=base_retention,
                            ),
                            legacy_status="selected",
                        )
                    else:
                        transition_item(
                            db_item,
                            ContentState(
                                fetch=base_fetch,
                                analysis=base_analysis,
                                preparation=PreparationState.NOT_QUEUED,
                                playback=base_playback,
                                retention=base_retention,
                            ),
                            legacy_status="skipped",
                        )

                    # Apply a playlist override only where the in-memory index names a
                    # real playlist that differs from the item's own. A None index means
                    # the item sits outside _playlists (e.g. "Uncategorized") and the
                    # user has expressed no choice, so nothing is written — the previous
                    # `.get(item_id, 0)` default resolved to "Work" and stamped an
                    # override onto every uncategorized item, dismissed ones included
                    # (BUG-6). Any future playlist-cycling binding must set this index,
                    # which is what makes the comparison below mean "the user chose".
                    playlist_idx = self._playlist_index.get(item_id)
                    if playlist_idx is not None and playlist_idx < len(self._playlists):
                        new_playlist = self._playlists[playlist_idx]
                        original = self._original_playlist.get(item_id)
                        if new_playlist != original:
                            db_item.playlist_override = new_playlist

                    db_item.save()

                    if report is not None:
                        decision = ReportDecision.ACCEPTED if selected else ReportDecision.DISMISSED
                        row, created = ReportItem.get_or_create(
                            report=report,
                            item=db_item,
                            defaults={
                                "rank": rank,
                                "decision": decision.value,
                                "defer_until": None,
                                "created_at": now,
                            },
                        )
                        if not created:
                            row.rank = rank
                            row.decision = decision.value
                            row.defer_until = None
                            row.save()

                    if selection_history_available():
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

    @on(Button.Pressed, "#done-button")
    def _done_button(self) -> None:
        self.action_save_and_close()
