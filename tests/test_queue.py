"""Tests for wilted.queue — reading list persistence and operations."""

import pytest

import wilted
from wilted.queue import (
    add_article,
    clear_queue,
    get_article_text,
    load_queue,
    mark_completed,
    remove_article,
)


class TestLoadSaveQueue:
    def test_empty_when_no_items(self):
        assert load_queue() == []

    def test_load_returns_only_ready_items(self):
        add_article("Text.", title="Added")
        queue = load_queue()
        assert len(queue) == 1
        assert queue[0]["status"] == "ready"


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
        article_path = wilted.ARTICLES_DIR / entry["file"]
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
        article_path = wilted.ARTICLES_DIR / entry["file"]
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
        article_path = wilted.ARTICLES_DIR / entry["file"]
        clear_queue()
        assert not article_path.exists()


class TestGetArticleText:
    def test_reads_cached_text(self):
        entry = add_article("The full article text.", title="Test")
        assert get_article_text(entry) == "The full article text."

    def test_returns_none_for_missing_file(self):
        entry = {"file": "nonexistent.txt"}
        assert get_article_text(entry) is None


class TestLoadQueueSelectedStatus:
    def test_selected_article_appears_in_queue(self):
        """load_queue() includes articles with status='selected'."""
        from wilted.db import Item

        entry = add_article("Article text.", title="Selected Article")
        Item.update(status="selected").where(Item.id == entry["id"]).execute()
        queue = load_queue()
        assert len(queue) == 1
        assert queue[0]["title"] == "Selected Article"

    def test_selected_podcast_excluded_from_queue(self):
        """load_queue() excludes podcast episodes with status='selected' (needs Phase 4)."""
        from datetime import UTC, datetime

        from wilted.db import Feed, Item

        now = datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
        feed = Feed.create(
            title="Test Podcast",
            feed_url="https://example.com/podcast.xml",
            feed_type="podcast",
            enabled=True,
            created_at=now,
            updated_at=now,
        )
        Item.create(
            feed=feed,
            guid="pod-ep-1",
            title="Podcast Episode",
            discovered_at=now,
            item_type="podcast_episode",
            status="selected",
            status_changed_at=now,
        )
        assert load_queue() == []

    def test_ready_podcast_included_in_queue(self):
        """load_queue() includes podcast episodes with status='ready' (Phase 4 prepared them)."""
        from datetime import UTC, datetime

        from wilted.db import Feed, Item

        now = datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")
        feed = Feed.create(
            title="Test Podcast",
            feed_url="https://example.com/podcast2.xml",
            feed_type="podcast",
            enabled=True,
            created_at=now,
            updated_at=now,
        )
        Item.create(
            feed=feed,
            guid="pod-ep-ready",
            title="Ready Podcast Episode",
            discovered_at=now,
            item_type="podcast_episode",
            status="ready",
            status_changed_at=now,
        )
        queue = load_queue()
        assert len(queue) == 1
        assert queue[0]["title"] == "Ready Podcast Episode"


class TestMarkCompleted:
    def test_removes_from_queue(self):
        entry = add_article("Content.", title="Test")
        mark_completed(entry)
        assert load_queue() == []

    def test_retains_cached_file(self):
        """mark_completed keeps files; retention policy handles cleanup later."""
        entry = add_article("Content.", title="Test")
        article_path = wilted.ARTICLES_DIR / entry["file"]
        mark_completed(entry)
        assert article_path.exists()

    def test_leaves_other_entries(self):
        add_article("First.", title="First")
        add_article("Second.", title="Second")
        # Remove first (id=1)
        queue = load_queue()
        mark_completed(queue[0])
        remaining = load_queue()
        assert len(remaining) == 1
        assert remaining[0]["title"] == "Second"
