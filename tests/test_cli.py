"""Tests for wilted.cli — CLI commands and argument parsing."""

import argparse
import types
from unittest.mock import MagicMock, patch

import pytest

from wilted.cli import (
    CLIError,
    _play_text,
    cmd_add,
    cmd_clear,
    cmd_direct,
    cmd_list,
    cmd_next,
    cmd_play,
    cmd_remove,
    main,
    run_cli,
)
from wilted.queue import add_article, load_queue


def _make_args(**overrides):
    """Create an argparse.Namespace with sensible defaults."""
    defaults = {
        "input": None,
        "add": False,
        "list": False,
        "play": False,
        "next": False,
        "remove": None,
        "clear": False,
        "voice": "af_heart",
        "speed": 1.0,
        "model": "mlx-community/Kokoro-82M-bf16",
        "lang": "a",
        "save": None,
        "clean": False,
        "list_voices": False,
        "version": False,
    }
    defaults.update(overrides)
    return argparse.Namespace(**defaults)


def _add_test_article(text="Hello world. This is a test article.", title="Test Article"):
    """Helper to add a test article to the queue."""
    return add_article(text, title=title)


# ---------------------------------------------------------------------------
# cmd_add
# ---------------------------------------------------------------------------


class TestCmdAdd:
    def test_add_from_url(self, capsys):
        """cmd_add with URL input fetches and adds article."""
        from wilted.ingest import ArticleResult

        args = _make_args(input="https://example.com/article", add=True)
        fake_result = ArticleResult(
            text="Article body text here.",
            title="Example Article",
            source_url="https://example.com/article",
            canonical_url="https://example.com/article",
        )
        with patch("wilted.cli.resolve_article", return_value=fake_result):
            cmd_add(args)

        captured = capsys.readouterr()
        assert "Added #1" in captured.out
        assert "Queue now has 1 article" in captured.out
        assert load_queue()[0]["title"] == "Example Article"

    def test_add_from_clipboard(self, capsys):
        """cmd_add from clipboard when no URL given."""
        from wilted.ingest import ArticleResult

        args = _make_args(add=True)
        fake_result = ArticleResult(
            text="Clipboard article text here.",
            title=None,
            source_url=None,
            canonical_url=None,
        )
        with patch("wilted.cli.resolve_article", return_value=fake_result):
            cmd_add(args)

        captured = capsys.readouterr()
        assert "Added #1" in captured.out
        assert load_queue()[0]["words"] > 0

    def test_add_empty_clipboard_raises(self):
        """cmd_add raises CLIError when clipboard is empty."""
        args = _make_args(add=True)
        with (
            patch("wilted.cli.resolve_article", side_effect=ValueError("Clipboard is empty.")),
            pytest.raises(CLIError, match="Clipboard is empty"),
        ):
            cmd_add(args)

    def test_add_url_fetch_fails_raises(self):
        """cmd_add raises CLIError when URL fetch returns no text."""
        args = _make_args(input="https://example.com/paywall", add=True)
        with (
            patch("wilted.cli.resolve_article", side_effect=ValueError("Could not fetch article text")),
            pytest.raises(CLIError, match="Could not fetch"),
        ):
            cmd_add(args)


# ---------------------------------------------------------------------------
# cmd_list
# ---------------------------------------------------------------------------


class TestCmdList:
    def test_list_empty(self, capsys):
        """cmd_list shows empty message for empty queue."""
        cmd_list(_make_args())
        assert "empty" in capsys.readouterr().out.lower()

    def test_list_populated(self, capsys):
        """cmd_list shows articles with word counts and time estimates."""
        _add_test_article(text="Word " * 300, title="Long Article")
        _add_test_article(text="Short text.", title="Short Article")
        cmd_list(_make_args())

        out = capsys.readouterr().out
        assert "Long Article" in out
        assert "Short Article" in out
        assert "2 articles" in out
        assert "Total:" in out


# ---------------------------------------------------------------------------
# cmd_remove
# ---------------------------------------------------------------------------


