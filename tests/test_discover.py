"""Tests for Phase 2 — RSS discovery and dedup (discover.py)."""

from __future__ import annotations

from time import gmtime
from unittest.mock import MagicMock, patch

import pytest

from wilted.db import Feed, Item
from wilted.discover import (
    _dedup_hash,
    _entry_enclosure,
    _entry_guid,
    _entry_link,
    _fetch_article_text,
    _is_duplicate,
    _normalize_text,
    _process_entry,
    run_discover,
)
from wilted.feeds import add_feed

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _make_parsed_entry(**kwargs):
    """Create a mock feedparser entry dict."""
    defaults = {
        "title": "Test Article",
        "id": "guid-123",
        "link": "https://example.com/article-1",
        "published_parsed": None,
        "author": "Test Author",
        "summary": "Article summary text for testing.",
        "enclosures": [],
        "links": [],
        "content": [],
    }
    defaults.update(kwargs)
    return defaults


def _make_feed_result(entries=None, status=200, etag=None, modified=None):
    """Create a mock feedparser.parse() result."""
    result = MagicMock()
    result.status = status
    result.entries = entries or []
    result.etag = etag
    result.modified = modified
    result.feed = MagicMock()
    result.feed.title = "Test Feed"
    return result


# ---------------------------------------------------------------------------
# Normalization and hashing
# ---------------------------------------------------------------------------


class TestNormalizeText:
    def test_basic(self):
        assert _normalize_text("Hello World") == "hello world"

    def test_nfkd_decomposition(self):
        # fi ligature should decompose
        assert "fi" in _normalize_text("\ufb01")


class TestDedupHash:
    def test_same_input_same_hash(self):
        h1 = _dedup_hash("Title", "2026-04-17T00:00", "https://ex.com")
        h2 = _dedup_hash("Title", "2026-04-17T00:00", "https://ex.com")
        assert h1 == h2

    def test_different_title_different_hash(self):
        h1 = _dedup_hash("Title A", "2026-04-17T00:00", "https://ex.com")
        h2 = _dedup_hash("Title B", "2026-04-17T00:00", "https://ex.com")
        assert h1 != h2

    def test_none_pubdate_handled(self):
        h = _dedup_hash("Title", None, "https://ex.com")
        assert isinstance(h, str) and len(h) == 64


# ---------------------------------------------------------------------------
# Entry extractors
# ---------------------------------------------------------------------------


class TestEntryGuid:
    def test_extracts_id(self):
        entry = _make_parsed_entry(id="my-guid")
        assert _entry_guid(entry) == "my-guid"

    def test_none_when_missing(self):
        entry = _make_parsed_entry()
        del entry["id"]
        assert _entry_guid(entry) is None


class TestEntryLink:
    def test_extracts_link(self):
        entry = _make_parsed_entry(link="https://example.com")
        assert _entry_link(entry) == "https://example.com"


class TestEntryEnclosure:
    def test_audio_enclosure(self):
        entry = _make_parsed_entry(enclosures=[{"href": "https://ex.com/ep.mp3", "type": "audio/mpeg"}])
        url, enc_type = _entry_enclosure(entry)
        assert url == "https://ex.com/ep.mp3"
        assert enc_type == "audio/mpeg"

    def test_no_enclosure(self):
        entry = _make_parsed_entry(enclosures=[])
        url, enc_type = _entry_enclosure(entry)
        assert url is None

    def test_non_audio_enclosure_skipped(self):
        entry = _make_parsed_entry(enclosures=[{"href": "https://ex.com/img.jpg", "type": "image/jpeg"}])
        url, _ = _entry_enclosure(entry)
        assert url is None

    def test_mp3_extension_fallback(self):
        entry = _make_parsed_entry(enclosures=[{"href": "https://ex.com/file.mp3", "type": ""}])
        url, _ = _entry_enclosure(entry)
        assert url == "https://ex.com/file.mp3"


# ---------------------------------------------------------------------------
# Dedup
# ---------------------------------------------------------------------------


