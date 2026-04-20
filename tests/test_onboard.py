"""Tests for wilted.onboard — setup and ingestion commands."""

from unittest.mock import MagicMock, patch

from wilted.onboard import STARTER_FEEDS, run_ingest, run_setup

# Patch targets match where the lazy imports land (source modules).
_P_DISCOVER = "wilted.discover.run_discover"
_P_CLASSIFY = "wilted.classify.run_classify"
_P_RUN_REPORT = "wilted.report.run_report"
_P_GET_REPORT = "wilted.report.get_report"


class TestStarterFeeds:
    def test_starter_feeds_all_have_required_keys(self):
        """Every starter feed has url, title, type, and playlist."""
        for feed in STARTER_FEEDS:
            assert "url" in feed
            assert "title" in feed
            assert "type" in feed
            assert feed["type"] in ("article", "podcast")

    def test_starter_feeds_urls_are_https(self):
        """All starter feed URLs use HTTPS."""
        for feed in STARTER_FEEDS:
            assert feed["url"].startswith("https://"), f"{feed['title']} uses non-HTTPS URL"

    def test_starter_feeds_not_empty(self):
        assert len(STARTER_FEEDS) >= 5


class TestRunIngest:
    def test_full_pipeline_runs_all_stages(self):
        """run_ingest calls discover, classify, and report in sequence."""
        mock_discover = MagicMock(return_value={"discovered": 5, "feeds_polled": 3, "errors": 0})
        mock_classify = MagicMock(return_value={"classified": 5, "errors": 0})
        mock_run_report = MagicMock()
        mock_get_report = MagicMock(
            return_value={
                "report": {"report_date": "2026-04-20"},
                "items": {"Work": [{"id": 1}], "Fun": [{"id": 2}]},
            }
        )

        with (
            patch(_P_DISCOVER, mock_discover),
            patch(_P_CLASSIFY, mock_classify),
            patch(_P_RUN_REPORT, mock_run_report),
            patch(_P_GET_REPORT, mock_get_report),
        ):
            results = run_ingest()

        mock_discover.assert_called_once()
        mock_classify.assert_called_once()
        mock_run_report.assert_called_once()
        assert results["discover"]["discovered"] == 5
        assert results["classify"]["classified"] == 5
        assert results["report"]["total_items"] == 2

    def test_skip_discover(self):
        """skip_discover=True skips feed polling."""
        mock_classify = MagicMock(return_value={"classified": 0, "errors": 0})
        mock_run_report = MagicMock()
        mock_get_report = MagicMock(return_value=None)

        with (
            patch(_P_DISCOVER) as mock_discover,
            patch(_P_CLASSIFY, mock_classify),
            patch(_P_RUN_REPORT, mock_run_report),
            patch(_P_GET_REPORT, mock_get_report),
        ):
            run_ingest(skip_discover=True)

        mock_discover.assert_not_called()

    def test_skip_classify(self):
        """skip_classify=True skips LLM classification."""
        mock_discover = MagicMock(return_value={"discovered": 0, "feeds_polled": 0, "errors": 0})
        mock_run_report = MagicMock()
        mock_get_report = MagicMock(return_value=None)

        with (
            patch(_P_DISCOVER, mock_discover),
            patch(_P_CLASSIFY) as mock_classify,
            patch(_P_RUN_REPORT, mock_run_report),
            patch(_P_GET_REPORT, mock_get_report),
        ):
            run_ingest(skip_classify=True)

        mock_classify.assert_not_called()

    def test_skip_report(self):
        """skip_report=True skips report generation."""
        mock_discover = MagicMock(return_value={"discovered": 0, "feeds_polled": 0, "errors": 0})
        mock_classify = MagicMock(return_value={"classified": 0, "errors": 0})

        with (
            patch(_P_DISCOVER, mock_discover),
            patch(_P_CLASSIFY, mock_classify),
            patch(_P_RUN_REPORT) as mock_run_report,
        ):
            run_ingest(skip_report=True)

        mock_run_report.assert_not_called()

    def test_discover_failure_continues_pipeline(self):
        """If discovery fails, classify and report still run."""
        mock_discover = MagicMock(side_effect=RuntimeError("Network error"))
        mock_classify = MagicMock(return_value={"classified": 0, "errors": 0})
        mock_run_report = MagicMock()
        mock_get_report = MagicMock(return_value=None)

        with (
            patch(_P_DISCOVER, mock_discover),
            patch(_P_CLASSIFY, mock_classify),
            patch(_P_RUN_REPORT, mock_run_report),
            patch(_P_GET_REPORT, mock_get_report),
        ):
            results = run_ingest()

        assert "error" in results["discover"]
        mock_classify.assert_called_once()

    def test_returns_stats_dict(self):
        """run_ingest returns a dict with per-stage results."""
        mock_discover = MagicMock(return_value={"discovered": 2, "feeds_polled": 1, "errors": 0})
        mock_classify = MagicMock(return_value={"classified": 2, "errors": 0})
        mock_run_report = MagicMock()
        mock_get_report = MagicMock(return_value=None)

        with (
            patch(_P_DISCOVER, mock_discover),
            patch(_P_CLASSIFY, mock_classify),
            patch(_P_RUN_REPORT, mock_run_report),
            patch(_P_GET_REPORT, mock_get_report),
        ):
            results = run_ingest()

        assert "discover" in results
        assert "classify" in results
        assert "report" in results


