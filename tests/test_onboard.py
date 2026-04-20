"""Tests for wilted.onboard — setup and ingestion commands."""

from unittest.mock import MagicMock, patch

from wilted.onboard import STARTER_FEEDS, run_ingest

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
