"""Edge case tests for wilted — corrupt data, missing files, concurrent access, engine errors."""

import importlib
import json
import os
import threading
from unittest.mock import patch

import numpy as np
import pytest

import wilted
from wilted.engine import AudioEngine
from wilted.queue import (
    add_article,
    clear_queue,
    get_article_text,
    load_queue,
    mark_completed,
    remove_article,
)

pytestmark = pytest.mark.usefixtures("stub_audio_modules")

# ---------------------------------------------------------------------------
# TestCorruptQueue
# ---------------------------------------------------------------------------


class TestCorruptQueue:
    """Verify load_queue() handles corrupt or unexpected queue file contents."""

    def test_corrupt_json_returns_empty(self):
        """Invalid JSON in the queue file should return an empty list."""
        wilted.QUEUE_FILE.write_text("{not valid json at all!!")
        assert load_queue() == []

    def test_empty_file_returns_empty(self):
        """A zero-byte queue file should return an empty list."""
        wilted.QUEUE_FILE.write_text("")
        assert load_queue() == []

    def test_non_list_json_returns_empty(self):
        """A JSON object (dict) instead of a list should return an empty list.

        After hardening, load_queue() validates the top-level type and returns []
        for non-list JSON.
        """
        wilted.QUEUE_FILE.write_text(json.dumps({"not": "a list"}))
        result = load_queue()
        assert result == []

    def test_non_list_json_types_return_empty(self):
        """Non-list JSON types (string, int, dict) should all return []."""
        for value in ['"just a string"', "42", '{"key": "val"}']:
            wilted.QUEUE_FILE.write_text(value)
            assert load_queue() == [], f"load_queue() should return [] for JSON: {value}"

    def test_corrupt_queue_does_not_break_add(self):
        """Adding an article when the queue file is corrupt should recover."""
        wilted.QUEUE_FILE.write_text("<<<garbage>>>")
        entry = add_article("Recovery test article.", title="Recovery")
        assert entry["id"] == 1
        assert load_queue() == [entry]

    def test_corrupt_queue_does_not_break_clear(self):
        """Clearing when the queue file is corrupt should not crash."""
        wilted.QUEUE_FILE.write_text("not json")
        count = clear_queue()
        assert count == 0


# ---------------------------------------------------------------------------
# TestMissingArticleFile
# ---------------------------------------------------------------------------


class TestMissingArticleFile:
    """Verify queue operations survive when cached article files are deleted."""

    def test_get_article_text_missing_file(self):
        """Add an article, delete its file, then get_article_text returns None."""
        entry = add_article("Some article text.", title="Vanishing")
        article_path = wilted.ARTICLES_DIR / entry["file"]
        assert article_path.exists()
        article_path.unlink()
        assert get_article_text(entry) is None

    def test_remove_article_missing_file(self):
        """remove_article should not crash when the cached file is already gone."""
        entry = add_article("Disappearing content.", title="Gone")
        article_path = wilted.ARTICLES_DIR / entry["file"]
        article_path.unlink()
        removed = remove_article(0)
        assert removed["title"] == "Gone"
        assert load_queue() == []

    def test_clear_queue_missing_files(self):
        """clear_queue should not crash when cached files are already deleted."""
        add_article("First article.", title="First")
        add_article("Second article.", title="Second")
        # Delete all cached files before clearing
        for f in wilted.ARTICLES_DIR.iterdir():
            f.unlink()
        count = clear_queue()
        assert count == 2
        assert load_queue() == []

    def test_mark_completed_missing_file(self):
        """mark_completed should not crash when the cached file is gone."""
        entry = add_article("Completed content.", title="Done")
        article_path = wilted.ARTICLES_DIR / entry["file"]
        article_path.unlink()
        mark_completed(entry)  # should not raise
        assert load_queue() == []


# ---------------------------------------------------------------------------
# TestConcurrentQueueAccess
# ---------------------------------------------------------------------------


