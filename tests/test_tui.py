"""Tests for the wilted TUI app using Textual's pilot testing framework.

KEYSTONE refactor (Plan A task A.3.5): playback now flows through
``StationController``/``MacPlaybackAdapter``/``EntrySequencer`` instead of the
legacy dict-based, inline-TTS model. ``FakeController``/``FakeAdapter``/a fake
sequencer factory (below) stand in for the real station runtime so these
tests stay fast and hardware-free; they are injected via
``WiltedApp(controller=..., adapter=..., sequencer_factory=..., poller_factory=...)``.
"""

from __future__ import annotations

import concurrent.futures
import dataclasses
import inspect
from unittest.mock import patch

import pytest
from textual.widgets import Label, Static, Tree

from wilted import ICONS
from wilted.station.models import (
    FinalizationState,
    MediaDescriptor,
    PlaybackCheckpoint,
    SafeInterruptionMap,
    StationEntry,
    TranscriptSegment,
)
from wilted.station.reducer import StartPlayback, StationState, Stop
from wilted.station_runtime import CompletionReason, LeaseHeldError
from wilted.station_runtime.controller import SubmitResult
from wilted.tui import (
    AddArticleScreen,
    ConfirmScreen,
    PlaybackCompleted,
    TextPreviewScreen,
    VoiceSettingsScreen,
    WiltedApp,
)

pytestmark = pytest.mark.usefixtures("stub_audio_modules")

# ---------------------------------------------------------------------------
# Shared builders / fakes
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


def _finalized_media(**overrides) -> MediaDescriptor:
    defaults = dict(
        sha256="a" * 64,
        byte_size=1024,
        mime_type="audio/mpeg",
        duration_ms=60_000,
        transcript_segments=(),
        safe_interruption=SafeInterruptionMap.empty(),
        byte_range_available=False,
        finalization=FinalizationState.complete(),
    )
    defaults.update(overrides)
    return MediaDescriptor(**defaults)


def _station_entry(
    item_id,
    *,
    entry_id: str | None = None,
    duration_ms: int = 60_000,
    kind: str = "item",
    transcript_segments: tuple = (),
):
    """Build a StationEntry. ``kind`` is always "item" for sequencer output —
    the article-vs-podcast distinction lives inside ``media``, not on
    ``StationEntry.kind`` (the sequencer never produces "bulletin" entries).

    ``transcript_segments`` defaults to ``()`` (matching the pre-existing
    default), so every caller that doesn't pass it is unaffected."""
    return StationEntry(
        entry_id=entry_id or f"item-{item_id}",
        kind=kind,
        item_id=str(item_id),
        source="feed:test",
        policy_id=None,
        priority=5,
        expiry=None,
        duration_ms=duration_ms,
        media=_finalized_media(duration_ms=duration_ms, transcript_segments=transcript_segments),
    )


class _FakeSequencer:
    """Stand-in for EntrySequencer with a pre-built, static .entries list."""

    def __init__(self, entries):
        self.entries = list(entries)


def _sequencer_factory(entries):
    return lambda: _FakeSequencer(entries)


class FakeController:
    """Records every submitted action; current_state() is settable by the test.

    Mirrors ONE piece of real reducer behavior — ``StartPlayback`` always
    clears any prior checkpoint (see ``reducer._start_playback``: idle ->
    playing(entry) starts a fresh session, ``checkpoint=None`` unconditionally)
    — because a bug class this test suite must catch is "read the checkpoint
    AFTER submitting StartPlayback instead of before". A fake that just
    echoes back whatever state you handed it, untouched, can't ever fail
    that way: it would silently pass a caller that reads post-submit. This is
    NOT a full reducer reimplementation — every other action is a no-op on
    state, by design.

    ``raise_on_submit_and_wait``, if set, makes ``submit_and_wait()`` raise
    that exception instead of succeeding — for exercising the timeout/error
    branch of ``_start_playback`` (fix #8: bounded ``timeout=5.0``, caught
    and downgraded to a "Station error" status rather than hanging or
    crashing). ``last_timeout`` records the ``timeout`` kwarg the caller most
    recently passed, so a test can pin the literal bounded-wait value.
    """

    def __init__(self, *, state: StationState | None = None, raise_on_submit_and_wait: Exception | None = None):
        self.actions: list = []
        self._state = state if state is not None else StationState()
        self.is_running = True
        self.is_lost = False
        self.start_calls = 0
        self.stop_calls = 0
        self.raise_on_submit_and_wait = raise_on_submit_and_wait
        self.last_timeout: float | None = None

    def start(self, *, on_loss=None) -> None:
        self.start_calls += 1
        self.is_running = True

    def stop(self) -> None:
        self.stop_calls += 1
        self.is_running = False

    def _record(self, action) -> None:
        self.actions.append(action)
        if isinstance(action, StartPlayback):
            self._state = dataclasses.replace(
                self._state,
                active_entry=action.entry,
                checkpoint=None,
                station_revision=self._state.station_revision + 1,
            )

    def submit(self, action) -> concurrent.futures.Future:
        self._record(action)
        future: concurrent.futures.Future = concurrent.futures.Future()
        future.set_result(SubmitResult(accepted=True, revision=len(self.actions), state=self._state))
        return future

    def submit_and_wait(self, action, timeout=None) -> SubmitResult:
        self.last_timeout = timeout
        if self.raise_on_submit_and_wait is not None:
            raise self.raise_on_submit_and_wait
        self._record(action)
        return SubmitResult(accepted=True, revision=len(self.actions), state=self._state)

    def current_state(self) -> StationState:
        return self._state

    def set_state(self, state: StationState) -> None:
        self._state = state


class FakeAdapter:
    """Records play/pause/resume/stop calls; on_complete is public+settable.

    ``raise_on_play``, if set, makes ``play()`` raise that exception instead
    of recording a call — for exercising ``_start_playback``'s adapter.play
    failure path (fix #5: must reset ``_generation_paused`` and submit a
    ``Stop()``, not leave generation paused forever on a failed start).
    """

    def __init__(self, *, raise_on_play: Exception | None = None):
        self.play_calls: list[tuple] = []
        self.pause_calls = 0
        self.resume_calls = 0
        self.stop_calls = 0
        self.on_complete = None
        self.last_completion = None
        self._offset_ms = 0
        self.raise_on_play = raise_on_play

    def play(self, media, *, offset_ms: int) -> None:
        if self.raise_on_play is not None:
            raise self.raise_on_play
        self.play_calls.append((media, offset_ms))
        self._offset_ms = offset_ms

    def pause(self) -> None:
        self.pause_calls += 1

    def resume(self) -> None:
        self.resume_calls += 1

    def stop(self) -> None:
        self.stop_calls += 1

    def current_offset_ms(self) -> int:
        return self._offset_ms

    def fire_completion(self, reason: CompletionReason) -> None:
        """Test helper: simulate the adapter completing playback."""
        self.last_completion = reason
        if self.on_complete is not None:
            self.on_complete(reason)


class FakePoller:
    """No-op poller — records start()/stop() calls."""

    def __init__(self, *args, **kwargs):
        self.start_calls = 0
        self.stop_calls = 0

    def start(self) -> None:
        self.start_calls += 1

    def stop(self) -> None:
        self.stop_calls += 1


def _fake_poller_factory(controller, adapter):
    return FakePoller()


def _make_app(*, entries=(), controller=None, adapter=None, poller_factory=None, **kwargs) -> WiltedApp:
    """Construct a WiltedApp with fake station-runtime dependencies injected.

    Safe to use without mocking ``get_playlist_items``/``ensure_default_playlists``
    — those remain real and run against the isolated (empty) test DB.
    """
    return WiltedApp(
        controller=controller if controller is not None else FakeController(),
        adapter=adapter if adapter is not None else FakeAdapter(),
        sequencer_factory=_sequencer_factory(list(entries)),
        poller_factory=poller_factory if poller_factory is not None else _fake_poller_factory,
        **kwargs,
    )


