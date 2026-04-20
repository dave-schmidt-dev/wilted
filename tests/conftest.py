"""Shared test fixtures for wilted."""

import importlib
import sys
import types
from unittest.mock import MagicMock, patch

import pytest

import wilted

_TEST_MARKERS = {
    "test_ads.py": ("unit",),
    "test_cache.py": ("integration",),
    "test_classify.py": ("unit",),
    "test_cli.py": ("integration",),
    "test_db.py": ("integration",),
    "test_discover.py": ("integration",),
    "test_download.py": ("integration",),
    "test_e2e.py": ("e2e",),
    "test_edge_cases.py": ("integration",),
    "test_engine.py": ("unit",),
    "test_feeds.py": ("integration",),
    "test_fetch.py": ("unit",),
    "test_ingest.py": ("unit",),
    "test_llm.py": ("unit",),
    "test_onboard.py": ("unit",),
    "test_playlists.py": ("integration",),
    "test_resume.py": ("integration",),
    "test_preferences.py": ("integration",),
    "test_prepare.py": ("integration",),
    "test_queue.py": ("integration",),
    "test_report.py": ("integration",),
    "test_text.py": ("unit",),
    "test_transcribe.py": ("unit",),
    "test_tui.py": ("tui",),
}


def _fake_package(name: str) -> types.ModuleType:
    """Return a minimal package-like module for sys.modules patching."""
    module = types.ModuleType(name)
    module.__path__ = []  # type: ignore[attr-defined]
    return module


@pytest.fixture(autouse=True)
def _no_preload_model():
    """Prevent TUI tests from loading the real TTS model."""
    try:
        importlib.import_module("wilted.tui")
    except ImportError:
        yield
        return

    with patch("wilted.tui.WiltedApp._preload_model"):
        yield


@pytest.fixture(autouse=True)
def isolated_data(tmp_path, monkeypatch):
    """Redirect all data paths to a temp directory for every test."""
    data_dir = tmp_path / "data"
    articles_dir = data_dir / "articles"
    audio_dir = data_dir / "audio"
    articles_dir.mkdir(parents=True)
    audio_dir.mkdir(parents=True)

    monkeypatch.setattr(wilted, "DATA_DIR", data_dir)
    monkeypatch.setattr(wilted, "QUEUE_FILE", data_dir / "queue.json")
    monkeypatch.setattr(wilted, "ARTICLES_DIR", articles_dir)
    monkeypatch.setattr(wilted, "AUDIO_DIR", audio_dir)

    from wilted import cache as cache_mod
    from wilted.db import reset_db, run_migrations

    monkeypatch.setattr(cache_mod, "AUDIO_DIR", audio_dir)

    # Give each test a fresh, isolated SQLite database.
    reset_db()
    run_migrations(data_dir / "wilted.db")

    yield

    reset_db()  # Close file handles so tmp_path cleanup succeeds on Windows


@pytest.fixture
def stub_audio_modules():
    """Provide fake sounddevice/mlx_audio modules for tests that patch them.

    This keeps collection-time imports from poisoning unrelated tests while
    still allowing module-level patch targets such as ``sounddevice`` and
    ``mlx_audio.audio_io`` to resolve inside unit tests.
    """
    fake_sounddevice = types.ModuleType("sounddevice")
    fake_sounddevice.OutputStream = MagicMock()
    fake_sounddevice.PortAudioError = OSError

    fake_mlx_audio = _fake_package("mlx_audio")
    fake_mlx_audio_tts = _fake_package("mlx_audio.tts")
    fake_tts_utils = types.ModuleType("mlx_audio.tts.utils")
    fake_tts_utils.load_model = MagicMock()
    fake_audio_io = types.ModuleType("mlx_audio.audio_io")
    fake_audio_io.write = lambda *args, **kwargs: None
    fake_audio_io.read = MagicMock()

    fake_mlx_audio.tts = fake_mlx_audio_tts
    fake_mlx_audio.audio_io = fake_audio_io
    fake_mlx_audio_tts.utils = fake_tts_utils

    with patch.dict(
        sys.modules,
        {
            "sounddevice": fake_sounddevice,
            "mlx_audio": fake_mlx_audio,
            "mlx_audio.tts": fake_mlx_audio_tts,
            "mlx_audio.tts.utils": fake_tts_utils,
            "mlx_audio.audio_io": fake_audio_io,
        },
    ):
        yield


@pytest.fixture
def stub_trafilatura_module():
    """Provide a fake trafilatura module for ingest tests."""
    fake_trafilatura = types.ModuleType("trafilatura")
    with patch.dict(sys.modules, {"trafilatura": fake_trafilatura}):
        yield


def pytest_collection_modifyitems(items: list[pytest.Item]) -> None:
    """Apply suite-tier markers centrally instead of scattering file edits."""
    for item in items:
        filename = item.path.name
        for marker in _TEST_MARKERS.get(filename, ()):
            item.add_marker(getattr(pytest.mark, marker))
