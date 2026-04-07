"""Tests for lilt.queue — reading list persistence and operations."""

import pytest

import lilt
from lilt.queue import (
    add_article,
    clear_queue,
    get_article_text,
    load_queue,
    mark_completed,
    remove_article,
    save_queue,
)


@pytest.fixture(autouse=True)
def isolated_data(tmp_path, monkeypatch):
    """Redirect all data paths to a temp directory."""
    data_dir = tmp_path / "data"
    articles_dir = data_dir / "articles"
    articles_dir.mkdir(parents=True)

    monkeypatch.setattr(lilt, "DATA_DIR", data_dir)
    monkeypatch.setattr(lilt, "QUEUE_FILE", data_dir / "queue.json")
    monkeypatch.setattr(lilt, "ARTICLES_DIR", articles_dir)

    # Also patch the module-level imports in queue.py
    from lilt import queue as queue_mod

    monkeypatch.setattr(queue_mod, "QUEUE_FILE", data_dir / "queue.json")
    monkeypatch.setattr(queue_mod, "ARTICLES_DIR", articles_dir)


class TestLoadSaveQueue:
    def test_empty_when_no_file(self):
        assert load_queue() == []

    def test_round_trip(self):
        entries = [{"id": 1, "title": "Test", "file": "test.txt"}]
        save_queue(entries)
        assert load_queue() == entries

    def test_atomic_write_creates_file(self, tmp_path):
        queue_file = lilt.QUEUE_FILE
        assert not queue_file.exists()
        save_queue([{"id": 1}])
        assert queue_file.exists()

    def test_atomic_write_no_partial(self, tmp_path):
        """Save should not leave .tmp files behind."""
        save_queue([{"id": 1}])
        tmp_files = list(lilt.DATA_DIR.glob("*.tmp"))
        assert tmp_files == []


class TestAddArticle:
    def test_adds_to_empty_queue(self):
        entry = add_article("Hello world article text.", title="Test Article")
        assert entry["id"] == 1
        assert entry["title"] == "Test Article"
        assert entry["words"] == 4
        assert load_queue() == [entry]

    def test_increments_id(self):
        add_article("First article.", title="First")
        entry2 = add_article("Second article.", title="Second")
        assert entry2["id"] == 2

    def test_saves_article_file(self):
        entry = add_article("Article content here.", title="My Article")
        article_path = lilt.ARTICLES_DIR / entry["file"]
        assert article_path.exists()
        assert article_path.read_text() == "Article content here."

    def test_default_title_from_first_line(self):
        entry = add_article("First line as title\nBody text here.")
        assert entry["title"] == "First line as title"

    def test_preserves_urls(self):
        entry = add_article(
            "Content.",
            title="Test",
            source_url="https://apple.news/abc",
            canonical_url="https://example.com/article",
        )
        assert entry["source_url"] == "https://apple.news/abc"
        assert entry["canonical_url"] == "https://example.com/article"


class TestRemoveArticle:
    def test_removes_by_index(self):
        add_article("First.", title="First")
        add_article("Second.", title="Second")
        removed = remove_article(0)
        assert removed["title"] == "First"
        assert len(load_queue()) == 1

    def test_deletes_cached_file(self):
        entry = add_article("Content.", title="Test")
        article_path = lilt.ARTICLES_DIR / entry["file"]
        assert article_path.exists()
        remove_article(0)
        assert not article_path.exists()

    def test_raises_on_invalid_index(self):
        with pytest.raises(IndexError):
            remove_article(0)

    def test_raises_on_negative_index(self):
        add_article("Content.", title="Test")
        with pytest.raises(IndexError):
            remove_article(-1)


class TestClearQueue:
    def test_clears_all(self):
        add_article("First.", title="First")
        add_article("Second.", title="Second")
        count = clear_queue()
        assert count == 2
        assert load_queue() == []

    def test_returns_zero_when_empty(self):
        assert clear_queue() == 0

    def test_deletes_cached_files(self):
        entry = add_article("Content.", title="Test")
        article_path = lilt.ARTICLES_DIR / entry["file"]
        clear_queue()
        assert not article_path.exists()


class TestGetArticleText:
    def test_reads_cached_text(self):
        entry = add_article("The full article text.", title="Test")
        assert get_article_text(entry) == "The full article text."

    def test_returns_none_for_missing_file(self):
        entry = {"file": "nonexistent.txt"}
        assert get_article_text(entry) is None


class TestMarkCompleted:
    def test_removes_from_queue(self):
        entry = add_article("Content.", title="Test")
        mark_completed(entry)
        assert load_queue() == []

    def test_deletes_cached_file(self):
        entry = add_article("Content.", title="Test")
        article_path = lilt.ARTICLES_DIR / entry["file"]
        mark_completed(entry)
        assert not article_path.exists()

    def test_leaves_other_entries(self):
        add_article("First.", title="First")
        add_article("Second.", title="Second")
        # Remove first (id=1)
        queue = load_queue()
        mark_completed(queue[0])
        remaining = load_queue()
        assert len(remaining) == 1
        assert remaining[0]["title"] == "Second"