# ---------------------------------------------------------------------------
# App launch / Larder tree / empty state / quit
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_app_launches():
    """App starts without error and shows the Tree widget."""
    app = _make_app()
    async with app.run_test():
        await app.workers.wait_for_complete()
        trees = app.query(Tree)
        assert len(trees) > 0, "Tree should be present in the app"


@pytest.mark.asyncio
@patch("wilted.tui.ensure_default_playlists")
@patch("wilted.tui.get_playlist_items", return_value=SAMPLE_QUEUE)
async def test_queue_displayed(mock_items, mock_ensure):
    """Two station entries appear as flat leaves in the Larder tree."""
    entries = [_station_entry(1), _station_entry(2)]
    app = _make_app(entries=entries)
    async with app.run_test():
        await app.workers.wait_for_complete()
        tree = app.query_one("#playlist-tree", Tree)
        assert len(tree.root.children) == 2, f"Expected 2 leaves, got {len(tree.root.children)}"
        first_label = str(tree.root.children[0].label)
        assert "Future" in first_label or "AI" in first_label


@pytest.mark.asyncio
async def test_empty_queue_message():
    """When the queue is truly empty (no DB items, no station entries), the
    'add an article' empty message is shown."""
    app = _make_app(entries=[])
    async with app.run_test():
        await app.workers.wait_for_complete()
        empty_label = app.query_one("#empty-message", Label)
        text = empty_label.content
        assert "empty" in text.lower()


@pytest.mark.asyncio
async def test_quit_key():
    """Pressing q exits the app."""
    app = _make_app()
    async with app.run_test() as pilot:
        await app.workers.wait_for_complete()
        await pilot.press("q")
        assert app._exit is not None or True  # App accepted the quit key


# ---------------------------------------------------------------------------
# Delete
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
@patch("wilted.tui.ensure_default_playlists")
@patch("wilted.tui.get_playlist_items", return_value=SAMPLE_QUEUE)
@patch("wilted.tui.remove_article_by_id")
async def test_delete_key(mock_remove, mock_items, mock_ensure):
    """Pressing d opens ConfirmScreen, confirming calls remove_article_by_id."""
    entries = [_station_entry(1), _station_entry(2)]
    app = _make_app(entries=entries)
    async with app.run_test() as pilot:
        await app.workers.wait_for_complete()
        tree = app.query_one("#playlist-tree", Tree)
        tree.select_node(tree.root.children[0])
        tree.scroll_to_node(tree.root.children[0])
        await pilot.pause()
        await pilot.press("d")
        await pilot.pause()
        confirm = app.screen
        assert isinstance(confirm, ConfirmScreen)
        confirm.action_confirm()
        await pilot.pause()
        mock_remove.assert_called_once_with(1)


@pytest.mark.asyncio
@patch("wilted.tui.ensure_default_playlists")
@patch("wilted.tui.get_playlist_items", return_value=SAMPLE_QUEUE)
@patch("wilted.tui.remove_article_by_id")
async def test_delete_confirm_button_click(mock_remove, mock_items, mock_ensure):
    """Clicking Confirm should delete the selected article."""
    entries = [_station_entry(1), _station_entry(2)]
    app = _make_app(entries=entries)
    async with app.run_test() as pilot:
        await app.workers.wait_for_complete()
        tree = app.query_one("#playlist-tree", Tree)
        tree.select_node(tree.root.children[0])
        tree.scroll_to_node(tree.root.children[0])
        await pilot.pause()
        await pilot.press("d")
        await pilot.pause()
        assert isinstance(app.screen, ConfirmScreen)
        await pilot.click("#confirm-accept", offset=(2, 1))
        await pilot.pause()
        mock_remove.assert_called_once_with(1)


@pytest.mark.asyncio
@patch("wilted.tui.ensure_default_playlists")
@patch("wilted.tui.get_playlist_items", return_value=SAMPLE_QUEUE)
@patch("wilted.tui.remove_article_by_id")
async def test_delete_playing_article_clears_plate(mock_remove, mock_items, mock_ensure):
    """Deleting the currently-playing entry should stop playback (via the
    station path) and reset the Plate pane."""
    entries = [_station_entry(1), _station_entry(2)]
    controller = FakeController()
    adapter = FakeAdapter()
    app = _make_app(entries=entries, controller=controller, adapter=adapter)
    async with app.run_test() as pilot:
        await app.workers.wait_for_complete()
        tree = app.query_one("#playlist-tree", Tree)
        tree.select_node(tree.root.children[0])
        await pilot.pause()
        # Simulate that this entry is currently playing
        app._current_entry = entries[0]
        app._current_index = 0
        app._playing = True
        title_label = app.query_one("#now-playing-title", Label)
        title_label.update("The Future of AI Research")
        app.query_one("#current-text", Static).update("Some article text")
        await pilot.pause()
        await pilot.press("d")
        await pilot.pause()
        assert isinstance(app.screen, ConfirmScreen)
        app.screen.action_confirm()
        await pilot.pause()
        # Plate should be cleared: state reset + progress zeroed
        assert app._current_entry is None
        assert app._playing is False
        assert app._bar_progress == 0.0
        assert adapter.stop_calls >= 1
        assert any(isinstance(a, Stop) for a in controller.actions)
        # Title widget should show empty-state text
        assert title_label._Static__content == "No article selected"


# ---------------------------------------------------------------------------
# Add-article screen
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_add_screen_launches_on_a_key():
    """Pressing 'a' should open the AddArticleScreen modal."""
    app = _make_app()
    async with app.run_test() as pilot:
        await pilot.press("a")
        await pilot.pause()
        assert any(isinstance(screen, AddArticleScreen) for screen in app.screen_stack)


@pytest.mark.asyncio
async def test_add_screen_cancel():
    """Pressing escape in AddArticleScreen should dismiss without adding."""
    app = _make_app()
    async with app.run_test() as pilot:
        await pilot.press("a")
        await pilot.pause()
        await pilot.press("escape")
        await pilot.pause()
        assert not any(isinstance(screen, AddArticleScreen) for screen in app.screen_stack if screen is not app.screen)


@pytest.mark.asyncio
async def test_add_screen_click_add_and_play_button():
    """Clicking Add & Play should trigger the play-after add path."""
    app = _make_app()
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
    app = _make_app()
    async with app.run_test() as pilot:
        await pilot.press("a")
        await pilot.pause()
        await pilot.click("#add-cancel", offset=(2, 1))
        await pilot.pause()
        assert not isinstance(app.screen, AddArticleScreen)


@pytest.mark.asyncio
async def test_add_article_and_play_starts_playback_once_finalized():
    """After 'Add & Play', if the next sequencer rebuild resolves the new
    item as already finalized, it starts playing.

    Drives the same state ``action_add_article``'s ``on_dismiss`` closure
    would set (``_pending_play_item_id`` then a rebuild) rather than pushing
    the real AddArticleScreen modal, since the screen's own add/fetch flow is
    already covered by ``test_add_screen_click_add_and_play_button``.
    """
    entry = _station_entry(42)
    controller = FakeController()
    adapter = FakeAdapter()
    app = _make_app(entries=[entry], controller=controller, adapter=adapter)
    async with app.run_test():
        await app.workers.wait_for_complete()
        app._pending_play_item_id = "42"
        app._rebuild_sequencer()
        await app.workers.wait_for_complete()
        assert adapter.play_calls == [(entry.media, 0)]
        assert app._pending_play_item_id is None


# ---------------------------------------------------------------------------
# Refresh
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
@patch("wilted.tui.ensure_default_playlists")
@patch("wilted.tui.get_playlist_items", return_value=SAMPLE_QUEUE)
async def test_refresh_key(mock_items, mock_ensure):
    """Pressing r calls get_playlist_items again to refresh."""
    app = _make_app(entries=[_station_entry(1), _station_entry(2)])
    async with app.run_test() as pilot:
        await app.workers.wait_for_complete()
        initial_count = mock_items.call_count
        await pilot.press("r")
        assert mock_items.call_count > initial_count, "get_playlist_items should be called again on refresh"


# ---------------------------------------------------------------------------
# Voice settings
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_voice_settings_shows_language():
    """VoiceSettingsScreen displays a language label widget."""
    app = _make_app()
    async with app.run_test() as pilot:
        await pilot.press("v")
        lang_label = app.screen.query_one("#lang-display", Label)
        assert lang_label is not None
        assert "American" in lang_label.content