class TestCmdRemove:
    def test_remove_valid(self, capsys):
        """cmd_remove removes article at given 1-based index."""
        _add_test_article(title="First")
        _add_test_article(title="Second")
        cmd_remove(_make_args(remove=1))

        out = capsys.readouterr().out
        assert "Removed: First" in out
        assert len(load_queue()) == 1

    def test_remove_invalid_raises(self):
        """cmd_remove raises CLIError for out-of-range index."""
        _add_test_article()
        with pytest.raises(CLIError, match="Invalid index"):
            cmd_remove(_make_args(remove=99))


# ---------------------------------------------------------------------------
# cmd_clear
# ---------------------------------------------------------------------------


class TestCmdClear:
    def test_clear_empty(self, capsys):
        """cmd_clear with empty queue shows appropriate message."""
        cmd_clear(_make_args())
        assert "already empty" in capsys.readouterr().out.lower()

    def test_clear_populated(self, capsys):
        """cmd_clear removes all articles."""
        _add_test_article()
        _add_test_article()
        cmd_clear(_make_args())

        assert "Cleared 2" in capsys.readouterr().out
        assert load_queue() == []


# ---------------------------------------------------------------------------
# cmd_play
# ---------------------------------------------------------------------------


class TestCmdPlay:
    def test_play_empty(self, capsys):
        """cmd_play with empty queue shows appropriate message."""
        args = _make_args(play=True)
        with patch("wilted.cli._play_text", return_value=True):
            cmd_play(args)
        assert "empty" in capsys.readouterr().out.lower()

    def test_play_articles(self, capsys):
        """cmd_play plays articles and marks them completed."""
        _add_test_article(title="Article One")
        _add_test_article(title="Article Two")
        args = _make_args(play=True)
        with patch("wilted.cli._play_text", return_value=True):
            cmd_play(args)

        out = capsys.readouterr().out
        assert "Article One" in out
        assert "Article Two" in out
        assert "Finished 2" in out
        assert load_queue() == []


# ---------------------------------------------------------------------------
# cmd_next
# ---------------------------------------------------------------------------


class TestCmdNext:
    def test_next_empty(self, capsys):
        """cmd_next with empty queue shows appropriate message."""
        cmd_next(_make_args())
        assert "empty" in capsys.readouterr().out.lower()

    def test_next_plays_first(self, capsys):
        """cmd_next plays the first article and marks it completed."""
        _add_test_article(title="First Article")
        _add_test_article(title="Second Article")
        args = _make_args()
        with patch("wilted.cli._play_text", return_value=True):
            cmd_next(args)

        out = capsys.readouterr().out
        assert "First Article" in out
        assert "1 article(s) remaining" in out
        assert len(load_queue()) == 1

    def test_next_missing_file_raises(self, tmp_path):
        """cmd_next raises CLIError when cached file is missing."""
        import wilted

        entry = _add_test_article(title="Missing File Article")
        # Delete the cached file
        article_path = wilted.ARTICLES_DIR / entry["file"]
        article_path.unlink()

        with pytest.raises(CLIError, match="Cached file missing"):
            cmd_next(_make_args())


# ---------------------------------------------------------------------------
# cmd_direct
# ---------------------------------------------------------------------------


class TestCmdDirect:
    def test_direct_url(self, capsys):
        """cmd_direct with URL input fetches and plays."""
        args = _make_args(input="https://example.com/test")
        with (
            patch("wilted.cli.get_text_from_url", return_value=("Test article text.", "https://example.com/test")),
            patch("wilted.cli._play_text", return_value=True),
        ):
            cmd_direct(args)

    def test_direct_file(self, tmp_path, capsys):
        """cmd_direct with file path reads and plays."""
        test_file = tmp_path / "article.txt"
        test_file.write_text("File article content here.")
        args = _make_args(input=str(test_file))
        with patch("wilted.cli._play_text", return_value=True):
            cmd_direct(args)

    def test_direct_clean(self, capsys):
        """cmd_direct with --clean prints cleaned text, no audio."""
        args = _make_args(input="https://example.com/test", clean=True)
        with patch("wilted.cli.get_text_from_url", return_value=("Raw text content.", "https://example.com/test")):
            cmd_direct(args)

        out = capsys.readouterr().out
        assert "Raw text content" in out

    def test_direct_no_text_raises(self):
        """cmd_direct raises CLIError when no text found."""
        args = _make_args()
        with (
            patch("wilted.cli.get_text_from_clipboard", return_value=""),
            patch("sys.stdin") as mock_stdin,
            pytest.raises(CLIError, match="No text found"),
        ):
            mock_stdin.isatty.return_value = True
            cmd_direct(args)