class TestCmdIngest:
    def test_cmd_ingest_dispatches(self):
        """cmd_ingest calls run_ingest."""
        from wilted.cli import cmd_ingest

        with patch("wilted.onboard.run_ingest", return_value={}) as mock:
            cmd_ingest([])

        mock.assert_called_once()

    def test_cmd_ingest_skip_flags(self):
        """--skip-* flags passed through."""
        from wilted.cli import cmd_ingest

        with patch("wilted.onboard.run_ingest", return_value={}) as mock:
            cmd_ingest(["--skip-discover", "--skip-classify"])

        mock.assert_called_once_with(
            skip_discover=True,
            skip_classify=True,
            skip_report=False,
        )


class TestCmdSetup:
    def test_cmd_setup_dispatches(self):
        """cmd_setup calls run_setup."""
        from wilted.cli import cmd_setup

        with patch("wilted.onboard.run_setup") as mock:
            cmd_setup([])

        mock.assert_called_once()


# ---------------------------------------------------------------------------
# run_setup — interactive flow
# ---------------------------------------------------------------------------

_P_LIST_FEEDS = "wilted.feeds.list_feeds"
_P_ADD_FEED = "wilted.feeds.add_feed"
_P_ADD_KEYWORD = "wilted.preferences.add_keyword"
_P_RUN_INGEST = "wilted.onboard.run_ingest"


def _fake_feed(title: str = "Test Feed") -> MagicMock:
    m = MagicMock()
    m.title = title
    return m