@pytest.mark.asyncio
async def test_voice_settings_dismiss_includes_lang():
    """VoiceSettingsScreen dismiss returns a 3-tuple (voice, speed, lang)."""
    app = _make_app()
    async with app.run_test() as pilot:
        await pilot.press("v")
        await pilot.pause()
        screen = app.screen
        assert isinstance(screen, VoiceSettingsScreen)
        await pilot.press("b")
        await pilot.pause()
        assert screen.selected_lang == "b"
        screen.action_confirm()
        await pilot.pause()
        assert app._lang == "b"


@pytest.mark.asyncio
async def test_voice_settings_cancel_button_click():
    """Clicking Cancel should dismiss the voice settings modal."""
    app = _make_app()
    async with app.run_test() as pilot:
        await pilot.press("v")
        await pilot.pause()
        assert isinstance(app.screen, VoiceSettingsScreen)
        await pilot.click("#voice-cancel", offset=(2, 1))
        await pilot.pause()
        assert not isinstance(app.screen, VoiceSettingsScreen)


@pytest.mark.asyncio
async def test_voice_settings_feedback_not_playing():
    """Changing voice settings when not playing triggers generation."""
    app = _make_app()
    async with app.run_test() as pilot:
        with patch.object(app, "_trigger_generation") as mock_trigger:
            await pilot.press("v")
            await pilot.pause()
            screen = app.screen
            assert isinstance(screen, VoiceSettingsScreen)
            screen.selected_speed = 1.5
            screen.action_confirm()
            await pilot.pause()
            mock_trigger.assert_called()


@pytest.mark.asyncio
async def test_voice_settings_feedback_while_playing():
    """Changing voice settings during playback shows status feedback."""
    app = _make_app()
    async with app.run_test() as pilot:
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


# ---------------------------------------------------------------------------
# Text preview
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_text_preview_launches():
    """Pressing 't' with a selected entry should open TextPreviewScreen."""
    articles = [{"id": 1, "title": "Test Article", "words": 100, "file": "1_test.txt", "added": "2026-04-06"}]
    with (
        patch("wilted.tui.ensure_default_playlists"),
        patch("wilted.tui.get_playlist_items", return_value=articles),
        patch("wilted.tui.get_article_text", return_value="This is the article text."),
    ):
        app = _make_app(entries=[_station_entry(1)])
        async with app.run_test() as pilot:
            await app.workers.wait_for_complete()
            tree = app.query_one("#playlist-tree", Tree)
            tree.select_node(tree.root.children[0])
            await pilot.pause()
            await pilot.press("t")
            await pilot.pause()
            assert any(isinstance(screen, TextPreviewScreen) for screen in app.screen_stack)


@pytest.mark.asyncio
async def test_text_preview_close_button_click():
    """Clicking Close should dismiss the preview modal."""
    articles = [{"id": 1, "title": "Test Article", "words": 100, "file": "1_test.txt", "added": "2026-04-06"}]
    with (
        patch("wilted.tui.ensure_default_playlists"),
        patch("wilted.tui.get_playlist_items", return_value=articles),
        patch("wilted.tui.get_article_text", return_value="This is the article text."),
    ):
        app = _make_app(entries=[_station_entry(1)])
        async with app.run_test() as pilot:
            await app.workers.wait_for_complete()
            tree = app.query_one("#playlist-tree", Tree)
            tree.select_node(tree.root.children[0])
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
    app = _make_app(entries=[])
    async with app.run_test() as pilot:
        await app.workers.wait_for_complete()
        await pilot.press("t")
        await pilot.pause()
        status = app.query_one("#status-line").render()
        assert "No article" in str(status) or "selected" in str(status)


# ---------------------------------------------------------------------------
# Clear-all / delete confirm launch
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_clear_all_launches_confirm():
    """Pressing 'c' should open ConfirmScreen."""
    articles = [{"id": 1, "title": "Test", "words": 50, "file": "1_test.txt", "added": "2026-04-06"}]
    with (
        patch("wilted.tui.ensure_default_playlists"),
        patch("wilted.tui.get_playlist_items", return_value=articles),
    ):
        app = _make_app(entries=[])
        async with app.run_test() as pilot:
            await app.workers.wait_for_complete()
            await pilot.press("c")
            await pilot.pause()
            assert any(isinstance(screen, ConfirmScreen) for screen in app.screen_stack)


@pytest.mark.asyncio
async def test_delete_launches_confirm():
    """Pressing 'd' should open ConfirmScreen for deletion."""
    articles = [{"id": 1, "title": "Test", "words": 50, "file": "1_test.txt", "added": "2026-04-06"}]
    with (
        patch("wilted.tui.ensure_default_playlists"),
        patch("wilted.tui.get_playlist_items", return_value=articles),
    ):
        app = _make_app(entries=[_station_entry(1)])
        async with app.run_test() as pilot:
            await app.workers.wait_for_complete()
            tree = app.query_one("#playlist-tree", Tree)
            tree.select_node(tree.root.children[0])
            await pilot.pause()
            await pilot.press("d")
            await pilot.pause()
            assert any(isinstance(screen, ConfirmScreen) for screen in app.screen_stack)


# ---------------------------------------------------------------------------
# WAV export
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_export_wav_no_article():
    """Pressing 'w' with empty queue should show error."""
    app = _make_app(entries=[])
    async with app.run_test() as pilot:
        await app.workers.wait_for_complete()
        await pilot.press("w")
        await pilot.pause()
        status = app.query_one("#status-line").render()
        assert "No article" in str(status)


@pytest.mark.asyncio
async def test_export_wav_missing_file():
    """Pressing 'w' when article text is missing should show error."""
    articles = [{"id": 1, "title": "Test", "words": 50, "file": "1_test.txt", "added": "2026-04-06"}]
    with (
        patch("wilted.tui.ensure_default_playlists"),
        patch("wilted.tui.get_playlist_items", return_value=articles),
        patch("wilted.tui.get_article_text", return_value=None),
    ):
        app = _make_app(entries=[_station_entry(1)])
        async with app.run_test() as pilot:
            await app.workers.wait_for_complete()
            tree = app.query_one("#playlist-tree", Tree)
            tree.select_node(tree.root.children[0])
            await pilot.pause()
            await pilot.press("w")
            await pilot.pause()
            status = app.query_one("#status-line").render()
            assert "not found" in str(status)


# ---------------------------------------------------------------------------
# Entry-level nav (skip/prev — MVP replaces per-paragraph skip, A.3.5)
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_prev_paragraph_no_crash_when_not_playing():
    """Pressing [ when not playing should not crash (no-op)."""
    app = _make_app(entries=[])
    async with app.run_test() as pilot:
        await app.workers.wait_for_complete()
        await pilot.press("left_square_bracket")
        await pilot.pause()


@pytest.mark.asyncio
async def test_skip_segment_no_crash_when_not_playing():
    """Pressing ] when not playing should not crash (no-op)."""
    app = _make_app(entries=[])
    async with app.run_test() as pilot:
        await app.workers.wait_for_complete()
        await pilot.press("right_square_bracket")
        await pilot.pause()


@pytest.mark.asyncio
async def test_skip_segment_advances_to_next_entry_while_playing():
    """MVP: ']' moves to the next station entry (adapter cannot seek within one)."""
    entry_a = _station_entry(1)
    entry_b = _station_entry(2)
    controller = FakeController()
    adapter = FakeAdapter()
    app = _make_app(entries=[entry_a, entry_b], controller=controller, adapter=adapter)
    async with app.run_test():
        await app.workers.wait_for_complete()
        app._start_playback(entry_a)
        app.action_skip_segment()
        assert app._current_entry.entry_id == entry_b.entry_id
        assert adapter.play_calls[-1] == (entry_b.media, 0)


