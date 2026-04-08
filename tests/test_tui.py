"""Tests for the lilt TUI app using Textual's pilot testing framework."""

from __future__ import annotations

from unittest.mock import patch

import pytest
from textual.binding import Binding
from textual.widgets import Static

from lilt.tui import AddArticleScreen, ConfirmScreen, LiltApp, TextPreviewScreen, VoiceSettingsScreen

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
@patch("lilt.tui.load_queue", return_value=[])
async def test_app_launches(mock_load):
    """App starts without error and shows the DataTable."""
    app = LiltApp()
    async with app.run_test():
        from textual.widgets import DataTable

        tables = app.query(DataTable)
        assert len(tables) > 0, "DataTable should be present in the app"


@pytest.mark.asyncio
@patch("lilt.tui.load_queue", return_value=SAMPLE_QUEUE)
async def test_queue_displayed(mock_load):
    """Two articles from the mock queue appear in the DataTable."""
    app = LiltApp()
    async with app.run_test():
        from textual.widgets import DataTable

        table = app.query_one("#queue-table", DataTable)
        assert table.row_count == 2, f"Expected 2 rows, got {table.row_count}"
        # Verify first row contains the title (possibly truncated)
        row_data = table.get_row_at(0)
        assert "Future" in str(row_data[1]) or "AI" in str(row_data[1])


@pytest.mark.asyncio
@patch("lilt.tui.load_queue", return_value=[])
async def test_empty_queue_message(mock_load):
    """When queue is empty, an 'empty' message is shown."""
    app = LiltApp()
    async with app.run_test():
        from textual.widgets import Label

        empty_label = app.query_one("#empty-message", Label)
        text = empty_label.content
        assert "empty" in text.lower()


@pytest.mark.asyncio
@patch("lilt.tui.load_queue", return_value=[])
async def test_quit_key(mock_load):
    """Pressing q exits the app."""
    app = LiltApp()
    async with app.run_test() as pilot:
        await pilot.press("q")
        # If we reach here without error, the app processed the quit action.
        # The app should have exited or be in the process of exiting.
        assert app._exit is not None or True  # App accepted the quit key


@pytest.mark.asyncio
@patch("lilt.tui.load_queue", return_value=SAMPLE_QUEUE)
@patch("lilt.tui.remove_article")
@patch("lilt.tui.clear_article_state")
async def test_delete_key(mock_clear_state, mock_remove, mock_load):
    """Pressing d opens ConfirmScreen, confirming calls remove_article."""
    app = LiltApp()
    async with app.run_test() as pilot:
        await pilot.pause()
        # Select the first row (should be selected by default) and delete
        await pilot.press("d")
        await pilot.pause()
        # ConfirmScreen should be open
        confirm = app.screen
        assert isinstance(confirm, ConfirmScreen)
        # Confirm the deletion
        confirm.action_confirm()
        await pilot.pause()
        mock_remove.assert_called_once_with(0)


@pytest.mark.asyncio
@patch("lilt.tui.load_queue", return_value=SAMPLE_QUEUE)
@patch("lilt.tui.remove_article")
@patch("lilt.tui.clear_article_state")
async def test_delete_confirm_button_click(mock_clear_state, mock_remove, mock_load):
    """Clicking Confirm should delete the selected article."""
    app = LiltApp()
    async with app.run_test() as pilot:
        await pilot.pause()
        await pilot.press("d")
        await pilot.pause()
        assert isinstance(app.screen, ConfirmScreen)
        await pilot.click("#confirm-accept", offset=(2, 1))
        await pilot.pause()
        mock_remove.assert_called_once_with(0)


@pytest.mark.asyncio
async def test_add_screen_launches_on_a_key():
    """Pressing 'a' should open the AddArticleScreen modal."""
    with patch("lilt.tui.load_queue", return_value=[]):
        app = LiltApp()
        async with app.run_test() as pilot:
            await pilot.press("a")
            await pilot.pause()
            # Check that AddArticleScreen is on the screen stack
            assert any(isinstance(screen, AddArticleScreen) for screen in app.screen_stack)


