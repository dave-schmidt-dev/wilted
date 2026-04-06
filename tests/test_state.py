"""Tests for lilt.state — resume position persistence."""

import json

import pytest

import lilt
from lilt.state import (
    clear_article_state,
    get_article_state,
    load_state,
    save_state,
    set_article_state,
)


@pytest.fixture(autouse=True)
def isolated_data(tmp_path, monkeypatch):
    """Redirect all data paths to a temp directory."""
    data_dir = tmp_path / "data"
    data_dir.mkdir(parents=True)

    monkeypatch.setattr(lilt, "DATA_DIR", data_dir)
    monkeypatch.setattr(lilt, "STATE_FILE", data_dir / "state.json")
    monkeypatch.setattr(lilt, "ARTICLES_DIR", data_dir / "articles")

    from lilt import state as state_mod

    monkeypatch.setattr(state_mod, "STATE_FILE", data_dir / "state.json")


class TestLoadSaveState:
    def test_empty_when_no_file(self):
        assert load_state() == {}

    def test_round_trip(self):
        state = {"1": {"paragraph_idx": 5, "segment_in_paragraph": 2}}
        save_state(state)
        assert load_state() == state

    def test_atomic_write_no_tmp_files(self):
        save_state({"1": {"paragraph_idx": 0}})
        tmp_files = list(lilt.DATA_DIR.glob("*.tmp"))
        assert tmp_files == []

    def test_corrupt_file_returns_empty(self):
        lilt.STATE_FILE.write_text("not valid json{{{")
        assert load_state() == {}


class TestGetArticleState:
    def test_returns_none_when_empty(self):
        assert get_article_state(1) is None

    def test_returns_saved_state(self):
        set_article_state(3, paragraph_idx=12, segment_in_paragraph=2)
        result = get_article_state(3)
        assert result["paragraph_idx"] == 12
        assert result["segment_in_paragraph"] == 2
        assert "updated" in result


class TestSetArticleState:
    def test_creates_new_entry(self):
        set_article_state(1, paragraph_idx=0)
        state = load_state()
        assert "1" in state
        assert state["1"]["paragraph_idx"] == 0
        assert state["1"]["segment_in_paragraph"] == 0

    def test_updates_existing_entry(self):
        set_article_state(1, paragraph_idx=0)
        set_article_state(1, paragraph_idx=5, segment_in_paragraph=3)
        result = get_article_state(1)
        assert result["paragraph_idx"] == 5
        assert result["segment_in_paragraph"] == 3

    def test_multiple_articles(self):
        set_article_state(1, paragraph_idx=10)
        set_article_state(2, paragraph_idx=20)
        assert get_article_state(1)["paragraph_idx"] == 10
        assert get_article_state(2)["paragraph_idx"] == 20


class TestClearArticleState:
    def test_removes_entry(self):
        set_article_state(1, paragraph_idx=5)
        clear_article_state(1)
        assert get_article_state(1) is None

    def test_leaves_other_entries(self):
        set_article_state(1, paragraph_idx=5)
        set_article_state(2, paragraph_idx=10)
        clear_article_state(1)
        assert get_article_state(1) is None
        assert get_article_state(2)["paragraph_idx"] == 10

    def test_noop_for_missing_entry(self):
        clear_article_state(999)  # should not raise
        assert load_state() == {}