class TestIsDuplicate:
    def test_not_duplicate_when_empty(self):
        feed = add_feed("https://ex.com/feed.xml")
        assert not _is_duplicate(feed, "new-guid", "https://new.com", "newhash")

    def test_duplicate_by_guid(self):
        feed = add_feed("https://ex.com/feed.xml")
        Item.create(
            feed=feed,
            guid="dup-guid",
            title="Existing",
            discovered_at="2026-04-17T00:00:00Z",
            item_type="article",
            status="fetched",
            status_changed_at="2026-04-17T00:00:00Z",
        )
        assert _is_duplicate(feed, "dup-guid", None, "somehash")

    def test_duplicate_by_url(self):
        feed = add_feed("https://ex.com/feed.xml")
        Item.create(
            feed=feed,
            guid="other-guid",
            title="Existing",
            canonical_url="https://ex.com/article",
            discovered_at="2026-04-17T00:00:00Z",
            item_type="article",
            status="fetched",
            status_changed_at="2026-04-17T00:00:00Z",
        )
        assert _is_duplicate(feed, "new-guid", "https://ex.com/article", "somehash")

    def test_duplicate_by_content_hash(self):
        import json

        feed = add_feed("https://ex.com/feed.xml")
        Item.create(
            feed=feed,
            guid="other-guid",
            title="Existing",
            discovered_at="2026-04-17T00:00:00Z",
            item_type="article",
            status="fetched",
            status_changed_at="2026-04-17T00:00:00Z",
            metadata=json.dumps({"content_hash": "matchhash"}),
        )
        assert _is_duplicate(feed, "new-guid", None, "matchhash")


# ---------------------------------------------------------------------------
# Process entry — article
# ---------------------------------------------------------------------------


class TestProcessEntryArticle:
    @patch("wilted.discover._fetch_article_text")
    def test_new_article_creates_item(self, mock_fetch):
        mock_fetch.return_value = ("Article body text here.", "Fetched Title")

        feed = add_feed("https://ex.com/feed.xml", feed_type="article")
        entry = _make_parsed_entry(
            title="RSS Title",
            id="guid-1",
            link="https://ex.com/article-1",
        )
        stats = {"new": 0, "skipped": 0, "errors": 0}

        _process_entry(feed, entry, stats)

        assert stats["new"] == 1
        item = Item.select().where(Item.guid == "guid-1").first()
        assert item is not None
        assert item.title == "Fetched Title"
        assert item.status == "fetched"
        assert item.item_type == "article"
        assert item.word_count == 4
        assert item.transcript_file is not None

    @patch("wilted.discover._fetch_article_text")
    def test_duplicate_skipped(self, mock_fetch):
        mock_fetch.return_value = ("Body.", "Title")

        feed = add_feed("https://ex.com/feed.xml", feed_type="article")
        entry = _make_parsed_entry(id="guid-dup", link="https://ex.com/dup")

        stats = {"new": 0, "skipped": 0, "errors": 0}
        _process_entry(feed, entry, stats)
        assert stats["new"] == 1

        # Process same entry again
        stats2 = {"new": 0, "skipped": 0, "errors": 0}
        _process_entry(feed, entry, stats2)
        assert stats2["skipped"] == 1
        assert stats2["new"] == 0

    @patch("wilted.discover._fetch_article_text")
    def test_falls_back_to_rss_summary(self, mock_fetch):
        mock_fetch.return_value = (None, None)

        feed = add_feed("https://ex.com/feed.xml", feed_type="article")
        entry = _make_parsed_entry(
            id="guid-summary",
            summary="This is the RSS summary content.",
        )
        stats = {"new": 0, "skipped": 0, "errors": 0}

        _process_entry(feed, entry, stats)

        assert stats["new"] == 1
        item = Item.select().where(Item.guid == "guid-summary").first()
        assert item is not None


# ---------------------------------------------------------------------------
# Process entry — podcast
# ---------------------------------------------------------------------------