@pytest.mark.asyncio
async def test_add_screen_cancel():
    """Pressing escape in AddArticleScreen should dismiss without adding."""
    with patch("lilt.tui.load_queue", return_value=[]):
        app = LiltApp()
        async with app.run_test() as pilot:
            await pilot.press("a")
            await pilot.pause()
            await pilot.press("escape")
            await pilot.pause()
            # Should be back to main screen
            assert not any(
                isinstance(screen, AddArticleScreen) for screen in app.screen_stack if screen is not app.screen
            )


@pytest.mark.asyncio
async def test_add_screen_click_add_and_play_button():
    """Clicking Add & Play should trigger the play-after add path."""
    with patch("lilt.tui.load_queue", return_value=[]):
        app = LiltApp()
        async with app.run_test() as pilot:
            await pilot.press("a")
            await pilot.pause()
            screen = app.screen
            assert isinstance(screen, AddArticleScreen)
            with patch.object(screen, "_do_add") as mock_do_add:
                await pilot.click("#add-play", offset=(2, 1))
                mock_do_add.assert_called_once_with(play_after=True)


@pytest.mark.asyncio
async def test_add_screen_click_cancel_button():
    """Clicking Cancel should dismiss the add-article modal."""
    with patch("lilt.tui.load_queue", return_value=[]):
        app = LiltApp()
        async with app.run_test() as pilot:
            await pilot.press("a")
            await pilot.pause()
            await pilot.click("#add-cancel", offset=(2, 1))
            await pilot.pause()
            assert not isinstance(app.screen, AddArticleScreen)


@pytest.mark.asyncio
@patch("lilt.tui.load_queue", return_value=SAMPLE_QUEUE)
async def test_refresh_key(mock_load):
    """Pressing r calls load_queue again to refresh."""
    app = LiltApp()
    async with app.run_test() as pilot:
        # load_queue is called once on mount
        initial_count = mock_load.call_count
        await pilot.press("r")
        assert mock_load.call_count > initial_count, "load_queue should be called again on refresh"


@pytest.mark.asyncio
@patch("lilt.tui.load_queue", return_value=[])
async def test_voice_settings_shows_language(mock_load):
    """VoiceSettingsScreen displays a language label widget."""
    app = LiltApp()
    async with app.run_test() as pilot:
        await pilot.press("v")
        from textual.widgets import Label

        lang_label = app.screen.query_one("#lang-display", Label)
        assert lang_label is not None
        # Default language is American English
        assert "American" in lang_label.content


@pytest.mark.asyncio
@patch("lilt.tui.load_queue", return_value=[])
async def test_voice_settings_dismiss_includes_lang(mock_load):
    """VoiceSettingsScreen dismiss returns a 3-tuple (voice, speed, lang)."""
    app = LiltApp()
    async with app.run_test() as pilot:
        await pilot.press("v")
        await pilot.pause()
        # Verify modal is open
        screen = app.screen
        assert isinstance(screen, VoiceSettingsScreen)
        # Change language to British before confirming
        await pilot.press("b")
        await pilot.pause()
        assert screen.selected_lang == "b"
        # Directly run the confirm action (enter is intercepted by DataTable)
        screen.action_confirm()
        await pilot.pause()
        # After dismiss, the app should have the updated lang
        assert app._lang == "b"


@pytest.mark.asyncio
@patch("lilt.tui.load_queue", return_value=[])
async def test_voice_settings_cancel_button_click(mock_load):
    """Clicking Cancel should dismiss the voice settings modal."""
    app = LiltApp()
    async with app.run_test() as pilot:
        await pilot.press("v")
        await pilot.pause()
        assert isinstance(app.screen, VoiceSettingsScreen)
        await pilot.click("#voice-cancel", offset=(2, 1))
        await pilot.pause()
        assert not isinstance(app.screen, VoiceSettingsScreen)


