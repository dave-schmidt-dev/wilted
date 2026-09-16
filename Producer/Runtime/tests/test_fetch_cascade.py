"""Tests for wilted.fetch_cascade — unified fetch/extract cascade (Phase 1).

This module has zero production callers until Phase 2 cuts fetch.py /
ingest.py / discover.py over onto it — these tests are the only thing
locking its acceptance-gate predicate and suppression contract down before
that happens.
"""

import ast
import inspect
import logging
from contextlib import nullcontext
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

import pytest

import wilted.fetch_cascade as fc
from wilted.fetch_cascade import FetchBudget, ResolvedText, resolve_apple_news_url, resolve_article_text

pytestmark = pytest.mark.usefixtures("stub_trafilatura_module")


@pytest.fixture(autouse=True)
def _reset_cascade_config_state():
    """``_configured``/``_trafilatura_config`` are process-global module state.

    Without resetting them around every test, whichever test happens to run
    ``resolve_article_text`` first flips ``_configured = True`` for the rest
    of the session — later tests that assert ``_configure_once`` behavior
    would silently see stale state and pass for the wrong reason.
    """
    fc._configured = False
    fc._trafilatura_config = None
    yield
    fc._configured = False
    fc._trafilatura_config = None


def _mock_fetch(html):
    return patch("trafilatura.fetch_url", create=True, return_value=html)


def _mock_extract(text, title=None):
    return patch("trafilatura.bare_extraction", create=True, return_value=SimpleNamespace(text=text, title=title))


class TestOutcomes:
    """The four-way acceptance-gate predicate, first-match precedence."""

    def test_ok_when_full_text_extracted(self):
        with _mock_fetch("<html>content</html>"), _mock_extract("word " * 30, "A Real Title"):
            result = resolve_article_text("https://example.com/a", budget=FetchBudget.CHEAP)

        assert isinstance(result, ResolvedText)
        assert result.outcome == "ok"
        assert result.title == "A Real Title"
        assert result.tier_used == "trafilatura"
        assert result.resolved_url == "https://example.com/a"

    def test_blocked_when_no_html(self):
        with _mock_fetch(None):
            result = resolve_article_text("https://example.com/blocked", budget=FetchBudget.CHEAP)

        assert result.outcome == "blocked"
        assert result.text is None
        assert result.title is None
        assert result.tier_used == "none"

    def test_failed_when_html_but_no_text(self):
        with _mock_fetch("<html></html>"), _mock_extract(None, None):
            result = resolve_article_text("https://example.com/empty", budget=FetchBudget.CHEAP)

        assert result.outcome == "failed"
        assert result.text is None
        assert result.title is None

    def test_headline_only_when_under_min_words(self):
        with _mock_fetch("<html>content</html>"), _mock_extract("Too short.", "Title"):
            result = resolve_article_text("https://example.com/short", budget=FetchBudget.CHEAP, min_words=25)

        assert result.outcome == "headline_only"
        assert result.text == "Too short."