# ---------------------------------------------------------------------------
# _play_text
# ---------------------------------------------------------------------------


class TestPlayText:
    def test_playback_mode(self, capsys):
        """_play_text in playback mode uses AudioEngine.play_article."""
        args = _make_args()
        mock_engine = MagicMock()
        with patch("wilted.engine.AudioEngine", return_value=mock_engine):
            result = _play_text("Hello world test text.", args)

        assert result is True
        mock_engine.play_article.assert_called_once()
        assert "Done" in capsys.readouterr().out

    def test_save_mode(self, tmp_path, capsys):
        """_play_text in save mode generates audio and writes WAV."""
        import numpy as np

        save_path = str(tmp_path / "output.wav")
        args = _make_args(save=save_path)
        mock_engine = MagicMock()
        mock_engine.generate_audio.return_value = np.zeros(1024, dtype=np.float32)
        mock_engine.sample_rate = 24000

        with (
            patch("wilted.engine.AudioEngine", return_value=mock_engine),
            patch("mlx_audio.audio_io.write"),
        ):
            result = _play_text("Hello world test text.", args)

        assert result is True
        mock_engine.generate_audio.assert_called()
        assert "Saved" in capsys.readouterr().out

    def test_playback_keyboard_interrupt(self, capsys):
        """_play_text returns False on KeyboardInterrupt and calls stop."""
        args = _make_args()
        mock_engine = MagicMock()
        mock_engine.play_article.side_effect = KeyboardInterrupt
        with patch("wilted.engine.AudioEngine", return_value=mock_engine):
            result = _play_text("Hello world test text.", args)

        assert result is False
        mock_engine.stop.assert_called_once()
        assert "Stopped" in capsys.readouterr().out


# ---------------------------------------------------------------------------
# Argparse / run_cli dispatch
# ---------------------------------------------------------------------------


class TestArgparse:
    def test_list_voices(self, capsys):
        """--list-voices prints available voices."""
        run_cli(["--list-voices"])
        out = capsys.readouterr().out
        assert "af_heart" in out
        assert "American" in out

    def test_version(self, capsys):
        """--version prints version string."""
        run_cli(["--version"])
        out = capsys.readouterr().out
        assert "wilted" in out
        assert "0.2.0" in out

    def test_list_dispatch(self, capsys):
        """--list dispatches to cmd_list."""
        run_cli(["--list"])
        assert "empty" in capsys.readouterr().out.lower()

    def test_clear_dispatch(self, capsys):
        """--clear dispatches to cmd_clear."""
        run_cli(["--clear"])
        assert "empty" in capsys.readouterr().out.lower()

    def test_cli_error_exits(self):
        """CLIError is caught and converted to sys.exit(1)."""
        with (
            patch("wilted.cli.cmd_add", side_effect=CLIError("test error")),
            pytest.raises(SystemExit, match="1"),
        ):
            run_cli(["--add"])


# ---------------------------------------------------------------------------
# Phase 2 subcommand dispatch
# ---------------------------------------------------------------------------


class TestFeedSubcommand:
    def test_feed_add(self, capsys):
        """wilted feed add creates a feed."""
        run_cli(["feed", "add", "https://example.com/feed.xml", "--type", "article"])
        out = capsys.readouterr().out
        assert "Added feed #1" in out

    def test_feed_list_empty(self, capsys):
        """wilted feed list with no feeds."""
        run_cli(["feed", "list"])
        out = capsys.readouterr().out
        assert "No feeds" in out

    def test_feed_list_populated(self, capsys):
        """wilted feed list shows feeds."""
        run_cli(["feed", "add", "https://example.com/feed.xml"])
        run_cli(["feed", "list"])
        out = capsys.readouterr().out
        assert "example.com" in out

    def test_feed_remove(self, capsys):
        """wilted feed remove deletes a feed."""
        run_cli(["feed", "add", "https://example.com/feed.xml"])
        run_cli(["feed", "remove", "1"])
        out = capsys.readouterr().out
        assert "Removed feed #1" in out

    def test_feed_remove_nonexistent_exits(self):
        """wilted feed remove with bad ID exits 1."""
        with pytest.raises(SystemExit):
            run_cli(["feed", "remove", "999"])

    def test_feed_no_action_exits(self):
        """wilted feed with no action exits 1."""
        with pytest.raises(SystemExit):
            run_cli(["feed"])