class TestProcessEntryPodcast:
    def test_new_podcast_episode(self):
        feed = add_feed("https://ex.com/podcast.xml", feed_type="podcast")
        entry = _make_parsed_entry(
            id="ep-1",
            title="Episode 1: Intro",
            enclosures=[{"href": "https://ex.com/ep1.mp3", "type": "audio/mpeg"}],
        )
        stats = {"new": 0, "skipped": 0, "errors": 0}

        _process_entry(feed, entry, stats)

        assert stats["new"] == 1
        item = Item.select().where(Item.guid == "ep-1").first()
        assert item is not None
        assert item.item_type == "podcast_episode"
        assert item.enclosure_url == "https://ex.com/ep1.mp3"
        assert item.fetch_state == "metadata"
        assert item.analysis_state == "pending"
        assert item.preparation_state == "not_queued"
        assert item.status == "discovered"

    def test_bws_podcast_persists_opaque_enclosure_reference(self):
        private_url = "https://private.example/credential-material.mp3"
        feed = add_feed("bws:WILTED_FEED_PRIVATE", feed_type="podcast")
        entry = _make_parsed_entry(id="ep-1", enclosures=[{"href": private_url, "type": "audio/mpeg"}])
        stats = {"new": 0, "skipped": 0, "errors": 0}

        _process_entry(feed, entry, stats)

        item = Item.select().where(Item.feed == feed).get()
        assert item.guid.startswith("bws-guid:")
        assert item.enclosure_url.startswith("bws-feed-item:WILTED_FEED_PRIVATE:")
        assert private_url not in item.enclosure_url

    def test_bws_podcast_never_persists_signed_identity_or_link(self, monkeypatch, caplog):
        signed_url = "https://private.example/signed-identity-and-link.mp3?token=secret"
        feed = add_feed("bws:WILTED_FEED_PRIVATE", feed_type="podcast")
        entry = _make_parsed_entry(
            id=signed_url,
            link=signed_url,
            enclosures=[{"href": signed_url, "type": "audio/mpeg"}],
        )
        stats = {"new": 0, "skipped": 0, "errors": 0}

        _process_entry(feed, entry, stats)

        item = Item.select().where(Item.feed == feed).get()
        assert signed_url not in item.guid
        assert item.source_url is None
        assert item.canonical_url is None
        assert signed_url not in (item.metadata or "")
        assert signed_url not in caplog.text

    def test_article_still_routed_through_classify(self):
        """Articles keep the classify/report flow — podcasts are pending candidates."""
        from unittest.mock import patch

        feed = add_feed("https://ex.com/blog.xml", feed_type="article")
        entry = _make_parsed_entry(id="art-1", title="A blog post", link="https://ex.com/post")
        stats = {"new": 0, "skipped": 0, "errors": 0}

        with patch("wilted.discover._fetch_article_text", return_value=("Body text.", "Title")):
            _process_entry(feed, entry, stats)

        item = Item.select().where(Item.guid == "art-1").first()
        assert item is not None
        assert item.item_type == "article"
        assert item.status == "fetched"

    def test_podcast_without_enclosure_skipped(self):
        feed = add_feed("https://ex.com/podcast.xml", feed_type="podcast")
        entry = _make_parsed_entry(id="ep-noaudio", enclosures=[])
        stats = {"new": 0, "skipped": 0, "errors": 0}

        _process_entry(feed, entry, stats)

        assert stats["skipped"] == 1
        assert stats["new"] == 0


# ---------------------------------------------------------------------------
# run_discover — integration
# ---------------------------------------------------------------------------


