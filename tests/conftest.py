"""Shared test fixtures for lilt."""

import pytest

import lilt


@pytest.fixture(autouse=True)
def isolated_data(tmp_path, monkeypatch):
    """Redirect all data paths to a temp directory for every test."""
    data_dir = tmp_path / "data"
    articles_dir = data_dir / "articles"
    articles_dir.mkdir(parents=True)

    monkeypatch.setattr(lilt, "DATA_DIR", data_dir)
    monkeypatch.setattr(lilt, "QUEUE_FILE", data_dir / "queue.json")
    monkeypatch.setattr(lilt, "ARTICLES_DIR", articles_dir)
    monkeypatch.setattr(lilt, "STATE_FILE", data_dir / "state.json")

    from lilt import queue as queue_mod
    from lilt import state as state_mod

    monkeypatch.setattr(queue_mod, "QUEUE_FILE", data_dir / "queue.json")
    monkeypatch.setattr(queue_mod, "ARTICLES_DIR", articles_dir)
    monkeypatch.setattr(state_mod, "STATE_FILE", data_dir / "state.json")