class TestKeywordSubcommand:
    def test_keyword_add(self, capsys):
        """wilted keyword add creates a keyword."""
        run_cli(["keyword", "add", "kubernetes"])
        out = capsys.readouterr().out
        assert "Added keyword" in out
        assert "kubernetes" in out

    def test_keyword_add_with_weight(self, capsys):
        """wilted keyword add with --weight."""
        run_cli(["keyword", "add", "security", "--weight", "2.0"])
        out = capsys.readouterr().out
        assert "weight: 2.0" in out

    def test_keyword_list_empty(self, capsys):
        """wilted keyword list with no keywords."""
        run_cli(["keyword", "list"])
        out = capsys.readouterr().out
        assert "No keywords" in out

    def test_keyword_list_populated(self, capsys):
        """wilted keyword list shows keywords."""
        run_cli(["keyword", "add", "python"])
        run_cli(["keyword", "list"])
        out = capsys.readouterr().out
        assert "python" in out

    def test_keyword_remove(self, capsys):
        """wilted keyword remove deletes a keyword."""
        run_cli(["keyword", "add", "remove-me"])
        run_cli(["keyword", "remove", "remove-me"])
        out = capsys.readouterr().out
        assert "Removed keyword" in out

    def test_keyword_no_action_exits(self):
        """wilted keyword with no action exits 1."""
        with pytest.raises(SystemExit):
            run_cli(["keyword"])


class TestPipelineSubcommands:
    def test_discover_dispatch(self, monkeypatch, capsys):
        """wilted discover dispatches to run_discover."""
        monkeypatch.setattr(
            "wilted.discover.run_discover",
            lambda: {"discovered": 3, "feeds_polled": 2, "errors": 0},
        )
        run_cli(["discover"])
        out = capsys.readouterr().out
        assert "3 new items" in out

    def test_classify_dispatch(self, monkeypatch, capsys):
        """wilted classify dispatches to run_classify."""
        monkeypatch.setattr(
            "wilted.classify.run_classify",
            lambda: {"classified": 5, "errors": 0},
        )
        run_cli(["classify"])
        out = capsys.readouterr().out
        assert "5 items classified" in out

    def test_stub_subcmds_still_exit(self):
        """Remaining stub subcommands still exit 1."""
        with pytest.raises(SystemExit):
            run_cli(["report"])
        with pytest.raises(SystemExit):
            run_cli(["prepare"])


class TestMainEntrypoint:
    def test_main_cli_mode_dispatches_without_tqdm_preinit(self):
        """CLI mode should dispatch directly to run_cli."""
        with (
            patch("wilted.cli.run_cli") as mock_run_cli,
            patch("sys.argv", ["wilted", "--version"]),
        ):
            main()

        mock_run_cli.assert_called_once_with()

    def test_main_tui_mode_preinitializes_tqdm_lock(self):
        """TUI mode must initialize tqdm's lock before starting Textual."""
        mock_tqdm = MagicMock()
        mock_app = MagicMock()
        mock_app_cls = MagicMock(return_value=mock_app)

        with (
            patch("sys.argv", ["wilted"]),
            patch.dict(
                "sys.modules",
                {
                    "tqdm": types.SimpleNamespace(tqdm=mock_tqdm),
                    "wilted.tui": types.SimpleNamespace(WiltedApp=mock_app_cls),
                },
            ),
        ):
            main()

        mock_tqdm.get_lock.assert_called_once_with()
        mock_app_cls.assert_called_once_with()
        mock_app.run.assert_called_once_with()
