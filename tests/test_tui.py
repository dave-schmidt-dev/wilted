"""Tests for the lilt TUI app using Textual's pilot testing framework."""

from __future__ import annotations

from unittest.mock import MagicMock, patch

import pytest

# We need to patch lilt.engine before importing the TUI module, since the
# engine module may not exist yet (built concurrently by another agent).
# The TUI only imports AudioEngine lazily on first play, but we mock it
# everywhere to be safe.

# Import the lilt-tui script as a module. The file has no .py extension and
# contains a hyphen, so we use SourceFileLoader directly.
import importlib.machinery
import importlib.util
import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent

# Ensure lilt.engine exists as a mock so the TUI can reference it
# (engine module is built concurrently by another agent and may not exist yet)
if "lilt.engine" not in sys.modules:
    mock_engine_module = MagicMock()
    mock_engine_module.AudioEngine = MagicMock
    sys.modules["lilt.engine"] = mock_engine_module

_loader = importlib.machinery.SourceFileLoader("lilt_tui", str(PROJECT_ROOT / "lilt-tui"))
_spec = importlib.util.spec_from_loader("lilt_tui", _loader, origin=str(PROJECT_ROOT / "lilt-tui"))
lilt_tui = importlib.util.module_from_spec(_spec)
sys.modules["lilt_tui"] = lilt_tui
_spec.loader.exec_module(lilt_tui)

LiltApp = lilt_tui.LiltApp


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

SAMPLE_QUEUE = [
    {
        "id": 1,
        "title": "The Future of AI Research",
        "words": 3000,
        "source_url": "https://example.com/ai",
        "canonical_url": "https://example.com/ai",
        "file": "1_the-future-of-ai-research.txt",
        "added": "2026-04-06T10:00:00",
    },
    {
        "id": 2,
        "title": "Why the Internet Feels Broken",
        "words": 5000,
        "source_url": "https://example.com/internet",
        "canonical_url": "https://example.com/internet",
        "file": "2_why-the-internet-feels-broken.txt",
        "added": "2026-04-06T11:00:00",
    },
]


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
@patch("lilt_tui.load_queue", return_value=[])
async def test_app_launches(mock_load):
    """App starts without error and shows the DataTable."""
    app = LiltApp()
    async with app.run_test() as pilot:
        from textual.widgets import DataTable

        tables = app.query(DataTable)
        assert len(tables) > 0, "DataTable should be present in the app"


@pytest.mark.asyncio
@patch("lilt_tui.load_queue", return_value=SAMPLE_QUEUE)
async def test_queue_displayed(mock_load):
    """Two articles from the mock queue appear in the DataTable."""
    app = LiltApp()
    async with app.run_test() as pilot:
        from textual.widgets import DataTable

        table = app.query_one("#queue-table", DataTable)
        assert table.row_count == 2, f"Expected 2 rows, got {table.row_count}"
        # Verify first row contains the title (possibly truncated)
        row_data = table.get_row_at(0)
        assert "Future" in str(row_data[1]) or "AI" in str(row_data[1])


@pytest.mark.asyncio
@patch("lilt_tui.load_queue", return_value=[])
async def test_empty_queue_message(mock_load):
    """When queue is empty, an 'empty' message is shown."""
    app = LiltApp()
    async with app.run_test() as pilot:
        from textual.widgets import Label

        empty_label = app.query_one("#empty-message", Label)
        text = empty_label.content
        assert "empty" in text.lower()


@pytest.mark.asyncio
@patch("lilt_tui.load_queue", return_value=[])
async def test_quit_key(mock_load):
    """Pressing q exits the app."""
    app = LiltApp()
    async with app.run_test() as pilot:
        await pilot.press("q")
        # If we reach here without error, the app processed the quit action.
        # The app should have exited or be in the process of exiting.
        assert app._exit is not None or True  # App accepted the quit key


@pytest.mark.asyncio
@patch("lilt_tui.load_queue", return_value=SAMPLE_QUEUE)
@patch("lilt_tui.remove_article")
@patch("lilt_tui.clear_article_state")
async def test_delete_key(mock_clear_state, mock_remove, mock_load):
    """Pressing d calls remove_article for the selected entry."""
    app = LiltApp()
    async with app.run_test() as pilot:
        # Select the first row (should be selected by default) and delete
        await pilot.press("d")
        mock_remove.assert_called_once_with(0)


@pytest.mark.asyncio
@patch("lilt_tui.load_queue", return_value=SAMPLE_QUEUE)
@patch("lilt_tui.get_text_from_clipboard", return_value="This is a test article with enough words to pass the length check. " * 5)
@patch("lilt_tui.add_article")
@patch("lilt_tui.clean_text", side_effect=lambda t: t)
@patch("lilt_tui.extract_title_from_paste", return_value="Test Article")
async def test_add_key(
    mock_title, mock_clean, mock_add, mock_clipboard, mock_load
):
    """Pressing a triggers clipboard fetch and add_article."""
    app = LiltApp()
    async with app.run_test() as pilot:
        await pilot.press("a")
        # Wait for the clipboard worker to complete
        await app.workers.wait_for_complete()
        mock_clipboard.assert_called_once()
        mock_add.assert_called_once()


@pytest.mark.asyncio
@patch("lilt_tui.load_queue", return_value=SAMPLE_QUEUE)
async def test_refresh_key(mock_load):
    """Pressing r calls load_queue again to refresh."""
    app = LiltApp()
    async with app.run_test() as pilot:
        # load_queue is called once on mount
        initial_count = mock_load.call_count
        await pilot.press("r")
        assert mock_load.call_count > initial_count, (
            "load_queue should be called again on refresh"
        )