class TestRunDiscover:
    @staticmethod
    def _podcast_entry(episode_id: str):
        return _make_parsed_entry(
            id=episode_id,
            title=f"Episode {episode_id}",
            link=f"https://example.com/{episode_id}",
            enclosures=[{"href": f"https://example.com/{episode_id}.mp3", "type": "audio/mpeg"}],
        )

    @patch("wilted.discover.feedparser.parse")
    @patch("wilted.discover._fetch_article_text")
    def test_polls_enabled_feeds(self, mock_fetch, mock_parse):
        mock_fetch.return_value = ("Article text.", "Title")
        mock_parse.return_value = _make_feed_result(
            entries=[_make_parsed_entry(id="g1")],
            etag='"new-etag"',
        )

        add_feed("https://ex.com/feed.xml", feed_type="article")
        stats = run_discover()

        assert stats["feeds_polled"] == 1
        assert stats["discovered"] == 1
        assert stats["errors"] == 0
        mock_parse.assert_called_once()

    @patch("wilted.discover.feedparser.parse")
    def test_304_not_modified(self, mock_parse):
        mock_parse.return_value = _make_feed_result(status=304)
        add_feed("https://ex.com/feed.xml")

        stats = run_discover()
        assert stats["discovered"] == 0

    @patch("wilted.discover.feedparser.parse")
    def test_http_error_counted(self, mock_parse):
        mock_parse.return_value = _make_feed_result(status=403)
        add_feed("https://ex.com/feed.xml")

        stats = run_discover()
        assert stats["errors"] == 1

    @patch("wilted.discover.feedparser.parse")
    @patch("wilted.discover._fetch_article_text")
    def test_partial_failure_continues(self, mock_fetch, mock_parse):
        """One feed failing doesn't stop other feeds."""
        mock_fetch.return_value = ("Text.", "Title")

        add_feed("https://good.com/feed.xml", title="Good")
        add_feed("https://bad.com/feed.xml", title="Bad")

        def side_effect(url, **kwargs):
            if "bad" in url:
                return _make_feed_result(status=500)
            return _make_feed_result(
                entries=[_make_parsed_entry(id="good-item")],
            )

        mock_parse.side_effect = side_effect

        stats = run_discover()
        assert stats["feeds_polled"] == 2
        assert stats["discovered"] == 1
        assert stats["errors"] == 1

    @patch("wilted.discover.feedparser.parse")
    @patch("wilted.discover._fetch_article_text")
    def test_etag_stored_and_sent(self, mock_fetch, mock_parse):
        mock_fetch.return_value = ("Text.", "Title")
        mock_parse.return_value = _make_feed_result(
            entries=[_make_parsed_entry(id="first")],
            etag='"etag-value"',
        )

        feed = add_feed("https://ex.com/feed.xml")
        run_discover()

        # Verify etag was stored
        updated_feed = Feed.get_by_id(feed.id)
        assert updated_feed.etag == '"etag-value"'

    @patch("wilted.discover.feedparser.parse")
    @patch("wilted.discover._fetch_article_text")
    def test_feed_title_auto_updated(self, mock_fetch, mock_parse):
        """Feed title updates from RSS if it was set to the URL."""
        mock_fetch.return_value = ("Text.", "Title")
        result = _make_feed_result(
            entries=[_make_parsed_entry(id="item1")],
        )
        result.feed.title = "Real Feed Name"
        mock_parse.return_value = result

        # Feed created with URL as title
        feed = add_feed("https://ex.com/feed.xml")
        assert feed.title == "https://ex.com/feed.xml"

        run_discover()

        updated = Feed.get_by_id(feed.id)
        assert updated.title == "Real Feed Name"

    @patch("wilted.discover.feedparser.parse")
    def test_bws_fetch_error_does_not_log_resolved_url(self, mock_parse, monkeypatch, caplog):
        private_url = "https://private.example/credential-material.xml"
        monkeypatch.setenv("WILTED_FEED_PRIVATE", private_url)
        mock_parse.side_effect = RuntimeError(private_url)
        add_feed("bws:WILTED_FEED_PRIVATE", feed_type="podcast")

        stats = run_discover()

        assert stats["errors"] == 1
        assert private_url not in caplog.text
        assert "bws:WILTED_FEED_PRIVATE" in caplog.text

    @patch("wilted.discover.feedparser.parse")
    def test_second_podcast_poll_never_backfills_archive(self, mock_parse):
        feed = add_feed("https://example.com/podcast.xml", feed_type="podcast")
        newest_five = [self._podcast_entry(f"recent-{index}") for index in range(5)]
        archive = [self._podcast_entry(f"archive-{index}") for index in range(100)]
        mock_parse.side_effect = [
            _make_feed_result(entries=newest_five),
            _make_feed_result(entries=[*newest_five, *archive]),
        ]

        first_stats = run_discover()
        second_stats = run_discover()

        assert first_stats["discovered"] == 5
        assert second_stats["discovered"] == 0
        assert Item.select().where(Item.feed == feed).count() == 5

    @patch("wilted.discover.feedparser.parse")
    def test_new_podcast_episode_in_top_five_is_discovered(self, mock_parse):
        feed = add_feed("https://example.com/podcast.xml", feed_type="podcast")
        original_five = [self._podcast_entry(f"recent-{index}") for index in range(5)]
        next_five = [self._podcast_entry("brand-new"), *original_five[:4]]
        mock_parse.side_effect = [
            _make_feed_result(entries=original_five),
            _make_feed_result(entries=[*next_five, *[self._podcast_entry("old-archive")]]),
        ]

        run_discover()
        second_stats = run_discover()

        assert second_stats["discovered"] == 1
        assert Item.select().where(Item.feed == feed).count() == 6
        assert Item.select().where(Item.feed == feed, Item.guid == "brand-new").exists()

    @patch("wilted.discover.feedparser.parse")
    def test_podcast_window_uses_publication_date_not_feed_order(self, mock_parse):
        feed = add_feed("https://example.com/podcast.xml", feed_type="podcast")
        entries = [
            self._podcast_entry("oldest"),
            *[self._podcast_entry(f"new-{index}") for index in range(5)],
        ]
        entries[0]["published_parsed"] = gmtime(1)
        for index, entry in enumerate(entries[1:], start=2):
            entry["published_parsed"] = gmtime(index)
        mock_parse.return_value = _make_feed_result(entries=entries)

        stats = run_discover()

        assert stats["discovered"] == 5
        assert not Item.select().where(Item.feed == feed, Item.guid == "oldest").exists()