class TestEdgeStates:
    """States called out explicitly in the spec as easy to get wrong."""

    def test_long_consent_wall_text_is_headline_only(self):
        """Word count alone isn't enough — a wordy consent wall must still downgrade."""
        long_consent_text = "We use cookies " + ("word " * 40)
        with _mock_fetch("<html>content</html>"), _mock_extract(long_consent_text, "Title"):
            result = resolve_article_text("https://example.com/consent", budget=FetchBudget.CHEAP)

        assert len(result.text.split()) >= 25
        assert result.outcome == "headline_only"

    def test_title_equal_to_url_blanks_title_but_stays_ok(self):
        """PM-7: title==url blanks the title only — it is not a downgrade trigger."""
        url = "https://example.com/pm7"
        body = "word " * 30
        with _mock_fetch("<html>content</html>"), _mock_extract(body, url):
            result = resolve_article_text(url, budget=FetchBudget.CHEAP)

        assert result.outcome == "ok"
        assert result.title is None

    def test_whitespace_only_extracted_text_is_failed_not_headline_only(self):
        """FIX #1: HTML fetched, text extracted, but it cleans down to nothing
        usable — must be "failed" with text=None, not "headline_only" with
        text="". The docstring promises None "if nothing usable" for every
        code path, not just the None-from-bare_extraction one.
        """
        with _mock_fetch("<html>content</html>"), _mock_extract("   \n\t  ", "Title"):
            result = resolve_article_text("https://example.com/whitespace", budget=FetchBudget.CHEAP)

        assert result.outcome == "failed"
        assert result.text is None
        assert result.title is None

    def test_empty_string_extracted_text_is_failed(self):
        """Defensive companion to the whitespace-only case: an empty string
        from bare_extraction (falsy pre-clean_text) must also land on
        "failed", not "headline_only".
        """
        with _mock_fetch("<html>content</html>"), _mock_extract("", "Title"):
            result = resolve_article_text("https://example.com/empty-string", budget=FetchBudget.CHEAP)

        assert result.outcome == "failed"
        assert result.text is None
        assert result.title is None


class TestExtractFromMain:
    """Direct unit coverage for _extract_from_main (previously untested only
    via the resolve_article_text integration path).
    """

    def test_main_present_with_article_body_returns_scoped_text_and_title(self):
        html = "<html><head><title>Ignored</title></head><body><main><p>Real article body.</p></main></body></html>"
        stub_trafilatura = MagicMock()
        stub_trafilatura.bare_extraction.return_value = SimpleNamespace(text="Real article body.", title="Scoped Title")

        text, title = fc._extract_from_main(html, stub_trafilatura, "fallback text", "fallback title")

        assert text == "Real article body."
        assert title == "Scoped Title"
        # Confirm the extraction actually ran scoped to <main> — the outer
        # <title> tag must not be part of what bare_extraction saw.
        scoped_html_passed = stub_trafilatura.bare_extraction.call_args.args[0]
        assert "<main>" in scoped_html_passed
        assert "Ignored" not in scoped_html_passed

    def test_no_main_element_returns_fallback_unchanged(self):
        html = "<html><body><p>No main tag anywhere in this document.</p></body></html>"
        stub_trafilatura = MagicMock()

        text, title = fc._extract_from_main(html, stub_trafilatura, "fallback text", "fallback title")

        assert (text, title) == ("fallback text", "fallback title")
        stub_trafilatura.bare_extraction.assert_not_called()

    @pytest.mark.parametrize(
        "raw_title,expected_title",
        [
            ("Article Headline - Site Name", "Article Headline"),
            ("Article Headline | Site", "Article Headline"),
            ("Article Headline — Site Name", "Article Headline"),  # em dash
            ("Article Headline – Site Name", "Article Headline"),  # en dash
            ("A Story About a self-made Millionaire", "A Story About a self-made Millionaire"),
        ],
    )
    def test_title_falls_back_to_full_html_title_with_suffix_strip(self, raw_title, expected_title):
        """Scoped extraction yields no title, so it's pulled from the full
        HTML <title> tag, stripping a trailing " - Site" / " | Site" /
        em/en-dash suffix — but not splitting a hyphenated word like
        "self-made" that has no surrounding whitespace.
        """
        html = f"<html><head><title>{raw_title}</title></head><body><main><p>content</p></main></body></html>"
        stub_trafilatura = MagicMock()
        stub_trafilatura.bare_extraction.return_value = SimpleNamespace(text="word " * 30, title=None)

        _, title = fc._extract_from_main(html, stub_trafilatura, None, None)

        assert title == expected_title

    def test_scoped_consent_wall_text_is_rejected_in_favor_of_fallback(self):
        html = "<html><body><main>cookie overlay markup</main></body></html>"
        consent_text = "We use cookies " + ("word " * 40)
        stub_trafilatura = MagicMock()
        stub_trafilatura.bare_extraction.return_value = SimpleNamespace(text=consent_text, title="Consent Title")

        text, title = fc._extract_from_main(html, stub_trafilatura, "fallback text", "fallback title")

        assert (text, title) == ("fallback text", "fallback title")