class TestRunSetup:
    def test_early_exit_when_existing_feeds_declined(self, monkeypatch):
        """User has feeds and declines — returns without adding anything."""
        inputs = iter(["n"])
        with (
            patch(_P_LIST_FEEDS, return_value=[_fake_feed("Existing")]),
            patch(_P_ADD_FEED) as mock_add,
        ):
            monkeypatch.setattr("builtins.input", lambda _: next(inputs))
            run_setup()

        mock_add.assert_not_called()

    def test_existing_feeds_proceeds_when_confirmed(self, monkeypatch):
        """User has feeds and confirms — setup continues to browsing step."""
        existing = [_fake_feed("Existing")]
        # y=continue, n=no browse, n=no custom, n=no keywords, n=no ingest
        inputs = iter(["y", "n", "n", "n", "n"])
        with (
            patch(_P_LIST_FEEDS, side_effect=[existing, existing]),
            patch(_P_ADD_FEED),
        ):
            monkeypatch.setattr("builtins.input", lambda _: next(inputs))
            run_setup()  # should not raise

    def test_add_all_starter_feeds(self, monkeypatch):
        """Selecting 'all' calls add_feed for every starter feed."""
        fake = _fake_feed()
        # y=browse, all=add all, n=no custom, n=no keywords, n=no ingest
        inputs = iter(["y", "all", "n", "n", "n"])
        with (
            patch(_P_LIST_FEEDS, side_effect=[[], [fake] * len(STARTER_FEEDS)]),
            patch(_P_ADD_FEED, return_value=fake) as mock_add,
        ):
            monkeypatch.setattr("builtins.input", lambda _: next(inputs))
            run_setup()

        assert mock_add.call_count == len(STARTER_FEEDS)

    def test_add_none_skips_all_starters(self, monkeypatch):
        """Selecting 'none' makes no add_feed calls."""
        # y=browse, none=add none, n=no custom, n=no keywords
        inputs = iter(["y", "none", "n", "n"])
        with (
            patch(_P_LIST_FEEDS, return_value=[]),
            patch(_P_ADD_FEED) as mock_add,
        ):
            monkeypatch.setattr("builtins.input", lambda _: next(inputs))
            run_setup()

        mock_add.assert_not_called()

    def test_add_specific_starters_by_number(self, monkeypatch):
        """Selecting '1 3' calls add_feed for feeds at positions 1 and 3."""
        fake = _fake_feed()
        # y=browse, '1 3'=select, n=no custom, n=no keywords
        inputs = iter(["y", "1 3", "n", "n"])
        with (
            patch(_P_LIST_FEEDS, return_value=[]),
            patch(_P_ADD_FEED, return_value=fake) as mock_add,
        ):
            monkeypatch.setattr("builtins.input", lambda _: next(inputs))
            run_setup()

        assert mock_add.call_count == 2
        called_urls = [c.args[0] for c in mock_add.call_args_list]
        assert STARTER_FEEDS[0]["url"] in called_urls
        assert STARTER_FEEDS[2]["url"] in called_urls

    def test_custom_feed_added(self, monkeypatch):
        """Custom feed URL, type, title, and playlist are passed to add_feed."""
        fake = _fake_feed("My Blog")
        # n=no browse, y=custom, url, type, title, playlist, n=no more, n=no keywords
        inputs = iter(
            [
                "n",
                "y",
                "https://example.com/feed.xml",
                "article",
                "My Blog",
                "",
                "n",
                "n",
            ]
        )
        with (
            patch(_P_LIST_FEEDS, return_value=[]),
            patch(_P_ADD_FEED, return_value=fake) as mock_add,
        ):
            monkeypatch.setattr("builtins.input", lambda _: next(inputs))
            run_setup()

        mock_add.assert_called_once_with(
            "https://example.com/feed.xml",
            feed_type="article",
            title="My Blog",
            default_playlist=None,
        )

    def test_keywords_added(self, monkeypatch):
        """Keyword and weight are passed to add_keyword."""
        fake_kw = MagicMock()
        fake_kw.keyword = "python"
        fake_kw.weight = 1.5
        # n=no browse, n=no custom, y=keywords, keyword, weight, blank=done
        inputs = iter(["n", "n", "y", "python", "1.5", ""])
        with (
            patch(_P_LIST_FEEDS, return_value=[]),
            patch(_P_ADD_KEYWORD, return_value=fake_kw) as mock_add_kw,
        ):
            monkeypatch.setattr("builtins.input", lambda _: next(inputs))
            run_setup()

        mock_add_kw.assert_called_once_with("python", weight=1.5)

    def test_ingest_called_when_confirmed(self, monkeypatch):
        """run_ingest is called when user has feeds and confirms."""
        fake = _fake_feed()
        # n=no browse, n=no custom, n=no keywords, y=run ingest
        inputs = iter(["n", "n", "n", "y"])
        with (
            patch(_P_LIST_FEEDS, side_effect=[[], [fake]]),
            patch(_P_RUN_INGEST) as mock_ingest,
        ):
            monkeypatch.setattr("builtins.input", lambda _: next(inputs))
            run_setup()

        mock_ingest.assert_called_once()

    def test_ingest_skipped_when_no_feeds(self, monkeypatch):
        """Step 3 is skipped when no feeds exist after setup."""
        # n=no browse, n=no custom, n=no keywords
        inputs = iter(["n", "n", "n"])
        with (
            patch(_P_LIST_FEEDS, return_value=[]),
            patch(_P_RUN_INGEST) as mock_ingest,
        ):
            monkeypatch.setattr("builtins.input", lambda _: next(inputs))
            run_setup()

        mock_ingest.assert_not_called()