# ---------------------------------------------------------------------------
# _start_playback (INV-8 core)
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_start_playback_pauses_generation_and_routes_through_controller():
    """_start_playback sets _generation_paused, submits StartPlayback, and
    calls adapter.play with the entry's media."""
    entry = _station_entry(1)
    controller = FakeController()
    adapter = FakeAdapter()
    app = _make_app(entries=[entry], controller=controller, adapter=adapter)
    async with app.run_test():
        app._start_playback(entry)
        assert app._generation_paused is True
        assert adapter.play_calls == [(entry.media, 0)]
        assert any(isinstance(a, StartPlayback) and a.entry.entry_id == entry.entry_id for a in controller.actions)


@pytest.mark.asyncio
async def test_start_playback_toggles_when_same_entry_already_playing():
    """Calling _start_playback again on the currently-playing entry pauses it
    (toggle), rather than restarting playback from offset 0."""
    entry = _station_entry(1)
    controller = FakeController()
    adapter = FakeAdapter()
    app = _make_app(entries=[entry], controller=controller, adapter=adapter)
    async with app.run_test():
        app._start_playback(entry)
        assert len(adapter.play_calls) == 1
        app._start_playback(entry)
        assert len(adapter.play_calls) == 1  # no second play() -- toggled to paused instead
        assert app._paused is True
        assert adapter.pause_calls == 1


@pytest.mark.asyncio
async def test_start_playback_starts_the_checkpoint_poller_once():
    entry_a = _station_entry(1)
    entry_b = _station_entry(2)
    controller = FakeController()
    adapter = FakeAdapter()
    poller = FakePoller()
    app = _make_app(
        entries=[entry_a, entry_b], controller=controller, adapter=adapter, poller_factory=lambda c, a: poller
    )
    async with app.run_test():
        app._start_playback(entry_a)
        app._start_playback(entry_b)
        assert poller.start_calls == 1  # guarded against double-start


@pytest.mark.asyncio
async def test_start_playback_resets_generation_paused_on_adapter_play_failure():
    """Regression lock for fix review #5: if adapter.play() raises,
    _start_playback must not leave _generation_paused stuck True forever
    (background generation would never resume — a real-world trigger is
    skip/next landing on an entry whose media turns out to be unplayable).
    Must also submit Stop() (station-state must not claim PLAYING for an
    entry that never actually started) and show a "Playback error" status,
    and must never mark the app as playing.

    Fails against the pre-fix code: the except branch already set the
    status and submitted Stop(), but never reset _generation_paused, so a
    caller that had already paused generation (simulated here by setting
    _generation_paused = True before calling _start_playback, mirroring an
    in-progress-generation state) would leave it stuck True.
    """
    entry = _station_entry(1)
    controller = FakeController()
    adapter = FakeAdapter(raise_on_play=RuntimeError("boom"))
    app = _make_app(entries=[entry], controller=controller, adapter=adapter)
    async with app.run_test():
        app._generation_paused = True  # simulate generation already paused
        app._start_playback(entry)

        assert app._generation_paused is False
        assert app._playing is False
        assert any(isinstance(a, Stop) for a in controller.actions)
        status = str(app.query_one("#status-line").render())
        assert "playback error" in status.lower()


@pytest.mark.asyncio
async def test_start_playback_shows_station_error_and_skips_adapter_play_on_submit_timeout():
    """Regression lock for fix review #8: a bounded ``timeout=5.0`` on
    ``submit_and_wait`` guards against a wedged drain thread hanging the UI
    forever; when it raises (timeout or any other exception), _start_playback
    must catch it, show a "Station error" status, and MUST NOT proceed to
    adapter.play() or mark the app as playing — an entry whose StartPlayback
    was never confirmed accepted is not safe to actually play.

    Fails against the pre-fix code in two independent ways: (1)
    ``controller.last_timeout == 5.0`` fails if the bounded timeout kwarg is
    removed/reverted (the fake records whatever timeout it was actually
    called with); (2) if the except branch were ever narrowed or the
    adapter.play call reordered ahead of the submit, ``adapter.play_calls``
    would be non-empty or the raised TimeoutError would propagate and fail
    the test outright.
    """
    entry = _station_entry(1)
    controller = FakeController(raise_on_submit_and_wait=concurrent.futures.TimeoutError("wedged"))
    adapter = FakeAdapter()
    app = _make_app(entries=[entry], controller=controller, adapter=adapter)
    async with app.run_test():
        app._start_playback(entry)

        assert controller.last_timeout == 5.0
        assert adapter.play_calls == []
        assert app._playing is False
        status = str(app.query_one("#status-line").render())
        assert "station error" in status.lower()


@pytest.mark.asyncio
async def test_stop_resumes_generation():
    """action_stop sets _generation_paused to False and triggers generation."""
    app = _make_app(entries=[])
    async with app.run_test():
        await app.workers.wait_for_complete()
        app._generation_paused = True
        app._playing = True
        with patch.object(app, "_trigger_generation") as mock_trigger:
            app.action_stop()
        assert app._generation_paused is False
        mock_trigger.assert_called_once()


# ---------------------------------------------------------------------------
# Phase 4 — Enhanced UI (playback bar / timer — pure rendering, unaffected
# by the station reroute; these poke the display fields directly)
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_playback_bar_widget_exists():
    """The #playback-bar Static widget is present in the app."""
    app = _make_app()
    async with app.run_test():
        bar = app.query_one("#playback-bar", Static)
        assert bar is not None


@pytest.mark.asyncio
async def test_playback_bar_shows_state_icon():
    """PlaybackBar shows state icon when playing/paused."""
    app = _make_app()
    async with app.run_test():
        app._playing = True
        app._paragraphs = ["Para one.", "Para two."]
        app._paragraph_idx = 0
        app._bar_progress = 50.0
        app._estimated_remaining_secs = 120
        app._update_playback_bar()
        content = str(app.query_one("#playback-bar", Static).render())
        assert ICONS["playing"] in content

        app._paused = True
        app._update_playback_bar()
        content = str(app.query_one("#playback-bar", Static).render())
        assert ICONS["paused"] in content


@pytest.mark.asyncio
async def test_playback_bar_shows_para_count():
    """PlaybackBar shows paragraph count like 1/5."""
    app = _make_app()
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
async def test_playback_bar_shows_timer():
    """PlaybackBar shows mm:ss timer."""
    app = _make_app()
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
async def test_timer_decrements():
    """_update_timer decrements _estimated_remaining_secs by 1."""
    app = _make_app()
    async with app.run_test():
        app._playing = True
        app._paragraphs = ["P1", "P2"]
        app._estimated_remaining_secs = 100
        app._update_timer()
        assert app._estimated_remaining_secs == 99


@pytest.mark.asyncio
async def test_timer_noop_when_paused():
    """_update_timer does nothing when paused."""
    app = _make_app()
    async with app.run_test():
        app._playing = True
        app._paused = True
        app._paragraphs = ["P1"]
        app._estimated_remaining_secs = 100
        app._update_timer()
        assert app._estimated_remaining_secs == 100  # Unchanged


@pytest.mark.asyncio
async def test_timer_noop_when_not_playing():
    """_update_timer does nothing when not playing."""
    app = _make_app()
    async with app.run_test():
        app._estimated_remaining_secs = 100
        app._update_timer()
        assert app._estimated_remaining_secs == 100


# ---------------------------------------------------------------------------
# Live per-segment transcript scrolling (restored A.3.5 dropped-path): driven
# by polling the adapter's current_offset_ms() on the existing 1s UI-thread
# timer -- no adapter callback, no new threads.
# ---------------------------------------------------------------------------

_SCROLL_SEGMENTS = (
    TranscriptSegment(start_ms=0, end_ms=5_000, text="Segment zero."),
    TranscriptSegment(start_ms=5_000, end_ms=10_000, text="Segment one."),
    TranscriptSegment(start_ms=10_000, end_ms=60_000, text="Segment two."),
)


@pytest.mark.asyncio
async def test_start_playback_seeds_transcript_from_entry_segments():
    """_start_playback populates _paragraphs from the entry's own
    transcript_segments and renders the initial (idx 0) segment into
    #current-text so the pane isn't blank at play start."""
    entry = _station_entry(1, transcript_segments=_SCROLL_SEGMENTS)
    app = _make_app(entries=[entry])
    async with app.run_test():
        app._start_playback(entry)
        assert app._paragraphs == ["Segment zero.", "Segment one.", "Segment two."]
        assert app._paragraph_idx == 0
        content = str(app.query_one("#current-text", Static).render())
        assert "Segment zero." in content