class TestBudgetDifferences:
    """CHEAP must reproduce discover._fetch_article_text's depth exactly: no browser, no <main> retry."""

    def test_cheap_never_invokes_browser_fallback(self):
        with _mock_fetch(None), patch("wilted.fetch_cascade.fetch_url_with_browser") as mock_browser:
            result = resolve_article_text("https://example.com/x", budget=FetchBudget.CHEAP)

        mock_browser.assert_not_called()
        assert result.outcome == "blocked"

    def test_full_escalates_to_browser_when_trafilatura_blocked(self):
        with (
            _mock_fetch(None),
            patch("wilted.fetch_cascade.fetch_url_with_browser", return_value="<html>browser</html>") as mock_browser,
            _mock_extract("word " * 30, "Title"),
        ):
            result = resolve_article_text("https://example.com/x", budget=FetchBudget.FULL)

        mock_browser.assert_called_once()
        assert result.tier_used == "browser"
        assert result.outcome == "ok"

    def test_cheap_never_retries_main_scope_on_consent_wall(self):
        long_consent_text = "We use cookies " + ("word " * 40)
        with (
            _mock_fetch("<html><main>ignored</main></html>"),
            _mock_extract(long_consent_text, "Title"),
            patch("wilted.fetch_cascade._extract_from_main") as mock_main,
        ):
            result = resolve_article_text("https://example.com/x", budget=FetchBudget.CHEAP)

        mock_main.assert_not_called()
        assert result.outcome == "headline_only"

    def test_full_retries_main_scope_on_consent_wall(self):
        html = "<html><main>Real article text here.</main></html>"
        consent_text = "We use cookies " + ("word " * 40)
        with (
            _mock_fetch(html),
            _mock_extract(consent_text, "Consent Title"),
            patch(
                "wilted.fetch_cascade._extract_from_main",
                return_value=("word " * 30, "Main Title"),
            ) as mock_main,
        ):
            result = resolve_article_text("https://example.com/x", budget=FetchBudget.FULL)

        mock_main.assert_called_once()
        assert result.tier_used == "main-scope"
        assert result.outcome == "ok"
        assert result.title == "Main Title"

    def test_full_no_op_main_retry_keeps_prior_tier_used(self):
        """FIX #2: a <main> retry that finds no <main> element is a no-op —
        it must not falsely claim tier_used="main-scope" when the text
        actually used is still whatever the pre-retry tier produced.
        """
        consent_text = "We use cookies " + ("word " * 40)
        html = "<html><body>no main element in this document</body></html>"
        with _mock_fetch(html), _mock_extract(consent_text, "Consent Title"):
            result = resolve_article_text("https://example.com/x", budget=FetchBudget.FULL)

        assert result.tier_used == "trafilatura"
        assert result.outcome == "headline_only"


class TestSuppressionScope:
    def test_transport_fetch_runs_outside_suppression_scope(self):
        """CR-9: the network fetch must never run inside suppress_subprocess_output.

        The 2026-04-20 TUI-freeze regression (HISTORY.md ~1368) was exactly
        this: wrapping the fetch too blinded the TUI for the whole HTTP
        round-trip instead of just the one-time trafilatura import.
        """
        events = []

        class RecordingSuppress:
            def __call__(self, on_wait=None):
                return self

            def __enter__(self):
                events.append("suppress_enter")
                return self

            def __exit__(self, *exc):
                events.append("suppress_exit")
                return False

        def fake_fetch_url(url, config=None):
            events.append("fetch_url")
            return "<html>content</html>"

        with (
            patch("wilted.fetch_cascade.suppress_subprocess_output", RecordingSuppress()),
            patch("trafilatura.fetch_url", create=True, side_effect=fake_fetch_url),
            _mock_extract("word " * 30, "Title"),
        ):
            resolve_article_text("https://example.com/a", budget=FetchBudget.CHEAP)

        assert events == ["suppress_enter", "suppress_exit", "fetch_url"]


