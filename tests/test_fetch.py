"""Tests for wilted.fetch — URL resolution, title extraction, and FD suppression."""

import threading
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

import pytest

from wilted.fetch import (
    _suppress_lock,
    extract_title_from_url,
    fetch_url_with_browser,
    get_text_from_url,
    suppress_subprocess_output,
)

# Note: fetch.resolve_apple_news_url was removed in the T2.2 cutover —
# get_text_from_url now delegates entirely to
# wilted.fetch_cascade.resolve_article_text, which has its own Apple News
# resolution covered by tests/test_fetch_cascade.py::TestAppleNewsResolution.


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


class TestGetTextFromUrl:
    """Characterization tests locking get_text_from_url's CURRENT contract.

    get_text_from_url now delegates entirely to
    ``wilted.fetch_cascade.resolve_article_text`` (FULL budget). These tests
    pin the observable contract — text present/absent, and the resolved URL —
    not the literal string the cascade's extraction happens to return, so
    they keep passing as the cascade's internals evolve.

    The cascade extracts via ``trafilatura.bare_extraction`` (not
    ``trafilatura.extract``, which the pre-cutover implementation used) and,
    on FULL budget, escalates to :func:`wilted.fetch.fetch_url_with_browser`
    when the trafilatura fetch yields no HTML — so the blocked-fetch case
    below stubs the browser fallback too, keeping this a fast, offline,
    deterministic unit test instead of one that silently opens a real
    browser.
    """

    pytestmark = pytest.mark.usefixtures("stub_trafilatura_module")

    @staticmethod
    def _mock_fetch(html):
        return patch("trafilatura.fetch_url", create=True, return_value=html)

    @staticmethod
    def _mock_extract(text, title=None):
        return patch(
            "trafilatura.bare_extraction",
            create=True,
            return_value=SimpleNamespace(text=text, title=title),
        )

    def test_apple_news_url_is_resolved_before_fetch(self):
        """apple.news links are resolved to their canonical URL before fetching."""
        redirect_html = b'<script>redirectToUrl("https://www.theatlantic.com/article/123/?utm_source=apple")</script>'
        mock_resp = MagicMock()
        mock_resp.read.return_value = redirect_html
        mock_resp.__enter__ = lambda s: s
        mock_resp.__exit__ = MagicMock(return_value=False)

        with (
            patch("wilted.fetch.urllib.request.urlopen", return_value=mock_resp),
            self._mock_fetch("<html>content</html>"),
            self._mock_extract("Article body text " * 30),
        ):
            text, resolved_url = get_text_from_url("https://apple.news/ABC123")

        assert resolved_url == "https://www.theatlantic.com/article/123/"
        assert text is not None

    def test_trafilatura_success_returns_text(self):
        """A clean trafilatura fetch+extract yields non-None text and the input URL unchanged."""
        with self._mock_fetch("<html>content</html>"), self._mock_extract("Article body text " * 30):
            text, resolved_url = get_text_from_url("https://example.com/article")

        assert text is not None
        assert resolved_url == "https://example.com/article"

    def test_blocked_fetch_returns_no_text(self):
        """When trafilatura.fetch_url can't retrieve HTML (e.g. blocked), no text is returned.

        FULL budget escalates to the headed-browser fallback when trafilatura
        yields no HTML — stub it to also return nothing so this stays a fast,
        offline unit test instead of launching a real browser.
        """
        with self._mock_fetch(None), patch("wilted.fetch_cascade.fetch_url_with_browser", return_value=None):
            text, resolved_url = get_text_from_url("https://example.com/blocked")

        assert text is None
        assert resolved_url == "https://example.com/blocked"

    def test_extraction_failure_returns_no_text(self):
        """When HTML is fetched but bare_extraction can't pull text, no text is returned."""
        with self._mock_fetch("<html>content</html>"), self._mock_extract(None):
            text, resolved_url = get_text_from_url("https://example.com/unparseable")

        assert text is None
        assert resolved_url == "https://example.com/unparseable"