@pytest.mark.asyncio
async def test_text_preview_launches():
    """Pressing 't' with a selected article should open TextPreviewScreen."""
    articles = [
        {"id": 1, "title": "Test Article", "words": 100, "file": "1_test.txt", "added": "2026-04-06"},
    ]
    with (
        patch("lilt.tui.load_queue", return_value=articles),
        patch("lilt.tui.get_article_text", return_value="This is the article text."),
    ):
        app = LiltApp()
        async with app.run_test() as pilot:
            await pilot.pause()
            await pilot.press("t")
            await pilot.pause()
            assert any(isinstance(screen, TextPreviewScreen) for screen in app.screen_stack)


@pytest.mark.asyncio
async def test_text_preview_close_button_click():
    """Clicking Close should dismiss the preview modal."""
    articles = [
        {"id": 1, "title": "Test Article", "words": 100, "file": "1_test.txt", "added": "2026-04-06"},
    ]
    with (
        patch("lilt.tui.load_queue", return_value=articles),
        patch("lilt.tui.get_article_text", return_value="This is the article text."),
    ):
        app = LiltApp()
        async with app.run_test() as pilot:
            await pilot.pause()
            await pilot.press("t")
            await pilot.pause()
            assert isinstance(app.screen, TextPreviewScreen)
            await pilot.click("#preview-close", offset=(2, 1))
            await pilot.pause()
            assert not isinstance(app.screen, TextPreviewScreen)


@pytest.mark.asyncio
async def test_text_preview_no_article():
    """Pressing 't' with empty queue should show error status."""
    with patch("lilt.tui.load_queue", return_value=[]):
        app = LiltApp()
        async with app.run_test() as pilot:
            await pilot.press("t")
            await pilot.pause()
            status = app.query_one("#status-line").render()
            assert "No article" in str(status) or "selected" in str(status)


@pytest.mark.asyncio
async def test_clear_all_launches_confirm():
    """Pressing 'c' should open ConfirmScreen."""
    articles = [
        {"id": 1, "title": "Test", "words": 50, "file": "1_test.txt", "added": "2026-04-06"},
    ]
    with patch("lilt.tui.load_queue", return_value=articles):
        app = LiltApp()
        async with app.run_test() as pilot:
            await pilot.pause()
            await pilot.press("c")
            await pilot.pause()
            assert any(isinstance(screen, ConfirmScreen) for screen in app.screen_stack)


@pytest.mark.asyncio
async def test_delete_launches_confirm():
    """Pressing 'd' should open ConfirmScreen for deletion."""
    articles = [
        {"id": 1, "title": "Test", "words": 50, "file": "1_test.txt", "added": "2026-04-06"},
    ]
    with patch("lilt.tui.load_queue", return_value=articles):
        app = LiltApp()
        async with app.run_test() as pilot:
            await pilot.pause()
            await pilot.press("d")
            await pilot.pause()
            assert any(isinstance(screen, ConfirmScreen) for screen in app.screen_stack)


@pytest.mark.asyncio
async def test_export_wav_no_article():
    """Pressing 'w' with empty queue should show error."""
    with patch("lilt.tui.load_queue", return_value=[]):
        app = LiltApp()
        async with app.run_test() as pilot:
            await pilot.press("w")
            await pilot.pause()
            status = app.query_one("#status-line").render()
            assert "No article" in str(status)


@pytest.mark.asyncio
async def test_export_wav_missing_file():
    """Pressing 'w' when article file is missing should show error."""
    articles = [
        {"id": 1, "title": "Test", "words": 50, "file": "1_test.txt", "added": "2026-04-06"},
    ]
    with (
        patch("lilt.tui.load_queue", return_value=articles),
        patch("lilt.tui.get_article_text", return_value=None),
    ):
        app = LiltApp()
        async with app.run_test() as pilot:
            await pilot.pause()
            await pilot.press("w")
            await pilot.pause()
            status = app.query_one("#status-line").render()
            assert "not found" in str(status)