class TestOnWaitForwarding:
    def test_on_wait_derived_from_on_status_reaches_suppress(self):
        """PM-2: on_wait passed to suppress_subprocess_output must be derived from on_status."""
        captured = {}

        def fake_suppress(on_wait=None):
            captured["on_wait"] = on_wait
            return nullcontext()

        statuses = []
        with (
            patch("wilted.fetch_cascade.suppress_subprocess_output", side_effect=fake_suppress),
            _mock_fetch("<html>content</html>"),
            _mock_extract("word " * 30, "Title"),
        ):
            resolve_article_text("https://example.com/a", budget=FetchBudget.CHEAP, on_status=statuses.append)

        assert callable(captured["on_wait"])
        captured["on_wait"]()
        assert "Waiting for another download to finish..." in statuses


class TestImportCleanliness:
    def test_no_module_top_trafilatura_import(self):
        """PM-1: trafilatura must be imported lazily inside suppress_subprocess_output.

        A module-top import would re-fire the historical TUI-freeze bug on
        the mere ``import wilted.fetch_cascade`` — before any suppression
        scope even exists. Scans the AST rather than checking
        ``sys.modules`` at runtime, since the latter is order-dependent
        (``stub_trafilatura_module`` or an earlier test that already ran the
        cascade would both leave ``trafilatura`` resident regardless of
        where this module imports it).
        """
        source = inspect.getsource(fc)
        tree = ast.parse(source)
        for node in tree.body:  # module top-level only; nested imports are fine
            if isinstance(node, ast.Import):
                names = [alias.name for alias in node.names]
                assert not any(n.split(".")[0] == "trafilatura" for n in names), (
                    f"module-top `import` of trafilatura found: {names}"
                )
            elif isinstance(node, ast.ImportFrom) and node.module:
                assert node.module.split(".")[0] != "trafilatura", f"module-top `from {node.module} import ...` found"

    def test_importing_module_does_not_pull_in_real_trafilatura(self):
        """Belt-and-braces runtime check for the common case: a fresh interpreter
        that imports wilted.fetch_cascade without ever calling resolve_article_text
        should not have trafilatura resident. (The gate command
        `python -c "import wilted.fetch_cascade; ...# must print False"` covers
        the fully-isolated-process version of this; this is the in-suite analog,
        skipped if a prior test already imported the real package into this
        process before this one ran.)
        """
        import sys

        if "trafilatura" in sys.modules and not isinstance(sys.modules["trafilatura"], type(fc)):
            pytest.skip("real trafilatura already resident from an earlier test in this process")


class TestObservability:
    def test_logs_tier_attempts_and_final_outcome_on_cheap(self, caplog):
        with caplog.at_level(logging.DEBUG, logger="wilted.fetch_cascade"):
            with _mock_fetch("<html>content</html>"), _mock_extract("word " * 30, "Title"):
                resolve_article_text("https://example.com/a", budget=FetchBudget.CHEAP)

        assert "trying trafilatura fetch" in caplog.text
        assert "extracting via bare_extraction" in caplog.text
        assert "outcome=ok" in caplog.text
        assert "tier_used=trafilatura" in caplog.text
        assert "words=30" in caplog.text

    def test_logs_browser_and_main_scope_attempts_on_full(self, caplog):
        html = "<html><main>Real article text here.</main></html>"
        with caplog.at_level(logging.DEBUG, logger="wilted.fetch_cascade"):
            with (
                _mock_fetch(None),
                patch("wilted.fetch_cascade.fetch_url_with_browser", return_value=html),
                _mock_extract(None, None),
                patch(
                    "wilted.fetch_cascade._extract_from_main",
                    return_value=("word " * 30, "Main Title"),
                ),
            ):
                result = resolve_article_text("https://example.com/a", budget=FetchBudget.FULL)

        assert "trying browser" in caplog.text
        assert "retrying extraction scoped to <main>" in caplog.text
        assert "outcome=ok" in caplog.text
        assert "tier_used=main-scope" in caplog.text
        assert result.tier_used == "main-scope"


