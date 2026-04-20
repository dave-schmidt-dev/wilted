"""Tests for wilted.fetch — URL resolution, title extraction, and FD suppression."""

import threading
from unittest.mock import MagicMock, patch

import pytest

from wilted.fetch import (
    _suppress_lock,
    extract_title_from_url,
    fetch_url_with_browser,
    resolve_apple_news_url,
    suppress_subprocess_output,
)


class TestResolveAppleNewsUrl:
    @patch("wilted.fetch.urllib.request.urlopen")
    def test_extracts_redirect_url(self, mock_urlopen):
        html = b'<script>redirectToUrl("https://www.theatlantic.com/article/123/?utm_source=apple")</script>'
        mock_resp = MagicMock()
        mock_resp.read.return_value = html
        mock_resp.__enter__ = lambda s: s
        mock_resp.__exit__ = MagicMock(return_value=False)
        mock_urlopen.return_value = mock_resp

        result = resolve_apple_news_url("https://apple.news/ABC123")
        assert result == "https://www.theatlantic.com/article/123/"

    @patch("wilted.fetch.urllib.request.urlopen")
    def test_returns_original_on_failure(self, mock_urlopen):
        mock_urlopen.side_effect = Exception("Network error")
        result = resolve_apple_news_url("https://apple.news/ABC123")
        assert result == "https://apple.news/ABC123"

    @patch("wilted.fetch.urllib.request.urlopen")
    def test_returns_original_when_no_redirect(self, mock_urlopen):
        mock_resp = MagicMock()
        mock_resp.read.return_value = b"<html><body>No redirect here</body></html>"
        mock_resp.__enter__ = lambda s: s
        mock_resp.__exit__ = MagicMock(return_value=False)
        mock_urlopen.return_value = mock_resp

        result = resolve_apple_news_url("https://apple.news/ABC123")
        assert result == "https://apple.news/ABC123"


class TestExtractTitleFromUrl:
    @patch("wilted.fetch.urllib.request.urlopen")
    def test_extracts_title(self, mock_urlopen):
        html = b"<html><head><title>Big Story - The Atlantic</title></head></html>"
        mock_resp = MagicMock()
        mock_resp.read.return_value = html
        mock_resp.__enter__ = lambda s: s
        mock_resp.__exit__ = MagicMock(return_value=False)
        mock_urlopen.return_value = mock_resp

        result = extract_title_from_url("https://www.theatlantic.com/article/123/")
        assert result == "Big Story"

    @patch("wilted.fetch.urllib.request.urlopen")
    def test_strips_new_yorker_suffix(self, mock_urlopen):
        html = b"<html><head><title>The Interview | The New Yorker</title></head></html>"
        mock_resp = MagicMock()
        mock_resp.read.return_value = html
        mock_resp.__enter__ = lambda s: s
        mock_resp.__exit__ = MagicMock(return_value=False)
        mock_urlopen.return_value = mock_resp

        result = extract_title_from_url("https://www.newyorker.com/article/123/")
        assert result == "The Interview"

    @patch("wilted.fetch.urllib.request.urlopen")
    def test_returns_none_on_failure(self, mock_urlopen):
        mock_urlopen.side_effect = Exception("Network error")
        result = extract_title_from_url("https://example.com")
        assert result is None

    @patch("wilted.fetch.urllib.request.urlopen")
    def test_returns_none_when_no_title(self, mock_urlopen):
        html = b"<html><head></head><body>No title tag</body></html>"
        mock_resp = MagicMock()
        mock_resp.read.return_value = html
        mock_resp.__enter__ = lambda s: s
        mock_resp.__exit__ = MagicMock(return_value=False)
        mock_urlopen.return_value = mock_resp

        result = extract_title_from_url("https://example.com")
        assert result is None


class TestSuppressSubprocessOutput:
    def test_on_wait_called_when_lock_is_held(self):
        """on_wait fires when another thread already holds the lock."""
        wait_called = threading.Event()
        worker_done = threading.Event()

        _suppress_lock.acquire()
        try:

            def worker():
                with suppress_subprocess_output(on_wait=wait_called.set):
                    pass
                worker_done.set()

            t = threading.Thread(target=worker)
            t.start()
            assert wait_called.wait(timeout=2.0), "on_wait should have been called"
        finally:
            _suppress_lock.release()
            assert worker_done.wait(timeout=2.0), "worker thread should complete"
            t.join()

    def test_on_wait_not_called_when_lock_is_free(self):
        """on_wait is not called when no contention exists."""
        called = []
        with suppress_subprocess_output(on_wait=lambda: called.append(True)):
            pass
        assert called == []

    def test_no_crash_when_fd_dup_raises(self):
        """suppress_subprocess_output survives an invalid FD gracefully."""
        with patch("wilted.fetch.os.dup", side_effect=OSError(9, "Bad file descriptor")):
            with suppress_subprocess_output():
                pass  # must not raise

    def test_lock_released_after_normal_exit(self):
        """The lock is free after the context manager exits normally."""
        with suppress_subprocess_output():
            pass
        acquired = _suppress_lock.acquire(blocking=False)
        assert acquired, "lock should be free after normal exit"
        _suppress_lock.release()

    def test_lock_released_after_exception(self):
        """The lock is free even when the body raises."""
        with pytest.raises(RuntimeError):
            with suppress_subprocess_output():
                raise RuntimeError("boom")
        acquired = _suppress_lock.acquire(blocking=False)
        assert acquired, "lock should be free after exception"
        _suppress_lock.release()


class TestFetchUrlWithBrowser:
    def test_returns_none_when_browser_raises(self):
        """fetch_url_with_browser returns None on any browser error."""
        with patch("playwright.sync_api.sync_playwright", side_effect=Exception("no browser")):
            result = fetch_url_with_browser("https://example.com")
        assert result is None

    def test_status_callback_called(self):
        """on_status receives progress messages during browser fetch."""
        messages = []
        with patch("playwright.sync_api.sync_playwright", side_effect=Exception("no browser")):
            fetch_url_with_browser("https://example.com", on_status=messages.append)
        assert any("browser" in m.lower() for m in messages)
