"""Tests for wilted.ingest — shared article ingestion."""

import types
from types import SimpleNamespace
from unittest.mock import patch

import pytest

from wilted.ingest import (
    ArticleResult,
    _extract_from_main,
    _looks_like_consent_wall,
    resolve_article,
)

pytestmark = pytest.mark.usefixtures("stub_trafilatura_module")


class TestResolveFromURL:
    def test_url_path_returns_article(self):
        """resolve_article with a URL fetches and returns text + metadata."""
        fake_doc = SimpleNamespace(text="Article body text.", title="Test Title")
        with (
            patch("trafilatura.fetch_url", create=True, return_value="<html>content</html>"),
            patch("trafilatura.bare_extraction", create=True, return_value=fake_doc),
        ):
            result = resolve_article(url="https://example.com/article")

        assert isinstance(result, ArticleResult)
        assert "Article body text" in result.text
        assert result.title == "Test Title"
        assert result.source_url == "https://example.com/article"
        assert result.canonical_url == "https://example.com/article"

    def test_url_fetch_failure_raises(self):
        """resolve_article raises ValueError when both trafilatura and browser fetch fail."""
        with (
            patch("trafilatura.fetch_url", create=True, return_value=None),
            patch("wilted.ingest.fetch_url_with_browser", return_value=None),
            pytest.raises(ValueError, match="Blocked"),
        ):
            resolve_article(url="https://example.com/paywall")

    def test_url_extraction_failure_raises(self):
        """resolve_article raises ValueError when extraction returns no text."""
        with (
            patch("trafilatura.fetch_url", create=True, return_value="<html></html>"),
            patch("trafilatura.bare_extraction", create=True, return_value=SimpleNamespace(text="", title=None)),
            pytest.raises(ValueError, match="Could not extract"),
        ):
            resolve_article(url="https://example.com/empty")

    def test_browser_fallback_used_when_trafilatura_blocked(self):
        """When trafilatura returns None, fetch_url_with_browser is tried."""
        fake_doc = SimpleNamespace(text="Browser-fetched article.", title="Browser Title")
        with (
            patch("trafilatura.fetch_url", create=True, return_value=None),
            patch("wilted.ingest.fetch_url_with_browser", return_value="<html>browser</html>") as mock_browser,
            patch("trafilatura.bare_extraction", create=True, return_value=fake_doc),
        ):
            result = resolve_article(url="https://example.com/cf-protected")

        mock_browser.assert_called_once()
        assert result.text == "Browser-fetched article."


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

    def test_clipboard_url_redirects_to_url_fetch(self):
        """A bare URL in clipboard should be fetched, not stored as text."""
        fake_doc = SimpleNamespace(text="Fetched article body.", title="Fetched Title")
        with (
            patch("trafilatura.fetch_url", create=True, return_value="<html>ok</html>"),
            patch("trafilatura.bare_extraction", create=True, return_value=fake_doc),
        ):
            result = resolve_article(
                clipboard_text="https://example.com/article",
            )

        assert result.text == "Fetched article body."
        assert result.title == "Fetched Title"
        assert result.source_url == "https://example.com/article"
        assert result.canonical_url == "https://example.com/article"

    def test_clipboard_url_with_prompt_prefix_redirects(self):
        """A URL prefixed by a shell prompt character should still be fetched."""
        fake_doc = SimpleNamespace(text="Fetched article.", title="Title")
        with (
            patch("trafilatura.fetch_url", create=True, return_value="<html>ok</html>"),
            patch("trafilatura.bare_extraction", create=True, return_value=fake_doc),
        ):
            result = resolve_article(
                clipboard_text="❯\xa0https://example.com/article",
            )

        assert result.text == "Fetched article."
        assert result.source_url == "https://example.com/article"

    def test_clipboard_url_with_newlines_treated_as_text(self):
        """Clipboard with a URL plus other lines is treated as pasted text."""
        text = "https://example.com/article\nSome article body text here."
        result = resolve_article(clipboard_text=text)

        assert "article body text" in result.text
        assert result.source_url is None

    def test_clipboard_sentence_with_url_treated_as_text(self):
        """A sentence that contains a URL should not be fetched."""
        text = "Read the full report at https://example.com/report for more details on the findings."
        result = resolve_article(clipboard_text=text)

        assert "full report" in result.text
        assert result.source_url is None