# ---------------------------------------------------------------------------
# INV-6 — nightly-path gate: CHEAP-budget fetch cascade integration
#
# These exercise the real wilted.fetch_cascade.resolve_article_text CHEAP
# path (not a mocked _fetch_article_text), matching how the nightly discover
# run actually calls it — only the transport (trafilatura.fetch_url /
# bare_extraction) is stubbed.
# ---------------------------------------------------------------------------


@pytest.fixture
def _reset_fetch_cascade_config_state():
    """Reset fetch_cascade's process-global config state around each test.

    ``fetch_cascade._configured``/``_trafilatura_config`` are module-global
    (see ``fetch_cascade._configure_once`` docstring) — without resetting
    them here, whichever test runs the CHEAP cascade first flips
    ``_configured = True`` for the rest of the session, and the timeout-bound
    assertions below would silently pass for the wrong reason (stale state
    from an earlier test) rather than because this test's own
    ``_configure_once()`` call did its job.
    """
    import wilted.fetch_cascade as fetch_cascade

    fetch_cascade._configured = False
    fetch_cascade._trafilatura_config = None
    yield
    fetch_cascade._configured = False
    fetch_cascade._trafilatura_config = None


class TestFetchArticleTextPerItemIsolation:
    """INV-6(a): one bad URL in a batch must not abort the other entries."""

    def test_bad_outcome_falls_back_and_batch_continues(self):
        """A blocked/failed cascade outcome for one entry still yields a
        typed, persisted item (via the RSS-summary fallback) and does not
        stop the surrounding good entries from being processed.
        """
        from wilted.fetch_cascade import ResolvedText

        def fake_resolve(url, *, budget, **kwargs):
            if "bad" in url:
                return ResolvedText(text=None, title=None, resolved_url=url, outcome="blocked", tier_used="none")
            return ResolvedText(
                text="Fetched body text for a good article.",
                title="Fetched Title",
                resolved_url=url,
                outcome="ok",
                tier_used="trafilatura",
            )

        feed = add_feed("https://ex.com/feed.xml", feed_type="article")
        entries = [
            _make_parsed_entry(id="good-1", link="https://ex.com/good-1", summary="Good one summary."),
            _make_parsed_entry(
                id="bad-1",
                link="https://ex.com/bad-1",
                summary="RSS summary fallback text for the bad entry.",
            ),
            _make_parsed_entry(id="good-2", link="https://ex.com/good-2", summary="Good two summary."),
        ]
        stats = {"new": 0, "skipped": 0, "errors": 0}

        with patch("wilted.fetch_cascade.resolve_article_text", side_effect=fake_resolve):
            for entry in entries:
                _process_entry(feed, entry, stats)

        # Item count unchanged by the bad URL: all three entries produced an
        # item (the bad one via RSS-summary fallback), and neither good
        # entry either side of it was skipped or errored.
        assert stats["new"] == 3
        assert stats["errors"] == 0
        assert stats["skipped"] == 0

        good_1 = Item.select().where(Item.guid == "good-1").first()
        good_2 = Item.select().where(Item.guid == "good-2").first()
        bad_1 = Item.select().where(Item.guid == "bad-1").first()
        assert good_1 is not None and good_1.title == "Fetched Title"
        assert good_2 is not None and good_2.title == "Fetched Title"
        assert bad_1 is not None

        # The bad entry's persisted text came from the RSS summary fallback,
        # not the (blocked) cascade.
        bad_transcript = open(bad_1.transcript_file, encoding="utf-8").read()
        assert "RSS summary fallback text for the bad entry." in bad_transcript


