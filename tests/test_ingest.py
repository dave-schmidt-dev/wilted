"""Tests for wilted.ingest — shared article ingestion."""

import sys
import types
from unittest.mock import patch

import pytest

# Ensure trafilatura is importable as a mock for test collection
if "trafilatura" not in sys.modules:
    sys.modules["trafilatura"] = types.ModuleType("trafilatura")

from wilted.ingest import ArticleResult, resolve_article


class TestResolveFromURL:
    def test_url_path_returns_article(self):
        """resolve_article with a URL fetches and returns text + metadata."""
        fake_result = {"text": "Article body text.", "title": "Test Title"}
        with (
            patch("trafilatura.fetch_url", create=True, return_value="<html>content</html>"),
            patch("trafilatura.bare_extraction", create=True, return_value=fake_result),
        ):
            result = resolve_article(url="https://example.com/article")

        assert isinstance(result, ArticleResult)
        assert "Article body text" in result.text
        assert result.title == "Test Title"
        assert result.source_url == "https://example.com/article"
        assert result.canonical_url == "https://example.com/article"

    def test_url_fetch_failure_raises(self):
        """resolve_article raises ValueError when URL fetch returns None."""
        with (
            patch("trafilatura.fetch_url", create=True, return_value=None),
            pytest.raises(ValueError, match="Could not fetch"),
        ):
            resolve_article(url="https://example.com/paywall")

    def test_url_extraction_failure_raises(self):
        """resolve_article raises ValueError when extraction returns no text."""
        with (
            patch("trafilatura.fetch_url", create=True, return_value="<html></html>"),
            patch("trafilatura.bare_extraction", create=True, return_value={"text": ""}),
            pytest.raises(ValueError, match="Could not extract"),
        ):
            resolve_article(url="https://example.com/empty")


class TestResolveFromClipboard:
    def test_clipboard_path_returns_article(self):
        """resolve_article from clipboard returns text + title."""
        result = resolve_article(clipboard_text="CATEGORY\nTITLE IN ALL CAPS\nBody text here.")

        assert isinstance(result, ArticleResult)
        assert "Body text here" in result.text
        assert result.source_url is None

    def test_empty_clipboard_raises(self):
        """resolve_article raises ValueError for empty clipboard."""
        with pytest.raises(ValueError, match="Clipboard is empty"):
            resolve_article(clipboard_text="")

    def test_short_clipboard_with_min_len_raises(self):
        """resolve_article with min_clipboard_len rejects short text."""
        with pytest.raises(ValueError, match="too short"):
            resolve_article(clipboard_text="Short.", min_clipboard_len=50)

    def test_apple_news_url_extracted(self):
        """resolve_article extracts Apple News URL from clipboard text."""
        text = "Article body text.\nhttps://apple.news/ABC123 more stuff"
        result = resolve_article(clipboard_text=text)

        assert result.source_url == "https://apple.news/ABC123"

    def test_reads_system_clipboard_when_no_text_provided(self):
        """resolve_article reads from pbpaste when no clipboard_text given."""
        with patch("wilted.ingest.get_text_from_clipboard", return_value="Clipboard content here."):
            result = resolve_article()

        assert "Clipboard content" in result.text


class TestOnStatusCallback:
    def test_on_status_called_for_url(self):
        """on_status callback receives progress messages for URL path."""
        messages = []
        fake_result = {"text": "Article text.", "title": "T"}
        with (
            patch("trafilatura.fetch_url", create=True, return_value="<html>x</html>"),
            patch("trafilatura.bare_extraction", create=True, return_value=fake_result),
        ):
            resolve_article(
                url="https://example.com/test",
                on_status=messages.append,
            )

        assert any("Fetching" in m for m in messages)

    def test_on_status_called_for_clipboard(self):
        """on_status callback receives progress messages for clipboard path."""
        messages = []
        with patch("wilted.ingest.get_text_from_clipboard", return_value="Clipboard body."):
            resolve_article(on_status=messages.append)

        assert any("clipboard" in m.lower() for m in messages)