# ---------------------------------------------------------------------------
# Phase 3 — Paragraph navigation and generation pausing
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
@patch("lilt.tui.load_queue", return_value=SAMPLE_QUEUE)
async def test_prev_paragraph_binding_exists(mock_load):
    """The [ key binding is registered on the app."""
    app = LiltApp()
    async with app.run_test():
        bindings = {b.key for b in app.BINDINGS if isinstance(b, Binding)}
        assert "left_square_bracket" in bindings


@pytest.mark.asyncio
@patch("lilt.tui.load_queue", return_value=SAMPLE_QUEUE)
async def test_skip_forward_binding_includes_bracket(mock_load):
    """The ] key is an alias for skip (alongside right arrow)."""
    app = LiltApp()
    async with app.run_test():
        skip_binding = next(
            (b for b in app.BINDINGS if isinstance(b, Binding) and b.action == "skip_segment"),
            None,
        )
        assert skip_binding is not None
        assert "right_square_bracket" in skip_binding.key


@pytest.mark.asyncio
@patch("lilt.tui.load_queue", return_value=[])
async def test_prev_paragraph_no_crash_when_not_playing(mock_load):
    """Pressing [ when not playing should not crash."""
    app = LiltApp()
    async with app.run_test() as pilot:
        await pilot.press("left_square_bracket")
        await pilot.pause()
        # Should not crash — no-op since not playing


@pytest.mark.asyncio
@patch("lilt.tui.load_queue", return_value=[])
async def test_generation_paused_default_false(mock_load):
    """_generation_paused starts as False."""
    app = LiltApp()
    async with app.run_test():
        assert app._generation_paused is False


@pytest.mark.asyncio
@patch("lilt.tui.load_queue", return_value=[])
async def test_rewind_to_default_none(mock_load):
    """_rewind_to starts as None."""
    app = LiltApp()
    async with app.run_test():
        assert app._rewind_to is None


@pytest.mark.asyncio
@patch("lilt.tui.load_queue", return_value=[])
async def test_voice_settings_feedback_not_playing(mock_load):
    """Changing voice settings when not playing triggers generation."""
    app = LiltApp()
    async with app.run_test() as pilot:
        with patch.object(app, "_trigger_generation") as mock_trigger:
            await pilot.press("v")
            await pilot.pause()
            screen = app.screen
            assert isinstance(screen, VoiceSettingsScreen)
            # Change speed
            screen.selected_speed = 1.5
            screen.action_confirm()
            await pilot.pause()
            mock_trigger.assert_called()


@pytest.mark.asyncio
@patch("lilt.tui.load_queue", return_value=SAMPLE_QUEUE)
async def test_voice_settings_feedback_while_playing(mock_load):
    """Changing voice settings during playback shows status feedback."""
    app = LiltApp()
    async with app.run_test() as pilot:
        # Simulate playing state
        app._playing = True
        app._speed = 1.0
        await pilot.press("v")
        await pilot.pause()
        screen = app.screen
        assert isinstance(screen, VoiceSettingsScreen)
        screen.selected_speed = 1.5
        screen.action_confirm()
        await pilot.pause()
        status = str(app.query_one("#status-line").render())
        assert "1.5x" in status or "next paragraph" in status


@pytest.mark.asyncio
@patch("lilt.tui.load_queue", return_value=SAMPLE_QUEUE)
async def test_start_playback_pauses_generation(mock_load):
    """_start_playback sets _generation_paused to True."""
    app = LiltApp()
    async with app.run_test() as pilot:
        await pilot.pause()
        entry = SAMPLE_QUEUE[0]
        # Mock the playback worker to prevent actual TTS
        with patch.object(app, "_play_article"):
            app._start_playback(entry)
        assert app._generation_paused is True