class TestConcurrentQueueAccess:
    """Verify queue behavior under simulated concurrent access patterns."""

    def test_add_during_read(self):
        """Simulate CLI --add while queue is loaded: both entries should persist."""
        add_article("First article.", title="First")
        # Simulate reading the queue, then adding another article
        queue_snapshot = load_queue()
        assert len(queue_snapshot) == 1
        add_article("Second article.", title="Second")
        fresh_queue = load_queue()
        assert len(fresh_queue) == 2
        assert fresh_queue[0]["title"] == "First"
        assert fresh_queue[1]["title"] == "Second"

    def test_concurrent_adds_from_threads(self):
        """Two threads adding articles concurrently should not corrupt the file.

        NOTE: Without file locking, the final count may be 1 instead of 2 due to
        a race condition. This test documents the behavior — after hardening with
        file locks, both entries should survive.
        """
        barrier = threading.Barrier(2)
        results = [None, None]

        def add_in_thread(idx, text, title):
            barrier.wait()
            results[idx] = add_article(text, title=title)

        t1 = threading.Thread(target=add_in_thread, args=(0, "Thread one.", "T1"))
        t2 = threading.Thread(target=add_in_thread, args=(1, "Thread two.", "T2"))
        t1.start()
        t2.start()
        t1.join(timeout=5.0)
        t2.join(timeout=5.0)

        queue = load_queue()
        # The queue file should be valid JSON regardless of race outcome
        assert isinstance(queue, list)
        assert len(queue) >= 1  # At minimum, one write succeeded


# ---------------------------------------------------------------------------
# TestEngineErrorHandling
# ---------------------------------------------------------------------------


class TestEngineErrorHandling:
    """Verify AudioEngine handles errors in model loading and playback."""

    def test_audio_device_error(self):
        """sd.OutputStream raising an exception should propagate from _play_audio().

        After hardening, _play_audio() may wrap device errors in RuntimeError.
        Before hardening, the raw exception propagates. Either way, it should not
        silently swallow the error.
        """
        engine = AudioEngine()
        audio = np.zeros(4096, dtype=np.float32)

        with patch("sounddevice.OutputStream") as mock_cls:
            mock_cls.side_effect = OSError("No audio device found")
            with pytest.raises((OSError, RuntimeError)):
                engine._play_audio(audio)

    def test_generate_and_play_exists(self):
        """AudioEngine should have a generate_and_play method (used by TUI)."""
        engine = AudioEngine()
        assert hasattr(engine, "generate_and_play"), (
            "AudioEngine is missing generate_and_play — the TUI depends on this method"
        )


class TestLanguageConstants:
    """Verify LANGUAGES dict is complete and consistent with VOICES."""

    def test_all_voice_accents_have_language(self):
        """Every accent in VOICES should have a matching LANGUAGES entry."""
        from wilted import LANGUAGES, VOICES

        for voice_id, info in VOICES.items():
            accent = info["accent"]
            matching = [code for code, name in LANGUAGES.items() if accent in name]
            assert matching, f"Voice {voice_id} has accent '{accent}' with no matching LANGUAGES entry"

    def test_chinese_language_exists(self):
        """Chinese must be in LANGUAGES since Chinese voices exist."""
        from wilted import LANGUAGES

        assert "z" in LANGUAGES
        assert "Chinese" in LANGUAGES["z"]

    def test_wpm_estimate_is_positive(self):
        from wilted import WPM_ESTIMATE

        assert WPM_ESTIMATE > 0


# ---------------------------------------------------------------------------
# TestLangCodeIntegration
# ---------------------------------------------------------------------------