class TestConfigureOnce:
    def test_configure_once_sets_download_timeout(self):
        fc._configure_once()
        assert fc._trafilatura_config.get("DEFAULT", "DOWNLOAD_TIMEOUT") == str(fc.FETCH_TIMEOUT_S)

    def test_configure_once_is_idempotent(self):
        fc._configure_once()
        first_cfg = fc._trafilatura_config
        fc._configure_once()
        assert fc._trafilatura_config is first_cfg


class TestAppleNewsResolution:
    def test_resolve_apple_news_url_extracts_canonical(self):
        html = b'<script>redirectToUrl("https://www.example.com/article/123/?utm_source=apple")</script>'
        mock_resp = MagicMock()
        mock_resp.read.return_value = html
        mock_resp.__enter__ = lambda s: s
        mock_resp.__exit__ = MagicMock(return_value=False)

        with patch("wilted.fetch_cascade.urllib.request.urlopen", return_value=mock_resp):
            result = resolve_apple_news_url("https://apple.news/ABC123")

        assert result == "https://www.example.com/article/123/"

    def test_resolve_apple_news_url_returns_original_on_network_error(self):
        """A network failure during resolution returns the original URL unchanged.

        Coverage relocated from the fetch.resolve_apple_news_url tests removed
        in the T2.2 cutover — the except branch must never raise or drop the URL.
        """
        with patch(
            "wilted.fetch_cascade.urllib.request.urlopen",
            side_effect=Exception("Network error"),
        ):
            result = resolve_apple_news_url("https://apple.news/ABC123")

        assert result == "https://apple.news/ABC123"

    def test_resolve_apple_news_url_returns_original_when_no_redirect(self):
        """HTML without a redirectToUrl marker returns the original URL unchanged."""
        mock_resp = MagicMock()
        mock_resp.read.return_value = b"<html><body>No redirect here</body></html>"
        mock_resp.__enter__ = lambda s: s
        mock_resp.__exit__ = MagicMock(return_value=False)

        with patch("wilted.fetch_cascade.urllib.request.urlopen", return_value=mock_resp):
            result = resolve_apple_news_url("https://apple.news/ABC123")

        assert result == "https://apple.news/ABC123"

    def test_resolve_apple_news_url_reports_via_on_status_not_print(self, capsys):
        html = b'<script>redirectToUrl("https://www.example.com/article/123/")</script>'
        mock_resp = MagicMock()
        mock_resp.read.return_value = html
        mock_resp.__enter__ = lambda s: s
        mock_resp.__exit__ = MagicMock(return_value=False)

        statuses = []
        with patch("wilted.fetch_cascade.urllib.request.urlopen", return_value=mock_resp):
            resolve_apple_news_url("https://apple.news/ABC123", on_status=statuses.append)

        assert any("Resolved to" in s for s in statuses)
        captured = capsys.readouterr()
        assert captured.out == ""

    def test_apple_news_url_resolved_before_fetch(self):
        canonical = "https://www.example.com/article/123/"
        html = f'<script>redirectToUrl("{canonical}")</script>'.encode()
        mock_resp = MagicMock()
        mock_resp.read.return_value = html
        mock_resp.__enter__ = lambda s: s
        mock_resp.__exit__ = MagicMock(return_value=False)

        with (
            patch("wilted.fetch_cascade.urllib.request.urlopen", return_value=mock_resp),
            _mock_fetch("<html>content</html>"),
            _mock_extract("word " * 30, "Title"),
        ):
            result = resolve_article_text("https://apple.news/ABC123", budget=FetchBudget.CHEAP)

        assert result.resolved_url == canonical
