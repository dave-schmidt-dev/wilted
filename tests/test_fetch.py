"""Tests for lilt.fetch — URL resolution and title extraction."""

from unittest.mock import MagicMock, patch

from lilt.fetch import extract_title_from_url, resolve_apple_news_url


class TestResolveAppleNewsUrl:
    @patch("lilt.fetch.urllib.request.urlopen")
    def test_extracts_redirect_url(self, mock_urlopen):
        html = b'<script>redirectToUrl("https://www.theatlantic.com/article/123/?utm_source=apple")</script>'
        mock_resp = MagicMock()
        mock_resp.read.return_value = html
        mock_resp.__enter__ = lambda s: s
        mock_resp.__exit__ = MagicMock(return_value=False)
        mock_urlopen.return_value = mock_resp

        result = resolve_apple_news_url("https://apple.news/ABC123")
        assert result == "https://www.theatlantic.com/article/123/"

    @patch("lilt.fetch.urllib.request.urlopen")
    def test_returns_original_on_failure(self, mock_urlopen):
        mock_urlopen.side_effect = Exception("Network error")
        result = resolve_apple_news_url("https://apple.news/ABC123")
        assert result == "https://apple.news/ABC123"

    @patch("lilt.fetch.urllib.request.urlopen")
    def test_returns_original_when_no_redirect(self, mock_urlopen):
        mock_resp = MagicMock()
        mock_resp.read.return_value = b"<html><body>No redirect here</body></html>"
        mock_resp.__enter__ = lambda s: s
        mock_resp.__exit__ = MagicMock(return_value=False)
        mock_urlopen.return_value = mock_resp

        result = resolve_apple_news_url("https://apple.news/ABC123")
        assert result == "https://apple.news/ABC123"


class TestExtractTitleFromUrl:
    @patch("lilt.fetch.urllib.request.urlopen")
    def test_extracts_title(self, mock_urlopen):
        html = b"<html><head><title>Big Story - The Atlantic</title></head></html>"
        mock_resp = MagicMock()
        mock_resp.read.return_value = html
        mock_resp.__enter__ = lambda s: s
        mock_resp.__exit__ = MagicMock(return_value=False)
        mock_urlopen.return_value = mock_resp

        result = extract_title_from_url("https://www.theatlantic.com/article/123/")
        assert result == "Big Story"

    @patch("lilt.fetch.urllib.request.urlopen")
    def test_strips_new_yorker_suffix(self, mock_urlopen):
        html = b"<html><head><title>The Interview | The New Yorker</title></head></html>"
        mock_resp = MagicMock()
        mock_resp.read.return_value = html
        mock_resp.__enter__ = lambda s: s
        mock_resp.__exit__ = MagicMock(return_value=False)
        mock_urlopen.return_value = mock_resp

        result = extract_title_from_url("https://www.newyorker.com/article/123/")
        assert result == "The Interview"

    @patch("lilt.fetch.urllib.request.urlopen")
    def test_returns_none_on_failure(self, mock_urlopen):
        mock_urlopen.side_effect = Exception("Network error")
        result = extract_title_from_url("https://example.com")
        assert result is None

    @patch("lilt.fetch.urllib.request.urlopen")
    def test_returns_none_when_no_title(self, mock_urlopen):
        html = b"<html><head></head><body>No title tag</body></html>"
        mock_resp = MagicMock()
        mock_resp.read.return_value = html
        mock_resp.__enter__ = lambda s: s
        mock_resp.__exit__ = MagicMock(return_value=False)
        mock_urlopen.return_value = mock_resp

        result = extract_title_from_url("https://example.com")
        assert result is None