class TestWpmEstimateConsistency:
    """Verify no hardcoded 150 WPM literals remain in the codebase."""

    @staticmethod
    def _scan_for_hardcoded_150(path):
        """Scan a file for hardcoded 150 WPM literals, return violations."""
        import re

        content = path.read_text()
        lines = content.split("\n")
        violations = []
        for i, line in enumerate(lines, 1):
            stripped = line.strip()
            if stripped.startswith("#") or stripped.startswith('"') or stripped.startswith("'"):
                continue
            if re.search(r"/\s*\(?\s*150\s*[*)]", line):
                violations.append(f"Line {i}: {stripped}")
        return violations

    def test_no_hardcoded_150_in_tui(self):
        """wilted-tui should use WPM_ESTIMATE, not literal 150."""
        from pathlib import Path

        tui_init = Path(__file__).resolve().parent.parent / "src" / "wilted" / "tui" / "__init__.py"
        violations = self._scan_for_hardcoded_150(tui_init)
        assert not violations, "Hardcoded 150 WPM found in tui/__init__.py:\n" + "\n".join(violations)

    def test_no_hardcoded_150_in_cli(self):
        """wilted CLI module should use WPM_ESTIMATE, not literal 150."""
        from pathlib import Path

        cli_path = Path(__file__).resolve().parent.parent / "src" / "wilted" / "cli.py"
        violations = self._scan_for_hardcoded_150(cli_path)
        assert not violations, "Hardcoded 150 WPM found in cli.py:\n" + "\n".join(violations)


# ---------------------------------------------------------------------------
# TestProjectRootResolution
# ---------------------------------------------------------------------------


class TestProjectRootResolution:
    """Verify PROJECT_ROOT resolves correctly regardless of install type."""

    def test_project_root_contains_pyproject_toml(self):
        """PROJECT_ROOT should point to the directory containing pyproject.toml."""
        assert (wilted.PROJECT_ROOT / "pyproject.toml").exists(), (
            f"PROJECT_ROOT={wilted.PROJECT_ROOT} does not contain pyproject.toml"
        )

    def test_data_dir_default_is_under_project_root(self):
        """The default DATA_DIR (before fixture override) should be PROJECT_ROOT/data."""
        # The autouse isolated_data fixture patches DATA_DIR to a tmp path, so
        # we verify the source definition rather than the live patched value.
        from pathlib import Path

        init_path = Path(wilted.__file__)
        source = init_path.read_text()
        assert 'DATA_DIR = PROJECT_ROOT / "data"' in source

    def test_env_var_override(self, tmp_path):
        """WILTED_PROJECT_ROOT env var should override auto-detection."""
        original_root = wilted.PROJECT_ROOT
        try:
            with patch.dict("os.environ", {"WILTED_PROJECT_ROOT": str(tmp_path)}):
                importlib.reload(wilted)
                assert wilted.PROJECT_ROOT == tmp_path
        finally:
            with patch.dict("os.environ", {}, clear=False):
                os.environ.pop("WILTED_PROJECT_ROOT", None)
                importlib.reload(wilted)
            assert wilted.PROJECT_ROOT == original_root


# ---------------------------------------------------------------------------
# BUG-3 regression guard — editable install must resolve
# ---------------------------------------------------------------------------


class TestEditableInstallResolves:
    """Regression guard for BUG-3 (iCloud UF_HIDDEN flag breaking .pth files).

    The venv now lives at ~/.venvs/wilted (outside iCloud) so Python 3.13's
    site.py never encounters hidden .pth files.  These fast, in-process checks
    verify the package resolves correctly through the editable install path and
    that key public sub-modules are importable.  If the venv regresses (e.g.
    someone moves it back inside ~/Documents/), these tests catch it immediately
    without needing to run the real CLI entry point.
    """

    def test_wilted_package_importable(self):
        """``import wilted`` must succeed — basic editable-install health check."""
        import importlib

        mod = importlib.import_module("wilted")
        assert mod is not None

    def test_wilted_cli_module_importable(self):
        """wilted.cli must import cleanly; main entry point depends on it."""
        import importlib

        mod = importlib.import_module("wilted.cli")
        assert hasattr(mod, "main")

    def test_wilted_package_file_is_under_src(self):
        """__file__ for the installed package must point inside src/, not a wheel cache.

        If the UF_HIDDEN / venv relocation bug recurs and PYTHONPATH masking is
        removed, this test would catch a wrong resolution.
        """
        import pathlib

        pkg_file = pathlib.Path(wilted.__file__).resolve()
        assert "src" in pkg_file.parts, (
            f"wilted.__file__={pkg_file} is not under src/ — "
            "editable install may not be resolving correctly; check UV_PROJECT_ENVIRONMENT"
        )