class TestOnStatusCallback:
    def test_on_status_called_for_url(self):
        """on_status callback receives progress messages for URL path."""
        messages = []
        fake_doc = SimpleNamespace(text="Article text.", title="T")
        with (
            patch("trafilatura.fetch_url", create=True, return_value="<html>x</html>"),
            patch("trafilatura.bare_extraction", create=True, return_value=fake_doc),
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


class TestLooksLikeConsentWall:
    def test_recognizes_tracker_preferences(self):
        assert _looks_like_consent_wall("Manage your tracker preferences\nWe use cookies...")

    def test_recognizes_cookie_consent(self):
        assert _looks_like_consent_wall("cookie consent dialog text here")

    def test_recognizes_we_use_cookies(self):
        assert _looks_like_consent_wall("We use cookies to improve your experience.")

    def test_ignores_normal_article_text(self):
        assert not _looks_like_consent_wall("President Trump signed an executive order today.")

    def test_only_checks_first_300_chars(self):
        """Consent text buried past 300 chars should not trigger the check."""
        long_article = "A" * 301 + " tracker preferences"
        assert not _looks_like_consent_wall(long_article)

    def test_case_insensitive(self):
        assert _looks_like_consent_wall("TRACKER PREFERENCES lorem ipsum")


class TestExtractFromMain:
    def _make_trafilatura(self, text, title=None):
        """Return a minimal trafilatura-like namespace for testing."""
        doc = SimpleNamespace(text=text, title=title)
        return types.SimpleNamespace(
            bare_extraction=lambda html, **kw: doc,
        )

    def test_extracts_article_from_main_element(self):
        html = (
            "<html><head><title>Great Article - Axios</title></head>"
            "<body><div>Cookie wall</div>"
            "<main><p>Real article content here.</p></main></body></html>"
        )
        traf = self._make_trafilatura("Real article content here.")
        text, title = _extract_from_main(html, traf, None, None)
        assert text == "Real article content here."
        assert title == "Great Article"

    def test_title_extracted_from_full_html_when_main_has_none(self):
        """Title comes from the full-page <title> tag when <main> extraction has none."""
        html = (
            "<html><head><title>Story Title - Site</title></head><body><main><p>Article body.</p></main></body></html>"
        )
        traf = self._make_trafilatura("Article body.", title=None)
        _, title = _extract_from_main(html, traf, None, None)
        assert title == "Story Title"

    def test_title_suffix_stripped_with_pipe(self):
        html = "<html><head><title>My Story | The Atlantic</title></head><body><main>x</main></body></html>"
        traf = self._make_trafilatura("x")
        _, title = _extract_from_main(html, traf, None, None)
        assert title == "My Story"

    def test_hyphenated_title_not_split(self):
        """A hyphen inside a word must not be treated as a title separator."""
        html = "<html><head><title>Self-made Billionaire - Forbes</title></head><body><main>x</main></body></html>"
        traf = self._make_trafilatura("x")
        _, title = _extract_from_main(html, traf, None, None)
        # " - " (space-hyphen-space) is the separator; "Self-made" should survive intact
        assert title == "Self-made Billionaire"

    def test_returns_fallback_when_no_main_element(self):
        html = "<html><body><div>No main tag here</div></body></html>"
        text, title = _extract_from_main(html, None, "fallback_text", "Fallback Title")
        assert text == "fallback_text"
        assert title == "Fallback Title"

    def test_returns_fallback_when_main_has_consent_text(self):
        """If <main> itself contains a consent wall, fall back to original values."""
        html = "<html><body><main>We use cookies and tracker preferences</main></body></html>"
        traf = self._make_trafilatura("We use cookies and tracker preferences")
        text, title = _extract_from_main(html, traf, "orig_text", "Orig Title")
        assert text == "orig_text"
        assert title == "Orig Title"

    def test_consent_wall_in_full_doc_triggers_main_extraction(self):
        """End-to-end: consent wall from first extraction causes retry via <main>."""
        consent_html = (
            "<html><head><title>Article - Site</title></head>"
            "<body>"
            "<div>We use cookies and tracker preferences everywhere</div>"
            "<main><p>The real article text lives here.</p></main>"
            "</body></html>"
        )
        consent_doc = SimpleNamespace(text="We use cookies and tracker preferences everywhere.", title=None)
        article_doc = SimpleNamespace(text="The real article text lives here.", title=None)

        call_count = [0]

        def fake_bare_extraction(html, **kwargs):
            call_count[0] += 1
            return consent_doc if call_count[0] == 1 else article_doc

        with (
            patch("trafilatura.fetch_url", create=True, return_value=consent_html),
            patch("trafilatura.bare_extraction", create=True, side_effect=fake_bare_extraction),
            patch("wilted.ingest.fetch_url_with_browser", return_value=None),
        ):
            result = resolve_article(url="https://example.com/article")

        assert "real article text" in result.text
        assert result.title == "Article"