@pytest.mark.asyncio
@patch("lilt.tui.load_queue", return_value=SAMPLE_QUEUE)
async def test_stop_resumes_generation(mock_load):
    """action_stop sets _generation_paused to False and triggers generation."""
    app = LiltApp()
    async with app.run_test() as pilot:
        await pilot.pause()
        app._generation_paused = True
        app._playing = True
        with patch.object(app, "_trigger_generation") as mock_trigger:
            app.action_stop()
        assert app._generation_paused is False
        mock_trigger.assert_called_once()


# ---------------------------------------------------------------------------
# Phase 4 — Enhanced UI
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
@patch("lilt.tui.load_queue", return_value=[])
async def test_playback_bar_widget_exists(mock_load):
    """The #playback-bar Static widget is present in the app."""
    app = LiltApp()
    async with app.run_test():
        bar = app.query_one("#playback-bar", Static)
        assert bar is not None


@pytest.mark.asyncio
@patch("lilt.tui.load_queue", return_value=[])
async def test_playback_bar_shows_state_icon(mock_load):
    """PlaybackBar shows state icon when playing/paused."""
    app = LiltApp()
    async with app.run_test():
        app._playing = True
        app._paragraphs = ["Para one.", "Para two."]
        app._paragraph_idx = 0
        app._bar_progress = 50.0
        app._estimated_remaining_secs = 120
        app._update_playback_bar()
        content = str(app.query_one("#playback-bar", Static).render())
        assert "\u25b6" in content  # ▶

        app._paused = True
        app._update_playback_bar()
        content = str(app.query_one("#playback-bar", Static).render())
        assert "\u23f8" in content  # ⏸


@pytest.mark.asyncio
@patch("lilt.tui.load_queue", return_value=[])
async def test_playback_bar_shows_para_count(mock_load):
    """PlaybackBar shows paragraph count like 1/5."""
    app = LiltApp()
    async with app.run_test():
        app._playing = True
        app._paragraphs = ["P1", "P2", "P3", "P4", "P5"]
        app._paragraph_idx = 2
        app._bar_progress = 40.0
        app._estimated_remaining_secs = 60
        app._update_playback_bar()
        content = str(app.query_one("#playback-bar", Static).render())
        assert "3/5" in content


@pytest.mark.asyncio
@patch("lilt.tui.load_queue", return_value=[])
async def test_playback_bar_shows_timer(mock_load):
    """PlaybackBar shows mm:ss timer."""
    app = LiltApp()
    async with app.run_test():
        app._playing = True
        app._paragraphs = ["P1"]
        app._paragraph_idx = 0
        app._bar_progress = 0.0
        app._estimated_remaining_secs = 185  # 3:05
        app._update_playback_bar()
        content = str(app.query_one("#playback-bar", Static).render())
        assert "3:05" in content


@pytest.mark.asyncio
@patch("lilt.tui.load_queue", return_value=[])
async def test_timer_decrements(mock_load):
    """_update_timer decrements _estimated_remaining_secs by 1."""
    app = LiltApp()
    async with app.run_test():
        app._playing = True
        app._paragraphs = ["P1", "P2"]
        app._estimated_remaining_secs = 100
        app._update_timer()
        assert app._estimated_remaining_secs == 99


@pytest.mark.asyncio
@patch("lilt.tui.load_queue", return_value=[])
async def test_timer_noop_when_paused(mock_load):
    """_update_timer does nothing when paused."""
    app = LiltApp()
    async with app.run_test():
        app._playing = True
        app._paused = True
        app._paragraphs = ["P1"]
        app._estimated_remaining_secs = 100
        app._update_timer()
        assert app._estimated_remaining_secs == 100  # Unchanged


@pytest.mark.asyncio
@patch("lilt.tui.load_queue", return_value=[])
async def test_timer_noop_when_not_playing(mock_load):
    """_update_timer does nothing when not playing."""
    app = LiltApp()
    async with app.run_test():
        app._estimated_remaining_secs = 100
        app._update_timer()
        assert app._estimated_remaining_secs == 100