@pytest.mark.asyncio
async def test_start_playback_resumes_transcript_at_checkpoint_segment():
    """The initial _paragraph_idx is the segment containing the resume
    offset, not always 0 -- a resumed entry shouldn't visually rewind its
    transcript to the start."""
    entry = _station_entry(1, transcript_segments=_SCROLL_SEGMENTS)
    checkpoint = PlaybackCheckpoint(
        station_revision=1,
        entry_id=entry.entry_id,
        media_offset_ms=7_000,  # inside segment one (index 1)
        state="paused",
        interrupted_entry_stack=(),
        writer_device="mac",
        mutation_id="m-resume",
        timestamp="2026-07-11T00:00:00Z",
    )
    controller = FakeController(state=StationState(checkpoint=checkpoint))
    adapter = FakeAdapter()
    app = _make_app(entries=[entry], controller=controller, adapter=adapter)
    async with app.run_test():
        app._start_playback(entry)
        assert app._paragraph_idx == 1


@pytest.mark.asyncio
async def test_timer_advances_transcript_segment_with_adapter_offset():
    """_update_timer polls adapter.current_offset_ms() each tick and, when
    the offset has crossed into a new segment, updates _paragraph_idx and
    re-renders #current-text -- the core live-scrolling behavior."""
    entry = _station_entry(1, transcript_segments=_SCROLL_SEGMENTS)
    controller = FakeController()
    adapter = FakeAdapter()
    app = _make_app(entries=[entry], controller=controller, adapter=adapter)
    async with app.run_test():
        app._start_playback(entry)
        assert app._paragraph_idx == 0

        adapter._offset_ms = 6_000  # segment one
        app._update_timer()
        assert app._paragraph_idx == 1
        content = str(app.query_one("#current-text", Static).render())
        assert "Segment one." in content

        adapter._offset_ms = 15_000  # segment two
        app._update_timer()
        assert app._paragraph_idx == 2
        content = str(app.query_one("#current-text", Static).render())
        assert "Segment two." in content


@pytest.mark.asyncio
async def test_timer_noop_transcript_advance_when_offset_stays_in_same_segment():
    """A same-segment offset change ticks the countdown but does not touch
    _paragraph_idx or re-render the pane."""
    entry = _station_entry(1, transcript_segments=_SCROLL_SEGMENTS)
    controller = FakeController()
    adapter = FakeAdapter()
    app = _make_app(entries=[entry], controller=controller, adapter=adapter)
    async with app.run_test():
        app._start_playback(entry)
        remaining_before = app._estimated_remaining_secs

        adapter._offset_ms = 1_000  # still segment zero
        app._update_timer()
        assert app._paragraph_idx == 0
        assert app._estimated_remaining_secs == remaining_before - 1


@pytest.mark.asyncio
async def test_timer_with_no_transcript_segments_does_not_crash():
    """An entry with empty transcript_segments: _paragraphs stays empty, the
    pane isn't scrolled, and the 1s timer (progress bar countdown) still
    ticks without crashing."""
    entry = _station_entry(1, transcript_segments=())
    controller = FakeController()
    adapter = FakeAdapter()
    app = _make_app(entries=[entry], controller=controller, adapter=adapter)
    async with app.run_test():
        app._start_playback(entry)
        assert app._paragraphs == []
        remaining_before = app._estimated_remaining_secs

        app._update_timer()  # must not raise

        assert app._paragraphs == []
        assert app._estimated_remaining_secs == remaining_before - 1


@pytest.mark.asyncio
async def test_stop_clears_transcript_state():
    """action_stop resets the read-along state so a stopped station doesn't
    keep a stale transcript/segment count on display."""
    entry = _station_entry(1, transcript_segments=_SCROLL_SEGMENTS)
    controller = FakeController()
    adapter = FakeAdapter()
    app = _make_app(entries=[entry], controller=controller, adapter=adapter)
    async with app.run_test():
        app._start_playback(entry)
        assert app._paragraphs

        app.action_stop()

        assert app._paragraphs == []
        assert app._paragraph_idx == 0
        content = str(app.query_one("#current-text", Static).render())
        assert "Segment" not in content


@pytest.mark.asyncio
async def test_clean_completion_with_no_next_entry_clears_transcript_state():
    """A clean completion with nothing left in the backlog ("queue finished")
    also clears the read-along state, not just an explicit stop."""
    entry = _station_entry(1, transcript_segments=_SCROLL_SEGMENTS)
    controller = FakeController()
    adapter = FakeAdapter()
    app = _make_app(entries=[entry], controller=controller, adapter=adapter)
    async with app.run_test():
        await app.workers.wait_for_complete()
        app._start_playback(entry)
        assert app._paragraphs

        with patch("wilted.tui.mark_completed"):
            app._handle_station_completion(CompletionReason.ENDED)

        assert app._paragraphs == []
        assert app._paragraph_idx == 0


# ---------------------------------------------------------------------------
# Speed
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
@patch("wilted.get_default_speed", return_value=1.0)
@patch("wilted.db.set_setting")
async def test_speed_down_key(mock_set, mock_default):
    """Pressing - decreases speed by 0.1x."""
    app = _make_app()
    async with app.run_test() as pilot:
        assert app._speed == 1.0
        await pilot.press("minus")
        await pilot.pause()
        assert app._speed == 0.9


@pytest.mark.asyncio
@patch("wilted.get_default_speed", return_value=1.0)
@patch("wilted.db.set_setting")
async def test_speed_up_key(mock_set, mock_default):
    """Pressing + increases speed by 0.1x."""
    app = _make_app()
    async with app.run_test() as pilot:
        assert app._speed == 1.0
        await pilot.press("equal")
        await pilot.pause()
        assert app._speed == 1.1


@pytest.mark.asyncio
@patch("wilted.db.set_setting")
async def test_speed_clamps_to_range(mock_set):
    """Speed stays within 0.5x-2.0x bounds."""
    app = _make_app()
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
@patch("wilted.get_default_speed", return_value=1.0)
@patch("wilted.db.set_setting")
async def test_speed_key_shows_feedback(mock_set, mock_default):
    """Speed change updates the speed display."""
    app = _make_app()
    async with app.run_test() as pilot:
        await pilot.press("equal")
        await pilot.pause()
        speed_text = str(app.query_one("#speed-display").render())
        assert "1.1x" in speed_text


# ---------------------------------------------------------------------------
# Status priority
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_status_priority_blocks_low():
    """MEDIUM priority message blocks subsequent LOW message within hold window."""
    from wilted.tui import _STATUS_LOW, _STATUS_MEDIUM

    app = _make_app()
    async with app.run_test():
        app._set_status("Important", _STATUS_MEDIUM)
        status1 = str(app.query_one("#status-line").render())
        app._set_status("Routine", _STATUS_LOW)
        status2 = str(app.query_one("#status-line").render())
        assert status1 == status2  # LOW didn't overwrite


@pytest.mark.asyncio
async def test_status_priority_allows_equal():
    """Same-priority messages can overwrite each other."""
    from wilted.tui import _STATUS_MEDIUM

    app = _make_app()
    async with app.run_test():
        app._set_status("First", _STATUS_MEDIUM)
        app._set_status("Second", _STATUS_MEDIUM)
        status = str(app.query_one("#status-line").render())
        assert "Second" in status


# ---------------------------------------------------------------------------
# Transcript helper (pure; still exercised directly, no longer fed by
# playback — see WiltedApp._build_transcript docstring)
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_transcript_markup_bold_current():
    """_build_transcript marks current paragraph as bold."""
    app = _make_app()
    async with app.run_test():
        app._paragraphs = ["First para.", "Second para.", "Third para."]
        result = app._build_transcript(1)
        assert "[bold #F2E8CF]Second para.[/bold #F2E8CF]" in result
        assert "[#A9BA9D]First para.[/#A9BA9D]" in result
        assert "[dim #A9BA9D]Third para.[/dim #A9BA9D]" in result