@pytest.mark.usefixtures("stub_trafilatura_module", "_reset_fetch_cascade_config_state")
class TestFetchArticleTextTransportRaises:
    """INV-6(b): a raising transport must never escape the discovery fetch path."""

    def test_fetch_url_raising_returns_none_none_not_exception(self):
        """trafilatura.fetch_url raising internally is absorbed by the
        cascade's own typed try/except (outcome="blocked"); no traceback
        propagates out of _fetch_article_text. Also covers one tier deeper:
        HTML fetched fine but bare_extraction itself raises — same
        guarantee, same (None, None), never raises.
        """

        def raising_fetch_url(url, config=None):
            raise ConnectionError("simulated transport failure")

        with patch("trafilatura.fetch_url", create=True, side_effect=raising_fetch_url):
            result = _fetch_article_text("https://example.com/raises")
        assert result == (None, None)

        def raising_bare_extraction(html, **kwargs):
            raise RuntimeError("simulated extraction failure")

        with (
            patch("trafilatura.fetch_url", create=True, return_value="<html>content</html>"),
            patch("trafilatura.bare_extraction", create=True, side_effect=raising_bare_extraction),
        ):
            result = _fetch_article_text("https://example.com/extraction-raises")
        assert result == (None, None)


@pytest.mark.usefixtures("stub_trafilatura_module", "_reset_fetch_cascade_config_state")
class TestConfigureOnceTimeoutBound:
    """INV-6(c): the CHEAP path's transport timeout is bounded, not unbounded."""

    def test_fetch_url_invoked_with_the_bounded_config(self):
        """The spike-locked FETCH_TIMEOUT_S global bounds every trafilatura
        fetch attempt: _configure_once() sets DOWNLOAD_TIMEOUT on the config
        object, and the nightly discover call site actually threads that
        same bounded config into trafilatura.fetch_url — asserted without
        any real network call.
        """
        from types import SimpleNamespace

        import wilted.fetch_cascade as fetch_cascade

        fetch_cascade._configure_once()
        assert fetch_cascade.FETCH_TIMEOUT_S == 30
        assert fetch_cascade._trafilatura_config.get("DEFAULT", "DOWNLOAD_TIMEOUT") == "30"

        captured = {}

        def fake_fetch_url(url, config=None):
            captured["config"] = config
            return "<html>content</html>"

        with (
            patch("trafilatura.fetch_url", create=True, side_effect=fake_fetch_url),
            patch(
                "trafilatura.bare_extraction",
                create=True,
                return_value=SimpleNamespace(text="word " * 30, title="Title"),
            ),
        ):
            text, _title = _fetch_article_text("https://example.com/bounded")

        assert text is not None
        assert captured.get("config") is fetch_cascade._trafilatura_config
        assert captured["config"].get("DEFAULT", "DOWNLOAD_TIMEOUT") == str(fetch_cascade.FETCH_TIMEOUT_S)