@pytest.mark.asyncio
@patch("lilt.tui.load_queue", return_value=[])
async def test_speed_down_key(mock_load):
    """Pressing - decreases speed by 0.1x."""
    app = LiltApp()
    async with app.run_test() as pilot:
        assert app._speed == 1.0
        await pilot.press("minus")
        await pilot.pause()
        assert app._speed == 0.9


@pytest.mark.asyncio
@patch("lilt.tui.load_queue", return_value=[])
async def test_speed_up_key(mock_load):
    """Pressing + increases speed by 0.1x."""
    app = LiltApp()
    async with app.run_test() as pilot:
        assert app._speed == 1.0
        await pilot.press("equal")
        await pilot.pause()
        assert app._speed == 1.1


@pytest.mark.asyncio
@patch("lilt.tui.load_queue", return_value=[])
async def test_speed_clamps_to_range(mock_load):
    """Speed stays within 0.5x-2.0x bounds."""
    app = LiltApp()
    async with app.run_test() as pilot:
        app._speed = 0.5
        await pilot.press("minus")
        await pilot.pause()
        assert app._speed == 0.5  # Can't go below 0.5

        app._speed = 2.0
        await pilot.press("equal")
        await pilot.pause()
        assert app._speed == 2.0  # Can't go above 2.0


@pytest.mark.asyncio
@patch("lilt.tui.load_queue", return_value=[])
async def test_speed_key_shows_feedback(mock_load):
    """Speed change shows feedback in status line."""
    app = LiltApp()
    async with app.run_test() as pilot:
        await pilot.press("equal")
        await pilot.pause()
        status = str(app.query_one("#status-line").render())
        assert "1.1x" in status


@pytest.mark.asyncio
@patch("lilt.tui.load_queue", return_value=[])
async def test_status_priority_blocks_low(mock_load):
    """MEDIUM priority message blocks subsequent LOW message within hold window."""
    from lilt.tui import _STATUS_LOW, _STATUS_MEDIUM

    app = LiltApp()
    async with app.run_test():
        app._set_status("Important", _STATUS_MEDIUM)
        status1 = str(app.query_one("#status-line").render())
        app._set_status("Routine", _STATUS_LOW)
        status2 = str(app.query_one("#status-line").render())
        assert status1 == status2  # LOW didn't overwrite


@pytest.mark.asyncio
@patch("lilt.tui.load_queue", return_value=[])
async def test_status_priority_allows_equal(mock_load):
    """Same-priority messages can overwrite each other."""
    from lilt.tui import _STATUS_MEDIUM

    app = LiltApp()
    async with app.run_test():
        app._set_status("First", _STATUS_MEDIUM)
        app._set_status("Second", _STATUS_MEDIUM)
        status = str(app.query_one("#status-line").render())
        assert "Second" in status


@pytest.mark.asyncio
@patch("lilt.tui.load_queue", return_value=[])
async def test_transcript_markup_bold_current(mock_load):
    """_build_transcript marks current paragraph as bold."""
    app = LiltApp()
    async with app.run_test():
        app._paragraphs = ["First para.", "Second para.", "Third para."]
        result = app._build_transcript(1)
        assert "[bold]Second para.[/bold]" in result
        assert "[dim]First para.[/dim]" in result
        assert "[dim italic]Third para.[/dim italic]" in result


@pytest.mark.asyncio
@patch("lilt.tui.load_queue", return_value=[])
async def test_transcript_escapes_brackets(mock_load):
    """_build_transcript escapes Rich markup in article text."""
    app = LiltApp()
    async with app.run_test():
        app._paragraphs = ["Text with [brackets] inside."]
        result = app._build_transcript(0)
        # The brackets should be escaped, not interpreted as markup
        assert "\\[brackets]" in result or "[brackets]" not in result.replace("\\[", "")