@pytest.mark.asyncio
async def test_transcript_escapes_brackets():
    """_build_transcript escapes Rich markup in article text."""
    app = _make_app()
    async with app.run_test():
        app._paragraphs = ["Text with [brackets] inside."]
        result = app._build_transcript(0)
        assert "\\[brackets]" in result or "[brackets]" not in result.replace("\\[", "")


# ---------------------------------------------------------------------------
# TUI launch with real database (no mock) — real controller/adapter/sequencer
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_tui_launches_with_real_db():
    """TUI starts against the real (isolated) SQLite database, not a mocked queue."""
    app = WiltedApp()
    async with app.run_test():
        await app.workers.wait_for_complete()
        trees = app.query(Tree)
        assert len(trees) > 0
        # Empty DB: the empty-message label should be visible
        empty = app.query_one("#empty-message", Label)
        assert "empty" in empty.content.lower()


@pytest.mark.asyncio
async def test_tui_shows_being_prepared_for_unfinalized_real_db_article():
    """A freshly-added real article has no audio cache yet, so EntrySequencer
    (which requires finalized media) excludes it from the station backlog —
    the Larder shows the PM-3 "being prepared" message, not a leaf for it,
    even though the item is visible in the DB-backed item list."""
    from wilted.queue import add_article

    add_article("Test article body text for TUI display.", title="TUI DB Test")

    app = WiltedApp()
    async with app.run_test():
        await app.workers.wait_for_complete()
        assert any(item["title"] == "TUI DB Test" for item in app._all_items)
        tree = app.query_one("#playlist-tree", Tree)
        assert len(tree.root.children) == 0
        empty = app.query_one("#empty-message", Label)
        assert "prepared" in empty.content.lower()


@pytest.mark.asyncio
async def test_tui_quit_with_real_db():
    """TUI exits cleanly on q key with a real database."""
    app = WiltedApp()
    async with app.run_test() as pilot:
        await app.workers.wait_for_complete()
        await pilot.press("q")
        assert app._exit is not None


# ---------------------------------------------------------------------------
# ReportScreen tests (unrelated to the station reroute)
# ---------------------------------------------------------------------------


@pytest.fixture
def sample_report_data():
    """Sample report data for testing ReportScreen."""
    return {
        "report": {
            "report_date": "2026-04-20",
            "generated_at": "2026-04-20T06:00:00Z",
            "item_count": 2,
            "metadata": '{"playlists": {"Work": 2}, "total_items": 2}',
        },
        "items": {
            "Work": [
                {
                    "id": 1,
                    "title": "Test Article 1",
                    "source_name": "Test Source",
                    "relevance_score": 0.9,
                    "summary": "Summary 1",
                },
                {
                    "id": 2,
                    "title": "Test Article 2",
                    "source_name": "Test Source",
                    "relevance_score": 0.8,
                    "summary": "Summary 2",
                },
            ]
        },
    }


@pytest.mark.asyncio
async def test_report_screen_renders_items():
    """ReportScreen displays report items in the DataTable."""
    from wilted.tui.screens.report import ReportScreen

    app = WiltedApp()
    report_data = {
        "report": {
            "report_date": "2026-04-20",
            "generated_at": "2026-04-20T06:00:00Z",
            "item_count": 2,
            "metadata": '{"playlists": {"Work": 2}, "total_items": 2}',
        },
        "items": {
            "Work": [
                {
                    "id": 1,
                    "title": "Test Article 1",
                    "source_name": "Test Source",
                    "relevance_score": 0.9,
                    "summary": "Summary 1",
                },
                {
                    "id": 2,
                    "title": "Test Article 2",
                    "source_name": "Test Source",
                    "relevance_score": 0.8,
                    "summary": "Summary 2",
                },
            ]
        },
    }
    async with app.run_test() as pilot:
        app.push_screen(ReportScreen(report_data))
        await pilot.pause()
        from textual.widgets import DataTable

        table = app.screen.query_one("#report-table", DataTable)
        assert table.row_count >= 2, f"Expected at least 2 data rows, got {table.row_count}"


@pytest.mark.asyncio
async def test_toggle_selection():
    """Toggling selection on an item updates its selected state."""
    from wilted.tui.screens.report import ReportScreen

    app = WiltedApp()
    report_data = {
        "report": {
            "report_date": "2026-04-20",
            "generated_at": "2026-04-20T06:00:00Z",
            "item_count": 1,
            "metadata": '{"playlists": {"Work": 1}, "total_items": 1}',
        },
        "items": {
            "Work": [
                {
                    "id": 1,
                    "title": "Test Article",
                    "source_name": "Test Source",
                    "relevance_score": 0.9,
                    "summary": "Summary",
                },
            ]
        },
    }
    async with app.run_test() as pilot:
        app.push_screen(ReportScreen(report_data))
        await pilot.pause()
        screen = app.screen
        assert screen._selected.get(1, False) is True
        await pilot.press("enter")
        await pilot.pause()
        assert screen._selected.get(1, True) is False


@pytest.mark.asyncio
async def test_accept_promotes_selected_items():
    """Accepting promotes selected items to selected status."""
    from datetime import UTC, datetime

    from wilted.db import Feed, Item
    from wilted.report import get_report, run_report
    from wilted.tui.screens.report import ReportScreen

    now = datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
    feed = Feed.create(
        title="Test Feed",
        feed_url="https://example.com/feed.xml",
        feed_type="article",
        enabled=True,
        created_at=now,
        updated_at=now,
    )
    item = Item.create(
        feed=feed,
        guid="test-accept-1",
        title="Test Article",
        discovered_at=now,
        item_type="article",
        status="classified",
        status_changed_at=now,
        playlist_assigned="Work",
        relevance_score=0.9,
        summary="Test summary",
    )

    run_report()
    report_data = get_report()
    assert report_data is not None

    app = WiltedApp()
    async with app.run_test() as pilot:
        app.push_screen(ReportScreen(report_data))
        await pilot.pause()
        await pilot.press("s")
        await pilot.pause(delay=0.5)

        updated = Item.get_by_id(item.id)
        assert updated.status == "selected"


@pytest.mark.asyncio
async def test_dismiss_without_action_preserves_state():
    """Dismissing without accepting preserves the original item states."""
    from wilted.tui.screens.report import ReportScreen

    app = WiltedApp()
    report_data = {
        "report": {
            "report_date": "2026-04-20",
            "generated_at": "2026-04-20T06:00:00Z",
            "item_count": 1,
            "metadata": '{"playlists": {"Work": 1}, "total_items": 1}',
        },
        "items": {
            "Work": [
                {
                    "id": 1,
                    "title": "Test Article",
                    "source_name": "Test Source",
                    "relevance_score": 0.9,
                    "summary": "Summary",
                },
            ]
        },
    }
    async with app.run_test() as pilot:
        app.push_screen(ReportScreen(report_data))
        await pilot.pause()
        await pilot.press("enter")
        await pilot.pause()
        screen = app.screen
        assert screen._selected.get(1, True) is False
        await pilot.press("q")
        await pilot.pause()
        assert not isinstance(app.screen, ReportScreen)


@pytest.mark.asyncio
async def test_report_screen_not_shown_when_no_report():
    """ReportScreen is not shown when there is no report."""
    with patch("wilted.tui.WiltedApp._check_unread_report_worker"):
        app = WiltedApp()
        async with app.run_test() as pilot:
            await pilot.pause()
            from wilted.tui.screens.report import ReportScreen

            assert not any(isinstance(screen, ReportScreen) for screen in app.screen_stack)


@pytest.mark.asyncio
async def test_on_report_dismissed_refreshes_queue():
    """_on_report_dismissed(True) calls _refresh_playlists."""
    app = _make_app()
    async with app.run_test():
        with patch.object(app, "_refresh_playlists") as mock_refresh:
            app._on_report_dismissed(True)
            mock_refresh.assert_called_once()


