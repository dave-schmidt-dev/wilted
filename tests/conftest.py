"""Shared test fixtures for wilted."""

import importlib
from unittest.mock import patch

import pytest

import wilted


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
    monkeypatch.setattr(wilted, "STATE_FILE", data_dir / "state.json")
    monkeypatch.setattr(wilted, "AUDIO_DIR", audio_dir)

    from wilted import cache as cache_mod
    from wilted import queue as queue_mod
    from wilted import state as state_mod

    monkeypatch.setattr(cache_mod, "AUDIO_DIR", audio_dir)
    monkeypatch.setattr(queue_mod, "QUEUE_FILE", data_dir / "queue.json")
    monkeypatch.setattr(queue_mod, "ARTICLES_DIR", articles_dir)
    monkeypatch.setattr(state_mod, "STATE_FILE", data_dir / "state.json")