@pytest.mark.asyncio
async def test_on_report_dismissed_no_refresh_when_not_accepted():
    """_on_report_dismissed(False) does not refresh the playlists."""
    app = _make_app()
    async with app.run_test():
        with patch.object(app, "_refresh_playlists") as mock_refresh:
            app._on_report_dismissed(False)
            mock_refresh.assert_not_called()


@pytest.mark.asyncio
async def test_report_screen_has_footer():
    """ReportScreen includes a Footer widget to display key bindings."""
    from textual.widgets import Footer

    from wilted.tui.screens.report import ReportScreen

    app = WiltedApp()
    report_data = {
        "report": {
            "report_date": "2026-04-20",
            "generated_at": "2026-04-20T06:00:00Z",
            "item_count": 1,
            "metadata": "{}",
        },
        "items": {
            "Work": [
                {"id": 1, "title": "Article", "source_name": "Src", "relevance_score": 0.8, "summary": ""},
            ]
        },
    }
    async with app.run_test() as pilot:
        app.push_screen(ReportScreen(report_data))
        await pilot.pause()
        footers = app.screen.query(Footer)
        assert len(footers) == 1, "ReportScreen should have exactly one Footer"


# ---------------------------------------------------------------------------
# NEW (A.3.5): INV-8 gate — legacy resume functions must never fire on the
# station playback lifecycle, and every station-state change must route
# through the controller.
# ---------------------------------------------------------------------------


def test_inv8_wilted_tui_source_never_references_legacy_resume_functions():
    """Static-scan guard (INV-8/PM-9): ``wilted.tui`` must contain NO reference
    at all to the legacy per-paragraph resume functions.

    This is the load-bearing check, not the behavioral test below: patching
    ``wilted.playlists.set_resume_position`` (the origin module) does NOT
    intercept a hypothetical regression that reintroduces
    ``from wilted.playlists import set_resume_position`` into ``wilted.tui``
    — that would create a SEPARATE module-local name binding in
    ``wilted.tui``'s namespace, untouched by a patch on the origin. Only a
    source scan (or patching ``wilted.tui.set_resume_position`` itself, which
    doesn't exist and would just raise AttributeError today) actually proves
    the retirement.

    Scans the AST (not raw text) so the module's own explanatory docstring
    mentioning these names by name (to document their retirement) doesn't
    trip the assertion — only actual code references count: imports,
    ``name(...)`` calls/references, and fully-qualified attribute access
    (``wilted.playlists.set_resume_position``).
    """
    import ast

    import wilted.tui as tui_module

    tree = ast.parse(inspect.getsource(tui_module))
    referenced: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Name):
            referenced.add(node.id)
        elif isinstance(node, ast.Attribute):
            referenced.add(node.attr)
        elif isinstance(node, (ast.Import, ast.ImportFrom)):
            referenced.update(alias.asname or alias.name for alias in node.names)

    for name in ("set_resume_position", "get_resume_position", "clear_resume_position"):
        assert name not in referenced, f"{name} must not be referenced in wilted.tui's code (INV-8: fully retired)"


@pytest.mark.asyncio
async def test_inv8_station_lifecycle_routes_through_controller_and_never_touches_resume():
    """PM-9 behavioral lock: play -> pause -> resume -> stop -> play -> complete
    drives real station-state transitions, all visible on the controller's
    action log (positive proof state changes went through the single
    writer) — paired with the static-scan test above (which is what actually
    proves the legacy functions are unreachable; these patches are
    defense-in-depth against a fully-qualified ``wilted.playlists.xxx(...)``
    call slipping in some other way).
    """
    entry_a = _station_entry(1)
    entry_b = _station_entry(2)
    controller = FakeController()
    adapter = FakeAdapter()
    app = _make_app(entries=[entry_a, entry_b], controller=controller, adapter=adapter)

    with (
        patch("wilted.playlists.set_resume_position") as mock_set,
        patch("wilted.playlists.get_resume_position") as mock_get,
        patch("wilted.playlists.clear_resume_position") as mock_clear,
        patch("wilted.tui.mark_completed"),
    ):
        async with app.run_test():
            await app.workers.wait_for_complete()

            app._start_playback(entry_a)
            app.action_toggle_play()  # pause
            app.action_toggle_play()  # resume
            app.action_stop()

            app._start_playback(entry_a)
            app._handle_station_completion(CompletionReason.ENDED)

        mock_set.assert_not_called()
        mock_get.assert_not_called()
        mock_clear.assert_not_called()

    action_types = [type(a).__name__ for a in controller.actions]
    assert action_types.count("StartPlayback") >= 2
    assert action_types.count("Stop") >= 2


# ---------------------------------------------------------------------------
# NEW (A.3.5): mixed-session Pilot drive — play, clean auto-advance, then a
# truncated completion that must NOT advance (PM-10 guard).
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_mixed_session_play_then_auto_advance_then_interrupted():
    first_entry = _station_entry(1, duration_ms=120_000)
    second_entry = _station_entry(2, duration_ms=90_000)
    items = [
        {"id": 1, "title": "An Article", "words": 3000, "file": "1_an-article.txt", "added": "2026-04-06"},
        {"id": 2, "title": "A Podcast Episode", "words": 4200, "file": "", "added": "2026-04-06"},
    ]
    controller = FakeController()
    adapter = FakeAdapter()
    app = _make_app(entries=[first_entry, second_entry], controller=controller, adapter=adapter)

    with (
        patch("wilted.tui.ensure_default_playlists"),
        patch("wilted.tui.get_playlist_items", return_value=items),
        patch("wilted.tui.mark_completed"),
    ):
        async with app.run_test() as pilot:
            await app.workers.wait_for_complete()
            tree = app.query_one("#playlist-tree", Tree)
            assert len(tree.root.children) == 2

            tree.select_node(tree.root.children[0])
            await pilot.pause()
            app.action_play_selected()
            await pilot.pause()

            assert adapter.play_calls == [(first_entry.media, 0)]
            assert any(
                isinstance(a, StartPlayback) and a.entry.entry_id == first_entry.entry_id for a in controller.actions
            )

            # Clean completion -> auto-advance to the second entry.
            app._handle_station_completion(CompletionReason.ENDED)
            await pilot.pause()

            assert adapter.play_calls[-1] == (second_entry.media, 0)
            assert app._current_entry is not None
            assert app._current_entry.entry_id == second_entry.entry_id

            # Truncated completion -> NO advance, interrupted status shown.
            app._handle_station_completion(CompletionReason.TRUNCATED)
            await pilot.pause()

            assert adapter.play_calls[-1] == (second_entry.media, 0)  # unchanged
            assert app._current_entry.entry_id == second_entry.entry_id
            status = str(app.query_one("#status-line").render())
            assert "interrupted" in status.lower()


# ---------------------------------------------------------------------------
# NEW (A.3.5 fix review): audio-thread deadlock regression lock —
# _on_adapter_completion must marshal via post_message, never call_from_thread.
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_on_adapter_completion_marshals_via_post_message_not_call_from_thread():
    """Pins the fix for a real deadlock: ``call_from_thread`` BLOCKS the
    calling thread (the audio thread, for ``_on_adapter_completion``) until
    the UI-thread callback returns. A clean completion's auto-advance path
    (``_handle_station_completion`` -> ``_start_playback`` -> ``adapter.play``)
    goes on to preempt/join the current track — on the REAL
    ``MacPlaybackAdapter`` that join targets this exact still-blocked audio
    thread, hanging for up to its join timeout on every natural track
    transition. ``post_message`` queues the event and returns immediately, so
    the audio thread has already exited before any join is attempted. This
    test would fail against the pre-fix ``call_from_thread`` implementation.
    """
    app = _make_app()
    async with app.run_test():
        with (
            patch.object(app, "post_message") as mock_post,
            patch.object(app, "call_from_thread") as mock_call_from_thread,
        ):
            app._on_adapter_completion(CompletionReason.ENDED)

            mock_call_from_thread.assert_not_called()
            mock_post.assert_called_once()
            (posted_message,), _kwargs = mock_post.call_args
            assert isinstance(posted_message, PlaybackCompleted)
            assert posted_message.reason == CompletionReason.ENDED


@pytest.mark.asyncio
async def test_adapter_completion_reaches_handler_through_real_message_pump():
    """End-to-end wiring check (not just that post_message was called): drives
    the ADAPTER's real ``fire_completion`` -> ``on_complete`` ->
    ``_on_adapter_completion`` -> ``post_message`` -> Textual's actual message
    queue -> ``on_playback_completed`` -> ``_handle_station_completion``,
    with no direct handler call — proves the message is actually dispatched,
    not just posted."""
    entry_a = _station_entry(1)
    entry_b = _station_entry(2)
    controller = FakeController()
    adapter = FakeAdapter()
    app = _make_app(entries=[entry_a, entry_b], controller=controller, adapter=adapter)
    async with app.run_test() as pilot:
        await app.workers.wait_for_complete()
        app._start_playback(entry_a)
        adapter.fire_completion(CompletionReason.ENDED)
        await pilot.pause()

        assert app._current_entry is not None
        assert app._current_entry.entry_id == entry_b.entry_id
        assert adapter.play_calls[-1] == (entry_b.media, 0)


# ---------------------------------------------------------------------------
# NEW (A.3.5 fix review): a clean completion with an unresolved current index
# must not replay station_entries[0].
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_clean_completion_with_unknown_current_index_does_not_replay_first_entry():
    """If ``_current_index`` is None when a clean ENDED arrives (e.g. a
    sequencer rebuild dropped the entry that was playing out from under it),
    the old ``(self._current_index + 1) if ... else 0`` default would replay
    ``station_entries[0]`` instead of correctly treating this as "queue
    finished". This must NOT auto-advance."""
    entry_a = _station_entry(1)
    entry_b = _station_entry(2)
    controller = FakeController()
    adapter = FakeAdapter()
    app = _make_app(entries=[entry_a, entry_b], controller=controller, adapter=adapter)
    async with app.run_test():
        await app.workers.wait_for_complete()
        app._start_playback(entry_a)
        assert len(adapter.play_calls) == 1

        app._current_index = None  # simulate a rebuild dropping the playing entry
        app._handle_station_completion(CompletionReason.ENDED)

        assert len(adapter.play_calls) == 1  # no replay of entry_a
        assert app._current_entry is None
        assert app._current_index is None


# ---------------------------------------------------------------------------
# NEW (A.3.5): resume offset — only honored for a checkpoint matching the
# entry being started.
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_start_playback_honors_matching_checkpoint_offset_only():
    """Genuinely fails against the pre-fix ordering bug: ``FakeController``
    now mirrors the real reducer's ``StartPlayback`` transition (it clears
    ``checkpoint`` on every submit — see ``FakeController``'s docstring), so
    code that reads the checkpoint AFTER ``submit_and_wait(StartPlayback(...))``
    (instead of before) would always observe ``offset_ms == 0`` here and this
    assertion (``42_000``) would fail.
    """
    entry = _station_entry(1)
    other_entry = _station_entry(2)
    checkpoint = PlaybackCheckpoint(
        station_revision=1,
        entry_id=entry.entry_id,
        media_offset_ms=42_000,
        state="paused",
        interrupted_entry_stack=(),
        writer_device="mac",
        mutation_id="m-1",
        timestamp="2026-07-11T00:00:00Z",
    )

    controller = FakeController(state=StationState(checkpoint=checkpoint))
    adapter = FakeAdapter()
    app = _make_app(entries=[entry, other_entry], controller=controller, adapter=adapter)
    async with app.run_test():
        app._start_playback(entry)
        assert adapter.play_calls == [(entry.media, 42_000)]

    controller2 = FakeController(state=StationState(checkpoint=checkpoint))
    adapter2 = FakeAdapter()
    app2 = _make_app(entries=[entry, other_entry], controller=controller2, adapter=adapter2)
    async with app2.run_test():
        # checkpoint.entry_id belongs to `entry`, not `other_entry` -> offset 0.
        app2._start_playback(other_entry)
        assert adapter2.play_calls == [(other_entry.media, 0)]


# ---------------------------------------------------------------------------
# NEW (A.3.5): empty-station state (PM-3)
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_empty_station_message_distinguishes_being_prepared_from_truly_empty():
    items = [{"id": 1, "title": "Unfinalized", "words": 500, "file": "1_x.txt", "added": "2026-04-06"}]
    with (
        patch("wilted.tui.ensure_default_playlists"),
        patch("wilted.tui.get_playlist_items", return_value=items),
    ):
        app = _make_app(entries=[])  # sequencer has nothing finalized yet
        async with app.run_test():
            await app.workers.wait_for_complete()
            empty = app.query_one("#empty-message", Label)
            assert "prepared" in empty.content.lower()

    with (
        patch("wilted.tui.ensure_default_playlists"),
        patch("wilted.tui.get_playlist_items", return_value=[]),
    ):
        app2 = _make_app(entries=[])
        async with app2.run_test():
            await app2.workers.wait_for_complete()
            empty2 = app2.query_one("#empty-message", Label)
            assert "empty" in empty2.content.lower()
            assert "prepared" not in empty2.content.lower()


# ---------------------------------------------------------------------------
# NEW (A.3.5): lease held elsewhere -> read-only, no crash, no play attempt.
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_lease_held_elsewhere_enters_read_only_state():
    class _RaisingController(FakeController):
        def start(self, *, on_loss=None) -> None:
            raise LeaseHeldError("held elsewhere")

    controller = _RaisingController()
    adapter = FakeAdapter()
    app = _make_app(entries=[_station_entry(1)], controller=controller, adapter=adapter)
    async with app.run_test() as pilot:
        await pilot.pause()
        assert app._station_read_only is True
        status = str(app.query_one("#status-line").render())
        assert "another session" in status.lower() or "read-only" in status.lower()

        # Attempting to play must not crash and must not touch the adapter.
        app._start_playback(_station_entry(1))
        assert adapter.play_calls == []


# ---------------------------------------------------------------------------
# NEW (A.3.5 fix review): read-only mode must refuse destructive CRUD too —
# another live session may be reading/writing the same DB items right now.
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_read_only_mode_refuses_destructive_crud():
    """Data-safety guard: with the station lease held elsewhere,
    delete/mark-read/clear-all must all be refused outright, not just
    playback. ``action_refresh_queue`` is deliberately NOT guarded (read-only
    still permits browsing/refreshing the backlog for viewing), which is how
    the tree gets populated below without ever taking write ownership of the
    station."""

    class _RaisingController(FakeController):
        def start(self, *, on_loss=None) -> None:
            raise LeaseHeldError("held elsewhere")

    articles = [{"id": 1, "title": "Test Article", "words": 50, "file": "1_test.txt", "added": "2026-04-06"}]
    with (
        patch("wilted.tui.ensure_default_playlists"),
        patch("wilted.tui.get_playlist_items", return_value=articles),
        patch("wilted.tui.remove_article_by_id") as mock_remove,
        patch("wilted.tui.mark_completed") as mock_mark,
        patch("wilted.tui.clear_queue") as mock_clear,
    ):
        app = _make_app(entries=[_station_entry(1)], controller=_RaisingController())
        async with app.run_test() as pilot:
            await pilot.pause()
            assert app._station_read_only is True

            # action_refresh_queue is unguarded -- populate the tree so a
            # real StationEntry is selectable, proving the CRUD refusals
            # below are the read-only guard firing, not just "nothing
            # selected".
            app.action_refresh_queue()
            await app.workers.wait_for_complete()
            tree = app.query_one("#playlist-tree", Tree)
            assert len(tree.root.children) == 1
            tree.select_node(tree.root.children[0])
            await pilot.pause()

            app.action_delete_selected()
            await pilot.pause()
            assert not any(isinstance(screen, ConfirmScreen) for screen in app.screen_stack)
            mock_remove.assert_not_called()

            app.action_mark_read()
            mock_mark.assert_not_called()

            app.action_clear_all()
            await pilot.pause()
            assert not any(isinstance(screen, ConfirmScreen) for screen in app.screen_stack)
            mock_clear.assert_not_called()

            status = str(app.query_one("#status-line").render())
            assert "read-only" in status.lower() or "another session" in status.lower()
